//! Typed-layer behaviour for the formats that carry untrusted bodies: CBOR and JSON.
//!
//! Each section is one guarantee: variable-length byte strings, unions, absent versus null,
//! strict integers, strict string types, UTF-8, number ranges, bounded nesting, deterministic
//! integer-key order, lenient well-formed input, and duplicate map keys.

const std = @import("std");
const zerde = @import("zerde");

const allocator = std.testing.allocator;

fn writeCbor(value: anytype, comptime serde_cfg: anytype, comptime format_cfg: anytype) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try zerde.serializeWith(zerde.cbor, &out.writer, value, serde_cfg, format_cfg);
    return out;
}

fn writeJson(value: anytype, comptime serde_cfg: anytype, comptime format_cfg: anytype) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try zerde.serializeWith(zerde.json, &out.writer, value, serde_cfg, format_cfg);
    return out;
}

fn expectCborBytes(expected: []const u8, value: anytype, comptime serde_cfg: anytype, comptime format_cfg: anytype) !void {
    var out = try writeCbor(value, serde_cfg, format_cfg);
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, expected, out.written());
}

fn expectJsonText(expected: []const u8, value: anytype, comptime serde_cfg: anytype, comptime format_cfg: anytype) !void {
    var out = try writeJson(value, serde_cfg, format_cfg);
    defer out.deinit();
    try std.testing.expectEqualStrings(expected, out.written());
}

fn cborRoundTrip(comptime T: type, value: T, comptime serde_cfg: anytype) !void {
    var out = try writeCbor(value, serde_cfg, .{});
    defer out.deinit();
    const decoded = try zerde.parseSliceWith(zerde.cbor, T, allocator, out.written(), serde_cfg, .{});
    defer zerde.free(allocator, decoded);
    try std.testing.expectEqualDeep(value, decoded);
}

fn jsonRoundTrip(comptime T: type, value: T, comptime serde_cfg: anytype, comptime format_cfg: anytype) !void {
    var out = try writeJson(value, serde_cfg, format_cfg);
    defer out.deinit();
    const decoded = try zerde.parseSliceWith(zerde.json, T, allocator, out.written(), serde_cfg, format_cfg);
    defer zerde.free(allocator, decoded);
    try std.testing.expectEqualDeep(value, decoded);
}

fn expectCborError(comptime T: type, expected: anyerror, input: []const u8) !void {
    try std.testing.expectError(expected, zerde.cbor.parseSlice(T, allocator, input));
}

fn expectJsonError(comptime T: type, expected: anyerror, input: []const u8) !void {
    try std.testing.expectError(expected, zerde.json.parseSlice(T, allocator, input));
}

/// A struct that reads one known field and skips everything else.
const Probe = struct { a: ?u8 = null };
const Linked = struct { next: ?*const Linked = null };

// ---- 1. variable-length byte strings ---------------------------------------------------------

const Blob = struct { id: u8, data: zerde.ByteString };

test "ByteString is a CBOR byte string, not text" {
    const blob = Blob{ .id = 1, .data = .{ .bytes = "\xff\x00" } };
    try expectCborBytes(&.{ 0xbf, 0x62, 'i', 'd', 0x01, 0x64, 'd', 'a', 't', 'a', 0x42, 0xff, 0x00, 0xff }, blob, .{}, .{});
    try cborRoundTrip(Blob, blob, .{});
}

test "ByteString of any length round-trips, including empty and long" {
    const long: [300]u8 = @splat(0xa5);
    for ([_][]const u8{ "", "x", &long }) |bytes| {
        try cborRoundTrip(Blob, .{ .id = 9, .data = .{ .bytes = bytes } }, .{});
    }
}

test "ByteString is refused when the input holds text, and a text field when it holds bytes" {
    try expectCborError(Blob, error.UnexpectedType, &.{ 0xa2, 0x62, 'i', 'd', 0x01, 0x64, 'd', 'a', 't', 'a', 0x62, 'h', 'i' });
    try expectCborError(Name, error.UnexpectedType, &.{ 0xa1, 0x64, 'n', 'a', 'm', 'e', 0x42, 'h', 'i' });
    const Fixed = struct { tag: [2]u8 };
    try expectCborError(Fixed, error.UnexpectedType, &.{ 0xa1, 0x63, 't', 'a', 'g', 0x62, 'h', 'i' });
}

test "ByteString nests in arrays, optionals and unions" {
    const Holder = struct { items: []const zerde.ByteString, maybe: ?zerde.ByteString };
    const items = [_]zerde.ByteString{ .{ .bytes = "\x00" }, .{ .bytes = "\xff\xfe" } };
    try cborRoundTrip(Holder, .{ .items = &items, .maybe = .{ .bytes = "z" } }, .{});
    try cborRoundTrip(Holder, .{ .items = &items, .maybe = null }, .{});
}

test "ByteString in JSON follows the configured encoding" {
    const blob = Blob{ .id = 1, .data = .{ .bytes = "\xff\x00" } };
    try expectJsonText("{\"id\":1,\"data\":\"/wA=\"}", blob, .{}, .{ .bytes = .base64 });
    try jsonRoundTrip(Blob, blob, .{}, zerde.json.ReadConfig{ .bytes = .base64 });
    try expectJsonText("{\"id\":1,\"data\":\"_wA\"}", blob, .{}, .{ .bytes = .base64url });
    try jsonRoundTrip(Blob, blob, .{}, zerde.json.ReadConfig{ .bytes = .base64url });
}

test "the raw-string JSON encoding refuses bytes that are not UTF-8" {
    const blob = Blob{ .id = 1, .data = .{ .bytes = "\xff\x00" } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidUtf8, zerde.serializeWith(zerde.json, &out.writer, blob, .{}, .{}));
    try jsonRoundTrip(Blob, .{ .id = 2, .data = .{ .bytes = "plain" } }, .{}, .{});
}

test "ByteString parsed with an aliased slice borrows the input" {
    const input = [_]u8{ 0xa2, 0x62, 'i', 'd', 0x01, 0x64, 'd', 'a', 't', 'a', 0x42, 0xff, 0x00 };
    const blob = try zerde.cbor.parseSliceAliased(Blob, allocator, &input);
    try std.testing.expectEqualSlices(u8, "\xff\x00", blob.data.bytes);
    try std.testing.expect(@intFromPtr(blob.data.bytes.ptr) >= @intFromPtr(&input) and @intFromPtr(blob.data.bytes.ptr) < @intFromPtr(&input) + input.len);
}

// ---- 2. tagged unions, absent versus null ----------------------------------------------------

const Shape = union(enum) {
    empty,
    circle: u32,
    rect: struct { w: u16, h: u16 },
    label: []const u8,
    blob: zerde.ByteString,

    pub const serde = .{ .rename_all = .snake_case };
};

test "a union is its name, or a one-entry map of name and payload" {
    try expectCborBytes(&.{ 0x65, 'e', 'm', 'p', 't', 'y' }, Shape.empty, .{}, .{});
    try expectCborBytes(&.{ 0xa1, 0x66, 'c', 'i', 'r', 'c', 'l', 'e', 0x07 }, Shape{ .circle = 7 }, .{}, .{ .deterministic = true });
    try expectCborBytes(&.{ 0xbf, 0x66, 'c', 'i', 'r', 'c', 'l', 'e', 0x07, 0xff }, Shape{ .circle = 7 }, .{}, .{});
    try expectJsonText("\"empty\"", Shape.empty, .{}, .{});
    try expectJsonText("{\"circle\":7}", Shape{ .circle = 7 }, .{}, .{});
    try expectJsonText("{\"rect\":{\"w\":2,\"h\":3}}", Shape{ .rect = .{ .w = 2, .h = 3 } }, .{}, .{});
}

test "every union variant round-trips in CBOR and JSON" {
    const shapes = [_]Shape{
        .empty,
        .{ .circle = 4_000_000_000 },
        .{ .rect = .{ .w = 65535, .h = 0 } },
        .{ .label = "round" },
        .{ .blob = .{ .bytes = "\x00\xff" } },
    };
    for (shapes) |shape| {
        try cborRoundTrip(Shape, shape, .{});
        try cborRoundTrip(Shape, shape, .{});
    }
    // A byte string has no JSON type; it needs an encoding.
    for (shapes) |shape| try jsonRoundTrip(Shape, shape, .{}, zerde.json.ReadConfig{ .bytes = .base64 });
}

test "a union inside a struct and an array" {
    const Holder = struct { first: Shape, rest: []const Shape };
    const rest = [_]Shape{ .empty, .{ .circle = 1 } };
    const value = Holder{ .first = .{ .label = "x" }, .rest = &rest };
    try cborRoundTrip(Holder, value, .{});
    try jsonRoundTrip(Holder, value, .{}, .{});
}

test "a union input must name one known variant and carry one entry" {
    try expectJsonError(Shape, error.InvalidEnumTag, "\"nope\"");
    try expectJsonError(Shape, error.InvalidEnumTag, "{\"nope\":1}");
    // A variant with a payload cannot be spelled as a bare name, nor one without as a map.
    try expectJsonError(Shape, error.InvalidEnumTag, "\"circle\"");
    try expectJsonError(Shape, error.InvalidEnumTag, "{\"empty\":null}");
    try expectJsonError(Shape, error.LengthMismatch, "{}");
    try expectJsonError(Shape, error.LengthMismatch, "{\"circle\":1,\"circle\":2}");
    try expectJsonError(Shape, error.LengthMismatch, "{\"circle\":1,\"label\":\"x\"}");
    try expectJsonError(Shape, error.UnexpectedType, "7");
    try expectCborError(Shape, error.LengthMismatch, &.{0xa0});
    try expectCborError(Shape, error.LengthMismatch, &.{ 0xa2, 0x66, 'c', 'i', 'r', 'c', 'l', 'e', 0x01, 0x65, 'l', 'a', 'b', 'e', 'l', 0x61, 'x' });
}

test "a union payload of the wrong type does not leak what was read" {
    try expectJsonError(Shape, error.InvalidNumber, "{\"circle\":\"seven\"}");
    try expectJsonError(Shape, error.LengthMismatch, "{\"label\":\"kept\",\"label\":\"again\"}");
}

const Policies = struct {
    must: ?u8,
    never_null: ?u8,
    plain: ?u8,

    pub const serde = .{ .fields = .{
        .must = .{ .optional = .nullable },
        .never_null = .{ .optional = .absent },
    } };
};

test "an optional field can be required but nullable" {
    const all_null = Policies{ .must = null, .never_null = null, .plain = null };
    // The nullable field is written as null even when the call omits nulls; the others are omitted.
    try expectJsonText("{\"must\":null}", all_null, .{ .omit_null_fields = true }, .{});
    try expectJsonText("{\"must\":null,\"plain\":null}", all_null, .{}, .{});

    try expectJsonError(Policies, error.MissingField, "{}");
    try expectJsonError(Policies, error.MissingField, "{\"never_null\":1}");
    const parsed = try zerde.json.parseSlice(Policies, allocator, "{\"must\":null}");
    try std.testing.expectEqual(Policies{ .must = null, .never_null = null, .plain = null }, parsed);
}

test "an optional field can be absent but not null" {
    try expectJsonError(Policies, error.UnexpectedType, "{\"must\":1,\"never_null\":null}");
    const parsed = try zerde.json.parseSlice(Policies, allocator, "{\"must\":1,\"never_null\":4,\"plain\":null}");
    try std.testing.expectEqual(Policies{ .must = 1, .never_null = 4, .plain = null }, parsed);
}

test "an optional policy holds in CBOR too" {
    try expectCborBytes(&.{ 0xa1, 0x64, 'm', 'u', 's', 't', 0xf6 }, Policies{ .must = null, .never_null = null, .plain = null }, .{ .omit_null_fields = true }, .{ .deterministic = true });
    try expectCborError(Policies, error.MissingField, &.{0xa0});
    try expectCborError(Policies, error.UnexpectedType, &.{ 0xa2, 0x64, 'm', 'u', 's', 't', 0x01, 0x6a, 'n', 'e', 'v', 'e', 'r', '_', 'n', 'u', 'l', 'l', 0xf6 });
}

const Patch = struct { end: ??u8 };

test "a nested optional field tells an absent field from null" {
    try expectJsonText("{}", Patch{ .end = null }, .{}, .{});
    try expectJsonText("{\"end\":null}", Patch{ .end = @as(?u8, null) }, .{}, .{});
    try expectJsonText("{\"end\":5}", Patch{ .end = 5 }, .{}, .{});
    try expectCborBytes(&.{0xa0}, Patch{ .end = null }, .{}, .{ .deterministic = true });
    try expectCborBytes(&.{ 0xa1, 0x63, 'e', 'n', 'd', 0xf6 }, Patch{ .end = @as(?u8, null) }, .{}, .{ .deterministic = true });

    for ([_]Patch{ .{ .end = null }, .{ .end = @as(?u8, null) }, .{ .end = 5 } }) |patch| {
        try jsonRoundTrip(Patch, patch, .{}, .{});
        try cborRoundTrip(Patch, patch, .{});
    }
}

// ---- 3. strict integers ----------------------------------------------------------------------

test "an integer field refuses a float, whole or not" {
    try expectCborError(u8, error.UnexpectedType, &.{ 0xf9, 0x3c, 0x00 }); // 1.0 as half
    try expectCborError(u8, error.UnexpectedType, &.{ 0xfa, 0x40, 0x00, 0x00, 0x00 }); // 2.0 as single
    try expectCborError(u64, error.UnexpectedType, &.{ 0xfb, 0x43, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }); // 2^64 as double
    try expectJsonError(u8, error.UnexpectedType, "1.0");
    try expectJsonError(u8, error.UnexpectedType, "1e2");
    try expectJsonError(i8, error.UnexpectedType, "-5.0");
    try expectJsonError(u64, error.UnexpectedType, "1e300");
}

test "a float field still takes an integer" {
    try std.testing.expectEqual(@as(f64, 3), try zerde.cbor.parseSlice(f64, allocator, &.{0x03}));
    try std.testing.expectEqual(@as(f64, 3), try zerde.json.parseSlice(f64, allocator, "3"));
}

test "msgpack refuses a float for an integer field" {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try zerde.msgpack.serialize(&out.writer, @as(f64, 1.0));
    try std.testing.expectError(error.UnexpectedType, zerde.msgpack.parseSlice(u8, allocator, out.written()));
}

// ---- 4. strings and byte strings are distinct --------------------------------------------------

test "chunked strings of the right type are read; mixed or nested chunks are refused" {
    const chunked = try zerde.cbor.parseSlice(zerde.ByteString, allocator, &.{ 0x5f, 0x41, 0x01, 0x42, 0x02, 0x03, 0xff });
    defer zerde.free(allocator, chunked);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, chunked.bytes);

    const text = try zerde.cbor.parseSlice([]const u8, allocator, &.{ 0x7f, 0x62, 'h', 'i', 0x61, '!', 0xff });
    defer zerde.free(allocator, text);
    try std.testing.expectEqualStrings("hi!", text);

    try expectCborError(zerde.ByteString, error.InvalidStringChunk, &.{ 0x5f, 0x61, 'a', 0xff });
    try expectCborError([]const u8, error.InvalidStringChunk, &.{ 0x7f, 0x41, 0x61, 0xff });
    try expectCborError([]const u8, error.InvalidStringChunk, &.{ 0x7f, 0x7f, 0xff, 0xff });
    try expectCborError([]const u8, error.UnexpectedEndOfInput, &.{ 0x7f, 0x61, 'a' });
}

// ---- 5. invalid UTF-8 is refused ---------------------------------------------------------------

const Name = struct { name: []const u8 };

test "CBOR text must be UTF-8, in a field, a key, a chunk and a skipped value" {
    try expectCborError(Name, error.InvalidUtf8, &.{ 0xa1, 0x64, 'n', 'a', 'm', 'e', 0x62, 0xc3, 0x28 });
    try expectCborError(Probe, error.InvalidUtf8, &.{ 0xa1, 0x62, 0xc3, 0x28, 0x01 }); // an unknown key
    try expectCborError(Probe, error.InvalidUtf8, &.{ 0xa1, 0x61, 'x', 0x62, 0xff, 0xfe }); // a skipped value
    try expectCborError([]const u8, error.InvalidUtf8, &.{ 0x7f, 0x61, 0xc3, 0x61, 0xa9, 0xff }); // a code point split across chunks
    try expectCborError([]const u8, error.InvalidUtf8, &.{ 0x63, 0xed, 0xa0, 0x80 }); // a UTF-16 surrogate
    try expectCborError([]const u8, error.InvalidUtf8, &.{ 0x62, 0xc0, 0xaf }); // an overlong encoding
    // The same bytes are fine as a byte string.
    const bytes = try zerde.cbor.parseSlice(zerde.ByteString, allocator, &.{ 0x42, 0xc3, 0x28 });
    defer zerde.free(allocator, bytes);
}

test "JSON strings must be UTF-8, on every path" {
    try expectJsonError(Name, error.InvalidUtf8, "{\"name\":\"\xc3\x28\"}");
    try expectJsonError(Name, error.InvalidUtf8, "{\"name\":\"a\\n\xff\"}"); // after an escape
    try expectJsonError(Name, error.InvalidUtf8, "{\"name\":\"\\u0041\xed\xa0\x80\"}");
    try expectJsonError(Probe, error.InvalidUtf8, "{\"\xc3\x28\":1}"); // a key
    try expectJsonError(Probe, error.InvalidUtf8, "{\"x\":\"\xff\"}"); // a skipped value
    const ok = try zerde.json.parseSlice(Name, allocator, "{\"name\":\"h\xc3\xa9llo \\u00e9\"}");
    defer zerde.free(allocator, ok);
    try std.testing.expectEqualStrings("h\xc3\xa9llo \xc3\xa9", ok.name);
}

// ---- 6. number ranges ------------------------------------------------------------------------

const Real = struct { v: f64 };
const Single = struct { v: f32 };

test "JSON refuses a number too large for its float type instead of making it infinity" {
    try expectJsonError(Real, error.FloatOutOfRange, "{\"v\":1e999}");
    try expectJsonError(Real, error.FloatOutOfRange, "{\"v\":-1e999}");
    try expectJsonError(Single, error.FloatOutOfRange, "{\"v\":1e39}");
    try expectJsonError(Single, error.FloatOutOfRange, "{\"v\":1" ++ @as([40]u8, @splat('0')) ++ "}");
    const near = try zerde.json.parseSlice(Single, allocator, "{\"v\":3.4e38}");
    try std.testing.expectEqual(@as(f32, 3.4e38), near.v);
    // Too small rounds to zero: precision RFC 8259 §6 allows an implementation to lose.
    const tiny = try zerde.json.parseSlice(Real, allocator, "{\"v\":1e-999}");
    try std.testing.expectEqual(@as(f64, 0), tiny.v);
    // A dynamic value cannot hold it either.
    try std.testing.expectError(error.FloatOutOfRange, zerde.value.parseSlice(zerde.json, allocator, "[1e999]"));
}

test "JSON skips a number it cannot represent" {
    // Well-formed JSON in a field nobody reads is not an error.
    const probe = try zerde.json.parseSlice(Probe, allocator, "{\"x\":1e999,\"y\":" ++ @as([60]u8, @splat('9')) ++ ",\"a\":3}");
    try std.testing.expectEqual(@as(?u8, 3), probe.a);
}

test "JSON does not write NaN or infinity" {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.NonFiniteFloat, zerde.json.serialize(&out.writer, Real{ .v = std.math.nan(f64) }));
    try std.testing.expectError(error.NonFiniteFloat, zerde.json.serialize(&out.writer, Real{ .v = std.math.inf(f64) }));
    try std.testing.expectError(error.NonFiniteFloat, zerde.json.serialize(&out.writer, Real{ .v = -std.math.inf(f64) }));
}

test "CBOR carries NaN and infinity, as RFC 8949 §3.3 defines them" {
    const nan = try zerde.cbor.parseSlice(Real, allocator, &.{ 0xa1, 0x61, 'v', 0xf9, 0x7e, 0x00 });
    try std.testing.expect(std.math.isNan(nan.v));
    const inf = try zerde.cbor.parseSlice(Real, allocator, &.{ 0xa1, 0x61, 'v', 0xf9, 0x7c, 0x00 });
    try std.testing.expect(std.math.isInf(inf.v) and inf.v > 0);
    const single_inf = try zerde.cbor.parseSlice(Single, allocator, &.{ 0xa1, 0x61, 'v', 0xf9, 0xfc, 0x00 });
    try std.testing.expect(std.math.isInf(single_inf.v) and single_inf.v < 0);
    try expectCborBytes(&.{ 0xa1, 0x61, 'v', 0xf9, 0x7e, 0x00 }, Real{ .v = std.math.nan(f64) }, .{}, .{ .deterministic = true });
    try expectCborBytes(&.{ 0xa1, 0x61, 'v', 0xf9, 0x7c, 0x00 }, Real{ .v = std.math.inf(f64) }, .{}, .{ .deterministic = true });
}

test "CBOR refuses a finite double too large for a narrower float field" {
    // 1e300 as a double, into f32.
    try expectCborError(Single, error.FloatOutOfRange, &.{ 0xa1, 0x61, 'v', 0xfb, 0x7e, 0x37, 0xe4, 0x3c, 0x88, 0x00, 0x75, 0x9c });
    // 70000 does not fit a half-precision field either.
    try std.testing.expectError(error.FloatOutOfRange, zerde.cbor.parseSlice(f16, allocator, &.{ 0x1a, 0x00, 0x01, 0x11, 0x70 }));
}

// ---- 7. bounded nesting ----------------------------------------------------------------------

fn nestedCbor(depth: usize, open: u8) ![]u8 {
    // A map whose unknown field "x" holds `depth` nested containers around a 0.
    const input = try allocator.alloc(u8, 3 + depth + 1);
    input[0] = 0xa1;
    input[1] = 0x61;
    input[2] = 'x';
    @memset(input[3 .. 3 + depth], open);
    input[3 + depth] = 0x00;
    return input;
}

test "CBOR bounds the nesting of a skipped value" {
    // The map is one level, so 127 more is the most that fits in 128.
    const fits = try nestedCbor(127, 0x81);
    defer allocator.free(fits);
    _ = try zerde.cbor.parseSlice(Probe, allocator, fits);

    const too_deep = try nestedCbor(128, 0x81);
    defer allocator.free(too_deep);
    try expectCborError(Probe, error.CborNestingTooDeep, too_deep);

    const hostile = try nestedCbor(30_000, 0x81);
    defer allocator.free(hostile);
    try expectCborError(Probe, error.CborNestingTooDeep, hostile);
}

test "CBOR bounds nested maps and indefinite containers too" {
    const maps = try allocator.alloc(u8, 30_000 * 2 + 1);
    defer allocator.free(maps);
    for (0..30_000) |index| {
        maps[index * 2] = 0xa1;
        maps[index * 2 + 1] = 0x00;
    }
    maps[maps.len - 1] = 0x00;
    try expectCborError(Probe, error.CborNestingTooDeep, maps);

    const indefinite = try nestedCbor(30_000, 0x9f);
    defer allocator.free(indefinite);
    try expectCborError(Probe, error.CborNestingTooDeep, indefinite);

    // The typed container stack has the same bound.
    var linked: std.ArrayList(u8) = .empty;
    defer linked.deinit(allocator);
    for (0..30_000) |_| try linked.appendSlice(allocator, &.{ 0xa1, 0x64, 'n', 'e', 'x', 't' });
    try linked.append(allocator, 0xa0);
    try expectCborError(Linked, error.CborNestingTooDeep, linked.items);
}

test "a run of tags is not nesting" {
    const tags = try allocator.alloc(u8, 100_000 + 4);
    defer allocator.free(tags);
    tags[0] = 0xa1;
    tags[1] = 0x61;
    tags[2] = 'x';
    @memset(tags[3 .. 3 + 100_000], 0xc1);
    tags[3 + 100_000] = 0x00;
    const probe = try zerde.cbor.parseSlice(Probe, allocator, tags);
    try std.testing.expectEqual(@as(?u8, null), probe.a);
}

test "JSON bounds nesting" {
    const depth_ok = 127;
    var buffer: [depth_ok * 2 + 16]u8 = undefined;
    var fits: std.Io.Writer = .fixed(&buffer);
    try fits.writeAll("{\"x\":");
    for (0..depth_ok) |_| try fits.writeByte('[');
    for (0..depth_ok) |_| try fits.writeByte(']');
    try fits.writeByte('}');
    _ = try zerde.json.parseSlice(Probe, allocator, fits.buffered());

    const hostile = try allocator.alloc(u8, 30_000 + 6);
    defer allocator.free(hostile);
    @memcpy(hostile[0..5], "{\"x\":");
    @memset(hostile[5 .. 5 + 30_000], '[');
    hostile[5 + 30_000] = '}';
    try expectJsonError(Probe, error.JsonNestingTooDeep, hostile);

    var one_more: [128 + 6 + 128]u8 = undefined;
    var over: std.Io.Writer = .fixed(&one_more);
    try over.writeAll("{\"x\":");
    for (0..128) |_| try over.writeByte('[');
    for (0..128) |_| try over.writeByte(']');
    try over.writeByte('}');
    try expectJsonError(Probe, error.JsonNestingTooDeep, over.buffered());
}

test "a length cannot claim more items than the input holds" {
    // An array of 4 billion `u16`s in eight bytes.
    try expectCborError([]const u16, error.UnexpectedEndOfInput, &.{ 0x9a, 0xff, 0xff, 0xff, 0xff, 0x01, 0x02, 0x03 });
    try expectCborError([]const u16, error.UnexpectedEndOfInput, &.{ 0x9b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    // A map of 2^31 pairs; each takes two bytes at least.
    try expectCborError(Probe, error.UnexpectedEndOfInput, &.{ 0xba, 0x80, 0x00, 0x00, 0x00, 0x01, 0x02 });
    // Exactly as many items as bytes is accepted.
    const ok = try zerde.cbor.parseSlice([]const u16, allocator, &.{ 0x83, 0x01, 0x02, 0x03 });
    defer zerde.free(allocator, ok);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, ok);
}

// ---- 8. deterministic key order for integer and mixed keys --------------------------------------

const Keyed = struct {
    f: u8,
    e: u8,
    d: u8,
    c: u8,
    b: u8,
    a: u8,

    pub const serde = .{ .fields = .{
        .a = .{ .key = 1 },
        .b = .{ .key = -1 },
        .c = .{ .key = 24 },
        .d = .{ .key = 256 },
        .e = .{ .rename = "a" },
        .f = .{ .rename = "bb" },
    } };
};

test "deterministic CBOR sorts integer and text keys by their encoded bytes" {
    const value = Keyed{ .f = 6, .e = 5, .d = 4, .c = 3, .b = 2, .a = 1 };
    // 1, 24, 256, -1, "a", "bb": the order of the encoded keys, not numeric order (-1 would come first).
    try expectCborBytes(&.{
        0xa6,
        0x01,
        0x01,
        0x18,
        0x18,
        0x03,
        0x19,
        0x01,
        0x00,
        0x04,
        0x20,
        0x02,
        0x61,
        'a',
        0x05,
        0x62,
        'b',
        'b',
        0x06,
    }, value, .{}, .{ .deterministic = true });
}

test "integer-key structs round-trip and read in any key order" {
    const value = Keyed{ .f = 6, .e = 5, .d = 4, .c = 3, .b = 2, .a = 1 };
    try cborRoundTrip(Keyed, value, .{});

    // The same map written in reverse, with a non-minimal key head, and an unknown integer key.
    const shuffled = [_]u8{
        0xa7,
        0x62,
        'b',
        'b',
        0x06,
        0x61,
        'a',
        0x05,
        0x19,
        0x01,
        0x00,
        0x04,
        0x18,
        0x18,
        0x03,
        0x20,
        0x02,
        0x18, 0x63, 0x09, // key 99: unknown
        0x19, 0x00, 0x01, 0x01, // key 1, in three bytes
    };
    const decoded = try zerde.cbor.parseSlice(Keyed, allocator, &shuffled);
    try std.testing.expectEqualDeep(value, decoded);
}

test "a repeated integer key is refused, whatever its spelling" {
    const Plain = struct {
        a: u8,
        pub const serde = .{ .fields = .{ .a = .{ .key = 1 } } };
    };
    try expectCborError(Plain, error.DuplicateField, &.{ 0xa2, 0x01, 0x01, 0x18, 0x01, 0x02 });
    try expectCborError(Plain, error.DuplicateField, &.{ 0xa3, 0x02, 0x00, 0x02, 0x00, 0x01, 0x01 }); // an unknown key twice
}

test "mixed keys of every order sort the same however they are declared" {
    const Forward = struct {
        a: u8,
        b: u8,
        pub const serde = .{ .fields = .{ .a = .{ .key = -2 }, .b = .{ .key = 2 } } };
    };
    const Backward = struct {
        b: u8,
        a: u8,
        pub const serde = .{ .fields = .{ .a = .{ .key = -2 }, .b = .{ .key = 2 } } };
    };
    var forward = try writeCbor(Forward{ .a = 1, .b = 2 }, .{}, .{ .deterministic = true });
    defer forward.deinit();
    var backward = try writeCbor(Backward{ .b = 2, .a = 1 }, .{}, .{ .deterministic = true });
    defer backward.deinit();
    try std.testing.expectEqualSlices(u8, forward.written(), backward.written());
    try std.testing.expectEqualSlices(u8, &.{ 0xa2, 0x02, 0x02, 0x21, 0x01 }, forward.written());
}

// ---- 9. any well-formed input is read; output stays deterministic ------------------------------------

const Mixed = struct { big: u8, text: []const u8, ratio: f32, list: []const u16 };

test "non-minimal heads, other float widths, unsorted keys and indefinite lengths all read" {
    const input = [_]u8{
        0xd9, 0xd9, 0xf7, // self-described CBOR
        0xbf, // an indefinite map
        0x78, 0x04, 't', 'e', 'x', 't', // a key with a one-byte length it did not need
        0x7f, 0x62, 'h', 'i', 0x61, '!', 0xff, // a chunked string
        0x63, 'b', 'i', 'g', 0x19, 0x00, 0x05, // 5 in two bytes
        0x65, 'r', 'a', 't', 'i', 'o', 0xfb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0, // 1.5 as a double
        0x64, 'l', 'i', 's', 't', 0x9f, 0x01, 0x1a, 0x00, 0x00, 0x00, 0x02, 0xff, // an indefinite array, 2 in four bytes
        0xff,
    };
    const decoded = try zerde.cbor.parseSlice(Mixed, allocator, &input);
    defer zerde.free(allocator, decoded);
    try std.testing.expectEqual(@as(u8, 5), decoded.big);
    try std.testing.expectEqualStrings("hi!", decoded.text);
    try std.testing.expectEqual(@as(f32, 1.5), decoded.ratio);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, decoded.list);

    // Reading changes nothing about writing: the deterministic form is one byte string.
    try expectCborBytes(&.{
        0xa4,
        0x63,
        'b',
        'i',
        'g',
        0x05,
        0x64,
        'l',
        'i',
        's',
        't',
        0x82,
        0x01,
        0x02,
        0x64,
        't',
        'e',
        'x',
        't',
        0x63,
        'h',
        'i',
        '!',
        0x65,
        'r',
        'a',
        't',
        'i',
        'o',
        0xf9,
        0x3e,
        0x00,
    }, decoded, .{}, .{ .deterministic = true });
}

