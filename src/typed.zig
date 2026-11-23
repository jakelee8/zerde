//! Format-independent typed walk.
//!
//! This layer reflects on `T` with `@typeInfo` and drives a format backend
//! through a small serializer/deserializer protocol. The backend knows how to
//! emit or read one concrete format; this file knows how to walk arbitrary Zig
//! data structures.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic_mod = @import("diagnostic.zig");
const meta = @import("meta.zig");

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
    try serializeValue(&serializer, value, serde_cfg, Format, comptime fieldOrderPolicy(Format, format_cfg));
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
    return deserializeValue(T, allocator, deserializer, cfg, null, false);
}

pub fn deserializeWithDiagnostics(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
) anyerror!T {
    return deserializeValue(T, allocator, deserializer, cfg, diagnostics, true);
}

fn serializeValue(
    serializer: anytype,
    value: anytype,
    comptime cfg: anytype,
    comptime Format: type,
    comptime order_policy: meta.FieldOrderPolicy,
) !void {
    const T = @TypeOf(value);
    const SerializerType = @TypeOf(serializer.*);
    if (comptime hasHook(T, "zerdeEncode")) {
        if (!@hasDecl(SerializerType, "encoder")) {
            @compileError("format " ++ @typeName(SerializerType) ++ " cannot call the encode hook of " ++ @typeName(T));
        }
        var encoder = serializer.encoder();
        try value.zerdeEncode(&encoder);
        return;
    }
    switch (@typeInfo(T)) {
        .bool => try serializer.emitBool(value),
        .int, .comptime_int => try serializer.emitInteger(value),
        .float, .comptime_float => try serializer.emitFloat(value),
        .optional => |info| {
            if (@typeInfo(info.child) == .optional) {
                @compileError("a nested optional is only supported as a struct field, where an absent field and null differ: " ++ @typeName(T));
            }
            if (@hasDecl(SerializerType, "beginOptional")) {
                if (value) |child| {
                    try serializer.beginOptional(true);
                    try serializeValue(serializer, child, cfg, Format, order_policy);
                } else {
                    try serializer.beginOptional(false);
                }
            } else {
                if (value) |child| {
                    try serializeValue(serializer, child, cfg, Format, order_policy);
                } else {
                    try serializer.emitNull();
                }
            }
        },
        .@"enum" => {
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
                        switch (comptime key) {
                            .text => |name| try serializer.emitString(name),
                            .integer => |number| try serializer.emitInteger(number),
                        }
                    } else {
                        if (@hasDecl(SerializerType, "beginStructSized")) {
                            try serializer.beginStructSized(T, 1);
                        } else {
                            try serializer.beginStruct(T);
                        }
                        switch (comptime key) {
                            .text => |name| _ = try serializer.beginStructField(T, name, Payload),
                            .integer => |number| _ = try serializer.beginStructFieldInteger(T, number, Payload),
                        }
                        try serializeValue(serializer, payload, cfg, Format, order_policy);
                        try serializer.endStructField(T, @tagName(tag), Payload);
                        try serializer.endStruct(T);
                    }
                },
            }
        },
        .array => |info| {
            if (info.child == u8) {
                try emitByteString(serializer, value[0..]);
                return;
            }

            if (@hasDecl(SerializerType, "serializeSequence")) {
                if (try serializer.serializeSequence(T, value, cfg)) return;
            }

            try serializer.beginArray(info.child, value.len);
            for (value, 0..) |item, index| {
                try serializer.beginArrayItem(info.child, index);
                try serializeValue(serializer, item, cfg, Format, order_policy);
                try serializer.endArrayItem(info.child, index);
            }
            try serializer.endArray(info.child, value.len);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) {
                    try serializer.emitString(value);
                    return;
                }

                if (@hasDecl(SerializerType, "serializeSequence")) {
                    if (try serializer.serializeSequence(T, value, cfg)) return;
                }

                try serializer.beginArray(info.child, value.len);
                for (value, 0..) |item, index| {
                    try serializer.beginArrayItem(info.child, index);
                    try serializeValue(serializer, item, cfg, Format, order_policy);
                    try serializer.endArrayItem(info.child, index);
                }
                try serializer.endArray(info.child, value.len);
            },
            .one => try serializeValue(serializer, value.*, cfg, Format, order_policy),
            else => @compileError("zerde cannot serialize pointer type " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            if (T == ByteString) {
                try emitByteString(serializer, value.bytes);
                return;
            }
            if (comptime isRaw(T)) {
                if (!@hasDecl(SerializerType, "emitRaw") or SerializerType.raw_format != T.zerde_raw_format) {
                    @compileError("format " ++ @typeName(SerializerType) ++ " cannot write a " ++ @tagName(T.zerde_raw_format) ++ " Raw item");
                }
                try serializer.emitRaw(value.bytes);
                return;
            }
            if (info.is_tuple) @compileError("tuple structs are not supported: " ++ @typeName(T));

            // The extras field is not a member: its entries are members of this struct's map.
            const extras_name = comptime meta.extrasField(T);
            if (comptime extras_name != null and !@hasDecl(SerializerType, "beginExtras")) {
                @compileError("format " ++ @typeName(SerializerType) ++ " cannot write extras: " ++ @typeName(T));
            }
            const extras_bytes: []const u8 = if (comptime extras_name) |name| extrasBytes(@field(value, name)) else &.{};

            // TOML uses two passes so scalars appear before nested tables; JSON stays at one pass.
            const pass_count = comptime SerializerType.structPassCount(T);
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
            const field_order = comptime structFieldOrder(T, Format, info, cfg, order_policy);
            var extras = if (comptime extras_name != null) try serializer.beginExtras(extras_bytes) else {};
            // In key order the extras are merged among the declared members; otherwise they follow them.
            const merge_extras = comptime extras_name != null and meta.effectiveFieldOrder(T, cfg, order_policy) == .encoded_key;
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
                            if (comptime merge_extras) {
                                try serializer.emitExtrasBefore(&extras, comptime Format.encodeKey(meta.effectiveFieldKey(T, field_name, cfg)));
                            }
                            const emit_value = switch (comptime meta.effectiveFieldKey(T, field_name, cfg)) {
                                .text => |emitted_name| if (@hasDecl(SerializerType, "beginStructFieldValue"))
                                    try serializer.beginStructFieldValue(T, emitted_name, field_type, field_value)
                                else
                                    try serializer.beginStructField(T, emitted_name, field_type),
                                .integer => |emitted_key| if (@hasDecl(SerializerType, "supports_integer_keys"))
                                    try serializer.beginStructFieldInteger(T, emitted_key, field_type)
                                else
                                    @compileError("format " ++ @typeName(SerializerType) ++ " does not support integer keys: " ++ @typeName(T) ++ "." ++ field_name),
                            };
                            if (emit_value) {
                                // A present nested optional field is written as its inner optional: null is
                                // a value there, and the outer null was omitted above.
                                if (comptime isNestedOptional(field_type)) {
                                    try serializeValue(serializer, field_value.?, cfg, Format, order_policy);
                                } else {
                                    try serializeValue(serializer, field_value, cfg, Format, order_policy);
                                }
                            }
                            switch (comptime meta.effectiveFieldKey(T, field_name, cfg)) {
                                .text => |emitted_name| try serializer.endStructField(T, emitted_name, field_type),
                                .integer => try serializer.endStructField(T, field_name, field_type),
                            }
                        }
                    }
                }
            }
            if (comptime extras_name != null) try serializer.finishExtras(&extras, comptime declaredKeys(T, info, cfg));
            try serializer.endStruct(T);
        },
        else => @compileError("zerde cannot serialize " ++ @typeName(T)),
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

