//! Format-independent typed walk.
//!
//! This layer reflects on `T` with `@typeInfo` and drives a format backend
//! through a small serializer/deserializer protocol. The backend knows how to
//! emit or read one concrete format; this file knows how to walk arbitrary Zig
//! data structures.
//!
//! A deserializer refuses an object that names a key twice (`error.DuplicateField`) at the latest when the object ends; the
//! typed layer checks only declared fields (`seen`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic_mod = @import("diagnostic.zig");
const meta = @import("meta.zig");
const sorted = @import("sorted.zig");
const bulk = @import("bulk.zig");
const resume_read = @import("typed_resume.zig");

pub const Error = Allocator.Error || error{
    UnsupportedType,
    UnexpectedType,
    UnknownField,
    MissingField,
    DuplicateField,
    IntegerOverflow,
    /// A finite input does not fit the target float type, so narrowing would give an infinity.
    FloatOutOfRange,
    InvalidEnumTag,
    LengthMismatch,
    /// A field's length (`min_len`, `max_len`) is outside its bounds.
    LengthOutOfBounds,
    /// A decode hook left part of its item unread.
    HookIncomplete,
    /// A field's integer value (`min`, `max`) is outside its bounds.
    ValueOutOfRange,
};

/// A variable-length byte string.
///
/// `[]const u8` is text and `[N]u8` is a fixed-length byte string, so a byte string whose length
/// is only known at run time needs its own type for the format to tell the two apart. It is
/// written as a CBOR byte string, a MessagePack `bin`, a BSON binary and a JSON string in the
/// configured `bytes` encoding, and read only from the same kind of token. `zerde.free` releases
/// it like any other slice.
pub const ByteString = struct {
    bytes: []const u8,
};

/// The formats that keep an item as its bytes.
pub const RawFormat = enum { cbor, json };

/// One data item of one format, validated and kept as its own bytes instead of being decoded:
/// `cbor.Raw` is a CBOR item, `json.Raw` is JSON text. The format is in the type, so a `Raw` of
/// one format cannot be written in another (that does not compile). Reading checks it as the read's
/// mode and limits say (a strict read refuses a non-deterministic item inside it) and returns
/// exactly the bytes that were read; a write checks it again and puts it back, in canonical form
/// when the write is deterministic. `zerde.free` releases it like any slice.
pub fn RawOf(comptime format: RawFormat) type {
    return struct {
        bytes: []const u8,

        pub const zerde_raw_format = format;
    };
}

/// Whether `T` is a `SortedMap`; see `sorted.zig`.
pub const isSortedMap = sorted.isSortedMap;

/// Whether `T` is a `Raw` of some format.
pub fn isRaw(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zerde_raw_format");
}

/// Whether `T` is a `Raw`, or an optional one: what an extras field may be.
pub fn isRawOrOptional(comptime T: type) bool {
    return isRaw(T) or (@typeInfo(T) == .optional and isRaw(@typeInfo(T).optional.child));
}

/// One step of a pull read: a scalar, or the start or end of an array or map. A map's events are
/// its keys and values alternately, so a key is the event before its value. A text or byte string
/// is valid until the next call.
pub const Event = union(enum) {
    null,
    bool: bool,
    integer: i128,
    float: f64,
    text: []const u8,
    bytes: []const u8,
    /// The element count when the format states it (a definite CBOR array), else null.
    array_begin: ?usize,
    array_end,
    /// The entry count when the format states it (a definite CBOR map), else null.
    map_begin: ?usize,
    map_end,
};

pub const ValueKind = enum {
    null,
    bool,
    number,
    string,
    bytes,
    array,
    object,
};

/// Numeric token returned by format backends before the typed layer casts it to `T`.
pub const Number = union(enum) {
    integer: i128,
    float: f64,
};

pub const ObjectFieldLookup = union(enum) {
    end,
    field_index: usize,
    unknown,
};

/// String token that may either borrow input bytes or own a freshly allocated buffer.
pub const StringToken = struct {
    bytes: []const u8,
    allocated: bool,

    pub fn deinit(self: StringToken, allocator: Allocator) void {
        if (self.allocated) allocator.free(@constCast(self.bytes));
    }
};

/// Frees values produced by the owning parse paths.
/// Aliased slice parses should instead be released by dropping the input and allocator scope together.
pub fn free(allocator: Allocator, value: anytype) void {
    freeTyped(@TypeOf(value), allocator, value);
}

/// Entry point used by `root.zig` once a format module has been selected.
pub fn serialize(comptime Format: type, writer: *std.Io.Writer, value: anytype, comptime serde_cfg: anytype, comptime format_cfg: anytype) !void {
    var serializer = Format.serializer(writer, format_cfg);
    defer if (@hasDecl(@TypeOf(serializer), "deinit")) serializer.deinit();
    try serializeValue(&serializer, value, serde_cfg, Format, comptime fieldOrderPolicy(Format, format_cfg), NoResume{});
}

/// `serialize` with a serializer the caller made and keeps, for a format that has state to set up first (a gather write).
pub fn serializeInto(serializer: anytype, value: anytype, comptime serde_cfg: anytype, comptime Format: type, comptime format_cfg: anytype) !void {
    try serializeValue(serializer, value, serde_cfg, Format, comptime fieldOrderPolicy(Format, format_cfg), NoResume{});
}

/// One step of a resumable write: `value` into the window `state.window` is the writer of, with `serializer` (which
/// is kept between steps, since the JSON one holds where it is). `error.WindowFull` says the window is full at a
/// token and the step is to be repeated with a fresh window, the same `value` and `state`; success says the value
/// is written.
pub fn serializeResumable(
    serializer: anytype,
    value: anytype,
    comptime serde_cfg: anytype,
    comptime Format: type,
    comptime format_cfg: anytype,
    state: *ResumeState,
) !void {
    try serializeValue(serializer, value, serde_cfg, Format, comptime fieldOrderPolicy(Format, format_cfg), state);
}

/// Copies what of `bytes[at.*..]` fits in the spare room of the fixed writer `w`, and says `error.WindowFull`
/// when that is not all of it.
pub fn copyPart(w: *std.Io.Writer, bytes: []const u8, at: *usize) error{WindowFull}!void {
    const room = w.buffer.len - w.end;
    const count = @min(room, bytes.len - at.*);
    @memcpy(w.buffer[w.end..][0..count], bytes[at.*..][0..count]);
    w.end += count;
    at.* += count;
    if (at.* < bytes.len) return error.WindowFull;
}

/// The format's field order for this write. A format declares `fieldOrderPolicy` when its config
/// can change the order, as deterministic CBOR does; every other format writes declaration order.
fn fieldOrderPolicy(comptime Format: type, comptime format_cfg: anytype) meta.FieldOrderPolicy {
    if (@hasDecl(Format, "fieldOrderPolicy")) return Format.fieldOrderPolicy(format_cfg);
    return .{};
}

/// Indexes of `T`'s fields in the order they are written.
pub fn structFieldOrder(
    comptime T: type,
    comptime Format: type,
    comptime info: std.builtin.Type.Struct,
    comptime cfg: anytype,
    comptime policy: meta.FieldOrderPolicy,
) [info.field_names.len]usize {
    const count = info.field_names.len;
    var order: [count]usize = undefined;
    for (0..count) |index| order[index] = index;
    const field_order = meta.effectiveFieldOrder(T, cfg, policy);
    if (field_order == .declaration) return order;

    // Resolve the sort keys once: the sort compares O(n^2) pairs, and resolving a key inside the
    // comparison exceeds the comptime branch quota on small structs.
    var sort_keys: [count][]const u8 = undefined;
    for (0..count) |index| {
        const key = meta.effectiveFieldKey(T, info.field_names[index], cfg);
        sort_keys[index] = switch (field_order) {
            .declaration => unreachable,
            .encoded_key => if (@hasDecl(Format, "encodeKey"))
                Format.encodeKey(key)
            else
                @compileError(@typeName(Format) ++ " does not define the encoded form of a key, so it cannot use field_order .encoded_key"),
            .length_first, .bytewise => switch (key) {
                .text => |name| name,
                .integer => @compileError(@typeName(T) ++ "." ++ info.field_names[index] ++ " has an integer key; use field_order .encoded_key or .declaration"),
            },
        };
    }

    // Insertion sort: stable, and field counts are small.
    var i: usize = 1;
    while (i < count) : (i += 1) {
        var j = i;
        while (j > 0 and keyLess(field_order, sort_keys[order[j]], sort_keys[order[j - 1]])) : (j -= 1) {
            const swap = order[j - 1];
            order[j - 1] = order[j];
            order[j] = swap;
        }
    }
    return order;
}

fn keyLess(comptime field_order: meta.FieldOrder, a: []const u8, b: []const u8) bool {
    return switch (field_order) {
        .declaration => false,
        .length_first => if (a.len != b.len) a.len < b.len else std.mem.lessThan(u8, a, b),
        .bytewise, .encoded_key => std.mem.lessThan(u8, a, b),
    };
}

/// Entry point used by `root.zig` once a format-specific deserializer has been created.
pub fn deserialize(comptime T: type, allocator: Allocator, deserializer: anytype, comptime cfg: anytype) anyerror!T {
    var result: T = undefined;
    try deserializeValue(TypedSink{}, T, &result, allocator, deserializer, cfg, null, false, NoRead{});
    return result;
}

pub fn deserializeWithDiagnostics(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
) anyerror!T {
    var result: T = undefined;
    try deserializeValue(TypedSink{}, T, &result, allocator, deserializer, cfg, diagnostics, true, NoRead{});
    return result;
}

/// Where a resumable write is. A write into a window that fills up stops at a token and keeps, for each open
/// container, how far it got, so the next call descends the same path and goes on: nothing is written twice and
/// nothing is sorted or buffered. The state is a few words per open container and lives in the caller's value.
pub const Level = struct {
    /// The container's opening token is written.
    entered: bool = false,
    /// A struct field's `beginStructField` result: whether its value follows.
    flag: bool = false,
    /// Where in the current item it is: 0 not started, 1 its value is being written.
    phase: u8 = 0,
    /// The items or fields that are complete.
    index: u32 = 0,
};

/// How far a long string, byte string or `Raw` is: bytes of the source written, and whether its head is.
pub const TextState = struct { at: usize = 0, started: bool = false };

/// The most containers a resumable write holds open at once.
pub const resume_max_depth = 128;

/// The most bytes any token of a resumable write takes, that a window must have room for (a number, a head, a
/// bracket, a float: at most 25 bytes of JSON for an `f64`, 41 for an `f128`, 9 of CBOR); a name adds its own, which
/// `keyRoom` counts.
pub const atomic_room = 64;