test "the same value in every legal spelling ends as one deterministic encoding" {
    const Pair = struct { n: i32, f: f64 };
    const spellings = [_][]const u8{
        &.{ 0xa2, 0x61, 'n', 0x20, 0x61, 'f', 0xf9, 0x3e, 0x00 },
        &.{ 0xa2, 0x61, 'f', 0xfa, 0x3f, 0xc0, 0x00, 0x00, 0x61, 'n', 0x38, 0x00 },
        &.{ 0xbf, 0x61, 'f', 0xfb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0, 0x61, 'n', 0x3a, 0x00, 0x00, 0x00, 0x00, 0xff },
        &.{ 0xb8, 0x02, 0x61, 'n', 0x3b, 0, 0, 0, 0, 0, 0, 0, 0, 0x78, 0x01, 'f', 0xf9, 0x3e, 0x00 },
    };
    for (spellings) |spelling| {
        const decoded = try zerde.cbor.parseSlice(Pair, allocator, spelling);
        try std.testing.expectEqual(Pair{ .n = -1, .f = 1.5 }, decoded);
        try expectCborBytes(&.{ 0xa2, 0x61, 'f', 0xf9, 0x3e, 0x00, 0x61, 'n', 0x20 }, decoded, .{}, .{ .deterministic = true });
    }
}

test "CBOR refuses what is not well-formed" {
    try expectCborError(u8, error.InvalidAdditionalInfo, &.{0x1c}); // reserved additional information
    try expectCborError(u8, error.InvalidAdditionalInfo, &.{0x1f}); // an indefinite integer
    try expectCborError(Probe, error.InvalidAdditionalInfo, &.{ 0xa1, 0x61, 'x', 0xff }); // a break where a value belongs
    try expectCborError(Probe, error.InvalidAdditionalInfo, &.{ 0xbf, 0x61, 'x', 0xff }); // an indefinite map missing its last value
    try expectCborError(Probe, error.InvalidSimpleValue, &.{ 0xa1, 0x61, 'x', 0xf8, 0x10 }); // a two-byte spelling of a one-byte simple value
    try expectCborError(Probe, error.UnexpectedEndOfInput, &.{ 0xa1, 0x61, 'x' });
    try expectCborError(Probe, error.UnexpectedEndOfInput, &.{ 0xbf, 0x61, 'x', 0x01 });
    try expectCborError(u8, error.TrailingCharacters, &.{ 0x01, 0x02 });
    // A simple value of 32 or more is well-formed, and skipped.
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa1, 0x61, 'x', 0xf8, 0x20 });
}

test "a tag other than self-described CBOR is not read through" {
    try expectCborError(Probe, error.UnexpectedTag, &.{ 0xa1, 0x61, 'a', 0xc1, 0x05 }); // epoch time around the field
    try expectCborError(u32, error.UnexpectedTag, &.{ 0xc2, 0x41, 0x05 }); // a bignum
    const self_described = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xd9, 0xd9, 0xf7, 0xa1, 0x61, 'a', 0xd9, 0xd9, 0xf7, 0x05 });
    try std.testing.expectEqual(@as(?u8, 5), self_described.a);
    // A skipped value may be tagged, however deeply.
    const skipped = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa2, 0x61, 'x', 0xc1, 0x81, 0xc2, 0x41, 0x05, 0x61, 'a', 0x07 });
    try std.testing.expectEqual(@as(?u8, 7), skipped.a);
}

// ---- duplicate map keys ----------------------------------------------------------------------------

test "CBOR refuses a map with a repeated key, known or not" {
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x61, 'a', 0x01, 0x61, 'a', 0x02 }); // a known field
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x61, 'x', 0x01, 0x61, 'x', 0x02 }); // an unknown field
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x61, 'x', 0x01, 0x78, 0x01, 'x', 0x02 }); // a key with a longer head
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x61, 'x', 0x01, 0x7f, 0x61, 'x', 0xff, 0x02 }); // a chunked key
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x01, 0x01, 0x18, 0x01, 0x02 }); // an integer key
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x20, 0x01, 0x20, 0x02 }); // a negative integer key
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x41, 'x', 0x01, 0x41, 'x', 0x02 }); // a byte-string key
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0xf9, 0x3c, 0x00, 0x01, 0xfa, 0x3f, 0x80, 0x00, 0x00, 0x02 }); // 1.0 in two widths
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0xf5, 0x01, 0xf5, 0x02 }); // true twice
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x81, 0x01, 0x00, 0x81, 0x01, 0x01 }); // an array key
    try expectCborError(Probe, error.DuplicateField, &.{ 0xbf, 0x61, 'x', 0x01, 0x61, 'x', 0x02, 0xff }); // in an indefinite map
}

test "CBOR refuses a repeated key inside a value it skips" {
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa1, 0x61, 'x', 0xa2, 0x01, 0x00, 0x01, 0x01 });
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa1, 0x61, 'x', 0x81, 0xa2, 0x61, 'k', 0x00, 0x61, 'k', 0x01 });
    // Inside a key that is itself a map.
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa1, 0xa2, 0x01, 0x00, 0x01, 0x01, 0x00 });
}

test "a dynamic value refuses a repeated key as well" {
    try std.testing.expectError(error.DuplicateField, zerde.value.parseSlice(zerde.cbor, allocator, &.{ 0xa2, 0x61, 'x', 0x01, 0x61, 'x', 0x02 }));
}

test "keys of different types are different keys" {
    // "x" and h'78'; 1 and 1.0; 1 and "1"; true and 1.
    const inputs = [_][]const u8{
        &.{ 0xa2, 0x61, 'x', 0x01, 0x41, 'x', 0x02 },
        &.{ 0xa2, 0x01, 0x01, 0xf9, 0x3c, 0x00, 0x02 },
        &.{ 0xa2, 0x01, 0x01, 0x61, '1', 0x02 },
        &.{ 0xa2, 0xf5, 0x01, 0x01, 0x02 },
        &.{ 0xa2, 0x00, 0x01, 0x20, 0x02 }, // 0 and -1
    };
    for (inputs) |input| _ = try zerde.cbor.parseSlice(Probe, allocator, input);
}

test "a large map of distinct unknown keys is read" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xb9, 0x01, 0x00 }); // 256 pairs
    for (0..256) |key| {
        try input.appendSlice(allocator, &.{ 0x19, @intCast(key >> 8), @intCast(key & 0xff), 0x00 });
    }
    const probe = try zerde.cbor.parseSlice(Probe, allocator, input.items);
    try std.testing.expectEqual(@as(?u8, null), probe.a);
    // One repeat among them is found.
    input.items[input.items.len - 4 - 1 - 2 + 3] = 0x00;
    input.items[input.items.len - 3] = 0x00;
    input.items[input.items.len - 2] = 0x07;
    try std.testing.expectError(error.DuplicateField, zerde.cbor.parseSlice(Probe, allocator, input.items));
}

test "JSON duplicate members keep their present behaviour" {
    // Not a decision: the lead has not settled whether JSON refuses or takes the last. A repeated
    // field the type knows is refused; a repeated member in a field nobody reads is skipped.
    try expectJsonError(Probe, error.DuplicateField, "{\"a\":1,\"a\":2}");
    const probe = try zerde.json.parseSlice(Probe, allocator, "{\"x\":1,\"x\":2,\"a\":3}");
    try std.testing.expectEqual(@as(?u8, 3), probe.a);
}

test "an integral float is not accepted as an enum tag either" {
    const Role = enum(u8) { captain = 1, doctor = 2 };
    try expectCborError(Role, error.UnexpectedType, &.{ 0xf9, 0x3c, 0x00 });
    try expectJsonError(Role, error.UnexpectedType, "1.0");
    const role = try zerde.cbor.parseSlice(Role, allocator, &.{0x02});
    try std.testing.expectEqual(Role.doctor, role);
}

test "MessagePack and BSON refuse text for a byte field" {
    const TextTag = struct { tag: []const u8 };
    const FixedTag = struct { tag: [2]u8 };
    const BlobTag = struct { tag: zerde.ByteString };

    inline for (.{ zerde.msgpack, zerde.bson }) |Format| {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try zerde.serialize(Format, &out.writer, TextTag{ .tag = "hi" });
        try std.testing.expectError(error.UnexpectedType, zerde.parseSlice(Format, FixedTag, allocator, out.written()));
        try std.testing.expectError(error.UnexpectedType, zerde.parseSlice(Format, BlobTag, allocator, out.written()));
    }
}

test "MessagePack refuses a finite double too large for a narrower float" {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try zerde.msgpack.serialize(&out.writer, @as(f64, 1e300));
    try std.testing.expectError(error.FloatOutOfRange, zerde.msgpack.parseSlice(f32, allocator, out.written()));
    try std.testing.expectEqual(@as(f64, 1e300), try zerde.msgpack.parseSlice(f64, allocator, out.written()));
}

test "JSON strings are UTF-8 before the first escape and between escapes" {
    try expectJsonError(Name, error.InvalidUtf8, "{\"name\":\"\xff\\n\"}");
    try expectJsonError(Name, error.InvalidUtf8, "{\"name\":\"\\n\xff\\n\"}");
    try expectJsonError(Name, error.InvalidUtf8, "{\"name\":\"\\n\\n\xff\"}");
}

test "equal keys in different maps are not repeats" {
    // "k" in two sibling maps and again one level down, all in skipped values.
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{
        0xa3,
        0x61,
        'x',
        0xa1,
        0x61,
        'k',
        0x01,
        0x61,
        'y',
        0xa1,
        0x61,
        'k',
        0x02,
        0x61,
        'z',
        0xa1,
        0x61,
        'k',
        0xa1,
        0x61,
        'k',
        0x03,
    });
    // The same through a chunked key, which is copied aside while its map is open.
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{
        0xa2,
        0x61,
        'x',
        0xa1,
        0x7f,
        0x61,
        'k',
        0xff,
        0x01,
        0x61,
        'y',
        0xa1,
        0x7f,
        0x61,
        'k',
        0xff,
        0x02,
    });
}

test "length_first and bytewise differ once names differ in length" {
    const Names = struct { aa: u8, z: u8 };
    const value = Names{ .aa = 1, .z = 2 };
    // Length first: "z" (one byte) before "aa". Bytewise: "aa" before "z".
    try expectCborBytes(&.{ 0xbf, 0x61, 'z', 0x02, 0x62, 'a', 'a', 0x01, 0xff }, value, .{ .field_order = .length_first }, .{});
    try expectCborBytes(&.{ 0xbf, 0x62, 'a', 'a', 0x01, 0x61, 'z', 0x02, 0xff }, value, .{ .field_order = .bytewise }, .{});
    try expectCborBytes(&.{ 0xa2, 0x61, 'z', 0x02, 0x62, 'a', 'a', 0x01 }, value, .{}, .{ .deterministic = true });
}

test "a field override from the call site wins over the type's" {
    const Plain = struct { a: u8, b: ?u8 };
    // The call site gives `a` an integer key and `b` the nullable policy; the type says nothing.
    const cfg = .{ .omit_null_fields = true, .fields = .{ .a = .{ .key = 7 }, .b = .{ .optional = .nullable } } };
    try expectCborBytes(&.{ 0xa2, 0x07, 0x01, 0x61, 'b', 0xf6 }, Plain{ .a = 1, .b = null }, cfg, .{ .deterministic = true });
    try std.testing.expectError(error.MissingField, zerde.cbor.parseSliceWith(Plain, allocator, &.{ 0xa1, 0x07, 0x01 }, cfg, .{}));

    // Over a type that sets its own key and policy.
    const Typed = struct {
        a: u8,
        b: ?u8,
        pub const serde = .{ .fields = .{ .a = .{ .key = 1 }, .b = .{ .optional = .absent } } };
    };
    try expectCborBytes(&.{ 0xa2, 0x07, 0x01, 0x61, 'b', 0xf6 }, Typed{ .a = 1, .b = null }, cfg, .{ .deterministic = true });
    try expectCborBytes(&.{ 0xa1, 0x01, 0x01 }, Typed{ .a = 1, .b = null }, .{ .omit_null_fields = true }, .{ .deterministic = true });
}

test "a dynamic value reads a CBOR byte string as bytes" {
    var value = try zerde.value.parseSlice(zerde.cbor, allocator, &.{ 0x82, 0x42, 'h', 'i', 0x62, 'h', 'i' });
    defer value.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "hi", value.array[0].bytes.bytes);
    try std.testing.expectEqualSlices(u8, "hi", value.array[1].string.bytes);
}

test "float keys are equal by RFC 8949 section 5.6.1" {
    // 0.0 and -0.0 are the same key, in any widths.
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0xf9, 0x00, 0x00, 0x00, 0xf9, 0x80, 0x00, 0x00 });
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0xf9, 0x00, 0x00, 0x00, 0xfb, 0x80, 0, 0, 0, 0, 0, 0, 0, 0x00 });
    // NaNs are the same key when their significands match once widened, whatever the width or sign.
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0xf9, 0x7e, 0x00, 0x00, 0xfa, 0x7f, 0xc0, 0x00, 0x00, 0x00 });
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0xf9, 0x7e, 0x00, 0x00, 0xf9, 0xfe, 0x00, 0x00 });
    // With different payloads they are different keys.
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa2, 0xf9, 0x7e, 0x00, 0x00, 0xf9, 0x7e, 0x01, 0x00 });
    // Infinities of opposite sign differ, and so do 0.0 and 1.0.
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa2, 0xf9, 0x7c, 0x00, 0x00, 0xf9, 0xfc, 0x00, 0x00 });
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa2, 0xf9, 0x00, 0x00, 0x00, 0xf9, 0x3c, 0x00, 0x00 });
}

test "array, map and tag keys are equal by value, not by spelling" {
    // [1] three ways.
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x81, 0x01, 0x00, 0x81, 0x18, 0x01, 0x00 });
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x81, 0x01, 0x00, 0x9f, 0x01, 0xff, 0x00 });
    // {1:1, 2:2} in two orders, one of them indefinite.
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0xa2, 0x01, 0x01, 0x02, 0x02, 0x00, 0xbf, 0x02, 0x02, 0x01, 0x01, 0xff, 0x00 });
    // A float zero inside a key, and a tagged key spelled two ways.
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x81, 0xf9, 0x00, 0x00, 0x00, 0x81, 0xf9, 0x80, 0x00, 0x00 });
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0xc1, 0x01, 0x00, 0xc1, 0x18, 0x01, 0x00 });
    // A text key inside a key, chunked.
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x81, 0x61, 'x', 0x00, 0x81, 0x7f, 0x61, 'x', 0xff, 0x00 });
    // Different values are different keys: [1] and [2], [1] and [1.0], a tagged and an untagged key.
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa2, 0x81, 0x01, 0x00, 0x81, 0x02, 0x00 });
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa2, 0x81, 0x01, 0x00, 0x81, 0xf9, 0x3c, 0x00, 0x00 });
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa2, 0xc1, 0x01, 0x00, 0x01, 0x00 });
    // Two maps that differ in one value.
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa2, 0xa1, 0x01, 0x01, 0x00, 0xa1, 0x01, 0x02, 0x00 });
}

test "composite keys keep their tag numbers and string lengths" {
    // Tag 1 and tag 2 around 1 are different keys.
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa2, 0xc1, 0x01, 0x00, 0xc2, 0x01, 0x00 });
    // ["a", "bc"] and ["ab", "c"] hold the same bytes and are different keys.
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa2, 0x82, 0x61, 'a', 0x62, 'b', 'c', 0x00, 0x82, 0x62, 'a', 'b', 0x61, 'c', 0x00 });
}

// ---- refuse NaN and infinity ----------------------------------------------------------------

