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
//!
//! `Decoder(T, serde_cfg, cbor_cfg)` is the same for a read: strict CBOR fed in chunks, as a request body arrives,
//! into a `T` (`Reading` for another layout, `wire.Reading` for `wire.Wire(T)`). `feed(chunk)` takes a whole chunk
//! and says whether the value is complete; the state is fixed by the config's `max_depth`, and every string is
//! copied once into the allocator it is given, which must be an arena or a fixed buffer, as nothing is freed on an
//! error. The value is the one the whole-input strict read gives, for every way the input is cut.

const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const meta = @import("meta.zig");
const root = @import("root.zig");
const cbor = @import("cbor.zig");
const chunk = @import("chunk.zig");
const typed_resume = @import("typed_resume.zig");
const json = @import("json.zig");
const bulk = @import("bulk.zig");

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

/// The deepest nesting a read of `cfg` allows, which fixes the size of its state.
fn depthOf(comptime cfg: anytype) usize {
    if (comptime @hasField(@TypeOf(cfg), "max_depth")) {
        if (cfg.max_depth > cbor.max_nesting) @compileError("max_depth is at most 128, the depth of the container stack");
        return cfg.max_depth;
    }
    return cbor.max_nesting;
}

/// The frames a read holds while it is in a value of type `T` until it reaches the first container inside, that one included: an
/// optional and a pointer to one value take one each, and a list, an array, a struct, a union or a sorted map is a container
/// and takes one. A string, a number or a `Raw` takes none.
fn wrapFrames(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .optional => |info| 1 + wrapFrames(info.child),
        .pointer => |info| switch (info.size) {
            .one => 1 + wrapFrames(info.child),
            .slice => if (info.child == u8) 0 else 1,
            else => 0,
        },
        .array => |info| if (info.child == u8) 0 else 1,
        .@"union" => 1,
        .@"struct" => if (typed.isRaw(T) or T == typed.ByteString) 0 else 1,
        else => 0,
    };
}

/// The most frames one step from a container to the next below it can take, anywhere in the type `T` reaches, looking through
/// a depth of 16 (a type that recurses repeats its steps by then): the frames of the value inside (`wrapFrames`), and one more for
/// a struct field that is a nested optional or an optional that must be absent rather than null, which has a frame of its own.
fn mostFrames(comptime T: type, comptime cfg: anytype, comptime depth: usize) usize {
    @setEvalBranchQuota(1_000_000);
    if (depth == 16) return 0;
    return comptime blk: {
        var most: usize = 0;
        switch (@typeInfo(T)) {
            .optional => |info| most = mostFrames(info.child, cfg, depth + 1),
            .array => |info| if (info.child != u8) {
                most = @max(wrapFrames(info.child), mostFrames(info.child, cfg, depth + 1));
            },
            .pointer => |info| switch (info.size) {
                .one => most = mostFrames(info.child, cfg, depth + 1),
                .slice => if (info.child != u8) {
                    most = @max(wrapFrames(info.child), mostFrames(info.child, cfg, depth + 1));
                },
                else => {},
            },
            .@"union" => |info| for (info.field_types) |PayloadType| {
                if (PayloadType != void) most = @max(most, @max(wrapFrames(PayloadType), mostFrames(PayloadType, cfg, depth + 1)));
            },
            .@"struct" => |info| {
                if (typed.isRaw(T) or T == typed.ByteString) break :blk 0;
                if (typed.isSortedMap(T)) {
                    break :blk @max(wrapFrames(T.Value), mostFrames(T.Value, cfg, depth + 1));
                }
                for (info.field_names, info.field_types) |name, FieldType| {
                    const nested = @typeInfo(FieldType) == .optional and @typeInfo(@typeInfo(FieldType).optional.child) == .optional;
                    const absent = @typeInfo(FieldType) == .optional and meta.effectiveOptionalPolicy(T, name, cfg) == .absent;
                    const own: usize = if (nested or absent) 1 else 0;
                    most = @max(most, @max(own + wrapFrames(FieldType), mostFrames(FieldType, cfg, depth + 1)));
                }
            },
            else => {},
        }
        break :blk most;
    };
}