fn deserializeValue(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
) anyerror!T {
    const DeserializerType = @TypeOf(deserializer.*);
    if (comptime hasHook(T, "zerdeDecode")) {
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
        return decoded;
    }
    return switch (@typeInfo(T)) {
        .bool => try deserializer.readBool(),
        // Formats parse numbers once into a common token; the typed layer is responsible for exact casts.
        .int, .comptime_int => if (@hasDecl(DeserializerType, "readInt"))
            try deserializer.readInt(T)
        else
            decodeIntNumber(T, try deserializer.readNumber()),
        .float, .comptime_float => if (@hasDecl(DeserializerType, "readFloat"))
            try deserializer.readFloat(T)
        else
            decodeFloatNumber(T, try deserializer.readNumber()),
        .optional => |info| blk: {
            if (@typeInfo(info.child) == .optional) {
                @compileError("a nested optional is only supported as a struct field, where an absent field and null differ: " ++ @typeName(T));
            }
            if (@hasDecl(DeserializerType, "readOptionalPresent")) {
                if (!try deserializer.readOptionalPresent()) break :blk null;
            } else {
                if (try deserializer.peekKind() == .null) {
                    try deserializer.readNull();
                    break :blk null;
                }
            }
            break :blk try deserializeValue(info.child, allocator, deserializer, cfg, diagnostics, track_diagnostics);
        },
        .@"enum" => try decodeEnumValue(T, allocator, deserializer, cfg),
        .@"union" => |info| try deserializeUnion(T, info, allocator, deserializer, cfg, diagnostics, track_diagnostics),
        .array => |info| try deserializeArray(T, info, allocator, deserializer, cfg, diagnostics, track_diagnostics),
        .pointer => |info| try deserializePointer(T, info, allocator, deserializer, cfg, diagnostics, track_diagnostics, .{}),
        .@"struct" => |info| if (T == ByteString)
            ByteString{ .bytes = try readByteSlice(allocator, deserializer, .{}) }
        else if (comptime isRaw(T))
            T{ .bytes = try readRawSlice(T, allocator, deserializer, .{}) }
        else
            try deserializeStruct(T, info, allocator, deserializer, cfg, diagnostics, track_diagnostics),
        else => error.UnsupportedType,
    };
}