test "refuse_non_finite turns NaN and infinity into an error, wherever they are" {
    const refuse = .{ .refuse_non_finite = true };
    const nan_half = [_]u8{ 0xa1, 0x61, 'v', 0xf9, 0x7e, 0x00 };
    const inf_single = [_]u8{ 0xa1, 0x61, 'v', 0xfa, 0xff, 0x80, 0x00, 0x00 };
    const inf_double = [_]u8{ 0xa1, 0x61, 'v', 0xfb, 0x7f, 0xf0, 0, 0, 0, 0, 0, 0 };
    for ([_][]const u8{ &nan_half, &inf_single, &inf_double }) |input| {
        try std.testing.expectError(error.NonFiniteFloat, zerde.cbor.parseSliceWith(Real, allocator, input, .{}, refuse));
        // The default reads them.
        _ = try zerde.cbor.parseSliceWith(Real, allocator, input, .{}, .{});
    }
    // In a skipped value, in a skipped key, and in a dynamic value.
    try std.testing.expectError(error.NonFiniteFloat, zerde.cbor.parseSliceWith(Probe, allocator, &.{ 0xa1, 0x61, 'x', 0x81, 0xf9, 0x7c, 0x00 }, .{}, refuse));
    try std.testing.expectError(error.NonFiniteFloat, zerde.cbor.parseSliceWith(Probe, allocator, &.{ 0xa1, 0xf9, 0x7e, 0x00, 0x01 }, .{}, refuse));
    try std.testing.expectError(error.NonFiniteFloat, zerde.cbor.parseSliceWith(Probe, allocator, &.{ 0xa1, 0x81, 0xf9, 0x7e, 0x00, 0x01 }, .{}, refuse));
    // Finite floats of every width are fine.
    const ok = try zerde.cbor.parseSliceWith(Real, allocator, &.{ 0xa1, 0x61, 'v', 0xf9, 0x3e, 0x00 }, .{}, refuse);
    try std.testing.expectEqual(@as(f64, 1.5), ok.v);
    _ = try zerde.cbor.parseSliceWith(Real, allocator, &.{ 0xa1, 0x61, 'v', 0xfa, 0x7f, 0x7f, 0xff, 0xff }, .{}, refuse);
    _ = try zerde.cbor.parseSliceWith(Real, allocator, &.{ 0xa1, 0x61, 'v', 0xfb, 0x7f, 0xef, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .{}, refuse);
}

// ---- integer variant keys, integer enums ----------------------------------------------------------

const Op = union(enum) {
    ping,
    get: u32,
    put: struct { a: u8 },

    pub const serde = .{ .fields = .{
        .ping = .{ .key = 1 },
        .get = .{ .key = 2 },
        .put = .{ .key = 24 },
    } };
};

test "a union variant can have an integer key" {
    try expectCborBytes(&.{0x01}, Op{ .ping = {} }, .{}, .{ .deterministic = true });
    try expectCborBytes(&.{ 0xa1, 0x02, 0x07 }, Op{ .get = 7 }, .{}, .{ .deterministic = true });
    try expectCborBytes(&.{ 0xa1, 0x18, 0x18, 0xa1, 0x61, 'a', 0x03 }, Op{ .put = .{ .a = 3 } }, .{}, .{ .deterministic = true });
    for ([_]Op{ .ping, .{ .get = 9 }, .{ .put = .{ .a = 1 } } }) |op| try cborRoundTrip(Op, op, .{});
    // Another spelling of the key (a longer head) reads the same.
    const decoded = try zerde.cbor.parseSlice(Op, allocator, &.{ 0xa1, 0x18, 0x02, 0x07 });
    try std.testing.expectEqual(Op{ .get = 7 }, decoded);
}

test "an integer-keyed union refuses a text key, an unknown number and a second entry" {
    try expectCborError(Op, error.InvalidEnumTag, &.{ 0xa1, 0x63, 'g', 'e', 't', 0x07 });
    try expectCborError(Op, error.InvalidEnumTag, &.{ 0xa1, 0x05, 0x07 });
    try expectCborError(Op, error.InvalidEnumTag, &.{0x05});
    try expectCborError(Op, error.LengthMismatch, &.{ 0xa2, 0x02, 0x07, 0x02, 0x08 });
    try expectCborError(Op, error.UnexpectedType, &.{ 0xa1, 0x41, 'x', 0x07 });
    try expectCborError(Op, error.UnexpectedType, &.{ 0xf9, 0x3c, 0x00 });
    // The payload keeps its own checks.
    try expectCborError(Op, error.UnexpectedType, &.{ 0xa1, 0x02, 0x61, 'x' });
}

test "text and integer variant keys can mix in one union" {
    const MixedKeys = union(enum) {
        a: u8,
        b: u8,
        pub const serde = .{ .fields = .{ .b = .{ .key = 5 } } };
    };
    try cborRoundTrip(MixedKeys, .{ .a = 1 }, .{});
    try cborRoundTrip(MixedKeys, .{ .b = 1 }, .{});
    // JSON has no integer keys; asking for one is a compile error, so only text unions reach it.
    try jsonRoundTrip(Shape, .{ .circle = 3 }, .{}, .{});
}

const Level = enum(u8) {
    low = 1,
    high = 9,
    pub const serde = .{ .enum_repr = .integer };
};

test "an enum can be written as its number" {
    const Holder = struct { level: Level };
    try expectCborBytes(&.{ 0xa1, 0x65, 'l', 'e', 'v', 'e', 'l', 0x09 }, Holder{ .level = .high }, .{}, .{ .deterministic = true });
    try expectJsonText("{\"level\":1}", Holder{ .level = .low }, .{}, .{});
    try cborRoundTrip(Holder, .{ .level = .high }, .{});
    try jsonRoundTrip(Holder, .{ .level = .low }, .{}, .{});
    // It reads only the number; an unknown number is not a level.
    try expectJsonError(Holder, error.UnexpectedType, "{\"level\":\"low\"}");
    try expectJsonError(Holder, error.InvalidEnumTag, "{\"level\":2}");
    // The call site can ask for it too, for an enum whose type says nothing.
    const Plain = enum(u8) { a = 3, b = 4 };
    try expectJsonText("4", Plain.b, .{ .enum_repr = .integer }, .{});
    try expectJsonText("\"b\"", Plain.b, .{}, .{});
    // The name form still reads either.
    const by_number = try zerde.json.parseSlice(Plain, allocator, "3");
    try std.testing.expectEqual(Plain.a, by_number);
}

// ---- strict mode and limits --------------------------------------------------------------------------

const strict = .{ .mode = .strict };

fn expectStrict(comptime T: type, expected: anyerror, input: []const u8) !void {
    try std.testing.expectError(expected, zerde.cbor.parseSliceWith(T, allocator, input, .{}, strict));
}

test "strict reads accept exactly what the deterministic writer writes" {
    inline for (.{
        Blob{ .id = 1, .data = .{ .bytes = "\xff\x00" } },
        Keyed{ .f = 6, .e = 5, .d = 4, .c = 3, .b = 2, .a = 1 },
        Real{ .v = 1.5 },
        Real{ .v = 1.1 },
        Real{ .v = 100000.0 },
        Real{ .v = -0.0 },
        Real{ .v = std.math.inf(f64) },
        Real{ .v = std.math.nan(f64) },
        Mixed{ .big = 200, .text = "hello", .ratio = 0.5, .list = &.{ 1, 300, 65535 } },
    }) |value| {
        const T = @TypeOf(value);
        var out = try writeCbor(value, .{}, .{ .deterministic = true });
        defer out.deinit();
        const decoded = try zerde.cbor.parseSliceWith(T, allocator, out.written(), .{}, strict);
        defer zerde.free(allocator, decoded);
        // And it is a fixed point: strict reading then writing gives the same bytes.
        try expectCborBytes(out.written(), decoded, .{}, .{ .deterministic = true });
    }
    // A union, a nested array and negative integers.
    var out = try writeCbor(Op{ .put = .{ .a = 3 } }, .{}, .{ .deterministic = true });
    defer out.deinit();
    _ = try zerde.cbor.parseSliceWith(Op, allocator, out.written(), .{}, strict);
    const nested = try zerde.cbor.parseSliceWith([]const []const i64, allocator, &.{ 0x82, 0x82, 0x20, 0x38, 0x64, 0x80 }, .{}, strict);
    defer zerde.free(allocator, nested);
}

test "strict refuses a head that is longer than it needs to be" {
    try expectStrict(u8, error.NonDeterministicEncoding, &.{ 0x18, 0x05 });
    try expectStrict(u32, error.NonDeterministicEncoding, &.{ 0x19, 0x00, 0xff });
    try expectStrict(u32, error.NonDeterministicEncoding, &.{ 0x1a, 0x00, 0x00, 0xff, 0xff });
    try expectStrict(u64, error.NonDeterministicEncoding, &.{ 0x1b, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff });
    try expectStrict(i8, error.NonDeterministicEncoding, &.{ 0x38, 0x05 });
    try expectStrict([]const u8, error.NonDeterministicEncoding, &.{ 0x78, 0x01, 'a' });
    try expectStrict([]const u16, error.NonDeterministicEncoding, &.{ 0x98, 0x01, 0x01 });
    try expectStrict(Probe, error.NonDeterministicEncoding, &.{ 0xb8, 0x00 });
    // The shortest form of each width is fine.
    _ = try zerde.cbor.parseSliceWith(u8, allocator, &.{ 0x18, 0x18 }, .{}, strict);
    _ = try zerde.cbor.parseSliceWith(u16, allocator, &.{ 0x19, 0x01, 0x00 }, .{}, strict);
    _ = try zerde.cbor.parseSliceWith(u32, allocator, &.{ 0x1a, 0x00, 0x01, 0x00, 0x00 }, .{}, strict);
    _ = try zerde.cbor.parseSliceWith(u64, allocator, &.{ 0x1b, 0, 0, 0, 1, 0, 0, 0, 0 }, .{}, strict);
}

test "strict refuses indefinite lengths and tags" {
    try expectStrict([]const u16, error.NonDeterministicEncoding, &.{ 0x9f, 0x01, 0xff });
    try expectStrict(Probe, error.NonDeterministicEncoding, &.{ 0xbf, 0xff });
    try expectStrict([]const u8, error.NonDeterministicEncoding, &.{ 0x7f, 0x61, 'a', 0xff });
    try expectStrict(zerde.ByteString, error.NonDeterministicEncoding, &.{ 0x5f, 0x41, 0x01, 0xff });
    try expectStrict(u8, error.UnexpectedTag, &.{ 0xc1, 0x05 });
    try expectStrict(u8, error.UnexpectedTag, &.{ 0xd9, 0xd9, 0xf7, 0x05 });
    try expectStrict(Probe, error.UnexpectedTag, &.{ 0xa1, 0x61, 'x', 0xc1, 0x05 }); // a skipped value
    // Lenient takes all of them.
    _ = try zerde.cbor.parseSlice(u8, allocator, &.{ 0xd9, 0xd9, 0xf7, 0x05 });
}

test "strict refuses a float that is not in its shortest width" {
    try expectStrict(f64, error.NonDeterministicEncoding, &.{ 0xfa, 0x3f, 0xc0, 0x00, 0x00 }); // 1.5 as single
    try expectStrict(f64, error.NonDeterministicEncoding, &.{ 0xfb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0 }); // 1.5 as double
    try expectStrict(f64, error.NonDeterministicEncoding, &.{ 0xfb, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0 }); // 1.0 as double
    try expectStrict(f64, error.NonDeterministicEncoding, &.{ 0xfa, 0x7f, 0x80, 0x00, 0x00 }); // infinity as single
    try expectStrict(f64, error.NonDeterministicEncoding, &.{ 0xfa, 0x7f, 0xc0, 0x00, 0x00 }); // NaN as single
    try expectStrict(f64, error.NonDeterministicEncoding, &.{ 0xf9, 0x7e, 0x01 }); // a NaN with a payload
    try expectStrict(f64, error.NonDeterministicEncoding, &.{ 0xf9, 0xfe, 0x00 }); // a NaN with a sign
    try expectStrict(Probe, error.NonDeterministicEncoding, &.{ 0xa1, 0x61, 'x', 0xfb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0 }); // skipped
    // A value that needs the width it has is fine.
    _ = try zerde.cbor.parseSliceWith(f64, allocator, &.{ 0xfa, 0x47, 0xc3, 0x50, 0x00 }, .{}, strict);
    _ = try zerde.cbor.parseSliceWith(f64, allocator, &.{ 0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a }, .{}, strict);
    _ = try zerde.cbor.parseSliceWith(f64, allocator, &.{ 0xf9, 0x80, 0x00 }, .{}, strict);
    // Lenient takes the long spellings.
    _ = try zerde.cbor.parseSlice(f64, allocator, &.{ 0xfb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0 });
}

test "strict needs map keys in ascending order of their encoded bytes, with none repeated" {
    // "b" before "a"; and a longer key before a shorter one.
    try expectStrict(Probe, error.NonDeterministicEncoding, &.{ 0xa2, 0x61, 'b', 0x00, 0x61, 'a', 0x00 });
    try expectStrict(Probe, error.NonDeterministicEncoding, &.{ 0xa2, 0x62, 'a', 'a', 0x00, 0x61, 'z', 0x00 });
    try expectStrict(Probe, error.DuplicateField, &.{ 0xa2, 0x61, 'a', 0x01, 0x61, 'a', 0x02 });
    try expectStrict(Probe, error.NonDeterministicEncoding, &.{ 0xa2, 0x02, 0x00, 0x01, 0x00 }); // integer keys
    try expectStrict(Probe, error.NonDeterministicEncoding, &.{ 0xa2, 0x20, 0x00, 0x01, 0x00 }); // -1 sorts after 1
    // In a skipped value.
    try expectStrict(Probe, error.NonDeterministicEncoding, &.{ 0xa1, 0x61, 'x', 0xa2, 0x61, 'b', 0x00, 0x61, 'a', 0x00 });
    try expectStrict(Probe, error.NonDeterministicEncoding, &.{ 0xa2, 0x61, 'x', 0x00, 0x61, 'a', 0x01 });
    // Ascending is fine, mixing types as the major types sort.
    _ = try zerde.cbor.parseSliceWith(Probe, allocator, &.{ 0xa3, 0x01, 0x00, 0x20, 0x00, 0x61, 'x', 0x00 }, .{}, strict);
    // Lenient takes any order.
    _ = try zerde.cbor.parseSlice(Probe, allocator, &.{ 0xa2, 0x61, 'b', 0x00, 0x61, 'a', 0x00 });
}

test "limits: depth, items and string length" {
    // Depth: a map holding an array holding an array is three levels.
    const three = [_]u8{ 0xa1, 0x61, 'x', 0x81, 0x81, 0x00 };
    _ = try zerde.cbor.parseSliceWith(Probe, allocator, &three, .{}, .{ .max_depth = 3 });
    try std.testing.expectError(error.CborNestingTooDeep, zerde.cbor.parseSliceWith(Probe, allocator, &three, .{}, .{ .max_depth = 2 }));
    // Typed containers count the same way.
    try std.testing.expectError(error.CborNestingTooDeep, zerde.cbor.parseSliceWith([]const []const u16, allocator, &.{ 0x81, 0x80 }, .{}, .{ .max_depth = 1 }));
    // The most the fixed stack holds is allowed: 127 arrays in a map is 128 containers, 128 is not.
    const fits = try nestedCbor(127, 0x81);
    defer allocator.free(fits);
    _ = try zerde.cbor.parseSliceWith(Probe, allocator, fits, .{}, .{ .max_depth = 128 });
    const over = try nestedCbor(128, 0x81);
    defer allocator.free(over);
    try std.testing.expectError(error.CborNestingTooDeep, zerde.cbor.parseSliceWith(Probe, allocator, over, .{}, .{ .max_depth = 128 }));

    // Items: the map, its key and its value are three.
    const two_pairs = [_]u8{ 0xa2, 0x61, 'x', 0x00, 0x61, 'y', 0x00 };
    _ = try zerde.cbor.parseSliceWith(Probe, allocator, &two_pairs, .{}, .{ .max_items = 5 });
    try std.testing.expectError(error.TooManyItems, zerde.cbor.parseSliceWith(Probe, allocator, &two_pairs, .{}, .{ .max_items = 4 }));
    // A skipped array's elements count, and a typed array's.
    try std.testing.expectError(error.TooManyItems, zerde.cbor.parseSliceWith(Probe, allocator, &.{ 0xa1, 0x61, 'x', 0x83, 0x01, 0x02, 0x03 }, .{}, .{ .max_items = 5 }));
    try std.testing.expectError(error.TooManyItems, zerde.cbor.parseSliceWith([]const u16, allocator, &.{ 0x83, 0x01, 0x02, 0x03 }, .{}, .{ .max_items = 3 }));
    const sixteen = try zerde.cbor.parseSliceWith([]const u16, allocator, &.{ 0x83, 0x01, 0x02, 0x03 }, .{}, .{ .max_items = 4 });
    allocator.free(sixteen);

    // String length: text and bytes, definite and in chunks, and a skipped string.
    const Text = struct { s: []const u8 };
    const hi = [_]u8{ 0xa1, 0x61, 's', 0x62, 'h', 'i' };
    const text = try zerde.cbor.parseSliceWith(Text, allocator, &hi, .{}, .{ .max_string_len = 2 });
    allocator.free(text.s);
    try std.testing.expectError(error.StringTooLong, zerde.cbor.parseSliceWith(Text, allocator, &hi, .{}, .{ .max_string_len = 1 }));
    try std.testing.expectError(error.StringTooLong, zerde.cbor.parseSliceWith(zerde.ByteString, allocator, &.{ 0x43, 1, 2, 3 }, .{}, .{ .max_string_len = 2 }));
    try std.testing.expectError(error.StringTooLong, zerde.cbor.parseSliceWith([]const u8, allocator, &.{ 0x7f, 0x62, 'h', 'i', 0x62, 'h', 'i', 0xff }, .{}, .{ .max_string_len = 3 }));
    try std.testing.expectError(error.StringTooLong, zerde.cbor.parseSliceWith(Probe, allocator, &.{ 0xa1, 0x61, 'x', 0x43, 1, 2, 3 }, .{}, .{ .max_string_len = 2 }));
    // A key is a string too.
    try std.testing.expectError(error.StringTooLong, zerde.cbor.parseSliceWith(Probe, allocator, &.{ 0xa1, 0x63, 'a', 'b', 'c', 0x00 }, .{}, .{ .max_string_len = 2 }));
}

test "JSON limits: depth, items and string length" {
    const Text = struct { s: []const u8 };
    // Depth: the object and two arrays.
    const three = "{\"x\":[[0]]}";
    _ = try zerde.json.parseSliceWith(Probe, allocator, three, .{}, .{ .max_depth = 3 });
    try std.testing.expectError(error.JsonNestingTooDeep, zerde.json.parseSliceWith(Probe, allocator, three, .{}, .{ .max_depth = 2 }));
    try std.testing.expectError(error.JsonNestingTooDeep, zerde.json.parseSliceWith([]const []const u16, allocator, "[[]]", .{}, .{ .max_depth = 1 }));

    // Items: the object, two keys and two values are five.
    const pairs = "{\"x\":0,\"y\":0}";
    _ = try zerde.json.parseSliceWith(Probe, allocator, pairs, .{}, .{ .max_items = 5 });
    try std.testing.expectError(error.TooManyItems, zerde.json.parseSliceWith(Probe, allocator, pairs, .{}, .{ .max_items = 4 }));
    // A skipped number, string and literal each count.
    try std.testing.expectError(error.TooManyItems, zerde.json.parseSliceWith(Probe, allocator, "{\"x\":[1,\"a\",null,true,false]}", .{}, .{ .max_items = 6 }));
    try std.testing.expectError(error.TooManyItems, zerde.json.parseSliceWith([]const u16, allocator, "[1,2,3]", .{}, .{ .max_items = 3 }));
    const three_items = try zerde.json.parseSliceWith([]const u16, allocator, "[1,2,3]", .{}, .{ .max_items = 4 });
    allocator.free(three_items);

    // String length counts decoded bytes: "\u00e9" is two bytes, and an escape is one.
    const fits = try zerde.json.parseSliceWith(Text, allocator, "{\"s\":\"h\\u00e9\"}", .{}, .{ .max_string_len = 3 });
    allocator.free(fits.s);
    try std.testing.expectError(error.StringTooLong, zerde.json.parseSliceWith(Text, allocator, "{\"s\":\"h\\u00e9\"}", .{}, .{ .max_string_len = 2 }));
    try std.testing.expectError(error.StringTooLong, zerde.json.parseSliceWith(Text, allocator, "{\"s\":\"abc\"}", .{}, .{ .max_string_len = 2 }));
    try std.testing.expectError(error.StringTooLong, zerde.json.parseSliceWith(Probe, allocator, "{\"x\":\"abc\"}", .{}, .{ .max_string_len = 2 }));
    try std.testing.expectError(error.StringTooLong, zerde.json.parseSliceWith(Probe, allocator, "{\"abc\":1}", .{}, .{ .max_string_len = 2 }));
}

test "strict checks the order of the keys of a union, and the items limit counts keys exactly" {
    try expectStrict(Op, error.NonDeterministicEncoding, &.{ 0xa2, 0x02, 0x07, 0x01, 0x00 });
    try expectStrict(Shape, error.NonDeterministicEncoding, &.{ 0xa2, 0x66, 'c', 'i', 'r', 'c', 'l', 'e', 0x01, 0x65, 'l', 'a', 'b', 'e', 'l', 0x61, 'x' });
    // Not strict, the second entry is a length mismatch whatever its order.
    try expectCborError(Op, error.LengthMismatch, &.{ 0xa2, 0x02, 0x07, 0x01, 0x00 });
    // A double that is infinity or NaN is not preferred; a half is.
    try expectStrict(f64, error.NonDeterministicEncoding, &.{ 0xfb, 0x7f, 0xf0, 0, 0, 0, 0, 0, 0 });
    try expectStrict(f64, error.NonDeterministicEncoding, &.{ 0xfb, 0x7f, 0xf8, 0, 0, 0, 0, 0, 0 });
    // An array key is one item and its elements: a map, [1], 0 is four items, however it is reached.
    _ = try zerde.cbor.parseSliceWith(Probe, allocator, &.{ 0xa1, 0x81, 0x01, 0x00 }, .{}, .{ .max_items = 4 });
    try std.testing.expectError(error.TooManyItems, zerde.cbor.parseSliceWith(Probe, allocator, &.{ 0xa1, 0x81, 0x01, 0x00 }, .{}, .{ .max_items = 3 }));
    _ = try zerde.cbor.parseSliceWith(Probe, allocator, &.{ 0xa1, 0x61, 'x', 0xa1, 0x81, 0x01, 0x00 }, .{}, .{ .max_items = 6 });
    try std.testing.expectError(error.TooManyItems, zerde.cbor.parseSliceWith(Probe, allocator, &.{ 0xa1, 0x61, 'x', 0xa1, 0x81, 0x01, 0x00 }, .{}, .{ .max_items = 5 }));
    // Every JSON value kind counts once: an object, a key, an array and one element is four.
    inline for (.{ "1", "\"a\"", "null", "true", "false", "[]", "{}" }) |element| {
        const text = "{\"x\":[" ++ element ++ "]}";
        _ = try zerde.json.parseSliceWith(Probe, allocator, text, .{}, .{ .max_items = 4 });
        try std.testing.expectError(error.TooManyItems, zerde.json.parseSliceWith(Probe, allocator, text, .{}, .{ .max_items = 3 }));
    }
}

test "strict checks the order of text keys in a union that also has integer keys" {
    const Wide = union(enum) {
        a: u8,
        c: u8,
        n: u8,
        pub const serde = .{ .fields = .{ .n = .{ .key = 5 } } };
    };
    try expectStrict(Wide, error.NonDeterministicEncoding, &.{ 0xa2, 0x61, 'c', 0x01, 0x61, 'a', 0x01 });
    try expectStrict(Wide, error.NonDeterministicEncoding, &.{ 0xa2, 0x61, 'a', 0x01, 0x05, 0x01 });
    _ = try zerde.cbor.parseSliceWith(Wide, allocator, &.{ 0xa1, 0x61, 'c', 0x01 }, .{}, strict);
}

// ---- Raw ---------------------------------------------------------------------------------------------

fn FramedOf(comptime R: type) type {
    return struct { id: u8, meta: R, after: ?u8 = null };
}
const Framed = FramedOf(zerde.cbor.Raw);
const FramedJson = FramedOf(zerde.json.Raw);

test "a CBOR Raw is the item's own bytes, whatever its spelling" {
    // meta is an indefinite map with a non-minimal head and a chunked string: a lenient read keeps it as it is.
    const meta = [_]u8{ 0xbf, 0x61, 'k', 0x9f, 0x18, 0x01, 0x02, 0xff, 0x61, 'j', 0x7f, 0x61, 'a', 0x61, 'b', 0xff, 0xff };
    const input = [_]u8{ 0xa3, 0x62, 'i', 'd', 0x07, 0x64, 'm', 'e', 't', 'a' } ++ meta ++ [_]u8{ 0x65, 'a', 'f', 't', 'e', 'r', 0x09 };
    const decoded = try zerde.cbor.parseSlice(Framed, allocator, &input);
    defer zerde.free(allocator, decoded);
    try std.testing.expectEqual(@as(u8, 7), decoded.id);
    try std.testing.expectEqualSlices(u8, &meta, decoded.meta.bytes);
    try std.testing.expectEqual(@as(?u8, 9), decoded.after);
    // A default write puts it back unchanged inside the map around it.
    try expectCborBytes(&([_]u8{ 0xbf, 0x62, 'i', 'd', 0x07, 0x64, 'm', 'e', 't', 'a' } ++ meta ++ [_]u8{ 0x65, 'a', 'f', 't', 'e', 'r', 0x09, 0xff }), decoded, .{}, .{});
    // A deterministic write promises deterministic bytes, so it refuses what is not, and takes it
    // once canonicalized: the map sorted, definite, the chunks joined, the head shortened.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.NonDeterministicEncoding, zerde.serializeWith(zerde.cbor, &out.writer, decoded, .{}, .{ .deterministic = true }));
    const canonical = try zerde.cbor.canonicalize(allocator, decoded.meta.bytes);
    defer allocator.free(canonical);
    try std.testing.expectEqualSlices(u8, &.{ 0xa2, 0x61, 'j', 0x62, 'a', 'b', 0x61, 'k', 0x82, 0x01, 0x02 }, canonical);
    const fixed = Framed{ .id = 7, .meta = .{ .bytes = canonical }, .after = 9 };
    try expectCborBytes(&([_]u8{ 0xa3, 0x62, 'i', 'd', 0x07, 0x64, 'm', 'e', 't', 'a' } ++ [_]u8{ 0xa2, 0x61, 'j', 0x62, 'a', 'b', 0x61, 'k', 0x82, 0x01, 0x02 } ++ [_]u8{ 0x65, 'a', 'f', 't', 'e', 'r', 0x09 }), fixed, .{}, .{ .deterministic = true });
    // Any item can be raw: a scalar, an array, a tagged value.
    inline for (.{ &[_]u8{ 0x82, 0x01, 0x02 }, &[_]u8{ 0xc1, 0x1a, 0x00, 0x00, 0x00, 0x01 }, &[_]u8{0xf5} }) |item| {
        const bytes = [_]u8{ 0xa2, 0x62, 'i', 'd', 0x00, 0x64, 'm', 'e', 't', 'a' } ++ item.*;
        const one = try zerde.cbor.parseSlice(Framed, allocator, &bytes);
        defer zerde.free(allocator, one);
        try std.testing.expectEqualSlices(u8, item, one.meta.bytes);
    }
}

test "a CBOR Raw is validated like any item, in the read's mode and limits" {
    const head = [_]u8{ 0xa2, 0x62, 'i', 'd', 0x00, 0x64, 'm', 'e', 't', 'a' };
    const cases = [_]struct { item: []const u8, err: anyerror }{
        .{ .item = &.{ 0x82, 0x01 }, .err = error.UnexpectedEndOfInput }, // truncated
        .{ .item = &.{ 0x62, 0xc3, 0x28 }, .err = error.InvalidUtf8 },
        .{ .item = &.{ 0xa2, 0x01, 0x00, 0x01, 0x00 }, .err = error.DuplicateField },
        .{ .item = &.{0xff}, .err = error.InvalidAdditionalInfo },
        .{ .item = &.{ 0xf8, 0x10 }, .err = error.InvalidSimpleValue },
    };
    for (cases) |case| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(allocator);
        try input.appendSlice(allocator, &head);
        try input.appendSlice(allocator, case.item);
        try expectCborError(Framed, case.err, input.items);
    }
    // Strict refuses a Raw that is not deterministic; lenient takes it.
    const loose = head ++ [_]u8{ 0x9f, 0x01, 0xff };
    const kept = try zerde.cbor.parseSliceWith(Framed, allocator, &loose, .{}, .{});
    zerde.free(allocator, kept);
    try std.testing.expectError(error.NonDeterministicEncoding, zerde.cbor.parseSliceWith(Framed, allocator, &loose, .{}, strict));
    // Limits count inside it: depth, items, string length, and NaN.
    const deep = head ++ [_]u8{ 0x81, 0x81, 0x00 };
    try std.testing.expectError(error.CborNestingTooDeep, zerde.cbor.parseSliceWith(Framed, allocator, &deep, .{}, .{ .max_depth = 2 }));
    try std.testing.expectError(error.TooManyItems, zerde.cbor.parseSliceWith(Framed, allocator, &deep, .{}, .{ .max_items = 6 }));
    const nan = head ++ [_]u8{ 0xf9, 0x7e, 0x00 };
    try std.testing.expectError(error.NonFiniteFloat, zerde.cbor.parseSliceWith(Framed, allocator, &nan, .{}, .{ .refuse_non_finite = true }));
    const long = head ++ [_]u8{ 0x43, 1, 2, 3 };
    try std.testing.expectError(error.StringTooLong, zerde.cbor.parseSliceWith(Framed, allocator, &long, .{}, .{ .max_string_len = 2 }));
}

test "Raw borrows the input when the parse aliases it, and owns a copy otherwise" {
    const input = [_]u8{ 0xa2, 0x62, 'i', 'd', 0x00, 0x64, 'm', 'e', 't', 'a', 0x82, 0x01, 0x02 };
    const aliased = try zerde.cbor.parseSliceAliased(Framed, allocator, &input);
    const begin = @intFromPtr(&input);
    try std.testing.expect(@intFromPtr(aliased.meta.bytes.ptr) >= begin and @intFromPtr(aliased.meta.bytes.ptr) < begin + input.len);
    const owned = try zerde.cbor.parseSlice(Framed, allocator, &input);
    defer zerde.free(allocator, owned);
    try std.testing.expect(@intFromPtr(owned.meta.bytes.ptr) < begin or @intFromPtr(owned.meta.bytes.ptr) >= begin + input.len);
}

test "Raw in an array, an optional and a union" {
    const Holder = struct { items: []const zerde.cbor.Raw, maybe: ?zerde.cbor.Raw };
    const input = [_]u8{ 0xa2, 0x65, 'i', 't', 'e', 'm', 's', 0x82, 0x01, 0x61, 'x', 0x65, 'm', 'a', 'y', 'b', 'e', 0xf6 };
    const decoded = try zerde.cbor.parseSlice(Holder, allocator, &input);
    defer zerde.free(allocator, decoded);
    try std.testing.expectEqual(@as(usize, 2), decoded.items.len);
    try std.testing.expectEqualSlices(u8, &.{0x01}, decoded.items[0].bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x61, 'x' }, decoded.items[1].bytes);
    try std.testing.expectEqual(@as(?zerde.cbor.Raw, null), decoded.maybe);
}

test "a JSON Raw is the value's own text without the whitespace around it" {
    const input = "{ \"id\" : 7 , \"meta\" :  { \"k\" : [ 1 , 2 ] , \"j\" : \"\\u0041\" }  , \"after\":9}";
    const decoded = try zerde.json.parseSlice(FramedJson, allocator, input);
    defer zerde.free(allocator, decoded);
    try std.testing.expectEqualStrings("{ \"k\" : [ 1 , 2 ] , \"j\" : \"\\u0041\" }", decoded.meta.bytes);
    try expectJsonText("{\"id\":7,\"meta\":{ \"k\" : [ 1 , 2 ] , \"j\" : \"\\u0041\" },\"after\":9}", decoded, .{}, .{});
    // It is still checked: syntax, UTF-8, depth, items.
    try expectJsonError(FramedJson, error.UnexpectedToken, "{\"id\":1,\"meta\":{\"a\":}}");
    try expectJsonError(FramedJson, error.InvalidUtf8, "{\"id\":1,\"meta\":\"\xff\"}");
    try std.testing.expectError(error.JsonNestingTooDeep, zerde.json.parseSliceWith(FramedJson, allocator, "{\"id\":1,\"meta\":[[1]]}", .{}, .{ .max_depth = 2 }));
    try std.testing.expectError(error.TooManyItems, zerde.json.parseSliceWith(FramedJson, allocator, "{\"id\":1,\"meta\":[1,2,3]}", .{}, .{ .max_items = 5 }));
}

// ---- bounds and check ----------------------------------------------------------------------------------

fn BoundedOf(comptime R: type) type {
    return struct {
        name: []const u8,
        blob: zerde.ByteString,
        items: []const u16,
        level: u8,
        note: ?[]const u8 = null,
        low: i64 = 0,
        meta: R,

        pub const serde = .{ .fields = .{
            .name = .{ .min_len = 1, .max_len = 4 },
            .blob = .{ .max_len = 3 },
            .items = .{ .min_len = 1, .max_len = 3 },
            .level = .{ .min = 10, .max = 20 },
            .note = .{ .max_len = 2 },
            .low = .{ .min = -5 },
            .meta = .{ .max_len = 4 },
        } };
    };
}
const Bounded = BoundedOf(zerde.cbor.Raw);
const BoundedJson = BoundedOf(zerde.json.Raw);

fn boundedJson(name: []const u8, blob: []const u8, items: []const u8, level: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"blob\":\"{s}\",\"items\":{s},\"level\":{s},\"meta\":1{s}}}", .{ name, blob, items, level, extra });
}

test "bounds are enforced on text, bytes, arrays, optionals, raw items and integers" {
    const ok = try boundedJson("abcd", "abc", "[1,2,3]", "20", ",\"note\":\"ab\",\"low\":-5");
    defer allocator.free(ok);
    const parsed = try zerde.json.parseSlice(BoundedJson, allocator, ok);
    zerde.free(allocator, parsed);

    const cases = [_]struct { name: []const u8, blob: []const u8, items: []const u8, level: []const u8, extra: []const u8, err: anyerror }{
        .{ .name = "", .blob = "a", .items = "[1]", .level = "10", .extra = "", .err = error.LengthOutOfBounds },
        .{ .name = "abcde", .blob = "a", .items = "[1]", .level = "10", .extra = "", .err = error.LengthOutOfBounds },
        .{ .name = "a", .blob = "abcd", .items = "[1]", .level = "10", .extra = "", .err = error.LengthOutOfBounds },
        .{ .name = "a", .blob = "a", .items = "[]", .level = "10", .extra = "", .err = error.LengthOutOfBounds },
        .{ .name = "a", .blob = "a", .items = "[1,2,3,4]", .level = "10", .extra = "", .err = error.LengthOutOfBounds },
        .{ .name = "a", .blob = "a", .items = "[1]", .level = "9", .extra = "", .err = error.ValueOutOfRange },
        .{ .name = "a", .blob = "a", .items = "[1]", .level = "21", .extra = "", .err = error.ValueOutOfRange },
        .{ .name = "a", .blob = "a", .items = "[1]", .level = "10", .extra = ",\"note\":\"abc\"", .err = error.LengthOutOfBounds },
        .{ .name = "a", .blob = "a", .items = "[1]", .level = "10", .extra = ",\"low\":-6", .err = error.ValueOutOfRange },
    };
    for (cases) |case| {
        const text = try boundedJson(case.name, case.blob, case.items, case.level, case.extra);
        defer allocator.free(text);
        try expectJsonError(BoundedJson, case.err, text);
    }
    // A null optional has no length to bound; a raw item's own length is bounded.
    const with_null = try boundedJson("a", "a", "[1]", "10", ",\"note\":null");
    defer allocator.free(with_null);
    zerde.free(allocator, try zerde.json.parseSlice(BoundedJson, allocator, with_null));
    try expectJsonError(BoundedJson, error.LengthOutOfBounds, "{\"name\":\"a\",\"blob\":\"a\",\"items\":[1],\"level\":10,\"meta\":12345}");
}

test "bounds in CBOR, and a length is refused before anything is allocated" {
    const a = [_]u8{ 0xa5, 0x64, 'n', 'a', 'm', 'e', 0x61, 'x', 0x64, 'b', 'l', 'o', 'b', 0x41, 0x01, 0x65, 'i', 't', 'e', 'm', 's', 0x81, 0x01, 0x65, 'l', 'e', 'v', 'e', 'l', 0x0a, 0x64, 'm', 'e', 't', 'a', 0x01 };
    zerde.free(allocator, try zerde.cbor.parseSlice(Bounded, allocator, &a));

    // An array that claims 1,000 items, with the bytes to hold them, against a bound of 3.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(allocator);
    try big.appendSlice(allocator, &.{ 0xa1, 0x65, 'i', 't', 'e', 'm', 's', 0x99, 0x03, 0xe8 });
    try big.appendNTimes(allocator, 0x01, 1000);
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSlice(Bounded, failing.allocator(), big.items));
    // Text and bytes too long are refused by the same check.
    const long_text = [_]u8{ 0xa1, 0x64, 'n', 'a', 'm', 'e', 0x65, 'a', 'b', 'c', 'd', 'e' };
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSlice(Bounded, failing.allocator(), &long_text));
    const long_bytes = [_]u8{ 0xa1, 0x64, 'b', 'l', 'o', 'b', 0x44, 1, 2, 3, 4 };
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSlice(Bounded, failing.allocator(), &long_bytes));
    // An indefinite array is counted as it is read.
    const indefinite = [_]u8{ 0xa1, 0x65, 'i', 't', 'e', 'm', 's', 0x9f, 0x01, 0x02, 0x03, 0x04, 0xff };
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSlice(Bounded, allocator, &indefinite));
}

test "bounds can come from the call site, and are not checked on write" {
    const cfg = .{ .fields = .{ .s = .{ .max_len = 2 }, .n = .{ .max = 5 } } };
    const Plain = struct { s: []const u8, n: u8 };
    try expectJsonText("{\"s\":\"abcdef\",\"n\":200}", Plain{ .s = "abcdef", .n = 200 }, cfg, .{});
    const ok = try zerde.json.parseSliceWith(Plain, allocator, "{\"s\":\"ab\",\"n\":5}", cfg, .{});
    zerde.free(allocator, ok);
    try std.testing.expectError(error.LengthOutOfBounds, zerde.json.parseSliceWith(Plain, allocator, "{\"s\":\"abc\",\"n\":5}", cfg, .{}));
    try std.testing.expectError(error.ValueOutOfRange, zerde.json.parseSliceWith(Plain, allocator, "{\"s\":\"ab\",\"n\":6}", cfg, .{}));
}

