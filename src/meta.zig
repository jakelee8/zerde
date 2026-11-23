//! Compile-time serde metadata helpers.
//!
//! This module merges call-site config with optional `pub const serde = ...`
//! declarations on user types and computes the final field naming policy.

const std = @import("std");

/// Global rename strategies understood by the typed layer.
pub const FieldCase = enum {
    unchanged,
    snake_case,
    camelCase,
    PascalCase,
    kebab_case,
};

/// The order struct fields are written in.
///
/// Reading accepts fields in any order whatever this says.
pub const FieldOrder = enum {
    /// Source declaration order.
    declaration,
    /// Shorter wire name first, then bytewise. For text keys this is the order of RFC 8949 §4.2.1
    /// (bytewise order of the encoded keys) and of the length-first ordering in §4.2.3. It is
    /// defined for text keys only: an integer key is a compile error here.
    length_first,
    /// Bytewise order of the wire names. For ASCII names this is the order of RFC 8785 (JSON
    /// Canonicalization Scheme), which sorts by UTF-16 code unit. Text keys only.
    bytewise,
    /// Bytewise order of each key's encoded form, which is RFC 8949 §4.2.1 for any mix of text and
    /// integer keys. Needs a format that defines `encodeKey`; CBOR does.
    encoded_key,
};

/// A struct field's wire key: its name, or an integer for a format whose maps allow integer keys.
pub const FieldKey = union(enum) {
    text: []const u8,
    integer: i128,
};

/// How an optional struct field treats an absent field and an explicit null.
pub const OptionalPolicy = enum {
    /// Absent and null both read as null; null is written, or the field is omitted when the call
    /// asks to omit null fields.
    lenient,
    /// The field must be present, and may be null: a null is always written and an absent field is
    /// `error.MissingField`.
    nullable,
    /// The field may be absent but not null: a null is never written and an explicit null is
    /// `error.UnexpectedType`.
    absent,
};

/// A format's field order: the order it uses when neither the call site nor the type names one,
/// and whether it requires that order. A deterministic encoding requires its order, so asking such
/// a format for another order is a compile error instead of output that only looks deterministic.
pub const FieldOrderPolicy = struct {
    default: FieldOrder = .declaration,
    required: bool = false,
};

/// Cross-format serde policy. Individual formats can add their own config on top.
pub const SerdeConfig = struct {
    rename_all: FieldCase = .unchanged,
    omit_null_fields: bool = false,
    deny_unknown_fields: bool = false,
    /// Field order on write. Null lets the format choose (`FieldOrderPolicy.default`).
    field_order: ?FieldOrder = null,
};

pub const JsonConfig = SerdeConfig;

