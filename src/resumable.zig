//! Resumable writes: a typed value written in windows.
//!
//! `Writer(Format, T, ...)` holds the state of one write of a `T` as JSON or CBOR, a few words for each open
//! container, and `fill` writes the next piece of it into a fixed window and returns, so a caller with a window
//! of 64 KiB can write a value of any size, handing each window to a stream and asking for the next when the
//! stream has room. Nothing is buffered, sorted or written twice: a window ends at a token, or inside a long
//! string, byte string or `Raw`, which goes on from its byte, and the next call descends the same path of
//! containers by the indexes the state keeps. A window needs `min_window` bytes, which holds any one token.
//!
//! The same typed walk writes the value as `zerde.serializeWith` does, so every rule of the schema (keys, field
//! order, optional policy, determinism, text checks) holds and the bytes are the same. Not supported, each a
//! compile error: extras, encode hooks and a format's sequence fast path (`bin`). The value must be the same in
//! every call, and the window is the only place output goes.

const std = @import("std");
const typed = @import("typed.zig");
const root = @import("root.zig");

pub const Error = error{
    /// The window is smaller than one token: no step could be taken in it.
    WindowTooSmall,
    /// More containers are open at once than a resumable write keeps (`typed.resume_max_depth`).
    ResumeTooDeep,
};

/// One window of output.
pub const Filled = struct {
    /// The bytes of the window that hold output.
    len: usize,
    /// The value is written entirely; a later `fill` writes nothing.
    done: bool,
};

pub fn Writer(comptime Format: type, comptime T: type, comptime serde_cfg: anytype, comptime format_cfg: anytype) type {
    const Serializer = @TypeOf(Format.serializer(@as(*std.Io.Writer, undefined), format_cfg));
    return struct {
        state: typed.ResumeState = .{},
        serializer: Serializer,
        finished: bool = false,

        const Self = @This();

        /// The smallest window `fill` can make progress in: the largest token the schema writes, which is a
        /// number or a head and the longest field name, escaped.
        pub const min_window: usize = typed.atomic_room + 6 * longestKey(T, serde_cfg, 0) + 7;

        pub fn init() Self {
            return .{ .serializer = Format.serializer(@as(*std.Io.Writer, undefined), format_cfg) };
        }

        /// Writes the next piece of `value` into `window` and says how much of it is output and whether that
        /// was the last. `value` is the same in every call; a call after the last writes nothing.
        pub fn fill(self: *Self, value: T, window: []u8) !Filled {
            if (self.finished) return .{ .len = 0, .done = true };
            if (window.len < min_window) return error.WindowTooSmall;
            var writer = std.Io.Writer.fixed(window);
            self.serializer.writer = &writer;
            self.state.window = &writer;
            defer self.state.window = null;
            typed.serializeResumable(&self.serializer, value, serde_cfg, Format, format_cfg, &self.state) catch |err| switch (err) {
                error.WindowFull => return .{ .len = writer.end, .done = false },
                else => return err,
            };
            self.finished = true;
            return .{ .len = writer.end, .done = true };
        }
    };
}

/// The length of the longest field name or variant name that writing a `T` can put out, looking through containers
/// to a depth of 16 (a type that recurses repeats its names by then).
fn longestKey(comptime T: type, comptime cfg: anytype, comptime depth: usize) usize {
    @setEvalBranchQuota(1_000_000);
    if (depth == 16) return 0;
    return comptime blk: {
        var longest: usize = 0;
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                if (typed.isRaw(T) or T == typed.ByteString) break :blk 0;
                for (info.field_types) |FieldType| longest = @max(longest, longestKey(FieldType, cfg, depth + 1));
                longest = @max(longest, typed.longestFieldName(T, cfg));
            },
            .@"union" => |info| {
                for (info.field_types) |PayloadType| {
                    if (PayloadType != void) longest = @max(longest, longestKey(PayloadType, cfg, depth + 1));
                }
                for (info.field_names) |name| longest = @max(longest, name.len);
            },
            .@"enum" => |info| for (info.field_names) |name| {
                longest = @max(longest, name.len);
            },
            .optional => |info| longest = longestKey(info.child, cfg, depth + 1),
            .array => |info| longest = longestKey(info.child, cfg, depth + 1),
            .pointer => |info| longest = longestKey(info.child, cfg, depth + 1),
            else => {},
        }
        break :blk longest;
    };
}