/// Marks a write that is not resumable: every resume step compiles to nothing.
pub const NoResume = struct {};

/// The state of a resumable write; see `Level`. `window` is the writer the serializer writes into for this call.
pub const ResumeState = struct {
    levels: [resume_max_depth]Level = @splat(.{}),
    depth: usize = 0,
    window: ?*std.Io.Writer = null,
    leaf: TextState = .{},

    fn enter(self: *ResumeState) error{ResumeTooDeep}!*Level {
        if (self.depth == self.levels.len) return error.ResumeTooDeep;
        self.depth += 1;
        return &self.levels[self.depth - 1];
    }

    fn leave(self: *ResumeState) void {
        self.depth -= 1;
    }

    /// Stops at a token when the window has less than `n` bytes left.
    pub fn reserve(self: *const ResumeState, n: usize) error{WindowFull}!void {
        const w = self.window.?;
        if (w.buffer.len - w.end < n) return error.WindowFull;
    }
};

fn reserveRoom(rc: anytype, comptime n: usize) !void {
    if (comptime @TypeOf(rc) != NoResume) try rc.reserve(n);
}

/// The room a struct field's or union variant's key can take on the wire: the escaped name, or a number.
fn keyRoom(comptime key: meta.FieldKey) usize {
    return atomic_room + switch (key) {
        .text => |name| 6 * name.len,
        .integer => 0,
    };
}

/// Writes a string, byte string or `Raw`: whole, or for a resumable write as far as the window goes, which is
/// `error.WindowFull` with `rc.leaf` saying where to go on.
fn emitText(serializer: anytype, rc: anytype, comptime kind: enum { string, bytes, bytes_inline, raw }, bytes: []const u8) !void {
    const SerializerType = @TypeOf(serializer.*);
    if (comptime @TypeOf(rc) == NoResume) {
        switch (kind) {
            .string => try serializer.emitString(bytes),
            .bytes => try emitByteString(serializer, bytes),
            .bytes_inline => if (@hasDecl(SerializerType, "emitBytesInline")) try serializer.emitBytesInline(bytes) else try emitByteString(serializer, bytes),
            .raw => try serializer.emitRaw(bytes),
        }
        return;
    }
    const part = switch (kind) {
        .string => "emitStringPart",
        .bytes, .bytes_inline => if (@hasDecl(SerializerType, "emitBytesPart")) "emitBytesPart" else "emitStringPart",
        .raw => "emitRawPart",
    };
    if (comptime !@hasDecl(SerializerType, part)) @compileError("format " ++ @typeName(SerializerType) ++ " has no resumable " ++ part);
    try @field(SerializerType, part)(serializer, bytes, &rc.leaf);
    rc.leaf = .{};
}

/// `serialize` into a window that may fill: with `rc` a `*ResumeState` it returns `error.WindowFull` at a token,
/// and a call with the same value and state goes on from there.
fn serializeValue(
    serializer: anytype,
    value: anytype,
    comptime cfg: anytype,
    comptime Format: type,
    comptime order_policy: meta.FieldOrderPolicy,
    rc: anytype,
) anyerror!void {
    const T = @TypeOf(value);
    const SerializerType = @TypeOf(serializer.*);
    const resumable = comptime @TypeOf(rc) != NoResume;
    if (comptime hasHook(T, "zerdeEncode")) {
        if (comptime resumable) @compileError("a resumable write cannot call the encode hook of " ++ @typeName(T));
        if (!@hasDecl(SerializerType, "encoder")) {
            @compileError("format " ++ @typeName(SerializerType) ++ " cannot call the encode hook of " ++ @typeName(T));
        }
        var encoder = serializer.encoder();
        try value.zerdeEncode(&encoder);
        try encoder.finish();
        return;
    }
    switch (@typeInfo(T)) {
        .bool => {
            try reserveRoom(rc, atomic_room);
            try serializer.emitBool(value);
        },
        .int, .comptime_int => {
            try reserveRoom(rc, atomic_room);
            try serializer.emitInteger(value);
        },
        .float, .comptime_float => {
            try reserveRoom(rc, atomic_room);
            try serializer.emitFloat(value);
        },
        .optional => |info| {
            if (@typeInfo(info.child) == .optional) {
                @compileError("a nested optional is only supported as a struct field, where an absent field and null differ: " ++ @typeName(T));
            }
            if (@hasDecl(SerializerType, "beginOptional")) {
                try reserveRoom(rc, atomic_room);
                if (value) |child| {
                    try serializer.beginOptional(true);
                    try serializeValue(serializer, child, cfg, Format, order_policy, rc);
                } else {
                    try serializer.beginOptional(false);
                }
            } else {
                if (value) |child| {
                    try serializeValue(serializer, child, cfg, Format, order_policy, rc);
                } else {
                    try reserveRoom(rc, atomic_room);
                    try serializer.emitNull();
                }
            }
        },
        .@"enum" => {
            try reserveRoom(rc, atomic_room + 6 * longestEnumName(@typeInfo(T).@"enum"));
            if (comptime meta.effectiveEnumRepr(T, cfg) == .integer) {
                try serializer.emitInteger(@backingInt(value));
            } else if (@hasDecl(SerializerType, "emitEnum")) {
                try serializer.emitEnum(T, value);
            } else {
                try serializer.emitString(@tagName(value));
            }
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("an untagged union cannot be serialized: " ++ @typeName(T));
            if (!@hasDecl(SerializerType, "supports_unions")) {
                @compileError("format " ++ @typeName(SerializerType) ++ " does not support unions: " ++ @typeName(T));
            }
            // Externally tagged: a variant without a payload is its key; any other is a map of one
            // entry, the key and the payload. A key is the variant's name, or an integer when the
            // variant has a `key` override. Both forms say which variant it is before its payload.
            switch (value) {
                inline else => |payload, tag| {
                    const key = comptime meta.effectiveFieldKey(T, @tagName(tag), cfg);
                    const Payload = @TypeOf(payload);
                    if (comptime key == .integer and !@hasDecl(SerializerType, "supports_integer_keys")) {
                        @compileError("format " ++ @typeName(SerializerType) ++ " does not support integer keys: " ++ @typeName(T));
                    }
                    if (Payload == void) {
                        try reserveRoom(rc, keyRoom(key));
                        switch (comptime key) {
                            .text => |name| try serializer.emitString(name),
                            .integer => |number| try serializer.emitInteger(number),
                        }
                    } else {
                        var local: Level = .{};
                        const level: *Level = if (comptime resumable) try rc.enter() else &local;
                        defer if (comptime resumable) rc.leave();
                        if (level.phase == 0) {
                            try reserveRoom(rc, keyRoom(key));
                            if (@hasDecl(SerializerType, "beginStructSized")) {
                                try serializer.beginStructSized(T, 1);
                            } else {
                                try serializer.beginStruct(T);
                            }
                            switch (comptime key) {
                                .text => |name| _ = try serializer.beginStructField(T, name, Payload),
                                .integer => |number| _ = try serializer.beginStructFieldInteger(T, number, Payload),
                            }
                            level.phase = 1;
                        }
                        if (level.phase == 1) {
                            try serializeValue(serializer, payload, cfg, Format, order_policy, rc);
                            level.phase = 2;
                        }
                        try reserveRoom(rc, atomic_room);
                        try serializer.endStructField(T, @tagName(tag), Payload);
                        try serializer.endStruct(T);
                        level.* = .{};
                    }
                },
            }
        },
        .array => |info| {
            if (info.child == u8) {
                try emitText(serializer, rc, .bytes_inline, value[0..]);
                return;
            }

            if (@hasDecl(SerializerType, "serializeSequence")) {
                if (resumable) @compileError("a resumable write cannot use the sequence fast path of " ++ @typeName(SerializerType));
                if (try serializer.serializeSequence(T, value, cfg)) return;
            }

            try serializeItems(serializer, info.child, value[0..], cfg, Format, order_policy, rc);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) {
                    try emitText(serializer, rc, .string, value);
                    return;
                }

                if (@hasDecl(SerializerType, "serializeSequence")) {
                    if (resumable) @compileError("a resumable write cannot use the sequence fast path of " ++ @typeName(SerializerType));
                    if (try serializer.serializeSequence(T, value, cfg)) return;
                }

                try serializeItems(serializer, info.child, value, cfg, Format, order_policy, rc);
            },
            .one => try serializeValue(serializer, value.*, cfg, Format, order_policy, rc),
            else => @compileError("zerde cannot serialize pointer type " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            if (T == ByteString) {
                try emitText(serializer, rc, .bytes, value.bytes);
                return;
            }
            if (comptime isRaw(T)) {
                if (!@hasDecl(SerializerType, "emitRaw") or SerializerType.raw_format != T.zerde_raw_format) {
                    @compileError("format " ++ @typeName(SerializerType) ++ " cannot write a " ++ @tagName(T.zerde_raw_format) ++ " Raw item");
                }
                try emitText(serializer, rc, .raw, value.bytes);
                return;
            }
            if (comptime isSortedMap(T)) {
                if (!@hasDecl(SerializerType, "beginMapEntry")) @compileError("format " ++ @typeName(SerializerType) ++ " cannot write a sorted map: " ++ @typeName(T));
                var local: Level = .{};
                const level: *Level = if (comptime resumable) try rc.enter() else &local;
                defer if (comptime resumable) rc.leave();
                // The entries are written as they are, in order, and refused if they are not: what goes out is in key order.
                if (!level.entered) {
                    try reserveRoom(rc, atomic_room);
                    if (@hasDecl(SerializerType, "beginStructSized")) {
                        try serializer.beginStructSized(T, value.entries.len);
                    } else {
                        try serializer.beginStruct(T);
                    }
                    level.entered = true;
                }
                // An entry is its key (a text, which a window may end inside), its value, and the tokens around them: `phase` is the
                // part it is in, 0 for the start, 1 the key, 2 after the key, 3 the value, and `index` the entries done.
                var index: usize = level.index;
                while (index < value.entries.len) : (index += 1) {
                    const entry = value.entries[index];
                    if (level.phase == 0) {
                        if (index > 0) try sorted.checkNext(value.entries[index - 1].key, entry.key);
                        try reserveRoom(rc, atomic_room);
                        try serializer.beginMapEntry();
                        level.phase = 1;
                    }
                    if (level.phase == 1) {
                        try emitText(serializer, rc, .string, entry.key);
                        level.phase = 2;
                    }
                    if (level.phase == 2) {
                        try reserveRoom(rc, atomic_room);
                        try serializer.endMapKey();
                        level.phase = 3;
                    }
                    if (level.phase == 3) {
                        try serializeValue(serializer, entry.value, cfg, Format, order_policy, rc);
                        level.phase = 4;
                    }
                    try reserveRoom(rc, atomic_room);
                    try serializer.endStructField(T, "entry", @TypeOf(entry.value));
                    level.phase = 0;
                    level.index = @intCast(index + 1);
                }
                try reserveRoom(rc, atomic_room);
                try serializer.endStruct(T);
                level.* = .{};
                return;
            }
            if (info.is_tuple) @compileError("tuple structs are not supported: " ++ @typeName(T));
            if (comptime meta.effectiveDeclaredInOrder(T, cfg) and @hasDecl(Format, "encodeKey")) assertDeclaredOrder(T, cfg, Format.encodeKey);

            // The extras field is not a member: its entries are members of this struct's map.
            const extras_name = comptime meta.extrasField(T);
            if (comptime extras_name != null and !@hasDecl(SerializerType, "beginExtras")) {
                @compileError("format " ++ @typeName(SerializerType) ++ " cannot write extras: " ++ @typeName(T));
            }
            if (comptime resumable and extras_name != null) @compileError("a resumable write cannot write extras: " ++ @typeName(T));
            const extras_bytes: []const u8 = if (comptime extras_name) |name| extrasBytes(@field(value, name)) else &.{};

            var local: Level = .{};
            const level: *Level = if (comptime resumable) try rc.enter() else &local;
            defer if (comptime resumable) rc.leave();

            // TOML uses two passes so scalars appear before nested tables; JSON stays at one pass.
            const pass_count = comptime SerializerType.structPassCount(T);
            if (!level.entered) {
                try reserveRoom(rc, atomic_room);
                if (@hasDecl(SerializerType, "beginStructSized")) {
                    var field_count: usize = if (comptime extras_name != null) try serializer.extrasCount(extras_bytes) else 0;
                    inline for (0..pass_count) |pass| {
                        inline for (info.field_names, info.field_types, info.field_attrs) |field_name, field_type, field_attrs| {
                            if (field_attrs.@"comptime") {
                                @compileError("comptime struct fields are not supported: " ++ @typeName(T) ++ "." ++ field_name);
                            }

                            if (comptime meta.isExtrasField(T, field_name)) continue;
                            if (SerializerType.includeStructField(T, field_type, pass)) {
                                if (!omitField(T, field_name, field_type, cfg, @field(value, field_name))) field_count += 1;
                            }
                        }
                    }
                    try serializer.beginStructSized(T, field_count);
                } else {
                    try serializer.beginStruct(T);
                }
                level.entered = true;
            }
            const field_order = comptime structFieldOrder(T, Format, info, cfg, order_policy);
            var extras = if (comptime extras_name != null) try serializer.beginExtras(extras_bytes) else {};
            // In key order the extras are merged among the declared members; otherwise they follow them.
            const merge_extras = comptime extras_name != null and meta.effectiveFieldOrder(T, cfg, order_policy) == .encoded_key;
            // The fields written so far, counted over the unrolled loops, which is where a resumed write skips to.
            var written: u32 = 0;
            inline for (0..pass_count) |pass| {
                inline for (field_order) |field_index| {
                    const field_name = info.field_names[field_index];
                    const field_type = info.field_types[field_index];
                    if (info.field_attrs[field_index].@"comptime") {
                        @compileError("comptime struct fields are not supported: " ++ @typeName(T) ++ "." ++ field_name);
                    }

                    if (comptime meta.isExtrasField(T, field_name)) continue;
                    if (SerializerType.includeStructField(T, field_type, pass)) {
                        const field_value = @field(value, field_name);
                        // Omission is decided by the typed layer so formats do not duplicate that policy.
                        if (!omitField(T, field_name, field_type, cfg, field_value)) {
                            const mine = written;
                            written += 1;
                            if (!resumable or mine >= level.index) {
                                if (level.phase == 0) {
                                    if (comptime merge_extras) {
                                        try serializer.emitExtrasBefore(&extras, comptime Format.encodeKey(meta.effectiveFieldKey(T, field_name, cfg)));
                                    }
                                    try reserveRoom(rc, keyRoom(comptime meta.effectiveFieldKey(T, field_name, cfg)));
                                    level.flag = switch (comptime meta.effectiveFieldKey(T, field_name, cfg)) {
                                        .text => |emitted_name| if (@hasDecl(SerializerType, "beginStructFieldValue"))
                                            try serializer.beginStructFieldValue(T, emitted_name, field_type, field_value)
                                        else
                                            try serializer.beginStructField(T, emitted_name, field_type),
                                        .integer => |emitted_key| if (@hasDecl(SerializerType, "supports_integer_keys"))
                                            try serializer.beginStructFieldInteger(T, emitted_key, field_type)
                                        else
                                            @compileError("format " ++ @typeName(SerializerType) ++ " does not support integer keys: " ++ @typeName(T) ++ "." ++ field_name),
                                    };
                                    level.phase = 1;
                                }
                                if (level.phase == 1) {
                                    if (level.flag) {
                                        // A present nested optional field is written as its inner optional: null is
                                        // a value there, and the outer null was omitted above.
                                        if (comptime isNestedOptional(field_type)) {
                                            try serializeValue(serializer, field_value.?, cfg, Format, order_policy, rc);
                                        } else {
                                            try serializeValue(serializer, field_value, cfg, Format, order_policy, rc);
                                        }
                                    }
                                    level.phase = 2;
                                }
                                try reserveRoom(rc, atomic_room);
                                switch (comptime meta.effectiveFieldKey(T, field_name, cfg)) {
                                    .text => |emitted_name| try serializer.endStructField(T, emitted_name, field_type),
                                    .integer => try serializer.endStructField(T, field_name, field_type),
                                }
                                level.phase = 0;
                                level.index = mine + 1;
                            }
                        }
                    }
                }
            }
            try reserveRoom(rc, atomic_room);
            if (comptime extras_name != null) try serializer.finishExtras(&extras, comptime declaredKeys(T, info, cfg));
            try serializer.endStruct(T);
            level.* = .{};
        },
        else => @compileError("zerde cannot serialize " ++ @typeName(T)),
    }
}