const Range = struct {
    lo: u8,
    label: []const u8,
    hi: u8,

    pub fn check(self: Range) error{Invalid}!void {
        if (self.lo > self.hi) return error.Invalid;
    }
};

test "a struct's check runs after it is read and its error is returned" {
    const ok = try zerde.json.parseSlice(Range, allocator, "{\"lo\":1,\"label\":\"x\",\"hi\":2}");
    zerde.free(allocator, ok);
    try expectJsonError(Range, error.Invalid, "{\"lo\":3,\"label\":\"x\",\"hi\":2}");
    const bad = [_]u8{ 0xa3, 0x62, 'l', 'o', 0x03, 0x65, 'l', 'a', 'b', 'e', 'l', 0x61, 'x', 0x62, 'h', 'i', 0x02 };
    try expectCborError(Range, error.Invalid, &bad);
    // A nested struct is checked too, and the failure leaks nothing (the testing allocator checks).
    const Outer = struct { inner: Range, tag: []const u8 };
    try expectJsonError(Outer, error.Invalid, "{\"tag\":\"t\",\"inner\":{\"lo\":9,\"label\":\"x\",\"hi\":2}}");
}

test "an indefinite array stops growing at its bound, and bin checks too" {
    // 1,000 items in an indefinite array, a bound of 3, and an allocator that fails on its second call:
    // the bound is hit before the list grows again.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(allocator);
    try big.appendSlice(allocator, &.{ 0xa1, 0x65, 'i', 't', 'e', 'm', 's', 0x9f });
    try big.appendNTimes(allocator, 0x01, 1000);
    try big.append(allocator, 0xff);
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSlice(Bounded, failing.allocator(), big.items));

    // The binary format reads fields in order and runs `check` as well.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try zerde.bin.serialize(&out.writer, Range{ .lo = 5, .label = "x", .hi = 1 });
    try std.testing.expectError(error.Invalid, zerde.bin.parseSlice(Range, allocator, out.written()));
}

// ---- extras ----------------------------------------------------------------------------------------------

fn WithExtrasOf(comptime R: type) type {
    return struct {
        id: u8,
        name: []const u8,
        rest: R,

        pub const serde = .{ .extras = "rest" };
    };
}
const WithExtras = WithExtrasOf(zerde.cbor.Raw);
const WithExtrasJson = WithExtrasOf(zerde.json.Raw);

fn MaybeExtrasOf(comptime R: type) type {
    return struct {
        id: u8,
        rest: ?R = null,

        pub const serde = .{ .extras = "rest", .deny_unknown_fields = true };
    };
}
const MaybeExtras = MaybeExtrasOf(zerde.cbor.Raw);
const MaybeExtrasJson = MaybeExtrasOf(zerde.json.Raw);

test "CBOR extras collect the unknown members as one map in key order" {
    // id, name, then z, a and bb in that order, which is not key order.
    const input = [_]u8{ 0xa5, 0x62, 'i', 'd', 0x01, 0x61, 'z', 0x81, 0x01, 0x64, 'n', 'a', 'm', 'e', 0x61, 'n', 0x61, 'a', 0xf5, 0x62, 'b', 'b', 0x61, 'x' };
    const decoded = try zerde.cbor.parseSlice(WithExtras, allocator, &input);
    defer zerde.free(allocator, decoded);
    try std.testing.expectEqualSlices(u8, &.{ 0xa3, 0x61, 'a', 0xf5, 0x61, 'z', 0x81, 0x01, 0x62, 'b', 'b', 0x61, 'x' }, decoded.rest.bytes);
    try std.testing.expectEqual(@as(u8, 1), decoded.id);
    // Written back, the extras are merged among the declared members in key order.
    try expectCborBytes(&.{
        0xa5,
        0x61,
        'a',
        0xf5,
        0x61,
        'z',
        0x81,
        0x01,
        0x62,
        'b',
        'b',
        0x61,
        'x',
        0x62,
        'i',
        'd',
        0x01,
        0x64,
        'n',
        'a',
        'm',
        'e',
        0x61,
        'n',
    }, decoded, .{}, .{ .deterministic = true });
    // And a deterministic read of that output reads it back as the same bytes.
    var out = try writeCbor(decoded, .{}, .{ .deterministic = true });
    defer out.deinit();
    const again = try zerde.cbor.parseSliceWith(WithExtras, allocator, out.written(), .{}, .{ .mode = .strict });
    defer zerde.free(allocator, again);
    try std.testing.expectEqualSlices(u8, decoded.rest.bytes, again.rest.bytes);
}

test "without unknown members the extras are an empty map, or null for an optional" {
    const input = [_]u8{ 0xa2, 0x62, 'i', 'd', 0x01, 0x64, 'n', 'a', 'm', 'e', 0x61, 'n' };
    const decoded = try zerde.cbor.parseSlice(WithExtras, allocator, &input);
    defer zerde.free(allocator, decoded);
    try std.testing.expectEqualSlices(u8, &.{0xa0}, decoded.rest.bytes);
    try expectCborBytes(&input, decoded, .{}, .{ .deterministic = true });
    const maybe = try zerde.cbor.parseSlice(MaybeExtras, allocator, &.{ 0xa1, 0x62, 'i', 'd', 0x01 });
    try std.testing.expectEqual(@as(?zerde.cbor.Raw, null), maybe.rest);
    try expectCborBytes(&.{ 0xa1, 0x62, 'i', 'd', 0x01 }, maybe, .{}, .{ .deterministic = true });
    // The default write puts the extras after the declared members.
    const extra = try zerde.cbor.parseSlice(MaybeExtras, allocator, &.{ 0xa2, 0x61, 'a', 0x05, 0x62, 'i', 'd', 0x01 });
    defer zerde.free(allocator, extra);
    try expectCborBytes(&.{ 0xbf, 0x62, 'i', 'd', 0x01, 0x61, 'a', 0x05, 0xff }, extra, .{}, .{});
}

test "extras never hold a declared key, and an extras entry that repeats one is refused on write" {
    // The extras field's own name is an ordinary unknown key.
    const named = try zerde.cbor.parseSlice(MaybeExtras, allocator, &.{ 0xa2, 0x62, 'i', 'd', 0x01, 0x64, 'r', 'e', 's', 't', 0x07 });
    defer zerde.free(allocator, named);
    try std.testing.expectEqualSlices(u8, &.{ 0xa1, 0x64, 'r', 'e', 's', 't', 0x07 }, named.rest.?.bytes);
    // An entry for `id` built by hand cannot be written, in any order.
    const clash = MaybeExtras{ .id = 1, .rest = .{ .bytes = &.{ 0xa1, 0x62, 'i', 'd', 0x02 } } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.DuplicateField, zerde.serializeWith(zerde.cbor, &out.writer, clash, .{}, .{ .deterministic = true }));
    try std.testing.expectError(error.DuplicateField, zerde.serializeWith(zerde.cbor, &out.writer, clash, .{}, .{}));
    // The same key twice in the input is refused on read, extras or not.
    try expectCborError(MaybeExtras, error.DuplicateField, &.{ 0xa3, 0x62, 'i', 'd', 0x01, 0x61, 'a', 0x00, 0x61, 'a', 0x01 });
}

test "extras are checked as the read's mode and limits say" {
    // A key that is not text cannot be an extras key.
    try expectCborError(WithExtras, error.UnexpectedType, &.{ 0xa3, 0x62, 'i', 'd', 0x01, 0x64, 'n', 'a', 'm', 'e', 0x61, 'n', 0x05, 0x00 });
    // Strict refuses a non-deterministic value kept in extras; lenient keeps it as it is.
    const loose = [_]u8{ 0xa3, 0x62, 'i', 'd', 0x01, 0x64, 'n', 'a', 'm', 'e', 0x61, 'n', 0x61, 'x', 0x9f, 0x01, 0xff };
    const kept = try zerde.cbor.parseSlice(WithExtras, allocator, &loose);
    defer zerde.free(allocator, kept);
    try std.testing.expectEqualSlices(u8, &.{ 0xa1, 0x61, 'x', 0x9f, 0x01, 0xff }, kept.rest.bytes);
    try std.testing.expectError(error.NonDeterministicEncoding, zerde.cbor.parseSliceWith(WithExtras, allocator, &loose, .{}, .{ .mode = .strict }));
    // Limits count inside it.
    try std.testing.expectError(error.CborNestingTooDeep, zerde.cbor.parseSliceWith(WithExtras, allocator, &loose, .{}, .{ .max_depth = 1 }));
    try std.testing.expectError(error.TooManyItems, zerde.cbor.parseSliceWith(WithExtras, allocator, &loose, .{}, .{ .max_items = 7 }));
}

test "a struct with extras inside another keeps its own" {
    const Outer = struct {
        inner: WithExtras,
        tag: u8,
        rest: zerde.cbor.Raw,

        pub const serde = .{ .extras = "rest" };
    };
    // Outer extras "p", then the inner struct with its own extras "q", then "tag", then outer extras "o".
    const input = [_]u8{
        0xa4,
        0x61,
        'p',
        0x01,
        0x65,
        'i',
        'n',
        'n',
        'e',
        'r',
        0xa3,
        0x62,
        'i',
        'd',
        0x01,
        0x64,
        'n',
        'a',
        'm',
        'e',
        0x61,
        'n',
        0x61,
        'q',
        0x02,
        0x63,
        't',
        'a',
        'g',
        0x03,
        0x61,
        'o',
        0x04,
    };
    const decoded = try zerde.cbor.parseSlice(Outer, allocator, &input);
    defer zerde.free(allocator, decoded);
    try std.testing.expectEqualSlices(u8, &.{ 0xa1, 0x61, 'q', 0x02 }, decoded.inner.rest.bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0xa2, 0x61, 'o', 0x04, 0x61, 'p', 0x01 }, decoded.rest.bytes);
    try std.testing.expectEqual(@as(u8, 3), decoded.tag);
}

test "JSON extras keep their members in input order, with values as read" {
    const input = "{\"id\":1,\"z\" : [ 1 , 2 ],\"name\":\"n\",\"k\\u00e9\":{ \"x\" : null }}";
    const decoded = try zerde.json.parseSlice(WithExtrasJson, allocator, input);
    defer zerde.free(allocator, decoded);
    try std.testing.expectEqualStrings("{\"z\":[ 1 , 2 ],\"k\xc3\xa9\":{ \"x\" : null }}", decoded.rest.bytes);
    try expectJsonText("{\"id\":1,\"name\":\"n\",\"z\":[ 1 , 2 ],\"k\xc3\xa9\":{ \"x\" : null }}", decoded, .{}, .{});
    // No unknown members: `{}`, or null; both write nothing.
    const none = try zerde.json.parseSlice(WithExtrasJson, allocator, "{\"id\":1,\"name\":\"n\"}");
    defer zerde.free(allocator, none);
    try std.testing.expectEqualStrings("{}", none.rest.bytes);
    try expectJsonText("{\"id\":1,\"name\":\"n\"}", none, .{}, .{});
    const maybe = try zerde.json.parseSlice(MaybeExtrasJson, allocator, "{\"id\":1}");
    try expectJsonText("{\"id\":1}", maybe, .{}, .{});
}

test "a JSON extras member that repeats a declared one is refused, however it is escaped" {
    for ([_][]const u8{ "{\"id\":2}", "{\"\\u0069d\":2}", "{\"x\":1,\"i\\u0064\":2}", "{\"\\u0069\\u0064\":2}" }) |rest| {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const clash = MaybeExtrasJson{ .id = 1, .rest = .{ .bytes = rest } };
        try std.testing.expectError(error.DuplicateField, zerde.serializeWith(zerde.json, &out.writer, clash, .{}, .{}));
    }
    // Close but not equal is fine.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try zerde.serializeWith(zerde.json, &out.writer, MaybeExtrasJson{ .id = 1, .rest = .{ .bytes = "{\"idx\":2,\"i\":3,\"\\u00e9\":4}" } }, .{}, .{});
    try std.testing.expectEqualStrings("{\"id\":1,\"idx\":2,\"i\":3,\"\\u00e9\":4}", out.written());
    // A repeated key in the input is still refused as a duplicate.
    try expectJsonError(MaybeExtrasJson, error.DuplicateField, "{\"id\":1,\"id\":2}");
}

test "JSON extras are checked while they are read" {
    try expectJsonError(WithExtrasJson, error.UnexpectedToken, "{\"id\":1,\"name\":\"n\",\"x\":{\"a\":}}");
    try expectJsonError(WithExtrasJson, error.InvalidUtf8, "{\"id\":1,\"name\":\"n\",\"x\":\"\xff\"}");
    try std.testing.expectError(error.JsonNestingTooDeep, zerde.json.parseSliceWith(WithExtrasJson, allocator, "{\"id\":1,\"name\":\"n\",\"x\":[[1]]}", .{}, .{ .max_depth = 2 }));
}

test "extras keys are written escaped, and a malformed extras item is an error" {
    const decoded = try zerde.json.parseSlice(MaybeExtrasJson, allocator, "{\"id\":1,\"a\\\"b\":1,\"c\\nd\":2}");
    defer zerde.free(allocator, decoded);
    try std.testing.expectEqualStrings("{\"a\\\"b\":1,\"c\\nd\":2}", decoded.rest.?.bytes);
    try expectJsonText("{\"id\":1,\"a\\\"b\":1,\"c\\nd\":2}", decoded, .{}, .{});
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    // A Raw that is not a map cannot be extras.
    try std.testing.expectError(error.UnexpectedType, zerde.serializeWith(zerde.cbor, &out.writer, MaybeExtras{ .id = 1, .rest = .{ .bytes = &.{0x01} } }, .{}, .{}));
    try std.testing.expectError(error.UnexpectedType, zerde.serializeWith(zerde.cbor, &out.writer, MaybeExtras{ .id = 1, .rest = .{ .bytes = &.{ 0xbf, 0xff } } }, .{}, .{}));
    try std.testing.expectError(error.UnexpectedEndOfInput, zerde.serializeWith(zerde.cbor, &out.writer, MaybeExtras{ .id = 1, .rest = .{ .bytes = &.{ 0xa1, 0x61 } } }, .{}, .{}));
    try std.testing.expectError(error.UnexpectedToken, zerde.serializeWith(zerde.json, &out.writer, MaybeExtrasJson{ .id = 1, .rest = .{ .bytes = "[1]" } }, .{}, .{}));
}

test "extras that sort after a declared member are written after it" {
    // "zz" sorts after "id" and before "name"; "name2" after "name".
    const input = [_]u8{ 0xa4, 0x62, 'i', 'd', 0x01, 0x64, 'n', 'a', 'm', 'e', 0x61, 'n', 0x62, 'z', 'z', 0x02, 0x65, 'n', 'a', 'm', 'e', '2', 0x03 };
    const decoded = try zerde.cbor.parseSlice(WithExtras, allocator, &input);
    defer zerde.free(allocator, decoded);
    try expectCborBytes(&.{
        0xa4,
        0x62,
        'i',
        'd',
        0x01,
        0x62,
        'z',
        'z',
        0x02,
        0x64,
        'n',
        'a',
        'm',
        'e',
        0x61,
        'n',
        0x65,
        'n',
        'a',
        'm',
        'e',
        '2',
        0x03,
    }, decoded, .{}, .{ .deterministic = true });
}

// ---- pull reader ----------------------------------------------------------------------------------------------

/// The events of one item as text: `[` `]` `{` `}` for containers, `i5` integers, `f1.5` floats,
/// `"x"` text, `b:0102` bytes, and `[3` or `{2` when the format states a count.
fn describeEvents(reader: anytype) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (try reader.next()) |event| {
        switch (event) {
            .null => try out.appendSlice(allocator, "null "),
            .bool => |b| try out.appendSlice(allocator, if (b) "true " else "false "),
            .integer => |n| try out.print(allocator, "i{d} ", .{n}),
            .float => |f| try out.print(allocator, "f{d} ", .{f}),
            .text => |t| try out.print(allocator, "\"{s}\" ", .{t}),
            .bytes => |b| try out.print(allocator, "b:{x} ", .{b}),
            .array_begin => |n| if (n) |count| try out.print(allocator, "[{d} ", .{count}) else try out.appendSlice(allocator, "[ "),
            .array_end => try out.appendSlice(allocator, "] "),
            .map_begin => |n| if (n) |count| try out.print(allocator, "{{{d} ", .{count}) else try out.appendSlice(allocator, "{ "),
            .map_end => try out.appendSlice(allocator, "} "),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn expectCborEvents(expected: []const u8, input: []const u8, comptime cfg: anytype) !void {
    var reader = try zerde.cbor.pullReader(allocator, input, cfg);
    defer reader.deinit();
    const text = try describeEvents(&reader);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
    try reader.finish();
}

fn expectJsonEvents(expected: []const u8, input: []const u8, comptime cfg: anytype) !void {
    var reader = try zerde.json.pullReader(allocator, input, cfg);
    defer reader.deinit();
    const text = try describeEvents(&reader);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
    try reader.finish();
}

test "a CBOR pull reader returns every kind of item in order" {
    // {1: "a", "k": [true, null, 1.5, h'01'], -3: {}} with counts stated.
    try expectCborEvents("{3 i1 \"a\" \"k\" [4 true null f1.5 b:01 ] i-3 {0 } } ", &.{ 0xa3, 0x01, 0x61, 'a', 0x61, 'k', 0x84, 0xf5, 0xf6, 0xf9, 0x3e, 0x00, 0x41, 0x01, 0x22, 0xa0 }, .{});
    // Indefinite containers and chunked strings: no counts, the chunks joined.
    try expectCborEvents("{ \"ab\" [ i1 i2 ] } ", &.{ 0xbf, 0x7f, 0x61, 'a', 0x61, 'b', 0xff, 0x9f, 0x01, 0x02, 0xff, 0xff }, .{});
    // Scalars at the top, a tag 55799 prefix, and an empty array.
    try expectCborEvents("i7 ", &.{0x07}, .{});
    try expectCborEvents("[0 ] ", &.{ 0xd9, 0xd9, 0xf7, 0x80 }, .{});
    try expectCborEvents("f-0 ", &.{ 0xf9, 0x80, 0x00 }, .{});
    try expectCborEvents("i18446744073709551615 ", &.{ 0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .{});
    try expectCborEvents("i-18446744073709551616 ", &.{ 0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, .{});
}

test "a CBOR pull reader checks what a typed read does" {
    // A repeated key is found when its map ends, a strict read refuses unsorted keys at once.
    var dup = try zerde.cbor.pullReader(allocator, &.{ 0xa2, 0x01, 0x00, 0x01, 0x01 }, .{});
    defer dup.deinit();
    var count: usize = 0;
    const result = while (dup.next()) |event| : (count += 1) {
        if (event == null) break error.Ended;
    } else |err| err;
    try std.testing.expectEqual(@as(anyerror, error.DuplicateField), result);
    try std.testing.expectEqual(@as(usize, 5), count);

    var unsorted = try zerde.cbor.pullReader(allocator, &.{ 0xa2, 0x02, 0x00, 0x01, 0x00 }, strict);
    defer unsorted.deinit();
    _ = try unsorted.next(); // {
    _ = try unsorted.next(); // 2
    _ = try unsorted.next(); // 0
    try std.testing.expectError(error.NonDeterministicEncoding, unsorted.next());

    // Invalid UTF-8, indefinite lengths under strict, tags, limits.
    var bad = try zerde.cbor.pullReader(allocator, &.{ 0x62, 0xc3, 0x28 }, .{});
    defer bad.deinit();
    try std.testing.expectError(error.InvalidUtf8, bad.next());
    var indef = try zerde.cbor.pullReader(allocator, &.{ 0x9f, 0xff }, strict);
    defer indef.deinit();
    try std.testing.expectError(error.NonDeterministicEncoding, indef.next());
    var tagged = try zerde.cbor.pullReader(allocator, &.{ 0xc1, 0x00 }, .{});
    defer tagged.deinit();
    try std.testing.expectError(error.UnexpectedTag, tagged.next());
    var deep = try zerde.cbor.pullReader(allocator, &.{ 0x81, 0x81, 0x00 }, .{ .max_depth = 1 });
    defer deep.deinit();
    _ = try deep.next();
    try std.testing.expectError(error.CborNestingTooDeep, deep.next());
    var many = try zerde.cbor.pullReader(allocator, &.{ 0x82, 0x01, 0x02 }, .{ .max_items = 2 });
    defer many.deinit();
    _ = try many.next();
    _ = try many.next();
    try std.testing.expectError(error.TooManyItems, many.next());
    // A map key that is an array cannot be an event.
    var composite = try zerde.cbor.pullReader(allocator, &.{ 0xa1, 0x81, 0x01, 0x00 }, .{});
    defer composite.deinit();
    _ = try composite.next();
    try std.testing.expectError(error.UnexpectedType, composite.next());
    // Trailing bytes, and an unfinished item.
    var trailing = try zerde.cbor.pullReader(allocator, &.{ 0x01, 0x02 }, .{});
    defer trailing.deinit();
    _ = try trailing.next();
    try std.testing.expectEqual(@as(?zerde.Event, null), try trailing.next());
    try std.testing.expectError(error.TrailingCharacters, trailing.finish());
    var partial = try zerde.cbor.pullReader(allocator, &.{ 0x82, 0x01, 0x02 }, .{});
    defer partial.deinit();
    _ = try partial.next();
    try std.testing.expectError(error.UnexpectedEndOfInput, partial.finish());
}

test "skip consumes the next value whole, at any depth" {
    // {"a": [1, [2, 3]], "b": 4, "c": {"d": 5}}: skip "a"'s value, then read "b".
    const input = [_]u8{ 0xa3, 0x61, 'a', 0x82, 0x01, 0x82, 0x02, 0x03, 0x61, 'b', 0x04, 0x61, 'c', 0xa1, 0x61, 'd', 0x05 };
    var reader = try zerde.cbor.pullReader(allocator, &input, .{});
    defer reader.deinit();
    _ = try reader.next(); // {
    try std.testing.expectEqualStrings("a", (try reader.next()).?.text);
    try reader.skip();
    try std.testing.expectEqualStrings("b", (try reader.next()).?.text);
    try std.testing.expectEqual(@as(i128, 4), (try reader.next()).?.integer);
    try std.testing.expectEqualStrings("c", (try reader.next()).?.text);
    try reader.skip();
    try std.testing.expectEqual(zerde.Event.map_end, (try reader.next()).?);
    try std.testing.expectEqual(@as(?zerde.Event, null), try reader.next());
    try reader.finish();

    // Skipping at the top level takes the whole item, and skip checks it too.
    var whole = try zerde.cbor.pullReader(allocator, &.{ 0x82, 0x01, 0x62, 0xc3, 0x28 }, .{});
    defer whole.deinit();
    try std.testing.expectError(error.InvalidUtf8, whole.skip());
}

test "a JSON pull reader returns every kind of value in order" {
    try expectJsonEvents("{ \"a\" [ i1 f2.5 \"x\" ] \"b\" { \"c\" null } \"d\" true } ", "{\"a\":[1, 2.5,\"x\"] ,\"b\":{\"c\":null},\"d\":true}", .{});
    try expectJsonEvents("{ \"k\u{e9}\" i-7 } ", " { \"k\\u00e9\" : -7 } ", .{});
    try expectJsonEvents("[ ] ", "[]", .{});
    try expectJsonEvents("\"a\nb\" ", "\"a\\nb\"", .{});
    try expectJsonEvents("f100 ", "1e2", .{});
    try expectJsonEvents("{ } ", "{}", .{});
}

test "a JSON pull reader checks syntax, UTF-8, limits and trailing text" {
    var syntax = try zerde.json.pullReader(allocator, "{\"a\":}", .{});
    defer syntax.deinit();
    _ = try syntax.next();
    _ = try syntax.next();
    try std.testing.expectError(error.UnexpectedToken, syntax.next());
    var bad = try zerde.json.pullReader(allocator, "\"\xff\"", .{});
    defer bad.deinit();
    try std.testing.expectError(error.InvalidUtf8, bad.next());
    var deep = try zerde.json.pullReader(allocator, "[[1]]", .{ .max_depth = 1 });
    defer deep.deinit();
    _ = try deep.next();
    try std.testing.expectError(error.JsonNestingTooDeep, deep.next());
    var trailing = try zerde.json.pullReader(allocator, "1 2", .{});
    defer trailing.deinit();
    _ = try trailing.next();
    try std.testing.expectError(error.TrailingCharacters, trailing.finish());
    var partial = try zerde.json.pullReader(allocator, "[1", .{});
    defer partial.deinit();
    _ = try partial.next();
    _ = try partial.next();
    try std.testing.expectError(error.UnexpectedEndOfInput, partial.next());

    var reader = try zerde.json.pullReader(allocator, "{\"a\":[1,{\"b\":2}],\"c\":3}", .{});
    defer reader.deinit();
    _ = try reader.next();
    _ = try reader.next();
    try reader.skip();
    try std.testing.expectEqualStrings("c", (try reader.next()).?.text);
    try std.testing.expectEqual(@as(i128, 3), (try reader.next()).?.integer);
    try std.testing.expectEqual(zerde.Event.map_end, (try reader.next()).?);
    try reader.finish();
}

test "a pull reader counts each item once against max_items" {
    // A map, a key and its value are three items; an array key is refused, so keys are scalars.
    var reader = try zerde.cbor.pullReader(allocator, &.{ 0xa1, 0x01, 0x00 }, .{ .max_items = 3 });
    defer reader.deinit();
    while (try reader.next()) |_| {}
    var tight = try zerde.cbor.pullReader(allocator, &.{ 0xa1, 0x01, 0x00 }, .{ .max_items = 2 });
    defer tight.deinit();
    _ = try tight.next();
    _ = try tight.next();
    try std.testing.expectError(error.TooManyItems, tight.next());
    var json = try zerde.json.pullReader(allocator, "{\"a\":[1]}", .{ .max_items = 4 });
    defer json.deinit();
    while (try json.next()) |_| {}
    var json_tight = try zerde.json.pullReader(allocator, "{\"a\":[1]}", .{ .max_items = 3 });
    defer json_tight.deinit();
    _ = try json_tight.next();
    _ = try json_tight.next();
    _ = try json_tight.next();
    try std.testing.expectError(error.TooManyItems, json_tight.next());
}

test "a pull reader releases each joined string before the next, and finish needs a complete item" {
    // Two chunked strings, one after the other: both are freed (the testing allocator checks).
    try expectCborEvents("[ \"ab\" \"cd\" ] ", &.{ 0x9f, 0x7f, 0x61, 'a', 0x61, 'b', 0xff, 0x7f, 0x61, 'c', 0x61, 'd', 0xff, 0xff }, .{});
    try expectJsonEvents("[ \"a\nb\" \"c\nd\" ] ", "[\"a\\nb\",\"c\\nd\"]", .{});
    var json = try zerde.json.pullReader(allocator, "[1", .{});
    defer json.deinit();
    _ = try json.next();
    _ = try json.next();
    try std.testing.expectError(error.UnexpectedEndOfInput, json.finish());
}

// ---- value writer -----------------------------------------------------------------------------------------------

fn valueBytes(comptime Format: type, comptime cfg: anytype, build: *const fn (w: *Format.ValueWriter) anyerror!void) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var w = Format.valueWriter(allocator, &out.writer, cfg);
    defer w.deinit();
    try build(&w);
    try w.finish();
    return out.toOwnedSlice();
}

fn buildMixed(comptime Format: type) *const fn (w: *Format.ValueWriter) anyerror!void {
    return struct {
        fn run(w: *Format.ValueWriter) anyerror!void {
            try w.beginMap();
            try w.writeText("b");
            try w.beginArray();
            try w.writeInt(1);
            try w.writeFloat(2.5);
            try w.writeText("x");
            try w.endArray();
            try w.writeText("a");
            try w.writeNull();
            try w.writeText("cc");
            try w.beginMap();
            try w.writeText("z");
            try w.writeBool(true);
            try w.writeText("y");
            try w.writeBool(false);
            try w.endMap();
            try w.endMap();
        }
    }.run;
}

test "a CBOR value writer sorts maps on close and writes shortest floats" {
    const bytes = try valueBytes(zerde.cbor, .{ .deterministic = true }, buildMixed(zerde.cbor));
    defer allocator.free(bytes);
    // {"a": null, "b": [1, 2.5, "x"], "cc": {"y": false, "z": true}}: keys by encoded bytes, 2.5 as a half.
    try std.testing.expectEqualSlices(u8, &.{
        0xa3,
        0x61,
        'a',
        0xf6,
        0x61,
        'b',
        0x83,
        0x01,
        0xf9,
        0x41,
        0x00,
        0x61,
        'x',
        0x62,
        'c',
        'c',
        0xa2,
        0x61,
        'y',
        0xf4,
        0x61,
        'z',
        0xf5,
    }, bytes);
    // Without `deterministic` the entries keep their order, lengths are still definite, floats are doubles.
    const plain = try valueBytes(zerde.cbor, .{}, buildMixed(zerde.cbor));
    defer allocator.free(plain);
    try std.testing.expectEqualSlices(u8, &.{
        0xa3,
        0x61,
        'b',
        0x83,
        0x01,
        0xfb,
        0x40,
        0x04,
        0,
        0,
        0,
        0,
        0,
        0,
        0x61,
        'x',
        0x61,
        'a',
        0xf6,
        0x62,
        'c',
        'c',
        0xa2,
        0x61,
        'z',
        0xf5,
        0x61,
        'y',
        0xf4,
    }, plain);
}

test "a CBOR value writer's keys can be any item, ordered as RFC 8949 4.2.1 says" {
    const Build = struct {
        fn run(w: *zerde.cbor.ValueWriter) anyerror!void {
            try w.beginMap();
            try w.writeText("a");
            try w.writeInt(1);
            try w.writeInt(-1);
            try w.writeInt(2);
            try w.writeInt(256);
            try w.writeInt(3);
            try w.writeBytes("x");
            try w.writeInt(4);
            try w.writeInt(24);
            try w.writeInt(5);
            try w.endMap();
        }
    };
    const bytes = try valueBytes(zerde.cbor, .{ .deterministic = true }, Build.run);
    defer allocator.free(bytes);
    // 24 (0x1818), 256 (0x190100), -1 (0x20), h'78' (0x4178), "a" (0x6161): by their encoded bytes.
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0x18, 0x18, 0x05, 0x19, 0x01, 0x00, 0x03, 0x20, 0x02, 0x41, 'x', 0x04, 0x61, 'a', 0x01 }, bytes);
}

test "a value writer refuses a repeated key, an unbalanced container and a missing value" {
    const Dup = struct {
        fn run(w: *zerde.cbor.ValueWriter) anyerror!void {
            try w.beginMap();
            try w.writeInt(1);
            try w.writeNull();
            try w.writeInt(1);
            try w.writeNull();
            try w.endMap();
        }
    };
    try std.testing.expectError(error.DuplicateField, valueBytes(zerde.cbor, .{ .deterministic = true }, Dup.run));
    const Unclosed = struct {
        fn run(w: *zerde.cbor.ValueWriter) anyerror!void {
            try w.beginArray();
        }
    };
    try std.testing.expectError(error.UnbalancedContainers, valueBytes(zerde.cbor, .{}, Unclosed.run));
    const Mismatch = struct {
        fn run(w: *zerde.cbor.ValueWriter) anyerror!void {
            try w.beginArray();
            try w.endMap();
        }
    };
    try std.testing.expectError(error.UnbalancedContainers, valueBytes(zerde.cbor, .{}, Mismatch.run));
    const Dangling = struct {
        fn run(w: *zerde.cbor.ValueWriter) anyerror!void {
            try w.beginMap();
            try w.writeText("k");
            try w.endMap();
        }
    };
    try std.testing.expectError(error.UnbalancedContainers, valueBytes(zerde.cbor, .{}, Dangling.run));
    const Stray = struct {
        fn run(w: *zerde.cbor.ValueWriter) anyerror!void {
            try w.endArray();
        }
    };
    try std.testing.expectError(error.UnbalancedContainers, valueBytes(zerde.cbor, .{}, Stray.run));
}

test "a JSON value writer sorts keys like deterministic CBOR, and writes arrays as they come" {
    const sorted = try valueBytes(zerde.json, .{}, buildMixed(zerde.json));
    defer allocator.free(sorted);
    try std.testing.expectEqualStrings("{\"a\":null,\"b\":[1,2.5,\"x\"],\"cc\":{\"y\":false,\"z\":true}}", sorted);
    const kept = try valueBytes(zerde.json, .{ .sort_keys = false }, buildMixed(zerde.json));
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("{\"b\":[1,2.5,\"x\"],\"a\":null,\"cc\":{\"z\":true,\"y\":false}}", kept);
    // Keys escape, an array of maps nests, bytes follow the config.
    const Build = struct {
        fn run(w: *zerde.json.ValueWriter) anyerror!void {
            try w.beginArray();
            try w.beginMap();
            try w.writeText("k\"q");
            try w.writeBytes("\xff\x00");
            try w.endMap();
            try w.beginMap();
            try w.endMap();
            try w.writeRaw("{ \"raw\" : 1 }");
            try w.endArray();
        }
    };
    const nested = try valueBytes(zerde.json, .{ .bytes = .base64 }, Build.run);
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("[{\"k\\\"q\":\"/wA=\"},{},{ \"raw\" : 1 }]", nested);
}

test "a JSON value writer refuses what JSON cannot say" {
    const Dup = struct {
        fn run(w: *zerde.json.ValueWriter) anyerror!void {
            try w.beginMap();
            try w.writeText("a");
            try w.writeNull();
            try w.writeText("a");
            try w.writeNull();
            try w.endMap();
        }
    };
    try std.testing.expectError(error.DuplicateField, valueBytes(zerde.json, .{}, Dup.run));
    const NumberKey = struct {
        fn run(w: *zerde.json.ValueWriter) anyerror!void {
            try w.beginMap();
            try w.writeInt(1);
        }
    };
    try std.testing.expectError(error.UnexpectedType, valueBytes(zerde.json, .{}, NumberKey.run));
    const Nan = struct {
        fn run(w: *zerde.json.ValueWriter) anyerror!void {
            try w.writeFloat(std.math.nan(f64));
        }
    };
    try std.testing.expectError(error.NonFiniteFloat, valueBytes(zerde.json, .{}, Nan.run));
    const Bad = struct {
        fn run(w: *zerde.json.ValueWriter) anyerror!void {
            try w.writeBytes("\xff");
        }
    };
    try std.testing.expectError(error.InvalidUtf8, valueBytes(zerde.json, .{}, Bad.run));
    const Unclosed = struct {
        fn run(w: *zerde.json.ValueWriter) anyerror!void {
            try w.beginMap();
        }
    };
    try std.testing.expectError(error.UnbalancedContainers, valueBytes(zerde.json, .{}, Unclosed.run));
}

test "a reader copied into a writer canonicalizes, and moves between formats" {
    // A lenient CBOR input in a scrambled spelling becomes the deterministic bytes a strict read accepts.
    const loose = [_]u8{ 0xbf, 0x61, 'b', 0x9f, 0x18, 0x01, 0xfb, 0x40, 0x04, 0, 0, 0, 0, 0, 0, 0xff, 0x61, 'a', 0x7f, 0x61, 'x', 0xff, 0xff };
    var reader = try zerde.cbor.pullReader(allocator, &loose, .{});
    defer reader.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var writer = zerde.cbor.valueWriter(allocator, &out.writer, .{ .deterministic = true });
    defer writer.deinit();
    while (try reader.next()) |event| try writer.writeEvent(event);
    try writer.finish();
    try std.testing.expectEqualSlices(u8, &.{ 0xa2, 0x61, 'a', 0x61, 'x', 0x61, 'b', 0x82, 0x01, 0xf9, 0x41, 0x00 }, out.written());
    var strict_reader = try zerde.cbor.pullReader(allocator, out.written(), strict);
    defer strict_reader.deinit();
    while (try strict_reader.next()) |_| {}
    try strict_reader.finish();

    // The same item as JSON, and back: map order is the key order of the deterministic form.
    var again = try zerde.cbor.pullReader(allocator, out.written(), .{});
    defer again.deinit();
    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();
    var json_writer = zerde.json.valueWriter(allocator, &json_out.writer, .{});
    defer json_writer.deinit();
    while (try again.next()) |event| try json_writer.writeEvent(event);
    try json_writer.finish();
    try std.testing.expectEqualStrings("{\"a\":\"x\",\"b\":[1,2.5]}", json_out.written());
    var back = try zerde.json.pullReader(allocator, json_out.written(), .{});
    defer back.deinit();
    var cbor_out: std.Io.Writer.Allocating = .init(allocator);
    defer cbor_out.deinit();
    var cbor_writer = zerde.cbor.valueWriter(allocator, &cbor_out.writer, .{ .deterministic = true });
    defer cbor_writer.deinit();
    while (try back.next()) |event| try cbor_writer.writeEvent(event);
    try std.testing.expectEqualSlices(u8, out.written(), cbor_out.written());
}

test "a value writer's nesting is bounded" {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var cbor = zerde.cbor.valueWriter(allocator, &out.writer, .{});
    defer cbor.deinit();
    for (0..128) |_| try cbor.beginArray();
    try std.testing.expectError(error.CborNestingTooDeep, cbor.beginArray());
    var json = zerde.json.valueWriter(allocator, &out.writer, .{});
    defer json.deinit();
    for (0..128) |_| try json.beginArray();
    try std.testing.expectError(error.JsonNestingTooDeep, json.beginArray());
}

test "a JSON value writer puts shorter keys first, as deterministic CBOR does" {
    const Build = struct {
        fn run(w: *zerde.json.ValueWriter) anyerror!void {
            try w.beginMap();
            try w.writeText("aa");
            try w.writeInt(1);
            try w.writeText("b");
            try w.writeInt(2);
            try w.endMap();
        }
    };
    const bytes = try valueBytes(zerde.json, .{}, Build.run);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"b\":2,\"aa\":1}", bytes);
}

