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

/// One CBOR data item kept as its bytes; see `typed.RawOf`.
pub const Raw = typed.RawOf(.cbor);

pub const ReadConfig = struct {
    max_input_bytes: usize = 16 * 1024 * 1024,
    borrow_strings: bool = false,
    /// Refuse NaN and the infinities in any float, including in skipped values and keys
    /// (`error.NonFiniteFloat`). RFC 8949 §3.3 makes them values, so the default reads them; a
    /// profile that forbids them turns this on.
    refuse_non_finite: bool = false,
    /// Refuse -0.0, in any float width, including in skipped values, keys and a `Raw` item (`error.NegativeZero`). RFC 8949 §4.2.2
    /// makes it a value distinct from 0.0 and `Mode.strict` takes it, so the default reads it; a profile that keeps no negative zero
    /// turns this on, and writes with `WriteConfig.normalize_negative_zero`.
    refuse_negative_zero: bool = false,
    /// Which encodings are accepted; see `Mode`.
    mode: Mode = .lenient,
    /// Do not check that text is UTF-8: for an item that is known to be valid already, such as one
    /// this library wrote and a store authenticated, where checking again costs more than the rest of
    /// the read. Bytes that are not UTF-8 are then handed on as text, so it is never for input that
    /// has not been checked once.
    trusted_text: bool = false,
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
    ///
    /// A strict read keeps no record of a key and allocates nothing for the repeated-key check: one data item
    /// has one deterministic encoding, so equal keys are neighbours in the ascending order and are compared as
    /// bytes. The exception is that RFC 8949 §5.6.1 makes 0.0 and -0.0 the same key though they are written
    /// differently and need not be neighbours: a map with both as keys is `error.DuplicateField`, and a key
    /// that is an array or a map and holds a float zero anywhere inside it is `error.NonDeterministicEncoding`
    /// (the one input strict refuses that is well-formed and valid, because telling its repeats needs a record).
    /// An enum written as its number where the type writes its name is `error.NonDeterministicEncoding`.
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
    /// Do not check that text is UTF-8 on the way out (`error.InvalidUtf8`): for text that is known
    /// to be valid already, such as a string just read from a source that was checked. A value
    /// written this way may not read back.
    trusted_text: bool = false,
    /// Write a float zero as +0 (`0xf90000`), -0.0 included, so that equal numbers have one encoding whatever sign a source gave
    /// them, as a profile that keeps no negative zero requires. RFC 8949 §4.2.2 writes -0.0 as `0xf98000`, so the default keeps it.
    /// A `Raw` or extras item that holds -0.0 is `error.NegativeZero`, since it is copied as it is (`ValueWriter.writeRaw` and
    /// `canonicalizeWith` rewrite it instead). It applies with or without `deterministic`.
    normalize_negative_zero: bool = false,
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
pub fn writeHead(out: []u8, major: u8, value: u64) usize {
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
    /// A strict read's check of the keys against each other.
    order: KeyOrder = .{},
};

/// The last key of a map in a strict read (an empty span for none), which the next key is compared to, and
/// which of the zeros 0.0 (bit 0) and -0.0 (bit 1) have been keys.
const KeyOrder = struct {
    start: usize = 0,
    end: usize = 0,
    zeros: u2 = 0,
};

/// Packed, so a head is copied as whole words: copying its byte fields one by one into a caller that then reads
/// them as a word stalls the read on every head.
pub const Header = packed struct {
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

/// One byte string or `Raw` a gather write left out of its output: the skeleton has the head, and `len` bytes are to be
/// inserted at `skeleton_offset`, which are at `offset` from the base address the write was given.
pub const GatherRef = extern struct { skeleton_offset: u32, offset: u32, len: u32 };

/// Where a gather write (see `gather.zig`) records the byte strings it leaves out: `refs` is filled in output order,
/// for those of at least `min_len` bytes. The writer must be a fixed one, whose `end` is how much is written.
pub const GatherState = struct {
    refs: []GatherRef,
    count: usize = 0,
    base: usize,
    min_len: usize,

    fn add(self: *GatherState, at: usize, bytes: []const u8) !void {
        if (self.count == self.refs.len) return error.NoSpaceLeft;
        const address = @intFromPtr(bytes.ptr);
        if (address < self.base) return error.OffsetOutOfRange;
        const offset = address - self.base;
        if (at > std.math.maxInt(u32) or offset > std.math.maxInt(u32) or bytes.len > std.math.maxInt(u32) - offset) return error.OffsetOutOfRange;
        self.refs[self.count] = .{ .skeleton_offset = @intCast(at), .offset = @intCast(offset), .len = @intCast(bytes.len) };
        self.count += 1;
    }
};

/// `deterministic` is a type parameter, so the default write carries no runtime branch for it.
pub fn CborSerializer(comptime Config: type, comptime deterministic: bool) type {
    return struct {
        writer: *std.Io.Writer,
        cfg: Config,
        /// Set by a gather write: byte strings and `Raw` items it names are left out of the output.
        gather: ?*GatherState = null,

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
            const written = if (self.normalizesZero()) unsignedZero(value) else value;
            if (deterministic) return writePreferredFloat(self.writer, written);
            try writeFloat(self.writer, written);
        }

        /// Whether the write puts -0.0 out as +0 (`WriteConfig.normalize_negative_zero`), so an item it copies as it is may not hold one.
        fn normalizesZero(self: *const Self) bool {
            return readOption(self.cfg, "normalize_negative_zero", false);
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            try encodeText(self.writer, value, readOption(self.cfg, "trusted_text", false));
        }

        pub fn emitBytes(self: *Self, value: []const u8) !void {
            try writeMajorValue(self.writer, 2, value.len);
            if (self.gather) |state| if (value.len >= state.min_len) return state.add(self.writer.end, value);
            try self.writer.writeAll(value);
        }

        /// A byte string whose bytes are a copy the typed walk made (a `[N]u8`), which a gather write cannot point at.
        pub fn emitBytesInline(self: *Self, value: []const u8) !void {
            try writeMajorValue(self.writer, 2, value.len);
            try self.writer.writeAll(value);
        }

        /// `emitString` in pieces, for a resumable write (see `typed.serializeResumable`): the head, which needs 9
        /// bytes of room, then the text as far as the window goes. The text is checked as UTF-8 once, before the head.
        pub fn emitStringPart(self: *Self, value: []const u8, state: *typed.TextState) !void {
            if (!state.started) {
                if (!readOption(self.cfg, "trusted_text", false) and !bulk.validUtf8(value)) return error.InvalidUtf8;
                try self.headPart(3, value.len, state);
            }
            try typed.copyPart(self.writer, value, &state.at);
        }

        /// `emitBytes` in pieces.
        pub fn emitBytesPart(self: *Self, value: []const u8, state: *typed.TextState) !void {
            if (!state.started) try self.headPart(2, value.len, state);
            try typed.copyPart(self.writer, value, &state.at);
        }

        fn headPart(self: *Self, major: u8, len: usize, state: *typed.TextState) !void {
            if (self.writer.buffer.len - self.writer.end < 9) return error.WindowFull;
            try writeMajorValue(self.writer, major, len);
            state.started = true;
        }

        /// How many entries an extras map holds, for the head of the map it joins.
        pub fn extrasCount(self: *Self, bytes: []const u8) !usize {
            if (bytes.len != 0) try verifyItem(bytes, deterministic, self.normalizesZero());
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
            return .{ .writer = self.writer, .deterministic = deterministic, .trusted_text = readOption(self.cfg, "trusted_text", false), .normalize_zero = self.normalizesZero() };
        }

        pub const raw_format: typed.RawFormat = .cbor;

        /// Writes an item that was read as `cbor.Raw`: it is checked first, and in a deterministic
        /// write must already be deterministic (see `canonicalize`), so the output is what the write
        /// promises whatever mode the item was read in.
        pub fn emitRaw(self: *Self, value: []const u8) !void {
            try verifyItem(value, deterministic, self.normalizesZero());
            if (self.gather) |state| if (value.len >= state.min_len) return state.add(self.writer.end, value);
            try self.writer.writeAll(value);
        }

        /// `emitRaw` in pieces, for a resumable write: the item is checked once, before the first byte.
        pub fn emitRawPart(self: *Self, value: []const u8, state: *typed.TextState) !void {
            if (!state.started) {
                try verifyItem(value, deterministic, self.normalizesZero());
                state.started = true;
            }
            try typed.copyPart(self.writer, value, &state.at);
        }

        pub fn emitEnum(self: *Self, comptime E: type, value: E) !void {
            if (comptime @typeInfo(E).@"enum".mode == .nonexhaustive) {
                try encodeText(self.writer, @tagName(value), false);
            } else switch (value) {
                inline else => |tag| try writeName(self.writer, @tagName(tag)),
            }
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
            try writeName(self.writer, name);
            return true;
        }

        /// The start of an entry of a map whose keys are data (`SortedMap`), and the end of its key; the key, text, is written between
        /// them as any text is (`emitString`, or `emitStringPart` in windows). A CBOR map has nothing to put at either.
        pub fn beginMapEntry(self: *Self) !void {
            _ = self;
        }

        pub fn endMapKey(self: *Self) !void {
            _ = self;
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
        trusted_text: bool = false,
        /// A word the caller keeps with the deserializer, for decode hooks to read (`PullReader.userData`).
        user_data: usize = 0,
        /// `canonicalItem` writes the deterministic encoding (preferred floats; no tags) instead of
        /// the form that compares keys.
        canon_det: bool = false,
        /// `canonicalItem` writes a float zero as +0.
        canon_zero: bool = false,
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
        /// Keys of the maps being read, innermost last, for the duplicate check of a lenient read. A strict
        /// read keeps none: its keys are in order, so a repeat is the key before.
        keys: std.ArrayList(KeyRecord) = .empty,
        /// The bytes of keys that are not contiguous in the input (indefinite-length strings).
        key_bytes: std.ArrayList(u8) = .empty,
        /// A strict read sets this when it reads a float zero, which a key that holds one is refused for (`recordKeyItem`).
        zero_float: bool = false,

        const Self = @This();

        pub const supports_unions = true;
        pub const supports_integer_keys = true;
        /// The encoded form of a key, which a type that declares its fields in order is checked against (`typed.assertDeclaredOrder`).
        pub const keyEncoder = encodeKey;

        /// A read whose configuration does not name `mode` is lenient, and one that does not name `max_items` counts no
        /// items: both are decided when it is compiled, so the default read carries no check for either on each head.
        const may_be_strict = meta.hasField(Config, "mode");
        const counts_items = meta.hasField(Config, "max_items");

        /// Whether the keys of a map are guaranteed to ascend, so each repeats or follows the one before (a strict read).
        pub fn keysAscend(self: *Self) bool {
            return self.isStrict();
        }

        /// The read accepts only the deterministic encoding (`Mode.strict`): one value, one encoding.
        pub fn isStrict(self: *const Self) bool {
            return may_be_strict and self.strict;
        }

        /// Takes back the count of a head that is about to be read again.
        fn uncountItem(self: *Self) void {
            if (counts_items) self.items -= 1;
        }

        fn initBorrowed(allocator: Allocator, input: []const u8, cfg: Config) Self {
            return .{
                .input = input,
                .cfg = cfg,
                .allocator = allocator,
                .owns_input = false,
                .can_borrow_strings = effectiveBorrowStrings(cfg),
                .strict = readOption(cfg, "mode", Mode.lenient) == .strict,
                .trusted_text = readOption(cfg, "trusted_text", false),
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

        pub const raw_format: typed.RawFormat = .cbor;

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
        /// The entries the map just begun states it has, or null for an indefinite one.
        pub fn objectLen(self: *Self) ?usize {
            const frame = self.current();
            return if (frame.indefinite) null else frame.remaining;
        }

        pub fn nextObjectField(self: *Self, allocator: Allocator) !?StringToken {
            const token = (try self.nextSortedKey(allocator)) orelse return null;
            errdefer token.deinit(allocator);
            try self.recordText(token);
            return token;
        }

        /// The next text key of a map, not recorded for the repeated-key check. The reader of a `SortedMap`
        /// uses it: that reader refuses a repeat by comparing neighbours, so a record would be scratch that
        /// `regionSizes` does not count.
        pub fn nextSortedKey(self: *Self, allocator: Allocator) !?StringToken {
            if (try self.beginObjectEntry()) return null;

            const start = self.index;
            const header = try self.readHeader();
            if (header.major != 3) return error.UnexpectedType;
            const token = try self.finishString(allocator, header);
            errdefer token.deinit(allocator);
            try self.orderFrameKey(start);
            return token;
        }

        /// A text string read into `buffer` or the input, without allocating, for comparing with names a type
        /// declares: a string longer than `cap` is `.long`, still read to its end and checked, since no name
        /// is as long. A definite string is the input's own bytes; chunks are joined in `buffer`.
        pub fn readStringShort(self: *Self, comptime cap: usize, buffer: *[cap]u8) !typed.ShortText {
            const header = try self.readHeader();
            if (header.major != 3) return error.UnexpectedType;
            return self.shortAfter(header, cap, buffer);
        }

        fn shortAfter(self: *Self, header: Header, comptime cap: usize, buffer: *[cap]u8) !typed.ShortText {
            if (!header.indefinite) {
                if (header.value > self.max_string_len) return error.StringTooLong;
                const raw = try self.takeBytes(header.value);
                if (!self.trusted_text and !bulk.validUtf8(raw)) return error.InvalidUtf8;
                return .{ .text = raw };
            }
            var length: usize = 0;
            var total: usize = 0;
            var long = false;
            while (true) {
                if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
                if (self.input[self.index] == 0xff) {
                    self.index += 1;
                    break;
                }
                const chunk = try parseHeader(self.input, &self.index);
                if (chunk.major != 3 or chunk.indefinite) return error.InvalidStringChunk;
                if (chunk.value > self.max_string_len - total) return error.StringTooLong;
                const raw = try self.takeBytes(chunk.value);
                if (!self.trusted_text and !bulk.validUtf8(raw)) return error.InvalidUtf8;
                total += raw.len;
                if (!long and length + raw.len <= cap) {
                    @memcpy(buffer[length..][0..raw.len], raw);
                    length += raw.len;
                } else long = true;
            }
            return if (long) .long else .{ .text = buffer[0..length] };
        }

        /// The next key of a union's map (see `readStringShort`), or null at its end. A union has one entry, so
        /// the key is not recorded for the repeated-key check, which is what keeps nothing behind it.
        pub fn nextObjectKeyShort(self: *Self, comptime cap: usize, buffer: *[cap]u8) !?typed.ObjectKeyShort {
            if (try self.beginObjectEntry()) return null;

            const start = self.index;
            const header = try self.readHeader();
            switch (header.major) {
                3 => {
                    const key = try self.shortAfter(header, cap, buffer);
                    try self.orderFrameKey(start);
                    return switch (key) {
                        .text => |bytes| .{ .text = bytes },
                        .long => .long,
                    };
                },
                0, 1 => {
                    try self.orderFrameKey(start);
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
            try self.checkKeyOrder(&frame.order, start);
            return result;
        }

        fn lookupKey(self: *Self, comptime T: type, comptime cfg: anytype, start: usize) !ObjectFieldLookup {
            // A key no field declares is an error where unknown members are denied and nothing collects them,
            // so it is neither checked nor recorded: the typed layer refuses it next.
            const refused = comptime meta.effectiveDenyUnknownFields(T, cfg) and meta.extrasField(T) == null;
            const header = try self.nextHead();
            switch (header.major) {
                3 => {
                    if (!header.indefinite) {
                        // A field name the type declares is UTF-8 already, so a key that matches one needs no
                        // validation; any other key is checked before it is recorded.
                        if (header.value > self.max_string_len) return error.StringTooLong;
                        const raw = try self.takeBytes(header.value);
                        if (typed.matchStructFieldIndex(T, cfg, raw)) |index| return .{ .field_index = index };
                        if (refused) return .unknown;
                        if (!self.trusted_text and !bulk.validUtf8(raw)) return error.InvalidUtf8;
                        try self.recordText(.{ .bytes = raw, .allocated = false });
                        return .unknown;
                    }
                    // Chunks are joined in a buffer as long as the longest field name, and not allocated: only a key the
                    // type does not declare is, to record it for the repeated-key check.
                    const cap = comptime typed.longestFieldName(T, cfg);
                    var buffer: [cap]u8 = undefined;
                    const resume_at = self.index;
                    switch (try self.shortAfter(header, cap, &buffer)) {
                        .text => |bytes| if (typed.matchStructFieldIndex(T, cfg, bytes)) |index| return .{ .field_index = index },
                        .long => {},
                    }
                    if (refused) return .unknown;
                    self.index = resume_at;
                    const token = try self.finishString(self.allocator, header);
                    defer token.deinit(self.allocator);
                    try self.recordText(token);
                    return .unknown;
                },
                0, 1 => {
                    const value: i128 = if (header.major == 0) header.value else -@as(i128, header.value) - 1;
                    if (typed.matchStructFieldIndexInteger(T, cfg, value)) |index| return .{ .field_index = index };
                    if (refused) return .unknown;
                    if (!self.isStrict()) try self.keys.append(self.allocator, .{ .kind = if (header.major == 0) .uint else .nint, .a = header.value });
                    return .unknown;
                },
                else => {
                    self.index = start;
                    self.uncountItem();
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
            if (counts_items) {
                self.items += 1;
                if (self.items > self.max_items) return error.TooManyItems;
            }
            if (self.isStrict()) {
                if (header.major == 6) return error.UnexpectedTag;
                if (header.indefinite or !isShortestHead(header)) return error.NonDeterministicEncoding;
                if (header.major == 7 and !isPreferredFloat(header)) return error.NonDeterministicEncoding;
                if (header.major == 7 and header.ai >= 25 and header.ai <= 27 and floatValue(header) == 0) self.zero_float = true;
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
        /// one definite chunk, else joined from the chunks of an indefinite one: they are measured and
        /// checked first, then copied once into an allocation of exactly their length. Each chunk of an
        /// indefinite string is a definite string of the same type (RFC 8949 §3.2.3), and a text
        /// chunk is valid UTF-8 on its own, so a code point cannot straddle two chunks.
        fn finishString(self: *Self, allocator: Allocator, header: Header) !StringToken {
            const is_text = header.major == 3;
            if (!header.indefinite) {
                if (header.value > self.max_string_len) return error.StringTooLong;
                const raw = try self.takeBytes(header.value);
                if (is_text and !self.trusted_text and !bulk.validUtf8(raw)) return error.InvalidUtf8;
                return .{ .bytes = raw, .allocated = false };
            }

            const start = self.index;
            const total = try self.measureChunks(header.major);
            const end = self.index;
            self.index = start;
            const joined = try allocator.alloc(u8, total);
            errdefer allocator.free(joined);
            var at: usize = 0;
            // The chunks are checked; only their heads are read again, up to the break at `end - 1`.
            while (self.index < end - 1) {
                const chunk = try parseHeader(self.input, &self.index);
                const raw = try self.takeBytes(chunk.value);
                @memcpy(joined[at..][0..raw.len], raw);
                at += raw.len;
            }
            self.index = end;
            return .{ .bytes = joined, .allocated = true };
        }

        /// The length of the chunks of an indefinite string of type `major`, which are all checked as they are
        /// counted, and the index after its break.
        fn measureChunks(self: *Self, major: u8) !usize {
            var total: usize = 0;
            while (true) {
                if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
                if (self.input[self.index] == 0xff) {
                    self.index += 1;
                    return total;
                }
                const chunk = try parseHeader(self.input, &self.index);
                if (chunk.major != major or chunk.indefinite) return error.InvalidStringChunk;
                if (chunk.value > self.max_string_len - total) return error.StringTooLong;
                const raw = try self.takeBytes(chunk.value);
                if (major == 3 and !self.trusted_text and !bulk.validUtf8(raw)) return error.InvalidUtf8;
                total += raw.len;
            }
        }

        /// Checks the string whose head is `header`, and keeps nothing: no buffer for the chunks of an indefinite one.
        fn skipString(self: *Self, header: Header) !void {
            if (header.indefinite) {
                _ = try self.measureChunks(header.major);
                return;
            }
            if (header.value > self.max_string_len) return error.StringTooLong;
            const raw = try self.takeBytes(header.value);
            if (header.major == 3 and !self.trusted_text and !bulk.validUtf8(raw)) return error.InvalidUtf8;
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
                2, 3 => try self.skipString(header),
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
                    var order: KeyOrder = .{};
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
                            try self.checkKeyOrder(&order, key_start);
                            try self.skipItem(depth + 1);
                        }
                    }
                    try self.endKeys(keys_base, key_bytes_base);
                },
                else => return error.UnexpectedToken,
            }
        }

        /// Refuses what the config says to in a float; see `checkFloatHeader`.
        fn checkFloat(self: *Self, header: Header) !void {
            try checkFloatHeader(Config, self.cfg, header);
        }

        /// A strict read needs each key of a map to sort after the one before it by its encoded bytes
        /// (RFC 8949 §4.2.1), which also rules out a repeated key: one data item has one deterministic
        /// encoding. `order` is the last key and what the map has of the zeros 0.0 and -0.0, which are
        /// the same key (RFC 8949 section 5.6.1) though they are written differently and need not be neighbours.
        fn checkKeyOrder(self: *Self, order: *KeyOrder, start: usize) !void {
            if (!self.isStrict()) return;
            const key = self.input[start..self.index];
            if (order.end != 0) {
                const before = self.input[order.start..order.end];
                if (std.mem.eql(u8, before, key)) return error.DuplicateField;
                if (!std.mem.lessThan(u8, before, key)) return error.NonDeterministicEncoding;
            }
            order.start = start;
            order.end = self.index;
            // The preferred form of a zero is the half float (`isPreferredFloat`).
            if (key.len == 3 and key[0] == 0xf9 and std.mem.readInt(u16, key[1..3], .big) & 0x7fff == 0) try noteZeroKey(order, key);
        }

        fn orderFrameKey(self: *Self, start: usize) !void {
            try self.checkKeyOrder(&self.current().order, start);
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
            if (self.isStrict()) {
                // A deterministic encoding has one form for each key, so equal keys are neighbours (`checkKeyOrder`)
                // and nothing is recorded. The one equal pair of different forms is 0.0 and -0.0 (RFC 8949 section
                // 5.6.1): a float key is checked for it there, and a key that holds one inside is refused here.
                switch (header.major) {
                    0, 1, 7 => {},
                    2, 3 => try self.skipString(header),
                    else => {
                        self.index = start;
                        self.uncountItem();
                        const outer = self.zero_float;
                        self.zero_float = false;
                        try self.skipItem(depth);
                        if (self.zero_float) return error.NonDeterministicEncoding;
                        self.zero_float = outer;
                    },
                }
                return;
            }
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
                    self.uncountItem();
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
                    if (self.canon_det) return error.UnexpectedTag;
                    try self.appendHead(6, header.value);
                    try self.canonicalItem();
                },
                else => switch (header.ai) {
                    25, 26, 27 => if (self.canon_det) {
                        var buffer: [9]u8 = undefined;
                        var fixed = std.Io.Writer.fixed(&buffer);
                        try writePreferredFloat(&fixed, if (self.canon_zero) unsignedZero(floatValue(header)) else floatValue(header));
                        try self.key_bytes.appendSlice(self.allocator, fixed.buffered());
                    } else {
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
            if (entries.items.len > 1) for (entries.items[0 .. entries.items.len - 1], entries.items[1..]) |a, b| {
                const keys = self.key_bytes.items;
                if (std.mem.eql(u8, keys[a.start..a.key_end], keys[b.start..b.key_end])) return error.DuplicateField;
            };

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
            // A strict read compares neighbours and keeps no record.
            if (self.isStrict()) return;
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
/// The value of a float head, widened to a double.
pub fn floatValue(header: Header) f64 {
    return switch (header.ai) {
        25 => @floatCast(@as(f16, @bitCast(@as(u16, @intCast(header.value))))),
        26 => @floatCast(@as(f32, @bitCast(@as(u32, @intCast(header.value))))),
        else => @bitCast(header.value),
    };
}

/// Whether a float head is -0.0, in any width.
pub fn isNegativeZero(header: Header) bool {
    if (header.major != 7) return false;
    return switch (header.ai) {
        25 => header.value == 0x8000,
        26 => header.value == 0x8000_0000,
        27 => header.value == 0x8000_0000_0000_0000,
        else => false,
    };
}

/// `value`, or +0 when it is a zero: the float a write that normalizes negative zero puts out.
fn unsignedZero(value: anytype) @TypeOf(value) {
    return if (value == 0) 0 else value;
}

/// What a read with `cfg` refuses in the float whose head is `header`: a NaN or an infinity with `refuse_non_finite`
/// (the exponent field is all ones) and -0.0 with `refuse_negative_zero`. One check for every reader of CBOR.
pub fn checkFloatHeader(comptime Config: type, cfg: Config, header: Header) !void {
    if (header.major != 7) return;
    if (comptime meta.hasField(Config, "refuse_non_finite")) {
        const exponent_all_ones = switch (header.ai) {
            25 => (header.value >> 10) & 0x1f == 0x1f,
            26 => (header.value >> 23) & 0xff == 0xff,
            27 => (header.value >> 52) & 0x7ff == 0x7ff,
            else => false,
        };
        if (cfg.refuse_non_finite and exponent_all_ones) return error.NonFiniteFloat;
    }
    if (comptime meta.hasField(Config, "refuse_negative_zero")) {
        if (cfg.refuse_negative_zero and isNegativeZero(header)) return error.NegativeZero;
    }
}

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

/// Checks, without allocating, that `input` is exactly one item the writer may put out as it is:
/// well-formed with text that is UTF-8 and nesting within 128. With `deterministic` it is also an
/// item a strict read accepts (RFC 8949 §4.2.1 and §4.2.2; no tag), which includes map keys that
/// ascend strictly, so none repeats. Without it a repeated key is not looked for: that needs an
/// allocation, which `validate` has.
fn verifyItem(input: []const u8, deterministic: bool, refuse_zero: bool) !void {
    try verifyAs(input, deterministic, refuse_zero, .write);
}

/// `verifyItem` as a strict read checks an item: a repeated key is `error.DuplicateField`, and with `check_text` false (a read
/// under `trusted_text`) text is not checked as UTF-8. A resumable read of a `Raw` uses it on the item once it is whole.
pub fn verifyStrict(input: []const u8, check_text: bool) !void {
    try verifyAs(input, true, false, if (check_text) .read else .read_trusted);
}

/// Whose rules `checkItem` applies: a write's (a repeated key is `NonDeterministicEncoding`, text is checked) or a strict
/// read's (a repeated key is `DuplicateField`, text is checked unless `trusted_text`).
const Check = enum { write, read, read_trusted };

fn verifyAs(input: []const u8, deterministic: bool, refuse_zero: bool, check: Check) !void {
    var index: usize = 0;
    var zero = false;
    try checkItem(input, &index, 0, deterministic, refuse_zero, &zero, check);
    if (index != input.len) return error.TrailingCharacters;
}

/// `zero` is set when the item holds a float zero, which a deterministic check needs for a key: 0.0 and -0.0
/// are one key (RFC 8949 section 5.6.1), so a map may not have both, and a key that holds one is refused, as a
/// strict read does (`CborDeserializer.recordKeyItem`).
fn checkItem(input: []const u8, index: *usize, depth: usize, deterministic: bool, refuse_zero: bool, zero: *bool, check: Check) anyerror!void {
    var header = try parseHeader(input, index);
    while (header.major == 6) {
        // A tag adds no nesting; a strict reader refuses it.
        if (deterministic) return error.UnexpectedTag;
        header = try parseHeader(input, index);
    }
    if (deterministic) {
        if (header.indefinite or !isShortestHead(header)) return error.NonDeterministicEncoding;
        if (header.major == 7 and !isPreferredFloat(header)) return error.NonDeterministicEncoding;
        if (header.major == 7 and header.ai >= 25 and header.ai <= 27 and floatValue(header) == 0) zero.* = true;
    }
    if (refuse_zero and isNegativeZero(header)) return error.NegativeZero;
    switch (header.major) {
        0, 1, 7 => {},
        2, 3 => if (header.indefinite) {
            while (true) {
                if (index.* >= input.len) return error.UnexpectedEndOfInput;
                if (input[index.*] == 0xff) {
                    index.* += 1;
                    break;
                }
                const chunk = try parseHeader(input, index);
                if (chunk.major != header.major or chunk.indefinite) return error.InvalidStringChunk;
                try checkString(input, index, chunk, check != .read_trusted);
            }
        } else try checkString(input, index, header, check != .read_trusted),
        else => {
            if (depth >= max_nesting) return error.CborNestingTooDeep;
            const per: u64 = if (header.major == 5) 2 else 1;
            if (header.indefinite) {
                while (true) {
                    if (index.* >= input.len) return error.UnexpectedEndOfInput;
                    if (input[index.*] == 0xff) {
                        index.* += 1;
                        break;
                    }
                    var step: u64 = 0;
                    while (step < per) : (step += 1) try checkItem(input, index, depth + 1, deterministic, refuse_zero, zero, check);
                }
            } else {
                var order: KeyOrder = .{};
                var count: u64 = 0;
                while (count < header.value) : (count += 1) {
                    const key_start = index.*;
                    var key_zero = false;
                    try checkItem(input, index, depth + 1, deterministic, refuse_zero, &key_zero, check);
                    zero.* = zero.* or key_zero;
                    if (per == 2) {
                        if (deterministic) {
                            const key = input[key_start..index.*];
                            if (order.end != 0) {
                                const before = input[order.start..order.end];
                                if (check != .write and std.mem.eql(u8, before, key)) return error.DuplicateField;
                                if (!std.mem.lessThan(u8, before, key)) return error.NonDeterministicEncoding;
                            }
                            order.start = key_start;
                            order.end = index.*;
                            if (key_zero) try noteZeroKey(&order, key);
                        }
                        try checkItem(input, index, depth + 1, deterministic, refuse_zero, zero, check);
                    }
                }
            }
        },
    }
}

/// A key that holds a float zero: a float zero itself marks its sign in `order`, and both signs are one key
/// twice; any other key (an array or map) is refused.
fn noteZeroKey(order: *KeyOrder, key: []const u8) !void {
    if (key.len != 3 or key[0] != 0xf9) return error.NonDeterministicEncoding;
    order.zeros |= if (std.mem.readInt(u16, key[1..3], .big) == 0) 1 else 2;
    if (order.zeros == 3) return error.DuplicateField;
}

fn checkString(input: []const u8, index: *usize, header: Header, check_text: bool) !void {
    if (header.value > input.len - index.*) return error.UnexpectedEndOfInput;
    const end = index.* + @as(usize, @intCast(header.value));
    if (check_text and header.major == 3 and !bulk.validUtf8(input[index.*..end])) return error.InvalidUtf8;
    index.* = end;
}

/// Checks that `bytes` is exactly one well-formed CBOR item, and has no map with a repeated key.
pub fn validate(allocator: Allocator, bytes: []const u8) !void {
    try validateItem(allocator, bytes, false);
}

/// `validate`, refusing -0.0 (`error.NegativeZero`) when `refuse_zero`.
fn validateItem(allocator: Allocator, bytes: []const u8, refuse_zero: bool) !void {
    var d = CborDeserializer(ReadConfig).initBorrowed(allocator, bytes, .{ .refuse_negative_zero = refuse_zero });
    defer d.deinit(allocator);
    try d.skipItem(0);
    if (d.index != bytes.len) return error.TrailingCharacters;
}

/// The deterministic encoding (RFC 8949 §4.2.1 and §4.2.2) of the one well-formed item in
/// `bytes`: shortest heads, definite lengths, the shortest exact float, maps in the order of their
/// encoded keys, text and byte strings joined. It is what a strict read accepts, so a `cbor.Raw` or
/// an extras field read leniently can be written in a deterministic write after it. A tag is
/// `error.UnexpectedTag`, as a strict read refuses it, and a repeated key `error.DuplicateField`.
/// The caller owns the result.
pub fn canonicalize(allocator: Allocator, bytes: []const u8) ![]u8 {
    return canonicalizeItem(allocator, bytes, false);
}

/// `canonicalize` with the write options in `cfg` (a `WriteConfig`): with `normalize_negative_zero` a float zero is written as +0,
/// -0.0 included (RFC 8949 §4.2.2 keeps it as `0xf98000`), so the form is that of an item written with the option.
pub fn canonicalizeWith(allocator: Allocator, bytes: []const u8, comptime cfg: anytype) ![]u8 {
    return canonicalizeItem(allocator, bytes, readOption(cfg, "normalize_negative_zero", false));
}

fn canonicalizeItem(allocator: Allocator, bytes: []const u8, unsigned_zero: bool) ![]u8 {
    var d = CborDeserializer(ReadConfig).initBorrowed(allocator, bytes, .{});
    defer d.deinit(allocator);
    try d.skipItem(0);
    if (d.index != bytes.len) return error.TrailingCharacters;
    d.index = 0;
    d.canon_det = true;
    d.canon_zero = unsigned_zero;
    try d.canonicalItem();
    return allocator.dupe(u8, d.key_bytes.items);
}

/// The bytes of scratch `canonicalizeInto` needs for an item with at most `max_entries` map entries open at once
/// (the entries of a map and of the maps that hold it, all counted): eight bytes each, and the three bytes
/// that aligning the region may cost.
pub fn canonicalScratchSize(comptime max_entries: usize) usize {
    return max_entries * @sizeOf(MapEntry) + @alignOf(MapEntry) - 1;
}

/// Where a map entry is in the input: its key, and its value, which follows the key.
const MapEntry = struct { key: u32, value: u32 };

/// `canonicalize` into the caller's memory, with no allocator: the deterministic form of the one well-formed item
/// in `bytes` is written to the front of `dst` and returned. It is never longer than `bytes`, so a `dst` of that
/// length is enough (`error.NoSpaceLeft` otherwise). `scratch` holds an index of the entries of the maps being
/// written, 8 bytes each, which is how a map is put in key order without copying its entries: they are
/// written once, in order, from the input. `canonicalScratchSize(n)` is enough for `n` entries open at once, and
/// `error.OutOfMemory` says it was not. The nesting bound is `max_nesting`.
///
/// The result is what `canonicalize` gives for an item whose map keys are all scalars (integers, strings, floats,
/// simple values). A map key that is an array or a map is `error.UnexpectedType`, as in `PullReader`: ordering it
/// would need its own canonical form kept, which has no bound. A tag is `error.UnexpectedTag` and a repeated key,
/// including 0.0 and -0.0 (RFC 8949 section 5.6.1), is `error.DuplicateField`.
pub fn canonicalizeInto(dst: []u8, scratch: []u8, bytes: []const u8) ![]u8 {
    return canonicalizeIntoWith(dst, scratch, bytes, .{});
}

/// `canonicalizeInto` with the write options in `cfg` (a `WriteConfig`): with `normalize_negative_zero` a float zero is written as +0,
/// -0.0 included, and the keys are ordered as written.
pub fn canonicalizeIntoWith(dst: []u8, scratch: []u8, bytes: []const u8, comptime cfg: anytype) ![]u8 {
    if (bytes.len > std.math.maxInt(u32)) return error.InputTooLarge;
    const skip = std.mem.alignPointerOffset(scratch.ptr, @alignOf(MapEntry)) orelse scratch.len;
    const aligned = scratch[@min(skip, scratch.len)..];
    const entries: []MapEntry = @as([*]MapEntry, @ptrCast(@alignCast(aligned.ptr)))[0 .. aligned.len / @sizeOf(MapEntry)];
    var writer: CanonicalWriter = .{ .input = bytes, .dst = dst, .entries = entries, .unsigned_zero = readOption(cfg, "normalize_negative_zero", false) };
    var index: usize = 0;
    try writer.item(&index, 0);
    if (index != bytes.len) return error.TrailingCharacters;
    return dst[0..writer.out];
}

const CanonicalWriter = struct {
    input: []const u8,
    dst: []u8,
    out: usize = 0,
    entries: []MapEntry,
    /// Entries of the maps open now, which are `entries[0..top]`.
    top: usize = 0,
    /// Write a float zero as +0 (`canonicalizeIntoWith`).
    unsigned_zero: bool = false,

    /// The value of the float whose head is `header`, as this writer puts it out.
    fn float(self: *const CanonicalWriter, header: Header) f64 {
        return if (self.unsigned_zero) unsignedZero(floatValue(header)) else floatValue(header);
    }

    fn put(self: *CanonicalWriter, bytes: []const u8) !void {
        if (bytes.len > self.dst.len - self.out) return error.NoSpaceLeft;
        @memcpy(self.dst[self.out..][0..bytes.len], bytes);
        self.out += bytes.len;
    }

    fn putHead(self: *CanonicalWriter, major: u8, value: u64) !void {
        var head: [9]u8 = undefined;
        try self.put(head[0..writeHead(&head, major, value)]);
    }

    /// The canonical form of the item at `index.*`, which is left after it.
    fn item(self: *CanonicalWriter, index: *usize, depth: usize) anyerror!void {
        const header = try parseHeader(self.input, index);
        switch (header.major) {
            0, 1 => try self.putHead(header.major, header.value),
            2, 3 => {
                const total = try self.measure(index, header);
                try self.putHead(header.major, total);
                try self.copyString(index, header);
            },
            4 => {
                if (depth >= max_nesting) return error.CborNestingTooDeep;
                if (!header.indefinite) {
                    try self.putHead(4, try boundedItems(self.input, index.*, header.value, 1));
                    for (0..@intCast(header.value)) |_| try self.item(index, depth + 1);
                    return;
                }
                // The count is known at the break: the items go after one byte for the head, and move up if it is longer.
                const start = self.out;
                try self.put(&.{0});
                var count: u64 = 0;
                while (try moreItems(self.input, index)) : (count += 1) try self.item(index, depth + 1);
                var head: [9]u8 = undefined;
                const length = writeHead(&head, 4, count);
                if (length > 1) {
                    if (length - 1 > self.dst.len - self.out) return error.NoSpaceLeft;
                    const moved = self.out - start - 1;
                    @memmove(self.dst[start + length ..][0..moved], self.dst[start + 1 ..][0..moved]);
                    self.out += length - 1;
                }
                @memcpy(self.dst[start..][0..length], head[0..length]);
            },
            5 => try self.map(index, header, depth),
            6 => return error.UnexpectedTag,
            else => switch (header.ai) {
                25, 26, 27 => {
                    var buffer: [9]u8 = undefined;
                    var fixed = std.Io.Writer.fixed(&buffer);
                    try writePreferredFloat(&fixed, self.float(header));
                    try self.put(fixed.buffered());
                },
                else => try self.putHead(7, header.value),
            },
        }
    }

    /// The map whose head is `header`: its entries are indexed by position in the input, sorted by the canonical
    /// form of their keys, then written once each, in that order.
    fn map(self: *CanonicalWriter, index: *usize, header: Header, depth: usize) anyerror!void {
        if (depth >= max_nesting) return error.CborNestingTooDeep;
        const base = self.top;
        defer self.top = base;
        var zero = false;
        var signs: u2 = 0;
        var count: u64 = 0;
        const definite = !header.indefinite;
        const expected = if (definite) try boundedItems(self.input, index.*, header.value, 2) else 0;
        while (if (definite) count < expected else try moreItems(self.input, index)) : (count += 1) {
            const key = index.*;
            var cursor = key;
            const key_head = try parseHeader(self.input, &cursor);
            switch (key_head.major) {
                4, 5 => return error.UnexpectedType,
                6 => return error.UnexpectedTag,
                // 0.0 and -0.0 are one key (RFC 8949 section 5.6.1) and are written differently, so not always neighbours.
                7 => if (key_head.ai >= 25 and key_head.ai <= 27 and floatValue(key_head) == 0) {
                    signs |= if (std.math.signbit(floatValue(key_head))) 2 else 1;
                    if (signs == 3) return error.DuplicateField;
                },
                else => {},
            }
            try checkItem(self.input, index, depth + 1, false, false, &zero, .write);
            const value = index.*;
            try checkItem(self.input, index, depth + 1, false, false, &zero, .write);
            if (self.top == self.entries.len) return error.OutOfMemory;
            self.entries[self.top] = .{ .key = @intCast(key), .value = @intCast(value) };
            self.top += 1;
        }
        const mine = self.entries[base..self.top];
        std.sort.pdq(MapEntry, mine, self, entryLess);
        for (mine[@min(1, mine.len)..], 0..) |entry, at| {
            if (try self.keyOrder(mine[at].key, entry.key) == .eq) return error.DuplicateField;
        }

        try self.putHead(5, mine.len);
        const end = index.*;
        for (mine) |entry| {
            var at: usize = entry.key;
            try self.item(&at, depth + 1);
            at = entry.value;
            try self.item(&at, depth + 1);
        }
        index.* = end;
    }

    fn entryLess(self: *CanonicalWriter, a: MapEntry, b: MapEntry) bool {
        // The keys were checked when they were indexed, so the order of two cannot fail.
        return (self.keyOrder(a.key, b.key) catch unreachable) == .lt;
    }

    /// The order of the canonical forms of the scalar keys at two input positions, compared as bytes: the head,
    /// which says the type and the length, and then the content of a string, which may be in chunks.
    fn keyOrder(self: *CanonicalWriter, a: u32, b: u32) !std.math.Order {
        const x = try self.keyImage(a);
        const y = try self.keyImage(b);
        const heads = std.mem.order(u8, x.head[0..x.head_len], y.head[0..y.head_len]);
        if (heads != .eq) return heads;
        return self.contentOrder(x, y);
    }

    const KeyImage = struct {
        head: [9]u8 = undefined,
        head_len: usize = 0,
        /// Where the content is: the bytes of a definite string, else the first chunk head of a chunked one.
        content: usize = 0,
        content_len: usize = 0,
        chunked: bool = false,
    };

    fn keyImage(self: *CanonicalWriter, at: usize) !KeyImage {
        var cursor = at;
        const header = try parseHeader(self.input, &cursor);
        var image: KeyImage = .{};
        switch (header.major) {
            0, 1 => image.head_len = writeHead(&image.head, header.major, header.value),
            2, 3 => {
                const total = try self.measure(&cursor, header);
                image.head_len = writeHead(&image.head, header.major, total);
                image.content = cursor;
                image.content_len = @intCast(total);
                image.chunked = header.indefinite;
            },
            7 => switch (header.ai) {
                25, 26, 27 => {
                    var fixed = std.Io.Writer.fixed(&image.head);
                    try writePreferredFloat(&fixed, self.float(header));
                    image.head_len = fixed.end;
                },
                else => image.head_len = writeHead(&image.head, 7, header.value),
            },
            else => return error.UnexpectedType,
        }
        return image;
    }

    fn contentOrder(self: *CanonicalWriter, x: KeyImage, y: KeyImage) !std.math.Order {
        var left: ChunkCursor = .{ .input = self.input, .at = x.content, .chunked = x.chunked };
        var right: ChunkCursor = .{ .input = self.input, .at = y.content, .chunked = y.chunked };
        var remaining = x.content_len;
        while (remaining != 0) {
            const a = try left.piece(remaining);
            const b = try right.piece(remaining);
            const take = @min(a.len, b.len);
            const order = std.mem.order(u8, a[0..take], b[0..take]);
            if (order != .eq) return order;
            left.advance(take);
            right.advance(take);
            remaining -= take;
        }
        return .eq;
    }

    /// The length of the string whose head is `header`, which is the sum of its chunks if it has any.
    /// `index.*`, after the head, is not moved: it is at the content of a definite string, or the first chunk head.
    fn measure(self: *CanonicalWriter, index: *usize, header: Header) !u64 {
        if (!header.indefinite) {
            if (header.value > self.input.len - index.*) return error.UnexpectedEndOfInput;
            return header.value;
        }
        var cursor = index.*;
        var total: u64 = 0;
        while (try moreItems(self.input, &cursor)) {
            const chunk = try parseHeader(self.input, &cursor);
            if (chunk.major != header.major or chunk.indefinite) return error.InvalidStringChunk;
            if (chunk.value > self.input.len - cursor) return error.UnexpectedEndOfInput;
            cursor += @intCast(chunk.value);
            total += chunk.value;
        }
        return total;
    }

    /// Writes the content of the string whose head is `header`, `index.*` being after it, checking text as
    /// UTF-8, and leaves `index.*` after the string.
    fn copyString(self: *CanonicalWriter, index: *usize, header: Header) !void {
        if (!header.indefinite) {
            const raw = self.input[index.*..][0..@intCast(header.value)];
            if (header.major == 3 and !bulk.validUtf8(raw)) return error.InvalidUtf8;
            try self.put(raw);
            index.* += raw.len;
            return;
        }
        while (try moreItems(self.input, index)) {
            const chunk = try parseHeader(self.input, index);
            const raw = self.input[index.*..][0..@intCast(chunk.value)];
            if (header.major == 3 and !bulk.validUtf8(raw)) return error.InvalidUtf8;
            try self.put(raw);
            index.* += raw.len;
        }
    }
};

/// The bytes of a string's content, which may be in chunks, read piece by piece.
const ChunkCursor = struct {
    input: []const u8,
    at: usize,
    chunked: bool,
    left: usize = 0,

    /// The next bytes, at most `most` of them.
    fn piece(self: *ChunkCursor, most: usize) ![]const u8 {
        if (!self.chunked) return self.input[self.at..][0..most];
        while (self.left == 0) {
            const chunk = try parseHeader(self.input, &self.at);
            self.left = @intCast(chunk.value);
        }
        return self.input[self.at..][0..self.left];
    }

    fn advance(self: *ChunkCursor, count: usize) void {
        self.at += count;
        if (self.chunked) self.left -= count;
    }
};

/// The number of items of a definite container at `index`, which cannot be more than the input has bytes
/// left at `per_item` each.
fn boundedItems(input: []const u8, index: usize, count: u64, per_item: usize) !u64 {
    if (count > (input.len - index) / per_item) return error.UnexpectedEndOfInput;
    return count;
}

/// Whether an indefinite-length container has another item, consuming its break if not.
fn moreItems(input: []const u8, index: *usize) !bool {
    if (index.* >= input.len) return error.UnexpectedEndOfInput;
    if (input[index.*] != 0xff) return true;
    index.* += 1;
    return false;
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

        /// The whole item as a `T`, read by the typed layer with the deserializer's mode and limits and
        /// `serde_cfg`: for a decode hook whose type is a schema type with some fixed layout around
        /// it. Only before the first event; it takes the item, so the reader is done after it.
        pub fn readTyped(self: *Self, comptime T: type, allocator: Allocator, comptime serde_cfg: anytype) !T {
            self.release();
            if (self.done or self.d.stack_len != self.base) return error.InvalidCborState;
            const value = try typed.deserialize(T, allocator, self.d, serde_cfg);
            self.done = self.d.stack_len == self.base;
            return value;
        }

        /// The caller's word set on the deserializer (`user_data`), such as the base address of the
        /// spans a wire type writes.
        pub fn userData(self: *const Self) usize {
            return self.d.user_data;
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

        /// The next value whole, as the bytes it was read from: what `readRaw` gives a `Raw` field. For
        /// a wire type's decode hook, which can return the span it consumed. Call it where a value is
        /// expected, as `next` would return one. The item is checked as the mode and limits say, and
        /// the bytes are valid as long as the input is. An end or a map key where a value is due is
        /// `error.UnexpectedType`.
        pub fn raw(self: *Self) ![]const u8 {
            self.release();
            const d = self.d;
            if (d.stack_len == self.base) {
                if (self.done) return error.UnexpectedEndOfInput;
                const token = try d.readRaw(self.allocator);
                self.done = d.stack_len == self.base;
                return token.bytes;
            }
            const depth = d.stack_len - 1;
            switch (d.current().kind) {
                .array => {
                    if (!try d.nextArrayItem()) {
                        self.done = d.stack_len == self.base;
                        return error.UnexpectedType;
                    }
                },
                .object => {
                    if (!self.want_value[depth]) return error.UnexpectedType;
                    self.want_value[depth] = false;
                },
            }
            return (try d.readRaw(self.allocator)).bytes;
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
            d.uncountItem();
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
/// `cfg` may set `deterministic`, `trusted_text` and `max_container_bytes`: the most output one open container may hold
/// (default unbounded). A container is held whole because a map is sorted when it closes and a length precedes its items,
/// so this is the bound of the one place the writer buffers: a write that would pass it is `error.ContainerTooLarge`,
/// before anything is allocated for it. Output at the top level goes straight to `writer` and is not counted.
pub fn valueWriter(allocator: Allocator, writer: *std.Io.Writer, comptime cfg: anytype) ValueWriter {
    var result = ValueWriter.init(allocator, writer, effectiveDeterministic(cfg), readOption(cfg, "trusted_text", false));
    result.max_container_bytes = readOption(cfg, "max_container_bytes", std.math.maxInt(usize));
    result.normalize_zero = readOption(cfg, "normalize_negative_zero", false);
    return result;
}

/// A writer for a wire type's encode hook: items go out as they are written, with no buffering and
/// no allocation, and it keeps the guarantees of `ValueWriter` that it can without either:
///
/// - a container's length is stated up front (twice as many items for a map, keys and values
///   alternately) and met exactly: one more item, or an end before the last, is `error.LengthMismatch`;
/// - nesting is at most 128 (`error.CborNestingTooDeep`) and `finish` says the one item is complete;
/// - text is UTF-8 (`error.InvalidUtf8`) and `writeRaw` takes one well-formed item, in the
///   deterministic form when the write is deterministic (see `canonicalize` for making one);
/// - with `deterministic`, a map's keys come in ascending order of their encoded bytes, each after
///   the one before (`error.NonDeterministicEncoding`; a repeated key is `error.DuplicateField`).
///   Such a key is a scalar or a `writeRaw` item, at most `key_capacity` bytes encoded, because the
///   writer keeps the key before it to compare (`error.KeyTooLong`). Without `deterministic` keys
///   are written as given.
///
/// The ends only check; they are there so a hook reads the same for every format.
pub const Encoder = struct {
    writer: *std.Io.Writer,
    deterministic: bool,
    trusted_text: bool = false,
    /// Write a float zero as +0 (`WriteConfig.normalize_negative_zero`).
    normalize_zero: bool = false,
    frames: [max_nesting]Frame = undefined,
    depth: usize = 0,
    root_done: bool = false,
    /// The encoded keys last written by the maps that are open, one after another: a map keeps the
    /// key before the one being written at `Frame.keys`, and the next map's start is after it.
    key_buf: [key_capacity]u8 = undefined,
    key_top: usize = 0,

    /// The most an encoded map key can take in a deterministic write, with the key before it.
    pub const key_capacity = 1024;

    const Frame = struct {
        kind: ContainerKind,
        /// Items still to write: elements, or keys and values.
        remaining: u64,
        /// Where this map's previous key starts in `key_buf` and how long it is.
        keys: usize = 0,
        prev_len: usize = 0,
    };

    pub fn writeNull(self: *Encoder) !void {
        try self.put(writeBytesOf, .{&[_]u8{0xf6}});
    }

    pub fn writeBool(self: *Encoder, value: bool) !void {
        try self.put(writeBytesOf, .{if (value) &[_]u8{0xf5} else &[_]u8{0xf4}});
    }

    pub fn writeInt(self: *Encoder, value: i128) !void {
        try self.put(encodeInt, .{value});
    }

    pub fn writeFloat(self: *Encoder, value: f64) !void {
        const written = if (self.normalize_zero) unsignedZero(value) else value;
        if (self.deterministic) try self.put(writePreferredFloat, .{written}) else try self.put(encodeFloat, .{written});
    }

    pub fn writeText(self: *Encoder, value: []const u8) !void {
        try self.put(encodeText, .{ value, self.trusted_text });
    }

    pub fn writeBytes(self: *Encoder, value: []const u8) !void {
        try self.put(writeByteString, .{value});
    }

    /// An item that is already CBOR: one well-formed item, and in a deterministic write one that
    /// is deterministic (`error.NonDeterministicEncoding`, `error.UnexpectedTag`).
    pub fn writeRaw(self: *Encoder, bytes: []const u8) !void {
        try verifyItem(bytes, self.deterministic, self.normalize_zero);
        try self.put(writeBytesOf, .{bytes});
    }

    pub fn beginArray(self: *Encoder, len: usize) !void {
        try self.open(.array, 4, len, len);
    }

    pub fn endArray(self: *Encoder) !void {
        try self.close(.array);
    }

    pub fn beginMap(self: *Encoder, len: usize) !void {
        const items = std.math.mul(u64, len, 2) catch return error.LengthMismatch;
        try self.open(.object, 5, len, items);
    }

    pub fn endMap(self: *Encoder) !void {
        try self.close(.object);
    }

    /// After the item: it is complete, and nothing is open.
    pub fn finish(self: *Encoder) !void {
        if (self.depth != 0 or !self.root_done) return error.LengthMismatch;
    }

    /// Writes one scalar with `write(writer, args...)`. A key of a deterministic map is encoded into
    /// the key buffer first, compared with the key before it, and then written.
    fn put(self: *Encoder, comptime write: anytype, args: anytype) !void {
        try self.beginItem();
        if (self.keyPosition()) {
            const frame = &self.frames[self.depth - 1];
            const start = frame.keys + frame.prev_len;
            var fixed = std.Io.Writer.fixed(self.key_buf[start..]);
            @call(.auto, write, .{&fixed} ++ args) catch |err| return if (err == error.WriteFailed) error.KeyTooLong else err;
            try self.acceptKey(frame, fixed.buffered().len);
        } else {
            try @call(.auto, write, .{self.writer} ++ args);
        }
        self.endItem();
    }

    /// Checks the room for one more item, and that it is not an array or map where a key goes.
    fn beginItem(self: *Encoder) !void {
        if (self.depth == 0) {
            if (self.root_done) return error.LengthMismatch;
            return;
        }
        if (self.frames[self.depth - 1].remaining == 0) return error.LengthMismatch;
    }

    fn endItem(self: *Encoder) void {
        if (self.depth == 0) {
            self.root_done = true;
        } else {
            self.frames[self.depth - 1].remaining -= 1;
        }
    }

    /// Whether the next item is a map key whose place in the order is checked.
    fn keyPosition(self: *const Encoder) bool {
        if (!self.deterministic or self.depth == 0) return false;
        const frame = &self.frames[self.depth - 1];
        return frame.kind == .object and frame.remaining % 2 == 0;
    }

    /// The key just encoded at `key_buf[start..][0..len]` must sort after the one before it; it
    /// then takes that one's place, and goes out.
    fn acceptKey(self: *Encoder, frame: *Frame, len: usize) !void {
        const start = frame.keys + frame.prev_len;
        const key = self.key_buf[start..][0..len];
        if (frame.prev_len != 0) {
            const before = self.key_buf[frame.keys..][0..frame.prev_len];
            if (std.mem.eql(u8, before, key)) return error.DuplicateField;
            if (!std.mem.lessThan(u8, before, key)) return error.NonDeterministicEncoding;
        }
        try self.writer.writeAll(key);
        std.mem.copyForwards(u8, self.key_buf[frame.keys..][0..len], key);
        frame.prev_len = len;
        self.key_top = frame.keys + len;
    }

    fn open(self: *Encoder, kind: ContainerKind, major: u8, len: usize, items: u64) !void {
        try self.beginItem();
        if (self.keyPosition()) return error.UnexpectedType;
        if (self.depth >= self.frames.len) return error.CborNestingTooDeep;
        try writeMajorValue(self.writer, major, len);
        self.frames[self.depth] = .{ .kind = kind, .remaining = items, .keys = self.key_top };
        self.depth += 1;
    }

    fn close(self: *Encoder, kind: ContainerKind) !void {
        if (self.depth == 0 or self.frames[self.depth - 1].kind != kind) return error.UnbalancedContainers;
        const frame = &self.frames[self.depth - 1];
        if (frame.remaining != 0) return error.LengthMismatch;
        self.key_top = frame.keys;
        self.depth -= 1;
        self.endItem();
    }
};

fn writeBytesOf(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeAll(bytes);
}

fn writeByteString(writer: *std.Io.Writer, value: []const u8) !void {
    try writeMajorValue(writer, 2, value.len);
    try writer.writeAll(value);
}

// The writer's methods share these names, so the file-level writers get others.
const encodeInt = writeInt;
const encodeFloat = writeFloat;

pub const ValueWriter = struct {
    allocator: Allocator,
    out: *std.Io.Writer,
    deterministic: bool,
    trusted_text: bool = false,
    /// Write a float zero as +0 (`WriteConfig.normalize_negative_zero`).
    normalize_zero: bool = false,
    max_container_bytes: usize = std.math.maxInt(usize),
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

    fn init(allocator: Allocator, writer: *std.Io.Writer, deterministic: bool, trusted_text: bool) ValueWriter {
        return .{ .allocator = allocator, .out = writer, .deterministic = deterministic, .trusted_text = trusted_text };
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

    /// Refuses `add` bytes more in the container being written when they would pass `max_container_bytes`.
    fn room(self: *ValueWriter, add: usize) !void {
        if (self.depth == 0) return;
        const used = self.frames[self.depth - 1].buf.written().len;
        if (add > self.max_container_bytes -| used) return error.ContainerTooLarge;
    }

    pub fn writeNull(self: *ValueWriter) !void {
        try self.beforeItem();
        try self.room(1);
        try self.sink().writeByte(0xf6);
        try self.afterItem();
    }

    pub fn writeBool(self: *ValueWriter, value: bool) !void {
        try self.beforeItem();
        try self.room(1);
        try self.sink().writeByte(if (value) 0xf5 else 0xf4);
        try self.afterItem();
    }

    pub fn writeInt(self: *ValueWriter, value: i128) !void {
        try self.beforeItem();
        try self.room(9);
        try encodeInt(self.sink(), value);
        try self.afterItem();
    }

    pub fn writeFloat(self: *ValueWriter, value: f64) !void {
        try self.beforeItem();
        try self.room(9);
        const written = if (self.normalize_zero) unsignedZero(value) else value;
        if (self.deterministic) try writePreferredFloat(self.sink(), written) else try encodeFloat(self.sink(), written);
        try self.afterItem();
    }

    pub fn writeText(self: *ValueWriter, value: []const u8) !void {
        try self.beforeItem();
        try self.room(9 + value.len);
        try encodeText(self.sink(), value, self.trusted_text);
        try self.afterItem();
    }

    pub fn writeBytes(self: *ValueWriter, value: []const u8) !void {
        try self.beforeItem();
        try self.room(9 + value.len);
        const out = self.sink();
        try writeMajorValue(out, 2, value.len);
        try out.writeAll(value);
        try self.afterItem();
    }

    /// Writes an item that is already CBOR: a `Raw` that was read, say. It is checked, and a
    /// deterministic writer puts it in the deterministic form first (`canonicalize`), so a Raw read
    /// leniently comes out as a strict read accepts it.
    pub fn writeRaw(self: *ValueWriter, bytes: []const u8) !void {
        try self.beforeItem();
        // The canonical form is never longer than the item, so its length bounds both.
        try self.room(bytes.len);
        if (self.deterministic) {
            const canonical = try canonicalizeItem(self.allocator, bytes, self.normalize_zero);
            defer self.allocator.free(canonical);
            try self.sink().writeAll(canonical);
        } else {
            try validateItem(self.allocator, bytes, self.normalize_zero);
            try self.sink().writeAll(bytes);
        }
        try self.afterItem();
    }

    pub fn beginArray(self: *ValueWriter) !void {
        try self.begin(.array);
    }

    pub fn endArray(self: *ValueWriter) !void {
        const frame = try self.closing(.array);
        try self.parentRoom(9 + frame.buf.written().len);
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
        try self.parentRoom(9 + frame.buf.written().len);
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

    /// `room` for the container around the innermost one, which takes the innermost one's output when it closes.
    fn parentRoom(self: *ValueWriter, add: usize) !void {
        if (self.depth <= 1) return;
        const used = self.frames[self.depth - 2].buf.written().len;
        if (add > self.max_container_bytes -| used) return error.ContainerTooLarge;
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
    var deserializer = try sliceDeserializer(allocator, input, read_cfg);
    defer deserializer.deinit(allocator);
    // The caller's whole configuration applies; only the aliasing is added.
    deserializer.can_borrow_strings = true;
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

/// Reads one head and checks that it is well-formed: a reserved additional-info value, an
/// indefinite length on a type that has none, and a two-byte simple value below 32 are all refused
/// (RFC 8949 §3.3 and Appendix C). A length written longer than it needs to be is accepted.
pub fn parseHeader(input: []const u8, cursor: *usize) !Header {
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

/// A text string is UTF-8 (RFC 8949 §3.1): bytes that are not would write output no reader accepts,
/// unless the caller has said the text is known to be valid.
fn encodeText(writer: *std.Io.Writer, value: []const u8, trusted: bool) !void {
    if (!trusted and !bulk.validUtf8(value)) return error.InvalidUtf8;
    try writeMajorValue(writer, 3, value.len);
    try writer.writeAll(value);
}

/// A text string known when the code is compiled, a field name or an enum name: checked as UTF-8 then, and written
/// head and text at once.
fn writeName(writer: *std.Io.Writer, comptime name: []const u8) !void {
    if (comptime !std.unicode.utf8ValidateSlice(name)) @compileError("the name `" ++ name ++ "` is not valid UTF-8");
    try writer.writeAll(comptime encodeKey(.{ .text = name }));
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
pub fn isShortestHead(header: Header) bool {
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
pub fn isPreferredFloat(header: Header) bool {
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
