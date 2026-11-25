//! A strict CBOR reader fed in chunks.
//!
//! `Reader(Config)` reads the deterministic encoding (`mode = .strict`: shortest heads, definite lengths,
//! preferred floats, ascending keys, no tags) from input that arrives in pieces, the way a request body does. It
//! keeps no input: a head cut by the end of a chunk waits in a small buffer of 8 bytes, a string goes on from its
//! byte, and the typed read above it (`typed_resume.zig`) keeps where it is in each open container. Every call
//! that needs more bytes than the chunk holds returns `error.NeedMore` having taken what there was, and the
//! caller feeds the next chunk and makes the same call again.
//!
//! What it holds is fixed: the head buffer, the limits and three counters, and a `RawScan` of at most `max_depth`
//! words while a `Raw` item is read. A chunk is never copied whole: the bytes of a string or a `Raw` go where the
//! caller says, once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cbor = @import("cbor.zig");
const typed = @import("typed.zig");
const meta = @import("meta.zig");

const Header = cbor.Header;
const ValueKind = typed.ValueKind;
const Number = typed.Number;

/// The `error.NeedMore` that every call may return, and the errors a read can end with beyond the whole-input
/// reader's: `InputTooLarge` for a stream longer than `max_input_bytes`.
pub const NeedMore = error{NeedMore};

/// The most bytes of a head: the initial byte and eight of length or value.
const head_max = 9;

fn optionOf(cfg: anytype, comptime name: []const u8, default: anytype) @TypeOf(default) {
    if (comptime meta.hasField(@TypeOf(cfg), name)) return @field(cfg, name);
    return default;
}

/// The bytes of a head the initial byte `initial` says it has.
fn headRoom(initial: u8) usize {
    return 1 + @as(usize, switch (initial & 0x1f) {
        24 => 1,
        25 => 2,
        26 => 4,
        27 => 8,
        else => 0,
    });
}

/// An item being copied out as it is read: its bytes in `buf` (grown through `allocator`, never past `cap`), and
/// where the scan is in it. The state is `remaining` for each open container and the bytes of a string still to
/// come: a fixed size, whatever the item.
pub fn RawScan(comptime depth: usize) type {
    return struct {
        allocator: Allocator,
        buf: []u8 = &.{},
        filled: usize = 0,
        cap: usize,
        /// The items still to read in each open container of the item (a map counts its keys and values).
        remaining: [depth]u64 = undefined,
        open: usize = 0,
        /// Bytes of the string being copied that have not come yet.
        body: u64 = 0,

        const Self = @This();

        /// Room for `n` bytes more at `filled`: `error.LengthOutOfBounds` past `cap`, else the buffer grows by half
        /// again, or to what is needed. A buffer that is the allocator's last allocation grows where it is.
        fn room(self: *Self, n: usize) ![]u8 {
            const needed = std.math.add(usize, self.filled, n) catch return error.LengthOutOfBounds;
            if (needed > self.cap) return error.LengthOutOfBounds;
            if (needed > self.buf.len) {
                const grown = @max(needed, @min(self.cap, self.buf.len + self.buf.len / 2 + 64));
                self.buf = try self.allocator.realloc(self.buf, grown);
            }
            return self.buf[self.filled..][0..n];
        }

        /// The item's bytes, in an allocation of exactly their length.
        pub fn finish(self: *Self) ![]u8 {
            self.buf = try self.allocator.realloc(self.buf, self.filled);
            return self.buf;
        }
    };
}