// ---- wire types with hooks --------------------------------------------------------------------------------------

/// An optional that is an empty or one-element array on the wire: `[]` or `[v]`.
fn Opt(comptime T: type) type {
    return struct {
        value: ?T = null,

        const Self = @This();

        pub fn zerdeDecode(gpa: std.mem.Allocator, reader: anytype) anyerror!Self {
            _ = gpa;
            const begin = (try reader.next()) orelse return error.UnexpectedEndOfInput;
            if (begin != .array_begin) return error.UnexpectedType;
            const first = (try reader.next()) orelse return error.UnexpectedEndOfInput;
            switch (first) {
                .array_end => return .{ .value = null },
                .integer => |n| {
                    const end = (try reader.next()) orelse return error.UnexpectedEndOfInput;
                    if (end != .array_end) return error.LengthMismatch;
                    return .{ .value = std.math.cast(T, n) orelse return error.IntegerOverflow };
                },
                else => return error.UnexpectedType,
            }
        }

        pub fn zerdeEncode(self: Self, encoder: anytype) anyerror!void {
            try encoder.beginArray(if (self.value == null) 0 else 1);
            if (self.value) |v| try encoder.writeInt(v);
            try encoder.endArray();
        }
    };
}

/// A fixed-size id carried as one integer.
const Id = struct {
    n: u32,

    pub fn zerdeDecode(gpa: std.mem.Allocator, reader: anytype) anyerror!Id {
        _ = gpa;
        const event = (try reader.next()) orelse return error.UnexpectedEndOfInput;
        return switch (event) {
            .integer => |n| .{ .n = std.math.cast(u32, n) orelse return error.IntegerOverflow },
            else => error.UnexpectedType,
        };
    }

    pub fn zerdeEncode(self: Id, encoder: anytype) anyerror!void {
        try encoder.writeInt(self.n);
    }
};

/// A union written as `[tag, payload]` with an integer tag, the shape a fixed-layout union has on the wire.
const Cmd = union(enum) {
    ping,
    get: u32,
    both: struct { a: u32, b: u32 },

    pub fn zerdeDecode(gpa: std.mem.Allocator, reader: anytype) anyerror!Cmd {
        _ = gpa;
        if (((try reader.next()) orelse return error.UnexpectedEndOfInput) != .array_begin) return error.UnexpectedType;
        const tag = switch ((try reader.next()) orelse return error.UnexpectedEndOfInput) {
            .integer => |n| n,
            else => return error.UnexpectedType,
        };
        const result: Cmd = switch (tag) {
            0 => .ping,
            1 => .{ .get = try integer(reader) },
            2 => .{ .both = .{ .a = try integer(reader), .b = try integer(reader) } },
            else => return error.InvalidEnumTag,
        };
        if (((try reader.next()) orelse return error.UnexpectedEndOfInput) != .array_end) return error.LengthMismatch;
        return result;
    }

    fn integer(reader: anytype) anyerror!u32 {
        return switch ((try reader.next()) orelse return error.UnexpectedEndOfInput) {
            .integer => |n| std.math.cast(u32, n) orelse error.IntegerOverflow,
            else => error.UnexpectedType,
        };
    }

    pub fn zerdeEncode(self: Cmd, encoder: anytype) anyerror!void {
        switch (self) {
            .ping => {
                try encoder.beginArray(1);
                try encoder.writeInt(0);
            },
            .get => |n| {
                try encoder.beginArray(2);
                try encoder.writeInt(1);
                try encoder.writeInt(n);
            },
            .both => |p| {
                try encoder.beginArray(3);
                try encoder.writeInt(2);
                try encoder.writeInt(p.a);
                try encoder.writeInt(p.b);
            },
        }
        try encoder.endArray();
    }
};

const Wired = struct {
    id: Id,
    maybe: Opt(u8),
    cmds: []const Cmd,
    note: ?Id = null,
};

test "a wire type with hooks reads and writes in CBOR and JSON" {
    const cmds = [_]Cmd{ .ping, .{ .get = 7 }, .{ .both = .{ .a = 1, .b = 2 } } };
    const value = Wired{ .id = .{ .n = 9 }, .maybe = .{ .value = 5 }, .cmds = &cmds, .note = .{ .n = 3 } };
    // Deterministic key order: id, cmds, note, maybe.
    const expected = [_]u8{ 0xa4, 0x62, 'i', 'd', 0x09, 0x64, 'c', 'm', 'd', 's', 0x83, 0x81, 0x00, 0x82, 0x01, 0x07, 0x83, 0x02, 0x01, 0x02, 0x64, 'n', 'o', 't', 'e', 0x03, 0x65, 'm', 'a', 'y', 'b', 'e', 0x81, 0x05 };
    try expectCborBytes(&expected, value, .{}, .{ .deterministic = true });
    try expectJsonText("{\"id\":9,\"maybe\":[5],\"cmds\":[[0],[1,7],[2,1,2]],\"note\":3}", value, .{}, .{});

    const cbor = try writeCbor(value, .{}, .{});
    var bytes = cbor;
    defer bytes.deinit();
    const from_cbor = try zerde.cbor.parseSlice(Wired, allocator, bytes.written());
    defer zerde.free(allocator, from_cbor);
    try std.testing.expectEqualDeep(value, from_cbor);
    const from_json = try zerde.json.parseSlice(Wired, allocator, "{ \"id\" : 9, \"maybe\" : [ 5 ], \"cmds\" : [[0],[1,7],[2,1,2]], \"note\":3 }");
    defer zerde.free(allocator, from_json);
    try std.testing.expectEqualDeep(value, from_json);

    // An empty optional and an omitted field.
    const empty = try zerde.json.parseSlice(Wired, allocator, "{\"id\":1,\"maybe\":[],\"cmds\":[]}");
    defer zerde.free(allocator, empty);
    try std.testing.expectEqual(@as(?u8, null), empty.maybe.value);
    try std.testing.expectEqual(@as(?Id, null), empty.note);
}

test "a decode hook's errors, and what it leaves unread, are errors" {
    try expectJsonError(Wired, error.IntegerOverflow, "{\"id\":4294967296,\"maybe\":[],\"cmds\":[]}");
    try expectJsonError(Wired, error.UnexpectedType, "{\"id\":\"x\",\"maybe\":[],\"cmds\":[]}");
    try expectJsonError(Wired, error.LengthMismatch, "{\"id\":1,\"maybe\":[1,2],\"cmds\":[]}");
    try expectJsonError(Wired, error.InvalidEnumTag, "{\"id\":1,\"maybe\":[],\"cmds\":[[9]]}");
    // A hook that stops short of the end of its item.
    const Short = struct {
        pub fn zerdeDecode(gpa: std.mem.Allocator, reader: anytype) anyerror!@This() {
            _ = gpa;
            _ = try reader.next(); // the start of an array, and nothing more
            return .{};
        }
    };
    const Holder = struct { s: Short };
    try expectJsonError(Holder, error.HookIncomplete, "{\"s\":[1,2]}");
    const None = struct {
        pub fn zerdeDecode(gpa: std.mem.Allocator, reader: anytype) anyerror!@This() {
            _ = gpa;
            _ = reader;
            return .{};
        }
    };
    try expectJsonError(struct { s: None }, error.HookIncomplete, "{\"s\":1}");
    // A hook that skips what it does not want reads past it whole.
    const Skip = struct {
        pub fn zerdeDecode(gpa: std.mem.Allocator, reader: anytype) anyerror!@This() {
            _ = gpa;
            try reader.skip();
            return .{};
        }
    };
    const parsed = try zerde.json.parseSlice(struct { s: Skip, after: u8 }, allocator, "{\"s\":{\"a\":[1,{\"b\":2}]},\"after\":7}");
    try std.testing.expectEqual(@as(u8, 7), parsed.after);
}

test "a decode hook reads under the read's mode and limits" {
    const Doc = struct { id: Id, maybe: Opt(u8), cmds: []const Cmd };
    // Strict CBOR refuses an indefinite array inside a hook, as it does anywhere.
    try std.testing.expectError(error.NonDeterministicEncoding, zerde.cbor.parseSliceWith(Doc, allocator, &.{ 0xa3, 0x62, 'i', 'd', 0x01, 0x65, 'm', 'a', 'y', 'b', 'e', 0x9f, 0xff, 0x64, 'c', 'm', 'd', 's', 0x80 }, .{}, strict));
    // A depth limit counts the container the hook opens.
    try std.testing.expectError(error.CborNestingTooDeep, zerde.cbor.parseSliceWith(Doc, allocator, &.{ 0xa3, 0x62, 'i', 'd', 0x01, 0x65, 'm', 'a', 'y', 'b', 'e', 0x80, 0x64, 'c', 'm', 'd', 's', 0x80 }, .{}, .{ .max_depth = 1 }));
}

/// A wire type that owns memory, with a hook to release it.
const NameList = struct {
    items: []const []const u8,

    pub fn zerdeDecode(gpa: std.mem.Allocator, reader: anytype) anyerror!NameList {
        const begin = (try reader.next()) orelse return error.UnexpectedEndOfInput;
        if (begin != .array_begin) return error.UnexpectedType;
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |item| gpa.free(item);
            list.deinit(gpa);
        }
        while (try reader.next()) |event| {
            switch (event) {
                .array_end => return .{ .items = try list.toOwnedSlice(gpa) },
                .text => |t| try list.append(gpa, try gpa.dupe(u8, t)),
                else => return error.UnexpectedType,
            }
        }
        return error.UnexpectedEndOfInput;
    }

    pub fn zerdeEncode(self: NameList, encoder: anytype) anyerror!void {
        try encoder.beginArray(self.items.len);
        for (self.items) |item| try encoder.writeText(item);
        try encoder.endArray();
    }

    pub fn zerdeFree(self: NameList, gpa: std.mem.Allocator) void {
        for (self.items) |item| gpa.free(item);
        gpa.free(self.items);
    }
};

test "a wire type that owns memory is released by its zerdeFree, also after a failure" {
    const parsed = try zerde.json.parseSlice(struct { names: NameList, n: u8 }, allocator, "{\"names\":[\"a\",\"bc\"],\"n\":1}");
    defer zerde.free(allocator, parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.names.items.len);
    try std.testing.expectEqualStrings("bc", parsed.names.items[1]);
    // A later field fails: what the hook allocated is freed (the testing allocator checks).
    try expectJsonError(struct { names: NameList, n: u8 }, error.InvalidNumber, "{\"names\":[\"a\"],\"n\":\"x\"}");
    // And a hook that fails halfway frees its own partial list.
    try expectJsonError(struct { names: NameList }, error.UnexpectedType, "{\"names\":[\"a\",\"b\",1]}");
    try expectJsonText("{\"names\":[\"a\",\"bc\"],\"n\":1}", parsed, .{}, .{});
}

test "an encode hook for a map writes its entries in the order it chooses" {
    const Dict = struct {
        keys: []const []const u8,

        pub fn zerdeEncode(self: @This(), encoder: anytype) anyerror!void {
            try encoder.beginMap(self.keys.len);
            for (self.keys, 0..) |key, index| {
                try encoder.writeText(key);
                try encoder.writeInt(@intCast(index));
            }
            try encoder.endMap();
        }
    };
    // Deterministic CBOR needs the keys in the order of their encoded bytes: a, c, bb.
    const dict = Dict{ .keys = &.{ "a", "c", "bb" } };
    try expectCborBytes(&.{ 0xa3, 0x61, 'a', 0x00, 0x61, 'c', 0x01, 0x62, 'b', 'b', 0x02 }, dict, .{}, .{ .deterministic = true });
    try expectJsonText("{\"a\":0,\"c\":1,\"bb\":2}", dict, .{}, .{});
    // Without it the hook's order stands.
    const unsorted = Dict{ .keys = &.{ "a", "bb", "c" } };
    try expectCborBytes(&.{ 0xa3, 0x61, 'a', 0x00, 0x62, 'b', 'b', 0x01, 0x61, 'c', 0x02 }, unsorted, .{}, .{});
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    try std.testing.expectError(error.NonDeterministicEncoding, zerde.serializeWith(zerde.cbor, &sink.writer, unsorted, .{}, .{ .deterministic = true }));
    try std.testing.expectError(error.DuplicateField, zerde.serializeWith(zerde.cbor, &sink.writer, Dict{ .keys = &.{ "a", "a" } }, .{}, .{ .deterministic = true }));
    // A JSON hook must write a key where a key is due, and close what it opens.
    const Bad = struct {
        pub fn zerdeEncode(self: @This(), encoder: anytype) anyerror!void {
            _ = self;
            try encoder.beginMap(1);
            try encoder.writeInt(1);
        }
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.UnexpectedType, zerde.serializeWith(zerde.json, &out.writer, Bad{}, .{}, .{}));
}

test "a hook that ends on a decoded string leaves nothing allocated" {
    const Label = struct {
        len: usize,

        pub fn zerdeDecode(gpa: std.mem.Allocator, reader: anytype) anyerror!@This() {
            _ = gpa;
            return switch ((try reader.next()) orelse return error.UnexpectedEndOfInput) {
                .text => |t| .{ .len = t.len },
                else => error.UnexpectedType,
            };
        }
    };
    // The escape makes the reader own the joined text until the hook is done with it.
    const parsed = try zerde.json.parseSlice(struct { label: Label }, allocator, "{\"label\":\"a\\nb\"}");
    try std.testing.expectEqual(@as(usize, 3), parsed.label.len);
}

// ---- reflection ---------------------------------------------------------------------------------------------

fn check(comptime ok: bool, comptime line: u32) void {
    if (!ok) @compileError(std.fmt.comptimePrint("reflection expectation failed at line {d}", .{line}));
}

const Described = struct {
    key: zerde.ByteString,
    commit_time: [8]u8,
    record_type: []const u8,
    level: u8,
    state: Level,
    tags: []const u16,
    nick: ?[]const u8 = null,
    patch: ??u8 = null,
    meta: zerde.cbor.Raw,
    wired: Id,
    rest: ?zerde.cbor.Raw = null,

    pub const serde = .{
        .extras = "rest",
        .rename_all = .camelCase,
        .fields = .{
            .key = .{ .key = 0, .max_len = 1024 },
            .commit_time = .{ .key = 1 },
            .record_type = .{ .key = 2, .min_len = 1, .max_len = 63 },
            .level = .{ .key = 3, .min = 1, .max = 9 },
            .state = .{ .key = 4 },
            .tags = .{ .rename = "labels", .max_len = 8 },
            .nick = .{ .optional = .absent },
        },
    };
};

test "reflect lists the fields of a struct as the typed layer sees them" {
    const info = comptime zerde.reflect.fields(Described, .{});
    comptime {
        check(info.len == 11, @src().line);
        check(std.mem.eql(u8, info[0].name, "key") and info[0].wire.integer == 0 and info[0].kind == .byte_string, @src().line);
        check(info[0].bounds.max_len == 1024 and info[0].bounds.min_len == 0, @src().line);
        check(info[1].kind == .byte_array and info[1].wire.integer == 1, @src().line);
        check(info[2].kind == .text and info[2].bounds.min_len == 1 and info[2].bounds.max_len == 63, @src().line);
        check(info[3].kind == .int and info[3].type == u8 and info[3].bounds.min.? == 1 and info[3].bounds.max.? == 9, @src().line);
        check(info[4].kind == .@"enum" and info[4].type == Level, @src().line);
        // A rename wins over rename_all; a field with neither is camelCased.
        check(info[5].kind == .list and std.mem.eql(u8, info[5].wire.text, "labels"), @src().line);
        check(info[6].kind == .optional and info[6].optional == .absent and info[6].has_default and !info[6].nested_optional, @src().line);
        check(info[7].nested_optional and info[7].kind == .optional, @src().line);
        check(info[8].kind == .raw and !info[8].has_default and !info[8].extras, @src().line);
        check(info[9].kind == .hook, @src().line);
        check(info[10].extras and info[10].kind == .optional, @src().line);
        check(!info[5].has_default and info[5].optional == .lenient, @src().line);
    }
    // A field whose default is null has a default (the outer optional is set), and its value is null.
    try std.testing.expect(zerde.reflect.defaultOf(Described, "patch") != null);
    try std.testing.expect(zerde.reflect.defaultOf(Described, "patch").? == null);
    try std.testing.expect(zerde.reflect.defaultOf(Described, "level") == null);
    try std.testing.expectEqual(@as(u8, 1), comptime zerde.reflect.intRange(u8).min + 1);
    try std.testing.expectEqual(@as(i128, 255), comptime zerde.reflect.intRange(u8).max);
    try std.testing.expectEqual(@as(i128, std.math.maxInt(u64)), comptime zerde.reflect.intRange(u64).max);
    try std.testing.expect(zerde.reflect.childOf([]const u16) == u16);
}

test "reflect follows the call site's overrides and renames" {
    const Plain = struct { first_name: []const u8, age: u8 };
    const info = comptime zerde.reflect.fields(Plain, .{ .rename_all = .camelCase, .fields = .{ .age = .{ .key = 7, .max = 120 } } });
    comptime {
        check(std.mem.eql(u8, info[0].wire.text, "firstName"), @src().line);
        check(info[1].wire.integer == 7 and info[1].bounds.max.? == 120, @src().line);
    }
}

test "reflect gives the order a write emits, extras left out" {
    const declaration = comptime zerde.reflect.writeOrder(Described, zerde.cbor, .{}, .{});
    const deterministic = comptime zerde.reflect.writeOrder(Described, zerde.cbor, .{}, .{ .deterministic = true });
    comptime {
        check(declaration.len == 10 and declaration[0] == 0 and declaration[9] == 9, @src().line);
        // Integer keys ascending (0, 1, 2, 3, 4), then the text keys by length, then bytewise.
        check(deterministic.len == 10, @src().line);
        for (0..5) |index| check(deterministic[index] == index, @src().line);
        // Then by length: "meta" (8) and "nick" (6), "patch" (7) and "wired" (9), "labels" (5).
        check(deterministic[5] == 8 and deterministic[6] == 6 and deterministic[7] == 7 and deterministic[8] == 9 and deterministic[9] == 5, @src().line);
    }
}

test "reflect describes unions and enums" {
    const ops = comptime zerde.reflect.variants(Op, .{});
    comptime {
        check(ops.len == 3, @src().line);
        check(ops[0].kind == .none and ops[0].wire.integer == 1 and std.mem.eql(u8, ops[0].name, "ping"), @src().line);
        check(ops[1].kind == .int and ops[1].wire.integer == 2, @src().line);
        check(ops[2].kind == .@"struct" and ops[2].wire.integer == 24, @src().line);
    }
    const names = comptime zerde.reflect.variants(Shape, .{});
    comptime check(names[1].wire == .text and std.mem.eql(u8, names[1].wire.text, "circle"), @src().line);
    const level = comptime zerde.reflect.enumInfo(Level, .{});
    comptime {
        check(level.repr == .integer and level.values.len == 2, @src().line);
        check(level.values[1].value == 9 and std.mem.eql(u8, level.values[1].name, "high"), @src().line);
    }
    comptime check(zerde.reflect.enumInfo(enum { a, b }, .{}).repr == .name, @src().line);
}

/// A generator over the reflection: a TypeScript-like declaration of a struct, built at comptime.
fn describeStruct(comptime T: type) []const u8 {
    comptime {
        var text: []const u8 = "{ ";
        for (zerde.reflect.fields(T, .{})) |field| {
            if (field.extras) continue;
            const name = switch (field.wire) {
                .text => |t| t,
                .integer => |n| std.fmt.comptimePrint("{d}", .{n}),
            };
            const ts = switch (field.kind) {
                .int, .float => "number",
                .text => "string",
                .byte_string, .byte_array => "bytes",
                .list => "array",
                .optional => "maybe",
                else => "other",
            };
            text = text ++ name ++ ": " ++ ts ++ "; ";
        }
        return text ++ "}";
    }
}

