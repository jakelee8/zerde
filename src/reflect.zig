//! Reflection over the types the typed layer reads and writes: what a generator needs to know about
//! a schema type to emit its declarations, its grammar or a printer, without walking `@typeInfo` and
//! re-deriving the typed layer's rules (renames, integer keys, optional policies, bounds, extras,
//! hooks) itself.
//!
//! Everything here is comptime. A description is shallow: a field or variant carries its Zig `type`
//! and a `Kind`, and a generator describes that type in turn, so recursive types need no care. Each
//! function takes the same `cfg` the read or write takes (`.{}` for none), because call-site field
//! overrides and `rename_all` change what the wire form is.

const std = @import("std");
const meta = @import("meta.zig");
const typed = @import("typed.zig");

/// What a type is on the wire, at the level a generator branches on.
pub const Kind = enum {
    /// `bool`.
    bool,
    /// An integer type; see `intRange`.
    int,
    /// A float type.
    float,
    /// `[]const u8`: a text string.
    text,
    /// `zerde.ByteString`: a variable-length byte string.
    byte_string,
    /// `[N]u8`: a byte string of exactly N bytes.
    byte_array,
    /// a `Raw`: an item kept as its bytes.
    raw,
    /// `?T`, and `??T` as a struct field (see `FieldInfo.nested_optional`).
    optional,
    /// `[N]T`.
    array,
    /// `[]const T`, an array of any length.
    list,
    /// `*const T`: written as `T`.
    pointer,
    /// An `enum`; see `enumInfo`.
    @"enum",
    /// A struct; see `fields`.
    @"struct",
    /// A tagged union; see `variants`.
    @"union",
    /// A type with a `zerdeDecode` or `zerdeEncode` hook: its wire form is its own.
    hook,
    /// `void`, the payload of a variant that has none.
    none,
};

/// The kind of `T`.
pub fn kindOf(comptime T: type) Kind {
    @setEvalBranchQuota(1_000_000);
    if (comptime hasAnyHook(T)) return .hook;
    return switch (@typeInfo(T)) {
        .bool => .bool,
        .int, .comptime_int => .int,
        .float, .comptime_float => .float,
        .void => .none,
        .optional => .optional,
        .@"enum" => .@"enum",
        .@"union" => .@"union",
        .array => |info| if (info.child == u8) .byte_array else .array,
        .pointer => |info| switch (info.size) {
            .slice => if (info.child == u8) .text else .list,
            else => .pointer,
        },
        .@"struct" => if (T == typed.ByteString) .byte_string else if (typed.isRaw(T)) .raw else .@"struct",
        else => @compileError("zerde has no wire form for " ++ @typeName(T)),
    };
}

fn hasAnyHook(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "zerdeDecode") or @hasDecl(T, "zerdeEncode"),
        else => false,
    };
}

/// One member of a struct as it is on the wire.
pub const FieldInfo = struct {
    /// The Zig field name.
    name: []const u8,
    /// The wire key: its name after `rename_all` and `rename`, or the integer `key`.
    wire: meta.FieldKey,
    type: type,
    kind: Kind,
    bounds: meta.Bounds,
    /// How an optional field treats an absent member and an explicit null.
    optional: meta.OptionalPolicy,
    /// `??T`: absent and null are different values.
    nested_optional: bool,
    /// The field has a default, which fills it when the input does not name it. See `defaultOf`.
    has_default: bool,
    /// The field collects the members the type does not declare (`serde.extras`); it is not a member.
    extras: bool,
};

/// The fields of struct `T` in declaration order, extras included and marked.
pub fn fields(comptime T: type, comptime cfg: anytype) []const FieldInfo {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError("fields needs a struct: " ++ @typeName(T)),
        };
        var out: [info.field_names.len]FieldInfo = undefined;
        for (info.field_names, info.field_types, info.field_attrs, 0..) |name, FieldType, attrs, index| {
            out[index] = .{
                .name = name,
                .wire = meta.effectiveFieldKey(T, name, cfg),
                .type = FieldType,
                .kind = kindOf(FieldType),
                .bounds = meta.effectiveBounds(T, name, cfg),
                .optional = meta.effectiveOptionalPolicy(T, name, cfg),
                .nested_optional = switch (@typeInfo(FieldType)) {
                    .optional => |o| @typeInfo(o.child) == .optional,
                    else => false,
                },
                .has_default = attrs.defaultValue(FieldType) != null,
                .extras = meta.isExtrasField(T, name),
            };
        }
        const final = out;
        return &final;
    }
}