fn deserializeUnion(
    comptime T: type,
    comptime info: std.builtin.Type.Union,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
) anyerror!T {
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

    switch (try deserializer.peekKind()) {
        .string => {
            const token = try deserializer.readString(allocator);
            defer token.deinit(allocator);
            inline for (info.field_names, info.field_types) |name, FieldType| {
                if (FieldType == void and variantHasText(T, name, cfg, token.bytes)) return @unionInit(T, name, {});
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
                if (FieldType == void and variantHasInteger(T, name, cfg, number)) return @unionInit(T, name, {});
            }
            return error.InvalidEnumTag;
        },
        .object => {
            try deserializer.beginObject();
            const key = (try nextUnionKey(deserializer, allocator, integer_keys)) orelse return error.LengthMismatch;
            defer if (key == .text) key.text.deinit(allocator);

            const result: T = blk: {
                inline for (info.field_names, info.field_types) |name, FieldType| {
                    const matches = switch (key) {
                        .text => |token| variantHasText(T, name, cfg, token.bytes),
                        .integer => |number| variantHasInteger(T, name, cfg, number),
                    };
                    if (FieldType != void and matches) {
                        const payload = try deserializeFieldValue(FieldType, allocator, deserializer, cfg, diagnostics, track_diagnostics, name, .{});
                        break :blk @unionInit(T, name, payload);
                    }
                }
                return error.InvalidEnumTag;
            };
            errdefer freeTypedPartial(T, allocator, result, borrowed_strings);

            // A union is one entry: a second one is not another variant.
            if (try nextUnionKey(deserializer, allocator, integer_keys)) |extra| {
                if (extra == .text) extra.text.deinit(allocator);
                return error.LengthMismatch;
            }
            return result;
        },
        else => return error.UnexpectedType,
    }
}

/// A map key that is text or an integer, for formats that allow both (`supports_integer_keys`).
pub const ObjectKey = union(enum) {
    text: StringToken,
    integer: i128,
};