/// The items of an array or slice, as an array of `Child`, going on from the item a resumable write stopped in.
fn serializeItems(
    serializer: anytype,
    comptime Child: type,
    items: []const Child,
    comptime cfg: anytype,
    comptime Format: type,
    comptime order_policy: meta.FieldOrderPolicy,
    rc: anytype,
) anyerror!void {
    const resumable = comptime @TypeOf(rc) != NoResume;
    var local: Level = .{};
    const level: *Level = if (comptime resumable) try rc.enter() else &local;
    defer if (comptime resumable) rc.leave();
    if (!level.entered) {
        try reserveRoom(rc, atomic_room);
        try serializer.beginArray(Child, items.len);
        level.entered = true;
    }
    var index: usize = level.index;
    while (index < items.len) : (index += 1) {
        if (level.phase == 0) {
            try reserveRoom(rc, atomic_room);
            try serializer.beginArrayItem(Child, index);
            level.phase = 1;
        }
        if (level.phase == 1) {
            try serializeValue(serializer, items[index], cfg, Format, order_policy, rc);
            level.phase = 2;
        }
        try reserveRoom(rc, atomic_room);
        try serializer.endArrayItem(Child, index);
        level.phase = 0;
        level.index = @intCast(index + 1);
    }
    try reserveRoom(rc, atomic_room);
    try serializer.endArray(Child, items.len);
    level.* = .{};
}

/// The first field of `T` that is not after the one before it in the order of the encoded keys `encode` gives (`null` when
/// all are), with that one: a repeated key is not after it either.
pub fn declaredOrderFault(comptime T: type, comptime cfg: anytype, comptime encode: anytype) ?struct { field: []const u8, previous: []const u8 } {
    comptime {
        @setEvalBranchQuota(100_000);
        const info = @typeInfo(T).@"struct";
        var previous: ?[]const u8 = null;
        var previous_name: []const u8 = "";
        for (info.field_names) |name| {
            const key = encode(meta.effectiveFieldKey(T, name, cfg));
            if (previous) |before| {
                if (!std.mem.lessThan(u8, before, key)) return .{ .field = name, .previous = previous_name };
            }
            previous = key;
            previous_name = name;
        }
        return null;
    }
}

/// A struct that declares `declared_in_order` has its fields in the ascending order of their encoded keys, `encode` being the
/// format's `encodeKey`: a compile error names the first field that is not after the one before it. A type with extras has
/// members that are not fields, so it cannot be in order.
pub fn assertDeclaredOrder(comptime T: type, comptime cfg: anytype, comptime encode: anytype) void {
    comptime {
        if (meta.extrasField(T) != null) @compileError("a type with extras cannot declare its fields in order: " ++ @typeName(T));
        if (declaredOrderFault(T, cfg, encode)) |fault| {
            @compileError(@typeName(T) ++ " declares its fields in order, but `" ++ fault.field ++ "` is not after `" ++ fault.previous ++
                "` in the order of their encoded keys");
        }
    }
}

/// The bytes of an extras field, which is `Raw` or `?Raw`; none for a null.
fn extrasBytes(extras: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(extras))) {
        .optional => if (extras) |raw| raw.bytes else &.{},
        else => extras.bytes,
    };
}

/// The wire keys of every declared member, which an extras entry must not repeat.
fn declaredKeys(comptime T: type, comptime info: std.builtin.Type.Struct, comptime cfg: anytype) []const meta.FieldKey {
    comptime {
        var keys: [info.field_names.len]meta.FieldKey = undefined;
        var count: usize = 0;
        for (info.field_names) |field_name| {
            if (meta.isExtrasField(T, field_name)) continue;
            keys[count] = meta.effectiveFieldKey(T, field_name, cfg);
            count += 1;
        }
        const final = keys[0..count].*;
        return &final;
    }
}

/// Whether a user type declares the wire hook `name`: `zerdeDecode`, `zerdeEncode` or `zerdeFree`.
fn hasHook(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

/// Bytes go to the format's byte-string token; a format with none carries them as a string.
fn emitByteString(serializer: anytype, bytes: []const u8) !void {
    if (@hasDecl(@TypeOf(serializer.*), "emitBytes")) {
        try serializer.emitBytes(bytes);
    } else {
        try serializer.emitString(bytes);
    }
}

fn isNestedOptional(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |info| @typeInfo(info.child) == .optional,
        else => false,
    };
}

/// Whether a struct field is left out of the output. The field's `optional` policy decides for a
/// plain optional; a nested optional (`??T`) is absent when its outer optional is null.
fn omitField(comptime T: type, comptime field_name: []const u8, comptime FieldType: type, comptime cfg: anytype, value: FieldType) bool {
    if (@typeInfo(FieldType) != .optional) return false;
    if (comptime isNestedOptional(FieldType)) return value == null;
    return switch (comptime meta.effectiveOptionalPolicy(T, field_name, cfg)) {
        .lenient => meta.effectiveOmitNullFields(T, cfg) and value == null,
        .nullable => false,
        .absent => value == null,
    };
}

