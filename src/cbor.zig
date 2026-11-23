//! CBOR backend for the typed walk.
//!
//! The write path writes arrays with definite lengths and, by default, structs as indefinite maps
//! in declaration order. `WriteConfig.deterministic` selects the core deterministic encoding of
//! RFC 8949 §4.2.1 instead. Text fields are CBOR text strings, `[N]u8` and `zerde.ByteString` are
//! byte strings, and a tagged union is a one-entry map (see `typed.zig`).
//!
//! The read path accepts any well-formed CBOR (RFC 8949 §5.3) whatever the encoder chose:
//! non-minimal heads, half, single and double floats for one value, unsorted maps and
//! indefinite-length arrays, maps and strings. What it checks beyond that is what a typed value
//! needs to be unambiguous:
//!
//!   * a text string is valid UTF-8, and a byte string is not a text string or the reverse;
//!   * a map has no two equal keys, including in values the typed layer skips (RFC 8949 §5.6);
//!   * nesting is bounded at `max_nesting`, so a hostile input cannot exhaust the stack;
//!   * a length cannot claim more items than the rest of the input holds;
//!   * a tag other than 55799 (self-described CBOR, RFC 8949 §3.4.6) is `error.UnexpectedTag` when
//!     a typed value would be read through it. A skipped value may carry any tag.
//!
//! Output is deterministic whatever the input form was: reading never changes how a value is written.

const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const meta = @import("meta.zig");
const bulk = @import("bulk.zig");
const Number = typed.Number;
const StringToken = typed.StringToken;
const ValueKind = typed.ValueKind;
const ObjectFieldLookup = typed.ObjectFieldLookup;

pub const FieldCase = meta.FieldCase;

/// Most containers that may be open at once, in a typed read and in a skipped value alike.
pub const max_nesting = 128;

/// The tag of self-described CBOR (RFC 8949 §3.4.6), which has no meaning to a reader.
const self_described_tag = 55799;

pub const ReadConfig = struct {
    max_input_bytes: usize = 16 * 1024 * 1024,
    borrow_strings: bool = false,
    /// Refuse NaN and the infinities in any float, including in skipped values and keys
    /// (`error.NonFiniteFloat`). RFC 8949 §3.3 makes them values, so the default reads them; a
    /// profile that forbids them turns this on.
    refuse_non_finite: bool = false,
    /// Which encodings are accepted; see `Mode`.
    mode: Mode = .lenient,
    /// Most containers open at once, at most `max_nesting`.
    max_depth: usize = max_nesting,
    /// Most data items in the whole input, map keys and values each counted (`error.TooManyItems`).
    max_items: usize = std.math.maxInt(usize),
    /// Longest text or byte string in bytes, after its chunks are joined (`error.StringTooLong`).
    max_string_len: usize = std.math.maxInt(usize),
};

/// Which encodings a read accepts.
pub const Mode = enum {
    /// Any well-formed CBOR (RFC 8949 §5.3), as the module documentation lists.
    lenient,
    /// Only the deterministic encoding of RFC 8949 §4.2.1 with the preferred floats of §4.2.2, which
    /// is the form `WriteConfig.deterministic` writes: shortest heads, definite lengths, map keys in
    /// strictly ascending order of their encoded bytes, floats in the shortest exact width and NaN
    /// only as `0xf97e00`, and no tags (self-described CBOR included). Anything else is
    /// `error.NonDeterministicEncoding`, or `error.DuplicateField` for a repeated key and
    /// `error.UnexpectedTag` for a tag. This is the check a boundary that requires canonical input uses.
    strict,
};
pub const WriteConfig = struct {
    /// Write the core deterministic encoding of RFC 8949 §4.2.1, so equal values produce equal
    /// bytes that can be hashed or signed: definite-length maps, struct fields in the bytewise
    /// order of their encoded keys (`field_order` `.encoded_key`), and each float in the shortest of
    /// half, single and double precision that keeps its value, with NaN as `0xf97e00`. Integers and
    /// lengths are always written in their shortest form. Asking for another `field_order` is a
    /// compile error.
    deterministic: bool = false,
};

/// Field order of a write with `cfg`: `encoded_key`, and required, when it is deterministic.
pub fn fieldOrderPolicy(comptime cfg: anytype) meta.FieldOrderPolicy {
    if (effectiveDeterministic(cfg)) return .{ .default = .encoded_key, .required = true };
    return .{};
}

fn effectiveDeterministic(comptime cfg: anytype) bool {
    if (comptime meta.hasField(@TypeOf(cfg), "deterministic")) return @field(cfg, "deterministic");
    return false;
}

/// The encoded form of a map key, which RFC 8949 §4.2.1 sorts bytewise: the head of the item, then
/// the bytes of a text key. A text key's encoding sorts shorter keys first, an integer key's sorts
/// by major type and then value, and the two mix as the major types order them.
pub fn encodeKey(comptime key: meta.FieldKey) []const u8 {
    const encoded = comptime blk: {
        var buffer: [
            9 + switch (key) {
                .text => |name| name.len,
                .integer => 0,
            }
        ]u8 = undefined;
        var len: usize = 0;
        switch (key) {
            .text => |name| {
                len = writeHead(&buffer, 3, name.len);
                @memcpy(buffer[len..][0..name.len], name);
                len += name.len;
            },
            .integer => |value| {
                if (value >= 0) {
                    len = writeHead(&buffer, 0, std.math.cast(u64, value) orelse @compileError("integer key out of CBOR range"));
                } else {
                    len = writeHead(&buffer, 1, std.math.cast(u64, -1 - value) orelse @compileError("integer key out of CBOR range"));
                }
            },
        }
        var exact: [len]u8 = undefined;
        @memcpy(&exact, buffer[0..len]);
        break :blk exact;
    };
    return &encoded;
}

/// Writes the shortest head for `major` and `value` into `out` and returns its length.
fn writeHead(out: []u8, major: u8, value: u64) usize {
    const initial = major << 5;
    if (value < 24) {
        out[0] = initial | @as(u8, @intCast(value));
        return 1;
    }
    const width: usize = if (value <= 0xff) 1 else if (value <= 0xffff) 2 else if (value <= 0xffff_ffff) 4 else 8;
    out[0] = initial | @as(u8, switch (width) {
        1 => 24,
        2 => 25,
        4 => 26,
        else => 27,
    });
    var shift: u6 = @intCast((width - 1) * 8);
    for (0..width) |index| {
        out[1 + index] = @truncate(value >> shift);
        shift -%= 8;
    }
    return 1 + width;
}

pub const ParseError = anyerror;

const ContainerKind = enum {
    array,
    object,
};

const Container = struct {
    kind: ContainerKind,
    indefinite: bool,
    remaining: usize,
    /// Where this map's keys start in `keys` and `key_bytes`, so its duplicate check sees its own
    /// keys only and the records are released when it ends.
    keys_base: usize = 0,
    key_bytes_base: usize = 0,
    /// The encoded bytes of the previous key in the input (an empty span for none), which a strict
    /// read compares the next key to.
    prev_key_start: usize = 0,
    prev_key_end: usize = 0,
};

const Header = struct {
    major: u8,
    ai: u8,
    value: u64,
    indefinite: bool,
};

/// What a map key is, for telling whether two keys are the same data item (RFC 8949 §5.6): an
/// integer is not a float with the same value, and a byte string is not a text string.
const KeyKind = enum(u8) { uint, nint, bytes, text, simple, float, raw };

/// One key of an open map. `a` is the integer value, the simple value, the float's bits, or for a
/// string or `raw` key the offset of its bytes (in the input, or in `key_bytes` when `pooled`) with
/// its length in `b`. A key that is an array, map or tagged item is compared by its encoded bytes,
/// so two encodings of one such key are not seen as equal; scalars and strings are compared by value.
/// One entry of a map being put in canonical form: its bytes in `key_bytes`, key first.
const CanonicalEntry = struct { start: usize, key_end: usize, end: usize };

const KeyRecord = struct {
    kind: KeyKind,
    pooled: bool = false,
    a: u64,
    b: u64 = 0,
};

pub fn serializer(writer: *std.Io.Writer, comptime cfg: anytype) CborSerializer(@TypeOf(cfg), effectiveDeterministic(cfg)) {
    return CborSerializer(@TypeOf(cfg), effectiveDeterministic(cfg)).init(writer, cfg);
}

pub fn readerDeserializer(allocator: Allocator, reader: *std.Io.Reader, comptime cfg: anytype) !CborDeserializer(@TypeOf(cfg)) {
    comptime checkLimits(cfg);
    const input = try reader.allocRemaining(allocator, .limited(effectiveMaxInputBytes(cfg)));
    return CborDeserializer(@TypeOf(cfg)).initOwned(allocator, input, cfg);
}

pub fn sliceDeserializer(allocator: Allocator, input: []const u8, comptime cfg: anytype) !CborDeserializer(@TypeOf(cfg)) {
    comptime checkLimits(cfg);
    return CborDeserializer(@TypeOf(cfg)).initBorrowed(allocator, input, cfg);
}