test "a generator can be written against the reflection alone" {
    try std.testing.expectEqualStrings("{ 0: bytes; 1: bytes; 2: string; 3: number; 4: other; labels: array; nick: maybe; patch: maybe; meta: other; wired: other; }", comptime describeStruct(Described));
}

test "a JSON encode hook refuses NaN and nests no deeper than 128" {
    const Nan = struct {
        pub fn zerdeEncode(self: @This(), encoder: anytype) anyerror!void {
            _ = self;
            try encoder.writeFloat(std.math.nan(f64));
        }
    };
    const Deep = struct {
        depth: usize,

        pub fn zerdeEncode(self: @This(), encoder: anytype) anyerror!void {
            for (0..self.depth) |_| try encoder.beginArray(1);
            try encoder.writeNull();
            for (0..self.depth) |_| try encoder.endArray();
        }
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.NonFiniteFloat, zerde.serializeWith(zerde.json, &out.writer, Nan{}, .{}, .{}));
    try zerde.serializeWith(zerde.json, &out.writer, Deep{ .depth = 128 }, .{}, .{});
    try std.testing.expectError(error.JsonNestingTooDeep, zerde.serializeWith(zerde.json, &out.writer, Deep{ .depth = 129 }, .{}, .{}));
}

// ---- review fixes: leaks on failure, chunk bounds -----------------------------------------------------------------

fn parseListOfText(gpa: std.mem.Allocator, input: []const u8) !void {
    const parsed = try zerde.json.parseSlice(struct { b: []const []const u8, n: u8 }, gpa, input);
    zerde.free(gpa, parsed);
}

fn parseCborListOfText(gpa: std.mem.Allocator, input: []const u8) !void {
    const parsed = try zerde.cbor.parseSlice(struct { b: []const []const u8, n: u8 }, gpa, input);
    zerde.free(gpa, parsed);
}

test "a slice of strings leaks nothing when an allocation fails in the middle" {
    try std.testing.checkAllAllocationFailures(allocator, parseListOfText, .{"{\"b\":[\"p\",\"q\",\"r\"],\"n\":1}"});
    try std.testing.checkAllAllocationFailures(allocator, parseCborListOfText, .{&[_]u8{ 0xa2, 0x61, 'b', 0x9f, 0x61, 'p', 0x61, 'q', 0xff, 0x61, 'n', 0x01 }});
}

test "a decode hook that stops short frees what it built" {
    const Early = struct {
        text: []const u8,

        pub fn zerdeDecode(gpa: std.mem.Allocator, reader: anytype) anyerror!@This() {
            _ = (try reader.next()) orelse return error.UnexpectedEndOfInput; // [
            const first = (try reader.next()) orelse return error.UnexpectedEndOfInput;
            return .{ .text = try gpa.dupe(u8, first.text) };
        }

        pub fn zerdeFree(self: @This(), gpa: std.mem.Allocator) void {
            gpa.free(self.text);
        }
    };
    try expectJsonError(struct { e: Early }, error.HookIncomplete, "{\"e\":[\"ab\",\"c\"]}");
}

test "a chunked string is refused at its bound before it is joined" {
    const Capped = struct {
        s: []const u8,
        pub const serde = .{ .fields = .{ .s = .{ .max_len = 2 } } };
    };
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xa1, 0x61, 's', 0x7f });
    for (0..64) |_| try input.appendSlice(allocator, &.{ 0x64, 'a', 'b', 'c', 'd' });
    try input.append(allocator, 0xff);
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSlice(Capped, failing.allocator(), input.items));
    try std.testing.expect(failing.allocated_bytes <= 16);
    // Bytes too.
    const CappedBytes = struct {
        b: zerde.ByteString,
        pub const serde = .{ .fields = .{ .b = .{ .max_len = 2 } } };
    };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &.{ 0xa1, 0x61, 'b', 0x5f });
    for (0..64) |_| try bytes.appendSlice(allocator, &.{ 0x44, 1, 2, 3, 4 });
    try bytes.append(allocator, 0xff);
    var failing_bytes = std.testing.FailingAllocator.init(allocator, .{});
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSlice(CappedBytes, failing_bytes.allocator(), bytes.items));
    try std.testing.expect(failing_bytes.allocated_bytes <= 16);
    // Within the bound a chunked string is read, and max_string_len still applies.
    const ok = try zerde.cbor.parseSlice(Capped, allocator, &.{ 0xa1, 0x61, 's', 0x7f, 0x61, 'a', 0x61, 'b', 0xff });
    defer zerde.free(allocator, ok);
    try std.testing.expectEqualStrings("ab", ok.s);
    try std.testing.expectError(error.StringTooLong, zerde.cbor.parseSliceWith(Capped, allocator, &.{ 0xa1, 0x61, 's', 0x7f, 0x62, 'a', 'b', 0xff }, .{}, .{ .max_string_len = 1 }));
}

test "a writer refuses text that is not UTF-8 in either format, so its output reads back" {
    const Text = struct { s: []const u8 };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidUtf8, zerde.serializeWith(zerde.cbor, &out.writer, Text{ .s = "\xff" }, .{}, .{ .deterministic = true }));
    try std.testing.expectError(error.InvalidUtf8, zerde.serializeWith(zerde.cbor, &out.writer, Text{ .s = "ok\xc3" }, .{}, .{}));
    try std.testing.expectError(error.InvalidUtf8, zerde.serializeWith(zerde.json, &out.writer, Text{ .s = "\xff" }, .{}, .{}));
    // A key is text too.
    const Keyed2 = struct {
        f: u8,
        pub const serde = .{ .fields = .{ .f = .{ .rename = "k" } } };
    };
    try zerde.serializeWith(zerde.json, &out.writer, Keyed2{ .f = 1 }, .{}, .{});
    // The value writers and encode hooks too.
    var cbor = zerde.cbor.valueWriter(allocator, &out.writer, .{});
    defer cbor.deinit();
    try std.testing.expectError(error.InvalidUtf8, cbor.writeText("\xed\xa0\x80"));
    var json = zerde.json.valueWriter(allocator, &out.writer, .{});
    defer json.deinit();
    try std.testing.expectError(error.InvalidUtf8, json.writeText("\xc0\xaf"));
    // Valid multi-byte text passes.
    try zerde.serializeWith(zerde.cbor, &out.writer, Text{ .s = "h\xc3\xa9 \xe2\x82\xac" }, .{}, .{});
    try zerde.serializeWith(zerde.json, &out.writer, Text{ .s = "h\xc3\xa9 \xe2\x82\xac" }, .{}, .{});
}

// ---- every entry point applies the whole read configuration ------------------------------------------------------

const OneA = struct { a: u8 };

test "every CBOR entry point applies mode, limits and refuse_non_finite" {
    // An indefinite map: lenient reads it, strict_mode refuses it.
    const loose = [_]u8{ 0xbf, 0x61, 'a', 0x01, 0xff };
    const strict_mode = .{ .mode = .strict };
    const E = error.NonDeterministicEncoding;
    try std.testing.expectError(E, zerde.cbor.parseSliceWith(OneA, allocator, &loose, .{}, strict_mode));
    try std.testing.expectError(E, zerde.cbor.parseSliceAliasedWith(OneA, allocator, &loose, .{}, strict_mode));
    var reader: std.Io.Reader = .fixed(&loose);
    try std.testing.expectError(E, zerde.cbor.deserializeWith(OneA, allocator, &reader, .{}, strict_mode));
    try std.testing.expectError(E, zerde.parseSliceWith(zerde.cbor, OneA, allocator, &loose, .{}, strict_mode));
    try std.testing.expectError(E, zerde.parseSliceAliasedWith(zerde.cbor, OneA, allocator, &loose, .{}, strict_mode));
    try std.testing.expectError(E, zerde.parseSliceOwnedWith(zerde.cbor, OneA, allocator, &loose, .{}, strict_mode));
    var again: std.Io.Reader = .fixed(&loose);
    try std.testing.expectError(E, zerde.deserializeWith(zerde.cbor, OneA, allocator, &again, .{}, strict_mode));
    var third: std.Io.Reader = .fixed(&loose);
    try std.testing.expectError(E, zerde.deserializeOwnedWith(zerde.cbor, OneA, allocator, &third, .{}, strict_mode));
    var diagnostic: zerde.Diagnostic = .{};
    try std.testing.expectError(E, zerde.parseSliceWithDiagnostics(zerde.cbor, OneA, allocator, &loose, &diagnostic, .{}, strict_mode));
    try std.testing.expectError(E, zerde.value.parseSliceWith(zerde.cbor, allocator, &loose, strict_mode));
    var fourth: std.Io.Reader = .fixed(&loose);
    try std.testing.expectError(E, zerde.value.deserializeWith(zerde.cbor, allocator, &fourth, strict_mode));
    var pull = try zerde.cbor.pullReader(allocator, &loose, strict_mode);
    defer pull.deinit();
    try std.testing.expectError(E, pull.next());
    // Lenient still reads it, aliased or not.
    try std.testing.expectEqual(@as(u8, 1), (try zerde.cbor.parseSliceAliasedWith(OneA, allocator, &loose, .{}, .{})).a);

    // A limit and a refused NaN apply to the aliased read as to the owned one.
    const nan = [_]u8{ 0xa1, 0x61, 'a', 0xf9, 0x7e, 0x00 };
    try std.testing.expectError(error.NonFiniteFloat, zerde.cbor.parseSliceAliasedWith(struct { a: f64 }, allocator, &nan, .{}, .{ .refuse_non_finite = true }));
    const text = [_]u8{ 0xa1, 0x61, 'a', 0x63, 'x', 'y', 'z' };
    try std.testing.expectError(error.StringTooLong, zerde.cbor.parseSliceAliasedWith(struct { a: []const u8 }, allocator, &text, .{}, .{ .max_string_len = 2 }));
    try std.testing.expectError(error.TooManyItems, zerde.cbor.parseSliceAliasedWith(OneA, allocator, &.{ 0xa1, 0x61, 'a', 0x01 }, .{}, .{ .max_items = 1 }));
    try std.testing.expectError(error.CborNestingTooDeep, zerde.cbor.parseSliceAliasedWith(struct { a: zerde.cbor.Raw }, allocator, &.{ 0xa1, 0x61, 'a', 0x81, 0x01 }, .{}, .{ .max_depth = 1 }));
}

test "every JSON entry point applies the limits" {
    const input = "{\"a\":1}";
    const limits = .{ .max_items = 1 };
    const E = error.TooManyItems;
    try std.testing.expectError(E, zerde.json.parseSliceWith(OneA, allocator, input, .{}, limits));
    try std.testing.expectError(E, zerde.json.parseSliceAliasedWith(OneA, allocator, input, .{}, limits));
    var reader: std.Io.Reader = .fixed(input);
    try std.testing.expectError(E, zerde.json.deserializeWith(OneA, allocator, &reader, .{}, limits));
    try std.testing.expectError(E, zerde.parseSliceWith(zerde.json, OneA, allocator, input, .{}, limits));
    try std.testing.expectError(E, zerde.parseSliceAliasedWith(zerde.json, OneA, allocator, input, .{}, limits));
    try std.testing.expectError(E, zerde.parseSliceOwnedWith(zerde.json, OneA, allocator, input, .{}, limits));
    try std.testing.expectError(E, zerde.value.parseSliceWith(zerde.json, allocator, input, limits));
    var pull = try zerde.json.pullReader(allocator, input, limits);
    defer pull.deinit();
    var failed = false;
    while (pull.next() catch |err| blk: {
        try std.testing.expectEqual(E, err);
        failed = true;
        break :blk null;
    }) |_| {}
    try std.testing.expect(failed);
    // Depth and string length reach the aliased read too.
    try std.testing.expectError(error.JsonNestingTooDeep, zerde.json.parseSliceAliasedWith(struct { a: zerde.json.Raw }, allocator, "{\"a\":[1]}", .{}, .{ .max_depth = 1 }));
    try std.testing.expectError(error.StringTooLong, zerde.json.parseSliceAliasedWith(struct { a: []const u8 }, allocator, "{\"a\":\"xyz\"}", .{}, .{ .max_string_len = 2 }));
    try std.testing.expectEqual(@as(u8, 1), (try zerde.json.parseSliceAliasedWith(OneA, allocator, input, .{}, .{})).a);
}

// ---- a deterministic write is deterministic: Raw, extras and the encode hook -------------------------------------

/// A hook that runs `script(encoder)`, for what a hook can get wrong.
fn Scripted(comptime script: anytype) type {
    return struct {
        pub fn zerdeEncode(self: @This(), encoder: anytype) anyerror!void {
            _ = self;
            try script(encoder);
        }
    };
}

fn expectHookCbor(comptime script: anytype, comptime deterministic: bool, expected: anyerror![]const u8) !void {
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    const result = zerde.serializeWith(zerde.cbor, &sink.writer, Scripted(script){}, .{}, .{ .deterministic = deterministic });
    if (expected) |bytes| {
        try result;
        try std.testing.expectEqualSlices(u8, bytes, sink.written());
    } else |err| try std.testing.expectError(err, result);
}

test "a CBOR encode hook meets the lengths it states" {
    const S = struct {
        fn two(e: anytype) !void {
            try e.beginArray(2);
            try e.writeInt(1);
            try e.endArray();
        }
        fn one(e: anytype) !void {
            try e.beginArray(1);
            try e.writeInt(1);
            try e.writeInt(2);
        }
        fn evenMap(e: anytype) !void {
            try e.beginMap(1);
            try e.writeText("k");
            try e.endMap();
        }
        fn exact(e: anytype) !void {
            try e.beginArray(2);
            try e.writeInt(1);
            try e.writeInt(2);
            try e.endArray();
        }
        fn two_items(e: anytype) !void {
            try e.writeInt(1);
            try e.writeInt(2);
        }
        fn nothing(e: anytype) !void {
            _ = e;
        }
        fn stray_end(e: anytype) !void {
            try e.endArray();
        }
        fn wrong_end(e: anytype) !void {
            try e.beginArray(0);
            try e.endMap();
        }
        fn unfinished(e: anytype) !void {
            try e.beginArray(0);
        }
    };
    inline for ([_]bool{ false, true }) |deterministic| {
        try expectHookCbor(S.two, deterministic, error.LengthMismatch);
        try expectHookCbor(S.one, deterministic, error.LengthMismatch);
        try expectHookCbor(S.evenMap, deterministic, error.LengthMismatch);
        try expectHookCbor(S.exact, deterministic, &.{ 0x82, 0x01, 0x02 });
        try expectHookCbor(S.two_items, deterministic, error.LengthMismatch);
        try expectHookCbor(S.nothing, deterministic, error.LengthMismatch);
        try expectHookCbor(S.stray_end, deterministic, error.UnbalancedContainers);
        try expectHookCbor(S.wrong_end, deterministic, error.UnbalancedContainers);
        try expectHookCbor(S.unfinished, deterministic, error.LengthMismatch);
    }
}

test "a CBOR encode hook is bound to the nesting a reader accepts, to UTF-8 and to well-formed raw items" {
    const S = struct {
        fn nested(comptime depth: usize) fn (anytype) anyerror!void {
            return struct {
                fn run(e: anytype) anyerror!void {
                    for (0..depth) |_| try e.beginArray(1);
                    try e.writeNull();
                    for (0..depth) |_| try e.endArray();
                }
            }.run;
        }
        fn badText(e: anytype) !void {
            try e.writeText("\xff");
        }
        fn badKey(e: anytype) !void {
            try e.beginMap(1);
            try e.writeText("\xc3");
        }
        fn rawJunk(e: anytype) !void {
            try e.writeRaw(&.{ 0xff, 0xff });
        }
        fn rawShort(e: anytype) !void {
            try e.writeRaw(&.{ 0x82, 0x01 });
        }
        fn rawTrailing(e: anytype) !void {
            try e.writeRaw(&.{ 0x01, 0x02 });
        }
        fn rawText(e: anytype) !void {
            try e.writeRaw(&.{ 0x61, 0xff });
        }
        fn rawGood(e: anytype) !void {
            try e.writeRaw(&.{ 0x82, 0x01, 0x02 });
        }
    };
    inline for ([_]bool{ false, true }) |deterministic| {
        try expectHookCbor(S.nested(127), deterministic, &(@as([127]u8, @splat(0x81)) ++ [_]u8{0xf6}));
        try expectHookCbor(S.nested(129), deterministic, error.CborNestingTooDeep);
        try expectHookCbor(S.badText, deterministic, error.InvalidUtf8);
        try expectHookCbor(S.badKey, deterministic, error.InvalidUtf8);
        try expectHookCbor(S.rawJunk, deterministic, error.InvalidAdditionalInfo);
        try expectHookCbor(S.rawShort, deterministic, error.UnexpectedEndOfInput);
        try expectHookCbor(S.rawTrailing, deterministic, error.TrailingCharacters);
        try expectHookCbor(S.rawText, deterministic, error.InvalidUtf8);
        try expectHookCbor(S.rawGood, deterministic, &.{ 0x82, 0x01, 0x02 });
    }
}

test "a deterministic CBOR encode hook writes keys in ascending order, nested maps included" {
    const S = struct {
        fn nested(e: anytype) !void {
            try e.beginMap(2);
            try e.writeText("b");
            try e.beginMap(2);
            try e.writeInt(1);
            try e.writeNull();
            try e.writeInt(2);
            try e.writeNull();
            try e.endMap();
            // The key before this one is "b", not an inner key: "c" follows it.
            try e.writeText("c");
            try e.writeBool(true);
            try e.endMap();
        }
        fn outer_back(e: anytype) !void {
            try e.beginMap(2);
            try e.writeText("b");
            try e.beginMap(1);
            try e.writeText("zz");
            try e.writeNull();
            try e.endMap();
            try e.writeText("a");
            try e.writeNull();
            try e.endMap();
        }
        fn inner_fresh(e: anytype) !void {
            // Each map starts its own order: "a" in the inner map is fine after "b" in the outer.
            try e.beginMap(1);
            try e.writeText("b");
            try e.beginMap(2);
            try e.writeText("a");
            try e.writeNull();
            try e.writeText("c");
            try e.writeNull();
            try e.endMap();
            try e.endMap();
        }
        fn inner_unsorted(e: anytype) !void {
            try e.beginMap(1);
            try e.writeText("b");
            try e.beginMap(2);
            try e.writeText("c");
            try e.writeNull();
            try e.writeText("a");
            try e.writeNull();
        }
        fn mixed(e: anytype) !void {
            // Integers sort before text, by their encoded bytes: 1, 255, "a".
            try e.beginMap(3);
            try e.writeInt(1);
            try e.writeNull();
            try e.writeInt(255);
            try e.writeNull();
            try e.writeText("a");
            try e.writeNull();
            try e.endMap();
        }
        fn mixed_back(e: anytype) !void {
            try e.beginMap(2);
            try e.writeText("a");
            try e.writeNull();
            try e.writeInt(1);
        }
        fn array_key(e: anytype) !void {
            try e.beginMap(1);
            try e.beginArray(0);
        }
        fn raw_key(e: anytype) !void {
            try e.beginMap(2);
            try e.writeRaw(&.{0x01});
            try e.writeNull();
            try e.writeRaw(&.{0x02});
            try e.writeNull();
            try e.endMap();
        }
        fn long_key(e: anytype) !void {
            try e.beginMap(1);
            try e.writeText(&@as([2000]u8, @splat('k')));
        }
        fn long_value(e: anytype) !void {
            try e.beginMap(1);
            try e.writeText("k");
            try e.writeText(&@as([2000]u8, @splat('v')));
            try e.endMap();
        }
    };
    try expectHookCbor(S.nested, true, &.{ 0xa2, 0x61, 'b', 0xa2, 0x01, 0xf6, 0x02, 0xf6, 0x61, 'c', 0xf5 });
    try expectHookCbor(S.outer_back, true, error.NonDeterministicEncoding);
    try expectHookCbor(S.inner_fresh, true, &.{ 0xa1, 0x61, 'b', 0xa2, 0x61, 'a', 0xf6, 0x61, 'c', 0xf6 });
    try expectHookCbor(S.inner_unsorted, true, error.NonDeterministicEncoding);
    try expectHookCbor(S.mixed, true, &.{ 0xa3, 0x01, 0xf6, 0x18, 0xff, 0xf6, 0x61, 'a', 0xf6 });
    try expectHookCbor(S.mixed_back, true, error.NonDeterministicEncoding);
    try expectHookCbor(S.array_key, true, error.UnexpectedType);
    try expectHookCbor(S.raw_key, true, &.{ 0xa2, 0x01, 0xf6, 0x02, 0xf6 });
    try expectHookCbor(S.long_key, true, error.KeyTooLong);
    // The key buffer is for keys only: a long value streams, and a default write has no key limit.
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    try zerde.serializeWith(zerde.cbor, &sink.writer, Scripted(S.long_value){}, .{}, .{ .deterministic = true });
    sink.clearRetainingCapacity();
    // (The hook's map is never closed, which `finish` refuses: the length error is the only one.)
    try std.testing.expectError(error.LengthMismatch, zerde.serializeWith(zerde.cbor, &sink.writer, Scripted(S.long_key){}, .{}, .{}));
}

test "a deterministic write of a Raw or of extras is deterministic, or refused" {
    // Lenient reads keep what they were given.
    const lenient_cases = [_][]const u8{
        &.{ 0x18, 0x01 }, // 1 in a longer head
        &.{ 0x9f, 0x01, 0xff }, // indefinite array
        &.{ 0xfb, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0 }, // 1.0 as a double
        &.{ 0xa2, 0x61, 'b', 0x01, 0x61, 'a', 0x02 }, // keys out of order
        &.{ 0xc1, 0x01 }, // a tag
        &.{ 0x7f, 0x61, 'a', 0xff }, // chunked text
    };
    for (lenient_cases) |meta| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(allocator);
        try input.appendSlice(allocator, &.{ 0xa2, 0x62, 'i', 'd', 0x01, 0x64, 'm', 'e', 't', 'a' });
        try input.appendSlice(allocator, meta);
        const decoded = try zerde.cbor.parseSlice(Framed, allocator, input.items);
        defer zerde.free(allocator, decoded);
        // The default write puts it back.
        var plain = try writeCbor(decoded, .{}, .{});
        defer plain.deinit();
        try std.testing.expect(std.mem.indexOf(u8, plain.written(), meta) != null);
        // A deterministic write refuses it...
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const refused = zerde.serializeWith(zerde.cbor, &out.writer, decoded, .{}, .{ .deterministic = true });
        try std.testing.expect(std.meta.isError(refused));
        // ...and writes what canonicalize gives, which a strict read accepts as it stands.
        if (zerde.cbor.canonicalize(allocator, meta)) |canonical| {
            defer allocator.free(canonical);
            var det = try writeCbor(Framed{ .id = 1, .meta = .{ .bytes = canonical } }, .{}, .{ .deterministic = true });
            defer det.deinit();
            const again = try zerde.cbor.parseSliceWith(Framed, allocator, det.written(), .{}, .{ .mode = .strict });
            defer zerde.free(allocator, again);
            try std.testing.expectEqualSlices(u8, canonical, again.meta.bytes);
        } else |err| try std.testing.expectEqual(error.UnexpectedTag, err);
    }
    // Extras are one Raw: the same rule.
    const loose = [_]u8{ 0xa3, 0x62, 'i', 'd', 0x01, 0x64, 'n', 'a', 'm', 'e', 0x61, 'n', 0x61, 'z', 0x18, 0x01 };
    const kept = try zerde.cbor.parseSlice(WithExtras, allocator, &loose);
    defer zerde.free(allocator, kept);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.NonDeterministicEncoding, zerde.serializeWith(zerde.cbor, &out.writer, kept, .{}, .{ .deterministic = true }));
    const canonical = try zerde.cbor.canonicalize(allocator, kept.rest.bytes);
    defer allocator.free(canonical);
    var det = try writeCbor(WithExtras{ .id = 1, .name = "n", .rest = .{ .bytes = canonical } }, .{}, .{ .deterministic = true });
    defer det.deinit();
    const strict_read = try zerde.cbor.parseSliceWith(WithExtras, allocator, det.written(), .{}, .{ .mode = .strict });
    defer zerde.free(allocator, strict_read);
    try std.testing.expectEqual(@as(u8, 1), strict_read.id);
}

test "canonicalize gives the deterministic form, and refuses what has none" {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = &.{ 0x18, 0x01 }, .out = &.{0x01} },
        .{ .in = &.{ 0x9f, 0x01, 0xff }, .out = &.{ 0x81, 0x01 } },
        .{ .in = &.{ 0xfb, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0 }, .out = &.{ 0xf9, 0x3c, 0x00 } },
        .{ .in = &.{ 0xfa, 0x47, 0xc3, 0x50, 0x00 }, .out = &.{ 0xfa, 0x47, 0xc3, 0x50, 0x00 } }, // 100000.0 needs a single
        .{ .in = &.{ 0xf9, 0x7e, 0x01 }, .out = &.{ 0xf9, 0x7e, 0x00 } }, // a NaN with a payload
        .{ .in = &.{ 0xfb, 0x7f, 0xf0, 0, 0, 0, 0, 0, 0 }, .out = &.{ 0xf9, 0x7c, 0x00 } }, // infinity
        .{ .in = &.{ 0xa2, 0x61, 'b', 0x01, 0x61, 'a', 0x02 }, .out = &.{ 0xa2, 0x61, 'a', 0x02, 0x61, 'b', 0x01 } },
        .{ .in = &.{ 0xbf, 0x61, 'a', 0x7f, 0x61, 'x', 0x61, 'y', 0xff, 0xff }, .out = &.{ 0xa1, 0x61, 'a', 0x62, 'x', 'y' } },
        .{ .in = &.{ 0xa2, 0x62, 'b', 'b', 0x01, 0x61, 'c', 0x02 }, .out = &.{ 0xa2, 0x61, 'c', 0x02, 0x62, 'b', 'b', 0x01 } },
        // The canonical form is what a strict read accepts, so it is its own canonical form.
        .{ .in = &.{ 0xa1, 0x61, 'a', 0xf9, 0x3c, 0x00 }, .out = &.{ 0xa1, 0x61, 'a', 0xf9, 0x3c, 0x00 } },
    };
    for (cases) |case| {
        const got = try zerde.cbor.canonicalize(allocator, case.in);
        defer allocator.free(got);
        try std.testing.expectEqualSlices(u8, case.out, got);
        // Strict mode accepts what it gives.
        var d = try zerde.cbor.pullReader(allocator, got, .{ .mode = .strict });
        defer d.deinit();
        while (try d.next()) |_| {}
    }
    try std.testing.expectError(error.UnexpectedTag, zerde.cbor.canonicalize(allocator, &.{ 0xc1, 0x01 }));
    try std.testing.expectError(error.DuplicateField, zerde.cbor.canonicalize(allocator, &.{ 0xa2, 0x61, 'a', 0x01, 0x61, 'a', 0x02 }));
    try std.testing.expectError(error.TrailingCharacters, zerde.cbor.canonicalize(allocator, &.{ 0x01, 0x02 }));
    try std.testing.expectError(error.UnexpectedEndOfInput, zerde.cbor.canonicalize(allocator, &.{ 0x82, 0x01 }));
    try std.testing.expectError(error.InvalidUtf8, zerde.cbor.canonicalize(allocator, &.{ 0x61, 0xff }));
    try std.testing.expectError(error.TrailingCharacters, zerde.cbor.validate(allocator, &.{ 0x01, 0x02 }));
    try zerde.cbor.validate(allocator, &.{ 0xc1, 0x01 });
}

test "the value writer puts a Raw in canonical form when deterministic, and checks it either way" {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var det = zerde.cbor.valueWriter(allocator, &out.writer, .{ .deterministic = true });
    defer det.deinit();
    try det.beginArray();
    try det.writeRaw(&.{ 0xfb, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0 });
    try det.writeRaw(&.{ 0xbf, 0x61, 'b', 0x01, 0x61, 'a', 0x02, 0xff });
    try std.testing.expectError(error.UnexpectedTag, det.writeRaw(&.{ 0xc1, 0x01 }));
    try std.testing.expectError(error.UnexpectedEndOfInput, det.writeRaw(&.{0x82}));
    try det.endArray();
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0xf9, 0x3c, 0x00, 0xa2, 0x61, 'a', 0x02, 0x61, 'b', 0x01 }, out.written());
    out.clearRetainingCapacity();
    var plain = zerde.cbor.valueWriter(allocator, &out.writer, .{});
    defer plain.deinit();
    try plain.writeRaw(&.{ 0xc1, 0x18, 0x01 });
    try std.testing.expectEqualSlices(u8, &.{ 0xc1, 0x18, 0x01 }, out.written());
    try std.testing.expectError(error.DuplicateField, plain.writeRaw(&.{ 0xa2, 0x61, 'a', 0x01, 0x61, 'a', 0x02 }));
}