/// What the typed walk builds, as a sink says: `TypedSink` builds the Zig value of `T`; `wire.WireSink`
/// builds its fixed layout (`wire.Wire(T)`) straight from the reader. Every rule of a read (what a token
/// may be, bounds, field keys, optionals, unions, defaults, unknown and repeated fields, `check`) is in this
/// one walk, and a sink says only how a result is assembled, so a layout has no second copy of a rule.
/// The walk is destination-passing: a value is read into the `*Of(T)` the caller gives, so what a container has
/// built so far is in the destination and not in a frame of the walk, which is what lets a resumable read
/// (`ReadLevel`) stop in the middle of one. A sink has `Of(T)`, the type of the result for `T`, and `scalar`,
/// `text`, `textOf`, `bytesOf`, `list`, `someDest`, `none`, `enumOf`, `unionDest`, `unionVoid`, `fromDefault`, `check` and
/// `free`, as `TypedSink` shows.
pub const TypedSink = struct {
    pub fn Of(comptime T: type) type {
        return T;
    }

    pub fn scalar(_: TypedSink, comptime T: type, value: T) !T {
        return value;
    }

    /// A string field, `bytes` being the input's own bytes, the reader's rewritten ones, or a copy.
    pub fn text(_: TypedSink, comptime T: type, bytes: []const u8) !T {
        return if (@typeInfo(T).pointer.attrs.@"const") bytes else @constCast(bytes);
    }

    /// The text a `text` result holds.
    pub fn textOf(_: TypedSink, text_value: []const u8) []const u8 {
        return text_value;
    }

    /// A `ByteString` or a `Raw` that holds `bytes`.
    pub fn bytesOf(_: TypedSink, comptime T: type, bytes: []const u8) !T {
        return .{ .bytes = bytes };
    }

    /// A string left in the stream, which is where its bytes are: only a layout of offsets (`wire.WireSink`) can say it.
    pub fn span(_: TypedSink, comptime T: type, _: u64, _: usize) !T {
        @compileError("a Zig value cannot hold a string that is left in the stream: " ++ @typeName(T));
    }

    pub fn list(_: TypedSink, comptime T: type, items: []@typeInfo(T).pointer.child) !T {
        return items;
    }

    /// Makes `dest` the present optional and gives its value to read into; with `init` false it is present already
    /// (a resumable read coming back to a value it began).
    pub fn someDest(_: TypedSink, comptime T: type, dest: *T, init: bool) *@typeInfo(T).optional.child {
        if (init) dest.* = @as(@typeInfo(T).optional.child, undefined);
        return &dest.*.?;
    }

    pub fn none(_: TypedSink, comptime T: type) !T {
        return null;
    }

    pub fn enumOf(_: TypedSink, comptime T: type, value: T) !T {
        return value;
    }

    /// Makes `dest` the variant `name` and gives its payload to read into; with `init` false it is that variant
    /// already.
    pub fn unionDest(_: TypedSink, comptime T: type, comptime name: []const u8, dest: *T, init: bool) *@FieldType(T, name) {
        if (init) dest.* = @unionInit(T, name, undefined);
        return &@field(dest.*, name);
    }

    pub fn unionVoid(_: TypedSink, comptime T: type, comptime name: []const u8) !T {
        return @unionInit(T, name, {});
    }

    /// The value of a field the input did not name, from its declared default.
    pub fn fromDefault(_: TypedSink, comptime T: type, _: Allocator, value: T) !T {
        return value;
    }

    /// A type's own `check` runs once the struct is built, for rules across fields. Its error is
    /// returned as it is; the fields already read are released.
    pub fn check(_: TypedSink, comptime T: type, _: Allocator, result: *const T) anyerror!void {
        if (comptime @hasDecl(T, "check")) try result.check();
    }

    pub fn free(_: TypedSink, comptime T: type, allocator: Allocator, value: T, borrowed_strings: bool) void {
        freeTypedPartial(T, allocator, value, borrowed_strings);
    }
};

/// Reads one `T` as `sink` builds it: the typed walk, for a sink of another layout (see `TypedSink`).
pub fn deserializeInto(sink: anytype, comptime T: type, allocator: Allocator, deserializer: anytype, comptime cfg: anytype) anyerror!@TypeOf(sink).Of(T) {
    var result: @TypeOf(sink).Of(T) = undefined;
    try deserializeValue(sink, T, &result, allocator, deserializer, cfg, null, false, NoRead{});
    return result;
}

/// One step of a resumable read into `dest`: `deserializer` is a chunk reader (`chunk.Reader`) and `rc` the state
/// (`typed_resume.State`). `error.NeedMore` says the chunk is used up and the step is to be made again, with the
/// same `dest` and `rc`, once the reader has the next chunk; success says `dest` holds the value. After any other
/// error `dest` and `rc` are not to be used again, and nothing is freed: a resumable read takes its memory from an
/// arena or a fixed buffer.
pub fn deserializeResumable(
    sink: anytype,
    comptime T: type,
    dest: *@TypeOf(sink).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    rc: anytype,
) anyerror!void {
    try deserializeValue(sink, T, dest, allocator, deserializer, cfg, null, false, rc);
}

/// Marks a read that is not resumable: every resume step compiles to nothing.
pub const NoRead = struct {};

/// What a resumable read keeps for one open container, optional or union between calls. The walk goes down the same
/// path again at each call, and each level skips what it has done and goes on from here; what the numbers mean is
/// said where each is used (`typed_resume.zig`).
pub const ReadLevel = struct {
    phase: u8 = 0,
    /// Items or entries complete.
    index: usize = 0,
    /// Items or entries the container states.
    count: usize = 0,
    /// A struct: the fields before this rank have a value, read or resolved as absent.
    cursor: usize = 0,
    /// A struct's field rank or a union's variant, from the key just read.
    pick: usize = 0,
    /// A list or a sorted map: the array its head allocated, in the sink's element type.
    items: ?*anyopaque = null,
    /// A sorted map: the key of the entry before.
    prev: []const u8 = &.{},
    /// A struct: a required field has no key, which is said at the end.
    missing: bool = false,
};

/// The string, key or `Raw` a resumable read is in the middle of: its length, how much of it has come, and where
/// it goes. Only one is in flight at a time, so a read has one.
pub const ReadLeaf = struct {
    started: bool = false,
    len: usize = 0,
    at: usize = 0,
    buf: []u8 = &.{},
    /// A string left in the stream (positions mode, `typed_resume.textInto`): where its bytes begin in the stream.
    start: u64 = 0,
    /// A text that is dropped, not kept (a key longer than every name), is still checked as UTF-8, a piece at a time.
    utf8: bulk.Utf8Stream = .{},
};