/// `deterministic` is a type parameter, so the default write carries no runtime branch for it.
pub fn CborSerializer(comptime Config: type, comptime deterministic: bool) type {
    return struct {
        writer: *std.Io.Writer,
        cfg: Config,

        const Self = @This();

        /// A tagged union is a one-entry map, and a struct field may have an integer key.
        pub const supports_unions = true;
        pub const supports_integer_keys = true;

        fn init(writer: *std.Io.Writer, cfg: Config) Self {
            return .{
                .writer = writer,
                .cfg = cfg,
            };
        }

        pub fn emitNull(self: *Self) !void {
            _ = self.cfg;
            try self.writer.writeByte(0xf6);
        }

        pub fn emitBool(self: *Self, value: bool) !void {
            try self.writer.writeByte(if (value) 0xf5 else 0xf4);
        }

        pub fn emitInteger(self: *Self, value: anytype) !void {
            try writeInt(self.writer, value);
        }

        pub fn emitFloat(self: *Self, value: anytype) !void {
            if (deterministic) return writePreferredFloat(self.writer, value);
            try writeFloat(self.writer, value);
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            try writeTextString(self.writer, value);
        }

        pub fn emitBytes(self: *Self, value: []const u8) !void {
            try writeMajorValue(self.writer, 2, value.len);
            try self.writer.writeAll(value);
        }

        /// How many entries an extras map holds, for the head of the map it joins.
        pub fn extrasCount(self: *Self, bytes: []const u8) !usize {
            _ = self;
            return @intCast((try extrasHead(bytes)).remaining);
        }

        /// Starts walking an extras map: a definite map as a read leaves it, its keys definite text
        /// in ascending order. The entries are written as they are.
        pub fn beginExtras(self: *Self, bytes: []const u8) !ExtrasCursor {
            _ = self;
            return try extrasHead(bytes);
        }

        /// Writes the entries whose key sorts before `encoded`, the encoded key of the next declared
        /// member, so the whole map stays in key order. An entry with that very key repeats a member.
        pub fn emitExtrasBefore(self: *Self, cursor: *ExtrasCursor, comptime encoded: []const u8) !void {
            while (cursor.remaining > 0) {
                const entry = try extrasEntry(cursor.bytes, cursor.pos);
                const key = cursor.bytes[cursor.pos..entry.key_end];
                switch (std.mem.order(u8, key, encoded)) {
                    .lt => {},
                    .eq => return error.DuplicateField,
                    .gt => return,
                }
                try self.writer.writeAll(cursor.bytes[cursor.pos..entry.end]);
                cursor.pos = entry.end;
                cursor.remaining -= 1;
            }
        }

        /// Writes the entries left. None may repeat a declared member.
        pub fn finishExtras(self: *Self, cursor: *ExtrasCursor, comptime declared: []const meta.FieldKey) !void {
            while (cursor.remaining > 0) {
                const entry = try extrasEntry(cursor.bytes, cursor.pos);
                const key = cursor.bytes[cursor.pos..entry.key_end];
                inline for (declared) |member| {
                    if (std.mem.eql(u8, key, comptime encodeKey(member))) return error.DuplicateField;
                }
                try self.writer.writeAll(cursor.bytes[cursor.pos..entry.end]);
                cursor.pos = entry.end;
                cursor.remaining -= 1;
            }
        }

        /// A streaming writer for a wire type's encode hook; see `Encoder`.
        pub fn encoder(self: *Self) Encoder {
            return .{ .writer = self.writer, .deterministic = deterministic };
        }

        /// Writes an item that was read as `zerde.Raw`, unchanged.
        pub fn emitRaw(self: *Self, value: []const u8) !void {
            try self.writer.writeAll(value);
        }

        pub fn emitEnum(self: *Self, comptime _: type, value: anytype) !void {
            try writeTextString(self.writer, @tagName(value));
        }

        /// A deterministic map states its length; any other map is indefinite, which keeps the
        /// default encoding byte-identical to earlier releases.
        pub fn beginStructSized(self: *Self, comptime T: type, field_count: usize) !void {
            _ = T;
            if (deterministic) {
                try writeMajorValue(self.writer, 5, field_count);
            } else {
                try self.writer.writeByte(0xbf);
            }
        }

        pub fn structPassCount(comptime T: type) usize {
            _ = T;
            return 1;
        }

        pub fn includeStructField(comptime Parent: type, comptime FieldType: type, comptime pass: usize) bool {
            _ = Parent;
            _ = FieldType;
            _ = pass;
            return true;
        }

        pub fn beginStructField(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type) !bool {
            _ = Parent;
            _ = FieldType;
            try writeTextString(self.writer, name);
            return true;
        }

        pub fn beginStructFieldInteger(self: *Self, comptime Parent: type, comptime key: i128, comptime FieldType: type) !bool {
            _ = Parent;
            _ = FieldType;
            try writeInt(self.writer, key);
            return true;
        }

        pub fn endStructField(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type) !void {
            _ = self;
            _ = Parent;
            _ = name;
            _ = FieldType;
        }

        pub fn endStruct(self: *Self, comptime T: type) !void {
            _ = T;
            if (!deterministic) try self.writer.writeByte(0xff);
        }

        pub fn beginArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            try writeMajorValue(self.writer, 4, len);
        }

        pub fn beginArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = self;
            _ = Child;
            _ = index;
        }

        pub fn endArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = self;
            _ = Child;
            _ = index;
        }

        pub fn endArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = self;
            _ = Child;
            _ = len;
        }
    };
}