fn nextUnionKey(deserializer: anytype, allocator: Allocator, comptime integer_keys: bool) anyerror!?ObjectKey {
    if (integer_keys) return try deserializer.nextObjectKey(allocator);
    const token = (try deserializer.nextObjectField(allocator)) orelse return null;
    return .{ .text = token };
}

fn unionHasIntegerKeys(comptime T: type, comptime info: std.builtin.Type.Union, comptime cfg: anytype) bool {
    inline for (info.field_names) |name| {
        if (meta.effectiveFieldKey(T, name, cfg) == .integer) return true;
    }
    return false;
}

fn variantHasText(comptime T: type, comptime name: []const u8, comptime cfg: anytype, bytes: []const u8) bool {
    return switch (comptime meta.effectiveFieldKey(T, name, cfg)) {
        .text => |text| std.mem.eql(u8, bytes, text),
        .integer => false,
    };
}

fn variantHasInteger(comptime T: type, comptime name: []const u8, comptime cfg: anytype, number: i128) bool {
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

fn decodeEnumValue(comptime T: type, allocator: Allocator, deserializer: anytype, comptime cfg: anytype) anyerror!T {
    const DeserializerType = @TypeOf(deserializer.*);
    if (@hasDecl(DeserializerType, "readEnumTag")) {
        return try deserializer.readEnumTag(T);
    }

    return switch (try deserializer.peekKind()) {
        .string => blk: {
            // An enum written as its number reads only a number.
            if (comptime meta.effectiveEnumRepr(T, cfg) == .integer) return error.UnexpectedType;
            const token = try deserializer.readString(allocator);
            defer token.deinit(allocator);
            break :blk std.meta.stringToEnum(T, token.bytes) orelse error.InvalidEnumTag;
        },
        .number => blk: {
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
    comptime T: type,
    comptime info: std.builtin.Type.Array,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
) anyerror!T {
    const DeserializerType = @TypeOf(deserializer.*);

    if (info.child == u8) {
        // A byte array is read from the format's byte-string token, never from a text string.
        const token = try readByteToken(allocator, deserializer);
        defer token.deinit(allocator);

        if (token.bytes.len != info.len) return error.LengthMismatch;
        var result: T = undefined;
        @memcpy(result[0..], token.bytes);
        return result;
    }

    const known_len = try beginArrayWithKnownLen(deserializer);
    if (known_len) |len| {
        if (len != info.len) return error.LengthMismatch;
    }
    var result: T = undefined;

    if (known_len) |_| {
        if (@hasDecl(DeserializerType, "finishKnownLenArray")) {
            inline for (0..info.len) |index| {
                result[index] = try deserializeIndexedValue(info.child, allocator, deserializer, cfg, diagnostics, track_diagnostics, index);
            }
            try deserializer.finishKnownLenArray();
        } else {
            inline for (0..info.len) |index| {
                if (!try deserializer.nextArrayItem()) return error.LengthMismatch;
                result[index] = try deserializeIndexedValue(info.child, allocator, deserializer, cfg, diagnostics, track_diagnostics, index);
            }
            if (try deserializer.nextArrayItem()) return error.LengthMismatch;
        }
        return result;
    }

    var index: usize = 0;
    while (try deserializer.nextArrayItem()) {
        if (index >= info.len) return error.LengthMismatch;
        result[index] = try deserializeIndexedValue(info.child, allocator, deserializer, cfg, diagnostics, track_diagnostics, index);
        index += 1;
    }

    if (index != info.len) return error.LengthMismatch;
    return result;
}

fn deserializePointer(
    comptime T: type,
    comptime info: std.builtin.Type.Pointer,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    comptime bounds: meta.Bounds,
) anyerror!T {
    const DeserializerType = @TypeOf(deserializer.*);
    const borrowed_strings = @hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings();

    switch (info.size) {
        .slice => {
            if (info.child == u8) {
                const token = if (comptime hasMax(bounds) and @hasDecl(DeserializerType, "readStringMax"))
                    try deserializer.readStringMax(allocator, bounds.max_len)
                else
                    try deserializer.readString(allocator);
                errdefer token.deinit(allocator);
                try checkLength(bounds, token.bytes.len);
                // Aliased slice parses can hand byte and string fields straight back to the caller without copying.
                if (borrowed_strings) {
                    return token.bytes;
                }
                if (token.allocated) {
                    return if (info.attrs.@"const") token.bytes else @constCast(token.bytes);
                }
                defer token.deinit(allocator);
                return allocator.dupe(info.child, token.bytes);
            }

            const known_len = try beginArrayWithKnownLen(deserializer);
            if (known_len) |len| {
                // Bounds are checked before the allocation they exist to limit.
                try checkLength(bounds, len);
                const items = try allocator.alloc(info.child, len);
                errdefer allocator.free(items);

                var initialized: usize = 0;
                errdefer {
                    for (items[0..initialized]) |item| freeTypedPartial(info.child, allocator, item, borrowed_strings);
                }

                if (@hasDecl(DeserializerType, "finishKnownLenArray")) {
                    for (0..len) |index| {
                        items[index] = try deserializeIndexedValue(info.child, allocator, deserializer, cfg, diagnostics, track_diagnostics, index);
                        initialized = index + 1;
                    }
                    try deserializer.finishKnownLenArray();
                } else {
                    for (0..len) |index| {
                        if (!try deserializer.nextArrayItem()) return error.LengthMismatch;
                        items[index] = try deserializeIndexedValue(info.child, allocator, deserializer, cfg, diagnostics, track_diagnostics, index);
                        initialized = index + 1;
                    }

                    if (try deserializer.nextArrayItem()) return error.LengthMismatch;
                }

                return items;
            }

            var items: std.ArrayList(info.child) = .empty;
            errdefer {
                for (items.items) |item| freeTypedPartial(info.child, allocator, item, borrowed_strings);
                items.deinit(allocator);
            }

            while (try deserializer.nextArrayItem()) {
                if (items.items.len >= bounds.max_len) return error.LengthOutOfBounds;
                const item = try deserializeIndexedValue(info.child, allocator, deserializer, cfg, diagnostics, track_diagnostics, items.items.len);
                errdefer freeTypedPartial(info.child, allocator, item, borrowed_strings);
                try items.append(allocator, item);
            }
            try checkLength(bounds, items.items.len);

            return items.toOwnedSlice(allocator);
        },
        .one => {
            const ptr = try allocator.create(info.child);
            errdefer allocator.destroy(ptr);
            ptr.* = try deserializeValue(info.child, allocator, deserializer, cfg, diagnostics, track_diagnostics);
            return ptr;
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
fn readRawSlice(comptime T: type, allocator: Allocator, deserializer: anytype, comptime bounds: meta.Bounds) anyerror![]const u8 {
    const DeserializerType = @TypeOf(deserializer.*);
    if (!@hasDecl(DeserializerType, "readRaw") or DeserializerType.raw_format != T.zerde_raw_format) {
        @compileError("format " ++ @typeName(DeserializerType) ++ " cannot read a " ++ @tagName(T.zerde_raw_format) ++ " Raw item");
    }
    const token = try deserializer.readRaw(allocator);
    try checkLength(bounds, token.bytes.len);
    if (@hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings()) return token.bytes;
    return allocator.dupe(u8, token.bytes);
}

fn deserializeStruct(
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
) anyerror!T {
    if (info.is_tuple) return error.UnsupportedType;

    const DeserializerType = @TypeOf(deserializer.*);
    const borrowed_strings = @hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings();
    if (@hasDecl(DeserializerType, "beginStructOrdered")) {
        try deserializer.beginStructOrdered(T);

        var ordered_result: T = undefined;
        var ordered_seen: [info.field_names.len]bool = @splat(false);
        errdefer freePartialStruct(T, allocator, &ordered_result, &ordered_seen, borrowed_strings);

        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, field_type, field_attrs, i| {
            if (field_attrs.@"comptime") {
                @compileError("comptime struct fields are not supported: " ++ @typeName(T) ++ "." ++ field_name);
            }

            @field(ordered_result, field_name) = try deserializeFieldValue(field_type, allocator, deserializer, cfg, diagnostics, track_diagnostics, field_name, meta.effectiveBounds(T, field_name, cfg));
            ordered_seen[i] = true;
        }

        if (@hasDecl(DeserializerType, "endStructOrdered")) try deserializer.endStructOrdered(T);
        try checkStruct(T, &ordered_result);
        return ordered_result;
    }

    if (comptime structHasIntegerKeys(T, info, cfg) and !@hasDecl(DeserializerType, "supports_integer_keys")) {
        @compileError("format " ++ @typeName(DeserializerType) ++ " does not support integer keys: " ++ @typeName(T));
    }

    try deserializer.beginObject();

    var result: T = undefined;
    var seen: [info.field_names.len]bool = @splat(false);
    errdefer freePartialStruct(T, allocator, &result, &seen, borrowed_strings);

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
                            @field(result, field_name) = try deserializeStructField(T, field_name, field_type, allocator, deserializer, cfg, diagnostics, track_diagnostics);
                            seen[i] = true;
                        }
                    }
                },
            }
        }

        if (comptime extras_name != null) try storeExtras(T, info, allocator, deserializer, extras_mark, &result, &seen);
        try fillMissingFields(T, info, cfg, &result, &seen);
        try checkStruct(T, &result);
        return result;
    }

    while (try deserializer.nextObjectField(allocator)) |object_field| {
        defer object_field.deinit(allocator);

        if (matchStructFieldIndexInfo(T, info, cfg, object_field.bytes)) |field_index| {
            inline for (info.field_names, info.field_types, 0..) |struct_field_name, field_type, i| {
                if (field_index == i) {
                    if (seen[i]) return error.DuplicateField;
                    @field(result, struct_field_name) = try deserializeStructField(T, struct_field_name, field_type, allocator, deserializer, cfg, diagnostics, track_diagnostics);
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

    if (comptime extras_name != null) try storeExtras(T, info, allocator, deserializer, extras_mark, &result, &seen);
    try fillMissingFields(T, info, cfg, &result, &seen);
    try checkStruct(T, &result);
    return result;
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
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    allocator: Allocator,
    deserializer: anytype,
    mark: anytype,
    result: *T,
    seen: *[info.field_names.len]bool,
) anyerror!void {
    const name = comptime meta.extrasField(T).?;
    inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
        if (comptime std.mem.eql(u8, field_name, name)) {
            const owned = try deserializer.finishExtras(allocator, mark, isRaw(field_type));
            @field(result.*, field_name) = if (comptime isRaw(field_type)) .{ .bytes = owned.? } else if (owned) |bytes| .{ .bytes = bytes } else null;
            seen[i] = true;
        }
    }
}

/// A type's own `check` runs once the struct is built, for rules across fields. Its error is
/// returned as it is; the fields already read are released.
fn checkStruct(comptime T: type, result: *const T) anyerror!void {
    if (comptime @hasDecl(T, "check")) try result.check();
}

/// Reads one struct field's value under the field's optional policy.
///
/// A nested optional (`??T`) is the field whose absence differs from its null: a present field
/// reads as the inner optional, so `null` is `.{ null }` and a missing field is the outer null.
/// A plain optional with the `absent` policy refuses an explicit null.
fn deserializeStructField(
    comptime T: type,
    comptime field_name: []const u8,
    comptime FieldType: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
) anyerror!FieldType {
    if (comptime isNestedOptional(FieldType)) {
        const Inner = @typeInfo(FieldType).optional.child;
        const inner: Inner = try deserializeFieldValue(Inner, allocator, deserializer, cfg, diagnostics, track_diagnostics, field_name, meta.effectiveBounds(T, field_name, cfg));
        return inner;
    }
    if (comptime @typeInfo(FieldType) == .optional and meta.effectiveOptionalPolicy(T, field_name, cfg) == .absent) {
        if (try deserializer.peekKind() == .null) return error.UnexpectedType;
    }
    return deserializeFieldValue(FieldType, allocator, deserializer, cfg, diagnostics, track_diagnostics, field_name, meta.effectiveBounds(T, field_name, cfg));
}

/// Resolves fields the input did not name, after the object is fully consumed: a declared default,
/// else null for an optional, else an error. An optional with the `nullable` policy must be named.
fn fillMissingFields(
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    comptime cfg: anytype,
    result: *T,
    seen: *const [info.field_names.len]bool,
) Error!void {
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, field_type, field_attrs, i| {
        if (!seen[i]) {
            if (field_attrs.defaultValue(field_type)) |default_value| {
                @field(result.*, field_name) = default_value;
            } else if (@typeInfo(field_type) == .optional) {
                if (comptime !isNestedOptional(field_type) and meta.effectiveOptionalPolicy(T, field_name, cfg) == .nullable) {
                    return error.MissingField;
                }
                @field(result.*, field_name) = null;
            } else {
                return error.MissingField;
            }
        }
    }
}

fn structHasIntegerKeys(comptime T: type, comptime info: std.builtin.Type.Struct, comptime cfg: anytype) bool {
    inline for (info.field_names) |field_name| {
        if (meta.effectiveFieldKey(T, field_name, cfg) == .integer) return true;
    }
    return false;
}

fn deserializeIndexedValue(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    index: usize,
) anyerror!T {
    if (track_diagnostics) diagnostics.?.pushIndex(index);
    const value = deserializeValue(T, allocator, deserializer, cfg, diagnostics, track_diagnostics) catch |err| return err;
    if (track_diagnostics) diagnostics.?.pop();
    return value;
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
    comptime T: type,
    comptime bounds: meta.Bounds,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
) anyerror!T {
    switch (@typeInfo(T)) {
        .optional => |info| {
            if (try readNullIfPresent(deserializer)) return null;
            return try deserializeBounded(info.child, bounds, allocator, deserializer, cfg, diagnostics, track_diagnostics);
        },
        .int => {
            const value = try deserializeValue(T, allocator, deserializer, cfg, diagnostics, track_diagnostics);
            if (bounds.min) |min| if (value < min) return error.ValueOutOfRange;
            if (bounds.max) |max| if (value > max) return error.ValueOutOfRange;
            return value;
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("length bounds apply to a slice: " ++ @typeName(T));
            return try deserializePointer(T, info, allocator, deserializer, cfg, diagnostics, track_diagnostics, bounds);
        },
        .@"struct" => {
            if (T == ByteString) return .{ .bytes = try readByteSlice(allocator, deserializer, bounds) };
            if (comptime isRaw(T)) return .{ .bytes = try readRawSlice(T, allocator, deserializer, bounds) };
            @compileError("bounds apply to text, bytes, arrays and integers: " ++ @typeName(T));
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

fn deserializeFieldValue(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*diagnostic_mod.Diagnostic,
    comptime track_diagnostics: bool,
    comptime field_name: []const u8,
    comptime bounds: meta.Bounds,
) anyerror!T {
    if (track_diagnostics) diagnostics.?.pushField(field_name);
    const value = (if (comptime bounds.isDefault())
        deserializeValue(T, allocator, deserializer, cfg, diagnostics, track_diagnostics)
    else
        deserializeBounded(T, bounds, allocator, deserializer, cfg, diagnostics, track_diagnostics)) catch |err| return err;
    if (track_diagnostics) diagnostics.?.pop();
    return value;
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
    comptime T: type,
    allocator: Allocator,
    result: *T,
    seen: *[@typeInfo(T).@"struct".field_names.len]bool,
    borrowed_strings: bool,
) void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
        if (seen[i]) freeTypedPartial(field_type, allocator, @field(result.*, field_name), borrowed_strings);
    }
}