pub fn deserializeValue(
    s: anytype,
    comptime T: type,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    rc: anytype,
) anyerror!void {
    const DeserializerType = @TypeOf(deserializer.*);
    if (comptime hasHook(T, "zerdeDecode")) {
        if (comptime @TypeOf(rc) != NoRead) @compileError("a resumable read cannot call the decode hook of " ++ @typeName(T));
        if (!@hasDecl(DeserializerType, "pullView")) {
            @compileError("format " ++ @typeName(DeserializerType) ++ " cannot call the decode hook of " ++ @typeName(T));
        }
        var reader = deserializer.pullView(allocator);
        defer reader.deinit();
        const decoded = try T.zerdeDecode(allocator, &reader);
        // The hook reads one whole item, no less; what it built is released before the error.
        if (!reader.done) {
            freeTypedPartial(T, allocator, decoded, @hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings());
            return error.HookIncomplete;
        }
        dest.* = decoded;
        return;
    }
    switch (@typeInfo(T)) {
        .bool => dest.* = try s.scalar(T, try deserializer.readBool()),
        // Formats parse numbers once into a common token; the typed layer is responsible for exact casts.
        .int, .comptime_int => dest.* = try s.scalar(T, if (@hasDecl(DeserializerType, "readInt"))
            try deserializer.readInt(T)
        else
            try decodeIntNumber(T, try deserializer.readNumber())),
        .float, .comptime_float => dest.* = try s.scalar(T, if (@hasDecl(DeserializerType, "readFloat"))
            try deserializer.readFloat(T)
        else
            try decodeFloatNumber(T, try deserializer.readNumber())),
        .optional => |info| try deserializeOptional(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, .{}, rc),
        .@"enum" => dest.* = try s.enumOf(T, try decodeEnumValue(T, allocator, deserializer, cfg, rc)),
        .@"union" => |info| try deserializeUnion(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc),
        .array => |info| try deserializeArray(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc),
        .pointer => |info| try deserializePointer(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, .{}, rc),
        .@"struct" => |info| {
            if (T == ByteString) {
                try readByteString(s, T, dest, allocator, deserializer, .{}, rc);
            } else if (comptime isRaw(T)) {
                dest.* = try s.bytesOf(T, try readRawSlice(T, allocator, deserializer, .{}, rc));
            } else if (comptime isSortedMap(T)) {
                try deserializeSortedMap(s, T, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, .{}, rc);
            } else {
                try deserializeStruct(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
            }
        },
        else => return error.UnsupportedType,
    }
}

/// An optional: null, or a value read as its child is, with the child's `bounds` if the field has any. A resumable
/// read decides once (`phase` 0), at the head of the value, and goes on into the child from then on.
fn deserializeOptional(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Optional,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    comptime bounds: meta.Bounds,
    rc: anytype,
) anyerror!void {
    if (@typeInfo(info.child) == .optional) {
        @compileError("a nested optional is only supported as a struct field, where an absent field and null differ: " ++ @typeName(T));
    }
    var local: ReadLevel = .{};
    const level: *ReadLevel = if (comptime @TypeOf(rc) != NoRead) rc.enter() else &local;
    defer if (comptime @TypeOf(rc) != NoRead) rc.leave();
    const first = level.phase == 0;
    if (first) {
        if (try readNullIfPresent(deserializer)) {
            dest.* = try s.none(T);
            level.* = .{};
            return;
        }
        level.phase = 1;
    }
    const child_dest = s.someDest(T, dest, first);
    if (comptime bounds.isDefault()) {
        try deserializeValue(s, info.child, child_dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
    } else {
        try deserializeBounded(s, info.child, bounds, child_dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
    }
    level.* = .{};
}

fn deserializeUnion(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Union,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    rc: anytype,
) anyerror!void {
    const DeserializerType = @TypeOf(deserializer.*);
    if (info.tag_type == null) @compileError("an untagged union cannot be deserialized: " ++ @typeName(T));
    if (!@hasDecl(DeserializerType, "supports_unions")) {
        @compileError("format " ++ @typeName(DeserializerType) ++ " does not support unions: " ++ @typeName(T));
    }
    const borrowed_strings = @hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings();
    const integer_keys = comptime unionHasIntegerKeys(T, info, cfg);
    if (integer_keys and !@hasDecl(DeserializerType, "supports_integer_keys")) {
        @compileError("format " ++ @typeName(DeserializerType) ++ " does not support integer keys: " ++ @typeName(T));
    }
    if (comptime @TypeOf(rc) != NoRead) return resume_read.unionValue(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);

    switch (try deserializer.peekKind()) {
        .string => {
            if (comptime @hasDecl(DeserializerType, "readStringShort")) {
                const cap = comptime longestVariantName(T, info, cfg);
                var buffer: [cap]u8 = undefined;
                const name = switch (try deserializer.readStringShort(cap, &buffer)) {
                    .text => |bytes| bytes,
                    .long => return error.InvalidEnumTag,
                };
                inline for (info.field_names, info.field_types) |variant, FieldType| {
                    if (FieldType == void and variantHasText(T, variant, cfg, name)) {
                        dest.* = try s.unionVoid(T, variant);
                        return;
                    }
                }
                return error.InvalidEnumTag;
            }
            const token = try deserializer.readString(allocator);
            defer token.deinit(allocator);
            inline for (info.field_names, info.field_types) |name, FieldType| {
                if (FieldType == void and variantHasText(T, name, cfg, token.bytes)) {
                    dest.* = try s.unionVoid(T, name);
                    return;
                }
            }
            return error.InvalidEnumTag;
        },
        .number => {
            if (!integer_keys) return error.UnexpectedType;
            const number = switch (try deserializer.readNumber()) {
                .integer => |n| n,
                .float => return error.UnexpectedType,
            };
            inline for (info.field_names, info.field_types) |name, FieldType| {
                if (FieldType == void and variantHasInteger(T, name, cfg, number)) {
                    dest.* = try s.unionVoid(T, name);
                    return;
                }
            }
            return error.InvalidEnumTag;
        },
        .object => {
            try deserializer.beginObject();
            // The key is compared with the variants' names where it is read, and not kept: it is not allocated,
            // so nothing is left behind it once the payload allocates.
            const cap = comptime longestVariantName(T, info, cfg);
            var buffer: [cap]u8 = undefined;
            const key = (try nextUnionKey(deserializer, allocator, cap, &buffer)) orelse return error.LengthMismatch;
            defer key.deinit(allocator);

            var matched = false;
            inline for (info.field_names, info.field_types) |name, FieldType| {
                const matches = switch (key.value) {
                    .text => |bytes| variantHasText(T, name, cfg, bytes),
                    .integer => |number| variantHasInteger(T, name, cfg, number),
                    .long => false,
                };
                if (FieldType != void and matches) {
                    matched = true;
                    try deserializeFieldValue(s, FieldType, s.unionDest(T, name, dest, true), allocator, deserializer, cfg, diagnostics, track_diagnostics, name, meta.effectiveBounds(T, name, cfg), rc);
                }
            }
            if (!matched) return error.InvalidEnumTag;
            errdefer s.free(T, allocator, dest.*, borrowed_strings);

            // A union is one entry: a second one is not another variant.
            var extra_buffer: [cap]u8 = undefined;
            if (try nextUnionKey(deserializer, allocator, cap, &extra_buffer)) |extra| {
                extra.deinit(allocator);
                return error.LengthMismatch;
            }
        },
        else => return error.UnexpectedType,
    }
}

/// A string that is only compared with names the type declares: the bytes if they fit the `cap` the caller
/// gave, which lie in the input or in the caller's buffer and are valid until the next read, or `.long` when
/// they are longer than every name, so it is none of them. A format that has `readStringShort` reads a name
/// without allocating, the escaped and chunked kinds included.
pub const ShortText = union(enum) {
    text: []const u8,
    long,
};

/// A map key, as `ShortText`, or an integer (`supports_integer_keys`).
pub const ObjectKeyShort = union(enum) {
    text: []const u8,
    integer: i128,
    long,
};

/// The length in bytes of the longest text key of a union's variants, or of an enum's names, which a key
/// is compared with.
pub fn longestVariantName(comptime T: type, comptime info: std.builtin.Type.Union, comptime cfg: anytype) usize {
    comptime {
        var longest: usize = 0;
        for (info.field_names) |name| {
            switch (meta.effectiveFieldKey(T, name, cfg)) {
                .text => |text| longest = @max(longest, text.len),
                .integer => {},
            }
        }
        return longest;
    }
}

pub fn longestEnumName(comptime info: std.builtin.Type.Enum) usize {
    comptime {
        var longest: usize = 0;
        for (info.field_names) |name| longest = @max(longest, name.len);
        return longest;
    }
}

/// The length in bytes of the longest text key of a struct's fields.
pub fn longestFieldName(comptime T: type, comptime cfg: anytype) usize {
    comptime {
        var longest: usize = 0;
        for (@typeInfo(T).@"struct".field_names) |name| {
            switch (meta.effectiveFieldKey(T, name, cfg)) {
                .text => |text| longest = @max(longest, text.len),
                .integer => {},
            }
        }
        return longest;
    }
}

/// The next key of a union's map: read into `buffer` or the input without allocating by a format with
/// `nextObjectKeyShort`, and as a token of the allocator's by any other.
const UnionKey = struct {
    value: ObjectKeyShort,
    token: ?StringToken = null,

    fn deinit(self: UnionKey, allocator: Allocator) void {
        if (self.token) |token| token.deinit(allocator);
    }
};

fn nextUnionKey(deserializer: anytype, allocator: Allocator, comptime cap: usize, buffer: *[cap]u8) anyerror!?UnionKey {
    if (comptime @hasDecl(@TypeOf(deserializer.*), "nextObjectKeyShort")) {
        const key = (try deserializer.nextObjectKeyShort(cap, buffer)) orelse return null;
        return .{ .value = key };
    }
    const token = (try deserializer.nextObjectField(allocator)) orelse return null;
    return .{ .value = .{ .text = token.bytes }, .token = token };
}

pub fn unionHasIntegerKeys(comptime T: type, comptime info: std.builtin.Type.Union, comptime cfg: anytype) bool {
    inline for (info.field_names) |name| {
        if (meta.effectiveFieldKey(T, name, cfg) == .integer) return true;
    }
    return false;
}

pub fn variantHasText(comptime T: type, comptime name: []const u8, comptime cfg: anytype, bytes: []const u8) bool {
    return switch (comptime meta.effectiveFieldKey(T, name, cfg)) {
        .text => |text| std.mem.eql(u8, bytes, text),
        .integer => false,
    };
}

pub fn variantHasInteger(comptime T: type, comptime name: []const u8, comptime cfg: anytype, number: i128) bool {
    return switch (comptime meta.effectiveFieldKey(T, name, cfg)) {
        .text => false,
        .integer => |key| key == number,
    };
}

fn decodeIntNumber(comptime T: type, number: Number) Error!T {
    return switch (number) {
        .integer => |n| std.math.cast(T, n) orelse error.IntegerOverflow,
        // A float is not an integer even when its value is whole: `1.0` and `1` are different
        // tokens in CBOR, and accepting one for the other turns a type error into a silent cast.
        .float => error.UnexpectedType,
    };
}

fn decodeFloatNumber(comptime T: type, number: Number) Error!T {
    return switch (number) {
        .integer => |n| narrowFloat(T, @floatFromInt(n)),
        .float => |n| narrowFloat(T, n),
    };
}

/// Narrows a parsed float to the field's type. A finite value too large for `T` is refused: rounding
/// it to infinity would turn an out-of-range number into a different, valid-looking one. An input
/// that is already infinite or NaN keeps that value.
pub fn narrowFloat(comptime T: type, wide: f64) Error!T {
    const narrowed: T = @floatCast(wide);
    if (std.math.isInf(narrowed) and !std.math.isInf(wide)) return error.FloatOutOfRange;
    return narrowed;
}

/// Whether `deserializer` reads only the deterministic encoding (`isStrict`); a format without the capability is never strict.
pub fn readsStrict(deserializer: anytype) bool {
    if (comptime !@hasDecl(@TypeOf(deserializer.*), "isStrict")) return false;
    return deserializer.isStrict();
}

fn decodeEnumValue(comptime T: type, allocator: Allocator, deserializer: anytype, comptime cfg: anytype, rc: anytype) anyerror!T {
    const DeserializerType = @TypeOf(deserializer.*);
    if (@hasDecl(DeserializerType, "readEnumTag")) {
        return try deserializer.readEnumTag(T);
    }
    if (comptime @TypeOf(rc) != NoRead) return resume_read.enumValue(T, deserializer, cfg, rc);

    return switch (try deserializer.peekKind()) {
        .string => blk: {
            // An enum written as its number reads only a number.
            if (comptime meta.effectiveEnumRepr(T, cfg) == .integer) return error.UnexpectedType;
            if (comptime @hasDecl(DeserializerType, "readStringShort")) {
                const cap = comptime longestEnumName(@typeInfo(T).@"enum");
                var buffer: [cap]u8 = undefined;
                break :blk switch (try deserializer.readStringShort(cap, &buffer)) {
                    .text => |bytes| std.meta.stringToEnum(T, bytes) orelse error.InvalidEnumTag,
                    .long => error.InvalidEnumTag,
                };
            }
            const token = try deserializer.readString(allocator);
            defer token.deinit(allocator);
            break :blk std.meta.stringToEnum(T, token.bytes) orelse error.InvalidEnumTag;
        },
        .number => blk: {
            // A strict read takes only the form the writer uses: the name, for an enum written as its name.
            if (comptime meta.effectiveEnumRepr(T, cfg) == .name) if (readsStrict(deserializer)) return error.NonDeterministicEncoding;
            const raw_tag = switch (try deserializer.readNumber()) {
                .integer => |n| n,
                .float => return error.UnexpectedType,
            };
            const tag_type = @typeInfo(T).@"enum".tag_type;
            const cast_tag = std.math.cast(tag_type, raw_tag) orelse return error.InvalidEnumTag;
            break :blk std.enums.fromInt(T, cast_tag) orelse error.InvalidEnumTag;
        },
        else => error.UnexpectedType,
    };
}

fn deserializeArray(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Array,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    rc: anytype,
) anyerror!void {
    const DeserializerType = @TypeOf(deserializer.*);
    const borrowed_strings = @hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings();
    if (comptime @TypeOf(rc) != NoRead) return resume_read.array(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);

    if (info.child == u8) {
        // A byte array is read from the format's byte-string token, never from a text string.
        const token = try readByteToken(allocator, deserializer);
        defer token.deinit(allocator);

        if (token.bytes.len != info.len) return error.LengthMismatch;
        var result: T = undefined;
        @memcpy(result[0..], token.bytes);
        dest.* = try s.scalar(T, result);
        return;
    }

    const known_len = try beginArrayWithKnownLen(deserializer);
    if (known_len) |len| {
        if (len != info.len) return error.LengthMismatch;
    }
    // The elements read so far are released if a later one fails.
    var initialized: usize = 0;
    errdefer for (dest[0..initialized]) |item| s.free(info.child, allocator, item, borrowed_strings);

    if (known_len) |_| {
        if (@hasDecl(DeserializerType, "finishKnownLenArray")) {
            inline for (0..info.len) |index| {
                try deserializeIndexedValue(s, info.child, &dest[index], allocator, deserializer, cfg, diagnostics, track_diagnostics, index, rc);
                initialized = index + 1;
            }
            try deserializer.finishKnownLenArray();
        } else {
            inline for (0..info.len) |index| {
                if (!try deserializer.nextArrayItem()) return error.LengthMismatch;
                try deserializeIndexedValue(s, info.child, &dest[index], allocator, deserializer, cfg, diagnostics, track_diagnostics, index, rc);
                initialized = index + 1;
            }
            if (try deserializer.nextArrayItem()) return error.LengthMismatch;
        }
        return;
    }

    var index: usize = 0;
    while (try deserializer.nextArrayItem()) {
        if (index >= info.len) return error.LengthMismatch;
        try deserializeIndexedValue(s, info.child, &dest[index], allocator, deserializer, cfg, diagnostics, track_diagnostics, index, rc);
        index += 1;
        initialized = index;
    }

    if (index != info.len) return error.LengthMismatch;
}

fn deserializePointer(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Pointer,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    comptime bounds: meta.Bounds,
    rc: anytype,
) anyerror!void {
    const DeserializerType = @TypeOf(deserializer.*);
    const borrowed_strings = @hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings();
    const Out = @TypeOf(s).Of;

    switch (info.size) {
        .slice => {
            if (info.child == u8) {
                if (comptime @TypeOf(rc) != NoRead) {
                    try resume_read.textInto(s, T, dest, 3, allocator, deserializer, bounds, rc);
                    return;
                }
                const token = if (comptime hasMax(bounds) and @hasDecl(DeserializerType, "readStringMax"))
                    try deserializer.readStringMax(allocator, bounds.max_len)
                else
                    try deserializer.readString(allocator);
                errdefer token.deinit(allocator);
                try checkLength(bounds, token.bytes.len);
                // Aliased slice parses can hand byte and string fields straight back to the caller without copying.
                if (borrowed_strings or token.allocated) {
                    dest.* = try s.text(T, token.bytes);
                    return;
                }
                dest.* = try s.text(T, try allocator.dupe(info.child, token.bytes));
                return;
            }
            if (comptime @TypeOf(rc) != NoRead) return resume_read.list(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, bounds, rc);

            const known_len = try beginArrayWithKnownLen(deserializer);
            if (known_len) |len| {
                // Bounds are checked before the allocation they exist to limit.
                try checkLength(bounds, len);
                const items = try allocator.alloc(Out(info.child), len);
                errdefer allocator.free(items);

                var initialized: usize = 0;
                errdefer {
                    for (items[0..initialized]) |item| s.free(info.child, allocator, item, borrowed_strings);
                }

                if (@hasDecl(DeserializerType, "finishKnownLenArray")) {
                    for (0..len) |index| {
                        try deserializeElement(s, info.child, &items[index], allocator, deserializer, cfg, diagnostics, track_diagnostics, index, bounds, rc);
                        initialized = index + 1;
                    }
                    try deserializer.finishKnownLenArray();
                } else {
                    for (0..len) |index| {
                        if (!try deserializer.nextArrayItem()) return error.LengthMismatch;
                        try deserializeElement(s, info.child, &items[index], allocator, deserializer, cfg, diagnostics, track_diagnostics, index, bounds, rc);
                        initialized = index + 1;
                    }

                    if (try deserializer.nextArrayItem()) return error.LengthMismatch;
                }

                dest.* = try s.list(T, items);
                return;
            }

            var items: std.ArrayList(Out(info.child)) = .empty;
            errdefer {
                for (items.items) |item| s.free(info.child, allocator, item, borrowed_strings);
                items.deinit(allocator);
            }

            while (try deserializer.nextArrayItem()) {
                if (items.items.len >= bounds.max_len) return error.LengthOutOfBounds;
                var item: Out(info.child) = undefined;
                try deserializeElement(s, info.child, &item, allocator, deserializer, cfg, diagnostics, track_diagnostics, items.items.len, bounds, rc);
                errdefer s.free(info.child, allocator, item, borrowed_strings);
                try items.append(allocator, item);
            }
            try checkLength(bounds, items.items.len);

            dest.* = try s.list(T, try items.toOwnedSlice(allocator));
        },
        .one => {
            if (comptime @TypeOf(rc) != NoRead) return resume_read.one(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
            const ptr = try allocator.create(Out(info.child));
            errdefer allocator.destroy(ptr);
            try deserializeValue(s, info.child, ptr, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
            dest.* = ptr;
        },
        else => return error.UnsupportedType,
    }
}

fn beginArrayWithKnownLen(deserializer: anytype) anyerror!?usize {
    const DeserializerType = @TypeOf(deserializer.*);
    if (@hasDecl(DeserializerType, "beginArrayLen")) {
        return try deserializer.beginArrayLen();
    }

    try deserializer.beginArray();
    return null;
}

/// Reads one byte-string token. A format with a `readBytes` has a distinct byte-string kind, and
/// only that kind is a byte string: text is not bytes, whatever its content.
fn readByteToken(allocator: Allocator, deserializer: anytype) anyerror!StringToken {
    const DeserializerType = @TypeOf(deserializer.*);
    if (@hasDecl(DeserializerType, "readByteToken")) {
        return try deserializer.readByteToken(allocator);
    }
    if (@hasDecl(DeserializerType, "readBytes")) {
        return switch (try deserializer.peekKind()) {
            .bytes => try deserializer.readBytes(allocator),
            else => error.UnexpectedType,
        };
    }
    return try deserializer.readString(allocator);
}

/// A `ByteString` into `dest`: as the format reads a byte string, or for a resumable read as it arrives (`typed_resume.textInto`).
fn readByteString(s: anytype, comptime T: type, dest: *@TypeOf(s).Of(T), allocator: Allocator, deserializer: anytype, comptime bounds: meta.Bounds, rc: anytype) anyerror!void {
    if (comptime @TypeOf(rc) != NoRead) return resume_read.textInto(s, T, dest, 2, allocator, deserializer, bounds, rc);
    dest.* = try s.bytesOf(T, try readByteSlice(allocator, deserializer, bounds));
}

/// Reads a variable-length byte string into memory the caller owns, or into the input when the
/// parse aliases it.
fn readByteSlice(allocator: Allocator, deserializer: anytype, comptime bounds: meta.Bounds) anyerror![]const u8 {
    const DeserializerType = @TypeOf(deserializer.*);
    const token = if (comptime hasMax(bounds) and @hasDecl(DeserializerType, "readByteTokenMax"))
        try deserializer.readByteTokenMax(allocator, bounds.max_len)
    else
        try readByteToken(allocator, deserializer);
    errdefer token.deinit(allocator);
    try checkLength(bounds, token.bytes.len);
    if (@hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings()) return token.bytes;
    if (token.allocated) return token.bytes;
    return allocator.dupe(u8, token.bytes);
}

/// Reads the next item as raw bytes into memory the caller owns, or into the input when the parse aliases it.
fn readRawSlice(comptime T: type, allocator: Allocator, deserializer: anytype, comptime bounds: meta.Bounds, rc: anytype) anyerror![]const u8 {
    if (comptime @TypeOf(rc) != NoRead) return resume_read.raw(T, allocator, deserializer, bounds, rc);
    const DeserializerType = @TypeOf(deserializer.*);
    if (!@hasDecl(DeserializerType, "readRaw") or DeserializerType.raw_format != T.zerde_raw_format) {
        @compileError("format " ++ @typeName(DeserializerType) ++ " cannot read a " ++ @tagName(T.zerde_raw_format) ++ " Raw item");
    }
    const token = try deserializer.readRaw(allocator);
    try checkLength(bounds, token.bytes.len);
    if (bounds.validate) |validate| try validate(allocator, token.bytes);
    if (@hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings()) return token.bytes;
    return allocator.dupe(u8, token.bytes);
}

fn deserializeStruct(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    rc: anytype,
) anyerror!void {
    if (info.is_tuple) return error.UnsupportedType;

    const DeserializerType = @TypeOf(deserializer.*);
    const borrowed_strings = @hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings();
    if (comptime @TypeOf(rc) != NoRead) return resume_read.structValue(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
    if (@hasDecl(DeserializerType, "beginStructOrdered")) {
        try deserializer.beginStructOrdered(T);

        var ordered_seen: [info.field_names.len]bool = @splat(false);
        errdefer freePartialStruct(s, T, allocator, dest, &ordered_seen, borrowed_strings);

        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, field_type, field_attrs, i| {
            if (field_attrs.@"comptime") {
                @compileError("comptime struct fields are not supported: " ++ @typeName(T) ++ "." ++ field_name);
            }

            try deserializeFieldValue(s, field_type, &@field(dest.*, field_name), allocator, deserializer, cfg, diagnostics, track_diagnostics, field_name, meta.effectiveBounds(T, field_name, cfg), rc);
            ordered_seen[i] = true;
        }

        if (@hasDecl(DeserializerType, "endStructOrdered")) try deserializer.endStructOrdered(T);
        try s.check(T, allocator, dest);
        return;
    }

    if (comptime structHasIntegerKeys(T, info, cfg) and !@hasDecl(DeserializerType, "supports_integer_keys")) {
        @compileError("format " ++ @typeName(DeserializerType) ++ " does not support integer keys: " ++ @typeName(T));
    }

    if (comptime meta.effectiveDeclaredInOrder(T, cfg) and @hasDecl(DeserializerType, "keyEncoder")) {
        assertDeclaredOrder(T, cfg, DeserializerType.keyEncoder);
        if (comptime !@hasDecl(DeserializerType, "nextObjectFieldIndex")) @compileError("a merge walk needs the field index of a key");
        if (deserializer.keysAscend()) return mergeStruct(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
    }

    try deserializer.beginObject();

    var seen: [info.field_names.len]bool = @splat(false);
    errdefer freePartialStruct(s, T, allocator, dest, &seen, borrowed_strings);

    // The members the type does not declare go to its extras field, when it has one.
    const extras_name = comptime meta.extrasField(T);
    if (comptime extras_name != null) checkExtrasField(T, info, DeserializerType);
    const extras_mark = if (comptime extras_name != null) deserializer.extrasMark() else {};

    if (@hasDecl(DeserializerType, "nextObjectFieldIndex")) {
        while (true) {
            switch (try deserializer.nextObjectFieldIndex(T, cfg)) {
                .end => break,
                .unknown => {
                    if (comptime extras_name != null) {
                        const key = try deserializer.unknownKey(allocator);
                        defer key.deinit(allocator);
                        try deserializer.captureExtra(allocator, key.bytes);
                    } else {
                        if (meta.effectiveDenyUnknownFields(T, cfg)) return error.UnknownField;
                        try deserializer.skipValue(allocator);
                    }
                },
                .field_index => |field_index| {
                    inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
                        if (field_index == i) {
                            if (seen[i]) return error.DuplicateField;
                            try deserializeStructField(s, T, field_name, field_type, &@field(dest.*, field_name), allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
                            seen[i] = true;
                        }
                    }
                },
            }
        }

        if (comptime extras_name != null) try storeExtras(s, T, info, allocator, deserializer, extras_mark, dest, &seen);
        try fillMissingFields(s, T, info, cfg, allocator, dest, &seen);
        try s.check(T, allocator, dest);
        return;
    }

    while (try deserializer.nextObjectField(allocator)) |object_field| {
        defer object_field.deinit(allocator);

        if (matchStructFieldIndexInfo(T, info, cfg, object_field.bytes)) |field_index| {
            inline for (info.field_names, info.field_types, 0..) |struct_field_name, field_type, i| {
                if (field_index == i) {
                    if (seen[i]) return error.DuplicateField;
                    try deserializeStructField(s, T, struct_field_name, field_type, &@field(dest.*, struct_field_name), allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
                    seen[i] = true;
                }
            }
        } else {
            if (comptime extras_name != null) {
                try deserializer.captureExtra(allocator, object_field.bytes);
            } else {
                // Unknown-field policy also lives at the typed layer so every format behaves the same way.
                if (meta.effectiveDenyUnknownFields(T, cfg)) return error.UnknownField;
                try deserializer.skipValue(allocator);
            }
        }
    }

    if (comptime extras_name != null) try storeExtras(s, T, info, allocator, deserializer, extras_mark, dest, &seen);
    try fillMissingFields(s, T, info, cfg, allocator, dest, &seen);
    try s.check(T, allocator, dest);
}

/// A `SortedMap`: the entries of a map of text keys. Every read refuses a repeated key (`error.DuplicateField`); a strict CBOR
/// read also refuses a key that does not sort after the one before it (`error.NonDeterministicEncoding`); any other read
/// (lenient CBOR, JSON) accepts the keys in any order and sorts the entries, so the value is always sorted and binary search
/// holds. A key is the input's own bytes in an aliased read and a copy otherwise; the entries are one exact allocation when the
/// format states their number. `bounds.max_len` is checked before that allocation, and at each entry when the format does not
/// state it, and `bounds.elem` bounds each value.
fn deserializeSortedMap(
    s: anytype,
    comptime T: type,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    comptime bounds: meta.Bounds,
    rc: anytype,
) anyerror!void {
    const DeserializerType = @TypeOf(deserializer.*);
    const Entry = T.Entry;
    const Out = @TypeOf(s).Of;
    const borrowed_strings = @hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings();
    if (comptime @TypeOf(rc) != NoRead) return resume_read.sortedMap(s, T, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, bounds, rc);
    try deserializer.beginObject();
    var items: std.ArrayList(Out(Entry)) = .empty;
    errdefer {
        for (items.items) |item| s.free(Entry, allocator, item, borrowed_strings);
        items.deinit(allocator);
    }
    if (comptime @hasDecl(DeserializerType, "objectLen")) {
        if (deserializer.objectLen()) |count| {
            // Bounds are checked before the allocation they exist to limit.
            try checkLength(bounds, count);
            try items.ensureTotalCapacityPrecise(allocator, count);
        }
    }
    var unsorted = false;
    var previous: ?[]const u8 = null;
    while (try nextSortedMapKey(deserializer, allocator)) |token| {
        errdefer token.deinit(allocator);
        if (items.items.len >= bounds.max_len) return error.LengthOutOfBounds;
        const key: []const u8 = if (borrowed_strings or token.allocated) token.bytes else try allocator.dupe(u8, token.bytes);
        // A key copied here is freed here on a failure; an escaped one is the token's, which is freed above.
        var owned = !borrowed_strings and !token.allocated;
        errdefer if (owned) allocator.free(@constCast(key));
        if (previous) |before| switch (sorted.order(before, key)) {
            .lt => {},
            .eq => return error.DuplicateField,
            // A strict CBOR read refuses a key out of order as it reads it (`cbor.Mode.strict`); any other read sorts the
            // entries when the map is done.
            .gt => unsorted = true,
        };
        previous = key;
        var value: Out(T.Value) = undefined;
        try deserializeElement(s, T.Value, &value, allocator, deserializer, cfg, diagnostics, track_diagnostics, items.items.len, bounds, rc);
        errdefer s.free(T.Value, allocator, value, borrowed_strings);
        try items.append(allocator, .{ .key = try s.text([]const u8, key), .value = value });
        owned = false;
    }
    if (unsorted) try sortEntries(s, Out(Entry), items.items);
    try checkLength(bounds, items.items.len);
    dest.* = .{ .entries = try s.list([]const Entry, try items.toOwnedSlice(allocator)) };
}

/// Sorts the entries of a `SortedMap` read out of order by their keys, which `s` resolves; two equal keys are a repeat. Nothing
/// is freed here: on an error the caller frees every item.
fn sortEntries(s: anytype, comptime Item: type, items: []Item) error{DuplicateField}!void {
    const Sink = @TypeOf(s);
    std.sort.pdq(Item, items, s, struct {
        fn less(sink: Sink, a: Item, b: Item) bool {
            return sorted.order(sink.textOf(a.key), sink.textOf(b.key)) == .lt;
        }
    }.less);
    for (items[@min(1, items.len)..], 0..) |item, before| {
        if (sorted.order(s.textOf(items[before].key), s.textOf(item.key)) == .eq) return error.DuplicateField;
    }
}

/// The next key of a `SortedMap`: by a format that records keys for a repeat check (`nextSortedKey`), one that is not
/// recorded, since the sorted order refuses a repeat by itself.
fn nextSortedMapKey(deserializer: anytype, allocator: Allocator) anyerror!?StringToken {
    if (comptime @hasDecl(@TypeOf(deserializer.*), "nextSortedKey")) return deserializer.nextSortedKey(allocator);
    return deserializer.nextObjectField(allocator);
}

/// A struct whose fields are declared in key order, read from a deserializer that guarantees its keys ascend (`keysAscend`):
/// one walk over the fields and the input together. A key names field `f`, so every field before it that was not named is
/// absent, and is resolved at once; there are no seen flags and no pass at the end for the fields after the last key.
fn mergeStruct(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    rc: anytype,
) anyerror!void {
    const DeserializerType = @TypeOf(deserializer.*);
    const borrowed_strings = @hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings();
    if (comptime structHasIntegerKeys(T, info, cfg) and !@hasDecl(DeserializerType, "supports_integer_keys")) {
        @compileError("format " ++ @typeName(DeserializerType) ++ " does not support integer keys: " ++ @typeName(T));
    }
    try deserializer.beginObject();
    // The fields before `cursor` have a value: read, or resolved as absent.
    var cursor: usize = 0;
    errdefer inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
        if (i < cursor) s.free(field_type, allocator, @field(dest.*, field_name), borrowed_strings);
    };
    while (true) {
        switch (try deserializer.nextObjectFieldIndex(T, cfg)) {
            .end => break,
            .unknown => {
                if (meta.effectiveDenyUnknownFields(T, cfg)) return error.UnknownField;
                try deserializer.skipValue(allocator);
            },
            .field_index => |field_index| {
                inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
                    if (field_index == i) {
                        inline for (0..i) |absent| {
                            if (absent >= cursor) {
                                try fillField(s, T, info, cfg, allocator, dest, absent);
                                cursor = absent + 1;
                            }
                        }
                        try deserializeStructField(s, T, field_name, field_type, &@field(dest.*, field_name), allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
                        cursor = i + 1;
                    }
                }
            },
        }
    }
    inline for (0..info.field_names.len) |i| {
        if (i >= cursor) {
            try fillField(s, T, info, cfg, allocator, dest, i);
            cursor = i + 1;
        }
    }
    try s.check(T, allocator, dest);
}

/// The extras field holds one map item, as a `Raw`, or an optional one, that is null when there is none.
fn checkExtrasField(comptime T: type, comptime info: std.builtin.Type.Struct, comptime DeserializerType: type) void {
    if (!@hasDecl(DeserializerType, "captureExtra")) {
        @compileError("format " ++ @typeName(DeserializerType) ++ " cannot collect extras: " ++ @typeName(T));
    }
    const name = comptime meta.extrasField(T).?;
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (comptime std.mem.eql(u8, field_name, name)) {
            if (comptime !isRawOrOptional(field_type)) {
                @compileError("the extras field must be a Raw or an optional Raw: " ++ @typeName(T) ++ "." ++ name);
            }
            return;
        }
    }
    @compileError("serde.extras names no field: " ++ @typeName(T) ++ "." ++ name);
}

/// Ends the extras of the struct just read and stores them in the extras field.
fn storeExtras(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    allocator: Allocator,
    deserializer: anytype,
    mark: anytype,
    result: *@TypeOf(s).Of(T),
    seen: *[info.field_names.len]bool,
) anyerror!void {
    const name = comptime meta.extrasField(T).?;
    inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
        if (comptime std.mem.eql(u8, field_name, name)) {
            const owned = try deserializer.finishExtras(allocator, mark, isRaw(field_type));
            if (comptime isRaw(field_type)) {
                @field(result.*, field_name) = try s.bytesOf(field_type, owned.?);
            } else if (owned) |bytes| {
                s.someDest(field_type, &@field(result.*, field_name), true).* = try s.bytesOf(@typeInfo(field_type).optional.child, bytes);
            } else {
                @field(result.*, field_name) = try s.none(field_type);
            }
            seen[i] = true;
        }
    }
}

/// Reads one struct field's value under the field's optional policy.
///
/// A nested optional (`??T`) is the field whose absence differs from its null: a present field
/// reads as the inner optional, so `null` is `.{ null }` and a missing field is the outer null.
/// A plain optional with the `absent` policy refuses an explicit null.
pub fn deserializeStructField(
    s: anytype,
    comptime T: type,
    comptime field_name: []const u8,
    comptime FieldType: type,
    dest: *@TypeOf(s).Of(FieldType),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    rc: anytype,
) anyerror!void {
    const bounds = comptime meta.effectiveBounds(T, field_name, cfg);
    if (comptime isNestedOptional(FieldType)) {
        const Inner = @typeInfo(FieldType).optional.child;
        var local: ReadLevel = .{};
        const level: *ReadLevel = if (comptime @TypeOf(rc) != NoRead) rc.enter() else &local;
        defer if (comptime @TypeOf(rc) != NoRead) rc.leave();
        const inner = s.someDest(FieldType, dest, level.phase == 0);
        level.phase = 1;
        try deserializeFieldValue(s, Inner, inner, allocator, deserializer, cfg, diagnostics, track_diagnostics, field_name, bounds, rc);
        level.* = .{};
        return;
    }
    if (comptime @typeInfo(FieldType) == .optional and meta.effectiveOptionalPolicy(T, field_name, cfg) == .absent) {
        // An explicit null is refused where the value begins, once: a resumable read does not look again.
        var local: ReadLevel = .{};
        const level: *ReadLevel = if (comptime @TypeOf(rc) != NoRead) rc.enter() else &local;
        defer if (comptime @TypeOf(rc) != NoRead) rc.leave();
        if (level.phase == 0) {
            if (try deserializer.peekKind() == .null) return error.UnexpectedType;
            level.phase = 1;
        }
        try deserializeFieldValue(s, FieldType, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, field_name, bounds, rc);
        level.* = .{};
        return;
    }
    try deserializeFieldValue(s, FieldType, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, field_name, bounds, rc);
}

/// Resolves fields the input did not name, after the object is fully consumed: a declared default,
/// else null for an optional, else an error. An optional with the `nullable` policy must be named.
fn fillMissingFields(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    comptime cfg: anytype,
    allocator: Allocator,
    result: *@TypeOf(s).Of(T),
    seen: *const [info.field_names.len]bool,
) anyerror!void {
    inline for (0..info.field_names.len) |i| {
        if (!seen[i]) try fillField(s, T, info, cfg, allocator, result, i);
    }
}

/// The value of field `i` when the input did not name it.
pub fn fillField(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    comptime cfg: anytype,
    allocator: Allocator,
    result: *@TypeOf(s).Of(T),
    comptime i: usize,
) anyerror!void {
    const field_name = info.field_names[i];
    const field_type = info.field_types[i];
    if (info.field_attrs[i].defaultValue(field_type)) |default_value| {
        @field(result.*, field_name) = try s.fromDefault(field_type, allocator, default_value);
    } else if (@typeInfo(field_type) == .optional) {
        if (comptime !isNestedOptional(field_type) and meta.effectiveOptionalPolicy(T, field_name, cfg) == .nullable) {
            return error.MissingField;
        }
        @field(result.*, field_name) = try s.none(field_type);
    } else {
        return error.MissingField;
    }
}

fn structHasIntegerKeys(comptime T: type, comptime info: std.builtin.Type.Struct, comptime cfg: anytype) bool {
    inline for (info.field_names) |field_name| {
        if (meta.effectiveFieldKey(T, field_name, cfg) == .integer) return true;
    }
    return false;
}

/// One element of an array field: read as the field's `elem` bounds say, if it has any.
pub fn deserializeElement(
    s: anytype,
    comptime T: type,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    index: usize,
    comptime bounds: meta.Bounds,
    rc: anytype,
) anyerror!void {
    if (comptime bounds.elem == null) return deserializeIndexedValue(s, T, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, index, rc);
    const elem = comptime bounds.elem.?;
    if (track_diagnostics) diagnostics.?.pushIndex(index);
    deserializeBounded(s, T, elem.*, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc) catch |err| return err;
    if (track_diagnostics) diagnostics.?.pop();
}

pub fn deserializeIndexedValue(
    s: anytype,
    comptime T: type,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    index: usize,
    rc: anytype,
) anyerror!void {
    if (track_diagnostics) diagnostics.?.pushIndex(index);
    deserializeValue(s, T, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc) catch |err| return err;
    if (track_diagnostics) diagnostics.?.pop();
}

/// Whether the field has a `max_len`.
fn hasMax(comptime bounds: meta.Bounds) bool {
    return bounds.max_len != std.math.maxInt(usize);
}

pub fn checkLength(comptime bounds: meta.Bounds, len: usize) error{LengthOutOfBounds}!void {
    if (len < bounds.min_len or len > bounds.max_len) return error.LengthOutOfBounds;
}

/// Reads a value that has bounds: a text, byte, raw or array length, or an integer range. The
/// length is checked before the memory it would take is allocated where the format states it first.
fn deserializeBounded(
    s: anytype,
    comptime T: type,
    comptime bounds: meta.Bounds,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    rc: anytype,
) anyerror!void {
    switch (@typeInfo(T)) {
        .optional => |info| try deserializeOptional(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, bounds, rc),
        .int => {
            if (comptime bounds.validate != null) @compileError("validate applies to a Raw field: " ++ @typeName(T));
            try deserializeValue(s, T, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
            if (bounds.min) |min| if (dest.* < min) return error.ValueOutOfRange;
            if (bounds.max) |max| if (dest.* > max) return error.ValueOutOfRange;
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("length bounds apply to a slice: " ++ @typeName(T));
            if (comptime bounds.validate != null) @compileError("validate applies to a Raw field: " ++ @typeName(T));
            try deserializePointer(s, T, info, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, bounds, rc);
        },
        .@"struct" => {
            if (comptime bounds.validate != null and !isRaw(T)) @compileError("validate applies to a Raw field: " ++ @typeName(T));
            if (T == ByteString) {
                try readByteString(s, T, dest, allocator, deserializer, bounds, rc);
            } else if (comptime isRaw(T)) {
                dest.* = try s.bytesOf(T, try readRawSlice(T, allocator, deserializer, bounds, rc));
            } else if (comptime isSortedMap(T)) {
                try deserializeSortedMap(s, T, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, bounds, rc);
            } else {
                @compileError("bounds apply to text, bytes, arrays and integers: " ++ @typeName(T));
            }
        },
        else => @compileError("bounds apply to text, bytes, arrays and integers: " ++ @typeName(T)),
    }
}

/// Consumes a null and returns true, or returns false and leaves the input alone.
fn readNullIfPresent(deserializer: anytype) anyerror!bool {
    const DeserializerType = @TypeOf(deserializer.*);
    if (@hasDecl(DeserializerType, "readOptionalPresent")) return !try deserializer.readOptionalPresent();
    if (try deserializer.peekKind() == .null) {
        try deserializer.readNull();
        return true;
    }
    return false;
}

pub fn deserializeFieldValue(
    s: anytype,
    comptime T: type,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    comptime field_name: []const u8,
    comptime bounds: meta.Bounds,
    rc: anytype,
) anyerror!void {
    if (track_diagnostics) diagnostics.?.pushField(field_name);
    (if (comptime bounds.isDefault())
        deserializeValue(s, T, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc)
    else
        deserializeBounded(s, T, bounds, dest, allocator, deserializer, cfg, diagnostics, track_diagnostics, rc)) catch |err| return err;
    if (track_diagnostics) diagnostics.?.pop();
}

/// Index of the field whose wire key is the text `actual`.
pub fn matchStructFieldIndex(comptime T: type, comptime cfg: anytype, actual: []const u8) ?usize {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("field index matching requires a struct type");
    return matchStructFieldIndexInfo(T, info.@"struct", cfg, actual);
}

fn matchStructFieldIndexInfo(
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    comptime cfg: anytype,
    actual: []const u8,
) ?usize {
    inline for (info.field_names, 0..) |field_name, i| {
        if (comptime meta.isExtrasField(T, field_name)) continue;
        switch (comptime meta.effectiveFieldKey(T, field_name, cfg)) {
            .text => |expected| if (expected.len == actual.len and std.mem.eql(u8, actual, expected)) return i,
            .integer => {},
        }
    }

    return null;
}

/// Index of the field whose wire key is the integer `actual`.
pub fn matchStructFieldIndexInteger(comptime T: type, comptime cfg: anytype, actual: i128) ?usize {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("field index matching requires a struct type");
    inline for (info.@"struct".field_names, 0..) |field_name, i| {
        if (comptime meta.isExtrasField(T, field_name)) continue;
        switch (comptime meta.effectiveFieldKey(T, field_name, cfg)) {
            .text => {},
            .integer => |expected| if (expected == actual) return i,
        }
    }

    return null;
}

fn freeTyped(comptime T: type, allocator: Allocator, value: T) void {
    freeTypedPartial(T, allocator, value, false);
}

fn freeTypedPartial(comptime T: type, allocator: Allocator, value: T, borrowed_strings: bool) void {
    if (comptime hasHook(T, "zerdeFree")) {
        if (!borrowed_strings) value.zerdeFree(allocator);
        return;
    }
    // A wire type with hooks and no `zerdeFree` is left alone, as the README says.
    if (comptime hasHook(T, "zerdeDecode") or hasHook(T, "zerdeEncode")) return;
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float, .@"enum" => {},
        .optional => {
            if (value) |child| freeTypedPartial(@TypeOf(child), allocator, child, borrowed_strings);
        },
        .array => |info| {
            if (info.child == u8) return;
            for (value) |item| freeTypedPartial(info.child, allocator, item, borrowed_strings);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) {
                    if (!borrowed_strings) allocator.free(value);
                } else {
                    for (value) |item| freeTypedPartial(info.child, allocator, item, borrowed_strings);
                    allocator.free(value);
                }
            },
            .one => {
                freeTypedPartial(info.child, allocator, value.*, borrowed_strings);
                allocator.destroy(value);
            },
            else => {},
        },
        .@"struct" => |info| {
            inline for (info.field_names, info.field_types, info.field_attrs) |field_name, field_type, field_attrs| {
                if (!field_attrs.@"comptime") {
                    freeTypedPartial(field_type, allocator, @field(value, field_name), borrowed_strings);
                }
            }
        },
        .@"union" => {
            switch (value) {
                inline else => |payload| freeTypedPartial(@TypeOf(payload), allocator, payload, borrowed_strings),
            }
        },
        else => {},
    }
}

fn freePartialStruct(
    s: anytype,
    comptime T: type,
    allocator: Allocator,
    result: *@TypeOf(s).Of(T),
    seen: *[@typeInfo(T).@"struct".field_names.len]bool,
    borrowed_strings: bool,
) void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
        if (seen[i]) s.free(field_type, allocator, @field(result.*, field_name), borrowed_strings);
    }
}