/// How many frames a read of `T` needs at `depth` open containers: the root's, and for each container after it the most one
/// step takes. The walk indexes its frames and does not check, so this is a bound that holds for every input the depth allows.
fn frameCount(comptime T: type, comptime cfg: anytype, comptime depth: usize) usize {
    return wrapFrames(T) + depth * mostFrames(T, cfg, 0);
}

/// A resumable read of a `T` into `Sink`'s layout (`typed.TypedSink` for the Zig value, `wire.WireSink` for the fixed
/// layout), from strict CBOR in chunks: `cbor_cfg` must say `mode = .strict`, and its limits (`max_depth`,
/// `max_items`, `max_string_len`, `max_input_bytes`, `trusted_text`, `refuse_non_finite`) apply to the whole stream
/// as they do to a whole input. A struct it reaches must `deny_unknown_fields` and have no extras (`typed_resume.zig`),
/// and a type with a decode hook is a compile error. The allocator must be an arena or a fixed buffer: nothing a read
/// allocated is freed on an error.
pub fn Reading(comptime Sink: type, comptime T: type, comptime serde_cfg: anytype, comptime cbor_cfg: anytype) type {
    const ReaderType = chunk.Reader(@TypeOf(cbor_cfg));
    const depth = depthOf(cbor_cfg);
    const StateType = typed_resume.State(frameCount(T, serde_cfg, depth), longestKey(T, serde_cfg, 0), depth);
    return struct {
        reader: ReaderType,
        state: StateType = .{},
        sink: Sink,
        allocator: Allocator,
        dest: Sink.Of(T) = undefined,
        status: enum { reading, done, failed } = .reading,
        failure: anyerror = undefined,

        const Self = @This();

        pub fn init(sink: Sink, allocator: Allocator) Self {
            return .{ .reader = ReaderType.init(cbor_cfg), .sink = sink, .allocator = allocator };
        }

        /// Takes the next chunk of input, all of it, and says whether the value is complete. Bytes after the end of
        /// the value, in this chunk or a later one, are `error.TrailingCharacters`; an error is the same for every
        /// later call.
        pub fn feed(self: *Self, bytes: []const u8) anyerror!bool {
            switch (self.status) {
                .failed => return self.failure,
                .done => return if (bytes.len != 0) self.fail(error.TrailingCharacters) else true,
                .reading => {},
            }
            self.reader.feed(bytes) catch |err| return self.fail(err);
            typed.deserializeResumable(self.sink, T, &self.dest, self.allocator, &self.reader, serde_cfg, &self.state) catch |err| switch (err) {
                error.NeedMore => return false,
                else => return self.fail(err),
            };
            self.status = .done;
            if (!self.reader.atEnd()) return self.fail(error.TrailingCharacters);
            return true;
        }

        /// The value, once `feed` has said it is complete; the input ending before that is
        /// `error.UnexpectedEndOfInput`.
        pub fn finish(self: *Self) anyerror!Sink.Of(T) {
            switch (self.status) {
                .failed => return self.failure,
                .reading => return self.fail(error.UnexpectedEndOfInput),
                .done => return self.dest,
            }
        }

        fn fail(self: *Self, err: anyerror) anyerror {
            self.status = .failed;
            self.failure = err;
            return err;
        }
    };
}

/// `Reading` into the Zig value of `T`.
pub fn Decoder(comptime T: type, comptime serde_cfg: anytype, comptime cbor_cfg: anytype) type {
    return Reading(typed.TypedSink, T, serde_cfg, cbor_cfg);
}