test "a JSON encode hook meets its lengths, and checks text and raw values" {
    const S = struct {
        fn two(e: anytype) !void {
            try e.beginArray(2);
            try e.writeInt(1);
            try e.endArray();
        }
        fn extra(e: anytype) !void {
            try e.beginArray(1);
            try e.writeInt(1);
            try e.writeInt(2);
        }
        fn exact(e: anytype) !void {
            try e.beginMap(1);
            try e.writeText("k");
            try e.writeInt(2);
            try e.endMap();
        }
        fn nothing(e: anytype) !void {
            _ = e;
        }
        fn twice(e: anytype) !void {
            try e.writeInt(1);
            try e.writeInt(2);
        }
        fn rawBad(e: anytype) !void {
            try e.writeRaw("[1,");
        }
        fn rawText(e: anytype) !void {
            try e.writeRaw("\"\xff\"");
        }
        fn rawEscape(e: anytype) !void {
            try e.writeRaw("\"\\q\"");
        }
        fn rawSurrogate(e: anytype) !void {
            try e.writeRaw("\"\\ud800\"");
        }
        fn rawTrailing(e: anytype) !void {
            try e.writeRaw("1 2");
        }
        fn rawGood(e: anytype) !void {
            try e.writeRaw(" {\"a\":[1,\"\\u00e9\\ud83d\\ude00\"]} ");
        }
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    inline for (.{
        .{ S.two, error.LengthMismatch },
        .{ S.extra, error.LengthMismatch },
        .{ S.nothing, error.LengthMismatch },
        .{ S.twice, error.LengthMismatch },
        .{ S.rawBad, error.UnexpectedEndOfInput },
        .{ S.rawText, error.InvalidUtf8 },
        .{ S.rawEscape, error.InvalidStringEscape },
        .{ S.rawSurrogate, error.InvalidUnicodeSurrogate },
        .{ S.rawTrailing, error.TrailingCharacters },
    }) |case| {
        out.clearRetainingCapacity();
        try std.testing.expectError(case[1], zerde.serializeWith(zerde.json, &out.writer, Scripted(case[0]){}, .{}, .{}));
    }
    out.clearRetainingCapacity();
    try zerde.serializeWith(zerde.json, &out.writer, Scripted(S.exact){}, .{}, .{});
    try std.testing.expectEqualStrings("{\"k\":2}", out.written());
    out.clearRetainingCapacity();
    try zerde.serializeWith(zerde.json, &out.writer, Scripted(S.rawGood){}, .{}, .{});
}

test "raw items are checked in full: keys in order, chunks, depth, escapes, extras" {
    // CBOR: a deterministic write refuses a repeated or unordered key in a raw map.
    const dup_key = [_]u8{ 0xa2, 0x61, 'a', 0x01, 0x61, 'a', 0x02 };
    const unordered = [_]u8{ 0xa2, 0x61, 'b', 0x01, 0x61, 'a', 0x02 };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    inline for (.{ dup_key, unordered }) |bytes| {
        out.clearRetainingCapacity();
        try std.testing.expectError(error.NonDeterministicEncoding, zerde.serializeWith(zerde.cbor, &out.writer, Framed{ .id = 1, .meta = .{ .bytes = &bytes } }, .{}, .{ .deterministic = true }));
    }
    // A chunk of another kind, and a chunk that is itself indefinite, are not a string.
    inline for (.{ &[_]u8{ 0x7f, 0x41, 'a', 0xff }, &[_]u8{ 0x5f, 0x61, 'a', 0xff }, &[_]u8{ 0x7f, 0x7f, 0xff, 0xff } }) |bytes| {
        out.clearRetainingCapacity();
        try std.testing.expectError(error.InvalidStringChunk, zerde.serializeWith(zerde.cbor, &out.writer, Framed{ .id = 1, .meta = .{ .bytes = bytes } }, .{}, .{}));
    }
    // 129 arrays are too deep for any reader of this library; 128 are not.
    const deep = try nestedCbor(129, 0x81);
    defer allocator.free(deep);
    out.clearRetainingCapacity();
    try std.testing.expectError(error.CborNestingTooDeep, zerde.serializeWith(zerde.cbor, &out.writer, Framed{ .id = 1, .meta = .{ .bytes = deep } }, .{}, .{}));

    // The key buffer is freed as each nested map closes: many nests of long keys fit.
    const Many = struct {
        pub fn zerdeEncode(self: @This(), encoder: anytype) anyerror!void {
            _ = self;
            try encoder.beginMap(40);
            for (0..40) |index| {
                try encoder.writeInt(@intCast(index));
                try encoder.beginMap(1);
                try encoder.writeText(&@as([300]u8, @splat('k')));
                try encoder.writeNull();
                try encoder.endMap();
            }
            try encoder.endMap();
        }
    };
    out.clearRetainingCapacity();
    try zerde.serializeWith(zerde.cbor, &out.writer, Many{}, .{}, .{ .deterministic = true });
    // Maps in an array: each frees its keys too.
    const InArray = struct {
        pub fn zerdeEncode(self: @This(), encoder: anytype) anyerror!void {
            _ = self;
            try encoder.beginArray(40);
            for (0..40) |_| {
                try encoder.beginMap(1);
                try encoder.writeText(&@as([300]u8, @splat('k')));
                try encoder.writeNull();
                try encoder.endMap();
            }
            try encoder.endArray();
        }
    };
    out.clearRetainingCapacity();
    try zerde.serializeWith(zerde.cbor, &out.writer, InArray{}, .{}, .{ .deterministic = true });

    // JSON: a raw value is checked wherever it is written.
    out.clearRetainingCapacity();
    try std.testing.expectError(error.UnexpectedEndOfInput, zerde.serializeWith(zerde.json, &out.writer, FramedJson{ .id = 1, .meta = .{ .bytes = "[1," } }, .{}, .{}));
    try std.testing.expectError(error.InvalidUtf8, zerde.serializeWith(zerde.json, &out.writer, WithExtrasJson{ .id = 1, .name = "n", .rest = .{ .bytes = "{\"a\":\"\xff\"}" } }, .{}, .{}));
    var json = zerde.json.valueWriter(allocator, &out.writer, .{});
    defer json.deinit();
    try std.testing.expectError(error.UnexpectedEndOfInput, json.writeRaw("[1,"));
    const S = struct {
        fn lowSurrogate(e: anytype) !void {
            try e.writeRaw("\"\\udc00\"");
        }
        fn unpairedHigh(e: anytype) !void {
            try e.writeRaw("\"\\ud800\\u0041\"");
        }
        fn control(e: anytype) !void {
            try e.writeRaw("\"a\x01\"");
        }
        fn shortMap(e: anytype) !void {
            try e.beginMap(2);
            try e.writeText("k");
            try e.writeNull();
            try e.endMap();
        }
        fn emptyMapKey(e: anytype) !void {
            try e.beginMap(0);
            try e.writeText("k");
        }
    };
    inline for (.{
        .{ S.lowSurrogate, error.InvalidUnicodeSurrogate },
        .{ S.unpairedHigh, error.InvalidUnicodeSurrogate },
        .{ S.control, error.InvalidStringCharacter },
        .{ S.shortMap, error.LengthMismatch },
        .{ S.emptyMapKey, error.LengthMismatch },
    }) |case| {
        out.clearRetainingCapacity();
        try std.testing.expectError(case[1], zerde.serializeWith(zerde.json, &out.writer, Scripted(case[0]){}, .{}, .{}));
    }
}

// ---- text known to be valid is not checked again ----------------------------------------------------------

test "trusted_text skips the UTF-8 check on read, in both formats, and nothing else" {
    const Text = struct { s: []const u8 };
    const cbor_plain = [_]u8{ 0xa1, 0x61, 's', 0x62, 'a', 0xff };
    const cbor_chunked = [_]u8{ 0xa1, 0x61, 's', 0x7f, 0x61, 0xff, 0xff };
    inline for (.{ &cbor_plain, &cbor_chunked }) |input| {
        try std.testing.expectError(error.InvalidUtf8, zerde.cbor.parseSlice(Text, allocator, input));
        const parsed = try zerde.cbor.parseSliceWith(Text, allocator, input, .{}, .{ .trusted_text = true });
        defer zerde.free(allocator, parsed);
        try std.testing.expect(std.mem.indexOfScalar(u8, parsed.s, 0xff) != null);
    }
    const aliased = try zerde.cbor.parseSliceAliasedWith(Text, allocator, &cbor_plain, .{}, .{ .trusted_text = true });
    try std.testing.expectEqualSlices(u8, &.{ 'a', 0xff }, aliased.s);
    // Strict mode still refuses the other things it refuses, and a text key is read too.
    try std.testing.expectError(error.NonDeterministicEncoding, zerde.cbor.parseSliceWith(Text, allocator, &.{ 0xbf, 0x61, 's', 0x61, 'a', 0xff }, .{}, .{ .trusted_text = true, .mode = .strict }));
    const skipped = try zerde.cbor.parseSliceWith(Text, allocator, &.{ 0xa2, 0x61, 's', 0x61, 'a', 0x62, 'x', 0xff, 0x00 }, .{}, .{ .trusted_text = true });
    defer zerde.free(allocator, skipped);
    try std.testing.expectError(error.InvalidUtf8, zerde.cbor.parseSlice(Text, allocator, &.{ 0xa2, 0x61, 's', 0x61, 'a', 0x62, 'x', 0xff, 0x00 }));
    // The pull reader and Raw take it too.
    var pull = try zerde.cbor.pullReader(allocator, &cbor_plain, .{ .trusted_text = true });
    defer pull.deinit();
    while (try pull.next()) |_| {}
    const Held = struct { s: zerde.cbor.Raw };
    const raw = try zerde.cbor.parseSliceWith(Held, allocator, &cbor_plain, .{}, .{ .trusted_text = true });
    defer zerde.free(allocator, raw);

    // JSON: plain and escaped runs.
    const plain = "{\"s\":\"a\xff\"}";
    const escaped = "{\"s\":\"\\n\xff\\t\"}";
    inline for (.{ plain, escaped }) |input| {
        try std.testing.expectError(error.InvalidUtf8, zerde.json.parseSlice(Text, allocator, input));
        const parsed = try zerde.json.parseSliceWith(Text, allocator, input, .{}, .{ .trusted_text = true });
        defer zerde.free(allocator, parsed);
        try std.testing.expect(std.mem.indexOfScalar(u8, parsed.s, 0xff) != null);
    }
    // Escapes and control characters are still checked.
    try std.testing.expectError(error.InvalidStringEscape, zerde.json.parseSliceWith(Text, allocator, "{\"s\":\"\\q\"}", .{}, .{ .trusted_text = true }));
    try std.testing.expectError(error.InvalidStringCharacter, zerde.json.parseSliceWith(Text, allocator, "{\"s\":\"\x01\"}", .{}, .{ .trusted_text = true }));
    var json_pull = try zerde.json.pullReader(allocator, plain, .{ .trusted_text = true });
    defer json_pull.deinit();
    while (try json_pull.next()) |_| {}
    // A Raw written back is checked in full, trusted or not.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidUtf8, zerde.serializeWith(zerde.json, &out.writer, FramedJson{ .id = 1, .meta = .{ .bytes = "\"\xff\"" } }, .{}, .{ .trusted_text = true }));
}

test "trusted_text skips the UTF-8 check on write" {
    const Text = struct { s: []const u8 };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidUtf8, zerde.serializeWith(zerde.cbor, &out.writer, Text{ .s = "\xff" }, .{}, .{}));
    out.clearRetainingCapacity();
    try zerde.serializeWith(zerde.cbor, &out.writer, Text{ .s = "\xff" }, .{}, .{ .trusted_text = true });
    try std.testing.expectEqualSlices(u8, &.{ 0xbf, 0x61, 's', 0x61, 0xff, 0xff }, out.written());
    out.clearRetainingCapacity();
    try std.testing.expectError(error.InvalidUtf8, zerde.serializeWith(zerde.json, &out.writer, Text{ .s = "\xff" }, .{}, .{}));
    out.clearRetainingCapacity();
    try zerde.serializeWith(zerde.json, &out.writer, Text{ .s = "\xff" }, .{}, .{ .trusted_text = true });
    try std.testing.expectEqualSlices(u8, "{\"s\":\"\xff\"}", out.written());
    // The value writers and the hook encoders follow the config too.
    out.clearRetainingCapacity();
    var cbor = zerde.cbor.valueWriter(allocator, &out.writer, .{ .trusted_text = true });
    defer cbor.deinit();
    try cbor.writeText("\xff");
    var checking = zerde.cbor.valueWriter(allocator, &out.writer, .{});
    defer checking.deinit();
    try std.testing.expectError(error.InvalidUtf8, checking.writeText("\xff"));
    var json = zerde.json.valueWriter(allocator, &out.writer, .{ .trusted_text = true });
    defer json.deinit();
    try json.writeText("\xff");
    const Hook = struct {
        pub fn zerdeEncode(self: @This(), encoder: anytype) anyerror!void {
            _ = self;
            try encoder.writeText("\xff");
        }
    };
    out.clearRetainingCapacity();
    try zerde.serializeWith(zerde.cbor, &out.writer, Hook{}, .{}, .{ .trusted_text = true });
    try zerde.serializeWith(zerde.json, &out.writer, Hook{}, .{}, .{ .trusted_text = true });
    try std.testing.expectError(error.InvalidUtf8, zerde.serializeWith(zerde.json, &out.writer, Hook{}, .{}, .{}));
}

// ---- bounds on the elements of an array --------------------------------------------------------------------

const Elems = struct {
    keys: []const []const u8,
    spans: []const u16,
    grid: []const []const u16,
    maybe: ?[]const u16 = null,

    pub const serde = .{ .fields = .{
        .keys = .{ .max_len = 3, .elem = .{ .min_len = 1, .max_len = 4 } },
        .spans = .{ .elem = .{ .min = 1, .max = 100 } },
        .grid = .{ .max_len = 2, .elem = .{ .max_len = 2, .elem = .{ .max = 9 } } },
        .maybe = .{ .elem = .{ .max = 5 } },
    } };
};

fn expectElems(comptime format: type, comptime encode: anytype, comptime err: ?anyerror, value: Elems) !void {
    var out = try encode(value, .{}, .{});
    defer out.deinit();
    if (err) |expected| {
        try std.testing.expectError(expected, format.parseSlice(Elems, allocator, out.written()));
    } else {
        const parsed = try format.parseSlice(Elems, allocator, out.written());
        zerde.free(allocator, parsed);
    }
}

test "bounds on elements are checked for every element, in both formats" {
    const ok = Elems{ .keys = &.{ "a", "abcd" }, .spans = &.{ 1, 100 }, .grid = &.{ &.{ 1, 9 }, &.{} }, .maybe = &.{ 5, 0 } };
    inline for (.{ .{ zerde.cbor, writeCbor }, .{ zerde.json, writeJson } }) |pair| {
        try expectElems(pair[0], pair[1], null, ok);
        var bad = ok;
        bad.keys = &.{ "a", "abcde" };
        try expectElems(pair[0], pair[1], error.LengthOutOfBounds, bad);
        bad = ok;
        bad.keys = &.{ "a", "" };
        try expectElems(pair[0], pair[1], error.LengthOutOfBounds, bad);
        bad = ok;
        bad.keys = &.{ "a", "b", "c", "d" };
        try expectElems(pair[0], pair[1], error.LengthOutOfBounds, bad);
        bad = ok;
        bad.spans = &.{ 1, 0 };
        try expectElems(pair[0], pair[1], error.ValueOutOfRange, bad);
        bad = ok;
        bad.spans = &.{ 101, 5 };
        try expectElems(pair[0], pair[1], error.ValueOutOfRange, bad);
        bad = ok;
        bad.grid = &.{ &.{ 1, 2, 3 }, &.{} };
        try expectElems(pair[0], pair[1], error.LengthOutOfBounds, bad);
        bad = ok;
        bad.grid = &.{&.{10}};
        try expectElems(pair[0], pair[1], error.ValueOutOfRange, bad);
        bad = ok;
        bad.maybe = &.{6};
        try expectElems(pair[0], pair[1], error.ValueOutOfRange, bad);
        bad = ok;
        bad.maybe = null;
        try expectElems(pair[0], pair[1], null, bad);
    }
}

test "an element bound stops an oversized element before it is joined or allocated" {
    const Capped = struct {
        keys: []const []const u8,
        pub const serde = .{ .fields = .{ .keys = .{ .elem = .{ .max_len = 2 } } } };
    };
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xa1, 0x64, 'k', 'e', 'y', 's', 0x81, 0x7f });
    for (0..64) |_| try input.appendSlice(allocator, &.{ 0x64, 'a', 'b', 'c', 'd' });
    try input.append(allocator, 0xff);
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSlice(Capped, failing.allocator(), input.items));
    try std.testing.expect(failing.allocated_bytes <= 32);
    // The call site can bound the elements too, and a read without bounds is unaffected.
    const Plain = struct { keys: []const []const u8 };
    try std.testing.expectError(error.LengthOutOfBounds, zerde.json.parseSliceWith(Plain, allocator, "{\"keys\":[\"abc\"]}", .{ .fields = .{ .keys = .{ .elem = .{ .max_len = 2 } } } }, .{}));
    const free = try zerde.json.parseSlice(Plain, allocator, "{\"keys\":[\"abc\"]}");
    zerde.free(allocator, free);
    // A struct check still runs after element bounds, and reflection reports them.
    const info = comptime zerde.reflect.fields(Elems, .{});
    try std.testing.expect(info[0].bounds.elem.?.max_len == 4);
    try std.testing.expect(info[2].bounds.elem.?.elem.?.max.? == 9);
    try std.testing.expect(info[3].bounds.elem.?.max.? == 5);
}

test "element bounds also apply in formats that state a length without a closing check" {
    const Short = struct {
        keys: []const []const u8,
        pub const serde = .{ .fields = .{ .keys = .{ .elem = .{ .max_len = 2 } } } };
    };
    inline for (.{ zerde.bson, zerde.msgpack, zerde.yaml, zerde.toml, zerde.zon }) |Format| {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try zerde.serializeWith(Format, &out.writer, Short{ .keys = &.{ "ab", "c" } }, .{}, .{});
        const ok = try Format.parseSlice(Short, allocator, out.written());
        zerde.free(allocator, ok);
        out.clearRetainingCapacity();
        try zerde.serializeWith(Format, &out.writer, Short{ .keys = &.{ "ab", "cde" } }, .{}, .{});
        try std.testing.expectError(error.LengthOutOfBounds, Format.parseSlice(Short, allocator, out.written()));
    }
}

// ---- a pull reader's raw span, and a validator for a kept item --------------------------------------------

test "a pull reader returns the span of the next item" {
    // [1, {"a": [2, 3]}, "x"]: raw at the root, as an element, and as a map value.
    const input = [_]u8{ 0x83, 0x01, 0xa1, 0x61, 'a', 0x82, 0x02, 0x03, 0x61, 'x' };
    var whole = try zerde.cbor.pullReader(allocator, &input, .{});
    defer whole.deinit();
    try std.testing.expectEqualSlices(u8, &input, try whole.raw());
    try whole.finish();
    try std.testing.expectError(error.UnexpectedEndOfInput, whole.raw());

    // One item only: a second one is not the reader's to take.
    var two = try zerde.cbor.pullReader(allocator, &.{ 0x01, 0x02 }, .{});
    defer two.deinit();
    try std.testing.expectEqualSlices(u8, &.{0x01}, try two.raw());
    try std.testing.expectError(error.UnexpectedEndOfInput, two.raw());
    try std.testing.expectError(error.TrailingCharacters, two.finish());
    var json_two = try zerde.json.pullReader(allocator, "1 2", .{});
    defer json_two.deinit();
    try std.testing.expectEqualStrings("1", try json_two.raw());
    try std.testing.expectError(error.UnexpectedEndOfInput, json_two.raw());
    try std.testing.expectError(error.TrailingCharacters, json_two.finish());

    var pull = try zerde.cbor.pullReader(allocator, &input, .{});
    defer pull.deinit();
    try std.testing.expect((try pull.next()).? == .array_begin);
    try std.testing.expectEqualSlices(u8, &.{0x01}, try pull.raw());
    try std.testing.expect((try pull.next()).? == .map_begin);
    // A map key is not a value.
    try std.testing.expectError(error.UnexpectedType, pull.raw());
    const key = (try pull.next()).?;
    try std.testing.expectEqualStrings("a", key.text);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x02, 0x03 }, try pull.raw());
    try std.testing.expect((try pull.next()).? == .map_end);
    try std.testing.expectEqualSlices(u8, &.{ 0x61, 'x' }, try pull.raw());
    // The array has ended where a value was due.
    try std.testing.expectError(error.UnexpectedType, pull.raw());
    try pull.finish();

    // The item is checked as the mode says.
    var strict_pull = try zerde.cbor.pullReader(allocator, &.{ 0x82, 0x18, 0x01, 0x02 }, .{ .mode = .strict });
    defer strict_pull.deinit();
    _ = try strict_pull.next();
    try std.testing.expectError(error.NonDeterministicEncoding, strict_pull.raw());

    // JSON: the text without the whitespace around it.
    const json = " [1, {\"a\": [2, 3]} , \"x\"] ";
    var json_pull = try zerde.json.pullReader(allocator, json, .{});
    defer json_pull.deinit();
    try std.testing.expect((try json_pull.next()).? == .array_begin);
    try std.testing.expectEqualStrings("1", try json_pull.raw());
    try std.testing.expect((try json_pull.next()).? == .map_begin);
    try std.testing.expectError(error.UnexpectedType, json_pull.raw());
    _ = try json_pull.next();
    try std.testing.expectEqualStrings("[2, 3]", try json_pull.raw());
    _ = try json_pull.next();
    try std.testing.expectEqualStrings("\"x\"", try json_pull.raw());
    try std.testing.expectError(error.UnexpectedType, json_pull.raw());
    try json_pull.finish();
    var bad = try zerde.json.pullReader(allocator, "[1,", .{});
    defer bad.deinit();
    _ = try bad.next();
    _ = try bad.raw();
    try std.testing.expectError(error.UnexpectedEndOfInput, bad.raw());
}

test "a decode hook can keep the span it consumed" {
    const Framed2 = struct {
        span: []const u8,

        pub fn zerdeDecode(gpa: std.mem.Allocator, reader: anytype) anyerror!@This() {
            return .{ .span = try gpa.dupe(u8, try reader.raw()) };
        }

        pub fn zerdeFree(self: @This(), gpa: std.mem.Allocator) void {
            gpa.free(self.span);
        }
    };
    const Holder = struct { a: Framed2, b: u8 };
    const cbor = try zerde.cbor.parseSlice(Holder, allocator, &.{ 0xa2, 0x61, 'a', 0x82, 0x01, 0x02, 0x61, 'b', 0x07 });
    defer zerde.free(allocator, cbor);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x01, 0x02 }, cbor.a.span);
    const json = try zerde.json.parseSlice(Holder, allocator, "{\"a\": {\"x\": [1, 2] }, \"b\": 7}");
    defer zerde.free(allocator, json);
    try std.testing.expectEqualStrings("{\"x\": [1, 2] }", json.a.span);
}

/// The profile of a metadata map: text keys, values that are scalars or arrays of scalars, finite floats.
fn checkMetaCbor(gpa: std.mem.Allocator, bytes: []const u8) anyerror!void {
    var reader = try zerde.cbor.pullReader(gpa, bytes, .{});
    defer reader.deinit();
    if ((try reader.next()).? != .map_begin) return error.BadMeta;
    while (try reader.next()) |event| {
        switch (event) {
            .map_end => return,
            .text => {},
            else => return error.BadMeta,
        }
        const value = (try reader.next()).?;
        switch (value) {
            .float => |f| if (!std.math.isFinite(f)) return error.BadMeta,
            .array_begin => while (try reader.next()) |item| {
                switch (item) {
                    .array_end => break,
                    .array_begin, .map_begin => return error.BadMeta,
                    .float => |f| if (!std.math.isFinite(f)) return error.BadMeta,
                    else => {},
                }
            },
            .map_begin => return error.BadMeta,
            else => {},
        }
    }
}

fn checkMetaJson(gpa: std.mem.Allocator, bytes: []const u8) anyerror!void {
    var reader = try zerde.json.pullReader(gpa, bytes, .{});
    defer reader.deinit();
    if ((try reader.next()).? != .map_begin) return error.BadMeta;
    while (try reader.next()) |event| {
        if (event == .map_end) return;
        const value = (try reader.next()).?;
        switch (value) {
            .array_begin => while (try reader.next()) |item| {
                switch (item) {
                    .array_end => break,
                    .array_begin, .map_begin => return error.BadMeta,
                    else => {},
                }
            },
            .map_begin => return error.BadMeta,
            else => {},
        }
    }
}

const Profiled = struct {
    id: u8,
    meta: zerde.cbor.Raw,
    maybe: ?zerde.cbor.Raw = null,
    all: []const zerde.cbor.Raw = &.{},

    pub const serde = .{ .fields = .{
        .meta = .{ .validate = checkMetaCbor },
        .maybe = .{ .validate = checkMetaCbor },
        .all = .{ .elem = .{ .validate = checkMetaCbor } },
    } };
};

const ProfiledJson = struct {
    id: u8,
    meta: zerde.json.Raw,
    pub const serde = .{ .fields = .{ .meta = .{ .validate = checkMetaJson } } };
};

test "a validator checks a kept item after the read has, and its error is the read's" {
    // {"id": 1, "meta": {"k": 1, "l": [2.5, "x"]}}
    const good = [_]u8{ 0xa2, 0x62, 'i', 'd', 0x01, 0x64, 'm', 'e', 't', 'a', 0xa2, 0x61, 'k', 0x01, 0x61, 'l', 0x82, 0xf9, 0x41, 0x40, 0x61, 'x' };
    const parsed = try zerde.cbor.parseSlice(Profiled, allocator, &good);
    defer zerde.free(allocator, parsed);
    try std.testing.expectEqual(@as(u8, 1), parsed.id);
    const aliased = try zerde.cbor.parseSliceAliasedWith(Profiled, allocator, &good, .{}, .{});
    try std.testing.expectEqualSlices(u8, parsed.meta.bytes, aliased.meta.bytes);

    const head = [_]u8{ 0xa2, 0x62, 'i', 'd', 0x01, 0x64, 'm', 'e', 't', 'a' };
    const cases = [_]struct { meta: []const u8, err: anyerror }{
        .{ .meta = &.{ 0xa1, 0x01, 0x01 }, .err = error.BadMeta }, // an integer key
        .{ .meta = &.{ 0xa1, 0x61, 'k', 0xa0 }, .err = error.BadMeta }, // a map value
        .{ .meta = &.{ 0xa1, 0x61, 'k', 0x81, 0x81, 0x01 }, .err = error.BadMeta }, // an array in an array
        .{ .meta = &.{ 0xa1, 0x61, 'k', 0xf9, 0x7e, 0x00 }, .err = error.BadMeta }, // NaN
        .{ .meta = &.{0x01}, .err = error.BadMeta }, // not a map
        .{ .meta = &.{ 0xa1, 0x61, 'k', 0x1b }, .err = error.UnexpectedEndOfInput }, // the read's own error comes first
    };
    for (cases) |case| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(allocator);
        try input.appendSlice(allocator, &head);
        try input.appendSlice(allocator, case.meta);
        // The owned copy of a refused item is not leaked: the testing allocator checks.
        try std.testing.expectError(case.err, zerde.cbor.parseSlice(Profiled, allocator, input.items));
        try std.testing.expectError(case.err, zerde.cbor.parseSliceAliasedWith(Profiled, allocator, input.items, .{}, .{}));
    }

    // In an optional and in the elements of an array.
    const with_maybe = [_]u8{0xa3} ++ head[1..].* ++ [_]u8{ 0xa0, 0x65, 'm', 'a', 'y', 'b', 'e', 0xa1, 0x01, 0x01 };
    try std.testing.expectError(error.BadMeta, zerde.cbor.parseSlice(Profiled, allocator, &with_maybe));
    const with_all = [_]u8{0xa3} ++ head[1..].* ++ [_]u8{ 0xa0, 0x63, 'a', 'l', 'l', 0x82, 0xa0, 0xa1, 0x01, 0x01 };
    try std.testing.expectError(error.BadMeta, zerde.cbor.parseSlice(Profiled, allocator, &with_all));
    const all_ok = [_]u8{0xa3} ++ head[1..].* ++ [_]u8{ 0xa0, 0x63, 'a', 'l', 'l', 0x82, 0xa0, 0xa1, 0x61, 'a', 0x01 };
    const ok = try zerde.cbor.parseSlice(Profiled, allocator, &all_ok);
    defer zerde.free(allocator, ok);
    try std.testing.expectEqual(@as(usize, 2), ok.all.len);

    // JSON.
    const j = try zerde.json.parseSlice(ProfiledJson, allocator, "{\"id\":1,\"meta\":{\"k\":1,\"l\":[2.5,\"x\"]}}");
    defer zerde.free(allocator, j);
    try std.testing.expectError(error.BadMeta, zerde.json.parseSlice(ProfiledJson, allocator, "{\"id\":1,\"meta\":{\"k\":{}}}"));
    try std.testing.expectError(error.BadMeta, zerde.json.parseSlice(ProfiledJson, allocator, "{\"id\":1,\"meta\":[1]}"));
    try std.testing.expectError(error.UnexpectedEndOfInput, zerde.json.parseSlice(ProfiledJson, allocator, "{\"id\":1,\"meta\":{\"k\":"));
}