pub fn Reader(comptime Config: type) type {
    return struct {
        chunk: []const u8 = &.{},
        index: usize = 0,
        /// The front of a head that the end of the last chunk cut.
        pending: [head_max - 1]u8 = undefined,
        pending_len: usize = 0,
        /// The bytes of the head `takeHead` last took, for a `Raw` that keeps them.
        head_bytes: [head_max]u8 = undefined,
        head_len: usize = 0,
        /// Bytes fed so far and bytes taken so far, which differ by what is in `pending` and the chunk.
        fed: u64 = 0,
        position: u64 = 0,
        items: usize = 0,
        open: usize = 0,
        cfg: Config,

        const Self = @This();

        pub const supports_unions = true;
        pub const supports_integer_keys = true;
        pub const keyEncoder = cbor.encodeKey;

        pub fn init(comptime cfg: Config) Self {
            comptime {
                if (!meta.hasField(Config, "mode") or cfg.mode != cbor.Mode.strict) @compileError("a resumable read reads strict CBOR: set mode = .strict");
            }
            return .{ .cfg = cfg };
        }

        pub fn maxDepth(self: *const Self) usize {
            return optionOf(self.cfg, "max_depth", cbor.max_nesting);
        }

        pub fn maxItems(self: *const Self) usize {
            return optionOf(self.cfg, "max_items", std.math.maxInt(usize));
        }

        pub fn maxStringLen(self: *const Self) usize {
            return optionOf(self.cfg, "max_string_len", std.math.maxInt(usize));
        }

        pub fn maxInputBytes(self: *const Self) usize {
            return optionOf(self.cfg, "max_input_bytes", (cbor.ReadConfig{}).max_input_bytes);
        }

        /// The bytes the stream may still hold: what `max_input_bytes` allows past the bytes taken.
        pub fn inputLeft(self: *const Self) usize {
            return self.maxInputBytes() - @as(usize, @intCast(@min(self.position, self.maxInputBytes())));
        }

        pub fn trustedText(self: *const Self) bool {
            return optionOf(self.cfg, "trusted_text", false);
        }

        pub fn keysAscend(_: *const Self) bool {
            return true;
        }

        /// The read accepts only the deterministic encoding: one value, one encoding.
        pub fn isStrict(_: *const Self) bool {
            return true;
        }

        /// Gives the reader its next chunk, which it must be done with (every call before it said `NeedMore`, or the
        /// item is complete). A stream longer than `max_input_bytes` is `error.InputTooLarge`.
        pub fn feed(self: *Self, chunk: []const u8) !void {
            std.debug.assert(self.index == self.chunk.len);
            const total = std.math.add(u64, self.fed, chunk.len) catch return error.InputTooLarge;
            if (total > self.maxInputBytes()) return error.InputTooLarge;
            self.fed = total;
            self.chunk = chunk;
            self.index = 0;
        }

        /// Whether every byte fed has been taken: what is left after the item is complete is trailing.
        pub fn atEnd(self: *const Self) bool {
            return self.index == self.chunk.len and self.pending_len == 0;
        }

        const Peeked = struct { header: Header, len: usize };

        /// The head in front, not taken. A head the chunk cuts is kept (all of the chunk goes to `pending`) and
        /// the call is `NeedMore`; the next chunk completes it.
        fn peekHead(self: *Self) !Peeked {
            const rest = self.chunk[self.index..];
            const have = self.pending_len + rest.len;
            if (have == 0) return error.NeedMore;
            const initial = if (self.pending_len != 0) self.pending[0] else rest[0];
            const need = headRoom(initial);
            if (have < need) {
                @memcpy(self.pending[self.pending_len..][0..rest.len], rest);
                self.pending_len += rest.len;
                self.index = self.chunk.len;
                return error.NeedMore;
            }
            var cursor: usize = 0;
            if (self.pending_len == 0) {
                const header = try cbor.parseHeader(rest[0..need], &cursor);
                return .{ .header = header, .len = need };
            }
            var joined: [head_max]u8 = undefined;
            @memcpy(joined[0..self.pending_len], self.pending[0..self.pending_len]);
            @memcpy(joined[self.pending_len..need], rest[0 .. need - self.pending_len]);
            const header = try cbor.parseHeader(joined[0..need], &cursor);
            return .{ .header = header, .len = need };
        }

        /// Takes the head `peekHead` found: counts it against `max_items` and refuses what the deterministic
        /// encoding does not allow, as the whole-input strict reader does.
        fn commitHead(self: *Self, peeked: Peeked) !Header {
            const header = peeked.header;
            self.items += 1;
            if (self.items > self.maxItems()) return error.TooManyItems;
            if (header.major == 6) return error.UnexpectedTag;
            if (header.indefinite or !cbor.isShortestHead(header)) return error.NonDeterministicEncoding;
            if (header.major == 7 and !cbor.isPreferredFloat(header)) return error.NonDeterministicEncoding;
            const from_pending = self.pending_len;
            const from_chunk = peeked.len - from_pending;
            @memcpy(self.head_bytes[0..from_pending], self.pending[0..from_pending]);
            @memcpy(self.head_bytes[from_pending..][0..from_chunk], self.chunk[self.index..][0..from_chunk]);
            self.head_len = peeked.len;
            self.index += from_chunk;
            self.pending_len = 0;
            self.position += peeked.len;
            return header;
        }

        fn takeHead(self: *Self) !Header {
            return self.commitHead(try self.peekHead());
        }

        /// The kind of the item in front, which is not taken. A tag is `error.UnexpectedTag`: a strict read has none.
        pub fn peekKind(self: *Self) !ValueKind {
            const header = (try self.peekHead()).header;
            return switch (header.major) {
                0, 1 => .number,
                2 => .bytes,
                3 => .string,
                4 => .array,
                5 => .object,
                6 => error.UnexpectedTag,
                else => switch (header.ai) {
                    20, 21 => .bool,
                    22 => .null,
                    25, 26, 27 => .number,
                    else => error.UnexpectedToken,
                },
            };
        }

        /// Takes a null, after `peekKind` said that is what is in front.
        pub fn readNull(self: *Self) !void {
            _ = try self.takeHead();
        }

        pub fn readBool(self: *Self) !bool {
            const header = try self.takeHead();
            if (header.major != 7) return error.UnexpectedType;
            return switch (header.ai) {
                20 => false,
                21 => true,
                else => error.UnexpectedType,
            };
        }

        pub fn readNumber(self: *Self) !Number {
            const header = try self.takeHead();
            try self.checkFloat(header);
            return switch (header.major) {
                0 => .{ .integer = @as(i128, @intCast(header.value)) },
                1 => .{ .integer = -@as(i128, @intCast(header.value)) - 1 },
                7 => switch (header.ai) {
                    25 => .{ .float = @as(f64, @floatCast(@as(f16, @bitCast(@as(u16, @intCast(header.value)))))) },
                    26 => .{ .float = @as(f64, @floatCast(@as(f32, @bitCast(@as(u32, @intCast(header.value)))))) },
                    27 => .{ .float = @as(f64, @bitCast(header.value)) },
                    else => error.UnexpectedType,
                },
                else => error.UnexpectedType,
            };
        }

        /// Refuses what the config says to in a float, as the whole-input reader does.
        fn checkFloat(self: *Self, header: Header) !void {
            try cbor.checkFloatHeader(Config, self.cfg, header);
        }

        /// `count` items of at least `per` bytes each cannot fit in what the stream may still hold, nor in what
        /// `max_items` has left: refused before anything is allocated for them, as the whole-input reader refuses a
        /// length that claims more items than the input has bytes (its input here is what `max_input_bytes` allows).
        fn claim(self: *Self, count: u64, per: usize) !usize {
            const left = self.inputLeft();
            if (count > left / per) return error.UnexpectedEndOfInput;
            if (count * per > self.maxItems() - self.items) return error.TooManyItems;
            return @intCast(count);
        }

        pub fn beginArrayLen(self: *Self) !usize {
            return self.beginContainer(4, 1);
        }

        pub fn beginMapLen(self: *Self) !usize {
            return self.beginContainer(5, 2);
        }

        fn beginContainer(self: *Self, comptime major: u8, comptime per: usize) !usize {
            const header = try self.takeHead();
            if (header.major != major) return error.UnexpectedType;
            const count = try self.claim(header.value, per);
            if (self.open >= self.maxDepth()) return error.CborNestingTooDeep;
            self.open += 1;
            return count;
        }

        /// A container the typed read has read to its end.
        pub fn endContainer(self: *Self) void {
            self.open -= 1;
        }

        /// The head of a text string (`major` 3) or byte string (2): its length, which `own_max` (a field's
        /// `max_len`) and `max_string_len` bound, the field's as `LengthOutOfBounds`. The bytes follow, by `takePart`.
        pub fn beginString(self: *Self, comptime major: u8, own_max: usize) !usize {
            const header = try self.takeHead();
            if (header.major != major) return error.UnexpectedType;
            return self.stringLen(header, own_max);
        }

        fn stringLen(self: *Self, header: Header, own_max: usize) !usize {
            const configured = self.maxStringLen();
            if (header.value > @min(own_max, configured)) return if (own_max < configured) error.LengthOutOfBounds else error.StringTooLong;
            if (header.value > self.maxInputBytes() - @min(self.position, self.maxInputBytes())) return error.UnexpectedEndOfInput;
            return @intCast(header.value);
        }

        /// Copies as much of the string in progress as the chunk has into `out`, and says how much.
        pub fn takePart(self: *Self, out: []u8) usize {
            std.debug.assert(self.pending_len == 0);
            const rest = self.chunk[self.index..];
            const n = @min(out.len, rest.len);
            @memcpy(out[0..n], rest[0..n]);
            self.index += n;
            self.position += n;
            return n;
        }

        /// Where the next byte is in the whole stream, from its first byte: the start of a string just after its head.
        pub fn streamPosition(self: *const Self) u64 {
            return self.position;
        }

        /// Takes up to `n` bytes of the string in progress without copying them: a view of the chunk, valid until the next call.
        pub fn takeView(self: *Self, n: usize) []const u8 {
            std.debug.assert(self.pending_len == 0);
            const count = @min(n, self.chunk.len - self.index);
            const view = self.chunk[self.index..][0..count];
            self.index += count;
            self.position += count;
            return view;
        }

        /// Copies the next item whole into `scan.buf`, as far as the chunk goes, and returns once it is complete
        /// (`scan.filled` bytes). The heads are checked as `takeHead` checks them, so the item is well-formed and
        /// within `max_depth`, `max_items` and `max_string_len`; what needs the item as a whole (the order of its keys,
        /// its text) is `cbor.verifyStrict`'s, on the bytes.
        pub fn scanItem(self: *Self, scan: anytype) !void {
            while (true) {
                if (scan.body > 0) {
                    // The bytes of a string go on: as many as the chunk has, within the room the cap leaves.
                    const want: usize = @intCast(@min(scan.body, self.chunk.len - self.index));
                    if (want == 0) return error.NeedMore;
                    const out = try scan.room(want);
                    const n = self.takePart(out);
                    scan.filled += n;
                    scan.body -= n;
                    if (scan.body > 0) return error.NeedMore;
                    if (self.itemDone(scan)) return;
                    continue;
                }
                const peeked = try self.peekHead();
                const out = try scan.room(peeked.len);
                const header = try self.commitHead(peeked);
                @memcpy(out, self.head_bytes[0..self.head_len]);
                scan.filled += self.head_len;
                switch (header.major) {
                    0, 1 => {},
                    7 => try self.checkFloat(header),
                    2, 3 => {
                        const len = try self.stringLen(header, std.math.maxInt(usize));
                        if (len > 0) {
                            scan.body = len;
                            continue;
                        }
                    },
                    else => {
                        const per: usize = if (header.major == 5) 2 else 1;
                        const count = try self.claim(header.value, per);
                        if (self.open >= self.maxDepth()) return error.CborNestingTooDeep;
                        if (count > 0) {
                            scan.remaining[scan.open] = count * per;
                            scan.open += 1;
                            self.open += 1;
                            continue;
                        }
                    },
                }
                if (self.itemDone(scan)) return;
            }
        }

        /// An item inside the innermost open container of `scan` is complete: counts it, closes the containers it
        /// completes, and says whether the whole item is complete.
        fn itemDone(self: *Self, scan: anytype) bool {
            while (scan.open > 0) {
                scan.remaining[scan.open - 1] -= 1;
                if (scan.remaining[scan.open - 1] > 0) return false;
                scan.open -= 1;
                self.open -= 1;
            }
            return true;
        }
    };
}