/// The default of field `name` of `T`, or null when it has none.
pub fn defaultOf(comptime T: type, comptime name: []const u8) ?@FieldType(T, name) {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |field_name, FieldType, attrs| {
        if (comptime std.mem.eql(u8, field_name, name)) return attrs.defaultValue(FieldType);
    }
    @compileError(@typeName(T) ++ " has no field " ++ name);
}

/// The indexes into `fields(T, cfg)` of the members a write of `T` emits, in the order it emits
/// them for `Format` (a format module such as `zerde.cbor`) and `format_cfg` (the write config, for
/// example `.{ .deterministic = true }`). The extras field is left out.
pub fn writeOrder(comptime T: type, comptime Format: type, comptime cfg: anytype, comptime format_cfg: anytype) []const usize {
    comptime {
        const info = @typeInfo(T).@"struct";
        const policy = if (@hasDecl(Format, "fieldOrderPolicy")) Format.fieldOrderPolicy(format_cfg) else meta.FieldOrderPolicy{};
        const order = typed.structFieldOrder(T, Format, info, cfg, policy);
        var out: [order.len]usize = undefined;
        var count: usize = 0;
        for (order) |index| {
            if (meta.isExtrasField(T, info.field_names[index])) continue;
            out[count] = index;
            count += 1;
        }
        const final = out[0..count].*;
        return &final;
    }
}

/// One variant of a tagged union.
pub const VariantInfo = struct {
    name: []const u8,
    /// How the variant is named on the wire: its name, or an integer `key`.
    wire: meta.FieldKey,
    /// The payload type; `void` for a variant that is only its key.
    type: type,
    kind: Kind,
    /// The bounds of the payload (`serde.fields.<variant>`), applied as a field's are.
    bounds: meta.Bounds,
};

/// The variants of tagged union `T`.
pub fn variants(comptime T: type, comptime cfg: anytype) []const VariantInfo {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"union" => |u| u,
            else => @compileError("variants needs a union: " ++ @typeName(T)),
        };
        var out: [info.field_names.len]VariantInfo = undefined;
        for (info.field_names, info.field_types, 0..) |name, PayloadType, index| {
            out[index] = .{
                .name = name,
                .wire = meta.effectiveFieldKey(T, name, cfg),
                .type = PayloadType,
                .kind = kindOf(PayloadType),
                .bounds = meta.effectiveBounds(T, name, cfg),
            };
        }
        const final = out;
        return &final;
    }
}

/// One value of an enum.
pub const EnumValue = struct { name: []const u8, value: i128 };

pub const EnumInfo = struct {
    /// How a write carries it: the name, or the number (`enum_repr`).
    repr: meta.EnumRepr,
    values: []const EnumValue,
};

pub fn enumInfo(comptime T: type, comptime cfg: anytype) EnumInfo {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"enum" => |e| e,
            else => @compileError("enumInfo needs an enum: " ++ @typeName(T)),
        };
        var out: [info.field_names.len]EnumValue = undefined;
        for (info.field_names, info.field_values, 0..) |name, value, index| {
            out[index] = .{ .name = name, .value = value };
        }
        const final = out;
        return .{ .repr = meta.effectiveEnumRepr(T, cfg), .values = &final };
    }
}

/// The smallest and largest value of integer type `T`.
pub fn intRange(comptime T: type) struct { min: i128, max: i128 } {
    return .{ .min = std.math.minInt(T), .max = std.math.maxInt(T) };
}

/// The type a `[N]T` or `[]const T` or `?T` or `*const T` holds.
pub fn childOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| info.child,
        .optional => |info| info.child,
        else => @compileError(@typeName(T) ++ " has no element type"),
    };
}