/// Whether the stored item can be rendered as JSON, which the first window decides, so that nothing is written of one that cannot: every
/// map key is text (`error.UnexpectedType`), every float is finite (`error.NonFiniteFloat`) and, where bytes are written as JSON strings
/// (`text_bytes`), every byte string is UTF-8 (`error.InvalidUtf8`). It is checked once the item is known to be well-formed
/// (`cbor.verifyStrict`), so heads are not checked again; only the heads are read, and a string is stepped over.
fn checkRenderable(stored: []const u8, comptime text_bytes: bool) !void {
    var left: [cbor.max_nesting]u64 = undefined;
    var map: [cbor.max_nesting]bool = undefined;
    // For a map, whether the next item is a key (otherwise it is a value).
    var key: [cbor.max_nesting]bool = undefined;
    var depth: usize = 0;
    var at: usize = 0;
    while (true) {
        // A container whose items are all read is closed, which completes an item of the one around it.
        while (depth > 0 and left[depth - 1] == 0) {
            depth -= 1;
            itemRead(left[0..depth], map[0..depth], key[0..depth]);
        }
        if (depth == 0 and at != 0) return;
        const header = try cbor.parseHeader(stored, &at);
        if (depth > 0 and map[depth - 1] and key[depth - 1] and header.major != 3) return error.UnexpectedType;
        switch (header.major) {
            2, 3 => {
                if (text_bytes and header.major == 2 and !bulk.validUtf8(stored[at..][0..@intCast(header.value)])) return error.InvalidUtf8;
                at += @intCast(header.value);
                itemRead(left[0..depth], map[0..depth], key[0..depth]);
            },
            4, 5 => {
                left[depth] = header.value;
                map[depth] = header.major == 5;
                key[depth] = true;
                depth += 1;
            },
            7 => {
                if (header.ai >= 25 and header.ai <= 27 and !std.math.isFinite(cbor.floatValue(header))) return error.NonFiniteFloat;
                itemRead(left[0..depth], map[0..depth], key[0..depth]);
            },
            else => itemRead(left[0..depth], map[0..depth], key[0..depth]),
        }
    }
}

/// An item inside the innermost open container is complete: a map's key makes its value next, and its value completes an entry.
fn itemRead(left: []u64, map: []const bool, key: []bool) void {
    if (left.len == 0) return;
    const top = left.len - 1;
    if (map[top] and key[top]) {
        key[top] = false;
        return;
    }
    key[top] = true;
    left[top] -= 1;
}