// ---- fixed-layout wire types generated from a schema ------------------------------------------------------

const wire = zerde.wire;

const WireLevel = enum(u8) { low = 1, high = 7 };

const WireRecord = struct {
    key: zerde.ByteString,
    kind: []const u8,
    revision: u64,
    meta: []const u8,
    note: ?zerde.ByteString = null,
    level: WireLevel,
    ratio: f32,
    flag: bool,
    pub const serde = .{
        .deny_unknown_fields = true,
        .enum_repr = .integer,
        .fields = .{
            .key = .{ .max_len = 8 },
            .kind = .{ .min_len = 1, .max_len = 16 },
            .meta = .{ .max_len = 16 },
            .note = .{ .optional = .absent, .max_len = 8 },
        },
    };
};

const WireEffect = union(enum) {
    put: WireRecord,
    delete: zerde.ByteString,
    noop,
};

const WireMsg = struct {
    id: [4]u8,
    effects: []const WireEffect,
    grid: []const []const u16,
    pair: [2]u16,
    first: ?WireEffect = null,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{
        .effects = .{ .max_len = 4 },
        .grid = .{ .max_len = 3, .elem = .{ .max_len = 4 } },
        .first = .{ .optional = .absent },
    } };
};

/// The limits `WireMsg` needs for an arena bound: its bytes are bounded by field, strings by the config.
const wire_read_cfg = .{ .max_string_len = 64, .max_items = 256 };

/// A region that holds the input and the arena, so every span is an offset into it from its start.
const Region = struct {
    bytes: [16384]u8 align(16) = undefined,
    parts: [1][]const u8 = undefined,

    fn base(self: *Region) usize {
        return @intFromPtr(&self.bytes);
    }

    fn memory(self: *Region) wire.Memory {
        self.parts[0] = &self.bytes;
        return .{ .base = self.base(), .regions = &self.parts };
    }
};

fn sampleMsg() WireMsg {
    const efs = [_]WireEffect{
        .{ .put = .{ .key = .{ .bytes = "k1" }, .kind = "note", .revision = 9, .meta = "m", .note = .{ .bytes = "n" }, .level = .high, .ratio = 0.5, .flag = true } },
        .{ .delete = .{ .bytes = "gone" } },
        .noop,
        .{ .put = .{ .key = .{ .bytes = "k2" }, .kind = "x", .revision = 1, .meta = "m", .note = null, .level = .low, .ratio = -1, .flag = false } },
    };
    const grid = [_][]const u16{ &.{ 1, 2 }, &.{}, &.{3} };
    return .{ .id = .{ 1, 2, 3, 4 }, .effects = &efs, .grid = &grid, .pair = .{ 5, 6 }, .first = .noop };
}

test "a wire type has the layout of C, and describe says where every member is" {
    const W = wire.Wire(WireMsg);
    const node = comptime wire.describe(WireMsg, .{});
    try std.testing.expectEqual(@as(usize, @sizeOf(W)), node.size);
    try std.testing.expectEqual(@as(usize, @offsetOf(W, "effects")), node.members[1].offset);
    try std.testing.expectEqual(@as(usize, @offsetOf(W, "pair")), node.members[3].offset);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(wire.Span));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(wire.Span, "len"));
    // The union: tag at 0 and the payload after it.
    const Effect = wire.Wire(WireEffect);
    const effect = comptime wire.describe(WireEffect, .{});
    try std.testing.expectEqual(@as(usize, @offsetOf(Effect, "payload")), effect.value_offset);
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Effect, "tag"));
    try std.testing.expectEqual(@as(usize, 3), effect.members.len);
    try std.testing.expectEqual(@as(usize, 0), effect.members[2].node.size);
    try std.testing.expectEqualStrings("delete", effect.members[1].wire.text);
    // An optional is a presence byte, then the value.
    const opt = comptime wire.describe(?u32, .{});
    try std.testing.expectEqual(@as(usize, 4), opt.value_offset);
    try std.testing.expectEqual(@as(usize, 8), opt.size);
    // A union with no payload at all still has a payload member, so tag and payload are always there.
    const Bare = union(enum) { a, b };
    try std.testing.expect(@hasField(wire.Wire(Bare), "payload"));
}

test "an enum is an integer of a width an extern struct accepts, whatever its tag type is" {
    // enum { a, b, c } has the tag type u2, which an extern struct refuses; negative values are signed.
    const Small = enum { a, b, c };
    const Neg = enum(i16) { down = -3, up = 5 };
    const Wide = enum(u32) { big = 70000 };
    const Holder = struct { s: Small, n: Neg, w: Wide, count: u32 };
    try std.testing.expect(wire.Wire(Small) == u8);
    try std.testing.expect(wire.Wire(Neg) == i8);
    try std.testing.expect(wire.Wire(Wide) == u32);
    const node = comptime wire.describe(Holder, .{});
    try std.testing.expectEqual(@as(usize, 4), node.members[3].offset - node.members[2].offset);
    var arena_buffer: [256]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&arena_buffer);
    var region: Region = .{};
    const mem = region.memory();
    const w = try wire.toWire(Holder, arena.allocator(), mem.base, .{ .s = .c, .n = .down, .w = .big, .count = 1 });
    try std.testing.expectEqual(@as(u8, 2), w.s);
    try std.testing.expectEqual(@as(i8, -3), w.n);
    const back = try wire.fromWire(Holder, arena.allocator(), mem, w);
    try std.testing.expectEqual(Small.c, back.s);
    try std.testing.expectEqual(Neg.down, back.n);
    // A value that is no variant, including one that does not fit the tag type.
    var bad = w;
    bad.s = 3;
    try std.testing.expectError(error.InvalidTag, wire.fromWire(Holder, arena.allocator(), mem, bad));
    // 4 does not fit the two bits of Small's tag type, though its low bits name a variant.
    bad = w;
    bad.s = 4;
    try std.testing.expectError(error.InvalidTag, wire.fromWire(Holder, arena.allocator(), mem, bad));
    bad = w;
    bad.n = 100;
    try std.testing.expectError(error.InvalidTag, wire.fromWire(Holder, arena.allocator(), mem, bad));
}

fn expectSampleDecoded(mem: wire.Memory, w: wire.Wire(WireMsg)) !void {
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &w.id);
    try std.testing.expectEqual(@as([2]u16, .{ 5, 6 }), w.pair);
    try std.testing.expectEqual(@as(u8, 1), w.first.present);
    try std.testing.expectEqual(@as(u8, 2), w.first.value.tag);
    // The effects span points at four contiguous wire effects.
    try std.testing.expectEqual(@as(u32, 4), w.effects.len);
    const Effect = wire.Wire(WireEffect);
    const effects = try mem.listOf(Effect, w.effects);
    try std.testing.expectEqual(@as(u8, 0), effects[0].tag);
    const put = effects[0].payload.put;
    try std.testing.expectEqualStrings("k1", try mem.bytesOf(put.key));
    try std.testing.expectEqualStrings("note", try mem.bytesOf(put.kind));
    try std.testing.expectEqual(@as(u64, 9), put.revision);
    try std.testing.expectEqualStrings("m", try mem.bytesOf(put.meta));
    try std.testing.expectEqual(@as(u8, 1), put.note.present);
    try std.testing.expectEqualStrings("n", try mem.bytesOf(put.note.value));
    try std.testing.expectEqual(@as(u8, 7), put.level);
    try std.testing.expectEqual(@as(f32, 0.5), put.ratio);
    try std.testing.expect(put.flag);
    try std.testing.expectEqual(@as(u8, 1), effects[1].tag);
    try std.testing.expectEqualStrings("gone", try mem.bytesOf(effects[1].payload.delete));
    try std.testing.expectEqual(@as(u8, 2), effects[2].tag);
    try std.testing.expectEqual(@as(u8, 0), effects[3].payload.put.note.present);
    try std.testing.expectEqual(@as(f32, -1), effects[3].payload.put.ratio);
    // Arrays of arrays: spans of spans.
    try std.testing.expectEqual(@as(u32, 3), w.grid.len);
    const grid = try mem.listOf(wire.Span, w.grid);
    try std.testing.expectEqual(@as(u32, 2), grid[0].len);
    try std.testing.expectEqual(@as(u32, 0), grid[1].len);
    const inner = try mem.listOf(u16, grid[0]);
    try std.testing.expectEqual(@as(u16, 2), inner[1]);
}

test "a message decodes into its wire layout, in CBOR and in JSON, and encodes back to the same bytes" {
    const msg = sampleMsg();
    inline for (.{ zerde.cbor, zerde.json }) |Format| {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const write_cfg = if (Format == zerde.cbor) .{ .deterministic = true } else .{};
        try zerde.serializeWith(Format, &out.writer, msg, .{}, write_cfg);
        var region: Region = .{};
        const len = out.written().len;
        @memcpy(region.bytes[0..len], out.written());
        var arena = std.heap.FixedBufferAllocator.init(region.bytes[len..]);
        const read_cfg = if (Format == zerde.cbor) .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 64, .max_items = 256 } else wire_read_cfg;
        const w = try wire.decode(Format, WireMsg, &arena, region.base(), region.bytes[0..len], .{}, read_cfg);
        const mem = region.memory();
        try expectSampleDecoded(mem, w);

        // And back: the same bytes.
        var again: std.Io.Writer.Allocating = .init(allocator);
        defer again.deinit();
        var scratch: [4096]u8 = undefined;
        var scratch_arena = std.heap.FixedBufferAllocator.init(&scratch);
        try wire.encode(Format, WireMsg, &scratch_arena, mem, w, &again.writer, .{}, write_cfg);
        try std.testing.expectEqualSlices(u8, out.written(), again.written());
        // The scratch arena is put back.
        try std.testing.expectEqual(@as(usize, 0), scratch_arena.end_index);
    }
}

fn repeatText(w: *std.Io.Writer, text: []const u8, count: usize) !void {
    for (0..count) |_| try w.writeAll(text);
}

test "the arena bound holds for the worst input, escapes and all, and a decode puts the arena back on an error" {
    const bound = comptime wire.maxArenaSize(WireMsg, .{}, wire_read_cfg);
    // Four put effects with the longest strings the bounds allow, escaped in JSON so each is copied.
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    const w = &json.writer;
    try w.writeAll("{\"id\":\"abcd\",\"effects\":[");
    for (0..4) |index| {
        if (index != 0) try w.writeAll(",");
        try w.writeAll("{\"put\":{\"key\":\"");
        try repeatText(w, "\\n", 4);
        try w.writeAll("\",\"kind\":\"");
        try repeatText(w, "\\t", 8);
        try w.writeAll("\",\"revision\":1,\"meta\":\"");
        try repeatText(w, "\\n", 8);
        try w.writeAll("\",\"note\":\"");
        try repeatText(w, "\\r", 4);
        try w.writeAll("\",\"level\":7,\"ratio\":1.5,\"flag\":true}}");
    }
    try w.writeAll("],\"grid\":[[1,2,3,4],[1,2,3,4],[1,2,3,4]],\"pair\":[1,2],\"first\":{\"put\":{\"key\":\"a\",\"kind\":\"b\",\"revision\":1,\"meta\":\"c\",\"level\":1,\"ratio\":0,\"flag\":false}}}");
    var region: Region = .{};
    const len = json.written().len;
    try std.testing.expect(len + bound < region.bytes.len);
    @memcpy(region.bytes[0..len], json.written());
    // Exactly the bound is enough.
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[len..][0..bound]);
    const decoded = try wire.decode(zerde.json, WireMsg, &arena, region.base(), region.bytes[0..len], .{}, wire_read_cfg);
    try std.testing.expectEqual(@as(u32, 4), decoded.effects.len);
    try std.testing.expect(arena.end_index <= bound);
    // The escaped strings are in the arena, not the input, and the whole of it is reachable through the memory.
    const effects = try region.memory().listOf(wire.Wire(WireEffect), decoded.effects);
    const key = try region.memory().bytesOf(effects[0].payload.put.key);
    try std.testing.expectEqualStrings("\n\n\n\n", key);
    try std.testing.expect(@intFromPtr(key.ptr) >= @intFromPtr(&region.bytes[len]));

    // A failed decode leaves the arena as it found it.
    arena.reset();
    _ = try arena.allocator().alloc(u8, 8);
    const before = arena.end_index;
    try std.testing.expectError(error.LengthOutOfBounds, wire.decode(zerde.json, WireMsg, &arena, region.base(), "{\"id\":\"abcd\",\"effects\":[\"noop\",\"noop\",\"noop\",\"noop\",\"noop\"],\"grid\":[],\"pair\":[1,2]}", .{}, wire_read_cfg));
    try std.testing.expectEqual(before, arena.end_index);
}

test "a list of scalars is not copied into the wire layout" {
    const Scalars = struct {
        xs: []const u32,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .xs = .{ .max_len = 100 } } };
    };
    var region: Region = .{};
    const input = "{\"xs\":[1,2,3]}";
    @memcpy(region.bytes[0..input.len], input);
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[input.len..]);
    const w = try wire.decode(zerde.json, Scalars, &arena, region.base(), region.bytes[0..input.len], .{}, .{});
    // The span points at the array the typed read made, and nothing else was allocated for it.
    const xs = try region.memory().listOf(u32, w.xs);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, xs);
    // The conversions copy nothing for it, either way.
    const values = [_]u32{ 4, 5, 6 };
    var scratch: [64]u8 align(16) = undefined;
    var none = std.heap.FixedBufferAllocator.init(&scratch);
    const span = try wire.toWire([]const u32, none.allocator(), @intFromPtr(&values), &values);
    try std.testing.expectEqual(wire.Span{ .offset = 0, .len = 3 }, span);
    const back = try wire.fromWire([]const u32, none.allocator(), .{ .base = @intFromPtr(&values), .regions = &.{std.mem.sliceAsBytes(&values)} }, span);
    try std.testing.expectEqual(@intFromPtr(&values), @intFromPtr(back.ptr));
    try std.testing.expectEqual(@as(usize, 0), none.end_index);
    // And the arena bound counts only the typed array: (3 * n + 64) * size + 40 * alignment, and the slack.
    try std.testing.expectEqual(@as(usize, (3 * 100 + 64) * 4 + 40 * 4 + 256), wire.maxArenaSize(Scalars, .{}, .{}));
}

test "a wire value from outside is not trusted: spans outside the memory or misaligned are refused" {
    var region: Region = .{};
    var other: [64]u8 align(16) = undefined;
    const mem = region.memory();
    var arena_buffer: [1024]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&arena_buffer);
    const Effect = wire.Wire(WireEffect);
    const Holder = struct { xs: []const u32, names: []const []const u8 };
    const HolderWire = wire.Wire(Holder);
    // Inside the region, aligned: fine.
    @memcpy(region.bytes[0..4], &[4]u8{ 1, 0, 0, 0 });
    var w = std.mem.zeroes(HolderWire);
    w.xs = .{ .offset = 0, .len = 1 };
    try std.testing.expectEqualSlices(u32, &.{1}, (try wire.fromWire(Holder, arena.allocator(), mem, w)).xs);
    // Past the end, before the start, misaligned, and a sum that overflows.
    w.xs = .{ .offset = region.bytes.len - 2, .len = 1 };
    try std.testing.expectError(error.OffsetOutOfRange, wire.fromWire(Holder, arena.allocator(), mem, w));
    w.xs = .{ .offset = 2, .len = 1 };
    try std.testing.expectError(error.OffsetOutOfRange, wire.fromWire(Holder, arena.allocator(), mem, w));
    w.xs = .{ .offset = std.math.maxInt(u32), .len = std.math.maxInt(u32) };
    try std.testing.expectError(error.OffsetOutOfRange, wire.fromWire(Holder, arena.allocator(), mem, w));
    const low_mem: wire.Memory = .{ .base = mem.base -% 1, .regions = mem.regions };
    w.xs = .{ .offset = 0, .len = 1 };
    try std.testing.expectError(error.OffsetOutOfRange, wire.fromWire(Holder, arena.allocator(), low_mem, w));
    // Before the start of the region is refused for bytes too, which have no alignment to refuse it.
    try std.testing.expectError(error.OffsetOutOfRange, low_mem.bytesOf(.{ .offset = 0, .len = 1 }));
    try std.testing.expectEqual(@as(usize, 1), (try mem.bytesOf(.{ .offset = 0, .len = 1 })).len);
    // Memory the caller did not name is refused even when it is real.
    const outside: wire.Memory = .{ .base = @intFromPtr(&other), .regions = mem.regions };
    try std.testing.expectError(error.OffsetOutOfRange, wire.fromWire(Holder, arena.allocator(), outside, w));
    // A text span is checked the same way, and so is the span of an inner list.
    var names = std.mem.zeroes(Effect);
    _ = &names;
    w.xs = .{ .offset = 0, .len = 0 };
    w.names = .{ .offset = 4, .len = 1 };
    @memset(region.bytes[4..12], 0);
    try std.testing.expectEqual(@as(usize, 0), (try wire.fromWire(Holder, arena.allocator(), mem, w)).names[0].len);
    @memset(region.bytes[4..12], 0xff);
    try std.testing.expectError(error.OffsetOutOfRange, wire.fromWire(Holder, arena.allocator(), mem, w));
    // A tag that names nothing, an enum value and a presence byte that mean nothing.
    var bad = std.mem.zeroes(Effect);
    bad.tag = 9;
    try std.testing.expectError(error.InvalidTag, wire.fromWire(WireEffect, arena.allocator(), mem, bad));
    var level = std.mem.zeroes(wire.Wire(WireRecord));
    level.level = 99;
    try std.testing.expectError(error.InvalidTag, wire.fromWire(WireRecord, arena.allocator(), mem, level));
    var presence = std.mem.zeroes(wire.Wire(?u32));
    presence.present = 2;
    try std.testing.expectError(error.InvalidTag, wire.fromWire(?u32, arena.allocator(), mem, presence));
    presence.present = 1;
    presence.value = 5;
    try std.testing.expectEqual(@as(?u32, 5), try wire.fromWire(?u32, arena.allocator(), mem, presence));
    // A zero length is no memory: it needs no region and makes no pointer.
    const none: wire.Memory = .{ .base = 0, .regions = &.{} };
    try std.testing.expectEqual(@as(usize, 0), (try none.bytesOf(.{ .offset = 0, .len = 0 })).len);
    // spanOf and the base.
    const text = "hello";
    const span = try wire.spanOf(@intFromPtr(text), text[1..4]);
    try std.testing.expectEqual(@as(u32, 1), span.offset);
    const here: wire.Memory = .{ .base = @intFromPtr(text), .regions = &.{text} };
    try std.testing.expectEqualStrings("ell", try here.bytesOf(span));
    try std.testing.expectEqual(wire.Span{ .offset = 0, .len = 0 }, try wire.spanOf(1234, &.{}));
    try std.testing.expectError(error.OffsetOutOfRange, wire.spanOf(@intFromPtr(text) -% 0xffff_fffe, text[0..5]));
    try std.testing.expectError(error.OffsetOutOfRange, wire.spanOf(@intFromPtr(text) + 1, text));
}

test "the rules of the schema apply to a wire decode, and an offset that does not fit is an error" {
    const msg = sampleMsg();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try zerde.serializeWith(zerde.cbor, &out.writer, msg, .{}, .{ .deterministic = true });
    var region: Region = .{};
    const len = out.written().len;
    @memcpy(region.bytes[0..len], out.written());
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[len..]);
    const cfg = .{ .max_string_len = 64, .max_items = 256 };
    // A field bound refuses: five effects, at most four.
    var five: std.ArrayList(WireEffect) = .empty;
    defer five.deinit(allocator);
    for (0..5) |_| try five.append(allocator, .noop);
    var big = msg;
    big.effects = five.items;
    var big_out: std.Io.Writer.Allocating = .init(allocator);
    defer big_out.deinit();
    try zerde.serializeWith(zerde.cbor, &big_out.writer, big, .{}, .{ .deterministic = true });
    @memcpy(region.bytes[0..big_out.written().len], big_out.written());
    try std.testing.expectError(error.LengthOutOfBounds, wire.decode(zerde.cbor, WireMsg, &arena, region.base(), region.bytes[0..big_out.written().len], .{}, cfg));

    // Strict mode refuses a non-deterministic input.
    var lenient = std.ArrayList(u8).empty;
    defer lenient.deinit(allocator);
    try lenient.append(allocator, 0xbf);
    try lenient.appendSlice(allocator, out.written()[1..]);
    try lenient.append(allocator, 0xff);
    @memcpy(region.bytes[0..lenient.items.len], lenient.items);
    arena.reset();
    try std.testing.expectError(error.NonDeterministicEncoding, wire.decode(zerde.cbor, WireMsg, &arena, region.base(), region.bytes[0..lenient.items.len], .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 64, .max_items = 256 }));

    // The base: before the input is an error, and so is an offset beyond 32 bits (a native base of 0).
    @memcpy(region.bytes[0..len], out.written());
    arena.reset();
    try std.testing.expectError(error.OffsetOutOfRange, wire.decode(zerde.cbor, WireMsg, &arena, region.base() + 1_000_000, region.bytes[0..len], .{}, cfg));
    try std.testing.expectEqual(@as(usize, 0), arena.end_index);
    try std.testing.expectError(error.OffsetOutOfRange, wire.decode(zerde.cbor, WireMsg, &arena, 0, region.bytes[0..len], .{}, cfg));
    // Bytes after the message are not part of it.
    var trailing: [1024]u8 = undefined;
    @memcpy(trailing[0..len], out.written());
    trailing[len] = 0;
    try std.testing.expectError(error.TrailingCharacters, wire.decode(zerde.cbor, WireMsg, &arena, region.base(), trailing[0 .. len + 1], .{}, cfg));
}

test "a wire type read through the typed layer: Hooked, user_data and readTyped" {
    const Holder = struct {
        id: u8,
        effect: wire.Hooked(WireEffect),
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const effect = sampleMsg().effects[0];
    var enc: std.Io.Writer.Allocating = .init(allocator);
    defer enc.deinit();
    try zerde.serializeWith(zerde.cbor, &enc.writer, effect, .{}, .{ .deterministic = true });
    try out.writer.writeAll(&.{ 0xa2, 0x62, 'i', 'd', 0x03, 0x66, 'e', 'f', 'f', 'e', 'c', 't' });
    try out.writer.writeAll(enc.written());
    var region: Region = .{};
    const len = out.written().len;
    @memcpy(region.bytes[0..len], out.written());
    var fixed = std.heap.FixedBufferAllocator.init(region.bytes[len..]);
    var d = try zerde.cbor.sliceDeserializer(fixed.allocator(), region.bytes[0..len], .{});
    defer d.deinit(fixed.allocator());
    d.can_borrow_strings = true;
    d.user_data = region.base();
    const holder = try zerde.typed.deserialize(Holder, fixed.allocator(), &d, .{});
    try d.finish();
    try std.testing.expectEqual(@as(u8, 3), holder.id);
    try std.testing.expectEqual(@as(u8, 0), holder.effect.value.tag);
    try std.testing.expectEqualStrings("k1", try region.memory().bytesOf(holder.effect.value.payload.put.key));
    // Without user_data the base is 0, which a native address cannot be offset from.
    var plain = try zerde.cbor.sliceDeserializer(fixed.allocator(), region.bytes[0..len], .{});
    defer plain.deinit(fixed.allocator());
    plain.can_borrow_strings = true;
    try std.testing.expectError(error.OffsetOutOfRange, zerde.typed.deserialize(Holder, fixed.allocator(), &plain, .{}));
    // A call site's config for the inner type: HookedWith.
    const Renamed = struct { first_name: []const u8 };
    const Named = struct { person: wire.HookedWith(Renamed, .{ .rename_all = zerde.FieldCase.camelCase }) };
    var named_region: Region = .{};
    const named_input = "{\"person\":{\"firstName\":\"Ada\"}}";
    @memcpy(named_region.bytes[0..named_input.len], named_input);
    var named_arena = std.heap.FixedBufferAllocator.init(named_region.bytes[named_input.len..]);
    var named_d = try zerde.json.sliceDeserializer(named_arena.allocator(), named_region.bytes[0..named_input.len], .{});
    defer named_d.deinit(named_arena.allocator());
    named_d.can_borrow_strings = true;
    named_d.user_data = named_region.base();
    const named = try zerde.typed.deserialize(Named, named_arena.allocator(), &named_d, .{});
    try std.testing.expectEqualStrings("Ada", try named_region.memory().bytesOf(named.person.value.first_name));
    // readTyped only before the first event.
    var pull = try zerde.cbor.pullReader(allocator, enc.written(), .{});
    defer pull.deinit();
    _ = try pull.next();
    try std.testing.expectError(error.InvalidCborState, pull.readTyped(WireEffect, allocator, .{}));
    // The item is taken: the reader is done after it, in both formats.
    var taken = try zerde.cbor.pullReader(allocator, enc.written(), .{});
    defer taken.deinit();
    const typed_effect = try taken.readTyped(WireEffect, allocator, .{});
    defer zerde.free(allocator, typed_effect);
    try std.testing.expect((try taken.next()) == null);
    try std.testing.expectError(error.InvalidCborState, taken.readTyped(WireEffect, allocator, .{}));
    try taken.finish();
    var json_pull = try zerde.json.pullReader(allocator, "\"noop\"", .{});
    defer json_pull.deinit();
    _ = try json_pull.readTyped(WireEffect, allocator, .{});
    try std.testing.expect((try json_pull.next()) == null);
    try std.testing.expectError(error.InvalidJsonState, json_pull.readTyped(WireEffect, allocator, .{}));
    var json_started = try zerde.json.pullReader(allocator, "[1]", .{});
    defer json_started.deinit();
    _ = try json_started.next();
    try std.testing.expectError(error.InvalidJsonState, json_started.readTyped(WireEffect, allocator, .{}));
}

test "integer keys, a Raw and bounds in a wire type, and their keys in the description" {
    const Frame = struct {
        id: u16,
        meta: zerde.cbor.Raw,
        tags: []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .id = .{ .key = 0 }, .meta = .{ .key = 1, .max_len = 32 }, .tags = .{ .key = 2, .max_len = 3 } } };
    };
    const node = comptime wire.describe(Frame, .{});
    try std.testing.expectEqual(@as(i128, 2), @as(i128, node.members[2].wire.integer));
    try std.testing.expectEqual(zerde.reflect.Kind.raw, node.members[1].node.kind);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try zerde.serializeWith(zerde.cbor, &out.writer, Frame{ .id = 7, .meta = .{ .bytes = &.{ 0xa1, 0x61, 'k', 0x01 } }, .tags = "ab" }, .{}, .{ .deterministic = true });
    var region: Region = .{};
    const len = out.written().len;
    @memcpy(region.bytes[0..len], out.written());
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[len..]);
    const cfg = .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 32 };
    const w = try wire.decode(zerde.cbor, Frame, &arena, region.base(), region.bytes[0..len], .{}, cfg);
    try std.testing.expectEqual(@as(u16, 7), w.id);
    const meta_bytes = try region.memory().bytesOf(w.meta);
    try std.testing.expectEqualSlices(u8, &.{ 0xa1, 0x61, 'k', 0x01 }, meta_bytes);
    // The raw span is the very bytes of the input: no copy, and the arena holds nothing for it.
    try std.testing.expect(@intFromPtr(meta_bytes.ptr) >= region.base() and @intFromPtr(meta_bytes.ptr) < region.base() + len);
    try std.testing.expectError(error.LengthOutOfBounds, wire.decode(zerde.cbor, Frame, &arena, region.base(), &.{ 0xa3, 0x00, 0x01, 0x01, 0xa0, 0x02, 0x64, 'a', 'b', 'c', 'd' }, .{}, cfg));
    try std.testing.expect(wire.maxArenaSize(Frame, .{}, cfg) > 0);
}