/// Returns whether a comptime-visible struct type exposes a field named `name`.
pub fn hasField(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            inline for (info.field_names) |field_name| {
                if (std.mem.eql(u8, field_name, name)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn cfgHasField(comptime cfg: anytype, comptime name: []const u8) bool {
    return hasField(@TypeOf(cfg), name);
}

fn serdeHasField(comptime T: type, comptime name: []const u8) bool {
    return @hasDecl(T, "serde") and hasField(@TypeOf(T.serde), name);
}

fn fieldOverrideHas(comptime container: anytype, comptime field_name: []const u8, comptime option: []const u8) bool {
    if (!comptime cfgHasField(container, "fields")) return false;
    const fields = @field(container, "fields");
    if (!comptime hasField(@TypeOf(fields), field_name)) return false;
    const field_cfg = @field(fields, field_name);
    return comptime hasField(@TypeOf(field_cfg), option);
}

fn fieldOverride(comptime container: anytype, comptime field_name: []const u8, comptime option: []const u8) @TypeOf(@field(@field(@field(container, "fields"), field_name), option)) {
    return @field(@field(@field(container, "fields"), field_name), option);
}

/// Per-type `rename_all` wins over call-site defaults.
pub fn effectiveRenameAll(comptime T: type, comptime cfg: anytype) FieldCase {
    if (comptime serdeHasField(T, "rename_all")) return @field(T.serde, "rename_all");
    if (comptime cfgHasField(cfg, "rename_all")) return @field(cfg, "rename_all");
    return .unchanged;
}

/// Call-site omission policy wins so one call can suppress nulls without editing the type.
pub fn effectiveOmitNullFields(comptime T: type, comptime cfg: anytype) bool {
    if (comptime cfgHasField(cfg, "omit_null_fields")) return @field(cfg, "omit_null_fields");
    if (comptime serdeHasField(T, "omit_null_fields")) return @field(T.serde, "omit_null_fields");
    return false;
}

/// Call-site unknown-field policy wins for the same reason as null omission.
pub fn effectiveDenyUnknownFields(comptime T: type, comptime cfg: anytype) bool {
    if (comptime cfgHasField(cfg, "deny_unknown_fields")) return @field(cfg, "deny_unknown_fields");
    if (comptime serdeHasField(T, "deny_unknown_fields")) return @field(T.serde, "deny_unknown_fields");
    return false;
}

/// Field order precedence is: call site, then the type's `serde`, then the format's default.
///
/// A format that requires its order rejects any other at compile time.
pub fn effectiveFieldOrder(comptime T: type, comptime cfg: anytype, comptime policy: FieldOrderPolicy) FieldOrder {
    const from_call: ?FieldOrder = comptime if (cfgHasField(cfg, "field_order")) @field(cfg, "field_order") else null;
    const from_type: ?FieldOrder = comptime if (serdeHasField(T, "field_order")) @field(T.serde, "field_order") else null;
    const order: FieldOrder = if (from_call) |call| call else if (from_type) |declared| declared else policy.default;
    if (policy.required and order != policy.default) {
        @compileError("this format writes fields in " ++ @tagName(policy.default) ++ " order; " ++ @typeName(T) ++
            " asks for " ++ @tagName(order));
    }
    return order;
}

/// Field name precedence is: call-site field override, type field override, then rename_all.
pub fn effectiveFieldName(comptime T: type, comptime field_name: []const u8, comptime cfg: anytype) []const u8 {
    if (comptime fieldOverrideHas(cfg, field_name, "rename")) {
        return validName(field_name, fieldOverride(cfg, field_name, "rename"));
    }

    if (comptime @hasDecl(T, "serde") and fieldOverrideHas(T.serde, field_name, "rename")) {
        return validName(field_name, fieldOverride(T.serde, field_name, "rename"));
    }

    return applyCase(field_name, effectiveRenameAll(T, cfg));
}

/// A wire name is text in every format, and the readers skip validating a key that equals a declared
/// name; both hold only if a declared name is UTF-8, so an invalid `rename` is a compile error.
fn validName(comptime field_name: []const u8, comptime name: []const u8) []const u8 {
    if (!std.unicode.utf8ValidateSlice(name)) @compileError("the wire name of field `" ++ field_name ++ "` is not valid UTF-8");
    return name;
}

/// A field's wire key. A field override `.key = <integer>` makes it an integer key; otherwise the
/// key is the name `effectiveFieldName` gives. The call site wins over the type at each step.
pub fn effectiveFieldKey(comptime T: type, comptime field_name: []const u8, comptime cfg: anytype) FieldKey {
    @setEvalBranchQuota(20_000);
    if (comptime fieldOverrideHas(cfg, field_name, "key")) return .{ .integer = fieldOverride(cfg, field_name, "key") };
    if (comptime fieldOverrideHas(cfg, field_name, "rename")) return .{ .text = validName(field_name, fieldOverride(cfg, field_name, "rename")) };
    if (comptime @hasDecl(T, "serde") and fieldOverrideHas(T.serde, field_name, "key")) {
        return .{ .integer = fieldOverride(T.serde, field_name, "key") };
    }
    return .{ .text = effectiveFieldName(T, field_name, cfg) };
}

/// A field's `optional` policy, from a field override: the call site, then the type. Lenient by default.
pub fn effectiveOptionalPolicy(comptime T: type, comptime field_name: []const u8, comptime cfg: anytype) OptionalPolicy {
    @setEvalBranchQuota(20_000);
    if (comptime fieldOverrideHas(cfg, field_name, "optional")) return fieldOverride(cfg, field_name, "optional");
    if (comptime @hasDecl(T, "serde") and fieldOverrideHas(T.serde, field_name, "optional")) {
        return fieldOverride(T.serde, field_name, "optional");
    }
    return .lenient;
}

/// Converts a source field name to the requested wire-format case at comptime.
pub fn applyCase(comptime name: []const u8, comptime style: FieldCase) []const u8 {
    if (style == .unchanged) return name;

    return comptime blk: {
        var buffer: [name.len * 2 + 1]u8 = undefined;
        var out_len: usize = 0;
        var word_index: usize = 0;
        var in_word = false;
        var i: usize = 0;

        while (i < name.len) : (i += 1) {
            const c = name[i];
            if (isSeparator(c)) {
                in_word = false;
                continue;
            }

            // Detect transitions like `firstName`, `HTTPServer`, or `field_name`.
            const boundary = isBoundary(name, i);
            if (boundary) {
                switch (style) {
                    .snake_case => {
                        buffer[out_len] = '_';
                        out_len += 1;
                    },
                    .kebab_case => {
                        buffer[out_len] = '-';
                        out_len += 1;
                    },
                    else => {},
                }
                in_word = false;
            }

            const normalized = switch (style) {
                .snake_case, .kebab_case => std.ascii.toLower(c),
                .camelCase => if (word_index == 0)
                    std.ascii.toLower(c)
                else if (!in_word)
                    std.ascii.toUpper(c)
                else
                    std.ascii.toLower(c),
                .PascalCase => if (!in_word)
                    std.ascii.toUpper(c)
                else
                    std.ascii.toLower(c),
                .unchanged => c,
            };

            buffer[out_len] = normalized;
            out_len += 1;

            if (!in_word) word_index += 1;
            in_word = true;
        }

        var exact: [out_len]u8 = undefined;
        @memcpy(&exact, buffer[0..out_len]);
        const final = exact;
        break :blk &final;
    };
}

fn isSeparator(c: u8) bool {
    return c == '_' or c == '-' or c == ' ';
}

fn isBoundary(comptime name: []const u8, comptime i: usize) bool {
    if (i == 0) return false;

    const c = name[i];
    const prev = name[i - 1];

    if (isSeparator(prev)) return true;
    if (isSeparator(c)) return false;

    if (std.ascii.isUpper(c) and (std.ascii.isLower(prev) or std.ascii.isDigit(prev))) return true;

    if (std.ascii.isUpper(c) and std.ascii.isUpper(prev) and i + 1 < name.len and std.ascii.isLower(name[i + 1])) {
        return true;
    }

    return false;
}

test "case conversion" {
    try std.testing.expectEqualStrings("first_name", applyCase("firstName", .snake_case));
    try std.testing.expectEqualStrings("firstName", applyCase("first_name", .camelCase));
    try std.testing.expectEqualStrings("FirstName", applyCase("first_name", .PascalCase));
    try std.testing.expectEqualStrings("http_server", applyCase("HTTPServer", .snake_case));
    try std.testing.expectEqualStrings("http-server", applyCase("HTTPServer", .kebab_case));
}