pub fn CborDeserializer(comptime Config: type) type {
    return struct {
        input: []const u8,
        cfg: Config,
        allocator: Allocator,
        index: usize = 0,
        owns_input: bool,
        can_borrow_strings: bool,
        strict: bool = false,
        max_depth: usize = max_nesting,
        max_items: usize = std.math.maxInt(usize),
        max_string_len: usize = std.math.maxInt(usize),
        items: usize = 0,
        /// The span of the last key that matched no field, for `unknownKey`.
        last_key: [2]usize = .{ 0, 0 },
        /// Members collected for an extras field, innermost struct last; see `captureExtra`.
        extras: std.ArrayList(ExtraEntry) = .empty,
        extra_keys: std.ArrayList(u8) = .empty,
        stack: [max_nesting]Container = undefined,
        stack_len: usize = 0,
        /// Keys of the maps being read, innermost last, for the duplicate check.
        keys: std.ArrayList(KeyRecord) = .empty,
        /// The bytes of keys that are not contiguous in the input (indefinite-length strings).
        key_bytes: std.ArrayList(u8) = .empty,

        const Self = @This();

        pub const supports_unions = true;
        pub const supports_integer_keys = true;

        fn initBorrowed(allocator: Allocator, input: []const u8, cfg: Config) Self {
            return .{
                .input = input,
                .cfg = cfg,
                .allocator = allocator,
                .owns_input = false,
                .can_borrow_strings = effectiveBorrowStrings(cfg),
                .strict = readOption(cfg, "mode", Mode.lenient) == .strict,
                .max_depth = limit(cfg, "max_depth", max_nesting),
                .max_items = limit(cfg, "max_items", std.math.maxInt(usize)),
                .max_string_len = limit(cfg, "max_string_len", std.math.maxInt(usize)),
            };
        }

        fn initOwned(allocator: Allocator, input: []const u8, cfg: Config) Self {
            return .{
                .input = input,
                .cfg = cfg,
                .allocator = allocator,
                .owns_input = true,
                .can_borrow_strings = false,
                .strict = readOption(cfg, "mode", Mode.lenient) == .strict,
                .max_depth = limit(cfg, "max_depth", max_nesting),
                .max_items = limit(cfg, "max_items", std.math.maxInt(usize)),
                .max_string_len = limit(cfg, "max_string_len", std.math.maxInt(usize)),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.keys.deinit(allocator);
            self.key_bytes.deinit(allocator);
            self.extras.deinit(allocator);
            self.extra_keys.deinit(allocator);
            if (self.owns_input) allocator.free(@constCast(self.input));
        }

        pub fn finish(self: *Self) !void {
            _ = self.cfg;
            if (self.index != self.input.len) return error.TrailingCharacters;
        }

        pub fn borrowStrings(self: *Self) bool {
            return self.can_borrow_strings;
        }

        pub fn errorOffset(self: *Self) usize {
            return self.index;
        }

        pub fn peekKind(self: *Self) !ValueKind {
            const header = try self.peekHeader();
            return switch (header.major) {
                0, 1 => .number,
                2 => .bytes,
                3 => .string,
                4 => .array,
                5 => .object,
                7 => switch (header.ai) {
                    20, 21 => .bool,
                    22 => .null,
                    25, 26, 27 => .number,
                    else => error.UnexpectedToken,
                },
                else => error.UnexpectedToken,
            };
        }

        pub fn readNull(self: *Self) !void {
            const header = try self.readHeader();
            if (header.major != 7) return error.UnexpectedType;
            if (header.ai != 22) return error.UnexpectedType;
        }

        pub fn readBool(self: *Self) !bool {
            const header = try self.readHeader();
            if (header.major != 7) return error.UnexpectedType;
            return switch (header.ai) {
                20 => false,
                21 => true,
                else => error.UnexpectedType,
            };
        }

        /// A float of any width is `.float`, a NaN or an infinity included: RFC 8949 §3.3 makes
        /// them values like any other, and a typed float field takes them. An integer field takes
        /// `.integer` only (see `typed.zig`).
        pub fn readNumber(self: *Self) !Number {
            const header = try self.readHeader();
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

        /// A text string, definite or in chunks. Only a text string: a byte string is
        /// `error.UnexpectedType`, whatever it holds.
        pub fn readString(self: *Self, allocator: Allocator) !StringToken {
            const header = try self.readHeader();
            if (header.major != 3) return error.UnexpectedType;
            return self.finishString(allocator, header);
        }

        /// A byte string, definite or in chunks, and nothing else.
        pub fn readBytes(self: *Self, allocator: Allocator) !StringToken {
            const header = try self.readHeader();
            if (header.major != 2) return error.UnexpectedType;
            return self.finishString(allocator, header);
        }

        pub fn readByteToken(self: *Self, allocator: Allocator) !StringToken {
            return self.readBytes(allocator);
        }

        /// `readString` for a field with a `max_len`: a string longer than `max` is refused as it
        /// is read, so chunks are not joined into memory the bound exists to deny.
        pub fn readStringMax(self: *Self, allocator: Allocator, max: usize) !StringToken {
            const saved = self.max_string_len;
            defer self.max_string_len = saved;
            if (max < saved) self.max_string_len = max;
            return self.readString(allocator) catch |err| if (err == error.StringTooLong and max < saved) error.LengthOutOfBounds else err;
        }

        /// `readByteToken` for a field with a `max_len`; see `readStringMax`.
        pub fn readByteTokenMax(self: *Self, allocator: Allocator, max: usize) !StringToken {
            const saved = self.max_string_len;
            defer self.max_string_len = saved;
            if (max < saved) self.max_string_len = max;
            return self.readBytes(allocator) catch |err| if (err == error.StringTooLong and max < saved) error.LengthOutOfBounds else err;
        }

        /// The next item as the bytes it was read from, checked as the mode and limits say. A
        /// strict read refuses a non-deterministic item here too; a lenient one takes any well-formed
        /// item, tags included.
        pub fn readRaw(self: *Self, allocator: Allocator) !StringToken {
            _ = allocator;
            const start = self.index;
            try self.skipItem(self.stack_len);
            return .{ .bytes = self.input[start..self.index], .allocated = false };
        }

        pub fn beginArray(self: *Self) !void {
            _ = try self.beginArrayLen();
        }

        pub fn beginArrayLen(self: *Self) !?usize {
            const header = try self.readHeader();
            if (header.major != 4) return error.UnexpectedType;
            const len: ?usize = if (header.indefinite) null else try self.boundedCount(header.value, 1);
            try self.push(.{
                .kind = .array,
                .indefinite = header.indefinite,
                .remaining = len orelse 0,
            });
            return len;
        }

        pub fn nextArrayItem(self: *Self) !bool {
            const frame = self.current();
            if (frame.kind != .array) return error.InvalidCborState;

            if (frame.indefinite) {
                if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
                if (self.input[self.index] == 0xff) {
                    self.index += 1;
                    _ = self.pop();
                    return false;
                }
                return true;
            }

            if (frame.remaining == 0) {
                _ = self.pop();
                return false;
            }

            frame.remaining -= 1;
            return true;
        }

        pub fn finishKnownLenArray(self: *Self) !void {
            const frame = self.current();
            if (frame.kind != .array) return error.InvalidCborState;
            if (frame.indefinite) return error.InvalidCborState;
            _ = self.pop();
        }

        pub fn beginObject(self: *Self) !void {
            const header = try self.readHeader();
            if (header.major != 5) return error.UnexpectedType;
            try self.push(.{
                .kind = .object,
                .indefinite = header.indefinite,
                .remaining = if (header.indefinite) 0 else try self.boundedCount(header.value, 2),
                .keys_base = self.keys.items.len,
                .key_bytes_base = self.key_bytes.items.len,
            });
        }

        /// The next key of a map whose keys are text, which is what a dynamic `Value` and a union
        /// hold. A key of another type is `error.UnexpectedType`; a repeated key is `error.DuplicateField`
        /// when the map ends.
        pub fn nextObjectField(self: *Self, allocator: Allocator) !?StringToken {
            if (try self.beginObjectEntry()) return null;

            const start = self.index;
            const header = try self.readHeader();
            if (header.major != 3) return error.UnexpectedType;
            const token = try self.finishString(allocator, header);
            errdefer token.deinit(allocator);
            try self.orderFrameKey(start);
            try self.recordText(token);
            return token;
        }

        /// The next key of a map whose keys are text or integers, which is what a union with integer
        /// variant keys holds. A key of another type is `error.UnexpectedType`.
        pub fn nextObjectKey(self: *Self, allocator: Allocator) !?typed.ObjectKey {
            if (try self.beginObjectEntry()) return null;

            const start = self.index;
            const header = try self.readHeader();
            switch (header.major) {
                3 => {
                    const token = try self.finishString(allocator, header);
                    errdefer token.deinit(allocator);
                    try self.orderFrameKey(start);
                    try self.recordText(token);
                    return .{ .text = token };
                },
                0, 1 => {
                    try self.orderFrameKey(start);
                    try self.keys.append(self.allocator, .{ .kind = if (header.major == 0) .uint else .nint, .a = header.value });
                    return .{ .integer = if (header.major == 0) header.value else -@as(i128, header.value) - 1 };
                },
                else => return error.UnexpectedType,
            }
        }

        /// The next key of a struct's map, matched to one of `T`'s fields by its text or integer
        /// key. Any other key, of any type, is `.unknown` and is checked for repeats.
        ///
        /// A key that names a field is not recorded: the typed layer refuses a field named twice,
        /// so only the keys it cannot see need the duplicate check.
        pub fn nextObjectFieldIndex(self: *Self, comptime T: type, comptime cfg: anytype) !ObjectFieldLookup {
            if (try self.beginObjectEntry()) return .end;

            const frame = self.current();
            const start = self.index;
            const result = try self.lookupKey(T, cfg, start);
            if (result == .unknown) self.last_key = .{ start, self.index };
            var previous: [2]usize = .{ frame.prev_key_start, frame.prev_key_end };
            try self.checkKeyOrder(&previous, start);
            frame.prev_key_start = previous[0];
            frame.prev_key_end = previous[1];
            return result;
        }

        fn lookupKey(self: *Self, comptime T: type, comptime cfg: anytype, start: usize) !ObjectFieldLookup {
            const header = try self.nextHead();
            switch (header.major) {
                3 => {
                    if (!header.indefinite) {
                        // A field name the type declares is UTF-8 already, so a key that matches one needs no
                        // validation; any other key is checked before it is recorded.
                        if (header.value > self.max_string_len) return error.StringTooLong;
                        const raw = try self.takeBytes(header.value);
                        if (typed.matchStructFieldIndex(T, cfg, raw)) |index| return .{ .field_index = index };
                        if (!bulk.validUtf8(raw)) return error.InvalidUtf8;
                        try self.recordText(.{ .bytes = raw, .allocated = false });
                        return .unknown;
                    }
                    const token = try self.finishString(self.allocator, header);
                    defer token.deinit(self.allocator);
                    if (typed.matchStructFieldIndex(T, cfg, token.bytes)) |index| return .{ .field_index = index };
                    try self.recordText(token);
                    return .unknown;
                },
                0, 1 => {
                    const value: i128 = if (header.major == 0) header.value else -@as(i128, header.value) - 1;
                    if (typed.matchStructFieldIndexInteger(T, cfg, value)) |index| return .{ .field_index = index };
                    try self.keys.append(self.allocator, .{ .kind = if (header.major == 0) .uint else .nint, .a = header.value });
                    return .unknown;
                },
                else => {
                    self.index = start;
                    self.items -= 1;
                    try self.recordKeyItem(self.stack_len);
                    return .unknown;
                },
            }
        }

        /// The text of the key that `nextObjectFieldIndex` just reported as unknown. A key of another
        /// type is `error.UnexpectedType`: extras are text-keyed.
        pub fn unknownKey(self: *Self, allocator: Allocator) !StringToken {
            const saved = self.index;
            defer self.index = saved;
            self.index = self.last_key[0];
            const header = try parseHeader(self.input, &self.index);
            if (header.major != 3) return error.UnexpectedType;
            return self.finishString(allocator, header);
        }

        /// A reader of the next item of this read, for a wire type's decode hook.
        pub fn pullView(self: *Self, allocator: Allocator) PullReader(Config) {
            return PullReader(Config).view(self, allocator);
        }

        /// Where the extras of a struct begin, so a struct read inside another keeps its own.
        pub fn extrasMark(self: *Self) usize {
            return self.extras.items.len;
        }

        /// Takes the member whose value is next: `key` is its text, and the value is checked and kept
        /// as the bytes it was read from.
        pub fn captureExtra(self: *Self, allocator: Allocator, key: []const u8) !void {
            const start = self.index;
            try self.skipItem(self.stack_len);
            const key_start = self.extra_keys.items.len;
            try self.extra_keys.appendSlice(allocator, key);
            try self.extras.append(allocator, .{ .key_start = key_start, .key_len = key.len, .value_start = start, .value_end = self.index });
        }

        /// Ends the extras since `mark` as one definite map, its keys in ascending order of their
        /// encoded form and each value as it was read, owned by the caller. With none it is null, or an
        /// empty map when `want_empty`.
        pub fn finishExtras(self: *Self, allocator: Allocator, mark: usize, want_empty: bool) !?[]u8 {
            const entries = self.extras.items[mark..];
            defer {
                if (entries.len != 0) self.extra_keys.items.len = entries[0].key_start;
                self.extras.items.len = mark;
            }
            if (entries.len == 0 and !want_empty) return null;
            std.sort.pdq(ExtraEntry, entries, self, extraLessThan);

            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            var head: [9]u8 = undefined;
            try out.appendSlice(allocator, head[0..writeHead(&head, 5, entries.len)]);
            for (entries) |entry| {
                try out.appendSlice(allocator, head[0..writeHead(&head, 3, entry.key_len)]);
                try out.appendSlice(allocator, self.extra_keys.items[entry.key_start..][0..entry.key_len]);
                try out.appendSlice(allocator, self.input[entry.value_start..entry.value_end]);
            }
            return try out.toOwnedSlice(allocator);
        }

        fn extraLessThan(self: *Self, a: ExtraEntry, b: ExtraEntry) bool {
            const x = self.extra_keys.items[a.key_start..][0..a.key_len];
            const y = self.extra_keys.items[b.key_start..][0..b.key_len];
            if (x.len != y.len) return x.len < y.len;
            return std.mem.lessThan(u8, x, y);
        }

        pub fn skipValue(self: *Self, allocator: Allocator) !void {
            _ = allocator;
            try self.skipItem(self.stack_len);
        }

        /// Consumes the break or counts down the entry before the next key. True when the map has ended.
        fn beginObjectEntry(self: *Self) !bool {
            const frame = self.current();
            if (frame.kind != .object) return error.InvalidCborState;

            if (frame.indefinite) {
                if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
                if (self.input[self.index] != 0xff) return false;
                self.index += 1;
            } else {
                if (frame.remaining != 0) {
                    frame.remaining -= 1;
                    return false;
                }
            }

            const finished = self.pop();
            try self.endKeys(finished.keys_base, finished.key_bytes_base);
            return true;
        }

        /// Reads one head, counts it against `max_items`, and in a strict read refuses what the
        /// deterministic encoding does not allow.
        fn nextHead(self: *Self) !Header {
            const header = try parseHeader(self.input, &self.index);
            self.items += 1;
            if (self.items > self.max_items) return error.TooManyItems;
            if (self.strict) {
                if (header.major == 6) return error.UnexpectedTag;
                if (header.indefinite or !isShortestHead(header)) return error.NonDeterministicEncoding;
                if (header.major == 7 and !isPreferredFloat(header)) return error.NonDeterministicEncoding;
            }
            return header;
        }

        /// A header with any self-described tag read through. Another tag is not a value the typed
        /// layer can read: it would be dropped without anyone having agreed what it meant. A strict
        /// read refuses every tag when it reads the head.
        fn peekHeader(self: *Self) !Header {
            var cursor = self.index;
            while (true) {
                const header = try parseHeader(self.input, &cursor);
                if (header.major != 6) return header;
                if (header.value != self_described_tag) return error.UnexpectedTag;
            }
        }

        fn readHeader(self: *Self) !Header {
            while (true) {
                const header = try self.nextHead();
                if (header.major != 6) return header;
                if (header.value != self_described_tag) return error.UnexpectedTag;
            }
        }

        /// A length that claims more items than the input has bytes left, at `per_item` bytes
        /// each at least, cannot be well-formed. Refusing it here keeps a nine-byte header from
        /// asking the allocator for the whole address space.
        fn boundedCount(self: *Self, count: u64, per_item: usize) !usize {
            const available = (self.input.len - self.index) / per_item;
            if (count > available) return error.UnexpectedEndOfInput;
            return @intCast(count);
        }

        fn takeBytes(self: *Self, len: u64) ![]const u8 {
            if (len > self.input.len - self.index) return error.UnexpectedEndOfInput;
            const raw = self.input[self.index..][0..@intCast(len)];
            self.index += raw.len;
            return raw;
        }

        /// The content of the string whose head is `header`: borrowed from the input when it is
        /// one definite chunk, else assembled from the chunks of an indefinite one. Each chunk of an
        /// indefinite string is a definite string of the same type (RFC 8949 §3.2.3), and a text
        /// chunk is valid UTF-8 on its own, so a code point cannot straddle two chunks.
        fn finishString(self: *Self, allocator: Allocator, header: Header) !StringToken {
            const is_text = header.major == 3;
            if (!header.indefinite) {
                if (header.value > self.max_string_len) return error.StringTooLong;
                const raw = try self.takeBytes(header.value);
                if (is_text and !bulk.validUtf8(raw)) return error.InvalidUtf8;
                return .{ .bytes = raw, .allocated = false };
            }

            var assembled: std.ArrayList(u8) = .empty;
            errdefer assembled.deinit(allocator);
            while (true) {
                if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
                if (self.input[self.index] == 0xff) {
                    self.index += 1;
                    break;
                }
                const chunk = try parseHeader(self.input, &self.index);
                if (chunk.major != header.major or chunk.indefinite) return error.InvalidStringChunk;
                if (chunk.value > self.max_string_len - assembled.items.len) return error.StringTooLong;
                const raw = try self.takeBytes(chunk.value);
                if (is_text and !bulk.validUtf8(raw)) return error.InvalidUtf8;
                try assembled.appendSlice(allocator, raw);
            }
            return .{ .bytes = try assembled.toOwnedSlice(allocator), .allocated = true };
        }

        /// Skips one data item, checking that it is well-formed and that every map in it has
        /// distinct keys. `depth` is how many containers are open around it.
        fn skipItem(self: *Self, depth: usize) anyerror!void {
            var header = try self.nextHead();
            // A tag adds no nesting of its own, so a run of tags is a loop, not recursion.
            while (header.major == 6) header = try self.nextHead();

            switch (header.major) {
                0, 1 => {},
                7 => try self.checkFloat(header),
                2, 3 => {
                    const token = try self.finishString(self.allocator, header);
                    token.deinit(self.allocator);
                },
                4 => {
                    if (depth >= self.max_depth) return error.CborNestingTooDeep;
                    if (header.indefinite) {
                        while (try self.moreItems()) try self.skipItem(depth + 1);
                    } else {
                        for (0..try self.boundedCount(header.value, 1)) |_| try self.skipItem(depth + 1);
                    }
                },
                5 => {
                    if (depth >= self.max_depth) return error.CborNestingTooDeep;
                    const keys_base = self.keys.items.len;
                    const key_bytes_base = self.key_bytes.items.len;
                    var previous: [2]usize = .{ 0, 0 };
                    if (header.indefinite) {
                        // A strict read has refused an indefinite map already, so no order to check.
                        while (try self.moreItems()) {
                            try self.recordKeyItem(depth + 1);
                            try self.skipItem(depth + 1);
                        }
                    } else {
                        for (0..try self.boundedCount(header.value, 2)) |_| {
                            const key_start = self.index;
                            try self.recordKeyItem(depth + 1);
                            try self.checkKeyOrder(&previous, key_start);
                            try self.skipItem(depth + 1);
                        }
                    }
                    try self.endKeys(keys_base, key_bytes_base);
                },
                else => return error.UnexpectedToken,
            }
        }

        /// Refuses a NaN or an infinity when the config says to: the exponent field is all ones.
        fn checkFloat(self: *Self, header: Header) !void {
            if (comptime !meta.hasField(Config, "refuse_non_finite")) return;
            if (!self.cfg.refuse_non_finite or header.major != 7) return;
            const exponent_all_ones = switch (header.ai) {
                25 => (header.value >> 10) & 0x1f == 0x1f,
                26 => (header.value >> 23) & 0xff == 0xff,
                27 => (header.value >> 52) & 0x7ff == 0x7ff,
                else => false,
            };
            if (exponent_all_ones) return error.NonFiniteFloat;
        }

        /// A strict read needs each key of a map to sort after the one before it by its encoded bytes
        /// (RFC 8949 §4.2.1), which also rules out a repeated key. `previous` is the span of the last key.
        fn checkKeyOrder(self: *Self, previous: *[2]usize, start: usize) !void {
            if (!self.strict) return;
            const key = self.input[start..self.index];
            if (previous[1] != 0) {
                const before = self.input[previous[0]..previous[1]];
                if (std.mem.eql(u8, before, key)) return error.DuplicateField;
                if (!std.mem.lessThan(u8, before, key)) return error.NonDeterministicEncoding;
            }
            previous.* = .{ start, self.index };
        }

        fn orderFrameKey(self: *Self, start: usize) !void {
            const frame = self.current();
            var previous: [2]usize = .{ frame.prev_key_start, frame.prev_key_end };
            try self.checkKeyOrder(&previous, start);
            frame.prev_key_start = previous[0];
            frame.prev_key_end = previous[1];
        }

        /// Whether an indefinite-length container has another item, consuming its break if not.
        fn moreItems(self: *Self) !bool {
            if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
            if (self.input[self.index] != 0xff) return true;
            self.index += 1;
            return false;
        }

        /// Reads one map key of any type and records it. A key that is an array, map or tagged item
        /// is skipped, which checks the maps inside it too, then recorded in canonical form so two
        /// spellings of one key are the same key.
        fn recordKeyItem(self: *Self, depth: usize) anyerror!void {
            const start = self.index;
            const header = try self.nextHead();
            try self.checkFloat(header);
            const record: KeyRecord = switch (header.major) {
                0 => .{ .kind = .uint, .a = header.value },
                1 => .{ .kind = .nint, .a = header.value },
                2, 3 => {
                    const token = try self.finishString(self.allocator, header);
                    defer token.deinit(self.allocator);
                    return self.recordString(if (header.major == 3) .text else .bytes, token);
                },
                7 => switch (header.ai) {
                    25, 26, 27 => .{ .kind = .float, .a = keyFloatBits(header.ai, header.value) },
                    else => .{ .kind = .simple, .a = if (header.ai == 24) header.value else header.ai },
                },
                else => blk: {
                    // skipItem reads the head again and counts it again.
                    self.index = start;
                    self.items -= 1;
                    try self.skipItem(depth);
                    const end = self.index;
                    self.index = start;
                    const offset = self.key_bytes.items.len;
                    try self.canonicalItem();
                    std.debug.assert(self.index == end);
                    break :blk .{ .kind = .raw, .pooled = true, .a = offset, .b = self.key_bytes.items.len - offset };
                },
            };
            try self.keys.append(self.allocator, record);
        }

        /// Appends the canonical form of the well-formed item at `index` to `key_bytes`: shortest
        /// heads, definite lengths, every float as a double with RFC 8949 section 5.6.1 equality
        /// (zeros equal, NaNs by significand), and map entries sorted by their canonical keys.
        /// `skipItem` has already bounded the nesting and refused repeated keys.
        fn canonicalItem(self: *Self) anyerror!void {
            const header = try parseHeader(self.input, &self.index);
            switch (header.major) {
                0, 1 => try self.appendHead(header.major, header.value),
                2, 3 => {
                    const token = try self.finishString(self.allocator, header);
                    defer token.deinit(self.allocator);
                    try self.appendHead(header.major, token.bytes.len);
                    try self.key_bytes.appendSlice(self.allocator, token.bytes);
                },
                4 => {
                    const start = self.key_bytes.items.len;
                    var count: u64 = 0;
                    if (header.indefinite) {
                        while (try self.moreItems()) : (count += 1) try self.canonicalItem();
                    } else {
                        while (count < header.value) : (count += 1) try self.canonicalItem();
                    }
                    try self.insertHead(start, 4, count);
                },
                5 => try self.canonicalMap(header),
                6 => {
                    try self.appendHead(6, header.value);
                    try self.canonicalItem();
                },
                else => switch (header.ai) {
                    25, 26, 27 => {
                        try self.key_bytes.append(self.allocator, 0xfb);
                        var be: [8]u8 = undefined;
                        std.mem.writeInt(u64, &be, keyFloatBits(header.ai, header.value), .big);
                        try self.key_bytes.appendSlice(self.allocator, &be);
                    },
                    else => try self.appendHead(7, header.value),
                },
            }
        }

        fn canonicalMap(self: *Self, header: Header) anyerror!void {
            var entries: std.ArrayList(CanonicalEntry) = .empty;
            defer entries.deinit(self.allocator);
            const start = self.key_bytes.items.len;
            if (header.indefinite) {
                while (try self.moreItems()) try self.canonicalEntry(&entries);
            } else {
                var count: u64 = 0;
                while (count < header.value) : (count += 1) try self.canonicalEntry(&entries);
            }

            const Sort = struct {
                bytes: []const u8,
                fn less(ctx: @This(), a: CanonicalEntry, b: CanonicalEntry) bool {
                    return std.mem.lessThan(u8, ctx.bytes[a.start..a.key_end], ctx.bytes[b.start..b.key_end]);
                }
            };
            std.sort.pdq(CanonicalEntry, entries.items, Sort{ .bytes = self.key_bytes.items }, Sort.less);

            var sorted: std.ArrayList(u8) = .empty;
            defer sorted.deinit(self.allocator);
            for (entries.items) |entry| try sorted.appendSlice(self.allocator, self.key_bytes.items[entry.start..entry.end]);
            self.key_bytes.items.len = start;
            try self.appendHead(5, entries.items.len);
            try self.key_bytes.appendSlice(self.allocator, sorted.items);
        }

        fn canonicalEntry(self: *Self, entries: *std.ArrayList(CanonicalEntry)) anyerror!void {
            const start = self.key_bytes.items.len;
            try self.canonicalItem();
            const key_end = self.key_bytes.items.len;
            try self.canonicalItem();
            try entries.append(self.allocator, .{ .start = start, .key_end = key_end, .end = self.key_bytes.items.len });
        }

        fn appendHead(self: *Self, major: u8, value: u64) !void {
            var head: [9]u8 = undefined;
            try self.key_bytes.appendSlice(self.allocator, head[0..writeHead(&head, major, value)]);
        }

        fn insertHead(self: *Self, at: usize, major: u8, value: u64) !void {
            var head: [9]u8 = undefined;
            try self.key_bytes.insertSlice(self.allocator, at, head[0..writeHead(&head, major, value)]);
        }

        fn recordText(self: *Self, token: StringToken) !void {
            try self.recordString(.text, token);
        }

        fn recordString(self: *Self, kind: KeyKind, token: StringToken) !void {
            if (!token.allocated) {
                const offset = @intFromPtr(token.bytes.ptr) - @intFromPtr(self.input.ptr);
                try self.keys.append(self.allocator, .{ .kind = kind, .a = offset, .b = token.bytes.len });
                return;
            }
            // The caller frees the token, so keep the bytes the check will compare.
            const offset = self.key_bytes.items.len;
            try self.key_bytes.appendSlice(self.allocator, token.bytes);
            try self.keys.append(self.allocator, .{ .kind = kind, .pooled = true, .a = offset, .b = token.bytes.len });
        }

        /// Ends a map's keys: refuses a repeated one, then drops the map's records.
        fn endKeys(self: *Self, keys_base: usize, key_bytes_base: usize) !void {
            const own = self.keys.items[keys_base..];
            if (own.len >= 2) {
                std.sort.pdq(KeyRecord, own, self, keyLessThan);
                for (own[1..], 0..) |record, previous| {
                    if (self.keyOrder(own[previous], record) == .eq) return error.DuplicateField;
                }
            }
            self.keys.items.len = keys_base;
            self.key_bytes.items.len = key_bytes_base;
        }

        fn keyLessThan(self: *Self, a: KeyRecord, b: KeyRecord) bool {
            return self.keyOrder(a, b) == .lt;
        }

        fn keyOrder(self: *const Self, a: KeyRecord, b: KeyRecord) std.math.Order {
            if (a.kind != b.kind) return std.math.order(@backingInt(a.kind), @backingInt(b.kind));
            switch (a.kind) {
                .uint, .nint, .simple, .float => return std.math.order(a.a, b.a),
                .bytes, .text, .raw => return std.mem.order(u8, self.keyBytes(a), self.keyBytes(b)),
            }
        }

        fn keyBytes(self: *const Self, record: KeyRecord) []const u8 {
            const source = if (record.pooled) self.key_bytes.items else self.input;
            return source[@intCast(record.a)..][0..@intCast(record.b)];
        }

        fn push(self: *Self, container: Container) !void {
            if (self.stack_len >= self.max_depth) return error.CborNestingTooDeep;
            self.stack[self.stack_len] = container;
            self.stack_len += 1;
        }

        fn pop(self: *Self) Container {
            self.stack_len -= 1;
            return self.stack[self.stack_len];
        }

        fn current(self: *Self) *Container {
            return &self.stack[self.stack_len - 1];
        }
    };
}

/// The bits that stand for a float key, widened to a double. RFC 8949 section 5.6.1: two floats are
/// the same key when they are numerically equal, so -0.0 is 0.0, and two NaNs are the same key when
/// they have the same significand after zero-extension to 64 bits (their sign is not compared).
fn keyFloatBits(ai: u8, value: u64) u64 {
    const sig_bits: u6 = switch (ai) {
        25 => 10,
        26 => 23,
        else => 52,
    };
    const exp_bits: u6 = switch (ai) {
        25 => 5,
        26 => 8,
        else => 11,
    };
    const significand = value & ((@as(u64, 1) << sig_bits) - 1);
    const exponent = (value >> sig_bits) & ((@as(u64, 1) << exp_bits) - 1);
    if (exponent == (@as(u64, 1) << exp_bits) - 1 and significand != 0) {
        return (@as(u64, 0x7ff) << 52) | (significand << (52 - sig_bits));
    }
    const wide: f64 = switch (ai) {
        25 => @floatCast(@as(f16, @bitCast(@as(u16, @intCast(value))))),
        26 => @floatCast(@as(f32, @bitCast(@as(u32, @intCast(value))))),
        else => @bitCast(value),
    };
    return if (wide == 0) 0 else @bitCast(wide);
}

/// One member collected for an extras field: its key in `extra_keys`, its value in the input.
const ExtraEntry = struct { key_start: usize, key_len: usize, value_start: usize, value_end: usize };

/// Where the writer is in an extras map: a definite map as a read leaves it.
pub const ExtrasCursor = struct {
    bytes: []const u8,
    pos: usize,
    remaining: u64,
};

fn extrasHead(bytes: []const u8) !ExtrasCursor {
    if (bytes.len == 0) return .{ .bytes = bytes, .pos = 0, .remaining = 0 };
    var index: usize = 0;
    const header = try parseHeader(bytes, &index);
    if (header.major != 5 or header.indefinite) return error.UnexpectedType;
    return .{ .bytes = bytes, .pos = index, .remaining = header.value };
}

/// Where the entry at `pos` of an extras map ends, and where its key does.
fn extrasEntry(bytes: []const u8, pos: usize) !struct { key_end: usize, end: usize } {
    var index = pos;
    try skipTrusted(bytes, &index, 0);
    const key_end = index;
    try skipTrusted(bytes, &index, 0);
    return .{ .key_end = key_end, .end = index };
}

/// Steps over one item that is already known to be well-formed, without validating it again.
/// A malformed or too deeply nested item is an error, not a trap.
fn skipTrusted(input: []const u8, index: *usize, depth: usize) !void {
    if (depth > max_nesting) return error.CborNestingTooDeep;
    var header = try parseHeader(input, index);
    while (header.major == 6) header = try parseHeader(input, index);
    switch (header.major) {
        0, 1, 7 => {},
        2, 3 => {
            if (header.indefinite) {
                while (true) {
                    if (index.* >= input.len) return error.UnexpectedEndOfInput;
                    if (input[index.*] == 0xff) {
                        index.* += 1;
                        break;
                    }
                    const chunk = try parseHeader(input, index);
                    if (chunk.value > input.len - index.*) return error.UnexpectedEndOfInput;
                    index.* += @intCast(chunk.value);
                }
            } else {
                if (header.value > input.len - index.*) return error.UnexpectedEndOfInput;
                index.* += @intCast(header.value);
            }
        },
        else => {
            const per: u64 = if (header.major == 5) 2 else 1;
            if (header.indefinite) {
                while (true) {
                    if (index.* >= input.len) return error.UnexpectedEndOfInput;
                    if (input[index.*] == 0xff) {
                        index.* += 1;
                        break;
                    }
                    var step: u64 = 0;
                    while (step < per) : (step += 1) try skipTrusted(input, index, depth + 1);
                }
            } else {
                if (header.value > input.len - index.*) return error.UnexpectedEndOfInput;
                var count: u64 = 0;
                while (count < header.value * per) : (count += 1) try skipTrusted(input, index, depth + 1);
            }
        },
    }
}

/// A pull reader over a CBOR input: `next` returns the events of one item in order, for a shape
/// that is only known while reading. It checks what a typed read does, as the mode and limits say,
/// including ascending keys in a strict read and no repeated key in a map. A map's keys must be
/// scalars (`error.UnexpectedType` for an array or map key). Text and byte strings borrow the input
/// unless they were in chunks, and are valid until the next call. The input must outlive the reader.
pub fn pullReader(allocator: Allocator, input: []const u8, comptime cfg: anytype) !PullReader(@TypeOf(cfg)) {
    comptime checkLimits(cfg);
    return PullReader(@TypeOf(cfg)).init(allocator, input, cfg);
}

pub fn PullReader(comptime Config: type) type {
    return struct {
        d: *CborDeserializer(Config),
        /// Whether this reader made `d` and frees it. A reader over a typed read's deserializer (a
        /// wire type's decode hook) does not.
        owns: bool,
        /// The depth the item starts at: the reader is done when it is back there.
        base: usize,
        allocator: Allocator,
        scratch: ?[]u8 = null,
        done: bool = false,
        /// Whether a map frame, by depth, has read a key and expects its value.
        want_value: [max_nesting]bool = @splat(false),

        const Self = @This();

        fn init(allocator: Allocator, input: []const u8, cfg: Config) !Self {
            const d = try allocator.create(CborDeserializer(Config));
            d.* = CborDeserializer(Config).initBorrowed(allocator, input, cfg);
            return .{ .d = d, .owns = true, .base = 0, .allocator = allocator };
        }

        /// A reader of the next item of a deserializer that is already reading.
        pub fn view(d: *CborDeserializer(Config), allocator: Allocator) Self {
            return .{ .d = d, .owns = false, .base = d.stack_len, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.release();
            if (self.owns) {
                self.d.deinit(self.allocator);
                self.allocator.destroy(self.d);
            }
        }

        /// The next event, or null after the item is complete.
        pub fn next(self: *Self) !?typed.Event {
            self.release();
            const d = self.d;
            if (d.stack_len == self.base) {
                if (self.done) return null;
                const event = try self.valueEvent();
                if (d.stack_len == self.base) self.done = true;
                return event;
            }
            const frame = d.current();
            const depth = d.stack_len - 1;
            switch (frame.kind) {
                .array => {
                    if (!try d.nextArrayItem()) {
                        self.done = d.stack_len == self.base;
                        return .array_end;
                    }
                    return try self.valueEvent();
                },
                .object => {
                    if (self.want_value[depth]) {
                        self.want_value[depth] = false;
                        return try self.valueEvent();
                    }
                    if (try d.beginObjectEntry()) {
                        self.done = d.stack_len == self.base;
                        return .map_end;
                    }
                    self.want_value[depth] = true;
                    return try self.keyEvent();
                },
            }
        }

        /// Consumes the next item whole: a scalar, or a container with everything in it. Call it
        /// where a value is expected, as `next` would return one.
        pub fn skip(self: *Self) !void {
            var depth: usize = 0;
            while (try self.next()) |event| {
                switch (event) {
                    .array_begin, .map_begin => depth += 1,
                    .array_end, .map_end => depth -= 1,
                    else => {},
                }
                if (depth == 0) return;
            }
        }

        /// After the last event: no trailing bytes.
        pub fn finish(self: *Self) !void {
            if (!self.done) return error.UnexpectedEndOfInput;
            try self.d.finish();
        }

        fn release(self: *Self) void {
            if (self.scratch) |bytes| self.allocator.free(bytes);
            self.scratch = null;
        }

        fn keep(self: *Self, token: StringToken) []const u8 {
            if (token.allocated) self.scratch = @constCast(token.bytes);
            return token.bytes;
        }

        fn valueEvent(self: *Self) !typed.Event {
            const d = self.d;
            switch (try d.peekKind()) {
                .array => {
                    const len = try d.beginArrayLen();
                    self.want_value[d.stack_len - 1] = false;
                    return .{ .array_begin = len };
                },
                .object => {
                    try d.beginObject();
                    self.want_value[d.stack_len - 1] = false;
                    const frame = d.current();
                    return .{ .map_begin = if (frame.indefinite) null else frame.remaining };
                },
                else => |kind| return try self.scalarEvent(kind),
            }
        }

        fn scalarEvent(self: *Self, kind: ValueKind) !typed.Event {
            const d = self.d;
            switch (kind) {
                .null => {
                    try d.readNull();
                    return .null;
                },
                .bool => return .{ .bool = try d.readBool() },
                .number => return switch (try d.readNumber()) {
                    .integer => |value| .{ .integer = value },
                    .float => |value| .{ .float = value },
                },
                .string => return .{ .text = self.keep(try d.readString(self.allocator)) },
                .bytes => return .{ .bytes = self.keep(try d.readBytes(self.allocator)) },
                .array, .object => unreachable,
            }
        }

        /// A map key: a scalar, checked and recorded like any key of a typed read.
        fn keyEvent(self: *Self) !typed.Event {
            const d = self.d;
            const kind = try d.peekKind();
            if (kind == .array or kind == .object) return error.UnexpectedType;
            const start = d.index;
            try d.recordKeyItem(d.stack_len);
            const end = d.index;
            // Read it again as an event; the first read counted it already.
            d.index = start;
            d.items -= 1;
            const event = try self.scalarEvent(kind);
            std.debug.assert(d.index == end);
            try d.orderFrameKey(start);
            return event;
        }
    };
}

/// A writer for a value whose shape is only known while writing: the caller says what comes next,
/// and containers are closed with `endArray` and `endMap`. Arrays and maps are buffered until they
/// close, so their lengths are definite. With `deterministic` a map is sorted by the encoded bytes of
/// its keys (RFC 8949 §4.2.1; a repeated key is `error.DuplicateField`) and a float is written in its
/// shortest exact width; without it entries keep the order they were written in and a float is a
/// double. A map's items are keys and values alternately, and a key can be any item.
pub fn valueWriter(allocator: Allocator, writer: *std.Io.Writer, comptime cfg: anytype) ValueWriter {
    return ValueWriter.init(allocator, writer, effectiveDeterministic(cfg));
}

/// A writer for a wire type's encode hook: items go out as they are written, with no buffering and
/// no allocation, so a container's length is stated up front and the caller writes exactly that many
/// items (twice as many for a map, keys and values alternately). Keys are written in the order the
/// output needs: for deterministic CBOR, ascending by encoded bytes. The ends are no-ops here and
/// are there so a hook reads the same for every format.
pub const Encoder = struct {
    writer: *std.Io.Writer,
    deterministic: bool,

    pub fn writeNull(self: *Encoder) !void {
        try self.writer.writeByte(0xf6);
    }

    pub fn writeBool(self: *Encoder, value: bool) !void {
        try self.writer.writeByte(if (value) 0xf5 else 0xf4);
    }

    pub fn writeInt(self: *Encoder, value: i128) !void {
        try encodeInt(self.writer, value);
    }

    pub fn writeFloat(self: *Encoder, value: f64) !void {
        if (self.deterministic) try writePreferredFloat(self.writer, value) else try encodeFloat(self.writer, value);
    }

    pub fn writeText(self: *Encoder, value: []const u8) !void {
        try writeTextString(self.writer, value);
    }

    pub fn writeBytes(self: *Encoder, value: []const u8) !void {
        try writeMajorValue(self.writer, 2, value.len);
        try self.writer.writeAll(value);
    }

    /// An item that is already CBOR, unchanged.
    pub fn writeRaw(self: *Encoder, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
    }

    pub fn beginArray(self: *Encoder, len: usize) !void {
        try writeMajorValue(self.writer, 4, len);
    }

    pub fn endArray(self: *Encoder) !void {
        _ = self;
    }

    pub fn beginMap(self: *Encoder, len: usize) !void {
        try writeMajorValue(self.writer, 5, len);
    }

    pub fn endMap(self: *Encoder) !void {
        _ = self;
    }
};

// The writer's methods share these names, so the file-level writers get others.
const encodeInt = writeInt;
const encodeFloat = writeFloat;

pub const ValueWriter = struct {
    allocator: Allocator,
    out: *std.Io.Writer,
    deterministic: bool,
    frames: [max_nesting]Frame = undefined,
    depth: usize = 0,

    const Frame = struct {
        kind: ContainerKind,
        buf: std.Io.Writer.Allocating,
        /// Items in an array, entries in a map.
        count: usize = 0,
        entries: std.ArrayList(Entry) = .empty,
        key_start: usize = 0,
        key_end: usize = 0,
        expect_key: bool = true,
    };

    /// One map entry in its frame's buffer: the key, then its value.
    const Entry = struct { key_start: usize, key_end: usize, end: usize };

    fn init(allocator: Allocator, writer: *std.Io.Writer, deterministic: bool) ValueWriter {
        return .{ .allocator = allocator, .out = writer, .deterministic = deterministic };
    }

    /// Releases the buffers of containers still open.
    pub fn deinit(self: *ValueWriter) void {
        for (self.frames[0..self.depth]) |*frame| {
            frame.buf.deinit();
            frame.entries.deinit(self.allocator);
        }
        self.depth = 0;
    }

    /// After the last item: every container is closed.
    pub fn finish(self: *ValueWriter) !void {
        if (self.depth != 0) return error.UnbalancedContainers;
    }

    pub fn writeNull(self: *ValueWriter) !void {
        try self.beforeItem();
        try self.sink().writeByte(0xf6);
        try self.afterItem();
    }

    pub fn writeBool(self: *ValueWriter, value: bool) !void {
        try self.beforeItem();
        try self.sink().writeByte(if (value) 0xf5 else 0xf4);
        try self.afterItem();
    }

    pub fn writeInt(self: *ValueWriter, value: i128) !void {
        try self.beforeItem();
        try encodeInt(self.sink(), value);
        try self.afterItem();
    }

    pub fn writeFloat(self: *ValueWriter, value: f64) !void {
        try self.beforeItem();
        if (self.deterministic) try writePreferredFloat(self.sink(), value) else try encodeFloat(self.sink(), value);
        try self.afterItem();
    }

    pub fn writeText(self: *ValueWriter, value: []const u8) !void {
        try self.beforeItem();
        try writeTextString(self.sink(), value);
        try self.afterItem();
    }

    pub fn writeBytes(self: *ValueWriter, value: []const u8) !void {
        try self.beforeItem();
        const out = self.sink();
        try writeMajorValue(out, 2, value.len);
        try out.writeAll(value);
        try self.afterItem();
    }

    /// Writes an item that is already CBOR, unchanged: a `zerde.Raw` that was read, say.
    pub fn writeRaw(self: *ValueWriter, bytes: []const u8) !void {
        try self.beforeItem();
        try self.sink().writeAll(bytes);
        try self.afterItem();
    }

    pub fn beginArray(self: *ValueWriter) !void {
        try self.begin(.array);
    }

    pub fn endArray(self: *ValueWriter) !void {
        const frame = try self.closing(.array);
        const out = self.parentSink();
        try writeMajorValue(out, 4, frame.count);
        try out.writeAll(frame.buf.written());
        self.release(frame);
        try self.afterItem();
    }

    pub fn beginMap(self: *ValueWriter) !void {
        try self.begin(.object);
    }

    pub fn endMap(self: *ValueWriter) !void {
        const frame = try self.closing(.object);
        if (!frame.expect_key) return error.UnbalancedContainers;
        const out = self.parentSink();
        const body = frame.buf.written();
        try writeMajorValue(out, 5, frame.count);
        if (!self.deterministic) {
            try out.writeAll(body);
        } else {
            const Order = struct {
                body: []const u8,
                fn less(ctx: @This(), a: Entry, b: Entry) bool {
                    return std.mem.lessThan(u8, ctx.body[a.key_start..a.key_end], ctx.body[b.key_start..b.key_end]);
                }
            };
            const entries = frame.entries.items;
            std.sort.pdq(Entry, entries, Order{ .body = body }, Order.less);
            for (entries[@min(1, entries.len)..], 0..) |entry, previous| {
                if (std.mem.eql(u8, body[entries[previous].key_start..entries[previous].key_end], body[entry.key_start..entry.key_end])) return error.DuplicateField;
            }
            for (entries) |entry| try out.writeAll(body[entry.key_start..entry.end]);
        }
        self.release(frame);
        try self.afterItem();
    }

    /// Writes one event of a pull read, so a reader can be copied into a writer.
    pub fn writeEvent(self: *ValueWriter, event: typed.Event) !void {
        switch (event) {
            .null => try self.writeNull(),
            .bool => |value| try self.writeBool(value),
            .integer => |value| try self.writeInt(value),
            .float => |value| try self.writeFloat(value),
            .text => |value| try self.writeText(value),
            .bytes => |value| try self.writeBytes(value),
            .array_begin => try self.beginArray(),
            .array_end => try self.endArray(),
            .map_begin => try self.beginMap(),
            .map_end => try self.endMap(),
        }
    }

    fn sink(self: *ValueWriter) *std.Io.Writer {
        if (self.depth == 0) return self.out;
        return &self.frames[self.depth - 1].buf.writer;
    }

    fn parentSink(self: *ValueWriter) *std.Io.Writer {
        if (self.depth <= 1) return self.out;
        return &self.frames[self.depth - 2].buf.writer;
    }

    /// Notes where a map key starts, before any item is written.
    fn beforeItem(self: *ValueWriter) !void {
        if (self.depth == 0) return;
        const frame = &self.frames[self.depth - 1];
        if (frame.kind == .object and frame.expect_key) frame.key_start = frame.buf.written().len;
    }

    /// Counts a finished item in the container around it, and closes a map entry.
    fn afterItem(self: *ValueWriter) !void {
        if (self.depth == 0) return;
        const frame = &self.frames[self.depth - 1];
        const at = frame.buf.written().len;
        switch (frame.kind) {
            .array => frame.count += 1,
            .object => if (frame.expect_key) {
                frame.key_end = at;
                frame.expect_key = false;
            } else {
                try frame.entries.append(self.allocator, .{ .key_start = frame.key_start, .key_end = frame.key_end, .end = at });
                frame.count += 1;
                frame.expect_key = true;
            },
        }
    }

    fn begin(self: *ValueWriter, kind: ContainerKind) !void {
        try self.beforeItem();
        if (self.depth >= max_nesting) return error.CborNestingTooDeep;
        self.frames[self.depth] = .{ .kind = kind, .buf = .init(self.allocator) };
        self.depth += 1;
    }

    /// The innermost container, which must be of `kind`; the caller releases it after use.
    fn closing(self: *ValueWriter, kind: ContainerKind) !*Frame {
        if (self.depth == 0 or self.frames[self.depth - 1].kind != kind) return error.UnbalancedContainers;
        return &self.frames[self.depth - 1];
    }

    fn release(self: *ValueWriter, frame: *Frame) void {
        frame.buf.deinit();
        frame.entries.deinit(self.allocator);
        self.depth -= 1;
    }
};

pub fn serialize(writer: *std.Io.Writer, value: anytype) !void {
    try serializeWith(writer, value, .{}, .{});
}

pub fn serializeWith(
    writer: *std.Io.Writer,
    value: anytype,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    try typed.serialize(@This(), writer, value, serde_cfg, format_cfg);
}

pub fn deserialize(comptime T: type, allocator: Allocator, reader: *std.Io.Reader) ParseError!T {
    return deserializeWith(T, allocator, reader, .{}, .{});
}

pub fn deserializeWith(
    comptime T: type,
    allocator: Allocator,
    reader: *std.Io.Reader,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try readerDeserializer(allocator, reader, read_cfg);
    defer deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

pub fn parseSlice(comptime T: type, allocator: Allocator, input: []const u8) ParseError!T {
    return parseSliceWith(T, allocator, input, .{}, .{});
}

pub fn parseSliceWith(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try sliceDeserializer(allocator, input, read_cfg);
    defer deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

pub fn parseSliceAliased(comptime T: type, allocator: Allocator, input: []const u8) ParseError!T {
    return parseSliceAliasedWith(T, allocator, input, .{}, .{});
}

pub fn parseSliceAliasedWith(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try sliceDeserializer(allocator, input, .{
        .max_input_bytes = effectiveMaxInputBytes(read_cfg),
        .borrow_strings = true,
    });
    defer deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

/// Reads one head and checks that it is well-formed: a reserved additional-info value, an
/// indefinite length on a type that has none, and a two-byte simple value below 32 are all refused
/// (RFC 8949 §3.3 and Appendix C). A length written longer than it needs to be is accepted.
fn parseHeader(input: []const u8, cursor: *usize) !Header {
    if (cursor.* >= input.len) return error.UnexpectedEndOfInput;

    const initial = input[cursor.*];
    cursor.* += 1;

    const major = initial >> 5;
    const ai = initial & 0x1f;

    return switch (ai) {
        0...23 => .{
            .major = major,
            .ai = ai,
            .value = ai,
            .indefinite = false,
        },
        24 => blk: {
            const value = try readSizedUnsigned(input, cursor, 1);
            // `0xf8` followed by a value under 32 would be a second spelling of a one-byte simple value.
            if (major == 7 and value < 32) return error.InvalidSimpleValue;
            break :blk .{
                .major = major,
                .ai = ai,
                .value = value,
                .indefinite = false,
            };
        },
        25 => .{
            .major = major,
            .ai = ai,
            .value = try readSizedUnsigned(input, cursor, 2),
            .indefinite = false,
        },
        26 => .{
            .major = major,
            .ai = ai,
            .value = try readSizedUnsigned(input, cursor, 4),
            .indefinite = false,
        },
        27 => .{
            .major = major,
            .ai = ai,
            .value = try readSizedUnsigned(input, cursor, 8),
            .indefinite = false,
        },
        28, 29, 30 => error.InvalidAdditionalInfo,
        31 => switch (major) {
            2, 3, 4, 5 => .{
                .major = major,
                .ai = ai,
                .value = 0,
                .indefinite = true,
            },
            else => error.InvalidAdditionalInfo,
        },
        else => unreachable,
    };
}

fn readSizedUnsigned(input: []const u8, cursor: *usize, byte_count: usize) !u64 {
    if (input.len - cursor.* < byte_count) return error.UnexpectedEndOfInput;

    var value: u64 = 0;
    for (input[cursor.* .. cursor.* + byte_count]) |byte| {
        value = (value << 8) | byte;
    }
    cursor.* += byte_count;
    return value;
}

fn writeInt(writer: *std.Io.Writer, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .comptime_int => {
            if (value >= 0) {
                const unsigned = std.math.cast(u64, value) orelse return error.CborIntegerOutOfRange;
                try writeMajorValue(writer, 0, unsigned);
            } else {
                const adjusted = std.math.cast(u64, -value - 1) orelse return error.CborIntegerOutOfRange;
                try writeMajorValue(writer, 1, adjusted);
            }
        },
        .int => |info| {
            if (info.signedness == .unsigned) {
                const unsigned = std.math.cast(u64, value) orelse return error.CborIntegerOutOfRange;
                try writeMajorValue(writer, 0, unsigned);
            } else if (value >= 0) {
                const unsigned = std.math.cast(u64, value) orelse return error.CborIntegerOutOfRange;
                try writeMajorValue(writer, 0, unsigned);
            } else {
                const adjusted = std.math.cast(u64, -@as(i128, @intCast(value)) - 1) orelse return error.CborIntegerOutOfRange;
                try writeMajorValue(writer, 1, adjusted);
            }
        },
        else => return error.UnsupportedType,
    }
}

fn writeFloat(writer: *std.Io.Writer, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .comptime_float => try writeFloat(writer, @as(f64, value)),
        .float => |info| switch (info.bits) {
            16 => {
                try writer.writeByte(0xf9);
                try writeBigEndian(writer, @as(u16, @bitCast(value)));
            },
            32 => {
                try writer.writeByte(0xfa);
                try writeBigEndian(writer, @as(u32, @bitCast(value)));
            },
            64 => {
                try writer.writeByte(0xfb);
                try writeBigEndian(writer, @as(u64, @bitCast(value)));
            },
            else => return error.UnsupportedType,
        },
        else => return error.UnsupportedType,
    }
}

/// RFC 8949 §4.1 preferred serialization: the shortest of half, single and double precision that
/// keeps the value exactly, and the canonical quiet NaN `0xf97e00` for every NaN.
fn writePreferredFloat(writer: *std.Io.Writer, value: anytype) !void {
    const wide: f64 = switch (@typeInfo(@TypeOf(value))) {
        .comptime_float => value,
        .float => |info| if (info.bits <= 64) @floatCast(value) else return error.UnsupportedType,
        else => return error.UnsupportedType,
    };
    if (std.math.isNan(wide)) return writer.writeAll(&.{ 0xf9, 0x7e, 0x00 });

    const half: f16 = @floatCast(wide);
    if (@as(f64, half) == wide) return writeFloat(writer, half);
    const single: f32 = @floatCast(wide);
    if (@as(f64, single) == wide) return writeFloat(writer, single);
    return writeFloat(writer, wide);
}

fn writeTextString(writer: *std.Io.Writer, value: []const u8) !void {
    try writeMajorValue(writer, 3, value.len);
    try writer.writeAll(value);
}

fn writeMajorValue(writer: *std.Io.Writer, major: u8, value: anytype) !void {
    const len = std.math.cast(u64, value) orelse return error.LengthMismatch;
    const head = major << 5;
    switch (len) {
        0...23 => try writer.writeByte(head | @as(u8, @intCast(len))),
        24...0xff => {
            try writer.writeByte(head | 24);
            try writer.writeByte(@as(u8, @intCast(len)));
        },
        0x0100...0xffff => {
            try writer.writeByte(head | 25);
            try writeBigEndian(writer, @as(u16, @intCast(len)));
        },
        0x0001_0000...0xffff_ffff => {
            try writer.writeByte(head | 26);
            try writeBigEndian(writer, @as(u32, @intCast(len)));
        },
        else => {
            try writer.writeByte(head | 27);
            try writeBigEndian(writer, len);
        },
    }
}

fn writeBigEndian(writer: *std.Io.Writer, value: anytype) !void {
    var buffer: [@sizeOf(@TypeOf(value))]u8 = undefined;
    inline for (0..buffer.len) |index| {
        const shift = (buffer.len - 1 - index) * 8;
        buffer[index] = @as(u8, @truncate(value >> shift));
    }
    try writer.writeAll(&buffer);
}

fn effectiveMaxInputBytes(comptime cfg: anytype) usize {
    if (comptime meta.hasField(@TypeOf(cfg), "max_input_bytes")) return @field(cfg, "max_input_bytes");
    return (ReadConfig{}).max_input_bytes;
}

fn readOption(cfg: anytype, comptime name: []const u8, default: anytype) @TypeOf(default) {
    if (comptime meta.hasField(@TypeOf(cfg), name)) return @field(cfg, name);
    return default;
}

fn limit(cfg: anytype, comptime name: []const u8, default: usize) usize {
    return readOption(cfg, name, default);
}

/// The container stack is fixed at `max_nesting`, so a larger `max_depth` cannot be honoured.
fn checkLimits(comptime cfg: anytype) void {
    if (comptime meta.hasField(@TypeOf(cfg), "max_depth") and cfg.max_depth > max_nesting) {
        @compileError("max_depth is at most 128, the depth of the container stack");
    }
}

/// Whether a head with a length argument is written in the fewest bytes (RFC 8949 §4.2.1).
fn isShortestHead(header: Header) bool {
    if (header.major == 7 or header.indefinite) return true;
    return switch (header.ai) {
        24 => header.value >= 24,
        25 => header.value > 0xff,
        26 => header.value > 0xffff,
        27 => header.value > 0xffff_ffff,
        else => true,
    };
}

/// Whether a float head is the preferred serialization of RFC 8949 §4.2.2: the shortest of half,
/// single and double that keeps the value, and NaN only as `0xf97e00`.
fn isPreferredFloat(header: Header) bool {
    switch (header.ai) {
        25 => {
            const half: f16 = @bitCast(@as(u16, @intCast(header.value)));
            return !std.math.isNan(half) or header.value == 0x7e00;
        },
        26 => {
            const single: f32 = @bitCast(@as(u32, @intCast(header.value)));
            if (!std.math.isFinite(single)) return false;
            const half: f16 = @floatCast(single);
            return @as(f32, half) != single;
        },
        27 => {
            const double: f64 = @bitCast(header.value);
            if (!std.math.isFinite(double)) return false;
            const single: f32 = @floatCast(double);
            return @as(f64, single) != double;
        },
        else => return true,
    }
}

fn effectiveBorrowStrings(cfg: anytype) bool {
    if (comptime meta.hasField(@TypeOf(cfg), "borrow_strings")) return cfg.borrow_strings;
    return false;
}

test "serialize and parse struct to cbor" {
    const Example = struct {
        firstName: []const u8,
        active: bool,
        kind: enum {
            admin,
            member,
        },
        note: ?[]const u8,
        samples: [3]u16,
        metadata: struct {
            accountId: u64,
        },

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const expected = Example{
        .firstName = "Ada",
        .active = true,
        .kind = .admin,
        .note = null,
        .samples = .{ 3, 5, 8 },
        .metadata = .{
            .accountId = 42,
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try serializeWith(&out.writer, expected, .{
        .rename_all = .snake_case,
    }, .{});

    const decoded = try parseSliceWith(Example, std.testing.allocator, out.written(), .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualDeep(expected, decoded);
}

test "parseSliceAliased reuses cbor string bytes from input" {
    const Example = struct {
        message: []const u8,
    };

    const input = [_]u8{
        0xa1,
        0x67,
        'm',
        'e',
        's',
        's',
        'a',
        'g',
        'e',
        0x62,
        'o',
        'k',
    };

    const decoded = try parseSliceAliased(Example, std.testing.allocator, &input);
    try std.testing.expectEqualStrings("ok", decoded.message);

    const begin = @intFromPtr(input[0..].ptr);
    const end = begin + input.len;
    const ptr = @intFromPtr(decoded.message.ptr);
    try std.testing.expect(ptr >= begin and ptr < end);
}

test "parseSlice keeps cbor strings owned at the typed edge" {
    const Example = struct {
        message: []const u8,
    };

    const input = [_]u8{
        0xa1,
        0x67,
        'm',
        'e',
        's',
        's',
        'a',
        'g',
        'e',
        0x62,
        'o',
        'k',
    };

    const decoded = try parseSlice(Example, std.testing.allocator, &input);
    defer typed.free(std.testing.allocator, decoded);
    try std.testing.expectEqualStrings("ok", decoded.message);

    const begin = @intFromPtr(input[0..].ptr);
    const end = begin + input.len;
    const ptr = @intFromPtr(decoded.message.ptr);
    try std.testing.expect(ptr < begin or ptr >= end);
}

test "parse definite cbor map with snake_case fields" {
    const Example = struct {
        firstName: []const u8,
        port: u16,

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const input = [_]u8{
        0xa2,
        0x6a,
        'f',
        'i',
        'r',
        's',
        't',
        '_',
        'n',
        'a',
        'm',
        'e',
        0x63,
        'A',
        'd',
        'a',
        0x64,
        'p',
        'o',
        'r',
        't',
        0x19,
        0x1f,
        0x90,
    };

    const decoded = try parseSliceWith(Example, std.testing.allocator, &input, .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Ada", decoded.firstName);
    try std.testing.expectEqual(@as(u16, 8080), decoded.port);
}

test "parse cbor byte string into fixed byte array" {
    const Example = struct {
        payload: [3]u8,
    };

    const input = [_]u8{
        0xa1,
        0x67,
        'p',
        'a',
        'y',
        'l',
        'o',
        'a',
        'd',
        0x43,
        0x01,
        0x02,
        0x03,
    };

    const decoded = try parseSlice(Example, std.testing.allocator, &input);
    try std.testing.expectEqualDeep([_]u8{ 0x01, 0x02, 0x03 }, decoded.payload);
}

test "parse indefinite cbor map and array" {
    const Example = struct {
        name: []const u8,
        samples: []const u16,
    };

    const input = [_]u8{
        0xbf,
        0x64,
        'n',
        'a',
        'm',
        'e',
        0x63,
        'A',
        'd',
        'a',
        0x67,
        's',
        'a',
        'm',
        'p',
        'l',
        'e',
        's',
        0x9f,
        0x01,
        0x02,
        0x03,
        0xff,
        0xff,
    };

    const decoded = try parseSlice(Example, std.testing.allocator, &input);
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Ada", decoded.name);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, decoded.samples);
}

test "reader deserialize reads from a fixed CBOR input" {
    const Example = struct {
        name: []const u8,
        count: u16,
    };

    const input = [_]u8{
        0xa2,
        0x64,
        'n',
        'a',
        'm',
        'e',
        0x63,
        'A',
        'd',
        'a',
        0x65,
        'c',
        'o',
        'u',
        'n',
        't',
        0x18,
        0x2a,
    };

    var reader = std.Io.Reader.fixed(&input);
    const decoded = try deserialize(Example, std.testing.allocator, &reader);
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Ada", decoded.name);
    try std.testing.expectEqual(@as(u16, 42), decoded.count);
}

test "simple value 23 is not treated as cbor null" {
    var deserializer = try sliceDeserializer(std.testing.allocator, &.{0xf7}, .{});
    defer deserializer.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnexpectedToken, deserializer.peekKind());
}

test "indefinite length is rejected for invalid major types" {
    try std.testing.expectError(
        error.InvalidAdditionalInfo,
        parseSlice(u8, std.testing.allocator, &.{0x1f}),
    );
}

test "a fixed byte array is written as a byte string and read back" {
    const Example = struct {
        digest: [3]u8,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(&out.writer, Example{ .digest = .{ 0xff, 0x00, 0x80 } }, .{}, .{});

    // Map head, "digest" as text, then a 3-byte bstr (0x43): not a text string, which must be UTF-8.
    try std.testing.expectEqualSlices(u8, &.{ 0xbf, 0x66, 'd', 'i', 'g', 'e', 's', 't', 0x43, 0xff, 0x00, 0x80, 0xff }, out.written());
    const decoded = try parseSlice(Example, std.testing.allocator, out.written());
    try std.testing.expectEqualDeep([_]u8{ 0xff, 0x00, 0x80 }, decoded.digest);
}

test "deterministic writes a definite map with length-first keys" {
    const Example = struct {
        zeta: u8,
        id: u8,
        alpha: u8,
        beta: u8,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(&out.writer, Example{ .zeta = 1, .id = 2, .alpha = 3, .beta = 4 }, .{}, .{ .deterministic = true });

    // Four pairs (0xa4); "id" before "beta" before "zeta" (length 4, bytewise) before "alpha".
    try std.testing.expectEqualSlices(u8, &.{
        0xa4,
        0x62,
        'i',
        'd',
        0x02,
        0x64,
        'b',
        'e',
        't',
        'a',
        0x04,
        0x64,
        'z',
        'e',
        't',
        'a',
        0x01,
        0x65,
        'a',
        'l',
        'p',
        'h',
        'a',
        0x03,
    }, out.written());
}

test "deterministic orders by wire name and counts omitted fields out" {
    const Example = struct {
        long_name: u8,
        b: ?u8,

        pub const serde = .{ .rename_all = .camelCase };
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(&out.writer, Example{ .long_name = 7, .b = null }, .{ .omit_null_fields = true }, WriteConfig{ .deterministic = true });

    try std.testing.expectEqualSlices(u8, &.{ 0xa1, 0x68, 'l', 'o', 'n', 'g', 'N', 'a', 'm', 'e', 0x07 }, out.written());
}

test "deterministic output does not depend on declaration order" {
    const Forward = struct { a: u8, bb: u8, ccc: u8 };
    const Backward = struct { ccc: u8, bb: u8, a: u8 };

    var forward: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer forward.deinit();
    var backward: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer backward.deinit();
    try serializeWith(&forward.writer, Forward{ .a = 1, .bb = 2, .ccc = 3 }, .{}, .{ .deterministic = true });
    try serializeWith(&backward.writer, Backward{ .ccc = 3, .bb = 2, .a = 1 }, .{}, .{ .deterministic = true });
    try std.testing.expectEqualSlices(u8, forward.written(), backward.written());
}

test "deterministic writes each float in its shortest exact width" {
    const cases = [_]struct { value: f64, bytes: []const u8 }{
        .{ .value = 1.5, .bytes = &.{ 0xf9, 0x3e, 0x00 } },
        .{ .value = -0.0, .bytes = &.{ 0xf9, 0x80, 0x00 } },
        .{ .value = std.math.inf(f64), .bytes = &.{ 0xf9, 0x7c, 0x00 } },
        .{ .value = std.math.nan(f64), .bytes = &.{ 0xf9, 0x7e, 0x00 } },
        .{ .value = 100000.0, .bytes = &.{ 0xfa, 0x47, 0xc3, 0x50, 0x00 } },
        .{ .value = 1.1, .bytes = &.{ 0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a } },
    };
    for (cases) |case| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try serializeWith(&out.writer, case.value, .{}, .{ .deterministic = true });
        try std.testing.expectEqualSlices(u8, case.bytes, out.written());
    }
}

test "the default write keeps indefinite maps in declaration order" {
    const Example = struct { zeta: u8, id: u8 };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(&out.writer, Example{ .zeta = 1, .id = 2 }, .{}, .{});
    try std.testing.expectEqualSlices(u8, &.{ 0xbf, 0x64, 'z', 'e', 't', 'a', 0x01, 0x62, 'i', 'd', 0x02, 0xff }, out.written());
}

test "a field order from the call site applies to the default write" {
    const Example = struct { zeta: u8, id: u8 };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(&out.writer, Example{ .zeta = 1, .id = 2 }, .{ .field_order = .bytewise }, .{});
    try std.testing.expectEqualSlices(u8, &.{ 0xbf, 0x62, 'i', 'd', 0x02, 0x64, 'z', 'e', 't', 'a', 0x01, 0xff }, out.written());
}