/// Stored CBOR rendered as JSON in windows, by a cursor the caller owns: the same bytes as reading the item with `cbor.pullReader`
/// (strict) into `json.valueWriter` with `json_cfg`, which is what a whole-buffer render is. A map's keys are written in the order
/// they are stored, which for a deterministic item is the order the value writer sorts them into, so nothing is buffered, sorted or
/// written twice: a window ends at a token or inside a long string or byte string, which goes on from its byte. The item must be
/// well-formed and deterministic with keys that are text and floats that are finite; the first window decides that, for the whole
/// item, so that no window of an item that cannot be rendered is written (`cbor.verifyStrict` and the rules of JSON). Its errors are
/// those the whole-buffer render has, but for an item with more than one fault, the one it reports may be another.
///
/// `fill(stored, window)` writes the next piece; `stored` is the same in every call, and a window needs `min_window` bytes, which
/// holds any one token. The state is a word for each open container (at most 128) and the place in `stored`.
pub fn Render(comptime json_cfg: anytype) type {
    const Serializer = @TypeOf(json.serializer(@as(*std.Io.Writer, undefined), json_cfg));
    return struct {
        serializer: Serializer,
        levels: [cbor.max_nesting]Level = undefined,
        depth: usize = 0,
        /// The next head in `stored`.
        at: usize = 0,
        /// The text or byte string being written: where its bytes are in `stored`, and what it is.
        text: struct { start: usize = 0, len: usize = 0, kind: enum { none, key, text, bytes } = .none } = .{},
        leaf: typed.TextState = .{},
        checked: bool = false,
        finished: bool = false,

        const Self = @This();

        /// A container that is open: whether it is a map, the items (the entries of a map) it has yet to complete, how many it has,
        /// and where it is in the one in progress: an array item is begun (1) or not (0), a map entry is at its key (0), has written
        /// its key (1) or its colon is due (2) or is written and the value is next (3).
        const Level = struct { map: bool, left: u64, index: u64 = 0, phase: u8 = 0 };

        /// What one step needs: a number, a head, a bracket, a comma or a colon.
        pub const min_window: usize = typed.atomic_room;

        pub fn init() Self {
            return .{ .serializer = json.serializer(@as(*std.Io.Writer, undefined), json_cfg) };
        }

        pub fn fill(self: *Self, stored: []const u8, window: []u8) !Filled {
            if (self.finished) return .{ .len = 0, .done = true };
            if (window.len < min_window) return error.WindowTooSmall;
            if (!self.checked) {
                try cbor.verifyStrict(stored, true);
                try checkRenderable(stored, json.bytesEncoding(@TypeOf(json_cfg), json_cfg) == .string);
                self.checked = true;
            }
            var writer = std.Io.Writer.fixed(window);
            self.serializer.writer = &writer;
            self.run(stored, &writer) catch |err| switch (err) {
                error.WindowFull => return .{ .len = writer.end, .done = false },
                else => return err,
            };
            return .{ .len = writer.end, .done = true };
        }

        fn reserve(w: *const std.Io.Writer) error{WindowFull}!void {
            if (w.buffer.len - w.end < typed.atomic_room) return error.WindowFull;
        }

        /// Goes on until the window is full or the item is done. Every token is written after a check that the window has room for it, so
        /// a step that fails for want of room has changed nothing, and the same step is made again in the next window.
        fn run(self: *Self, stored: []const u8, w: *std.Io.Writer) !void {
            const serializer = &self.serializer;
            while (true) {
                if (self.text.kind != .none) {
                    const bytes = stored[self.text.start..][0..self.text.len];
                    switch (self.text.kind) {
                        .key, .text => try serializer.emitStringPart(bytes, &self.leaf),
                        .bytes => try serializer.emitBytesPart(bytes, &self.leaf),
                        .none => unreachable,
                    }
                    self.leaf = .{};
                    const kind = self.text.kind;
                    self.text.kind = .none;
                    if (kind == .key) self.levels[self.depth - 1].phase = 2 else self.valueDone();
                    continue;
                }
                if (self.depth == 0) {
                    if (self.finished) return;
                } else {
                    const top = &self.levels[self.depth - 1];
                    if (top.map and top.phase == 2) {
                        try reserve(w);
                        try serializer.endMapKey();
                        top.phase = 3;
                        continue;
                    }
                    if (top.left == 0) {
                        try reserve(w);
                        if (top.map) try serializer.endStruct(void) else try serializer.endArray(void, 0);
                        self.depth -= 1;
                        self.valueDone();
                        continue;
                    }
                }
                try self.next(stored, w);
            }
        }

        /// The item at `at` has been written, whole: it completes an entry or an element of the container around it, or the item.
        fn valueDone(self: *Self) void {
            if (self.depth == 0) {
                self.finished = true;
                return;
            }
            const top = &self.levels[self.depth - 1];
            top.left -= 1;
            top.index += 1;
            top.phase = 0;
        }

        /// Begins the next key or value: the head is read once the room for what it writes is known.
        fn next(self: *Self, stored: []const u8, w: *std.Io.Writer) !void {
            const serializer = &self.serializer;
            const level: ?*Level = if (self.depth == 0) null else &self.levels[self.depth - 1];
            if (level) |top| {
                if (!top.map and top.phase == 0) {
                    try reserve(w);
                    try serializer.beginArrayItem(void, @intCast(top.index));
                    top.phase = 1;
                }
                if (top.map and top.phase == 0) {
                    try reserve(w);
                    var at = self.at;
                    const head = try cbor.parseHeader(stored, &at);
                    try serializer.beginMapEntry();
                    self.at = at + @as(usize, @intCast(head.value));
                    self.text = .{ .start = at, .len = @intCast(head.value), .kind = .key };
                    top.phase = 1;
                    return;
                }
            }
            try reserve(w);
            const head = try cbor.parseHeader(stored, &self.at);
            switch (head.major) {
                0 => try serializer.emitInteger(@as(i128, head.value)),
                1 => try serializer.emitInteger(-1 - @as(i128, head.value)),
                2, 3 => {
                    self.text = .{ .start = self.at, .len = @intCast(head.value), .kind = if (head.major == 3) .text else .bytes };
                    self.at += @intCast(head.value);
                    return;
                },
                4, 5 => {
                    if (head.major == 5) try serializer.beginStruct(void) else try serializer.beginArray(void, @intCast(head.value));
                    self.levels[self.depth] = .{ .map = head.major == 5, .left = head.value };
                    self.depth += 1;
                    return;
                },
                else => switch (head.ai) {
                    20 => try serializer.emitBool(false),
                    21 => try serializer.emitBool(true),
                    22 => try serializer.emitNull(),
                    else => try serializer.emitFloat(cbor.floatValue(head)),
                },
            }
            self.valueDone();
        }
    };
}
