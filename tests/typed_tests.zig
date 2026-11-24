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

const JsonMetaBox = struct { meta: zerde.json.Raw };

test "a json.Raw refuses a member that an object of its item names twice, at any depth and however it is spelled" {
    const refused = [_][]const u8{
        "{\"meta\":{\"a\":1,\"a\":2}}",
        "{\"meta\":{\"a\":{\"b\":1},\"c\":{\"d\":[{\"e\":1,\"f\":2,\"e\":3}]}}}",
        "{\"meta\":[1,{\"k\":{},\"k\":{}}]}",
        "{\"meta\":{\"\":1,\"\":2}}",
        // The same text spelled differently: an escape of a plain letter, of a control character, of a code point and a surrogate pair.
        "{\"meta\":{\"a\":1,\"\\u0061\":2}}",
        "{\"meta\":{\"\\n\":1,\"\\u000a\":2}}",
        "{\"meta\":{\"\\/\":1,\"/\":2}}",
        "{\"meta\":{\"caf\\u00e9\":1,\"caf\xc3\xa9\":2}}",
        "{\"meta\":{\"\\ud83d\\ude00\":1,\"\xf0\x9f\x98\x80\":2}}",
        "{\"meta\":{\"x\\ud83d\\ude00y\":1,\"x\\uD83D\\uDE00y\":2}}",
        // Not neighbours in the input.
        "{\"meta\":{\"a\":1,\"b\":2,\"c\":3,\"\\u0061\":4}}",
    };
    for (refused) |input| try expectJsonError(JsonMetaBox, error.DuplicateField, input);

    // The same names in different objects, names that only share a prefix or differ in case, and names that decode to different text
    // however they are spelled, are taken, and the item is the text it was read from.
    const taken = [_][]const u8{
        "{\"a\":{\"a\":1},\"b\":{\"a\":1}}",
        "{\"a\":1,\"aa\":2,\"A\":3,\"b\":{\"a\":1,\"aa\":{\"a\":0}}}",
        "[{\"a\":1},{\"a\":2}]",
        "{\"ab\":1,\"a\\u0062c\":2,\"\\u0061b\\u0063\\u0064\":3}",
        "{\"\\ud83d\\ude00\":1,\"\\ud83d\\ude01\":2,\"\xf0\x9f\x98\x80\xf0\x9f\x98\x80\":3}",
        "{\"\\n\":1,\"\\\\n\":2,\"n\":3}",
    };
    for (taken) |item| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try text.print(allocator, "{{\"meta\":{s}}}", .{item});
        const parsed = try zerde.json.parseSlice(JsonMetaBox, allocator, text.items);
        defer allocator.free(parsed.meta.bytes);
        try std.testing.expectEqualStrings(item, parsed.meta.bytes);
    }
    // A repeat after an item that had none is found: the names of the first item do not take part.
    try expectJsonError(struct { first: zerde.json.Raw, second: zerde.json.Raw }, error.DuplicateField, "{\"first\":{\"a\":1},\"second\":{\"a\":1,\"a\":1}}");
    // The pull reader's `raw` is the same read.
    var pull = try zerde.json.pullReader(allocator, "{\"a\":1,\"\\u0061\":2}", .{});
    defer pull.deinit();
    try std.testing.expectError(error.DuplicateField, pull.raw());
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
// ---- a strict read finds a repeated key by its neighbour and keeps no record -------------------------------

const RawHolder = struct { r: zerde.cbor.Raw, a: ?u8 = null };

/// `{"r": <raw>}` read strict.
fn strictRaw(raw: []const u8) !RawHolder {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xa1, 0x61, 'r' });
    try input.appendSlice(allocator, raw);
    return zerde.cbor.parseSliceAliasedWith(RawHolder, allocator, input.items, .{}, strict);
}

test "a strict read allocates nothing to check keys: text, integer, byte and unknown keys, in a Raw and in a skipped value" {
    // {1: 0, "a": 1, "b": {1: 0, 2: 0, "k": 0}, "r": {-1: 0, h'61': 0}} in deterministic order.
    const input = [_]u8{ 0xa4, 0x01, 0x00, 0x61, 'a', 0x01, 0x61, 'b', 0xa3, 0x01, 0x00, 0x02, 0x00, 0x61, 'k', 0x00, 0x61, 'r', 0xa2, 0x20, 0x00, 0x41, 0x61, 0x00 };
    var none = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const got = try zerde.cbor.parseSliceAliasedWith(RawHolder, none.allocator(), &input, .{}, strict);
    try std.testing.expectEqual(@as(?u8, 1), got.a);
    try std.testing.expectEqualSlices(u8, input[18..], got.r.bytes);
    // The lenient read records the keys, which is what it spends the allocation on.
    var some = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, zerde.cbor.parseSliceAliasedWith(RawHolder, some.allocator(), &input, .{}, .{}));
}

test "a strict read refuses a repeated key as its neighbour, in every place a map is read" {
    // A key no field declares, a key in a skipped value, a key in a Raw, a dynamic value, a pull reader.
    try expectStrict(Probe, error.DuplicateField, &.{ 0xa2, 0x61, 'x', 0x00, 0x61, 'x', 0x01 });
    try expectStrict(Probe, error.DuplicateField, &.{ 0xa1, 0x61, 'z', 0xa2, 0x01, 0x00, 0x01, 0x00 });
    try std.testing.expectError(error.DuplicateField, strictRaw(&.{ 0xa3, 0x61, 'x', 0x00, 0x61, 'y', 0x00, 0x61, 'y', 0x01 }));
    try std.testing.expectError(error.DuplicateField, zerde.value.parseSliceWith(zerde.cbor, allocator, &.{ 0xa2, 0x61, 'x', 0x00, 0x61, 'x', 0x01 }, strict));
    var pull = try zerde.cbor.pullReader(allocator, &.{ 0xa2, 0x61, 'x', 0x00, 0x61, 'x', 0x01 }, strict);
    defer pull.deinit();
    var failed = false;
    while (pull.next()) |event| {
        if (event == null) break;
    } else |err| {
        try std.testing.expectEqual(error.DuplicateField, err);
        failed = true;
    }
    try std.testing.expect(failed);
    // Different keys are fine, and equal keys in different maps are not repeats.
    _ = try strictRaw(&.{ 0xa2, 0x61, 'x', 0xa1, 0x61, 'k', 0x00, 0x61, 'y', 0xa1, 0x61, 'k', 0x00 });
}

test "a strict read keeps 0.0 and -0.0 one key though their encodings are not neighbours (RFC 8949 section 5.6.1)" {
    const zero = [_]u8{ 0xf9, 0x00, 0x00 };
    const small = [_]u8{ 0xf9, 0x00, 0x01 };
    const minus = [_]u8{ 0xf9, 0x80, 0x00 };
    // 0.0, the smallest subnormal and -0.0 sort in this order, so the zeros are not neighbours.
    const apart = [_]u8{0xa3} ++ zero ++ [_]u8{0x00} ++ small ++ [_]u8{0x00} ++ minus ++ [_]u8{0x00};
    try expectStrict(Probe, error.DuplicateField, &apart);
    try expectStrict(Probe, error.DuplicateField, &([_]u8{0xa2} ++ zero ++ [_]u8{0x00} ++ minus ++ [_]u8{0x00}));
    // In a skipped value, in a Raw, and in a pull reader.
    try expectStrict(Probe, error.DuplicateField, &([_]u8{ 0xa1, 0x61, 'z' } ++ apart));
    try std.testing.expectError(error.DuplicateField, strictRaw(&apart));
    // Either alone is a key, with or without the subnormal.
    _ = try strictRaw(&([_]u8{0xa2} ++ zero ++ [_]u8{0x00} ++ small ++ [_]u8{0x00}));
    _ = try strictRaw(&([_]u8{0xa2} ++ small ++ [_]u8{0x00} ++ minus ++ [_]u8{0x00}));
    _ = try strictRaw(&([_]u8{0xa1} ++ minus ++ [_]u8{0x00}));
    // A deterministic write puts out a Raw only if a strict read takes it.
    const bad = RawHolder{ .r = .{ .bytes = &apart } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.DuplicateField, zerde.serializeWith(zerde.cbor, &out.writer, bad, .{}, .{ .deterministic = true }));
}

test "a strict read refuses a composite key that holds a float zero, and takes any other composite key" {
    // The one case where equality of keys is not equality of bytes, so the check without records cannot tell.
    const E = error.NonDeterministicEncoding;
    try std.testing.expectError(E, strictRaw(&.{ 0xa1, 0x81, 0xf9, 0x00, 0x00, 0x00 })); // {[0.0]: 0}
    try std.testing.expectError(E, strictRaw(&.{ 0xa1, 0x81, 0xf9, 0x80, 0x00, 0x00 })); // {[-0.0]: 0}
    try std.testing.expectError(E, strictRaw(&.{ 0xa1, 0xa1, 0x01, 0xf9, 0x00, 0x00, 0x00 })); // {{1: 0.0}: 0}
    try std.testing.expectError(E, strictRaw(&.{ 0xa1, 0xa1, 0xf9, 0x00, 0x00, 0x01, 0x00 })); // {{0.0: 1}: 0}
    // A zero before a composite key inside the key is still inside it: {[0.0, {[1]: 2}]: 0}.
    try std.testing.expectError(E, strictRaw(&.{ 0xa1, 0x82, 0xf9, 0x00, 0x00, 0xa1, 0x81, 0x01, 0x02, 0x00 }));
    // The same key twice is a repeat, as its neighbour.
    try std.testing.expectError(error.DuplicateField, strictRaw(&.{ 0xa2, 0x81, 0x01, 0x00, 0x81, 0x01, 0x01 }));
    // Composite keys without a zero, and a zero in a value, are fine: no record is kept for them.
    var none = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xa1, 0x61, 'r', 0xa3, 0x81, 0x01, 0x00, 0x81, 0x02, 0x81, 0xf9, 0x00, 0x00, 0xa1, 0x01, 0x02, 0x00 });
    const got = try zerde.cbor.parseSliceAliasedWith(RawHolder, none.allocator(), input.items, .{}, strict);
    try std.testing.expectEqual(@as(usize, 14), got.r.bytes.len);
    // Lenient is not narrower: [0.0] and [-0.0] are the same key there.
    try expectCborError(Probe, error.DuplicateField, &.{ 0xa2, 0x81, 0xf9, 0x00, 0x00, 0x00, 0x81, 0xf9, 0x80, 0x00, 0x00 });
    // The write-side check of a deterministic Raw is the same rule: a composite key with a zero is refused.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const holder = RawHolder{ .r = .{ .bytes = &.{ 0xa1, 0x81, 0xf9, 0x00, 0x00, 0x00 } } };
    try std.testing.expectError(E, zerde.serializeWith(zerde.cbor, &out.writer, holder, .{}, .{ .deterministic = true }));
    // Without the zero it is written.
    const fine = RawHolder{ .r = .{ .bytes = &.{ 0xa1, 0x81, 0x01, 0x00 } } };
    try zerde.serializeWith(zerde.cbor, &out.writer, fine, .{}, .{ .deterministic = true });
}

// ---- canonicalizeInto, the deterministic form into caller buffers ------------------------------------------------

/// `canonicalizeInto` with buffers of exactly the sizes it documents, and `canonicalize` to compare with.
fn expectCanonicalInto(input: []const u8) !void {
    const expected = try zerde.cbor.canonicalize(allocator, input);
    defer allocator.free(expected);
    var dst: [4096]u8 = undefined;
    var scratch: [zerde.cbor.canonicalScratchSize(64)]u8 = undefined;
    const got = try zerde.cbor.canonicalizeInto(dst[0..input.len], &scratch, input);
    try std.testing.expectEqualSlices(u8, expected, got);
    // And it is what a strict read takes, which is its point.
    var again = try zerde.cbor.pullReader(allocator, got, strict);
    defer again.deinit();
    while (try again.next()) |_| {}
    try again.finish();
}

fn canonicalError(expected: anyerror, input: []const u8) !void {
    var dst: [4096]u8 = undefined;
    var scratch: [zerde.cbor.canonicalScratchSize(64)]u8 = undefined;
    try std.testing.expectError(expected, zerde.cbor.canonicalizeInto(dst[0..@min(input.len, dst.len)], &scratch, input));
}

test "canonicalizeInto gives what canonicalize gives, for items in every spelling" {
    // Scalars: non-minimal heads, floats in every width, simple values.
    try expectCanonicalInto(&.{ 0x18, 0x05 });
    try expectCanonicalInto(&.{ 0x19, 0x00, 0x20 });
    try expectCanonicalInto(&.{ 0x3b, 0, 0, 0, 0, 0, 0, 0, 0x04 });
    try expectCanonicalInto(&.{ 0xfb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0 });
    try expectCanonicalInto(&.{ 0xfa, 0x7f, 0xc0, 0, 0 });
    try expectCanonicalInto(&.{ 0xfa, 0x47, 0xc3, 0x50, 0x00 });
    try expectCanonicalInto(&.{0xf6});
    // A simple value in two bytes stays; the pull reader has no event for it, so only the form is compared.
    var simple: [4]u8 = undefined;
    var none: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0xf8, 0xff }, try zerde.cbor.canonicalizeInto(&simple, &none, &.{ 0xf8, 0xff }));
    // Strings in chunks, and the empty ones.
    try expectCanonicalInto(&.{ 0x7f, 0x61, 'a', 0x60, 0x62, 'b', 'c', 0xff });
    try expectCanonicalInto(&.{ 0x5f, 0x41, 1, 0x40, 0x42, 2, 3, 0xff });
    try expectCanonicalInto(&.{ 0x7f, 0xff });
    // An indefinite array and map nested in a definite one, keys in a scrambled order and in mixed spellings.
    try expectCanonicalInto(&.{ 0x9f, 0xbf, 0x62, 'b', 'b', 0x01, 0x61, 'z', 0x02, 0x18, 0x07, 0x03, 0x01, 0x04, 0x7f, 0x61, 'k', 0xff, 0x05, 0xff, 0xa1, 0x41, 0x61, 0x80, 0xff });
    try expectCanonicalInto(&.{ 0xa3, 0x61, 'b', 0x01, 0x20, 0x02, 0x0a, 0x03 });
    try expectCanonicalInto(&.{ 0xa4, 0xf5, 0x00, 0xf4, 0x01, 0xf6, 0x02, 0xf9, 0x3c, 0x00, 0x03 });
    // Keys that differ only in a long common prefix, and one that is a prefix of another.
    try expectCanonicalInto(&.{ 0xa3, 0x63, 'a', 'b', 'd', 0x00, 0x63, 'a', 'b', 'c', 0x01, 0x62, 'a', 'b', 0x02 });
    // The same key spelled chunked and plain is one key; chunked keys in two spellings of different strings are two.
    try expectCanonicalInto(&.{ 0xa2, 0x7f, 0x61, 'a', 0x61, 'c', 0xff, 0x00, 0x7f, 0x62, 'a', 'b', 0xff, 0x01 });
    // A float key beside an integer key, and 0.0 and 1.0 in different widths.
    try expectCanonicalInto(&.{ 0xa3, 0xfa, 0x3f, 0x80, 0, 0, 0x00, 0xf9, 0x00, 0x00, 0x01, 0x01, 0x02 });
    // Real items: the corpus files, written with indefinite maps in declaration order, come out in the deterministic form.
    inline for (.{ "object_nested.cbor", "object_array.cbor", "object_integer_keys.cbor", "mixed_scalars.cbor", "union_struct_payload.cbor", "object_optional_patch_value.cbor", "float.cbor" }) |name| {
        try expectCanonicalInto(@embedFile("corpus/cbor/" ++ name));
    }
}

test "canonicalizeInto moves the items of an indefinite array up when their count needs a longer head" {
    // 30 items: a head of two bytes; 300: three. Nested, so the inner shift happens inside the outer one.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.append(allocator, 0x9f);
    for (0..30) |index| try input.append(allocator, @intCast(index % 20));
    try input.append(allocator, 0x9f);
    for (0..300) |_| try input.append(allocator, 0x01);
    try input.appendSlice(allocator, &.{ 0xff, 0xff });
    const expected = try zerde.cbor.canonicalize(allocator, input.items);
    defer allocator.free(expected);
    var dst: [1024]u8 = undefined;
    var scratch: [8]u8 = undefined;
    const got = try zerde.cbor.canonicalizeInto(&dst, &scratch, input.items);
    try std.testing.expectEqualSlices(u8, expected, got);
    try std.testing.expectEqual(@as(u8, 0x98), got[0]);
    try std.testing.expectEqual(@as(u8, 31), got[1]);
    // The head of the inner array is three bytes (0x99 and 300).
    try std.testing.expectEqualSlices(u8, &.{ 0x99, 0x01, 0x2c }, got[2 + 30 ..][0..3]);
    // Not enough room for the move is an error and not an overrun.
    try std.testing.expectError(error.NoSpaceLeft, zerde.cbor.canonicalizeInto(dst[0 .. expected.len - 1], &scratch, input.items));
}

test "canonicalizeInto refuses what canonicalize refuses, and a map key that is an array or a map" {
    try canonicalError(error.UnexpectedTag, &.{ 0xc1, 0x01 });
    try canonicalError(error.UnexpectedTag, &.{ 0xa1, 0x01, 0xc1, 0x01 });
    try canonicalError(error.InvalidUtf8, &.{ 0x62, 0xc3, 0x28 });
    try canonicalError(error.InvalidUtf8, &.{ 0xa1, 0x62, 0xc3, 0x28, 0x00 });
    try canonicalError(error.InvalidUtf8, &.{ 0x7f, 0x61, 'a', 0x61, 0xff, 0xff });
    try canonicalError(error.InvalidStringChunk, &.{ 0x7f, 0x41, 'a', 0xff });
    try canonicalError(error.UnexpectedEndOfInput, &.{ 0x82, 0x01 });
    try canonicalError(error.UnexpectedEndOfInput, &.{ 0xa1, 0x01 });
    try canonicalError(error.UnexpectedEndOfInput, &.{ 0x9f, 0x01 });
    try canonicalError(error.UnexpectedEndOfInput, &.{ 0xb9, 0xff, 0xff });
    try canonicalError(error.TrailingCharacters, &.{ 0x01, 0x02 });
    try canonicalError(error.InvalidSimpleValue, &.{ 0xf8, 0x10 });
    try canonicalError(error.InvalidAdditionalInfo, &.{0x1c});
    // A key that is an array or a map, or a tag.
    try canonicalError(error.UnexpectedType, &.{ 0xa1, 0x81, 0x01, 0x00 });
    try canonicalError(error.UnexpectedType, &.{ 0xa1, 0xa0, 0x00 });
    try canonicalError(error.UnexpectedTag, &.{ 0xa1, 0xc1, 0x01, 0x00 });
    // Nesting: 128 containers is the most, a 129th is refused.
    var deep: [300]u8 = undefined;
    @memset(deep[0..128], 0x81);
    deep[128] = 0x01;
    var dst: [300]u8 = undefined;
    var scratch: [8]u8 = undefined;
    _ = try zerde.cbor.canonicalizeInto(&dst, &scratch, deep[0..129]);
    @memset(deep[0..129], 0x81);
    deep[129] = 0x01;
    try std.testing.expectError(error.CborNestingTooDeep, zerde.cbor.canonicalizeInto(&dst, &scratch, deep[0..130]));
    // A map as the 129th container, under arrays: only the map's own check can refuse it.
    @memset(deep[0..128], 0x81);
    deep[128] = 0xa0;
    try std.testing.expectError(error.CborNestingTooDeep, zerde.cbor.canonicalizeInto(&dst, &scratch, deep[0..129]));
    var maps: [300]u8 = undefined;
    for (0..129) |level| {
        maps[level * 2] = 0xa1;
        maps[level * 2 + 1] = 0x00;
    }
    maps[258] = 0x00;
    try std.testing.expectError(error.CborNestingTooDeep, zerde.cbor.canonicalizeInto(&dst, &scratch, maps[0..259]));
}

test "canonicalizeInto finds a repeated key in any spelling, and 0.0 with -0.0, wherever they sort" {
    const E = error.DuplicateField;
    try canonicalError(E, &.{ 0xa2, 0x01, 0x00, 0x18, 0x01, 0x01 }); // 1 and 1 spelled in two ways
    try canonicalError(E, &.{ 0xa2, 0x61, 'a', 0x00, 0x7f, 0x61, 'a', 0xff, 0x01 }); // "a" and a chunked "a"
    try canonicalError(E, &.{ 0xa2, 0x42, 1, 2, 0x00, 0x5f, 0x41, 1, 0x41, 2, 0xff, 0x01 }); // h'0102' twice
    try canonicalError(E, &.{ 0xa2, 0xf9, 0x3c, 0x00, 0x00, 0xfb, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0, 0x01 }); // 1.0 in two widths
    try canonicalError(E, &.{ 0xa2, 0xf9, 0x00, 0x00, 0x00, 0xf9, 0x80, 0x00, 0x00 }); // 0.0 and -0.0
    try canonicalError(E, &.{ 0xa2, 0xf9, 0x00, 0x00, 0x00, 0xfb, 0x80, 0, 0, 0, 0, 0, 0, 0, 0x00 });
    try canonicalError(E, &.{ 0xa3, 0xf9, 0x00, 0x00, 0x00, 0xf9, 0x00, 0x01, 0x00, 0xf9, 0x80, 0x00, 0x00 }); // with a key between
    try canonicalError(E, &.{ 0xa2, 0xf9, 0x7e, 0x00, 0x00, 0xfa, 0x7f, 0xc0, 0x00, 0x00, 0x01 }); // NaN twice
    try canonicalError(E, &.{ 0xa1, 0x61, 'x', 0xa2, 0x01, 0x00, 0x01, 0x01 }); // in a value
    try canonicalError(E, &.{ 0x81, 0xbf, 0x00, 0x00, 0x00, 0x01, 0xff }); // in an indefinite map in an array
    // Different keys are fine: 0.0 alone, -0.0 alone, 1 and 1.0.
    try expectCanonicalInto(&.{ 0xa1, 0xf9, 0x80, 0x00, 0x00 });
    try expectCanonicalInto(&.{ 0xa2, 0x01, 0x00, 0xf9, 0x3c, 0x00, 0x01 });
    // And the same key in different maps.
    try expectCanonicalInto(&.{ 0x82, 0xa1, 0x01, 0x00, 0xa1, 0x01, 0x01 });
}

test "canonicalizeInto refuses an input its 32-bit offsets cannot name, before it reads any of it" {
    if (@sizeOf(usize) <= 4) return error.SkipZigTest;
    const byte: u8 = 1;
    // A slice of 4 GiB and a byte, over memory that is never touched.
    const huge = @as([*]const u8, @ptrCast(&byte))[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    var dst: [1]u8 = undefined;
    var scratch: [8]u8 = undefined;
    try std.testing.expectError(error.InputTooLarge, zerde.cbor.canonicalizeInto(&dst, &scratch, huge));
}

test "canonicalizeInto allocates nothing, and says when its scratch or its output is too small" {
    // Nested maps hold their entries at once: 3 + 2 + 1.
    const input = [_]u8{ 0xa3, 0x03, 0xa2, 0x02, 0xa1, 0x01, 0x00, 0x00, 0x01, 0x01, 0x00, 0x02, 0x00 };
    var dst: [64]u8 = undefined;
    var scratch: [zerde.cbor.canonicalScratchSize(6)]u8 = undefined;
    const got = try zerde.cbor.canonicalizeInto(&dst, &scratch, &input);
    const expected = try zerde.cbor.canonicalize(allocator, &input);
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, got);
    // The entries of a map and of the maps that hold it are counted together: five entries are not enough, six are.
    var small: [zerde.cbor.canonicalScratchSize(5)]u8 = undefined;
    try std.testing.expectError(error.OutOfMemory, zerde.cbor.canonicalizeInto(&dst, &small, &input));
    // A scratch that is not aligned still works, with the bytes the size function adds.
    var offset: [zerde.cbor.canonicalScratchSize(6) + 1]u8 align(8) = undefined;
    _ = try zerde.cbor.canonicalizeInto(&dst, offset[1..], &input);
    // The output is at most the input, so a buffer of the input's length is enough, and one byte short is not for a
    // map that is already deterministic.
    _ = try zerde.cbor.canonicalizeInto(dst[0..input.len], &scratch, &input);
    try std.testing.expectError(error.NoSpaceLeft, zerde.cbor.canonicalizeInto(dst[0 .. input.len - 1], &scratch, &input));
    try std.testing.expectError(error.NoSpaceLeft, zerde.cbor.canonicalizeInto(dst[0..0], &scratch, &.{0x01}));
    // Strings are copied once and checked: a long chunked one that is exactly the buffer.
    var chunked: std.ArrayList(u8) = .empty;
    defer chunked.deinit(allocator);
    try chunked.append(allocator, 0x7f);
    for (0..40) |_| try chunked.appendSlice(allocator, &.{ 0x65, 'h', 'e', 'l', 'l', 'o' });
    try chunked.append(allocator, 0xff);
    var big: [256]u8 = undefined;
    const joined = try zerde.cbor.canonicalizeInto(big[0..202], &scratch, chunked.items);
    try std.testing.expectEqual(@as(usize, 202), joined.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 200 }, joined[0..2]);
    try std.testing.expectError(error.NoSpaceLeft, zerde.cbor.canonicalizeInto(big[0..201], &scratch, chunked.items));
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
    bytes: [65536]u8 align(16) = undefined,
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
    try std.testing.expectEqual(@as(u8, 1), put.flag);
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
    const bound = comptime wire.maxArenaSize(zerde.json, WireMsg, .{}, wire_read_cfg);
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
    // And the arena bound counts only the typed array: the capacities an array list grows through (33, 83 and 158 items
    // of 4 bytes, each with up to 3 bytes of alignment), the copy to its exact size, and the slack.
    try std.testing.expectEqual(@as(usize, 1764), wire.maxArenaSize(zerde.json, Scalars, .{}, .{}));
}

// ---- the wire decode is the typed walk, with no typed value between ---------------------------------------

const WireChecked = struct {
    lo: u8,
    label: []const u8,
    hi: u8 = 9,
    tail: ?u8,
    opts: []const ?u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .label = .{ .max_len = 8 }, .opts = .{ .max_len = 4 } } };

    pub fn check(self: WireChecked) error{Invalid}!void {
        if (self.lo > self.hi) return error.Invalid;
    }
};

fn decodeChecked(arena: *std.heap.FixedBufferAllocator, region: *Region, input: []const u8) !wire.Wire(WireChecked) {
    @memcpy(region.bytes[0..input.len], input);
    return wire.decode(zerde.json, WireChecked, arena, region.base(), region.bytes[0..input.len], .{}, .{});
}

test "wire.decode applies the typed layer's rules: defaults, optionals, a struct's check, unknown, repeated and missing fields" {
    var region: Region = .{};
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[1024..]);
    // A default fills `hi`, an absent optional is absent.
    const ok = try decodeChecked(&arena, &region, "{\"lo\":1,\"label\":\"x\",\"opts\":[]}");
    try std.testing.expectEqual(@as(u8, 1), ok.lo);
    try std.testing.expectEqual(@as(u8, 9), ok.hi);
    try std.testing.expectEqual(@as(u8, 0), ok.tail.present);
    try std.testing.expectEqualStrings("x", try region.memory().bytesOf(ok.label));
    const named = try decodeChecked(&arena, &region, "{\"tail\":4,\"lo\":2,\"label\":\"y\",\"hi\":3,\"opts\":[]}");
    try std.testing.expectEqual(@as(u8, 1), named.tail.present);
    try std.testing.expectEqual(@as(u8, 4), named.tail.value);
    try std.testing.expectEqual(@as(u8, 3), named.hi);

    // `check` is the type's own, called on the struct as the typed layer would have built it (its list of optionals
    // is rebuilt for the call), and its error is returned; the arena it rebuilt the struct in is handed back at
    // once, so the decode holds the wire list only, and a failed decode puts the arena back as it was.
    arena.reset();
    const before = arena.end_index;
    try std.testing.expectError(error.Invalid, decodeChecked(&arena, &region, "{\"lo\":10,\"label\":\"x\",\"opts\":[1,null]}"));
    try std.testing.expectEqual(before, arena.end_index);
    _ = try decodeChecked(&arena, &region, "{\"lo\":1,\"label\":\"x\",\"opts\":[1,null]}");
    try std.testing.expectEqual(before + 2 * @sizeOf(wire.Opt(u8)), arena.end_index);

    try std.testing.expectError(error.UnknownField, decodeChecked(&arena, &region, "{\"lo\":1,\"label\":\"x\",\"opts\":[],\"z\":1}"));
    try std.testing.expectError(error.DuplicateField, decodeChecked(&arena, &region, "{\"lo\":1,\"lo\":2,\"label\":\"x\",\"opts\":[]}"));
    try std.testing.expectError(error.MissingField, decodeChecked(&arena, &region, "{\"lo\":1,\"opts\":[]}"));
    try std.testing.expectError(error.LengthOutOfBounds, decodeChecked(&arena, &region, "{\"lo\":1,\"label\":\"123456789\",\"opts\":[]}"));
    try std.testing.expectError(error.LengthOutOfBounds, decodeChecked(&arena, &region, "{\"lo\":1,\"label\":\"x\",\"opts\":[1,1,1,1,1]}"));
}

const WireList = struct {
    effects: []const WireEffect,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .effects = .{ .max_len = 8 } } };
};

test "a strict decode of a list of unions allocates the wire array and nothing else" {
    const input = [_]u8{ 0xa1, 0x67, 'e', 'f', 'f', 'e', 'c', 't', 's', 0x83, 0x64, 'n', 'o', 'o', 'p', 0x64, 'n', 'o', 'o', 'p', 0x64, 'n', 'o', 'o', 'p' };
    var region: Region = .{};
    @memcpy(region.bytes[0..input.len], &input);
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[1024..]);
    const cfg = .{ .mode = zerde.cbor.Mode.strict, .max_items = 16, .max_string_len = 64 };
    const w = try wire.decode(zerde.cbor, WireList, &arena, region.base(), region.bytes[0..input.len], .{}, cfg);
    try std.testing.expectEqual(@as(u32, 3), w.effects.len);
    // The three elements, at their wire size: no typed array before them (a typed `WireEffect` is larger than its
    // wire form, and the decode used to hold both).
    try std.testing.expectEqual(3 * @sizeOf(wire.Wire(WireEffect)), arena.end_index);
    const effects = try region.memory().listOf(wire.Wire(WireEffect), w.effects);
    for (effects) |effect| try std.testing.expectEqual(@as(u8, 2), effect.tag);
    try std.testing.expect(arena.end_index <= comptime wire.maxArenaSize(zerde.cbor, WireList, .{}, cfg));
}

// ---- a decode into the caller's regions, with scratch of a size known at compile time -------------------------

test "decodeInto gives the value of decode, with regions of exactly regionSizes and no allocator" {
    const msg = sampleMsg();
    inline for (.{ zerde.cbor, zerde.json }) |Format| {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const write_cfg = if (Format == zerde.cbor) .{ .deterministic = true } else .{};
        try zerde.serializeWith(Format, &out.writer, msg, .{}, write_cfg);
        const read_cfg = if (Format == zerde.cbor) .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 64, .max_items = 256 } else wire_read_cfg;
        const sizes = comptime wire.regionSizes(Format, WireMsg, .{}, read_cfg);
        // The two regions are the one arena of `maxArenaSize`, and a strict CBOR read and a JSON read keep no scratch.
        try std.testing.expectEqual(wire.maxArenaSize(Format, WireMsg, .{}, read_cfg), sizes.output + sizes.scratch);
        try std.testing.expectEqual(@as(usize, 0), sizes.scratch);
        var region: Region = .{};
        const len = out.written().len;
        @memcpy(region.bytes[0..len], out.written());
        var scratch: [sizes.scratch]u8 align(16) = undefined;
        const decoded = try wire.decodeInto(Format, WireMsg, region.bytes[1024..][0..sizes.output], &scratch, region.base(), region.bytes[0..len], .{}, read_cfg);
        try expectSampleDecoded(region.memory(), decoded.value);
        try std.testing.expect(decoded.used > 0 and decoded.used <= sizes.output);
        // The same value as the allocator form gives, and the same bytes written back.
        var arena = std.heap.FixedBufferAllocator.init(region.bytes[16384..]);
        const same = try wire.decode(Format, WireMsg, &arena, region.base(), region.bytes[0..len], .{}, read_cfg);
        try std.testing.expectEqual(arena.end_index, decoded.used);
        try std.testing.expectEqual(same.effects.len, decoded.value.effects.len);
        // An output region one byte short is refused, not overrun.
        try std.testing.expectError(error.OutOfMemory, wire.decodeInto(Format, WireMsg, region.bytes[1024..][0 .. decoded.used - 1], &scratch, region.base(), region.bytes[0..len], .{}, read_cfg));
    }
}

const RawBox = struct {
    r: zerde.cbor.Raw,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .r = .{ .max_len = 400 } } };
};

test "what a lenient CBOR read keeps goes to the scratch region, which is free afterwards, and the output takes none of it" {
    const sizes = comptime wire.regionSizes(zerde.cbor, RawBox, .{}, .{});
    try std.testing.expectEqual(wire.maxArenaSize(zerde.cbor, RawBox, .{}, .{}), sizes.output + sizes.scratch);
    try std.testing.expectEqual(@as(usize, 256), sizes.output);
    try std.testing.expect(sizes.scratch > 100_000);
    // A raw item of 130 integer keys in descending order: a lenient read records every key to find a repeat.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xa1, 0x61, 'r', 0xb8, 130 });
    for (0..130) |index| try input.appendSlice(allocator, &.{ 0x18, @as(u8, @intCast(153 - index)), 0x00 });
    var region: [4096]u8 align(16) = undefined;
    @memcpy(region[0..input.items.len], input.items);
    var scratch: [sizes.scratch]u8 align(16) = undefined;
    const decoded = try wire.decodeInto(zerde.cbor, RawBox, region[1024..][0..sizes.output], &scratch, @intFromPtr(&region), region[0..input.items.len], .{}, .{});
    try std.testing.expectEqual(@as(usize, 0), decoded.used);
    try std.testing.expectEqual(@as(u32, @intCast(input.items.len - 3)), decoded.value.r.len);
    // The scratch is what a read of that item needs: too little is OutOfMemory, and the output is untouched by it.
    try std.testing.expectError(error.OutOfMemory, wire.decodeInto(zerde.cbor, RawBox, region[1024..][0..sizes.output], scratch[0..64], @intFromPtr(&region), region[0..input.items.len], .{}, .{}));
    // A repeat is found through the records, as before.
    input.items[input.items.len - 2] = 0x99;
    @memcpy(region[0..input.items.len], input.items);
    try std.testing.expectError(error.DuplicateField, wire.decodeInto(zerde.cbor, RawBox, region[1024..][0..sizes.output], &scratch, @intFromPtr(&region), region[0..input.items.len], .{}, .{}));
    // A strict read needs none.
    try std.testing.expectEqual(@as(usize, 0), wire.regionSizes(zerde.cbor, RawBox, .{}, strict).scratch);
}

const JsonRawBox = struct {
    r: zerde.json.Raw,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .r = .{ .max_len = 400 } } };
};

test "a json.Raw read keeps the names of its objects in the scratch region, as much as regionSizes says, and refuses a repeat" {
    const sizes = comptime wire.regionSizes(zerde.json, JsonRawBox, .{}, .{});
    try std.testing.expectEqual(wire.maxArenaSize(zerde.json, JsonRawBox, .{}, .{}), sizes.output + sizes.scratch);
    // An item of 45 members (the list of names grows to its fourth capacity) of 361 bytes, in a region of exactly that scratch.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, "{\"r\":{");
    for (0..45) |index| {
        if (index != 0) try input.append(allocator, ',');
        try input.print(allocator, "\"k{d:0>2}\":0", .{index});
    }
    try input.appendSlice(allocator, "}}");
    var region: [4096]u8 align(16) = undefined;
    @memcpy(region[0..input.items.len], input.items);
    var scratch: [sizes.scratch]u8 align(16) = undefined;
    const decoded = try wire.decodeInto(zerde.json, JsonRawBox, region[1024..][0..sizes.output], &scratch, @intFromPtr(&region), region[0..input.items.len], .{}, .{});
    try std.testing.expectEqual(@as(usize, 0), decoded.used);
    try std.testing.expectEqual(@as(u32, @intCast(input.items.len - 6)), decoded.value.r.len);
    // The names are charged to the scratch, not to the output: too little scratch is OutOfMemory.
    try std.testing.expectError(error.OutOfMemory, wire.decodeInto(zerde.json, JsonRawBox, region[1024..][0..sizes.output], scratch[0..64], @intFromPtr(&region), region[0..input.items.len], .{}, .{}));
    // The last name repeats the first, and is found with the same scratch.
    input.items[input.items.len - 7] = '0';
    input.items[input.items.len - 6] = '0';
    @memcpy(region[0..input.items.len], input.items);
    try std.testing.expectError(error.DuplicateField, wire.decodeInto(zerde.json, JsonRawBox, region[1024..][0..sizes.output], &scratch, @intFromPtr(&region), region[0..input.items.len], .{}, .{}));
}

// ---- a typed value written in windows, resumably ---------------------------------------------------------------

/// Every window of the resumable write of `value`, joined; each is checked to be no longer than the window and to
/// make progress.
fn writeInWindows(comptime Format: type, comptime T: type, value: T, comptime serde_cfg: anytype, comptime format_cfg: anytype, window_len: usize) ![]u8 {
    var resumed = zerde.resumable.Writer(Format, T, serde_cfg, format_cfg).init();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const window = try allocator.alloc(u8, window_len);
    defer allocator.free(window);
    while (true) {
        const filled = try resumed.fill(value, window);
        try std.testing.expect(filled.len <= window_len);
        try out.appendSlice(allocator, window[0..filled.len]);
        if (filled.done) break;
        try std.testing.expect(filled.len > 0);
    }
    // After the last window there is nothing more.
    try std.testing.expectEqual(@as(usize, 0), (try resumed.fill(value, window)).len);
    return out.toOwnedSlice(allocator);
}

/// The resumable write equals `serializeWith` for windows of every size from the smallest to a few hundred bytes, and one
/// that holds all of it.
fn expectWindows(comptime Format: type, comptime T: type, value: T, comptime serde_cfg: anytype, comptime format_cfg: anytype) !void {
    var whole: std.Io.Writer.Allocating = .init(allocator);
    defer whole.deinit();
    try zerde.serializeWith(Format, &whole.writer, value, serde_cfg, format_cfg);
    const min = zerde.resumable.Writer(Format, T, serde_cfg, format_cfg).min_window;
    var size: usize = min;
    while (size < min + 300) : (size += 1) {
        const got = try writeInWindows(Format, T, value, serde_cfg, format_cfg, size);
        defer allocator.free(got);
        try std.testing.expectEqualSlices(u8, whole.written(), got);
    }
    const all = try writeInWindows(Format, T, value, serde_cfg, format_cfg, whole.written().len + min);
    defer allocator.free(all);
    try std.testing.expectEqualSlices(u8, whole.written(), all);
}

test "a typed value written in windows is the bytes of the whole write, in JSON and CBOR, for any window" {
    const msg = sampleMsg();
    try expectWindows(zerde.json, WireMsg, msg, .{}, .{});
    try expectWindows(zerde.cbor, WireMsg, msg, .{}, .{});
    try expectWindows(zerde.cbor, WireMsg, msg, .{}, .{ .deterministic = true });
    // Many unions in a row: a window ends after a payload is complete and before the union's closing tokens.
    const Many = struct { v: []const WireEffect };
    var effects: [24]WireEffect = undefined;
    for (&effects, 0..) |*effect, index| effect.* = if (index % 3 == 0) .noop else if (index % 3 == 1) .{ .delete = .{ .bytes = "gone" } } else .{ .put = .{ .key = .{ .bytes = "k" }, .kind = "x", .revision = index, .meta = "m", .note = null, .level = .low, .ratio = 1, .flag = true } };
    try expectWindows(zerde.json, Many, .{ .v = &effects }, .{}, .{});
    try expectWindows(zerde.cbor, Many, .{ .v = &effects }, .{}, .{ .deterministic = true });
    // A union whose payload ends exactly where the window leaves less room than its closing tokens need: padding moves the
    // end of the payload through every position of a window.
    const Tail = struct { ok: bool };
    const Choice = union(enum) { put: Tail, gone: zerde.ByteString };
    const Padded = struct { pad: []const u8, choice: Choice };
    const padding = "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789";
    inline for (.{ zerde.json, zerde.cbor }) |Format| {
        const min = zerde.resumable.Writer(Format, Padded, .{}, .{}).min_window;
        for (0..padding.len) |pad| {
            inline for (.{ 0, 1, 2 }) |extra| {
                const value: Padded = .{ .pad = padding[0..pad], .choice = if (pad % 2 == 0) .{ .put = .{ .ok = true } } else .{ .gone = .{ .bytes = padding[pad..] } } };
                const got = try writeInWindows(Format, Padded, value, .{}, .{}, min + extra);
                defer allocator.free(got);
                var whole: std.Io.Writer.Allocating = .init(allocator);
                defer whole.deinit();
                try zerde.serializeWith(Format, &whole.writer, value, .{}, .{});
                try std.testing.expectEqualSlices(u8, whole.written(), got);
            }
        }
    }
    // Integer keys, an enum as an integer, optional policies, a union of every payload kind.
    try expectWindows(zerde.cbor, WireMsg, .{ .id = .{ 9, 8, 7, 6 }, .effects = &.{}, .grid = &.{}, .pair = .{ 0, 65535 } }, .{}, .{ .deterministic = true });
}

const Resumed = struct {
    text: []const u8,
    blob: zerde.ByteString,
    tail: ?[]const u8 = null,
    raw: zerde.json.Raw,
    numbers: []const i64,
    pub const serde = .{ .fields = .{ .tail = .{ .optional = .absent } } };
};
const ResumedCbor = struct {
    text: []const u8,
    blob: zerde.ByteString,
    raw: zerde.cbor.Raw,
    nested: []const []const WireEffect,
};

test "a long string, byte string and Raw are written in pieces that never split an escape or a code point apart from the window" {
    // 6,000 bytes of text with every kind of escape and multi-byte characters, in runs.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const parts = [_][]const u8{ "plain text ", "quote \" and slash \\ ", "tab\t newline\n bell\x07 ", "caf\xc3\xa9 ", "\xe2\x82\xac euro ", "\xf0\x9f\x98\x80 face " };
    var at: usize = 0;
    while (text.items.len < 6000) : (at += 1) try text.appendSlice(allocator, parts[at % parts.len]);
    var blob: [1001]u8 = undefined;
    for (&blob, 0..) |*byte, index| byte.* = @intCast((index * 7 + 3) % 256);
    const numbers = [_]i64{ 1, -2, 300, std.math.maxInt(i64), std.math.minInt(i64) };
    const raw_json = "{ \"a\" : [1, 2, 3], \"b\": \"x\\ny\" }";
    const value: Resumed = .{ .text = text.items, .blob = .{ .bytes = &blob }, .tail = "t\"", .raw = .{ .bytes = raw_json }, .numbers = &numbers };
    // Text as bytes needs UTF-8 for JSON; base64 and base64url for the rest.
    var utf8_blob: [10]u8 = "0123456789".*;
    const as_text: Resumed = .{ .text = text.items, .blob = .{ .bytes = &utf8_blob }, .raw = .{ .bytes = raw_json }, .numbers = &numbers };
    try expectWindows(zerde.json, Resumed, as_text, .{}, .{});
    inline for (.{ zerde.json.BytesEncoding.base64, zerde.json.BytesEncoding.base64url }) |encoding| {
        try expectWindows(zerde.json, Resumed, value, .{}, .{ .bytes = encoding });
        // Blobs of every length mod 3, from empty.
        inline for (.{ 0, 1, 2, 3, 4, 5 }) |length| {
            var short = value;
            short.blob = .{ .bytes = blob[0..length] };
            try expectWindows(zerde.json, Resumed, short, .{}, .{ .bytes = encoding });
        }
    }
    const cbor_value: ResumedCbor = .{
        .text = text.items,
        .blob = .{ .bytes = &blob },
        .raw = .{ .bytes = &.{ 0xa2, 0x61, 'a', 0x83, 1, 2, 3, 0x61, 'b', 0x61, 'x' } },
        .nested = &.{ &.{ .noop, .{ .delete = .{ .bytes = "gone" } } }, &.{}, &.{.noop} },
    };
    try expectWindows(zerde.cbor, ResumedCbor, cbor_value, .{}, .{});
    try expectWindows(zerde.cbor, ResumedCbor, cbor_value, .{}, .{ .deterministic = true });
    // Text of every length around the 1, 2 and 4 byte heads of CBOR, in a window that holds only a head and a little.
    inline for (.{ 0, 23, 24, 255, 256, 3000 }) |length| {
        var sized = cbor_value;
        sized.text = text.items[0..length];
        try expectWindows(zerde.cbor, ResumedCbor, sized, .{}, .{});
    }
}

test "a resumable write refuses what the whole write refuses, before the byte it concerns, and needs a window of one token" {
    const bad: Resumed = .{ .text = "a\xff", .blob = .{ .bytes = "x" }, .raw = .{ .bytes = "1" }, .numbers = &.{} };
    const Json = zerde.resumable.Writer(zerde.json, Resumed, .{}, .{});
    var window: [256]u8 = undefined;
    var resumed = Json.init();
    try std.testing.expectError(error.InvalidUtf8, resumed.fill(bad, &window));
    const bad_raw: Resumed = .{ .text = "a", .blob = .{ .bytes = "x" }, .raw = .{ .bytes = "{" }, .numbers = &.{} };
    var again = Json.init();
    try std.testing.expectError(error.UnexpectedToken, again.fill(bad_raw, &window));
    // A window smaller than one token is an error and not an endless loop.
    var small: [Json.min_window - 1]u8 = undefined;
    var tiny = Json.init();
    try std.testing.expectError(error.WindowTooSmall, tiny.fill(.{ .text = "a", .blob = .{ .bytes = "x" }, .raw = .{ .bytes = "1" }, .numbers = &.{} }, &small));
    // The minimum window is the largest token: a field name of the longest key, escaped.
    try std.testing.expect(Json.min_window >= zerde.typed.atomic_room + 6 * "numbers".len);
    const Longer = struct { a_name_that_is_a_good_deal_longer: u8 };
    try std.testing.expect(zerde.resumable.Writer(zerde.json, Longer, .{}, .{}).min_window > Json.min_window);
    // Bad CBOR text, and a Raw that is not deterministic in a deterministic write.
    const BadCbor = struct { s: []const u8, r: zerde.cbor.Raw };
    var cbor_window: [128]u8 = undefined;
    var bad_text = zerde.resumable.Writer(zerde.cbor, BadCbor, .{}, .{}).init();
    try std.testing.expectError(error.InvalidUtf8, bad_text.fill(.{ .s = "\xff", .r = .{ .bytes = &.{0x01} } }, &cbor_window));
    var bad_raw_cbor = zerde.resumable.Writer(zerde.cbor, BadCbor, .{}, .{ .deterministic = true }).init();
    try std.testing.expectError(error.NonDeterministicEncoding, bad_raw_cbor.fill(.{ .s = "a", .r = .{ .bytes = &.{ 0xbf, 0xff } } }, &cbor_window));
}

test "the pieces stop at the edge of a window exactly: a closing quote, a base64 tail, a CBOR head, a 40 digit number" {
    // JSON text that fills the window to its last byte: the closing quote waits for the next window.
    var small: [10]u8 = undefined;
    var w = std.Io.Writer.fixed(&small);
    var state: zerde.typed.TextState = .{};
    try std.testing.expectError(error.WindowFull, zerde.json.writeEscapedPart(&w, "abcdefghi", &state, false));
    try std.testing.expectEqual(@as(usize, 10), w.end);
    var next: [4]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&next);
    try zerde.json.writeEscapedPart(&w2, "abcdefghi", &state, false);
    try std.testing.expectEqualStrings("\"", w2.buffered());
    // A base64 tail of one byte needs four characters, and two are left: it waits.
    var tiny: [3]u8 = undefined;
    var wt = std.Io.Writer.fixed(&tiny);
    var bstate: zerde.typed.TextState = .{};
    try std.testing.expectError(error.WindowFull, zerde.json.writeBytesPart(&wt, .base64, "a", &bstate));
    try std.testing.expectEqualStrings("\"", wt.buffered());
    var rest: [8]u8 = undefined;
    var wr = std.Io.Writer.fixed(&rest);
    try zerde.json.writeBytesPart(&wr, .base64, "a", &bstate);
    try std.testing.expectEqualStrings("YQ==\"", wr.buffered());
    // A CBOR head of three bytes with two left writes nothing.
    var two: [2]u8 = undefined;
    var wc = std.Io.Writer.fixed(&two);
    var cbor_serializer = zerde.cbor.serializer(&wc, .{});
    var cstate: zerde.typed.TextState = .{};
    const long: [300]u8 = @splat('x');
    try std.testing.expectError(error.WindowFull, cbor_serializer.emitStringPart(&long, &cstate));
    try std.testing.expectEqual(@as(usize, 0), wc.end);
    try std.testing.expect(!cstate.started);
    // The widest numbers, in every window: i128's minimum is 40 characters and the widest f64 is 24.
    const Wide = struct { a: i128, b: f64, c: u128 };
    try expectWindows(zerde.json, Wide, .{ .a = std.math.minInt(i128), .b = -1.7976931348623157e308, .c = std.math.maxInt(u128) }, .{}, .{});
    try expectWindows(zerde.cbor, Wide, .{ .a = std.math.minInt(i64), .b = -1.7976931348623157e308, .c = std.math.maxInt(u64) }, .{}, .{});
}

test "a resumable write keeps 128 open containers, and refuses a deeper value instead of overrunning" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // Each level of nesting is two containers: the one-entry map of a union and its array.
    var tree: RecTree = .{ .leaf = 1 };
    var window: [4096]u8 = undefined;
    for (0..70) |level| {
        const children = try arena.allocator().alloc(RecTree, 1);
        children[0] = tree;
        tree = .{ .node = children };
        const Cbor = zerde.resumable.Writer(zerde.cbor, RecTree, .{}, .{ .deterministic = true });
        var resumed = Cbor.init();
        if (level < 63) {
            const filled = try resumed.fill(tree, &window);
            try std.testing.expect(filled.done);
        } else if (level >= 64) {
            try std.testing.expectError(error.ResumeTooDeep, resumed.fill(tree, &window));
        }
    }
}

// ---- max_container_bytes, the bound of what an event-fed writer buffers --------------------------------------------

/// `{"a": text, "b": [1, 2, 3], "c": {"d": true}, "e": text as bytes}` as events into a value writer of `Format` with `cfg`; the output length.
fn scriptedMap(comptime Format: type, limit: usize, text: []const u8, allocator_in: std.mem.Allocator) !usize {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var writer = Format.valueWriter(allocator_in, &out.writer, .{});
    defer writer.deinit();
    writer.max_container_bytes = limit;
    try writer.beginMap();
    try writer.writeText("a");
    try writer.writeText(text);
    try writer.writeText("b");
    try writer.beginArray();
    for (1..4) |number| try writer.writeInt(number);
    try writer.endArray();
    try writer.writeText("c");
    try writer.beginMap();
    try writer.writeText("d");
    try writer.writeBool(true);
    try writer.endMap();
    try writer.writeText("e");
    try writer.writeBytes(text);
    try writer.endMap();
    try writer.finish();
    return out.written().len;
}

test "max_container_bytes is an error before an allocation, in the JSON and the CBOR value writer" {
    inline for (.{ zerde.json, zerde.cbor }) |Format| {
        const unbounded = try scriptedMap(Format, std.math.maxInt(usize), "xxxx", allocator);
        // The smallest limit that passes is at most the output plus what each item is counted over by (a byte or eight);
        // one that is much smaller is refused, and the limit never makes a different output.
        var smallest: usize = 0;
        while (true) : (smallest += 1) {
            if (scriptedMap(Format, smallest, "xxxx", allocator)) |length| {
                try std.testing.expectEqual(unbounded, length);
                break;
            } else |err| try std.testing.expectEqual(error.ContainerTooLarge, err);
        }
        try std.testing.expect(smallest <= unbounded + 40);
        try std.testing.expect(smallest + 40 >= unbounded);
        // Every larger limit passes too.
        _ = try scriptedMap(Format, smallest + 1, "xxxx", allocator);
        _ = try scriptedMap(Format, std.math.maxInt(usize), "xxxx", allocator);
        // Text that is mostly escapes costs what it takes escaped.
        const quotes: [60]u8 = @splat('"');
        const loud = try scriptedMap(Format, std.math.maxInt(usize), &quotes, allocator);
        var loud_smallest: usize = 0;
        while (std.meta.isError(scriptedMap(Format, loud_smallest, &quotes, allocator))) loud_smallest += 1;
        try std.testing.expect(loud_smallest + 40 >= loud);
        // A CBOR array that closes into a map around it, and a key, are counted too (a JSON array streams into the map).
        if (Format == zerde.cbor) {
            var sink: std.Io.Writer.Allocating = .init(allocator);
            defer sink.deinit();
            var w = Format.valueWriter(allocator, &sink.writer, .{});
            defer w.deinit();
            w.max_container_bytes = 40;
            try w.beginMap();
            try w.writeText("k");
            try w.beginArray();
            for (0..2) |_| try w.writeText("some text here");
            try std.testing.expectError(error.ContainerTooLarge, w.endArray());
        }
        // A text of a megabyte in a container of 100 bytes is refused before its bytes are copied: nothing near it is allocated.
        const huge = try allocator.alloc(u8, 1 << 20);
        defer allocator.free(huge);
        @memset(huge, 'x');
        var counting = std.testing.FailingAllocator.init(allocator, .{});
        try std.testing.expectError(error.ContainerTooLarge, scriptedMap(Format, 100, huge, counting.allocator()));
        try std.testing.expect(counting.allocated_bytes < 4096);
        {
            var sink: std.Io.Writer.Allocating = .init(allocator);
            defer sink.deinit();
            var w = Format.valueWriter(allocator, &sink.writer, .{});
            defer w.deinit();
            w.max_container_bytes = 100;
            try w.beginMap();
            try std.testing.expectError(error.ContainerTooLarge, w.writeText(huge));
        }
        // At the top level there is no container: output goes to the writer, and the limit does not count it.
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var top = Format.valueWriter(allocator, &out.writer, .{ .max_container_bytes = 10 });
        defer top.deinit();
        try top.writeText(huge[0..4096]);
        try std.testing.expect(out.written().len > 4096);
    }
}

test "max_container_bytes counts base64 bytes as the characters they become" {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var w = zerde.json.valueWriter(allocator, &out.writer, .{ .bytes = zerde.json.BytesEncoding.base64, .max_container_bytes = 40 });
    defer w.deinit();
    try w.beginMap();
    try w.writeText("k");
    try std.testing.expectError(error.ContainerTooLarge, w.writeBytes("0123456789012345678901234"));
}

test "max_container_bytes counts what a nested container hands to the one around it when it closes" {
    inline for (.{ zerde.json, zerde.cbor }) |Format| {
        // The inner map is small enough alone and too large once it joins the outer one.
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var w = Format.valueWriter(allocator, &out.writer, .{ .max_container_bytes = 40 });
        defer w.deinit();
        try w.beginMap();
        try w.writeText("outer-key-one");
        try w.beginMap();
        try w.writeText("inner");
        try w.writeText("value-of-some-size");
        try std.testing.expectError(error.ContainerTooLarge, w.endMap());
    }
}

// ---- gather encode, a skeleton and references -----------------------------------------------------------------------

const GatherFrame = struct {
    id: [4]u8,
    key: zerde.ByteString,
    payload: zerde.ByteString,
    meta: zerde.cbor.Raw,
    note: ?zerde.ByteString = null,
    name: []const u8,
    pub const serde = .{ .fields = .{ .note = .{ .optional = .absent } } };
};

test "a gather encode is the skeleton and references that assemble to the bytes of the whole write" {
    // The bytes the frame holds are in one region that the references are relative to.
    var heap: [4096]u8 align(16) = undefined;
    for (&heap, 0..) |*byte, index| byte.* = @intCast(index % 251);
    const meta = [_]u8{ 0xa1, 0x61, 'k', 0x01 };
    @memcpy(heap[3000..][0..meta.len], &meta);
    const frame: GatherFrame = .{
        .id = .{ 1, 2, 3, 4 },
        .key = .{ .bytes = heap[100..108] },
        .payload = .{ .bytes = heap[1000..2500] },
        .meta = .{ .bytes = heap[3000..][0..meta.len] },
        .note = .{ .bytes = heap[200..204] },
        .name = "frame",
    };
    var whole: std.Io.Writer.Allocating = .init(allocator);
    defer whole.deinit();
    try zerde.serializeWith(zerde.cbor, &whole.writer, frame, .{}, .{ .deterministic = true });

    var skeleton: [256]u8 = undefined;
    var refs: [8]zerde.gather.Ref = undefined;
    const base = @intFromPtr(&heap);
    const gathered = try zerde.gather.encode(GatherFrame, &skeleton, &refs, base, 1, frame, .{}, .{ .deterministic = true });
    // Four byte strings and the raw item are left out; the array `id` and the text are in the skeleton.
    try std.testing.expectEqual(@as(usize, 4), gathered.refs.len);
    try std.testing.expectEqual(whole.written().len, gathered.len());
    try std.testing.expect(gathered.skeleton.len < 64);
    // The references are in output order, at the offsets of the bytes in the region and of the gaps in the skeleton.
    try std.testing.expectEqual(@as(u32, 100), gathered.refs[0].offset);
    try std.testing.expectEqual(@as(u32, 8), gathered.refs[0].len);
    // In key order: key, meta (the raw item), note, payload.
    try std.testing.expectEqual(@as(u32, 3000), gathered.refs[1].offset);
    try std.testing.expectEqual(@as(u32, 200), gathered.refs[2].offset);
    try std.testing.expectEqual(@as(u32, 1000), gathered.refs[3].offset);
    try std.testing.expectEqual(@as(u32, 1500), gathered.refs[3].len);
    for (gathered.refs[1..], gathered.refs[0 .. gathered.refs.len - 1]) |next, before| try std.testing.expect(next.skeleton_offset >= before.skeleton_offset);
    var out: [2048]u8 = undefined;
    const mem: wire.Memory = .{ .base = base, .regions = &.{&heap} };
    try std.testing.expectEqualSlices(u8, whole.written(), try zerde.gather.assemble(&out, gathered, mem));

    // Only the byte strings of at least min_len are left out: here the payload and nothing else.
    var skeleton_small: [256]u8 = undefined;
    var refs_small: [8]zerde.gather.Ref = undefined;
    const big = try zerde.gather.encode(GatherFrame, &skeleton_small, &refs_small, base, 100, frame, .{}, .{ .deterministic = true });
    try std.testing.expectEqual(@as(usize, 1), big.refs.len);
    try std.testing.expectEqualSlices(u8, whole.written(), try zerde.gather.assemble(&out, big, mem));
    // None at all: the skeleton is the whole frame.
    var skeleton_all: [2048]u8 = undefined;
    const none = try zerde.gather.encode(GatherFrame, &skeleton_all, &refs_small, base, 100_000, frame, .{}, .{ .deterministic = true });
    try std.testing.expectEqual(@as(usize, 0), none.refs.len);
    try std.testing.expectEqualSlices(u8, whole.written(), none.skeleton);
}

test "a gather encode refuses a short skeleton or list, bytes below its base, and a reference outside the memory" {
    var heap: [512]u8 align(16) = @splat(7);
    const frame: GatherFrame = .{ .id = .{ 0, 0, 0, 0 }, .key = .{ .bytes = heap[10..20] }, .payload = .{ .bytes = heap[100..300] }, .meta = .{ .bytes = &.{0xa0} }, .name = "n" };
    var skeleton: [256]u8 = undefined;
    var refs: [8]zerde.gather.Ref = undefined;
    const base = @intFromPtr(&heap);
    // The raw item is a literal outside the heap, so with a floor of one byte it is below `base` or beyond a u32.
    const outside = zerde.gather.encode(GatherFrame, &skeleton, &refs, base, 1, frame, .{}, .{});
    try std.testing.expectError(error.OffsetOutOfRange, outside);
    // With a floor above its length the raw item stays in the skeleton, and the rest is inside the heap.
    const ok = try zerde.gather.encode(GatherFrame, &skeleton, &refs, base, 2, frame, .{}, .{});
    try std.testing.expectEqual(@as(usize, 2), ok.refs.len);
    try std.testing.expectError(error.NoSpaceLeft, zerde.gather.encode(GatherFrame, &skeleton, refs[0..1], base, 2, frame, .{}, .{}));
    try std.testing.expectError(error.NoSpaceLeft, zerde.gather.encode(GatherFrame, skeleton[0..10], &refs, base, 2, frame, .{}, .{}));
    // The whole frame needs room, and each reference must name memory the caller says it holds.
    var small: [10]u8 = undefined;
    const mem: wire.Memory = .{ .base = base, .regions = &.{&heap} };
    try std.testing.expectError(error.NoSpaceLeft, zerde.gather.assemble(&small, ok, mem));
    var out: [1024]u8 = undefined;
    const elsewhere: wire.Memory = .{ .base = base, .regions = &.{heap[0..50]} };
    try std.testing.expectError(error.OffsetOutOfRange, zerde.gather.assemble(&out, ok, elsewhere));
    // An offset that does not fit 32 bits is refused and not cut: with a base of zero the heap is far above 4 GiB on a 64-bit target.
    if (@sizeOf(usize) > 4) try std.testing.expectError(error.OffsetOutOfRange, zerde.gather.encode(GatherFrame, &skeleton, &refs, 0, 2, frame, .{}, .{}));
    // Bytes below the base are refused as they are written.
    try std.testing.expectError(error.OffsetOutOfRange, zerde.gather.encode(GatherFrame, &skeleton, &refs, base + 100, 2, frame, .{}, .{}));
}

// ---- an integral JSON number into an integer, by its exact decimal value ------------------------------------------

const integral = .{ .integral_numbers = true };

fn expectIntegral(comptime T: type, expected: T, text: []const u8) !void {
    const got = try zerde.json.parseSliceWith(T, allocator, text, .{}, integral);
    try std.testing.expectEqual(expected, got);
}

fn expectIntegralError(comptime T: type, expected: anyerror, text: []const u8) !void {
    try std.testing.expectError(expected, zerde.json.parseSliceWith(T, allocator, text, .{}, integral));
}

/// `head`, `zeros` zeros, `tail` as one number text, read into an `i64`: its value, or the error it is refused with.
fn expectIntegralPadded(expected: anytype, head: []const u8, zeros: usize, tail: []const u8) !void {
    const text = try allocator.alloc(u8, head.len + zeros + tail.len);
    defer allocator.free(text);
    @memcpy(text[0..head.len], head);
    @memset(text[head.len..][0..zeros], '0');
    @memcpy(text[head.len + zeros ..], tail);
    const result = zerde.json.parseSliceWith(i64, allocator, text, .{}, integral);
    if (@typeInfo(@TypeOf(expected)) == .error_set) {
        try std.testing.expectError(expected, result);
    } else {
        try std.testing.expectEqual(@as(i64, expected), try result);
    }
}

test "integral_numbers takes a number whose exact decimal value is an integer, whatever its spelling" {
    try expectIntegral(i64, 1, "1.0");
    try expectIntegral(i64, 100, "1e2");
    try expectIntegral(i64, 100, "1E+2");
    try expectIntegral(i64, 100, "1.00e2");
    try expectIntegral(i64, 1, "10e-1");
    try expectIntegral(i64, 5, "0.5e1");
    try expectIntegral(i64, 15, "1.50e1");
    try expectIntegral(i64, 123, "12300e-2");
    try expectIntegral(i64, -42, "-4.2e1");
    try expectIntegral(i64, 0, "0.0");
    try expectIntegral(i64, 0, "-0.0");
    try expectIntegral(i64, 0, "0e5");
    try expectIntegral(i64, 0, "0e999999999999");
    try expectIntegral(i64, 7, "7.000000000000000000000000000000000000000000000");
    try expectIntegral(i64, 70, "7.000000000000000000000000000000000000000000000e1");
    // Integers still read as before.
    try expectIntegral(i64, 12, "12");
    try expectIntegral(u8, 255, "255.0");
    try expectIntegral(u8, 0, "-0e0");
    // `-0` is the number zero, which an unsigned type holds: spelled as an integer or as a float it is read alike.
    try expectIntegral(u8, 0, "-0");
    try expectIntegral(u8, 0, "-0.0");
    // More digits than a binary64 holds are exact: these are not rounded.
    try expectIntegral(u128, 100000000000000000000, "100000000000000000000.0");
    try expectIntegral(i128, std.math.maxInt(i128), "170141183460469231731687303715884105727.0");
    try expectIntegral(i128, std.math.maxInt(i128), "1.70141183460469231731687303715884105727e38");
    try expectIntegral(i128, std.math.minInt(i128), "-170141183460469231731687303715884105728e0");
    try expectIntegral(u128, std.math.maxInt(u128), "340282366920938463463374607431768211455.0");
    try expectIntegral(i64, 9007199254740993, "9007199254740993.0");
    try expectIntegral(i64, 9007199254740993, "9.007199254740993e15");
}

test "integral_numbers refuses a value that has a fraction, or does not fit, by its digits and not its binary64 value" {
    try expectIntegralError(i64, error.UnexpectedType, "1.5");
    try expectIntegralError(i64, error.UnexpectedType, "1.0000000000000001");
    try expectIntegralError(i64, error.UnexpectedType, "1e-1");
    try expectIntegralError(i64, error.UnexpectedType, "100e-3");
    try expectIntegralError(i64, error.UnexpectedType, "1e-999999999999");
    try expectIntegralError(i64, error.UnexpectedType, "9007199254740993.5");
    // A nonzero digit far out after the point is a fraction even where a double would round it away.
    try expectIntegralError(i64, error.UnexpectedType, "1.000000000000000000000000000000000000000000000000000001");
    try expectIntegralError(u8, error.IntegerOverflow, "256.0");
    try expectIntegralError(u8, error.IntegerOverflow, "-1.0");
    try expectIntegralError(u8, error.IntegerOverflow, "2.56e2");
    try expectIntegralError(i8, error.IntegerOverflow, "128.0");
    try expectIntegralError(i8, error.IntegerOverflow, "-129.0");
    try expectIntegralError(i64, error.IntegerOverflow, "1e999999999999");
    try expectIntegralError(i64, error.IntegerOverflow, "1e99999999999999999999999999");
    try expectIntegralError(i64, error.UnexpectedType, "1e-99999999999999999999999999");
    try expectIntegral(i64, 0, "0e99999999999999999999999999");
    try expectIntegralError(i64, error.IntegerOverflow, "1e40");
    try expectIntegralError(i128, error.IntegerOverflow, "170141183460469231731687303715884105728.0");
    try expectIntegralError(u128, error.IntegerOverflow, "340282366920938463463374607431768211456.0");
    try expectIntegralError(i128, error.IntegerOverflow, "1" ++ comptime longName(60, '0') ++ ".0");
    // A fraction of a million digits cancels no exponent: the scale is the true one, in sign and size.
    try expectIntegralPadded(error.IntegerOverflow, "0.", 999_999, "1e2000000");
    try expectIntegralPadded(error.UnexpectedType, "1", 1_500_000, "e-2000000");
    try expectIntegralPadded(1, "0.", 999_999, "1e1000000");
    // Something that is not an integer type, a string, a bad number.
    try expectIntegralError(i64, error.InvalidNumber, "\"1.0\"");
    try expectIntegralError(i64, error.InvalidNumber, "1.");
}

test "negative zero is the number zero for an unsigned integer, and any other negative is out of range" {
    // RFC 8259 writes `-0` as a number, whose value is zero; zero is in range for `u8`, as `-0.0` is with integral_numbers.
    const zero = try zerde.json.parseSlice(u8, allocator, "-0");
    try std.testing.expectEqual(@as(u8, 0), zero);
    try expectJsonError(u8, error.IntegerOverflow, "-1");
    try expectJsonError(u8, error.IntegerOverflow, "-256");
    try expectJsonError(u8, error.UnexpectedType, "-0.0");
}

test "integral_numbers is off by default, and a float field and the typed layer's bounds are unchanged" {
    try expectJsonError(i64, error.UnexpectedType, "1.0");
    try expectJsonError(i64, error.UnexpectedType, "1e2");
    const Fields = struct {
        count: u16,
        steps: []const i32,
        ratio: f64,
        maybe: ?u8 = null,
        pub const serde = .{ .fields = .{ .count = .{ .max = 100 }, .maybe = .{ .optional = .absent } } };
    };
    const got = try zerde.json.parseSliceWith(Fields, allocator, "{\"count\": 1e2, \"steps\": [1.0, -2e0, 3.0e1], \"ratio\": 1e2, \"maybe\": 2.0e0}", .{}, integral);
    defer zerde.free(allocator, got);
    try std.testing.expectEqual(@as(u16, 100), got.count);
    try std.testing.expectEqualSlices(i32, &.{ 1, -2, 30 }, got.steps);
    try std.testing.expectEqual(@as(f64, 100), got.ratio);
    try std.testing.expectEqual(@as(?u8, 2), got.maybe);
    // The field's own bound applies to the value read, and a missing exact value is not made up.
    try std.testing.expectError(error.ValueOutOfRange, zerde.json.parseSliceWith(Fields, allocator, "{\"count\": 1.01e2, \"steps\": [], \"ratio\": 0}", .{}, integral));
    try std.testing.expectError(error.UnexpectedType, zerde.json.parseSliceWith(Fields, allocator, "{\"count\": 1.5, \"steps\": [], \"ratio\": 0}", .{}, integral));
    try std.testing.expectError(error.UnexpectedType, zerde.json.parseSliceWith(Fields, allocator, "{\"count\": 1.0, \"steps\": [], \"ratio\": 0}", .{}, .{}));
    // Through a decode into the wire layout, as the config of a request.
    var region: Region = .{};
    const input = "{\"count\":1e1,\"steps\":[2.0],\"ratio\":1}";
    @memcpy(region.bytes[0..input.len], input);
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[1024..]);
    const w = try wire.decode(zerde.json, Fields, &arena, region.base(), region.bytes[0..input.len], .{}, .{ .integral_numbers = true, .max_items = 16, .max_string_len = 16 });
    try std.testing.expectEqual(@as(u16, 10), w.count);
}

// ---- fields declared in encoded-key order, and a strict read by merge walk ---------------------------------------

fn FramePair(comptime in_order: bool) type {
    return struct {
        id: u16,
        kind: []const u8,
        flags: u8 = 7,
        note: ?[]const u8 = null,
        tail: u32,
        pub const serde = if (in_order) .{
            .declared_in_order = true,
            .deny_unknown_fields = true,
            .fields = .{ .id = .{ .key = 0 }, .kind = .{ .key = 1 }, .flags = .{ .key = 2 }, .note = .{ .key = 3, .optional = .absent }, .tail = .{ .key = 4 } },
        } else .{
            .deny_unknown_fields = true,
            .fields = .{ .id = .{ .key = 0 }, .kind = .{ .key = 1 }, .flags = .{ .key = 2 }, .note = .{ .key = 3, .optional = .absent }, .tail = .{ .key = 4 } },
        };
    };
}
const Ordered = FramePair(true);
const Unordered = FramePair(false);

test "a type that declares its fields in order reads, strict, as the type that does not does, and writes the same bytes" {
    const frames = [_][]const u8{
        &.{ 0xa5, 0x00, 0x01, 0x01, 0x61, 'k', 0x02, 0x08, 0x03, 0x61, 'n', 0x04, 0x09 }, // every field
        &.{ 0xa3, 0x00, 0x01, 0x01, 0x61, 'k', 0x04, 0x09 }, // the default and the optional are absent
        &.{ 0xa4, 0x00, 0x01, 0x01, 0x61, 'k', 0x03, 0x60, 0x04, 0x09 }, // the optional is empty text
        &.{ 0xa2, 0x01, 0x61, 'k', 0x04, 0x09 }, // the first is missing
        &.{ 0xa2, 0x00, 0x01, 0x01, 0x61, 'k' }, // the last is missing
        &.{ 0xa1, 0x00, 0x01 }, // everything after the first is
        &.{0xa0},
        &.{ 0xa2, 0x01, 0x61, 'k', 0x00, 0x01 }, // out of order
        &.{ 0xa2, 0x00, 0x01, 0x00, 0x02 }, // repeated
        &.{ 0xa4, 0x00, 0x01, 0x01, 0x61, 'k', 0x04, 0x09, 0x05, 0x00 }, // a key the type does not declare
        &.{ 0xa4, 0x00, 0x01, 0x01, 0x61, 'k', 0x03, 0x61, 'n', 0x04, 0x0a },
        &.{ 0xa3, 0x00, 0x01, 0x20, 0x00, 0x04, 0x09 }, // -1 is not a field and sorts after 0
        &.{ 0xa2, 0x00, 0x01, 0x01, 0xf6 }, // a null for the text
    };
    for (frames) |frame| {
        const twin = zerde.cbor.parseSliceWith(Unordered, allocator, frame, .{}, strict);
        const merged = zerde.cbor.parseSliceWith(Ordered, allocator, frame, .{}, strict);
        if (twin) |left| {
            const right = try merged;
            try std.testing.expectEqual(left.id, right.id);
            try std.testing.expectEqualStrings(left.kind, right.kind);
            try std.testing.expectEqual(left.flags, right.flags);
            try std.testing.expectEqualDeep(left.note, right.note);
            try std.testing.expectEqual(left.tail, right.tail);
            zerde.free(allocator, left);
            zerde.free(allocator, right);
        } else |_| {
            // Both refuse it. The error can differ when an input has two faults: the merge walk reports an absent required field
            // when the key after it arrives, the other at the end of the map (the cases below pin each one alone).
            if (merged) |value| {
                zerde.free(allocator, value);
                return error.TestUnexpectedResult;
            } else |_| {}
        }
    }
    // The errors, named: a missing field (the unsorted frame lacks `id` when `kind` arrives), an unsorted key, a repeated one, an undeclared one.
    try std.testing.expectError(error.MissingField, zerde.cbor.parseSliceWith(Ordered, allocator, frames[3], .{}, strict));
    try std.testing.expectError(error.MissingField, zerde.cbor.parseSliceWith(Ordered, allocator, frames[4], .{}, strict));
    try std.testing.expectError(error.MissingField, zerde.cbor.parseSliceWith(Ordered, allocator, frames[7], .{}, strict));
    try std.testing.expectError(error.NonDeterministicEncoding, zerde.cbor.parseSliceWith(Ordered, allocator, &.{ 0xa4, 0x00, 0x01, 0x01, 0x61, 'k', 0x04, 0x09, 0x03, 0x61, 'n' }, .{}, strict));
    try std.testing.expectError(error.DuplicateField, zerde.cbor.parseSliceWith(Ordered, allocator, frames[8], .{}, strict));
    try std.testing.expectError(error.UnknownField, zerde.cbor.parseSliceWith(Ordered, allocator, frames[9], .{}, strict));
    // A lenient read does not rely on order: the same type takes keys in any order, through the walk it has always had.
    const lenient = try zerde.cbor.parseSlice(Ordered, allocator, &.{ 0xa3, 0x04, 0x09, 0x01, 0x61, 'k', 0x00, 0x01 });
    defer zerde.free(allocator, lenient);
    try std.testing.expectEqual(@as(u32, 9), lenient.tail);
    try std.testing.expectError(error.DuplicateField, zerde.cbor.parseSlice(Ordered, allocator, &.{ 0xa2, 0x00, 0x01, 0x00, 0x02 }));
    // The write is the same bytes: the declaration is the canonical order.
    const value: Unordered = .{ .id = 1, .kind = "k", .flags = 8, .note = "n", .tail = 9 };
    var left: std.Io.Writer.Allocating = .init(allocator);
    defer left.deinit();
    try zerde.serializeWith(zerde.cbor, &left.writer, value, .{}, .{ .deterministic = true });
    var right: std.Io.Writer.Allocating = .init(allocator);
    defer right.deinit();
    try zerde.serializeWith(zerde.cbor, &right.writer, Ordered{ .id = 1, .kind = "k", .flags = 8, .note = "n", .tail = 9 }, .{}, .{ .deterministic = true });
    try std.testing.expectEqualSlices(u8, left.written(), right.written());
    try std.testing.expectEqualSlices(u8, frames[0], right.written());
}

test "a merge walk releases what it read when a later field fails, in a list and in a wire decode" {
    const Many = struct {
        items: []const Ordered,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    // The second item lacks `tail`; the first was read and the list was allocated.
    const input = [_]u8{ 0xa1, 0x65, 'i', 't', 'e', 'm', 's', 0x82, 0xa2, 0x00, 0x01, 0x04, 0x02, 0xa1, 0x00, 0x01 };
    try std.testing.expectError(error.MissingField, zerde.cbor.parseSliceWith(Many, allocator, &input, .{}, strict));
    try std.testing.expectError(error.MissingField, zerde.cbor.parseSliceWith(Many, allocator, &input, .{}, .{ .mode = zerde.cbor.Mode.strict }));
    // Through the wire sink, whose arena is put back.
    var region: Region = .{};
    @memcpy(region.bytes[0..input.len], &input);
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[1024..]);
    try std.testing.expectError(error.MissingField, wire.decode(zerde.cbor, Many, &arena, region.base(), region.bytes[0..input.len], .{}, .{ .mode = zerde.cbor.Mode.strict, .max_items = 64, .max_string_len = 64 }));
    try std.testing.expectEqual(@as(usize, 0), arena.end_index);
    const ok = [_]u8{ 0xa1, 0x65, 'i', 't', 'e', 'm', 's', 0x81, 0xa3, 0x00, 0x01, 0x01, 0x60, 0x04, 0x02 };
    @memcpy(region.bytes[0..ok.len], &ok);
    const decoded = try wire.decode(zerde.cbor, Many, &arena, region.base(), region.bytes[0..ok.len], .{}, .{ .mode = zerde.cbor.Mode.strict, .max_items = 64, .max_string_len = 64 });
    try std.testing.expectEqual(@as(u32, 1), decoded.items.len);
}

test "the declared order is checked against the encoded keys, text and integer, and names the first field out of order" {
    const enc = zerde.cbor.encodeKey;
    const AscendingKeys = struct { a: u8, b: u8, cc: u8, dd: u8 };
    const Bad = struct { b: u8, a: u8 };
    const Long = struct { aa: u8, b: u8 };
    const Same = struct {
        x: u8,
        y: u8,
        pub const serde = .{ .fields = .{ .x = .{ .key = 3 }, .y = .{ .key = 3 } } };
    };
    const Ints = struct {
        zero: u8,
        one: u8,
        minus: u8,
        pub const serde = .{ .fields = .{ .zero = .{ .key = 0 }, .one = .{ .key = 1 }, .minus = .{ .key = -1 } } };
    };
    const TextThenNumber = struct {
        text: u8,
        number: u8,
        pub const serde = .{ .fields = .{ .number = .{ .key = 1 } } };
    };
    try std.testing.expect(comptime zerde.typed.declaredOrderFault(AscendingKeys, .{}, enc) == null);
    try std.testing.expect(comptime zerde.typed.declaredOrderFault(Ints, .{}, enc) == null);
    const bad = comptime zerde.typed.declaredOrderFault(Bad, .{}, enc).?;
    try std.testing.expectEqualStrings("a", bad.field);
    try std.testing.expectEqualStrings("b", bad.previous);
    // Shorter keys sort first, so `b` before `aa`, not after.
    try std.testing.expectEqualStrings("b", (comptime zerde.typed.declaredOrderFault(Long, .{}, enc).?).field);
    // A key twice is not after itself.
    try std.testing.expectEqualStrings("y", (comptime zerde.typed.declaredOrderFault(Same, .{}, enc).?).field);
    // An integer key sorts before a text key: a text key first, then a number, is out of order.
    try std.testing.expectEqualStrings("number", (comptime zerde.typed.declaredOrderFault(TextThenNumber, .{}, enc).?).field);
    // A call site's key override changes the order the check sees.
    const renamed = .{ .fields = .{ .b = .{ .key = 9 } } };
    try std.testing.expectEqualStrings("b", (comptime zerde.typed.declaredOrderFault(AscendingKeys, renamed, enc).?).field);
}

// ---- a sorted map, for keys that are data ---------------------------------------------------------------------

const Labels = zerde.SortedMap([]const u8);
const Limits = zerde.SortedMap(u32);
const Maps = struct {
    id: u8,
    labels: Labels,
    limits: Limits,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .labels = .{ .max_len = 4 }, .limits = .{ .max_len = 3, .elem = .{ .max = 100 } } } };
};

fn sampleMaps() Maps {
    const labels = [_]Labels.Entry{ .{ .key = "a", .value = "x" }, .{ .key = "b", .value = "yy" }, .{ .key = "cc", .value = "" }, .{ .key = "ab", .value = "z" } };
    const limits = [_]Limits.Entry{ .{ .key = "r", .value = 5 }, .{ .key = "w", .value = 100 } };
    // The labels array above is not in order (`ab` after `cc`): the caller of a test sorts what it needs.
    return .{ .id = 1, .labels = .{ .entries = labels[0..3] }, .limits = .{ .entries = &limits } };
}

test "a sorted map is found by binary search, over every key of a set, and says when it is not sorted" {
    var storage: [40]Limits.Entry = undefined;
    var keys: [40][3]u8 = undefined;
    // Keys of one to three bytes, in encoded-key order: shorter first, then bytewise.
    var count: usize = 0;
    for (1..4) |length| {
        var letter: u8 = 'a';
        while (letter < 'a' + 13 and count < 40) : (letter += 1) {
            keys[count] = .{ letter, 'z', letter + 1 };
            storage[count] = .{ .key = keys[count][0..length], .value = @intCast(count) };
            count += 1;
        }
    }
    const map: Limits = .{ .entries = storage[0..count] };
    try std.testing.expect(map.isSorted());
    for (storage[0..count], 0..) |entry, at| {
        try std.testing.expectEqual(@as(?usize, at), map.index(entry.key));
        try std.testing.expectEqual(@as(?u32, @intCast(at)), map.get(entry.key));
        try std.testing.expectEqual(@as(u32, @intCast(at)), map.getPtr(entry.key).?.*);
    }
    // Keys that are not there, before, between and after.
    for ([_][]const u8{ "", "0", "aa", "b!", "zzzz", "q", "az!" }) |absent| try std.testing.expectEqual(@as(?u32, null), map.get(absent));
    // Edges: empty, one, two.
    const none: Limits = .{ .entries = &.{} };
    try std.testing.expectEqual(@as(?u32, null), none.get("a"));
    try std.testing.expect(none.isSorted());
    try std.testing.expectEqual(@as(?u32, 1), (Limits{ .entries = &.{.{ .key = "a", .value = 1 }} }).get("a"));
    // Not sorted, and a repeat.
    try std.testing.expect(!(Limits{ .entries = &.{ .{ .key = "b", .value = 1 }, .{ .key = "a", .value = 1 } } }).isSorted());
    try std.testing.expect(!(Limits{ .entries = &.{ .{ .key = "a", .value = 1 }, .{ .key = "a", .value = 1 } } }).isSorted());
    // Length first: `b` before `aa`.
    try std.testing.expect((Limits{ .entries = &.{ .{ .key = "b", .value = 1 }, .{ .key = "aa", .value = 1 } } }).isSorted());
}

test "a sorted map is written in key order, in both formats, and read back; what is not in order is refused both ways" {
    const value = sampleMaps();
    var cbor_out = try writeCbor(value, .{}, .{ .deterministic = true });
    defer cbor_out.deinit();
    // {"id": 1, "labels": {"a": "x", "b": "yy", "cc": ""}, "limits": {"r": 5, "w": 100}} in deterministic order.
    try std.testing.expectEqualSlices(u8, &.{
        0xa3, 0x62, 'i',  'd',  0x01,
        0x66, 'l',  'a',  'b',  'e',
        'l',  's',  0xa3, 0x61, 'a',
        0x61, 'x',  0x61, 'b',  0x62,
        'y',  'y',  0x62, 'c',  'c',
        0x60, 0x66, 'l',  'i',  'm',
        'i',  't',  's',  0xa2, 0x61,
        'r',  0x05, 0x61, 'w',  0x18,
        0x64,
    }, cbor_out.written());
    const back = try zerde.cbor.parseSliceWith(Maps, allocator, cbor_out.written(), .{}, strict);
    defer zerde.free(allocator, back);
    try std.testing.expectEqualStrings("yy", back.labels.get("b").?);
    try std.testing.expectEqual(@as(?u32, 100), back.limits.get("w"));
    try std.testing.expect(back.labels.isSorted());
    var json_out = try writeJson(value, .{}, .{});
    defer json_out.deinit();
    try std.testing.expectEqualStrings("{\"id\":1,\"labels\":{\"a\":\"x\",\"b\":\"yy\",\"cc\":\"\"},\"limits\":{\"r\":5,\"w\":100}}", json_out.written());
    const from_json = try zerde.json.parseSlice(Maps, allocator, json_out.written());
    defer zerde.free(allocator, from_json);
    try std.testing.expectEqualStrings("x", from_json.labels.get("a").?);
    // The default CBOR write, with indefinite maps, reads back too.
    var plain = try writeCbor(value, .{}, .{});
    defer plain.deinit();
    const again = try zerde.cbor.parseSlice(Maps, allocator, plain.written());
    defer zerde.free(allocator, again);
    try std.testing.expectEqual(@as(usize, 3), again.labels.entries.len);

    // A write refuses entries out of order, and a repeat, in every format, with the errors of a strict read.
    const unordered: Limits = .{ .entries = &.{ .{ .key = "b", .value = 1 }, .{ .key = "a", .value = 2 } } };
    const repeated: Limits = .{ .entries = &.{ .{ .key = "a", .value = 1 }, .{ .key = "a", .value = 2 } } };
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    try std.testing.expectError(error.NonDeterministicEncoding, zerde.serializeWith(zerde.cbor, &sink.writer, unordered, .{}, .{ .deterministic = true }));
    try std.testing.expectError(error.NonDeterministicEncoding, zerde.serializeWith(zerde.json, &sink.writer, unordered, .{}, .{}));
    try std.testing.expectError(error.DuplicateField, zerde.serializeWith(zerde.cbor, &sink.writer, repeated, .{}, .{}));
    try std.testing.expectError(error.DuplicateField, zerde.serializeWith(zerde.json, &sink.writer, repeated, .{}, .{}));
}

test "a sorted map read refuses an unsorted or repeated key in every mode, and a JSON key with an escape is the key it spells" {
    const E = error.NonDeterministicEncoding;
    const D = error.DuplicateField;
    // CBOR, lenient and strict: {"limits": ...} is the field, with the keys of the map in the order given.
    const prefix = [_]u8{ 0xa3, 0x62, 'i', 'd', 0x01, 0x66, 'l', 'a', 'b', 'e', 'l', 's', 0xa0, 0x66, 'l', 'i', 'm', 'i', 't', 's' };
    const unsorted = prefix ++ [_]u8{ 0xa2, 0x61, 'w', 0x01, 0x61, 'r', 0x02 };
    const repeat = prefix ++ [_]u8{ 0xa2, 0x61, 'r', 0x01, 0x61, 'r', 0x02 };
    const long_first = prefix ++ [_]u8{ 0xa2, 0x62, 'a', 'a', 0x01, 0x61, 'b', 0x02 };
    inline for (.{ false, true }) |is_strict| {
        const read_cfg = if (is_strict) strict else .{ .mode = zerde.cbor.Mode.lenient };
        try std.testing.expectError(E, zerde.cbor.parseSliceWith(Maps, allocator, &unsorted, .{}, read_cfg));
        try std.testing.expectError(D, zerde.cbor.parseSliceWith(Maps, allocator, &repeat, .{}, read_cfg));
        try std.testing.expectError(E, zerde.cbor.parseSliceWith(Maps, allocator, &long_first, .{}, read_cfg));
    }
    // JSON has no mode and keeps no order: a sorted map is where an order is demanded.
    try std.testing.expectError(E, zerde.json.parseSlice(Maps, allocator, "{\"id\":1,\"labels\":{\"b\":\"x\",\"a\":\"y\"},\"limits\":{}}"));
    try std.testing.expectError(D, zerde.json.parseSlice(Maps, allocator, "{\"id\":1,\"labels\":{\"a\":\"x\",\"a\":\"y\"},\"limits\":{}}"));
    try std.testing.expectError(E, zerde.json.parseSlice(Maps, allocator, "{\"id\":1,\"labels\":{\"aa\":\"x\",\"b\":\"y\"},\"limits\":{}}"));
    // `\u0061` is `a`: a repeat of it, and an order that only holds for the spelling.
    try std.testing.expectError(D, zerde.json.parseSlice(Maps, allocator, "{\"id\":1,\"labels\":{\"a\":\"x\",\"\\u0061\":\"y\"},\"limits\":{}}"));
    const spelled = try zerde.json.parseSlice(Maps, allocator, "{\"id\":1,\"labels\":{\"\\u0061\":\"x\",\"b\\n\":\"y\"},\"limits\":{}}");
    defer zerde.free(allocator, spelled);
    try std.testing.expectEqualStrings("y", spelled.labels.get("b\n").?);
    // The same with the values failing after keys were read: nothing is left allocated (the testing allocator checks).
    try std.testing.expectError(error.ValueOutOfRange, zerde.json.parseSlice(Maps, allocator, "{\"id\":1,\"labels\":{\"a\":\"x\"},\"limits\":{\"\\u0061\":5,\"b\":101}}"));
    try std.testing.expectError(E, zerde.json.parseSlice(Maps, allocator, "{\"id\":1,\"labels\":{\"a\":\"x\",\"\\u0063\\u0063\":\"y\",\"\\u0062\":\"z\"},\"limits\":{}}"));
}

test "a sorted map's bounds are checked before it is allocated, and its values have their own" {
    // Five labels where four are the most: refused from the map's head, with nothing allocated.
    var counting = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const five = [_]u8{ 0xa3, 0x62, 'i', 'd', 0x01, 0x66, 'l', 'a', 'b', 'e', 'l', 's', 0xa5, 0x61, 'a', 0x60, 0x61, 'b', 0x60, 0x61, 'c', 0x60, 0x61, 'd', 0x60, 0x61, 'e', 0x60, 0x66, 'l', 'i', 'm', 'i', 't', 's', 0xa0 };
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSliceAliasedWith(Maps, counting.allocator(), &five, .{}, strict));
    // An indefinite map is bounded as it is read.
    const indefinite = [_]u8{ 0xbf, 0x62, 'i', 'd', 0x01, 0x66, 'l', 'a', 'b', 'e', 'l', 's', 0xbf, 0x61, 'a', 0x60, 0x61, 'b', 0x60, 0x61, 'c', 0x60, 0x61, 'd', 0x60, 0x61, 'e', 0x60, 0xff, 0x66, 'l', 'i', 'm', 'i', 't', 's', 0xa0, 0xff };
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSlice(Maps, allocator, &indefinite));
    // The limits map allows three entries of at most 100.
    try std.testing.expectError(error.ValueOutOfRange, zerde.json.parseSlice(Maps, allocator, "{\"id\":1,\"labels\":{},\"limits\":{\"a\":101}}"));
    try std.testing.expectError(error.LengthOutOfBounds, zerde.json.parseSlice(Maps, allocator, "{\"id\":1,\"labels\":{},\"limits\":{\"a\":1,\"b\":2,\"c\":3,\"d\":4}}"));
    const ok = try zerde.json.parseSlice(Maps, allocator, "{\"id\":1,\"labels\":{},\"limits\":{\"a\":1,\"b\":2,\"c\":100}}");
    defer zerde.free(allocator, ok);
    try std.testing.expectEqual(@as(?u32, 100), ok.limits.get("c"));
}

test "a sorted map of more entries than max_len is refused at the first one over, before more is allocated" {
    // 200 sorted keys against max_len 3: an allocator that fails at the 50th allocation is never reached.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "{\"id\":1,\"labels\":{},\"limits\":{");
    for (0..200) |at| {
        if (at != 0) try text.append(allocator, ',');
        try text.print(allocator, "\"k{d:0>3}\":1", .{at});
    }
    try text.appendSlice(allocator, "}}");
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 50 });
    try std.testing.expectError(error.LengthOutOfBounds, zerde.json.parseSlice(Maps, failing.allocator(), text.items));
    try std.testing.expect(failing.allocations <= 20);
    // The same through a decode into regions, which has nothing to grow into.
    var region: Region = .{};
    @memcpy(region.bytes[0..text.items.len], text.items);
    const cfg = .{ .max_items = 512, .max_string_len = 16, .max_input_bytes = 4096 };
    const sizes = comptime wire.regionSizes(zerde.json, Maps, .{}, cfg);
    var scratch: [sizes.scratch]u8 align(16) = undefined;
    try std.testing.expectError(error.LengthOutOfBounds, wire.decodeInto(zerde.json, Maps, region.bytes[8192..][0..sizes.output], &scratch, region.base(), region.bytes[0..text.items.len], .{}, cfg));
}

const LabelsOnly = struct {
    labels: Labels,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .labels = .{ .max_len = 4 } } };
};

test "a lenient CBOR sorted map decodes within exactly regionSizes: its keys are not recorded for a repeat check" {
    const cfg = .{ .mode = zerde.cbor.Mode.lenient, .max_input_bytes = 256, .max_items = 64, .max_string_len = 16 };
    const sizes = comptime wire.regionSizes(zerde.cbor, LabelsOnly, .{}, cfg);
    // Indefinite maps with definite keys, and with chunked keys; the bound must hold for both.
    const plain = [_]u8{ 0xbf, 0x66, 'l', 'a', 'b', 'e', 'l', 's', 0xbf, 0x61, 'a', 0x61, 'x', 0x61, 'b', 0x61, 'x', 0x61, 'c', 0x61, 'x', 0x61, 'd', 0x61, 'x', 0xff, 0xff };
    const chunked = [_]u8{ 0xbf, 0x66, 'l', 'a', 'b', 'e', 'l', 's', 0xbf, 0x7f, 0x61, 'a', 0xff, 0x61, 'x', 0x7f, 0x61, 'b', 0xff, 0x61, 'x', 0x7f, 0x61, 'c', 0xff, 0x61, 'x', 0x7f, 0x61, 'd', 0xff, 0x61, 'x', 0xff, 0xff };
    inline for (.{ &plain, &chunked }) |input| {
        var region: [2048]u8 align(16) = undefined;
        @memcpy(region[0..input.len], input);
        var scratch: [sizes.scratch]u8 align(16) = undefined;
        const decoded = try wire.decodeInto(zerde.cbor, LabelsOnly, region[1024..][0..sizes.output], &scratch, @intFromPtr(&region), region[0..input.len], .{}, cfg);
        try std.testing.expectEqual(@as(u32, 4), decoded.value.labels.entries.len);
    }
    // A repeat and a disorder are still refused, by the order of the keys.
    var repeat = plain;
    repeat[14] = 'a';
    var region: [2048]u8 align(16) = undefined;
    @memcpy(region[0..repeat.len], &repeat);
    var scratch: [sizes.scratch]u8 align(16) = undefined;
    try std.testing.expectError(error.DuplicateField, wire.decodeInto(zerde.cbor, LabelsOnly, region[1024..][0..sizes.output], &scratch, @intFromPtr(&region), region[0..repeat.len], .{}, cfg));
}

test "a sorted map decodes into the wire layout with its keys in the input, and its arena bound holds" {
    var out = try writeCbor(sampleMaps(), .{}, .{ .deterministic = true });
    defer out.deinit();
    var region: Region = .{};
    const len = out.written().len;
    @memcpy(region.bytes[0..len], out.written());
    const cfg = .{ .mode = zerde.cbor.Mode.strict, .max_items = 64, .max_string_len = 64, .max_input_bytes = 4096 };
    const bound = comptime wire.maxArenaSize(zerde.cbor, Maps, .{}, cfg);
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[len..][0..bound]);
    const w = try wire.decode(zerde.cbor, Maps, &arena, region.base(), region.bytes[0..len], .{}, cfg);
    const mem = region.memory();
    const entries = try mem.listOf(wire.Wire(Labels.Entry), w.labels.entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    // A key is a span of the input and a value is its own layout: nothing was copied but the array of entries.
    const key = try mem.bytesOf(entries[1].key);
    try std.testing.expectEqualStrings("b", key);
    try std.testing.expect(@intFromPtr(key.ptr) >= region.base() and @intFromPtr(key.ptr) < region.base() + len);
    try std.testing.expectEqualStrings("yy", try mem.bytesOf(entries[1].value));
    try std.testing.expect(arena.end_index <= bound);
    // And back to the bytes it came from.
    var again: std.Io.Writer.Allocating = .init(allocator);
    defer again.deinit();
    var scratch: [1024]u8 = undefined;
    var scratch_arena = std.heap.FixedBufferAllocator.init(&scratch);
    try wire.encode(zerde.cbor, Maps, &scratch_arena, mem, w, &again.writer, .{}, .{ .deterministic = true });
    try std.testing.expectEqualSlices(u8, out.written(), again.written());
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
    // A span must be reachable from the base, so the refused input lies in a region too (the field that is too
    // long is read after `meta`, whose span is made as it is read).
    const refused = [_]u8{ 0xa3, 0x00, 0x01, 0x01, 0xa0, 0x02, 0x64, 'a', 'b', 'c', 'd' };
    var bad: Region = .{};
    @memcpy(bad.bytes[0..refused.len], &refused);
    var bad_arena = std.heap.FixedBufferAllocator.init(bad.bytes[refused.len..]);
    try std.testing.expectError(error.LengthOutOfBounds, wire.decode(zerde.cbor, Frame, &bad_arena, bad.base(), bad.bytes[0..refused.len], .{}, cfg));
    try std.testing.expect(wire.maxArenaSize(zerde.cbor, Frame, .{}, cfg) > 0);
}

// ---- a wide schema needs no help with the comptime branch quota --------------------------------------------------

const QuotaKey = struct { name: []const u8, ver: u32, tags: []const u16 };
const QuotaSpan = union(enum) { point: zerde.ByteString, range: struct { start: zerde.ByteString, end: ?zerde.ByteString } };
const QuotaGuard = struct { span: QuotaSpan, shard: [16]u8, generation: u64, key: QuotaKey };
const QuotaRecord = struct { key: QuotaKey, payload: zerde.ByteString, meta: []const u8, guards: []const QuotaGuard, rev: ?u64 };
const QuotaEffect = union(enum) { put: QuotaRecord, delete: QuotaKey, touch: struct { key: QuotaKey, at: u64 } };
const QuotaResponse = union(enum) {
    v0: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    v1: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    v2: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    v3: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    v4: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    v5: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    v6: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    v7: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    v8: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    v9: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    v10: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    v11: struct { a: QuotaRecord, b: QuotaRecord, c: []const QuotaEffect, d: ?QuotaGuard, e: QuotaSpan },
    failed: struct { code: u16, message: []const u8, at: QuotaKey },
};

test "a wire type of a wide schema needs no comptime branch quota from the caller" {
    const W = wire.Wire(QuotaResponse);
    try std.testing.expect(@sizeOf(W) > 0);
    // The walk of both directions compiles and runs on it.
    const input = "{\"failed\":{\"code\":9,\"message\":\"no\",\"at\":{\"name\":\"k\",\"ver\":1,\"tags\":[1,2]}}}";
    var region: Region = .{};
    @memcpy(region.bytes[0..input.len], input);
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[input.len..]);
    const w = try wire.decode(zerde.json, QuotaResponse, &arena, region.base(), region.bytes[0..input.len], .{}, .{});
    try std.testing.expectEqual(@as(u8, 12), w.tag);
    try std.testing.expectEqual(@as(u16, 9), w.payload.failed.code);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try wire.encode(zerde.json, QuotaResponse, &arena, region.memory(), w, &out.writer, .{}, .{});
    try std.testing.expectEqualStrings(input, out.written());
}

// ---- the arena bound against adversarial input; bools; limits while a JSON string is read --------------------------

/// Decodes `input` into an arena of exactly `bound` bytes, placed after the input, and says how much it took.
fn decodeWithin(comptime Format: type, comptime T: type, comptime bound: usize, input: []const u8, comptime format_cfg: anytype) !usize {
    const region = try allocator.alignedAlloc(u8, .@"16", input.len + bound);
    defer allocator.free(region);
    @memcpy(region[0..input.len], input);
    var arena = std.heap.FixedBufferAllocator.init(region[input.len..]);
    _ = try wire.decode(Format, T, &arena, @intFromPtr(region.ptr), region[0..input.len], .{}, format_cfg);
    return arena.end_index;
}

test "a JSON string over its max_len is LengthOutOfBounds, not an arena that ran out" {
    const Capped = struct {
        t: []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .t = .{ .max_len = 4 } } };
    };
    const cfg = .{ .max_string_len = 4096, .max_items = 16 };
    const bound = comptime wire.maxArenaSize(zerde.json, Capped, .{}, cfg);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, "{\"t\":\"");
    for (0..3000) |_| try input.appendSlice(allocator, "\\n");
    try input.appendSlice(allocator, "\"}");
    try std.testing.expectError(error.LengthOutOfBounds, decodeWithin(zerde.json, Capped, bound, input.items, cfg));
    // The typed read says the same without an arena of any size.
    try std.testing.expectError(error.LengthOutOfBounds, zerde.json.parseSlice(Capped, allocator, input.items));
    // Within the bound, escaped, it reads.
    _ = try decodeWithin(zerde.json, Capped, bound, "{\"t\":\"\\n\\n\\n\\n\"}", cfg);
    try std.testing.expectError(error.LengthOutOfBounds, decodeWithin(zerde.json, Capped, bound, "{\"t\":\"\\n\\n\\n\\n\\n\"}", cfg));
    // A field with no max_len keeps the config's limit and its error.
    const Free = struct { t: []const u8 };
    try std.testing.expectError(error.StringTooLong, zerde.json.parseSliceWith(Free, allocator, input.items, .{}, .{ .max_string_len = 100 }));
    // Bytes in base64: the bound is on the decoded bytes, and the token is a third longer.
    const BlobBound = struct {
        b: zerde.ByteString,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .b = .{ .max_len = 6 } } };
    };
    const six = try zerde.json.parseSliceWith(BlobBound, allocator, "{\"b\":\"AAECAwQF\"}", .{}, .{ .bytes = .base64 });
    defer zerde.free(allocator, six);
    try std.testing.expectEqual(@as(usize, 6), six.b.bytes.len);
    try std.testing.expectError(error.LengthOutOfBounds, zerde.json.parseSliceWith(BlobBound, allocator, "{\"b\":\"AAECAwQFBg==\"}", .{}, .{ .bytes = .base64 }));
    var long_blob: std.ArrayList(u8) = .empty;
    defer long_blob.deinit(allocator);
    try long_blob.appendSlice(allocator, "{\"b\":\"");
    for (0..2000) |_| try long_blob.appendSlice(allocator, "AAAA");
    try long_blob.appendSlice(allocator, "\"}");
    try std.testing.expectError(error.LengthOutOfBounds, zerde.json.parseSliceWith(BlobBound, allocator, long_blob.items, .{}, .{ .bytes = .base64 }));
}

test "nested lists share the max_items budget, and the bound holds for the input that spends it all" {
    const Nested = struct {
        grid: []const []const u32,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const cfg = .{ .max_items = 256, .max_string_len = 64 };
    const bound = comptime wire.maxArenaSize(zerde.json, Nested, .{}, cfg);
    // One budget, not one per level: well under the per-level product (256 * (3 * 256 + 32) * 4 = 800 KB).
    try std.testing.expect(bound < 40_000);
    try std.testing.expect(bound > 8_000);
    // Worst shapes: every item a list of one, one list of all the items, and in between.
    inline for (.{ 1, 3, 20, 120 }) |per_list| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(allocator);
        try input.appendSlice(allocator, "{\"grid\":[");
        // Each list is one item and so is each number: 256 items in the whole input, counting the object and its key.
        var items: usize = 3;
        var first = true;
        while (items + 1 + per_list <= 256) : (items += 1 + per_list) {
            if (!first) try input.append(allocator, ',');
            first = false;
            try input.append(allocator, '[');
            for (0..per_list) |k| {
                if (k != 0) try input.append(allocator, ',');
                try input.append(allocator, '7');
            }
            try input.append(allocator, ']');
        }
        try input.appendSlice(allocator, "]}");
        const used = try decodeWithin(zerde.json, Nested, bound, input.items, cfg);
        try std.testing.expect(used <= bound);
    }
    // One more item than the budget is refused by the reader, not by the arena.
    var over: std.ArrayList(u8) = .empty;
    defer over.deinit(allocator);
    try over.appendSlice(allocator, "{\"grid\":[[");
    for (0..260) |k| {
        if (k != 0) try over.append(allocator, ',');
        try over.append(allocator, '1');
    }
    try over.appendSlice(allocator, "]]}");
    try std.testing.expectError(error.TooManyItems, decodeWithin(zerde.json, Nested, bound, over.items, cfg));
    // A field with its own max_len is charged in full per element, and still bounded.
    const Own = struct {
        rows: []const []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .rows = .{ .max_len = 3, .elem = .{ .max_len = 5 } } } };
    };
    const own_bound = comptime wire.maxArenaSize(zerde.json, Own, .{}, .{ .max_string_len = 64, .max_items = 64 });
    _ = try decodeWithin(zerde.json, Own, own_bound, "{\"rows\":[\"\\n\\n\\n\\n\\n\",\"\\t\\t\\t\\t\\t\",\"\\r\\r\\r\\r\\r\"]}", .{ .max_string_len = 64, .max_items = 64 });
}

test "the bound holds for a raw item built to cost the reader most" {
    const Held = struct {
        meta: zerde.cbor.Raw,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .meta = .{ .max_len = 600 } } };
    };
    const cfg = .{ .max_depth = 16, .max_items = 100_000, .max_string_len = 600 };
    const bound = comptime wire.maxArenaSize(zerde.cbor, Held, .{}, cfg);
    // A map whose key is a map whose key is a map...: each level is a key holding the one inside it, and
    // so is recorded in canonical form again at every level. `a1 <key> 00` is four bytes more per level.
    var item: std.ArrayList(u8) = .empty;
    defer item.deinit(allocator);
    const levels = 14;
    for (0..levels) |_| try item.appendSlice(allocator, &.{0xa1});
    try item.appendSlice(allocator, &.{ 0x61, 'k' });
    for (0..levels) |_| try item.appendSlice(allocator, &.{0x00});
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xa1, 0x64, 'm', 'e', 't', 'a' });
    try input.appendSlice(allocator, item.items);
    const used = try decodeWithin(zerde.cbor, Held, bound, input.items, cfg);
    try std.testing.expect(used <= bound);
    // Many small maps in one item: the records, not the key bytes.
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(allocator);
    try wide.appendSlice(allocator, &.{ 0xa1, 0x64, 'm', 'e', 't', 'a', 0x99, 0x00, 0x60 });
    for (0..96) |_| try wide.appendSlice(allocator, &.{ 0xa1, 0x00, 0x00 });
    // 96 maps of one entry in an array of 96: 0x99 0x00 0x60 is 96 items.
    const used_wide = try decodeWithin(zerde.cbor, Held, bound, wide.items, cfg);
    try std.testing.expect(used_wide <= bound);
    // Over the field's max_len is refused by the field, before the reader records anything.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(allocator);
    try big.appendSlice(allocator, &.{ 0xa1, 0x64, 'm', 'e', 't', 'a', 0x99, 0x01, 0xf4 });
    for (0..500) |_| try big.appendSlice(allocator, &.{ 0xa1, 0x00, 0x00 });
    try std.testing.expectError(error.LengthOutOfBounds, decodeWithin(zerde.cbor, Held, bound, big.items, cfg));
}

test "a union is charged at its worst variant, and a variant that fails halfway leaves the arena as it was" {
    const Light = struct {
        n: u8,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const HeavyBound = struct {
        rows: []const WireRecord,
        text: []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .rows = .{ .max_len = 2 }, .text = .{ .max_len = 8 } } };
    };
    const Choice = union(enum) {
        heavy: HeavyBound,
        light: Light,
        plain,
    };
    const Picks = struct {
        picks: []const Choice,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .picks = .{ .max_len = 3 } } };
    };
    const cfg = .{ .max_string_len = 64, .max_items = 256 };
    const bound = comptime wire.maxArenaSize(zerde.json, Picks, .{}, cfg);
    // The heaviest variant, three times, with every string escaped.
    const record = "{\"key\":\"\\n\\n\",\"kind\":\"\\t\\t\",\"revision\":1,\"meta\":\"\\r\",\"level\":7,\"ratio\":1.5,\"flag\":true}";
    const heavy = "{\"heavy\":{\"rows\":[" ++ record ++ "," ++ record ++ "],\"text\":\"\\n\\n\\n\\n\\n\\n\\n\\n\"}}";
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, "{\"picks\":[" ++ heavy ++ "," ++ heavy ++ "," ++ heavy ++ "]}");
    const used = try decodeWithin(zerde.json, Picks, bound, input.items, cfg);
    try std.testing.expect(used <= bound);
    // A variant that fails after it allocated: the next decode in the same arena starts where this one did.
    var region: Region = .{};
    const bad = "{\"picks\":[" ++ heavy ++ ",{\"heavy\":{\"rows\":[],\"text\":\"toolongtext\"}}]}";
    @memcpy(region.bytes[0..bad.len], bad);
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[bad.len..][0..bound]);
    try std.testing.expectError(error.LengthOutOfBounds, wire.decode(zerde.json, Picks, &arena, region.base(), region.bytes[0..bad.len], .{}, cfg));
    try std.testing.expectEqual(@as(usize, 0), arena.end_index);
    // Two variants in one object, a variant named twice, and an unknown variant: errors, with the same restore.
    inline for (.{ "{\"picks\":[{\"light\":{\"n\":1},\"plain\":null}]}", "{\"picks\":[{\"light\":{\"n\":1},\"light\":{\"n\":2}}]}", "{\"picks\":[{\"nope\":1}]}" }) |text| {
        @memcpy(region.bytes[0..text.len], text);
        try std.testing.expect(std.meta.isError(wire.decode(zerde.json, Picks, &arena, region.base(), region.bytes[0..text.len], .{}, cfg)));
        try std.testing.expectEqual(@as(usize, 0), arena.end_index);
    }
}

test "a bool on the wire is 0 or 1, and anything else is refused, alone or in a list" {
    const Flags = struct { flag: bool, flags: []const bool, pair: [2]bool };
    try std.testing.expect(wire.Wire(bool) == u8);
    var region: Region = .{};
    var arena = std.heap.FixedBufferAllocator.init(region.bytes[256..]);
    const mem = region.memory();
    const good = try wire.toWire(Flags, arena.allocator(), mem.base, .{ .flag = true, .flags = &.{ true, false, true }, .pair = .{ false, true } });
    try std.testing.expectEqual(@as(u8, 1), good.flag);
    try std.testing.expectEqual(@as([2]u8, .{ 0, 1 }), good.pair);
    const back = try wire.fromWire(Flags, arena.allocator(), mem, good);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, back.flags);
    // A byte that is neither, in each place a bool can be.
    var bad = good;
    bad.flag = 2;
    try std.testing.expectError(error.InvalidTag, wire.fromWire(Flags, arena.allocator(), mem, bad));
    bad = good;
    bad.pair[1] = 7;
    try std.testing.expectError(error.InvalidTag, wire.fromWire(Flags, arena.allocator(), mem, bad));
    const list = try wire.Memory.resolve(mem, good.flags, 1, 1);
    @constCast(list)[1] = 2;
    try std.testing.expectError(error.InvalidTag, wire.fromWire(Flags, arena.allocator(), mem, good));
    // And through encode: nothing is written for it that a reader would take for a bool.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var scratch: [512]u8 = undefined;
    var scratch_arena = std.heap.FixedBufferAllocator.init(&scratch);
    try std.testing.expectError(error.InvalidTag, wire.encode(zerde.json, Flags, &scratch_arena, mem, good, &out.writer, .{}, .{}));
}

// ---- the arena bound is within a small factor of the worst the input can cost ------------------------------------

fn Request(comptime R: type) type {
    const Effect = struct {
        key: zerde.ByteString,
        record_type: []const u8,
        payload: zerde.ByteString,
        meta: R,
        note: ?zerde.ByteString = null,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{
            .key = .{ .max_len = 1024 },
            .record_type = .{ .min_len = 1, .max_len = 63 },
            .payload = .{ .max_len = 262144 },
            .meta = .{ .max_len = 16384 },
            .note = .{ .optional = .absent, .max_len = 16384 },
        } };
    };
    return struct {
        effects: []const Effect,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .effects = .{ .max_len = 64 } } };
    };
}

test "a CBOR request's bound is small next to its field bounds, and holds for chunked strings and nested raw keys" {
    const Req = Request(zerde.cbor.Raw);
    const cfg = .{ .max_items = 8192, .max_string_len = 262144, .max_input_bytes = 32768, .max_depth = 16 };
    const bound = comptime wire.maxArenaSize(zerde.cbor, Req, .{}, cfg);
    // The fields alone allow 64 effects of 262144 + 16384 + ... bytes: tens of megabytes. The input is 32 KiB.
    // Chunked text everywhere, as many chunks as the input holds: each string is assembled in the arena.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xa1, 0x67, 'e', 'f', 'f', 'e', 'c', 't', 's', 0x98, 64 });
    for (0..64) |_| {
        try input.appendSlice(allocator, &.{ 0xa4, 0x63, 'k', 'e', 'y', 0x5f, 0x41, 1, 0x41, 2, 0xff });
        try input.appendSlice(allocator, &.{ 0x6b, 'r', 'e', 'c', 'o', 'r', 'd', '_', 't', 'y', 'p', 'e', 0x7f, 0x61, 'a', 0x61, 'b', 0xff });
        try input.appendSlice(allocator, &.{ 0x67, 'p', 'a', 'y', 'l', 'o', 'a', 'd', 0x5f, 0x41, 1, 0xff });
        try input.appendSlice(allocator, &.{ 0x64, 'm', 'e', 't', 'a', 0xa0 });
    }
    const used = try decodeWithin(zerde.cbor, Req, bound, input.items, cfg);
    try std.testing.expect(used <= bound);
    // One effect whose raw meta is a chain of maps used as keys, as deep as the config allows.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(allocator);
    try deep.appendSlice(allocator, &.{ 0xa1, 0x67, 'e', 'f', 'f', 'e', 'c', 't', 's', 0x81, 0xa4, 0x63, 'k', 'e', 'y', 0x41, 1, 0x6b, 'r', 'e', 'c', 'o', 'r', 'd', '_', 't', 'y', 'p', 'e', 0x61, 'a', 0x67, 'p', 'a', 'y', 'l', 'o', 'a', 'd', 0x41, 1, 0x64, 'm', 'e', 't', 'a' });
    // meta = { K(0): 0 } with K(i) = { K(i + 1): 0 } and, innermost, a map of 3000 entries: every level's key holds all
    // of that, so it is recorded in canonical form again at each of the levels the config allows.
    var level: std.ArrayList(u8) = .empty;
    defer level.deinit(allocator);
    try level.appendSlice(allocator, &.{ 0xb9, 0x0b, 0xb8 });
    for (0..3000) |key| try level.appendSlice(allocator, &.{ 0x19, @intCast(key >> 8), @intCast(key & 0xff), 0x00 });
    for (0..10) |_| {
        var next: std.ArrayList(u8) = .empty;
        try next.append(allocator, 0xa1);
        try next.appendSlice(allocator, level.items);
        try next.append(allocator, 0x00);
        level.deinit(allocator);
        level = next;
    }
    try deep.append(allocator, 0xa1);
    try deep.appendSlice(allocator, level.items);
    try deep.append(allocator, 0x00);
    const deep_used = try decodeWithin(zerde.cbor, Req, bound, deep.items, cfg);
    try std.testing.expect(deep_used <= bound);
    // Within a small factor of the worst: the reader's keys for the chain take more than a third of the bound.
    try std.testing.expect(deep_used * 4 > bound);
    // The input the bound relies on is enforced.
    var big: [40000]u8 = undefined;
    @memset(&big, 0);
    try std.testing.expectError(error.InputTooLarge, decodeWithin(zerde.cbor, Req, bound, &big, cfg));
}

test "a JSON request's bound holds for escaped strings and base64 bytes, as many as the input allows" {
    const Req = Request([]const u8);
    const cfg = .{ .max_items = 8192, .max_string_len = 262144, .max_input_bytes = 32768, .bytes = zerde.json.BytesEncoding.base64 };
    const bound = comptime wire.maxArenaSize(zerde.json, Req, .{}, cfg);
    try std.testing.expect(bound < 1_500_000);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, "{\"effects\":[");
    for (0..64) |index| {
        if (index != 0) try input.append(allocator, ',');
        // Escaped text in every string, base64 in every byte string, within what 32 KiB holds in 64 effects.
        try input.appendSlice(allocator, "{\"key\":\"AAEC\",\"record_type\":\"\\n\\n\",\"payload\":\"AAECAwQFBgcICQoL\",\"meta\":\"\\t\\t\\t\\t\\t\\t\\t\\t\",\"note\":\"AAEC\"}");
    }
    try input.appendSlice(allocator, "]}");
    try std.testing.expect(input.items.len <= 32768);
    const used = try decodeWithin(zerde.json, Req, bound, input.items, cfg);
    try std.testing.expect(used <= bound);
    // Many tiny escaped strings: each costs a buffer's first capacity, so the count is what the bound must charge.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(allocator);
    try many.appendSlice(allocator, "{\"effects\":[");
    for (0..64) |index| {
        if (index != 0) try many.append(allocator, ',');
        try many.appendSlice(allocator, "{\"key\":\"AA\\/\\/\",\"record_type\":\"\\n\",\"payload\":\"AA\\/\\/\",\"meta\":\"\\n\",\"note\":\"AA\\/\\/\"}");
    }
    try many.appendSlice(allocator, "]}");
    const many_used = try decodeWithin(zerde.json, Req, bound, many.items, cfg);
    try std.testing.expect(many_used <= bound);
    // The worst the input can do: base64 in every payload with one escape to force a rewrite, so each is
    // built as a token and decoded. 1.75 times the input, and the bound is under twice that.
    var worst: std.ArrayList(u8) = .empty;
    defer worst.deinit(allocator);
    try worst.appendSlice(allocator, "{\"effects\":[");
    for (0..64) |index| {
        if (index != 0) try worst.append(allocator, ',');
        try worst.appendSlice(allocator, "{\"key\":\"\",\"record_type\":\"a\",\"payload\":\"");
        for (0..396) |_| try worst.append(allocator, 'A');
        try worst.appendSlice(allocator, "\\/AAA\",\"meta\":\"\"}");
    }
    try worst.appendSlice(allocator, "]}");
    try std.testing.expect(worst.items.len <= 32768);
    const worst_used = try decodeWithin(zerde.json, Req, bound, worst.items, cfg);
    try std.testing.expect(worst_used <= bound);
    try std.testing.expect(worst_used * 3 > bound);
}

test "arena bound figures, from small schemas, for the parts of the model" {
    const Row = struct {
        a: u32,
        b: u32,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const Rows = struct {
        rows: []const Row,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .rows = .{ .max_len = 10 } } };
    };
    const Text = struct {
        s: []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .s = .{ .max_len = 100 } } };
    };
    const Blob2 = struct {
        b: zerde.ByteString,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .b = .{ .max_len = 90 } } };
    };
    const Raws = struct {
        r: zerde.cbor.Raw,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .r = .{ .max_len = 400 } } };
    };
    const Pool = struct {
        grid: []const []const u8,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const Times = struct {
        names: []const []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .names = .{ .max_len = 5, .elem = .{ .max_len = 20 } } } };
    };
    // Worked by hand: a list of ten 8-byte rows grows through one capacity of 17 (17 * 8 + 3 bytes), is copied to
    // its exact size (83) and its wire array is 10 * 8 + 16; and the slack is 256.
    try std.testing.expectEqual(@as(usize, 139 + 83 + 256), wire.maxArenaSize(zerde.json, Rows, .{}, .{}));
    // A string of at most 100 bytes costs 100 (it is measured first and written once, exactly sized); with an input of 10 bytes
    // the strings hold at most 10.
    try std.testing.expectEqual(@as(usize, 100 + 256), wire.maxArenaSize(zerde.json, Text, .{}, .{}));
    try std.testing.expectEqual(@as(usize, 10 + 256), wire.maxArenaSize(zerde.json, Text, .{}, .{ .max_input_bytes = 10 }));
    // Two strings: both held.
    const Two = struct {
        a: []const u8,
        b: []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .a = .{ .max_len = 100 }, .b = .{ .max_len = 40 } } };
    };
    try std.testing.expectEqual(@as(usize, 140 + 256), wire.maxArenaSize(zerde.json, Two, .{}, .{}));
    // Bytes: the 90 they decode to; the base64 is decoded from the input, or from its unescaped text a chunk at a time.
    try std.testing.expectEqual(@as(usize, 90 + 256), wire.maxArenaSize(zerde.json, Blob2, .{}, .{}));
    // A raw item of 400 bytes: its keys at 101 levels (four bytes each), or at the two the config allows below the
    // two that hold it; a raw item itself is never copied.
    try std.testing.expectEqual(@as(usize, 187419), wire.maxArenaSize(zerde.cbor, Raws, .{}, .{}));
    try std.testing.expectEqual(@as(usize, 24751), wire.maxArenaSize(zerde.cbor, Raws, .{}, .{ .max_depth = 4 }));
    // Lists with no bound of their own share the one budget of 100 items, whatever the nesting.
    try std.testing.expectEqual(@as(usize, 8556), wire.maxArenaSize(zerde.json, Pool, .{}, .{ .max_items = 100, .max_string_len = 8 }));
    try std.testing.expect(wire.maxArenaSize(zerde.json, Pool, .{}, .{ .max_items = 200, .max_string_len = 8 }) > 8556);
    // Lists of lists with bounds of their own multiply: three lists of at most four rows each.
    const Nest = struct {
        rows: []const []const Row,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .rows = .{ .max_len = 3, .elem = .{ .max_len = 4 } } } };
    };
    // A list that draws on the budget, holding a struct with a list of its own bound: the 100 items of the budget each
    // cost a bounded list, once per item, not per level.
    const Held = struct {
        xs: []const u32,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .xs = .{ .max_len = 5 } } };
    };
    const Drawn = struct {
        held: []const Held,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const Ints = struct {
        xs: []const u32,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    // By hand: the outer list of 8-byte wire spans, 139 + 27; each of the three inner lists of 8-byte rows, 139 + 35.
    try std.testing.expectEqual(@as(usize, 166 + 3 * 174 + 256), wire.maxArenaSize(zerde.json, Nest, .{}, .{}));
    // The budget alone, per item: a list of one element costs (142 for 33 u32s grown to and copied) over two items.
    try std.testing.expectEqual(@as(usize, 71 * 100 + 256), wire.maxArenaSize(zerde.json, Ints, .{}, .{ .max_items = 100 }));
    // Charged per item: the array of 8-byte wire lists, grown and copied, over the items of the budget: 75 an item.
    try std.testing.expectEqual(@as(usize, 75 * 100 + 256), wire.maxArenaSize(zerde.json, Drawn, .{}, .{ .max_items = 100 }));
    // Strings in a list with a max_len and elem bounds: five of at most twenty bytes (the list of 8-byte spans grows through 139 and is copied to 43; 182 in all).
    try std.testing.expectEqual(@as(usize, 182 + 100 + 256), wire.maxArenaSize(zerde.json, Times, .{}, .{}));
}
// ---- a rewritten string is measured first and written once, at its exact length ---------------------------

/// The bytes of an arena that `input` decodes into, when it is given `size` bytes and no more.
fn decodeInExactly(comptime Format: type, comptime T: type, size: usize, input: []const u8, comptime format_cfg: anytype) !usize {
    const region = try allocator.alignedAlloc(u8, .@"16", input.len + size);
    defer allocator.free(region);
    @memcpy(region[0..input.len], input);
    var arena = std.heap.FixedBufferAllocator.init(region[input.len..]);
    _ = try wire.decode(Format, T, &arena, @intFromPtr(region.ptr), region[0..input.len], .{}, format_cfg);
    return arena.end_index;
}

const TextBox = struct {
    s: []const u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .s = .{ .max_len = 100 } } };
};
const BytesBox = struct {
    b: zerde.ByteString,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .b = .{ .max_len = 1000 } } };
};
const BigBytes = struct {
    b: zerde.ByteString,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .b = .{ .max_len = 4096 } } };
};

test "a JSON string with escapes and a chunked CBOR string are allocated once, at their length" {
    // "a", a newline, "b", é (two bytes) and an emoji from a surrogate pair: nine bytes, and an arena of nine bytes.
    try std.testing.expectEqual(@as(usize, 9), try decodeInExactly(zerde.json, TextBox, 9, "{\"s\":\"a\\nb\\u00e9\\ud83d\\ude00\"}", .{}));
    try std.testing.expectError(error.OutOfMemory, decodeInExactly(zerde.json, TextBox, 8, "{\"s\":\"a\\nb\\u00e9\\ud83d\\ude00\"}", .{}));
    // A CBOR string in three chunks: three bytes, one allocation.
    try std.testing.expectEqual(@as(usize, 3), try decodeInExactly(zerde.cbor, TextBox, 3, &.{ 0xa1, 0x61, 's', 0x7f, 0x61, 'a', 0x60, 0x62, 'b', 'c', 0xff }, .{}));
    // The bound is the length of the string.
    try std.testing.expectEqual(@as(usize, 100 + 256), wire.maxArenaSize(zerde.json, TextBox, .{}, .{}));
    // The errors are the ones the reader gave: a bad escape, a control character, a lone surrogate, bad UTF-8, a long string.
    try std.testing.expectError(error.InvalidStringEscape, decodeInExactly(zerde.json, TextBox, 64, "{\"s\":\"ab\\q\"}", .{}));
    try std.testing.expectError(error.InvalidStringCharacter, decodeInExactly(zerde.json, TextBox, 64, "{\"s\":\"a\\nb\x01\"}", .{}));
    try std.testing.expectError(error.InvalidUnicodeSurrogate, decodeInExactly(zerde.json, TextBox, 64, "{\"s\":\"a\\nb\\ud800\"}", .{}));
    try std.testing.expectError(error.InvalidUtf8, decodeInExactly(zerde.json, TextBox, 64, "{\"s\":\"a\\nb\xff\"}", .{}));
    try std.testing.expectError(error.UnexpectedEndOfInput, decodeInExactly(zerde.json, TextBox, 64, "{\"s\":\"a\\nb", .{}));
    try std.testing.expectError(error.LengthOutOfBounds, decodeInExactly(zerde.json, TextBox, 400, "{\"s\":\"\\n" ++ comptime longName(100, 'x') ++ "\"}", .{}));
    try std.testing.expectError(error.InvalidUtf8, decodeInExactly(zerde.cbor, TextBox, 64, &.{ 0xa1, 0x61, 's', 0x7f, 0x61, 'a', 0x61, 0xff, 0xff }, .{}));
    try std.testing.expectError(error.InvalidStringChunk, decodeInExactly(zerde.cbor, TextBox, 64, &.{ 0xa1, 0x61, 's', 0x7f, 0x41, 'a', 0xff }, .{}));
    // A skipped chunked string is checked and not allocated: the allocator given here fails on its first allocation.
    var none = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try zerde.cbor.validate(none.allocator(), &.{ 0x82, 0x7f, 0x61, 'a', 0x62, 'b', 'c', 0xff, 0x5f, 0x41, 1, 0xff });
    try std.testing.expectError(error.InvalidUtf8, zerde.cbor.validate(none.allocator(), &.{ 0x81, 0x7f, 0x61, 0xff, 0xff }));
    try std.testing.expectError(error.InvalidStringChunk, zerde.cbor.validate(none.allocator(), &.{ 0x81, 0x7f, 0x41, 'a', 0xff }));
}

test "base64 bytes in JSON are decoded from the input, or from their unescaped text, into one allocation of their length" {
    const std_cfg = .{ .bytes = zerde.json.BytesEncoding.base64 };
    const url_cfg = .{ .bytes = zerde.json.BytesEncoding.base64url };
    // "AA//AAAA" is six bytes whether or not its slashes are escaped, and an arena of six bytes is enough for both:
    // the escaped token is not built first.
    try std.testing.expectEqual(@as(usize, 6), try decodeInExactly(zerde.json, BytesBox, 6, "{\"b\":\"AA//AAAA\"}", std_cfg));
    try std.testing.expectEqual(@as(usize, 6), try decodeInExactly(zerde.json, BytesBox, 6, "{\"b\":\"AA\\/\\/AAAA\"}", std_cfg));
    // Padding that is escaped counts: "AA==" is one byte; and unpadded URL-safe text with a dash and an underscore.
    try std.testing.expectEqual(@as(usize, 1), try decodeInExactly(zerde.json, BytesBox, 1, "{\"b\":\"AA\\u003d\\u003d\"}", std_cfg));
    try std.testing.expectEqual(@as(usize, 3), try decodeInExactly(zerde.json, BytesBox, 3, "{\"b\":\"AA\\u002d_\"}", url_cfg));
    try std.testing.expectEqual(@as(usize, 2), try decodeInExactly(zerde.json, BytesBox, 2, "{\"b\":\"AA\\u0041\"}", url_cfg));
    // A long escaped token is decoded a chunk at a time and gives the same bytes as the same token with no escape.
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(allocator);
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(allocator);
    try escaped.appendSlice(allocator, "{\"b\":\"");
    try plain.appendSlice(allocator, "{\"b\":\"");
    for (0..300) |index| {
        try escaped.appendSlice(allocator, if (index % 50 == 49) "AAAA\\/AAA" else "AAAAAAAAAAAA");
        try plain.appendSlice(allocator, if (index % 50 == 49) "AAAA/AAA" else "AAAAAAAAAAAA");
    }
    try escaped.appendSlice(allocator, "\"}");
    try plain.appendSlice(allocator, "\"}");
    var region: Region = .{};
    @memcpy(region.bytes[0..escaped.items.len], escaped.items);
    @memcpy(region.bytes[8192..][0..plain.items.len], plain.items);
    // 294 groups of nine bytes and six of six: 2,682 bytes, in an arena of exactly that.
    var arena_escaped = std.heap.FixedBufferAllocator.init(region.bytes[16384..][0..2682]);
    const from_escaped = try wire.decode(zerde.json, BigBytes, &arena_escaped, region.base(), region.bytes[0..escaped.items.len], .{}, std_cfg);
    var arena_plain = std.heap.FixedBufferAllocator.init(region.bytes[24576..][0..2682]);
    const from_plain = try wire.decode(zerde.json, BigBytes, &arena_plain, region.base(), region.bytes[8192..][0..plain.items.len], .{}, std_cfg);
    try std.testing.expectEqual(@as(u32, 2682), from_escaped.b.len);
    try std.testing.expectEqualSlices(u8, try region.memory().bytesOf(from_plain.b), try region.memory().bytesOf(from_escaped.b));
    // The slashes decoded to something: the groups are not all zero.
    try std.testing.expect(std.mem.indexOfNone(u8, try region.memory().bytesOf(from_escaped.b), &.{0}) != null);
    // Padding inside the token, at the end of a chunk, is not padding: the whole is refused, as a decode of it whole is.
    var padded: std.ArrayList(u8) = .empty;
    defer padded.deinit(allocator);
    try padded.appendSlice(allocator, "{\"b\":\"");
    for (0..63) |_| try padded.appendSlice(allocator, "AAAA");
    try padded.appendSlice(allocator, "AA==AAAA\\/AAA\"}");
    try std.testing.expectError(error.InvalidBytes, decodeInExactly(zerde.json, BytesBox, 400, padded.items, std_cfg));
    // Errors: a character outside the alphabet, a bad length, a bad escape, a token too long for max_len.
    try std.testing.expectError(error.InvalidBytes, decodeInExactly(zerde.json, BytesBox, 64, "{\"b\":\"AA\\n=\"}", std_cfg));
    try std.testing.expectError(error.InvalidBytes, decodeInExactly(zerde.json, BytesBox, 64, "{\"b\":\"AAA\\/A\"}", std_cfg));
    try std.testing.expectError(error.InvalidStringEscape, decodeInExactly(zerde.json, BytesBox, 64, "{\"b\":\"AA\\q\"}", std_cfg));
    try std.testing.expectError(error.InvalidBytes, decodeInExactly(zerde.json, BytesBox, 64, "{\"b\":\"A\"}", std_cfg));
    // A token longer than max_len allows is refused before anything is allocated for it (a bound of 1,000 bytes allows 1,340 characters; the arena here is 100).
    const too_long = "{\"b\":\"" ++ comptime longName(1345, 'A') ++ "\"}";
    try std.testing.expectError(error.LengthOutOfBounds, decodeInExactly(zerde.json, BytesBox, 100, too_long, std_cfg));
    // The bound is the bytes only.
    try std.testing.expectEqual(@as(usize, 1000 + 256), wire.maxArenaSize(zerde.json, BytesBox, .{}, std_cfg));
}

test "a long string that is rewritten fits an arena of exactly the bound, while its buffer grows and after" {
    const Long = struct {
        s: []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .s = .{ .max_len = 2700 } } };
    };
    const cfg = .{ .max_string_len = 4096 };
    const bound = comptime wire.maxArenaSize(zerde.json, Long, .{}, cfg);
    // A rewritten string is written once, at its length, so it costs nothing more while it is built.
    try std.testing.expectEqual(@as(usize, 2700 + 256), bound);
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(allocator);
    try plain.appendSlice(allocator, "{\"s\":\"");
    for (0..2699) |_| try plain.append(allocator, 'a');
    try plain.appendSlice(allocator, "\\n\"}");
    _ = try decodeWithin(zerde.json, Long, bound, plain.items, cfg);
    _ = try decodeWithin(zerde.json, Long, bound, plain.items, .{ .max_string_len = 4096, .max_input_bytes = 8192 });
    // Every byte an escape.
    var escapes: std.ArrayList(u8) = .empty;
    defer escapes.deinit(allocator);
    try escapes.appendSlice(allocator, "{\"s\":\"");
    for (0..2700) |_| try escapes.appendSlice(allocator, "\\n");
    try escapes.appendSlice(allocator, "\"}");
    _ = try decodeWithin(zerde.json, Long, bound, escapes.items, cfg);
    // CBOR chunks: one long and one short, and one byte each.
    var chunks: std.ArrayList(u8) = .empty;
    defer chunks.deinit(allocator);
    try chunks.appendSlice(allocator, &.{ 0xa1, 0x61, 's', 0x7f, 0x79, 0x0a, 0x8b });
    for (0..2699) |_| try chunks.append(allocator, 'a');
    try chunks.appendSlice(allocator, &.{ 0x61, 'b', 0xff });
    _ = try decodeWithin(zerde.cbor, Long, bound, chunks.items, cfg);
    var singles: std.ArrayList(u8) = .empty;
    defer singles.deinit(allocator);
    try singles.appendSlice(allocator, &.{ 0xa1, 0x61, 's', 0x7f });
    for (0..2700) |_| try singles.appendSlice(allocator, &.{ 0x61, 'a' });
    try singles.append(allocator, 0xff);
    _ = try decodeWithin(zerde.cbor, Long, bound, singles.items, cfg);

    // An optional and a union variant: the same, with 999 bytes and an escape.
    const Optional = struct {
        s: ?[]const u8 = null,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .s = .{ .max_len = 1000, .optional = .absent } } };
    };
    const Variant = union(enum) { a: []const u8, b };
    const Holder2 = struct {
        v: Variant,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    var small: std.ArrayList(u8) = .empty;
    defer small.deinit(allocator);
    for (0..999) |_| try small.append(allocator, 'a');
    var optional_input: std.ArrayList(u8) = .empty;
    defer optional_input.deinit(allocator);
    try optional_input.appendSlice(allocator, "{\"s\":\"");
    try optional_input.appendSlice(allocator, small.items);
    try optional_input.appendSlice(allocator, "\\n\"}");
    const small_cfg = .{ .max_string_len = 1000 };
    _ = try decodeWithin(zerde.json, Optional, comptime wire.maxArenaSize(zerde.json, Optional, .{}, small_cfg), optional_input.items, small_cfg);
    var variant_input: std.ArrayList(u8) = .empty;
    defer variant_input.deinit(allocator);
    try variant_input.appendSlice(allocator, "{\"v\":{\"a\":\"");
    try variant_input.appendSlice(allocator, small.items);
    try variant_input.appendSlice(allocator, "\\n\"}}");
    _ = try decodeWithin(zerde.json, Holder2, comptime wire.maxArenaSize(zerde.json, Holder2, .{}, small_cfg), variant_input.items, small_cfg);
    // Base64 whose token is built and then decoded: 2700 bytes of bytes are a token of 3600.
    const Bytes = struct {
        b: zerde.ByteString,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .b = .{ .max_len = 2700 } } };
    };
    const bytes_cfg = .{ .max_string_len = 8192, .bytes = zerde.json.BytesEncoding.base64 };
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(allocator);
    try token.appendSlice(allocator, "{\"b\":\"");
    for (0..3596) |_| try token.append(allocator, 'A');
    try token.appendSlice(allocator, "\\/AAA\"}");
    _ = try decodeWithin(zerde.json, Bytes, comptime wire.maxArenaSize(zerde.json, Bytes, .{}, bytes_cfg), token.items, bytes_cfg);
}

// ---- pooled transient, union variant bounds, strict mode, large limits -----------------------------

test "a pooled list of long escaped strings fits an arena of exactly the bound" {
    const Pooled = struct {
        names: []const []const u8,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const cfg = .{ .max_items = 4, .max_string_len = 1000 };
    const bound = comptime wire.maxArenaSize(zerde.json, Pooled, .{}, cfg);
    // One string of 1000 bytes built while the list holds nothing else: its buffer is 1.5 times its length and 128 more.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, "{\"names\":[\"");
    for (0..999) |_| try input.append(allocator, 'a');
    try input.appendSlice(allocator, "\\n\"]}");
    const used = try decodeWithin(zerde.json, Pooled, bound, input.items, cfg);
    try std.testing.expect(used <= bound);
    // The smallest arena that works is found by trying: it holds the string's buffer, 1.5 times its length. (The bound
    // charges each item of the budget a string, so the term for the buffer is not what decides it here; it is pinned
    // by the figure of a pooled string in the bound figures above.)
    var low: usize = 0;
    var high: usize = bound;
    while (low + 1 < high) {
        const middle = (low + high) / 2;
        const region = try allocator.alignedAlloc(u8, .@"16", input.items.len + middle);
        defer allocator.free(region);
        @memcpy(region[0..input.items.len], input.items);
        var arena = std.heap.FixedBufferAllocator.init(region[input.items.len..]);
        if (wire.decode(zerde.json, Pooled, &arena, @intFromPtr(region.ptr), region[0..input.items.len], .{}, cfg)) |_| {
            high = middle;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            low = middle;
        }
    }
    try std.testing.expect(high >= 1000);
    try std.testing.expect(high <= bound);
}

test "a bound set on a union variant applies to its payload, and to the arena bound" {
    const Choice = union(enum) {
        raw: zerde.cbor.Raw,
        text: []const u8,
        none,
        pub const serde = .{ .fields = .{ .raw = .{ .max_len = 64 }, .text = .{ .max_len = 5 } } };
    };
    const Holder = struct {
        c: Choice,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    // The typed read applies them.
    const ok = try zerde.cbor.parseSlice(Holder, allocator, &.{ 0xa1, 0x61, 'c', 0xa1, 0x64, 't', 'e', 'x', 't', 0x65, 'h', 'e', 'l', 'l', 'o' });
    defer zerde.free(allocator, ok);
    try std.testing.expectEqualStrings("hello", ok.c.text);
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSlice(Holder, allocator, &.{ 0xa1, 0x61, 'c', 0xa1, 0x64, 't', 'e', 'x', 't', 0x66, 'h', 'e', 'l', 'l', 'o', '!' }));
    var long_raw: std.ArrayList(u8) = .empty;
    defer long_raw.deinit(allocator);
    try long_raw.appendSlice(allocator, &.{ 0xa1, 0x61, 'c', 0xa1, 0x63, 'r', 'a', 'w', 0x58, 100 });
    for (0..100) |_| try long_raw.append(allocator, 0);
    try std.testing.expectError(error.LengthOutOfBounds, zerde.cbor.parseSlice(Holder, allocator, long_raw.items));
    try std.testing.expectError(error.LengthOutOfBounds, zerde.json.parseSlice(struct { c: union(enum) {
        text: []const u8,
        pub const serde = .{ .fields = .{ .text = .{ .max_len = 3 } } };
    } }, allocator, "{\"c\":{\"text\":\"abcd\"}}"));
    // The arena bound uses them: a 16 MiB string allowance does not make a 64-byte raw item cost 16 MiB.
    const loose = .{ .max_string_len = 16 * 1024 * 1024 };
    const bound = comptime wire.maxArenaSize(zerde.cbor, Holder, .{}, loose);
    try std.testing.expect(bound < 100_000);
    reflectVariantBounds: {
        const variants = comptime zerde.reflect.variants(Choice, .{});
        try std.testing.expectEqual(@as(usize, 64), variants[0].bounds.max_len);
        try std.testing.expectEqual(@as(usize, 5), variants[1].bounds.max_len);
        break :reflectVariantBounds;
    }
}

test "a strict read rewrites no string and builds no list: the bound says so" {
    const Req = Request(zerde.cbor.Raw);
    const lenient_cfg = .{ .max_items = 8192, .max_string_len = 262144, .max_input_bytes = 32768, .max_depth = 16 };
    const strict_cfg = .{ .max_items = 8192, .max_string_len = 262144, .max_input_bytes = 32768, .max_depth = 16, .mode = zerde.cbor.Mode.strict };
    const lenient = comptime wire.maxArenaSize(zerde.cbor, Req, .{}, lenient_cfg);
    const strict_bound = comptime wire.maxArenaSize(zerde.cbor, Req, .{}, strict_cfg);
    try std.testing.expect(strict_bound < lenient);
    // The effects list is a definite array of 64: 64 * 128 bytes of Effect and the wire copy, exactly, and the
    // reader's keys for a raw item; no string, no growth.
    try std.testing.expect(strict_bound < lenient - 2 * 32768 + 1);
    // Strict input at the worst: a deterministic raw item that is a chain of maps used as keys, in 64 effects of
    // definite strings and arrays, decoded into an arena of exactly the strict bound.
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(allocator);
    try inner.appendSlice(allocator, &.{ 0xb9, 0x0b, 0xb8 });
    for (0..3000) |key| {
        if (key < 24) {
            try inner.appendSlice(allocator, &.{ @intCast(key), 0x00 });
        } else if (key < 256) {
            try inner.appendSlice(allocator, &.{ 0x18, @intCast(key), 0x00 });
        } else {
            try inner.appendSlice(allocator, &.{ 0x19, @intCast(key >> 8), @intCast(key & 0xff), 0x00 });
        }
    }
    for (0..5) |_| {
        var next: std.ArrayList(u8) = .empty;
        try next.append(allocator, 0xa1);
        try next.appendSlice(allocator, inner.items);
        try next.append(allocator, 0x00);
        inner.deinit(allocator);
        inner = next;
    }
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xa1, 0x67, 'e', 'f', 'f', 'e', 'c', 't', 's', 0x81 });
    // An effect's keys in the order a strict read needs: key, meta, payload, record_type.
    try input.appendSlice(allocator, &.{ 0xa4, 0x63, 'k', 'e', 'y', 0x41, 1, 0x64, 'm', 'e', 't', 'a' });
    try input.appendSlice(allocator, inner.items);
    try input.appendSlice(allocator, &.{ 0x67, 'p', 'a', 'y', 'l', 'o', 'a', 'd', 0x41, 1, 0x6b, 'r', 'e', 'c', 'o', 'r', 'd', '_', 't', 'y', 'p', 'e', 0x61, 'a' });
    const used = try decodeWithin(zerde.cbor, Req, strict_bound, input.items, strict_cfg);
    try std.testing.expect(used <= strict_bound);
    // Many effects, definite everything.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(allocator);
    try many.appendSlice(allocator, &.{ 0xa1, 0x67, 'e', 'f', 'f', 'e', 'c', 't', 's', 0x98, 64 });
    for (0..64) |_| {
        try many.appendSlice(allocator, &.{ 0xa4, 0x63, 'k', 'e', 'y', 0x41, 1, 0x64, 'm', 'e', 't', 'a', 0xa0 });
        try many.appendSlice(allocator, &.{ 0x67, 'p', 'a', 'y', 'l', 'o', 'a', 'd', 0x41, 1, 0x6b, 'r', 'e', 'c', 'o', 'r', 'd', '_', 't', 'y', 'p', 'e', 0x61, 'a' });
    }
    const used_many = try decodeWithin(zerde.cbor, Req, strict_bound, many.items, strict_cfg);
    try std.testing.expect(used_many <= strict_bound);
    // The lenient reader would have been refused what the strict bound relies on: chunked text is not strict.
    var chunked: std.ArrayList(u8) = .empty;
    defer chunked.deinit(allocator);
    try chunked.appendSlice(allocator, &.{ 0xa1, 0x67, 'e', 'f', 'f', 'e', 'c', 't', 's', 0x81, 0xa4, 0x63, 'k', 'e', 'y', 0x41, 1, 0x64, 'm', 'e', 't', 'a', 0xa0 });
    try chunked.appendSlice(allocator, &.{ 0x67, 'p', 'a', 'y', 'l', 'o', 'a', 'd', 0x41, 1, 0x6b, 'r', 'e', 'c', 'o', 'r', 'd', '_', 't', 'y', 'p', 'e', 0x7f, 0x61, 'a', 0xff });
    try std.testing.expectError(error.NonDeterministicEncoding, decodeWithin(zerde.cbor, Req, strict_bound, chunked.items, strict_cfg));
}

test "figures for a strict read, and for a union variant that holds a bounded list" {
    const Row = struct {
        a: u32,
        b: u32,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const Rows = struct {
        rows: []const Row,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .rows = .{ .max_len = 10 } } };
    };
    const Text = struct {
        s: []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .s = .{ .max_len = 100 } } };
    };
    const Blob3 = struct {
        b: zerde.ByteString,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .b = .{ .max_len = 90 } } };
    };
    const strict_cfg = .{ .mode = zerde.cbor.Mode.strict };
    // Nothing is rewritten and each list is allocated once, at its exact size: 10 * 8 + 3, the wire array 10 * 8 + 16.
    try std.testing.expectEqual(@as(usize, 256), wire.maxArenaSize(zerde.cbor, Text, .{}, strict_cfg));
    // A raw item of a strict read keeps no key record: it costs nothing, and a lenient one is charged for them.
    const Raws4 = struct {
        r: zerde.cbor.Raw,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .r = .{ .max_len = 400 } } };
    };
    try std.testing.expectEqual(@as(usize, 256), wire.maxArenaSize(zerde.cbor, Raws4, .{}, strict_cfg));
    try std.testing.expect(wire.maxArenaSize(zerde.cbor, Raws4, .{}, .{}) > 100_000);
    // And it decodes a raw item of 130 integer keys in an arena of exactly that.
    var keys: std.ArrayList(u8) = .empty;
    defer keys.deinit(allocator);
    try keys.appendSlice(allocator, &.{ 0xa1, 0x61, 'r', 0xb8, 130 });
    for (0..130) |index| try keys.appendSlice(allocator, &.{ 0x18, @as(u8, @intCast(index + 24)), 0x00 });
    const used = try decodeWithin(zerde.cbor, Raws4, 256, keys.items, strict_cfg);
    try std.testing.expectEqual(@as(usize, 0), used);
    try std.testing.expectEqual(@as(usize, 256), wire.maxArenaSize(zerde.cbor, Blob3, .{}, strict_cfg));
    try std.testing.expectEqual(@as(usize, 83 + 256), wire.maxArenaSize(zerde.cbor, Rows, .{}, strict_cfg));
    // A strict list that draws on the budget costs its size and alignment per item.
    const Drawn = struct {
        xs: []const []const u8,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    try std.testing.expectEqual(@as(usize, (8 + 4) * 10 + 256), wire.maxArenaSize(zerde.cbor, Drawn, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_items = 10 }));
    // A variant with a list of its own bound: typed 139 + 35, wire 4 * 8 + 16, with no budget needed.
    const Pick = union(enum) {
        rows: []const Row,
        none,
        pub const serde = .{ .fields = .{ .rows = .{ .max_len = 4 } } };
    };
    try std.testing.expectEqual(@as(usize, 139 + 35 + 256), wire.maxArenaSize(zerde.json, Pick, .{}, .{}));
}

test "the bound is computed in 64 bits, so limits that overflow a 32-bit usize do not stop it" {
    const Big = struct {
        names: []const []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .names = .{ .max_len = 4096 } } };
    };
    // 4,096 strings of 4 MiB each is 16 GiB by the fields; the input of 8 MiB is what the bound rests on.
    const cfg = .{ .max_items = 8192, .max_string_len = 4 * 1024 * 1024, .max_input_bytes = 8 * 1024 * 1024 };
    const bound = comptime wire.maxArenaSize(zerde.json, Big, .{}, cfg);
    try std.testing.expect(bound > 8 * 1024 * 1024 and bound < 16 * 1024 * 1024);
    // (19,227,081 on a 64-bit target and 19,043,431 on wasm32, where slices are half the size: the arithmetic is in 64 bits.)
}

// ---- keys of open union maps, the format decides strictness -----------------------------------------

fn NestedUnion(comptime depth: usize) type {
    if (depth == 0) return union(enum) { leaf: u8 };
    return union(enum) { next: NestedUnion(depth - 1), leaf: u8 };
}

fn nestedUnionInput(comptime depth: usize, out: *std.ArrayList(u8)) !void {
    // {"next": {"next": ... {"leaf": 1}}} in deterministic CBOR (keys of equal length, one entry each).
    for (0..depth) |_| try out.appendSlice(allocator, &.{ 0xa1, 0x64, 'n', 'e', 'x', 't' });
    try out.appendSlice(allocator, &.{ 0xa1, 0x64, 'l', 'e', 'a', 'f', 0x01 });
}

test "a union's key is not allocated: eight nested unions fit the bound of a schema without any, in both modes" {
    const Root = struct {
        u: NestedUnion(8),
        pub const serde = .{ .deny_unknown_fields = true };
    };
    inline for (.{ .lenient, .strict }) |mode| {
        const cfg = .{ .mode = if (mode == .strict) zerde.cbor.Mode.strict else zerde.cbor.Mode.lenient };
        const bound = comptime wire.maxArenaSize(zerde.cbor, Root, .{}, cfg);
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(allocator);
        try input.appendSlice(allocator, &.{ 0xa1, 0x61, 'u' });
        try nestedUnionInput(8, &input);
        const used = try decodeWithin(zerde.cbor, Root, bound, input.items, cfg);
        try std.testing.expect(used <= bound);
    }
    // The bound has no term for the keys, in either format.
    try std.testing.expectEqual(@as(usize, 256), wire.maxArenaSize(zerde.cbor, Root, .{}, .{}));
    try std.testing.expectEqual(@as(usize, 256), wire.maxArenaSize(zerde.json, Root, .{}, .{}));
}

test "figures: a field's own limit against the config's" {
    // The field's max_len and the config's max_string_len: the smaller is the bound (50).
    const Both = struct {
        s: []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .s = .{ .max_len = 100 } } };
    };
    try std.testing.expectEqual(@as(usize, 50 + 256), wire.maxArenaSize(zerde.json, Both, .{}, .{ .max_string_len = 50 }));
}

const RecTree = union(enum) {
    node: []const RecTree,
    leaf: u8,
};

test "a union that recurses through a list is charged down to max_depth and no further" {
    const Holder3 = struct {
        t: RecTree,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const cfg = .{ .max_depth = 11, .max_items = 64 };
    const bound = comptime wire.maxArenaSize(zerde.cbor, Holder3, .{}, cfg);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xa1, 0x61, 't' });
    for (0..4) |_| try input.appendSlice(allocator, &.{ 0xa1, 0x64, 'n', 'o', 'd', 'e', 0x81 });
    try input.appendSlice(allocator, &.{ 0xa1, 0x64, 'l', 'e', 'a', 'f', 0x01 });
    const used = try decodeWithin(zerde.cbor, Holder3, bound, input.items, cfg);
    try std.testing.expect(used <= bound);
    // Deeper than max_depth is refused by the reader, not by the arena.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(allocator);
    try deep.appendSlice(allocator, &.{ 0xa1, 0x61, 't' });
    for (0..9) |_| try deep.appendSlice(allocator, &.{ 0xa1, 0x64, 'n', 'o', 'd', 'e', 0x81 });
    try deep.appendSlice(allocator, &.{ 0xa1, 0x64, 'l', 'e', 'a', 'f', 0x01 });
    try std.testing.expectError(error.CborNestingTooDeep, decodeWithin(zerde.cbor, Holder3, bound, deep.items, cfg));
}

// ---- keys are compared where they are read, and never allocated -------------------------------------------------

fn longName(comptime length: usize, comptime fill: u8) []const u8 {
    const bytes: [length]u8 = @splat(fill);
    return &bytes;
}

const Named60 = union(enum) {
    sixty: []const u32,
    other: u8,
    pub const serde = .{ .fields = .{ .sixty = .{ .rename = longName(60, 'a'), .max_len = 300 }, .other = .{ .rename = longName(200, 'b') } } };
};

const Holder60 = struct {
    u: Named60,
    pub const serde = .{ .deny_unknown_fields = true };
};

test "a union key of 60 or 200 characters, escaped or chunked, leaves nothing behind it: 300 elements fit the bound" {
    const cfg = .{ .max_items = 400, .max_string_len = 256 };
    const bound = comptime wire.maxArenaSize(zerde.json, Holder60, .{}, cfg);
    // JSON: every character of the key an escape (\u0061), then a payload of 300 numbers.
    var json_input: std.ArrayList(u8) = .empty;
    defer json_input.deinit(allocator);
    try json_input.appendSlice(allocator, "{\"u\":{\"");
    for (0..60) |_| try json_input.appendSlice(allocator, "\\u0061");
    try json_input.appendSlice(allocator, "\":[");
    for (0..300) |index| {
        if (index != 0) try json_input.append(allocator, ',');
        try json_input.append(allocator, '7');
    }
    try json_input.appendSlice(allocator, "]}}");
    const json_used = try decodeWithin(zerde.json, Holder60, bound, json_input.items, cfg);
    try std.testing.expect(json_used <= bound);
    // The 200-character name, with a payload of one byte.
    var long_input: std.ArrayList(u8) = .empty;
    defer long_input.deinit(allocator);
    try long_input.appendSlice(allocator, "{\"u\":{\"");
    for (0..200) |_| try long_input.appendSlice(allocator, "\\u0062");
    try long_input.appendSlice(allocator, "\":7}}");
    _ = try decodeWithin(zerde.json, Holder60, bound, long_input.items, cfg);
    // A key longer than every name is no variant, and is not allocated either.
    var too_long: std.ArrayList(u8) = .empty;
    defer too_long.deinit(allocator);
    try too_long.appendSlice(allocator, "{\"u\":{\"");
    for (0..250) |_| try too_long.appendSlice(allocator, "\\u0062");
    try too_long.appendSlice(allocator, "\":7}}");
    try std.testing.expectError(error.InvalidEnumTag, decodeWithin(zerde.json, Holder60, bound, too_long.items, cfg));

    // CBOR: the key in chunks of one byte, and in two chunks, then the payload.
    var cbor_input: std.ArrayList(u8) = .empty;
    defer cbor_input.deinit(allocator);
    try cbor_input.appendSlice(allocator, &.{ 0xa1, 0x61, 'u', 0xa1, 0x7f });
    for (0..60) |_| try cbor_input.appendSlice(allocator, &.{ 0x61, 'a' });
    try cbor_input.appendSlice(allocator, &.{ 0xff, 0x99, 0x01, 0x2c });
    for (0..300) |_| try cbor_input.append(allocator, 0x07);
    const cbor_bound = comptime wire.maxArenaSize(zerde.cbor, Holder60, .{}, cfg);
    const cbor_used = try decodeWithin(zerde.cbor, Holder60, cbor_bound, cbor_input.items, cfg);
    try std.testing.expect(cbor_used <= cbor_bound);
    var split: std.ArrayList(u8) = .empty;
    defer split.deinit(allocator);
    try split.appendSlice(allocator, &.{ 0xa1, 0x61, 'u', 0xa1, 0x7f, 0x78, 0x78 });
    for (0..120) |_| try split.append(allocator, 'b');
    try split.appendSlice(allocator, &.{ 0x78, 0x50 });
    for (0..80) |_| try split.append(allocator, 'b');
    try split.appendSlice(allocator, &.{ 0xff, 0x07 });
    _ = try decodeWithin(zerde.cbor, Holder60, cbor_bound, split.items, cfg);
    // Too long for every name; invalid UTF-8 in a chunk is still refused.
    var bad_chunk: std.ArrayList(u8) = .empty;
    defer bad_chunk.deinit(allocator);
    try bad_chunk.appendSlice(allocator, &.{ 0xa1, 0x61, 'u', 0xa1, 0x7f, 0x61, 0xff, 0xff, 0x07 });
    try std.testing.expectError(error.InvalidUtf8, decodeWithin(zerde.cbor, Holder60, cbor_bound, bad_chunk.items, cfg));
    var no_end: std.ArrayList(u8) = .empty;
    defer no_end.deinit(allocator);
    try no_end.appendSlice(allocator, &.{ 0xa1, 0x61, 'u', 0xa1, 0x7f, 0x61, 'a' });
    try std.testing.expectError(error.UnexpectedEndOfInput, decodeWithin(zerde.cbor, Holder60, cbor_bound, no_end.items, cfg));
}

const WideNames = struct {
    first: []const u32,
    second: []const u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .first = .{ .rename = longName(80, 'f'), .max_len = 300 }, .second = .{ .rename = longName(70, 's'), .max_len = 20 } } };
};

test "a struct's field names, escaped or chunked, are matched without being allocated, before a 300-element payload" {
    const cfg = .{ .max_items = 400, .max_string_len = 256 };
    const bound = comptime wire.maxArenaSize(zerde.json, WideNames, .{}, cfg);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, "{\"");
    for (0..80) |_| try input.appendSlice(allocator, "\\u0066");
    try input.appendSlice(allocator, "\":[");
    for (0..300) |index| {
        if (index != 0) try input.append(allocator, ',');
        try input.append(allocator, '7');
    }
    try input.appendSlice(allocator, "],\"");
    for (0..70) |_| try input.appendSlice(allocator, "\\u0073");
    try input.appendSlice(allocator, "\":\"x\"}");
    const used = try decodeWithin(zerde.json, WideNames, bound, input.items, cfg);
    try std.testing.expect(used <= bound);
    // CBOR chunked names, a field after the long list, and an unknown long name refused.
    var cbor_input: std.ArrayList(u8) = .empty;
    defer cbor_input.deinit(allocator);
    try cbor_input.appendSlice(allocator, &.{ 0xa2, 0x7f });
    for (0..80) |_| try cbor_input.appendSlice(allocator, &.{ 0x61, 'f' });
    try cbor_input.appendSlice(allocator, &.{ 0xff, 0x99, 0x01, 0x2c });
    for (0..300) |_| try cbor_input.append(allocator, 0x07);
    try cbor_input.appendSlice(allocator, &.{0x7f});
    for (0..70) |_| try cbor_input.appendSlice(allocator, &.{ 0x61, 's' });
    try cbor_input.appendSlice(allocator, &.{ 0xff, 0x61, 'x' });
    const cbor_bound = comptime wire.maxArenaSize(zerde.cbor, WideNames, .{}, cfg);
    const cbor_used = try decodeWithin(zerde.cbor, WideNames, cbor_bound, cbor_input.items, cfg);
    try std.testing.expect(cbor_used <= cbor_bound);
    // The names are the same through the typed read, in any allocator.
    const parsed = try zerde.cbor.parseSlice(WideNames, allocator, cbor_input.items);
    defer zerde.free(allocator, parsed);
    try std.testing.expectEqual(@as(usize, 300), parsed.first.len);
    try std.testing.expectEqualStrings("x", parsed.second);
    var unknown: std.ArrayList(u8) = .empty;
    defer unknown.deinit(allocator);
    try unknown.appendSlice(allocator, &.{ 0xa1, 0x7f });
    for (0..90) |_| try unknown.appendSlice(allocator, &.{ 0x61, 'q' });
    try unknown.appendSlice(allocator, &.{ 0xff, 0x00 });
    try std.testing.expectError(error.UnknownField, zerde.cbor.parseSlice(WideNames, allocator, unknown.items));
}

test "an enum and a bare union variant, escaped or chunked, are matched without allocating" {
    const Color = enum { red, green, blue_green_with_a_long_name };
    const Holder4 = struct {
        c: Color,
        u: union(enum) { plain, with_data: u8 },
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const json = try zerde.json.parseSlice(Holder4, allocator, "{\"c\":\"blue_green_with_a_\\u006cong_name\",\"u\":\"pl\\u0061in\"}");
    try std.testing.expectEqual(Color.blue_green_with_a_long_name, json.c);
    try std.testing.expectEqual(std.meta.Tag(@TypeOf(json.u)).plain, std.meta.activeTag(json.u));
    try std.testing.expectError(error.InvalidEnumTag, zerde.json.parseSlice(Holder4, allocator, "{\"c\":\"reddish_but_far_too_long_to_be_any_of_the_names\",\"u\":\"plain\"}"));
    const cbor = try zerde.cbor.parseSlice(Holder4, allocator, &.{ 0xa2, 0x61, 'c', 0x7f, 0x63, 'r', 'e', 'd', 0xff, 0x61, 'u', 0x65, 'p', 'l', 'a', 'i', 'n' });
    try std.testing.expectEqual(Color.red, cbor.c);
    try std.testing.expectError(error.InvalidUtf8, zerde.cbor.parseSlice(Holder4, allocator, &.{ 0xa2, 0x61, 'c', 0x7f, 0x61, 0xff, 0xff, 0x61, 'u', 0x65, 'p', 'l', 'a', 'i', 'n' }));
}

const Tiny200 = struct {
    u: union(enum) {
        other: u8,
        pub const serde = .{ .fields = .{ .other = .{ .rename = longName(200, 'b') } } };
    },
    wide: u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .wide = .{ .rename = longName(150, 'w') } } };
};

test "a key of 200 characters needs no arena of its own: the bound of a schema with no allocation holds" {
    const bound = comptime wire.maxArenaSize(zerde.json, Tiny200, .{}, .{});
    try std.testing.expectEqual(@as(usize, 256), bound);
    var json_input: std.ArrayList(u8) = .empty;
    defer json_input.deinit(allocator);
    try json_input.appendSlice(allocator, "{\"u\":{\"");
    for (0..200) |_| try json_input.appendSlice(allocator, "\\u0062");
    try json_input.appendSlice(allocator, "\":7},\"");
    for (0..150) |_| try json_input.appendSlice(allocator, "\\u0077");
    try json_input.appendSlice(allocator, "\":1}");
    _ = try decodeWithin(zerde.json, Tiny200, bound, json_input.items, .{});
    var cbor_input: std.ArrayList(u8) = .empty;
    defer cbor_input.deinit(allocator);
    try cbor_input.appendSlice(allocator, &.{ 0xa2, 0x61, 'u', 0xa1, 0x7f });
    for (0..200) |_| try cbor_input.appendSlice(allocator, &.{ 0x61, 'b' });
    try cbor_input.appendSlice(allocator, &.{ 0xff, 0x07, 0x7f });
    for (0..150) |_| try cbor_input.appendSlice(allocator, &.{ 0x61, 'w' });
    try cbor_input.appendSlice(allocator, &.{ 0xff, 0x01 });
    _ = try decodeWithin(zerde.cbor, Tiny200, comptime wire.maxArenaSize(zerde.cbor, Tiny200, .{}, .{}), cbor_input.items, .{});
}

test "a key read without allocating is as strictly checked as one that is allocated" {
    const Short = union(enum) {
        ab: u8,
        abcd: u8,
    };
    const Holder5 = struct {
        u: Short,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    // A key that does not fit the buffer is no name, though its first chunk is one.
    try std.testing.expectError(error.InvalidEnumTag, zerde.cbor.parseSlice(Holder5, allocator, &.{ 0xa1, 0x61, 'u', 0xa1, 0x7f, 0x62, 'a', 'b', 0x65, 'c', 'd', 'e', 'f', 'g', 0xff, 0x07 }));
    const exact = try zerde.cbor.parseSlice(Holder5, allocator, &.{ 0xa1, 0x61, 'u', 0xa1, 0x7f, 0x62, 'a', 'b', 0x62, 'c', 'd', 0xff, 0x07 });
    try std.testing.expectEqual(@as(u8, 7), exact.u.abcd);
    // A chunk of another kind, text that is not UTF-8 in a definite key, and a key past max_string_len in escapes.
    try std.testing.expectError(error.InvalidStringChunk, zerde.cbor.parseSlice(Holder5, allocator, &.{ 0xa1, 0x61, 'u', 0xa1, 0x7f, 0x41, 'a', 0xff, 0x07 }));
    try std.testing.expectError(error.InvalidUtf8, zerde.cbor.parseSlice(Holder5, allocator, &.{ 0xa1, 0x61, 'u', 0xa1, 0x61, 0xff, 0x07 }));
    try std.testing.expectError(error.StringTooLong, zerde.json.parseSliceWith(Holder5, allocator, "{\"u\":{\"\\u0061\\u0062\\u0063\\u0064\":7}}", .{}, .{ .max_string_len = 3 }));
    const ok = try zerde.json.parseSliceWith(Holder5, allocator, "{\"u\":{\"\\u0061\\u0062\\u0063\\u0064\":7}}", .{}, .{ .max_string_len = 4 });
    try std.testing.expectEqual(@as(u8, 7), ok.u.abcd);
}

test "a key no field declares is refused as it is read, and allocates nothing" {
    const bound = comptime wire.maxArenaSize(zerde.cbor, Tiny200, .{}, .{});
    try std.testing.expectEqual(@as(usize, 256), bound);
    // Chunked, 1000 bytes: no buffer of its own, and not recorded.
    var chunked: std.ArrayList(u8) = .empty;
    defer chunked.deinit(allocator);
    try chunked.appendSlice(allocator, &.{ 0xa1, 0x7f });
    for (0..1000) |_| try chunked.appendSlice(allocator, &.{ 0x61, 'z' });
    try chunked.appendSlice(allocator, &.{ 0xff, 0x01 });
    try std.testing.expectError(error.UnknownField, decodeWithin(zerde.cbor, Tiny200, bound, chunked.items, .{}));
    // Definite and integer keys likewise, and a key past max_string_len keeps its own error.
    // (In an arena of 16 bytes, under the 24 a record of the key would take.)
    try std.testing.expectError(error.UnknownField, decodeWithin(zerde.cbor, Tiny200, 16, &.{ 0xa1, 0x63, 'z', 'z', 'z', 0x01 }, .{}));
    try std.testing.expectError(error.UnknownField, decodeWithin(zerde.cbor, Tiny200, 16, &.{ 0xa1, 0x05, 0x01 }, .{}));
    try std.testing.expectError(error.StringTooLong, decodeWithin(zerde.cbor, Tiny200, bound, chunked.items, .{ .max_string_len = 100 }));
    // Where members are not denied the key is checked and recorded as before: a repeated unknown key is refused.
    const Open = struct {
        a: u8,
    };
    try std.testing.expectError(error.DuplicateField, zerde.cbor.parseSlice(Open, allocator, &.{ 0xa3, 0x7f, 0x61, 'z', 0xff, 0x01, 0x7f, 0x61, 'z', 0xff, 0x02, 0x61, 'a', 0x03 }));
    try std.testing.expectError(error.InvalidUtf8, zerde.cbor.parseSlice(Open, allocator, &.{ 0xa2, 0x61, 0xff, 0x01, 0x61, 'a', 0x03 }));
}

test "an escaped string ends at max_string_len, and a long key is no name, in JSON" {
    const Short = union(enum) {
        ab: u8,
        abcd: u8,
    };
    const Holder6 = struct {
        u: Short,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    // The run after the last escape is what takes the key over the limit.
    try std.testing.expectError(error.StringTooLong, zerde.json.parseSliceWith(Holder6, allocator, "{\"u\":{\"\\u0061bcd\":7}}", .{}, .{ .max_string_len = 3 }));
    const exact = try zerde.json.parseSliceWith(Holder6, allocator, "{\"u\":{\"\\u0061bcd\":7}}", .{}, .{ .max_string_len = 4 });
    try std.testing.expectEqual(@as(u8, 7), exact.u.abcd);
    // The characters that fit are not a name when more follow: "abcd" then "e" is not "abcd".
    try std.testing.expectError(error.InvalidEnumTag, zerde.json.parseSlice(Holder6, allocator, "{\"u\":{\"ab\\u0063\\u0064\\u0065\":7}}"));
    const matched = try zerde.json.parseSlice(Holder6, allocator, "{\"u\":{\"ab\\u0063\\u0064\":7}}");
    try std.testing.expectEqual(@as(u8, 7), matched.u.abcd);
}

// ---- JSON float text: the shortest digits, laid out as ECMAScript's Number::toString (RFC 8785) -----------------------

fn expectFloatText(expected: []const u8, value: anytype) !void {
    var buffer: [zerde.json.float_text_max]u8 = undefined;
    try std.testing.expectEqualStrings(expected, zerde.json.floatText(&buffer, value));
}

test "a JSON float is written as the shortest digits that read back, in ECMAScript's layout" {
    // Decimal from 1e-6 up to 1e21, whole numbers without a point.
    try expectFloatText("0", @as(f64, 0));
    try expectFloatText("-0", @as(f64, -0.0));
    try expectFloatText("1", @as(f64, 1));
    try expectFloatText("100", @as(f64, 100));
    try expectFloatText("-1.5", @as(f64, -1.5));
    try expectFloatText("0.1", @as(f64, 0.1));
    var tenth: f64 = 0.1;
    tenth += 0.2;
    try expectFloatText("0.30000000000000004", tenth);
    try expectFloatText("123456789012345680000", @as(f64, 123456789012345678901.0));
    try expectFloatText("0.000001", @as(f64, 1e-6));
    try expectFloatText("0.0000012345", @as(f64, 1.2345e-6));
    // Scientific beyond them, with a sign on a positive exponent.
    try expectFloatText("1e+21", @as(f64, 1e21));
    try expectFloatText("1.5e+300", @as(f64, 1.5e300));
    try expectFloatText("1e-7", @as(f64, 1e-7));
    try expectFloatText("1.2345e-7", @as(f64, 1.2345e-7));
    try expectFloatText("1.7976931348623157e+308", std.math.floatMax(f64));
    try expectFloatText("-1.7976931348623157e+308", -std.math.floatMax(f64));
    try expectFloatText("5e-324", std.math.floatTrueMin(f64));
    try expectFloatText("3.4028235e+38", std.math.floatMax(f32));
    try expectFloatText("1e-45", std.math.floatTrueMin(f32));
    try expectFloatText("0.1", @as(f32, 0.1));
}

test "a JSON float round-trips exactly, and no float of any type is longer than float_text_max, or 25 bytes for f64" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var buffer: [zerde.json.float_text_max]u8 = undefined;
    for (0..20_000) |_| {
        const bits = random.int(u64);
        const value: f64 = @bitCast(bits);
        if (!std.math.isFinite(value)) continue;
        const text = zerde.json.floatText(&buffer, value);
        try std.testing.expect(text.len <= 25);
        try std.testing.expectEqual(bits, @as(u64, @bitCast(try std.fmt.parseFloat(f64, text))));
        const small: f32 = @bitCast(random.int(u32));
        if (!std.math.isFinite(small)) continue;
        const small_text = zerde.json.floatText(&buffer, small);
        try std.testing.expectEqual(@as(u32, @bitCast(small)), @as(u32, @bitCast(try std.fmt.parseFloat(f32, small_text))));
    }
    // The widest types, at their extremes.
    inline for (.{ f16, f80, f128 }) |T| {
        inline for (.{ std.math.floatMax(T), -std.math.floatMax(T), std.math.floatTrueMin(T), -std.math.floatTrueMin(T), std.math.floatMin(T), -std.math.floatMin(T), std.math.floatEps(T) }) |value| {
            const text = zerde.json.floatText(&buffer, value);
            try std.testing.expect(text.len <= zerde.json.float_text_max);
            try std.testing.expectEqual(value, try std.fmt.parseFloat(T, text));
        }
    }
}

test "every JSON writer writes a float alike, and a window of min_window holds the widest float of either format" {
    const Reals = struct { a: f64, b: f64, c: f32, d: f64 };
    const value: Reals = .{ .a = -std.math.floatMax(f64), .b = std.math.floatTrueMin(f64), .c = -1.2345e-7, .d = 1e21 };
    try expectJsonText("{\"a\":-1.7976931348623157e+308,\"b\":5e-324,\"c\":-1.2345e-7,\"d\":1e+21}", value, .{}, .{});
    // The dynamic value writers and the value tree agree with the typed writer.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var writer = zerde.json.valueWriter(allocator, &out.writer, .{});
    try writer.beginArray();
    try writer.writeFloat(1e21);
    var tenth: f64 = 0.1;
    tenth += 0.2;
    try writer.writeFloat(tenth);
    try writer.endArray();
    try writer.finish();
    try std.testing.expectEqualStrings("[1e+21,0.30000000000000004]", out.written());
    try expectWindows(zerde.json, Reals, value, .{}, .{});
    try expectWindows(zerde.cbor, Reals, value, .{}, .{});
    try expectWindows(zerde.cbor, Reals, value, .{}, .{ .deterministic = true });
    // Floats in an array are not covered by a field's room: each reserves its own.
    const Series = struct { xs: []const f64 };
    const series: Series = .{ .xs = &.{ -std.math.floatMax(f64), 1.5, std.math.floatTrueMin(f64), 1e21, -1.2345e-7, 100 } };
    try expectWindows(zerde.json, Series, series, .{}, .{});
    try expectWindows(zerde.cbor, Series, series, .{}, .{});
    // One window size for both formats: a float no longer sets it.
    try std.testing.expectEqual(zerde.resumable.Writer(zerde.json, Reals, .{}, .{}).min_window, zerde.resumable.Writer(zerde.cbor, Reals, .{}, .{}).min_window);
    try std.testing.expectEqual(zerde.typed.atomic_room + 6 * 1 + 7, zerde.resumable.Writer(zerde.json, Reals, .{}, .{}).min_window);
}

// ---- strict CBOR read in chunks, resumably ---------------------------------------------------------------------

const chunk_read = .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 64, .max_items = 256 };

/// The value `input` reads as when it arrives in pieces cut at `cuts` (ascending offsets), from an arena.
fn readInChunks(comptime T: type, comptime serde_cfg: anytype, comptime read_cfg: anytype, arena: std.mem.Allocator, input: []const u8, cuts: []const usize) !T {
    var decoder = zerde.resumable.Decoder(T, serde_cfg, read_cfg).init(.{}, arena);
    var start: usize = 0;
    for (cuts) |cut| {
        _ = try decoder.feed(input[start..cut]);
        start = cut;
    }
    _ = try decoder.feed(input[start..]);
    return decoder.finish();
}

/// The deterministic CBOR of `value`, owned by the caller.
fn deterministicBytes(comptime T: type, comptime serde_cfg: anytype, value: T) ![]u8 {
    var out = try writeCbor(value, serde_cfg, .{ .deterministic = true });
    return out.toOwnedSlice();
}

/// What a resumable read gives of the encoding of `value` is what the whole-input strict read gives, which is `value`, for
/// the input cut at every offset, at every pair of offsets (a head and a string cut in two places), and in pieces of
/// every size from 1 to 17 bytes.
fn expectChunked(comptime T: type, comptime serde_cfg: anytype, comptime read_cfg: anytype, value: T) !void {
    const input = try deterministicBytes(T, serde_cfg, value);
    defer allocator.free(input);
    const whole = try zerde.cbor.parseSliceWith(T, allocator, input, serde_cfg, read_cfg);
    defer zerde.free(allocator, whole);
    try std.testing.expectEqualDeep(value, whole);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (0..input.len + 1) |cut| {
        _ = arena_state.reset(.retain_capacity);
        const got = try readInChunks(T, serde_cfg, read_cfg, arena, input, &.{cut});
        try std.testing.expectEqualDeep(whole, got);
        const again = try deterministicBytes(T, serde_cfg, got);
        defer allocator.free(again);
        try std.testing.expectEqualSlices(u8, input, again);
    }
    if (input.len <= 160) {
        for (0..input.len + 1) |first| {
            for (first..input.len + 1) |second| {
                _ = arena_state.reset(.retain_capacity);
                const got = try readInChunks(T, serde_cfg, read_cfg, arena, input, &.{ first, second });
                try std.testing.expectEqualDeep(whole, got);
            }
        }
    }
    var size: usize = 1;
    while (size <= 17) : (size += 1) {
        _ = arena_state.reset(.retain_capacity);
        var cuts: std.ArrayList(usize) = .empty;
        defer cuts.deinit(allocator);
        var at = size;
        while (at < input.len) : (at += size) try cuts.append(allocator, at);
        const got = try readInChunks(T, serde_cfg, read_cfg, arena, input, cuts.items);
        try std.testing.expectEqualDeep(whole, got);
    }
}

test "a resumable read gives the value of the whole strict read, for every way the input is cut" {
    try expectChunked(WireMsg, .{}, chunk_read, sampleMsg());
    try expectChunked(WireMsg, .{}, chunk_read, .{ .id = .{ 0, 0, 0, 0 }, .effects = &.{}, .grid = &.{}, .pair = .{ 0, 65535 } });
}

const ChunkInner = struct {
    a: u8,
    b: ?[]const u8 = null,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .b = .{ .optional = .absent } } };
};

const ChunkKind = enum { alpha, beta, gamma_long_name };
const ChunkLevel = enum(u8) { low = 1, high = 200 };

const ChunkChoice = union(enum) {
    bare,
    num: u32,
    text: []const u8,
    inner: ChunkInner,
    list: []const u16,
    pub const serde = .{ .deny_unknown_fields = true };
};

const ChunkInts = union(enum) {
    zero,
    one: u8,
    two: []const u8,
    three: ChunkInner,
    pub const serde = .{ .fields = .{ .zero = .{ .key = 0 }, .one = .{ .key = 1 }, .two = .{ .key = 2 }, .three = .{ .key = 300 } } };
};

const ChunkMeta = struct {
    name: []const u8,
    kind: ChunkKind,
    level: ChunkLevel,
    ratio: f64,
    small: f32,
    flag: bool,
    count: i64,
    digest: [8]u8,
    blob: zerde.ByteString,
    raw: zerde.cbor.Raw,
    opt_raw: ?zerde.cbor.Raw = null,
    maybe: ?ChunkInner = null,
    labels: zerde.SortedMap(u32) = .{ .entries = &.{} },
    choices: []const ChunkChoice,
    ints: []const ChunkInts,
    nested: []const []const ChunkInner,
    fixed: [3]ChunkInner,
    boxed: *const ChunkInner,
    pub const serde = .{ .deny_unknown_fields = true, .enum_repr = .name, .fields = .{
        .name = .{ .min_len = 1, .max_len = 40 },
        .level = .{},
        .raw = .{ .max_len = 60 },
        .opt_raw = .{ .max_len = 60, .optional = .absent },
        .maybe = .{ .optional = .absent },
        .labels = .{ .max_len = 8 },
        .choices = .{ .max_len = 8 },
        .nested = .{ .max_len = 4, .elem = .{ .max_len = 4 } },
        .count = .{ .min = -1000, .max = 1000 },
    } };
};

const chunk_choices = [_]ChunkChoice{ .bare, .{ .num = 70000 }, .{ .text = "a longer text than a head holds, over twenty-four bytes" }, .{ .inner = .{ .a = 1, .b = "bee" } }, .{ .list = &.{ 1, 300, 70 } } };
const chunk_ints = [_]ChunkInts{ .zero, .{ .one = 9 }, .{ .two = "ii" }, .{ .three = .{ .a = 3 } } };
const chunk_row = [_]ChunkInner{ .{ .a = 1 }, .{ .a = 2, .b = "x" } };
const chunk_nested = [_][]const ChunkInner{ &chunk_row, &.{}, &chunk_row };
const chunk_entries = [_]zerde.SortedMap(u32).Entry{
    .{ .key = "b", .value = 2 },
    .{ .key = "cc", .value = 70000 },
    .{ .key = "aaa", .value = 0 },
};

fn sampleChunkMeta() ChunkMeta {
    return .{
        .name = "chunked meta",
        .kind = .gamma_long_name,
        .level = .high,
        .ratio = 0.1,
        .small = 2.5,
        .flag = true,
        .count = -300,
        .digest = .{ 1, 2, 3, 4, 5, 6, 7, 8 },
        .blob = .{ .bytes = "a byte string of more than twenty-four bytes" },
        // {"a": 1, "c": {"x": h'0102'}, "bb": [1, 2, 3]}
        .raw = .{ .bytes = &.{ 0xa3, 0x61, 'a', 0x01, 0x61, 'c', 0xa1, 0x61, 'x', 0x42, 0x01, 0x02, 0x62, 'b', 'b', 0x83, 0x01, 0x02, 0x03 } },
        .opt_raw = .{ .bytes = &.{ 0x82, 0xf9, 0x3e, 0x00, 0x20 } },
        .maybe = .{ .a = 7, .b = "present" },
        .labels = .{ .entries = &chunk_entries },
        .choices = &chunk_choices,
        .ints = &chunk_ints,
        .nested = &chunk_nested,
        .fixed = .{ .{ .a = 1 }, .{ .a = 2, .b = "two" }, .{ .a = 3 } },
        .boxed = &.{ .a = 4, .b = "boxed" },
    };
}

test "a resumable read of every kind of field gives the whole read's value, for every way the input is cut" {
    var value = sampleChunkMeta();
    try expectChunked(ChunkMeta, .{}, chunk_read, value);
    // The optional fields absent, a sorted map empty.
    value.opt_raw = null;
    value.maybe = null;
    value.labels = .{ .entries = &.{} };
    try expectChunked(ChunkMeta, .{}, chunk_read, value);
}

/// The result of a read, as a value or as its error, to compare the two reads.
fn Outcome(comptime T: type) type {
    return union(enum) { value: T, err: anyerror };
}

fn wholeOutcome(comptime T: type, comptime serde_cfg: anytype, comptime read_cfg: anytype, arena: std.mem.Allocator, input: []const u8) Outcome(T) {
    const value = zerde.cbor.parseSliceWith(T, arena, input, serde_cfg, read_cfg) catch |err| return .{ .err = err };
    return .{ .value = value };
}

fn chunkedOutcome(comptime T: type, comptime serde_cfg: anytype, comptime read_cfg: anytype, arena: std.mem.Allocator, input: []const u8, cuts: []const usize) Outcome(T) {
    const value = readInChunks(T, serde_cfg, read_cfg, arena, input, cuts) catch |err| return .{ .err = err };
    return .{ .value = value };
}

const MutationTally = struct { reads: usize = 0, refused: usize = 0, key_shape: usize = 0 };

/// Every input that differs from `input` in one byte (set to each of `changes`) reads in pieces as it reads whole: the same
/// value or the same error, for the input cut at a few offsets. The one difference allowed is the documented one: a key of a
/// struct that is neither text nor an integer is refused as `UnknownField` where it is met (`typed_resume.zig`), where the
/// whole read reads the key first and so may find it malformed; those are counted in `key_shape`.
fn expectSameOnMutations(comptime T: type, comptime serde_cfg: anytype, comptime read_cfg: anytype, input: []const u8) !MutationTally {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mutable = try allocator.dupe(u8, input);
    defer allocator.free(mutable);
    var tally: MutationTally = .{};
    const changes = [_]u8{ 0x00, 0x01, 0x18, 0x1f, 0x20, 0x61, 0x7f, 0x80, 0xa0, 0xc0, 0xf4, 0xf6, 0xf9, 0xff };
    for (0..input.len) |at| {
        for (changes) |change| {
            if (change == input[at]) continue;
            mutable[at] = change;
            defer mutable[at] = input[at];
            _ = arena_state.reset(.retain_capacity);
            const whole = wholeOutcome(T, serde_cfg, read_cfg, arena, mutable);
            if (whole == .err) tally.refused += 1;
            // Cuts at a few offsets around the changed byte and at both ends.
            for ([_]usize{ 0, 1, at, at + 1, mutable.len / 2, mutable.len }) |cut| {
                if (cut > mutable.len) continue;
                tally.reads += 1;
                const got = chunkedOutcome(T, serde_cfg, read_cfg, arena, mutable, &.{cut});
                switch (whole) {
                    .value => |value| {
                        if (got != .value) {
                            std.debug.print("byte {d} to {x:0>2}, cut {d}: whole read a value, chunks gave {s}\n", .{ at, change, cut, @errorName(got.err) });
                            return error.TestUnexpectedResult;
                        }
                        try std.testing.expectEqualDeep(value, got.value);
                    },
                    .err => |err| {
                        if (got == .err and got.err == err) continue;
                        if (got == .err and got.err == error.UnknownField) {
                            tally.key_shape += 1;
                            continue;
                        }
                        std.debug.print("byte {d} to {x:0>2}, cut {d}: whole gave {s}, chunks gave {s}\n{x}\n", .{ at, change, cut, @errorName(err), if (got == .err) @errorName(got.err) else "a value", mutable });
                        return error.TestUnexpectedResult;
                    },
                }
            }
        }
    }
    return tally;
}

test "mutated inputs read in pieces as they read whole: the same value, or the same error" {
    const msg = try deterministicBytes(WireMsg, .{}, sampleMsg());
    defer allocator.free(msg);
    const msg_tally = try expectSameOnMutations(WireMsg, .{}, chunk_read, msg);
    try std.testing.expect(msg_tally.refused > msg.len);
    try std.testing.expect(msg_tally.key_shape * 20 < msg_tally.reads);
    const meta = try deterministicBytes(ChunkMeta, .{}, sampleChunkMeta());
    defer allocator.free(meta);
    const meta_tally = try expectSameOnMutations(ChunkMeta, .{}, chunk_read, meta);
    try std.testing.expect(meta_tally.refused > meta.len);
    try std.testing.expect(meta_tally.key_shape * 20 < meta_tally.reads);
}

/// A resumable decode into the wire layout, in a region of exactly `resumableRegionSizes`, gives `expected` when the input is cut
/// at every offset; returns the bytes of the region it used.
fn expectWireChunks(comptime T: type, comptime serde_cfg: anytype, comptime read_cfg: anytype, expected: T) !usize {
    const sizes = comptime wire.resumableRegionSizes(T, serde_cfg, read_cfg);
    try std.testing.expectEqual(@as(usize, 0), sizes.scratch);
    const input = try deterministicBytes(T, serde_cfg, expected);
    defer allocator.free(input);
    var region: Region = .{};
    var used: usize = 0;
    for (0..input.len + 1) |cut| {
        var decoder: wire.Resumable(T, serde_cfg, read_cfg) = undefined;
        decoder.init(region.bytes[0..sizes.output], region.base());
        const early = try decoder.feed(input[0..cut]);
        try std.testing.expectEqual(cut == input.len, early);
        _ = try decoder.feed(input[cut..]);
        const decoded = try decoder.finish();
        try std.testing.expect(decoded.used <= sizes.output);
        used = decoded.used;
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const back = try wire.fromWire(T, arena_state.allocator(), region.memory(), decoded.value);
        try std.testing.expectEqualDeep(expected, back);
    }
    return used;
}

test "a resumable decode into the wire layout is the value of the whole decode, in a region of exactly its bound" {
    const used = try expectWireChunks(WireMsg, .{}, chunk_read, sampleMsg());
    try std.testing.expect(used > 0);
    // Every string and list at its bound: the most the config lets the schema take.
    const long_put: WireEffect = .{ .put = .{ .key = .{ .bytes = "kkkkkkkk" }, .kind = "tttttttttttttttt", .revision = std.math.maxInt(u64), .meta = "mmmmmmmmmmmmmmmm", .note = .{ .bytes = "nnnnnnnn" }, .level = .high, .ratio = 1.5, .flag = true } };
    const effects = [_]WireEffect{ long_put, long_put, long_put, long_put };
    const row = [_]u16{ 1, 2, 3, 4 };
    const grid = [_][]const u16{ &row, &row, &row };
    const biggest: WireMsg = .{ .id = .{ 255, 255, 255, 255 }, .effects = &effects, .grid = &grid, .pair = .{ 1, 2 }, .first = long_put };
    const biggest_used = try expectWireChunks(WireMsg, .{}, chunk_read, biggest);
    try std.testing.expect(biggest_used <= wire.resumableRegionSizes(WireMsg, .{}, chunk_read).output);
    // A region one byte short of what this input takes is refused, and nothing is written past it.
    const input = try deterministicBytes(WireMsg, .{}, biggest);
    defer allocator.free(input);
    var region: Region = .{};
    var decoder: wire.Resumable(WireMsg, .{}, chunk_read) = undefined;
    decoder.init(region.bytes[0 .. biggest_used - 1], region.base());
    try std.testing.expectError(error.OutOfMemory, decoder.feed(input));
    // The input of a whole-input decode is in the region; the resumable decode keeps none of it.
    try std.testing.expect(wire.resumableRegionSizes(WireMsg, .{}, chunk_read).output < wire.regionSizes(zerde.cbor, WireMsg, .{}, chunk_read).output + 4096);
}

/// `ChunkMeta` without the pointer, which has no wire layout.
const ChunkWire = struct {
    name: []const u8,
    kind: ChunkKind,
    level: ChunkLevel,
    ratio: f64,
    small: f32,
    flag: bool,
    count: i64,
    digest: [8]u8,
    blob: zerde.ByteString,
    raw: zerde.cbor.Raw,
    opt_raw: ?zerde.cbor.Raw = null,
    maybe: ?ChunkInner = null,
    labels: zerde.SortedMap(u32) = .{ .entries = &.{} },
    choices: []const ChunkChoice,
    ints: []const ChunkInts,
    nested: []const []const ChunkInner,
    fixed: [3]ChunkInner,
    pub const serde = ChunkMeta.serde;
};

test "a resumable decode into the wire layout holds a Raw, a sorted map and its keys in the bound of the region" {
    const read = .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 64, .max_items = 200, .max_input_bytes = 4096 };
    const meta = sampleChunkMeta();
    var value: ChunkWire = undefined;
    inline for (@typeInfo(ChunkWire).@"struct".field_names) |name| @field(value, name) = @field(meta, name);
    const used = try expectWireChunks(ChunkWire, .{}, read, value);
    try std.testing.expect(used > value.raw.bytes.len);
    // The Raw and the keys are charged: without a bound for the Raw's string the type has none, and the bound follows the config.
    const sizes = comptime wire.resumableRegionSizes(ChunkWire, .{}, read);
    const lenient = .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 64, .max_items = 200, .max_input_bytes = 1024 };
    try std.testing.expect(wire.resumableRegionSizes(ChunkWire, .{}, lenient).output <= sizes.output);
    try std.testing.expect(sizes.output > wire.regionSizes(zerde.cbor, ChunkWire, .{}, read).output);
}

/// `input` is refused with `expected` by the whole strict read and by the resumable read for the input cut at every offset.
fn expectRefusedInChunks(comptime T: type, comptime serde_cfg: anytype, comptime read_cfg: anytype, expected: anyerror, input: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const whole = wholeOutcome(T, serde_cfg, read_cfg, arena, input);
    if (whole != .err or whole.err != expected) {
        std.debug.print("whole read: {s}, expected {s}\n", .{ if (whole == .err) @errorName(whole.err) else "a value", @errorName(expected) });
        return error.TestUnexpectedResult;
    }
    for (0..input.len + 1) |cut| {
        const got = chunkedOutcome(T, serde_cfg, read_cfg, arena, input, &.{cut});
        if (got != .err or got.err != expected) {
            std.debug.print("cut {d}: chunks gave {s}, expected {s}\n", .{ cut, if (got == .err) @errorName(got.err) else "a value", @errorName(expected) });
            return error.TestUnexpectedResult;
        }
    }
}

const ChunkStrict = struct {
    a: u8,
    b: ?[]const u8 = null,
    c: []const u8,
    d: ChunkKind,
    e: [2]u8,
    f: ?ChunkInner = null,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{
        .a = .{ .min = 1, .max = 200 },
        .b = .{ .optional = .absent, .max_len = 4 },
        .c = .{ .min_len = 1, .max_len = 6 },
        .f = .{ .optional = .absent },
    } };
};

test "a resumable read refuses what the strict read refuses, with the same error, however the input is cut" {
    const valid = [_]u8{ 0xa4, 0x61, 'a', 0x05, 0x61, 'c', 0x62, 'h', 'i', 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ok = try readInChunks(ChunkStrict, .{}, chunk_read, arena, &valid, &.{ 3, 9 });
    try std.testing.expectEqual(@as(u8, 5), ok.a);
    try std.testing.expectEqualStrings("hi", ok.c);
    try std.testing.expectEqual(ChunkKind.alpha, ok.d);
    try std.testing.expectEqual([2]u8{ 1, 2 }, ok.e);
    try std.testing.expect(ok.b == null and ok.f == null);

    const head = [_]u8{ 0xa4, 0x61, 'a' };
    const c_d_e = [_]u8{ 0x61, 'c', 0x62, 'h', 'i', 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 };
    const Case = struct { err: anyerror, input: []const u8 };
    const cases = [_]Case{
        .{ .err = error.NonDeterministicEncoding, .input = &(head ++ [_]u8{ 0x18, 0x05 } ++ c_d_e) }, // a head longer than it needs to be
        .{ .err = error.NonDeterministicEncoding, .input = &[_]u8{ 0xa4, 0x61, 'c', 0x62, 'h', 'i', 0x61, 'a', 0x05, 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 } }, // keys out of order
        .{ .err = error.DuplicateField, .input = &[_]u8{ 0xa4, 0x61, 'a', 0x05, 0x61, 'a', 0x06, 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 } }, // a key twice
        .{ .err = error.UnknownField, .input = &(valid ++ [_]u8{ 0x61, 'z', 0x01 }) }, // not counted in the head, so see below
        .{ .err = error.UnknownField, .input = &[_]u8{ 0xa5, 0x61, 'a', 0x05, 0x61, 'c', 0x62, 'h', 'i', 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02, 0x61, 'z', 0x01 } }, // a key no field has
        .{ .err = error.MissingField, .input = &[_]u8{ 0xa3, 0x61, 'a', 0x05, 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 } }, // c is required
        .{ .err = error.UnexpectedTag, .input = &(head ++ [_]u8{ 0xc1, 0x05 } ++ c_d_e) },
        .{ .err = error.NonDeterministicEncoding, .input = &[_]u8{ 0xa4, 0x61, 'a', 0x05, 0x61, 'c', 0x7f, 0x62, 'h', 'i', 0xff, 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 } }, // an indefinite string
        .{ .err = error.InvalidUtf8, .input = &[_]u8{ 0xa4, 0x61, 'a', 0x05, 0x61, 'c', 0x62, 0xff, 0xff, 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 } },
        .{ .err = error.ValueOutOfRange, .input = &(head ++ [_]u8{0x00} ++ c_d_e) }, // below min
        .{ .err = error.ValueOutOfRange, .input = &(head ++ [_]u8{ 0x18, 0xc9 } ++ c_d_e) }, // above max
        .{ .err = error.IntegerOverflow, .input = &(head ++ [_]u8{ 0x19, 0x03, 0xe8 } ++ c_d_e) }, // does not fit u8
        .{ .err = error.UnexpectedType, .input = &(head ++ [_]u8{ 0x61, 'x' } ++ c_d_e) }, // text for an integer
        .{ .err = error.UnexpectedType, .input = &(head ++ [_]u8{ 0xf9, 0x3c, 0x00 } ++ c_d_e) }, // a float for an integer
        .{ .err = error.LengthOutOfBounds, .input = &[_]u8{ 0xa4, 0x61, 'a', 0x05, 0x61, 'c', 0x67, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 } }, // over max_len
        .{ .err = error.LengthOutOfBounds, .input = &[_]u8{ 0xa4, 0x61, 'a', 0x05, 0x61, 'c', 0x60, 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 } }, // under min_len
        .{ .err = error.InvalidEnumTag, .input = &[_]u8{ 0xa4, 0x61, 'a', 0x05, 0x61, 'c', 0x62, 'h', 'i', 0x61, 'd', 0x64, 'z', 'e', 't', 'a', 0x61, 'e', 0x42, 0x01, 0x02 } },
        .{ .err = error.LengthMismatch, .input = &[_]u8{ 0xa4, 0x61, 'a', 0x05, 0x61, 'c', 0x62, 'h', 'i', 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x41, 0x01 } }, // a byte array of the wrong length
        .{ .err = error.UnexpectedType, .input = &[_]u8{ 0xa5, 0x61, 'a', 0x05, 0x61, 'b', 0xf6, 0x61, 'c', 0x62, 'h', 'i', 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 } }, // null where only absence is allowed
        .{ .err = error.LengthOutOfBounds, .input = &[_]u8{ 0xa5, 0x61, 'a', 0x05, 0x61, 'b', 0x65, 'a', 'b', 'c', 'd', 'e', 0x61, 'c', 0x62, 'h', 'i', 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 } }, // an optional's text over max_len
        .{ .err = error.UnexpectedType, .input = &[_]u8{0x05} }, // not a map
        .{ .err = error.TrailingCharacters, .input = &(valid ++ [_]u8{0x00}) },
        .{ .err = error.UnexpectedEndOfInput, .input = &.{} },
        .{ .err = error.UnexpectedEndOfInput, .input = valid[0 .. valid.len - 1] },
        .{ .err = error.UnexpectedEndOfInput, .input = &[_]u8{ 0xa4, 0x61, 'a' } },
    };
    for (cases, 0..) |case, number| {
        // The fourth case has the map's head of four entries and a fifth: after the four, the value is complete and the rest is trailing.
        const expected = if (number == 3) error.TrailingCharacters else case.err;
        expectRefusedInChunks(ChunkStrict, .{}, chunk_read, expected, case.input) catch |err| {
            std.debug.print("case {d}\n", .{number});
            return err;
        };
    }
}

test "a resumable read keeps to the limits of the config across chunks" {
    const Nested = struct {
        v: []const []const u16,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    // {"v": [[1, 2], [3]]}: the heads are the map, its key, the array, two arrays inside it and three numbers: eight items, three containers deep.
    const nested = [_]u8{ 0xa1, 0x61, 'v', 0x82, 0x82, 0x01, 0x02, 0x81, 0x03 };
    const items_ok = .{ .mode = zerde.cbor.Mode.strict, .max_items = 8 };
    const items_short = .{ .mode = zerde.cbor.Mode.strict, .max_items = 7 };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = try readInChunks(Nested, .{}, items_ok, arena, &nested, &.{4});
    try expectRefusedInChunks(Nested, .{}, items_short, error.TooManyItems, &nested);
    // The count is of the whole stream, not of each chunk.
    var one_by_one: std.ArrayList(usize) = .empty;
    defer one_by_one.deinit(allocator);
    for (1..nested.len) |cut| try one_by_one.append(allocator, cut);
    try std.testing.expectError(error.TooManyItems, readInChunks(Nested, .{}, items_short, arena, &nested, one_by_one.items));
    // Depth: the map, the array and the arrays inside it are three containers.
    _ = try readInChunks(Nested, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_depth = 3 }, arena, &nested, &.{5});
    try expectRefusedInChunks(Nested, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_depth = 2 }, error.CborNestingTooDeep, &nested);

    // A string over max_string_len, and over a field's own max_len, which says which.
    const Texts = struct {
        plain: []const u8,
        capped: []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .capped = .{ .max_len = 2 } } };
    };
    // Keys of a map are in order of their encoded form: "plain" (5) before "capped" (6).
    const texts = [_]u8{ 0xa2, 0x65, 'p', 'l', 'a', 'i', 'n', 0x64, 'a', 'b', 'c', 'd', 0x66, 'c', 'a', 'p', 'p', 'e', 'd', 0x60 };
    try expectRefusedInChunks(Texts, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 3 }, error.StringTooLong, &texts);
    const capped_long = [_]u8{ 0xa2, 0x65, 'p', 'l', 'a', 'i', 'n', 0x60, 0x66, 'c', 'a', 'p', 'p', 'e', 'd', 0x63, 'a', 'b', 'c' };
    try expectRefusedInChunks(Texts, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 8 }, error.LengthOutOfBounds, &capped_long);
    // max_len under max_string_len is the field's error; over it, the config's.
    try expectRefusedInChunks(Texts, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 2 }, error.StringTooLong, &capped_long);

    // The stream is bounded by max_input_bytes whatever the chunks are, and exactly that much is accepted.
    const Scalar = struct {
        n: u8,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const scalar = [_]u8{ 0xa1, 0x61, 'n', 0x05 };
    _ = try readInChunks(Scalar, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_input_bytes = scalar.len }, arena, &scalar, &.{ 1, 2, 3 });
    try std.testing.expectError(error.InputTooLarge, readInChunks(Scalar, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_input_bytes = scalar.len - 1 }, arena, &scalar, &.{ 1, 2, 3 }));
    var decoder = zerde.resumable.Decoder(Scalar, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_input_bytes = scalar.len }).init(.{}, arena);
    try std.testing.expect(!(try decoder.feed(scalar[0..3])));
    try std.testing.expectError(error.InputTooLarge, decoder.feed(&[_]u8{ 0x05, 0x00 }));
    // A container that claims more than the stream may still hold is refused at its head, as the whole read refuses one that
    // claims more than the input has.
    try std.testing.expectError(error.UnexpectedEndOfInput, readInChunks(Nested, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_input_bytes = nested.len - 1 }, arena, &nested, one_by_one.items));
}

test "a resumable read refuses a length the stream cannot hold before it allocates for it" {
    const Big = struct {
        list: []const u64,
        text: []const u8,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    // A list of a million items, and a string of a million bytes, in a stream that may be 4 KiB.
    const list_claim = [_]u8{ 0xa1, 0x64, 'l', 'i', 's', 't', 0x9a, 0x00, 0x0f, 0x42, 0x40 };
    const small = .{ .mode = zerde.cbor.Mode.strict, .max_input_bytes = 4096 };
    const text_claim = [_]u8{ 0xa1, 0x64, 't', 'e', 'x', 't', 0x7a, 0x00, 0x0f, 0x42, 0x40 };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    for ([_][]const u8{ &list_claim, &text_claim }) |input| {
        for (0..input.len + 1) |cut| {
            const got = chunkedOutcome(Big, .{}, small, failing.allocator(), input, &.{cut});
            try std.testing.expect(got == .err);
            // Not "out of memory": the claim is refused first, with what the whole-input read says of it.
            try std.testing.expectEqual(error.UnexpectedEndOfInput, got.err);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);

    // A bound of the field is checked before the allocation too, and a Raw holds no more than its bound, whatever it says it is.
    const Held = struct {
        text: []const u8,
        raw: zerde.cbor.Raw,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .text = .{ .max_len = 8 }, .raw = .{ .max_len = 64 } } };
    };
    const claim_over_bound = [_]u8{ 0xa1, 0x64, 't', 'e', 'x', 't', 0x78, 0xff };
    var backing = std.heap.ArenaAllocator.init(allocator);
    defer backing.deinit();
    var counting = std.testing.FailingAllocator.init(backing.allocator(), .{});
    for (0..claim_over_bound.len + 1) |cut| {
        const got = chunkedOutcome(Held, .{}, .{ .mode = zerde.cbor.Mode.strict }, counting.allocator(), &claim_over_bound, &.{cut});
        try std.testing.expectEqual(error.LengthOutOfBounds, got.err);
    }
    try std.testing.expectEqual(@as(usize, 0), counting.allocated_bytes);
    // A Raw of 4000 bytes (an array of zeros) is refused when it passes 64, having held at most a little more than that.
    var big_raw: std.ArrayList(u8) = .empty;
    defer big_raw.deinit(allocator);
    try big_raw.appendSlice(allocator, &.{ 0xa2, 0x63, 'r', 'a', 'w', 0x99, 0x0f, 0xa0 });
    try big_raw.appendNTimes(allocator, 0x00, 4000);
    counting = std.testing.FailingAllocator.init(backing.allocator(), .{});
    for ([_]usize{ 0, 8, 100, 2000 }) |cut| {
        const got = chunkedOutcome(Held, .{}, .{ .mode = zerde.cbor.Mode.strict }, counting.allocator(), big_raw.items, &.{cut});
        try std.testing.expect(got == .err);
    }
    try std.testing.expect(counting.allocated_bytes < 4 * 4 * 200);
}

test "a resumable read honours trusted_text and refuse_non_finite as the whole read does" {
    const Holder = struct {
        t: []const u8,
        raw: zerde.cbor.Raw,
        f: f64,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .raw = .{ .max_len = 16 } } };
    };
    // Keys in encoded order: "f", "t", "raw".
    const bad_text = [_]u8{ 0xa3, 0x61, 'f', 0xf9, 0x3c, 0x00, 0x61, 't', 0x62, 0xff, 0xff, 0x63, 'r', 'a', 'w', 0x01 };
    const bad_raw = [_]u8{ 0xa3, 0x61, 'f', 0xf9, 0x3c, 0x00, 0x61, 't', 0x61, 'x', 0x63, 'r', 'a', 'w', 0x62, 0xff, 0xff };
    const nan_field = [_]u8{ 0xa3, 0x61, 'f', 0xf9, 0x7e, 0x00, 0x61, 't', 0x61, 'x', 0x63, 'r', 'a', 'w', 0x01 };
    const nan_raw = [_]u8{ 0xa3, 0x61, 'f', 0xf9, 0x3c, 0x00, 0x61, 't', 0x61, 'x', 0x63, 'r', 'a', 'w', 0xf9, 0x7e, 0x00 };
    try expectRefusedInChunks(Holder, .{}, strict, error.InvalidUtf8, &bad_text);
    try expectRefusedInChunks(Holder, .{}, strict, error.InvalidUtf8, &bad_raw);
    const trusted = .{ .mode = zerde.cbor.Mode.strict, .trusted_text = true };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ &bad_text, &bad_raw }) |input| {
        const whole = try zerde.cbor.parseSliceWith(Holder, arena, input, .{}, trusted);
        for (0..input.len + 1) |cut| {
            const got = try readInChunks(Holder, .{}, trusted, arena, input, &.{cut});
            try std.testing.expectEqualDeep(whole, got);
        }
    }
    // A float that is not finite is a value by default, and refused when the config says so, in a field and inside a Raw.
    for ([_][]const u8{ &nan_field, &nan_raw }) |input| {
        try expectRefusedInChunks(Holder, .{}, .{ .mode = zerde.cbor.Mode.strict, .refuse_non_finite = true }, error.NonFiniteFloat, input);
        const whole = try zerde.cbor.parseSliceWith(Holder, arena, input, .{}, strict);
        for (0..input.len + 1) |cut| {
            const got = try readInChunks(Holder, .{}, strict, arena, input, &.{cut});
            // A NaN is not equal to itself, so the parts are compared.
            try std.testing.expectEqual(std.math.isNan(whole.f), std.math.isNan(got.f));
            try std.testing.expectEqualStrings(whole.t, got.t);
            try std.testing.expectEqualSlices(u8, whole.raw.bytes, got.raw.bytes);
        }
    }
}

const ChunkKeyed = struct {
    a: ?u8 = null,
    b: ??u8 = null,
    c: u8,
    d: ?u16,
    e: ?[]const u8 = null,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{
        .a = .{ .key = 1, .optional = .absent },
        .b = .{ .key = 2 },
        .c = .{ .key = 3 },
        .d = .{ .key = -4, .optional = .nullable },
        .e = .{ .key = 5 },
    } };
};

test "a resumable read of integer keys, absent, null and nested optionals is the whole read's, for every cut" {
    try expectChunked(ChunkKeyed, .{}, chunk_read, .{ .c = 1, .d = null });
    try expectChunked(ChunkKeyed, .{}, chunk_read, .{ .a = 7, .b = @as(?u8, null), .c = 1, .d = 300, .e = "tail text over twenty-four bytes long" });
    try expectChunked(ChunkKeyed, .{}, chunk_read, .{ .a = 7, .b = @as(?u8, 9), .c = 255, .d = 65535, .e = null });
    // `d` is nullable: it must be present, and a read with no key for it says so.
    try expectRefusedInChunks(ChunkKeyed, .{}, chunk_read, error.MissingField, &[_]u8{ 0xa1, 0x03, 0x01 });
    // `a` is absent-only: a null is refused, where `e` takes it.
    try expectRefusedInChunks(ChunkKeyed, .{}, chunk_read, error.UnexpectedType, &[_]u8{ 0xa3, 0x01, 0xf6, 0x03, 0x01, 0x23, 0x00 });
}

test "a fixed array of owning elements frees the elements it read when a later one is refused" {
    const Pair = struct {
        v: [2][]const u8,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    // {"v": ["a", h'ffff']}: the second element is not text, after the first was copied. The testing allocator reports a leak.
    try std.testing.expectError(error.UnexpectedType, zerde.cbor.parseSlice(Pair, allocator, &.{ 0xa1, 0x61, 'v', 0x82, 0x61, 'a', 0x42, 0xff, 0xff }));
    try std.testing.expectError(error.InvalidUtf8, zerde.cbor.parseSlice(Pair, allocator, &.{ 0xa1, 0x61, 'v', 0x82, 0x61, 'a', 0x62, 0xff, 0xff }));
    try std.testing.expectError(error.UnexpectedToken, zerde.json.parseSlice(Pair, allocator, "{\"v\":[\"a\",1]}"));
    // An array that is too long for the type, which is found after the elements.
    try std.testing.expectError(error.LengthMismatch, zerde.cbor.parseSlice(Pair, allocator, &.{ 0xa1, 0x61, 'v', 0x83, 0x61, 'a', 0x61, 'b', 0x61, 'c' }));
}

const Wrapped = struct {
    inner: ?*const *const Wrapped = null,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .inner = .{ .optional = .absent } } };
};

test "a resumable read of a type that wraps each container in an optional and two pointers has room for it at the deepest nesting" {
    // Each level is an absent-only optional field, an optional, and two pointers around the struct that is the container: five
    // frames a level, which the state is sized for from the type, and the nesting is that of max_depth.
    inline for (.{ 1, 2, 5, 9 }) |depth| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(allocator);
        for (0..depth - 1) |_| try input.appendSlice(allocator, &.{ 0xa1, 0x65, 'i', 'n', 'n', 'e', 'r' });
        try input.append(allocator, 0xa0);
        const read = .{ .mode = zerde.cbor.Mode.strict, .max_depth = depth };
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        for ([_]usize{ 0, input.items.len / 2, input.items.len - 1 }) |cut| {
            const got = try readInChunks(Wrapped, .{}, read, arena, input.items, &.{cut});
            const again = try deterministicBytes(Wrapped, .{}, got);
            defer allocator.free(again);
            try std.testing.expectEqualSlices(u8, input.items, again);
        }
        // One more is too deep, as it is for the whole read.
        try input.insertSlice(allocator, 0, &.{ 0xa1, 0x65, 'i', 'n', 'n', 'e', 'r' });
        try expectRefusedInChunks(Wrapped, .{}, read, error.CborNestingTooDeep, input.items);
    }
}

/// The value `input` reads as in pieces, for every cut, which must be `expected`.
fn expectValueInChunks(comptime T: type, comptime serde_cfg: anytype, comptime read_cfg: anytype, expected: T, input: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (0..input.len + 1) |cut| {
        const got = try readInChunks(T, serde_cfg, read_cfg, arena, input, &.{cut});
        try std.testing.expectEqualDeep(expected, got);
    }
}

test "a resumable read of unions reads each form, and refuses the others as the whole read does" {
    // Bare name, and a map of one entry; a variant with a payload cannot be a bare name, nor one without a map entry.
    try expectValueInChunks(ChunkChoice, .{}, chunk_read, .bare, &[_]u8{ 0x64, 'b', 'a', 'r', 'e' });
    try expectValueInChunks(ChunkChoice, .{}, chunk_read, .{ .num = 5 }, &[_]u8{ 0xa1, 0x63, 'n', 'u', 'm', 0x05 });
    try expectValueInChunks(ChunkChoice, .{}, chunk_read, .{ .inner = .{ .a = 3 } }, &[_]u8{ 0xa1, 0x65, 'i', 'n', 'n', 'e', 'r', 0xa1, 0x61, 'a', 0x03 });
    const choice_errors = [_]struct { err: anyerror, input: []const u8 }{
        .{ .err = error.LengthMismatch, .input = &[_]u8{0xa0} }, // a map of no entry
        .{ .err = error.LengthMismatch, .input = &[_]u8{ 0xa2, 0x63, 'n', 'u', 'm', 0x05, 0x64, 't', 'e', 'x', 't', 0x61, 'x' } }, // two
        .{ .err = error.UnexpectedType, .input = &[_]u8{0x05} }, // a number where no variant has an integer key
        .{ .err = error.UnexpectedType, .input = &[_]u8{ 0xa1, 0x80, 0x00 } }, // a key that is not text or an integer
        .{ .err = error.UnexpectedType, .input = &[_]u8{0xf5} },
        .{ .err = error.InvalidEnumTag, .input = &[_]u8{ 0xa1, 0x63, 'z', 'z', 'z', 0x00 } }, // no variant of that name
        .{ .err = error.InvalidEnumTag, .input = &[_]u8{ 0x63, 'n', 'u', 'm' } }, // a variant with a payload, as a bare name
        .{ .err = error.InvalidEnumTag, .input = &[_]u8{ 0xa1, 0x64, 'b', 'a', 'r', 'e', 0x00 } }, // one without, as a map entry
        .{ .err = error.InvalidUtf8, .input = &[_]u8{ 0x62, 0xff, 0xff } },
        .{ .err = error.UnexpectedEndOfInput, .input = &[_]u8{ 0xa1, 0x63, 'n', 'u' } },
    };
    for (choice_errors, 0..) |case, number| {
        expectRefusedInChunks(ChunkChoice, .{}, chunk_read, case.err, case.input) catch |err| {
            std.debug.print("choice case {d}\n", .{number});
            return err;
        };
    }
    // Variants keyed by integers have no text name at all, so any text is longer than every name.
    try expectValueInChunks(ChunkInts, .{}, chunk_read, .zero, &[_]u8{0x00});
    try expectValueInChunks(ChunkInts, .{}, chunk_read, .{ .one = 9 }, &[_]u8{ 0xa1, 0x01, 0x09 });
    try expectValueInChunks(ChunkInts, .{}, chunk_read, .{ .three = .{ .a = 3 } }, &[_]u8{ 0xa1, 0x19, 0x01, 0x2c, 0xa1, 0x61, 'a', 0x03 });
    const ints_errors = [_]struct { err: anyerror, input: []const u8 }{
        .{ .err = error.InvalidUtf8, .input = &[_]u8{ 0x61, 0xc3 } }, // a text longer than any name, whose last sequence is cut
        .{ .err = error.InvalidUtf8, .input = &[_]u8{ 0x62, 0xff, 0x41 } },
        .{ .err = error.InvalidEnumTag, .input = &[_]u8{ 0x62, 0xc3, 0xa9 } },
        .{ .err = error.InvalidEnumTag, .input = &[_]u8{0x01} }, // a variant with a payload, as a bare integer
        .{ .err = error.InvalidEnumTag, .input = &[_]u8{ 0xa1, 0x07, 0x00 } },
        .{ .err = error.UnexpectedType, .input = &[_]u8{ 0xa1, 0xf9, 0x3c, 0x00, 0x00 } },
    };
    for (ints_errors, 0..) |case, number| {
        expectRefusedInChunks(ChunkInts, .{}, chunk_read, case.err, case.input) catch |err| {
            std.debug.print("ints case {d}\n", .{number});
            return err;
        };
    }
}

test "a resumable read of enums takes a name or a number, and an enum written as its number only the number" {
    const ByNumber = struct {
        l: ChunkLevel,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const ByName = struct {
        k: ChunkKind,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const integers = .{ .enum_repr = .integer };
    try expectValueInChunks(ByNumber, integers, chunk_read, .{ .l = .low }, &[_]u8{ 0xa1, 0x61, 'l', 0x01 });
    try expectValueInChunks(ByName, .{}, chunk_read, .{ .k = .beta }, &[_]u8{ 0xa1, 0x61, 'k', 0x64, 'b', 'e', 't', 'a' });
    try expectValueInChunks(ByName, .{}, chunk_read, .{ .k = .gamma_long_name }, &[_]u8{ 0xa1, 0x61, 'k', 0x6f, 'g', 'a', 'm', 'm', 'a', '_', 'l', 'o', 'n', 'g', '_', 'n', 'a', 'm', 'e' });
    try expectValueInChunks(ByName, .{}, chunk_read, .{ .k = .beta }, &[_]u8{ 0xa1, 0x61, 'k', 0x01 });
    try expectRefusedInChunks(ByNumber, integers, chunk_read, error.UnexpectedType, &[_]u8{ 0xa1, 0x61, 'l', 0x63, 'l', 'o', 'w' });
    try expectRefusedInChunks(ByNumber, integers, chunk_read, error.InvalidEnumTag, &[_]u8{ 0xa1, 0x61, 'l', 0x05 });
    try expectRefusedInChunks(ByNumber, integers, chunk_read, error.InvalidEnumTag, &[_]u8{ 0xa1, 0x61, 'l', 0x19, 0x01, 0x2c });
    try expectRefusedInChunks(ByNumber, integers, chunk_read, error.UnexpectedType, &[_]u8{ 0xa1, 0x61, 'l', 0xf9, 0x3c, 0x00 });
    try expectRefusedInChunks(ByNumber, integers, chunk_read, error.UnexpectedType, &[_]u8{ 0xa1, 0x61, 'l', 0xf5 });
    try expectRefusedInChunks(ByName, .{}, chunk_read, error.InvalidEnumTag, &[_]u8{ 0xa1, 0x61, 'k', 0x64, 'z', 'e', 't', 'a' });
    try expectRefusedInChunks(ByName, .{}, chunk_read, error.InvalidEnumTag, &[_]u8{ 0xa1, 0x61, 'k', 0x78, 0x1e, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'a', 'b', 'c', 'd' });
    try expectRefusedInChunks(ByName, .{}, chunk_read, error.InvalidEnumTag, &[_]u8{ 0xa1, 0x61, 'k', 0x09 });
    try expectRefusedInChunks(ByName, .{}, chunk_read, error.UnexpectedType, &[_]u8{ 0xa1, 0x61, 'k', 0x41, 0x00 });
    try expectRefusedInChunks(ByName, .{}, chunk_read, error.InvalidUtf8, &[_]u8{ 0xa1, 0x61, 'k', 0x62, 0xc3, 0x28 });
}

test "a resumable read keys a struct by its encoded key, and orders a key that is none of its fields as the whole read does" {
    const input = [_]u8{ 0xa5, 0x61, 'a', 0x05, 0x61, 'c', 0x62, 'h', 'i', 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02, 0x61, 'f' };
    // A tag, a text where bytes are due and bytes where text is due.
    const Case = struct { err: anyerror, input: []const u8 };
    const cases = [_]Case{
        .{ .err = error.UnexpectedTag, .input = &(input ++ [_]u8{ 0xc1, 0xa0 }) }, // before the value of an optional
        .{ .err = error.UnexpectedType, .input = &[_]u8{ 0xa4, 0x61, 'a', 0x05, 0x61, 'c', 0x62, 'h', 'i', 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x62, 'a', 'b' } },
        .{ .err = error.UnexpectedType, .input = &[_]u8{ 0xa4, 0x61, 'a', 0x05, 0x61, 'c', 0x42, 'h', 'i', 0x61, 'd', 0x65, 'a', 'l', 'p', 'h', 'a', 0x61, 'e', 0x42, 0x01, 0x02 } },
        // A key that no field has: its place among the keys decides the error.
        .{ .err = error.UnknownField, .input = &[_]u8{ 0xa1, 0x01, 0x05 } }, // first
        .{ .err = error.NonDeterministicEncoding, .input = &[_]u8{ 0xa2, 0x61, 'a', 0x05, 0x61, '0', 0x05 } }, // text before the key before it
        .{ .err = error.NonDeterministicEncoding, .input = &[_]u8{ 0xa2, 0x61, 'a', 0x05, 0x01, 0x05 } }, // an integer after a text
        .{ .err = error.NonDeterministicEncoding, .input = &[_]u8{ 0xa2, 0x61, 'a', 0x05, 0x41, 0x00, 0x05 } }, // bytes after text
        .{ .err = error.UnknownField, .input = &[_]u8{ 0xa2, 0x61, 'a', 0x05, 0x80, 0x05 } }, // an array after text
        .{ .err = error.UnknownField, .input = &[_]u8{ 0xa2, 0x61, 'a', 0x05, 0xf9, 0x3c, 0x00, 0x05 } }, // a float after text
        .{ .err = error.UnknownField, .input = &[_]u8{ 0xa2, 0x61, 'a', 0x05, 0x78, 0x1f, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'a', 'b', 'c', 'd', 'e', 0x05 } }, // a text longer than every field's name
    };
    for (cases, 0..) |case, number| {
        expectRefusedInChunks(ChunkStrict, .{}, chunk_read, case.err, case.input) catch |err| {
            std.debug.print("key case {d}\n", .{number});
            return err;
        };
    }
}

test "a resumable read checks a list's length against its bounds before it allocates, and a fixed array's against its size" {
    const Caps = struct {
        v: []const u16,
        w: [2]u16,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .v = .{ .min_len = 1, .max_len = 2 } } };
    };
    const valid = [_]u8{ 0xa2, 0x61, 'v', 0x82, 0x01, 0x02, 0x61, 'w', 0x82, 0x01, 0x02 };
    try expectValueInChunks(Caps, .{}, chunk_read, .{ .v = &.{ 1, 2 }, .w = .{ 1, 2 } }, &valid);
    try expectRefusedInChunks(Caps, .{}, chunk_read, error.LengthOutOfBounds, &[_]u8{ 0xa2, 0x61, 'v', 0x83, 0x01, 0x02, 0x03, 0x61, 'w', 0x82, 0x01, 0x02 });
    try expectRefusedInChunks(Caps, .{}, chunk_read, error.LengthOutOfBounds, &[_]u8{ 0xa2, 0x61, 'v', 0x80, 0x61, 'w', 0x82, 0x01, 0x02 });
    try expectRefusedInChunks(Caps, .{}, chunk_read, error.LengthMismatch, &[_]u8{ 0xa2, 0x61, 'v', 0x82, 0x01, 0x02, 0x61, 'w', 0x83, 0x01, 0x02, 0x03 });
    try expectRefusedInChunks(Caps, .{}, chunk_read, error.LengthMismatch, &[_]u8{ 0xa2, 0x61, 'v', 0x82, 0x01, 0x02, 0x61, 'w', 0x81, 0x01 });
    // Over the bound: refused at the head, with nothing allocated.
    var counting = std.testing.FailingAllocator.init(allocator, .{});
    for (0..12) |cut| {
        const got = chunkedOutcome(Caps, .{}, chunk_read, counting.allocator(), &[_]u8{ 0xa2, 0x61, 'v', 0x83, 0x01, 0x02, 0x03, 0x61, 'w', 0x82, 0x01, 0x02 }, &.{cut});
        try std.testing.expectEqual(error.LengthOutOfBounds, got.err);
    }
    try std.testing.expectEqual(@as(usize, 0), counting.allocated_bytes);

    // The same of a sorted map's entries, and its keys must ascend and be text.
    const ChunkLabeled = struct {
        m: zerde.SortedMap(u8),
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .m = .{ .max_len = 2 } } };
    };
    const entries = [_]zerde.SortedMap(u8).Entry{ .{ .key = "a", .value = 1 }, .{ .key = "b", .value = 2 } };
    try expectValueInChunks(ChunkLabeled, .{}, chunk_read, .{ .m = .{ .entries = &entries } }, &[_]u8{ 0xa1, 0x61, 'm', 0xa2, 0x61, 'a', 0x01, 0x61, 'b', 0x02 });
    try expectRefusedInChunks(ChunkLabeled, .{}, chunk_read, error.NonDeterministicEncoding, &[_]u8{ 0xa1, 0x61, 'm', 0xa2, 0x61, 'b', 0x01, 0x61, 'a', 0x02 });
    try expectRefusedInChunks(ChunkLabeled, .{}, chunk_read, error.DuplicateField, &[_]u8{ 0xa1, 0x61, 'm', 0xa2, 0x61, 'a', 0x01, 0x61, 'a', 0x02 });
    try expectRefusedInChunks(ChunkLabeled, .{}, chunk_read, error.UnexpectedType, &[_]u8{ 0xa1, 0x61, 'm', 0xa1, 0x01, 0x01 });
    try expectRefusedInChunks(ChunkLabeled, .{}, chunk_read, error.LengthOutOfBounds, &[_]u8{ 0xa1, 0x61, 'm', 0xa3, 0x61, 'a', 0x01, 0x61, 'b', 0x02, 0x61, 'c', 0x03 });
    counting = std.testing.FailingAllocator.init(allocator, .{});
    for (0..13) |cut| {
        const got = chunkedOutcome(ChunkLabeled, .{}, chunk_read, counting.allocator(), &[_]u8{ 0xa1, 0x61, 'm', 0xa3, 0x61, 'a', 0x01, 0x61, 'b', 0x02, 0x61, 'c', 0x03 }, &.{cut});
        try std.testing.expectEqual(error.LengthOutOfBounds, got.err);
    }
    try std.testing.expectEqual(@as(usize, 0), counting.allocated_bytes);
}

test "a resumable read of a Raw keeps to its bounds, and the containers of one are closed when it ends" {
    const Held = struct {
        raw: zerde.cbor.Raw,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .raw = .{ .min_len = 3, .max_len = 8 } } };
    };
    try expectValueInChunks(Held, .{}, chunk_read, .{ .raw = .{ .bytes = &.{ 0x82, 0x01, 0x02 } } }, &[_]u8{ 0xa1, 0x63, 'r', 'a', 'w', 0x82, 0x01, 0x02 });
    try expectRefusedInChunks(Held, .{}, chunk_read, error.LengthOutOfBounds, &[_]u8{ 0xa1, 0x63, 'r', 'a', 'w', 0x01 });
    try expectRefusedInChunks(Held, .{}, chunk_read, error.LengthOutOfBounds, &[_]u8{ 0xa1, 0x63, 'r', 'a', 'w', 0x89, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    // A Raw that is itself deeper than the rest: closing it gives its levels back, or the list after it would be too deep.
    const Both = struct {
        a: zerde.cbor.Raw,
        b: []const []const []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .a = .{ .max_len = 16 } } };
    };
    const both = [_]u8{ 0xa2, 0x61, 'a', 0x81, 0x81, 0x80, 0x61, 'b', 0x81, 0x81, 0x60 };
    const four = .{ .mode = zerde.cbor.Mode.strict, .max_depth = 4 };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    for (0..both.len + 1) |cut| _ = try readInChunks(Both, .{}, four, arena_state.allocator(), &both, &.{cut});
    try expectRefusedInChunks(Both, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_depth = 3 }, error.CborNestingTooDeep, &both);
}

test "a resumable decoder says when the value is complete, refuses what follows it, and repeats an error" {
    const Scalar = struct {
        n: u8,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Decoder = zerde.resumable.Decoder(Scalar, .{}, chunk_read);
    // Input that ends before the value is complete is refused, and stays refused.
    var short = Decoder.init(.{}, arena);
    try std.testing.expect(!(try short.feed(&[_]u8{ 0xa1, 0x61 })));
    try std.testing.expectError(error.UnexpectedEndOfInput, short.finish());
    try std.testing.expectError(error.UnexpectedEndOfInput, short.feed(&[_]u8{ 'n', 0x05 }));
    var decoder = Decoder.init(.{}, arena);
    try std.testing.expect(!(try decoder.feed(&.{})));
    try std.testing.expect(!(try decoder.feed(&[_]u8{ 0xa1, 0x61 })));
    try std.testing.expect(try decoder.feed(&[_]u8{ 'n', 0x05 }));
    // Complete: nothing more is welcome, and nothing is the same.
    try std.testing.expect(try decoder.feed(&.{}));
    try std.testing.expectEqual(@as(u8, 5), (try decoder.finish()).n);
    try std.testing.expectError(error.TrailingCharacters, decoder.feed(&[_]u8{0x00}));
    try std.testing.expectError(error.TrailingCharacters, decoder.feed(&.{}));
    try std.testing.expectError(error.TrailingCharacters, decoder.finish());
    // Trailing bytes in the chunk that completes it.
    var second = Decoder.init(.{}, arena);
    try std.testing.expectError(error.TrailingCharacters, second.feed(&[_]u8{ 0xa1, 0x61, 'n', 0x05, 0x00 }));
    // A refused value is refused again, whatever is fed.
    var third = Decoder.init(.{}, arena);
    try std.testing.expectError(error.UnexpectedType, third.feed(&[_]u8{0x05}));
    try std.testing.expectError(error.UnexpectedType, third.feed(&[_]u8{ 0xa1, 0x61, 'n', 0x05 }));
    try std.testing.expectError(error.UnexpectedType, third.finish());
}

test "a resumable decode charges the strings and the Raw it copies, and its region holds the largest the schema allows" {
    const CopiedRaw = struct {
        raw: zerde.cbor.Raw,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .raw = .{ .max_len = 1000 } } };
    };
    const CopiedText = struct {
        s: []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .s = .{ .max_len = 500 } } };
    };
    const read = .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 1000 };
    // The whole-input strict read keeps nothing in the output for either; the resumable one copies them.
    try std.testing.expect(wire.regionSizes(zerde.cbor, CopiedRaw, .{}, read).output < 1000);
    try std.testing.expect(wire.resumableRegionSizes(CopiedRaw, .{}, read).output >= 1000);
    try std.testing.expect(wire.resumableRegionSizes(CopiedText, .{}, read).output >= 500);
    try std.testing.expectEqual(wire.resumableRegionSizes(CopiedText, .{}, read).output, wire.maxResumableArenaSize(CopiedText, .{}, read));

    // A Raw of exactly its bound (an array of 997 zeros, 1000 bytes), in a region of exactly the bound, cut in sevens.
    var raw_item: std.ArrayList(u8) = .empty;
    defer raw_item.deinit(allocator);
    try raw_item.appendSlice(allocator, &.{ 0x99, 0x03, 0xe5 });
    try raw_item.appendNTimes(allocator, 0x00, 997);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xa1, 0x63, 'r', 'a', 'w' });
    try input.appendSlice(allocator, raw_item.items);
    const sizes = comptime wire.resumableRegionSizes(CopiedRaw, .{}, read);
    var region: Region = .{};
    var decoder: wire.Resumable(CopiedRaw, .{}, read) = undefined;
    decoder.init(region.bytes[0..sizes.output], region.base());
    var at: usize = 0;
    while (at < input.items.len) : (at += 7) _ = try decoder.feed(input.items[at..@min(at + 7, input.items.len)]);
    const decoded = try decoder.finish();
    try std.testing.expectEqualSlices(u8, raw_item.items, try region.memory().bytesOf(decoded.value.raw));
    try std.testing.expect(decoded.used <= sizes.output);
    // One byte more is over the bound of the field.
    try raw_item.appendSlice(allocator, &.{0x00});
    raw_item.items[2] = 0xe6;
    input.items.len = 5;
    try input.appendSlice(allocator, raw_item.items);
    decoder.init(region.bytes[0..sizes.output], region.base());
    try std.testing.expectError(error.LengthOutOfBounds, decoder.feed(input.items));
    // The same for a text, which has no room beyond its bound.
    const text_sizes = comptime wire.resumableRegionSizes(CopiedText, .{}, read);
    var text_decoder: wire.Resumable(CopiedText, .{}, read) = undefined;
    text_decoder.init(region.bytes[0..text_sizes.output], region.base());
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, &.{ 0xa1, 0x61, 's', 0x79, 0x01, 0xf4 });
    try text.appendNTimes(allocator, 'x', 500);
    _ = try text_decoder.feed(text.items);
    try std.testing.expectEqual(@as(usize, 500), (try text_decoder.finish()).value.s.len);
}

test "a resumable read decides absent, null and nested optionals once, at the head of the value, and not again where it goes on" {
    // The first item of the list is a null: a read that looked again after the head would take it for the field's own null.
    const Nulls = struct {
        v: ?[]const ?u8 = null,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .v = .{ .optional = .absent } } };
    };
    try expectChunked(Nulls, .{}, chunk_read, .{ .v = &.{ null, 5, null } });
    try expectChunked(Nulls, .{}, chunk_read, .{});
    // A nested optional field holding a struct: the part of it read before the cut is kept, and not made again.
    const Nested = struct {
        n: ??ChunkInner = null,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    try expectChunked(Nested, .{}, chunk_read, .{ .n = @as(?ChunkInner, .{ .a = 1, .b = "xy" }) });
    try expectChunked(Nested, .{}, chunk_read, .{ .n = @as(?ChunkInner, null) });
    try expectChunked(Nested, .{}, chunk_read, .{});
}

test "a resumable read refuses a Raw whose keys repeat or do not ascend, as the whole read does" {
    const Held = struct {
        raw: zerde.cbor.Raw,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .raw = .{ .max_len = 16 } } };
    };
    try expectRefusedInChunks(Held, .{}, chunk_read, error.DuplicateField, &[_]u8{ 0xa1, 0x63, 'r', 'a', 'w', 0xa2, 0x61, 'a', 0x01, 0x61, 'a', 0x02 });
    try expectRefusedInChunks(Held, .{}, chunk_read, error.NonDeterministicEncoding, &[_]u8{ 0xa1, 0x63, 'r', 'a', 'w', 0xa2, 0x61, 'b', 0x01, 0x61, 'a', 0x02 });
    try expectRefusedInChunks(Held, .{}, chunk_read, error.UnexpectedTag, &[_]u8{ 0xa1, 0x63, 'r', 'a', 'w', 0xc1, 0x01 });
    try expectRefusedInChunks(Held, .{}, chunk_read, error.NonDeterministicEncoding, &[_]u8{ 0xa1, 0x63, 'r', 'a', 'w', 0x18, 0x01 });
}

test "a resumable read counts the items of the whole stream where it reads them, and refuses a claim over the budget before it allocates" {
    // {"a": [1], "b": 2}: six items, which the map's head (four) and the array's (one) do not foresee, so the count is the head of `b`'s value.
    const Budget = struct {
        a: []const u16,
        b: u16,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const mixed = [_]u8{ 0xa2, 0x61, 'a', 0x81, 0x01, 0x61, 'b', 0x02 };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    _ = try readInChunks(Budget, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_items = 6 }, arena_state.allocator(), &mixed, &.{4});
    try expectRefusedInChunks(Budget, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_items = 5 }, error.TooManyItems, &mixed);
    // A list that claims more items than the budget has left is refused at its head, with nothing allocated for it.
    const Big = struct {
        list: []const u64,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    const claim = [_]u8{ 0xa1, 0x64, 'l', 'i', 's', 't', 0x9a, 0x00, 0x0f, 0x42, 0x40 };
    var counting = std.testing.FailingAllocator.init(arena_state.allocator(), .{});
    for (0..claim.len + 1) |cut| {
        const got = chunkedOutcome(Big, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_items = 100 }, counting.allocator(), &claim, &.{cut});
        try std.testing.expectEqual(error.TooManyItems, got.err);
    }
    try std.testing.expectEqual(@as(usize, 0), counting.allocated_bytes);
}

// ---- a sorted map in the resumable write -----------------------------------------------------------------------

const long_key_bytes: [300]u8 = @splat('k');
const long_key: []const u8 = &long_key_bytes;
const inner_entries = [_]zerde.SortedMap(u8).Entry{ .{ .key = "x", .value = 1 }, .{ .key = "yy", .value = 255 } };
const window_entries = [_]zerde.SortedMap(zerde.SortedMap(u8)).Entry{
    .{ .key = "a", .value = .{ .entries = &inner_entries } },
    .{ .key = "bb", .value = .{ .entries = &.{} } },
    .{ .key = "q\"\\\n", .value = .{ .entries = &inner_entries } },
    .{ .key = "\xc3\xa9\xe2\x82\xac", .value = .{ .entries = &inner_entries } },
    .{ .key = long_key, .value = .{ .entries = &inner_entries } },
};
const WindowedMap = struct {
    head: u8,
    m: zerde.SortedMap(zerde.SortedMap(u8)),
    tail: []const u8,
    pub const serde = .{ .fields = .{ .m = .{ .max_len = 8 } } };
};

test "a sorted map is written in windows as it is written whole, in JSON and CBOR, a key longer than the window included" {
    const value: WindowedMap = .{ .head = 7, .m = .{ .entries = &window_entries }, .tail = "after the map" };
    try expectWindows(zerde.json, WindowedMap, value, .{}, .{});
    try expectWindows(zerde.cbor, WindowedMap, value, .{}, .{});
    try expectWindows(zerde.cbor, WindowedMap, value, .{}, .{ .deterministic = true });
    const empty: WindowedMap = .{ .head = 0, .m = .{ .entries = &.{} }, .tail = "" };
    try expectWindows(zerde.json, WindowedMap, empty, .{}, .{});
    try expectWindows(zerde.cbor, WindowedMap, empty, .{}, .{ .deterministic = true });
    // A window of one token's room: a key goes through it a few bytes at a time.
    const got = try writeInWindows(zerde.json, WindowedMap, value, .{}, .{}, zerde.resumable.Writer(zerde.json, WindowedMap, .{}, .{}).min_window);
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"" ++ long_key ++ "\":{\"x\":1,\"yy\":255}") != null);
}

test "a resumable write of a sorted map refuses entries that are not in order, as the whole write does, before the entry" {
    const entries = [_]zerde.SortedMap(u8).Entry{ .{ .key = "a", .value = 1 }, .{ .key = "c", .value = 2 }, .{ .key = "b", .value = 3 } };
    const repeated = [_]zerde.SortedMap(u8).Entry{ .{ .key = "a", .value = 1 }, .{ .key = "a", .value = 2 } };
    const Holder = struct { m: zerde.SortedMap(u8) };
    inline for (.{ zerde.json, zerde.cbor }) |Format| {
        inline for (.{ .{ &entries, error.NonDeterministicEncoding }, .{ &repeated, error.DuplicateField } }) |case| {
            const value: Holder = .{ .m = .{ .entries = case[0] } };
            var resumed = zerde.resumable.Writer(Format, Holder, .{}, .{}).init();
            var window: [128]u8 = undefined;
            var written: std.ArrayList(u8) = .empty;
            defer written.deinit(allocator);
            while (true) {
                const filled = resumed.fill(value, &window) catch |err| {
                    try std.testing.expectEqual(case[1], err);
                    break;
                };
                try written.appendSlice(allocator, window[0..filled.len]);
                try std.testing.expect(!filled.done);
            }
        }
    }
}

// ---- stored CBOR rendered as JSON in windows --------------------------------------------------------------------

/// The JSON of the stored CBOR `stored` by reading it (strict) into the value writer: the whole-buffer render.
fn renderWhole(stored: []const u8, comptime json_cfg: anytype) ![]u8 {
    var reader = try zerde.cbor.pullReader(allocator, stored, .{ .mode = zerde.cbor.Mode.strict });
    defer reader.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var writer = zerde.json.valueWriter(allocator, &out.writer, json_cfg);
    defer writer.deinit();
    while (try reader.next()) |event| try writer.writeEvent(event);
    try writer.finish();
    try reader.finish();
    return out.toOwnedSlice();
}

/// Every window of the resumable render, joined.
fn renderInWindows(comptime json_cfg: anytype, stored: []const u8, window_len: usize) ![]u8 {
    var render = zerde.resumable.Render(json_cfg).init();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const window = try allocator.alloc(u8, window_len);
    defer allocator.free(window);
    while (true) {
        const filled = try render.fill(stored, window);
        try std.testing.expect(filled.len <= window_len);
        try out.appendSlice(allocator, window[0..filled.len]);
        if (filled.done) break;
        try std.testing.expect(filled.len > 0);
    }
    try std.testing.expectEqual(@as(usize, 0), (try render.fill(stored, window)).len);
    return out.toOwnedSlice(allocator);
}

/// The render in windows is the whole render, for every window from the smallest to a few hundred bytes more and one that holds it all.
fn expectRenderWindows(comptime json_cfg: anytype, stored: []const u8) !void {
    const whole = try renderWhole(stored, json_cfg);
    defer allocator.free(whole);
    const min = zerde.resumable.Render(json_cfg).min_window;
    var size: usize = min;
    while (size < min + 300) : (size += 1) {
        const got = try renderInWindows(json_cfg, stored, size);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(whole, got);
    }
    const all = try renderInWindows(json_cfg, stored, whole.len + min);
    defer allocator.free(all);
    try std.testing.expectEqualStrings(whole, all);
}

const render_text: []const u8 = "text with \"quotes\", a \\ and a tab\t, a newline\n, a control \x01, \xc3\xa9 \xe2\x82\xac \xf0\x9f\x98\x80, and so on and on";
const render_bytes_data: [500]u8 = blk: {
    var data: [500]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index * 7);
    break :blk data;
};
const render_labels = [_]zerde.SortedMap(u32).Entry{
    .{ .key = "b", .value = 2 },
    .{ .key = "cc", .value = 4_000_000_000 },
    .{ .key = "d\"d", .value = 0 },
    .{ .key = "\xc3\xa9\xe2\x82\xac", .value = 1 },
    .{ .key = long_key, .value = 9 },
};
const render_rows = [_][]const u16{ &.{ 1, 2, 3 }, &.{}, &.{65535} };

const RenderInner = struct {
    flag: bool,
    note: ?[]const u8,
    pub const serde = .{ .fields = .{ .note = .{ .optional = .nullable } } };
};

const RenderDoc = struct {
    nothing: ?u8,
    yes: bool,
    no: bool,
    big: u64,
    neg: i64,
    half: f64,
    single: f64,
    double: f64,
    huge: f64,
    tiny: f64,
    zero: f64,
    negative_zero: f64,
    text: []const u8,
    long_text: []const u8,
    blob: zerde.ByteString,
    rows: []const []const u16,
    labels: zerde.SortedMap(u32),
    empty_labels: zerde.SortedMap(u8),
    inner: RenderInner,
    pub const serde = .{ .fields = .{ .nothing = .{ .optional = .nullable } } };
};

fn sampleRenderDoc(blob: []const u8) RenderDoc {
    return .{
        .nothing = null,
        .yes = true,
        .no = false,
        .big = std.math.maxInt(u64),
        .neg = std.math.minInt(i64),
        .half = 1.5,
        .single = 100000.0,
        .double = 0.1,
        .huge = 1e300,
        .tiny = 5e-324,
        .zero = 0.0,
        .negative_zero = -0.0,
        .text = render_text,
        .long_text = long_key,
        .blob = .{ .bytes = blob },
        .rows = &render_rows,
        .labels = .{ .entries = &render_labels },
        .empty_labels = .{ .entries = &.{} },
        .inner = .{ .flag = true, .note = null },
    };
}

test "stored CBOR is rendered as JSON in windows as it is rendered whole, for every window" {
    // By default bytes are written as JSON strings, so they must be text; base64 takes any.
    var stored = try writeCbor(sampleRenderDoc(long_key), .{}, .{ .deterministic = true });
    defer stored.deinit();
    try expectRenderWindows(.{}, stored.written());
    var binary = try writeCbor(sampleRenderDoc(&render_bytes_data), .{}, .{ .deterministic = true });
    defer binary.deinit();
    try expectRenderWindows(.{ .bytes = zerde.json.BytesEncoding.base64 }, binary.written());
    try expectRenderWindows(.{ .bytes = zerde.json.BytesEncoding.base64url, .trusted_text = true }, binary.written());
    try std.testing.expectError(error.InvalidUtf8, renderWhole(binary.written(), .{}));
    var render = zerde.resumable.Render(.{}).init();
    var window: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidUtf8, render.fill(binary.written(), &window));
    try expectRenderWindows(.{ .bytes = zerde.json.BytesEncoding.base64url, .trusted_text = true }, stored.written());
    // The pieces of a document: a scalar, an empty container, nested empty ones, a string longer than the window.
    inline for (.{
        &[_]u8{0x05},
        &[_]u8{0x20},
        &[_]u8{0xf5},
        &[_]u8{0xf6},
        &[_]u8{ 0xf9, 0x3c, 0x00 },
        &[_]u8{0x80},
        &[_]u8{0xa0},
        &[_]u8{ 0x82, 0x80, 0xa0 },
        &[_]u8{ 0xa1, 0x60, 0xa1, 0x61, 'k', 0x80 },
        &[_]u8{0x60},
        &[_]u8{0x40},
        &[_]u8{ 0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
        &[_]u8{ 0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
    }) |item| try expectRenderWindows(.{}, item);
    // Containers 128 deep, which is as deep as there is room for.
    const deep = try nestedCbor(127, 0x81);
    defer allocator.free(deep);
    try expectRenderWindows(.{}, deep);
}

test "the first window of a render refuses what cannot be rendered, with the error of the whole render, and writes nothing" {
    const Case = struct { err: anyerror, stored: []const u8 };
    const deep = try nestedCbor(128, 0x81);
    defer allocator.free(deep);
    // Faults after more than a window: the first window must already refuse them.
    var late_nan: std.ArrayList(u8) = .empty;
    defer late_nan.deinit(allocator);
    try late_nan.appendSlice(allocator, &.{ 0x82, 0x79, 0x01, 0x2c });
    try late_nan.appendNTimes(allocator, 'k', 300);
    try late_nan.appendSlice(allocator, &.{ 0xf9, 0x7e, 0x00 });
    var late_key: std.ArrayList(u8) = .empty;
    defer late_key.deinit(allocator);
    try late_key.appendSlice(allocator, &.{ 0x82, 0x79, 0x01, 0x2c });
    try late_key.appendNTimes(allocator, 'k', 300);
    try late_key.appendSlice(allocator, &.{ 0xa1, 0x01, 0x01 });
    const cases = [_]Case{
        .{ .err = error.UnexpectedType, .stored = &.{ 0xa1, 0x01, 0x01 } }, // an integer key
        .{ .err = error.UnexpectedType, .stored = &.{ 0xa1, 0x41, 'k', 0x01 } }, // a byte string key
        .{ .err = error.UnexpectedType, .stored = &.{ 0xa2, 0x61, 'a', 0x01, 0xf5, 0x01 } }, // a bool key, after a good entry
        .{ .err = error.NonFiniteFloat, .stored = &.{ 0xf9, 0x7e, 0x00 } },
        .{ .err = error.NonFiniteFloat, .stored = &.{ 0x82, 0x01, 0xf9, 0x7c, 0x00 } },
        .{ .err = error.NonDeterministicEncoding, .stored = &.{ 0xa2, 0x61, 'b', 0x01, 0x61, 'a', 0x02 } },
        .{ .err = error.DuplicateField, .stored = &.{ 0xa2, 0x61, 'a', 0x01, 0x61, 'a', 0x02 } },
        .{ .err = error.NonDeterministicEncoding, .stored = &.{ 0x18, 0x05 } },
        .{ .err = error.NonDeterministicEncoding, .stored = &.{ 0x9f, 0xff } },
        .{ .err = error.UnexpectedTag, .stored = &.{ 0xc1, 0x01 } },
        .{ .err = error.InvalidUtf8, .stored = &.{ 0x62, 0xff, 0xff } },
        .{ .err = error.UnexpectedEndOfInput, .stored = &.{ 0x82, 0x01 } },
        .{ .err = error.TrailingCharacters, .stored = &.{ 0x01, 0x02 } },
        .{ .err = error.CborNestingTooDeep, .stored = deep },
        .{ .err = error.NonFiniteFloat, .stored = late_nan.items },
        .{ .err = error.UnexpectedType, .stored = late_key.items },
    };
    for (cases, 0..) |case, number| {
        errdefer std.debug.print("render case {d}\n", .{number});
        try std.testing.expectError(case.err, renderWhole(case.stored, .{}));
        var render = zerde.resumable.Render(.{}).init();
        var window: [128]u8 = undefined;
        try std.testing.expectError(case.err, render.fill(case.stored, &window));
    }
    // A window smaller than one token is refused, and the item is not touched.
    var render = zerde.resumable.Render(.{}).init();
    var small: [zerde.resumable.Render(.{}).min_window - 1]u8 = undefined;
    try std.testing.expectError(error.WindowTooSmall, render.fill(&.{0x05}, &small));
}

const StreamItem = struct {
    label: []const u8,
    data: zerde.ByteString,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .label = .{ .max_len = 16 }, .data = .{ .max_len = 6000 } } };
};

const StreamMsg = struct {
    id: u32,
    name: []const u8,
    blob: zerde.ByteString,
    items: []const StreamItem,
    raw: zerde.cbor.Raw,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{
        .name = .{ .max_len = 3000 },
        .blob = .{ .max_len = 6000 },
        .items = .{ .max_len = 4 },
        .raw = .{ .max_len = 40 },
    } };
};

const stream_read = .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 6000, .max_items = 100, .max_input_bytes = 20000 };

/// The decode of `input` that is cut at `cuts` in a region of exactly `streamRegionSizes`: every text and byte string is a span of
/// `input` itself (its position in the stream), and the arrays, the `Raw` and the sorted map's keys are spans of the region.
fn expectStreamSpans(input: []const u8, expected: StreamMsg, cuts: []const usize) !void {
    const sizes = comptime wire.streamRegionSizes(StreamMsg, .{}, stream_read);
    var region: Region = .{};
    var decoder: wire.StreamResumable(StreamMsg, .{}, stream_read) = undefined;
    decoder.init(region.bytes[0..sizes.output], region.base());
    var from: usize = 0;
    for (cuts) |cut| {
        _ = try decoder.feed(input[from..cut]);
        from = cut;
    }
    _ = try decoder.feed(input[from..]);
    const decoded = try decoder.finish();
    try std.testing.expect(decoded.used <= sizes.output);
    const stream: wire.Memory = .{ .base = @intFromPtr(input.ptr), .regions = &.{input} };
    const memory = region.memory();
    const value = decoded.value;
    try std.testing.expectEqual(expected.id, value.id);
    try std.testing.expectEqualSlices(u8, expected.name, try stream.bytesOf(value.name));
    try std.testing.expectEqualSlices(u8, expected.blob.bytes, try stream.bytesOf(value.blob));
    const items = try memory.listOf(wire.Wire(StreamItem), value.items);
    try std.testing.expectEqual(expected.items.len, items.len);
    for (expected.items, items) |want, got| {
        try std.testing.expectEqualSlices(u8, want.label, try stream.bytesOf(got.label));
        try std.testing.expectEqualSlices(u8, want.data.bytes, try stream.bytesOf(got.data));
    }
    try std.testing.expectEqualSlices(u8, expected.raw.bytes, try memory.bytesOf(value.raw));
}

test "a resumable decode that leaves strings in the stream gives their positions, at every cut, in a region that holds none of them" {
    // Text that is not ASCII, so a cut falls inside a character; a byte string longer than the whole region.
    var name: [200]u8 = undefined;
    for (0..100) |at| {
        name[at * 2] = 0xc3;
        name[at * 2 + 1] = 0xa9;
    }
    var blob: [5000]u8 = undefined;
    for (&blob, 0..) |*byte, at| byte.* = @truncate(at *% 7);
    const items = [_]StreamItem{
        .{ .label = "", .data = .{ .bytes = "" } },
        .{ .label = "sécond", .data = .{ .bytes = &blob } },
        .{ .label = "third", .data = .{ .bytes = "xyz" } },
    };
    const raw = [_]u8{ 0x83, 0x01, 0x02, 0x03 };
    const expected: StreamMsg = .{ .id = 70000, .name = &name, .blob = .{ .bytes = &blob }, .items = &items, .raw = .{ .bytes = &raw } };
    const input = try deterministicBytes(StreamMsg, .{}, expected);
    defer allocator.free(input);

    // The region is a fraction of the input, and holds no string: the arrays, the keys and the Raw only.
    const sizes = comptime wire.streamRegionSizes(StreamMsg, .{}, stream_read);
    try std.testing.expect(sizes.output < 1200);
    try std.testing.expect(sizes.output * 4 < input.len);
    try std.testing.expect(wire.resumableRegionSizes(StreamMsg, .{}, stream_read).output > blob.len + name.len);
    try std.testing.expectEqual(sizes.output, wire.maxStreamArenaSize(StreamMsg, .{}, stream_read));

    try expectStreamSpans(input, expected, &.{});
    for (0..input.len + 1) |cut| try expectStreamSpans(input, expected, &.{cut});
    var step: usize = 1;
    while (step < 70) : (step = step * 3 + 1) {
        var cuts: std.ArrayList(usize) = .empty;
        defer cuts.deinit(allocator);
        var at: usize = step;
        while (at < input.len) : (at += step) try cuts.append(allocator, at);
        try expectStreamSpans(input, expected, cuts.items);
    }
}

test "a resumable decode that leaves strings in the stream refuses what the whole read refuses, and a position past 4 GiB" {
    const input_ok = try deterministicBytes(StreamMsg, .{}, .{ .id = 1, .name = "ok", .blob = .{ .bytes = "b" }, .items = &.{}, .raw = .{ .bytes = &.{0x01} } });
    defer allocator.free(input_ok);
    const sizes = comptime wire.streamRegionSizes(StreamMsg, .{}, stream_read);
    var region: Region = .{};
    // Invalid UTF-8 in the name, cut at every offset: refused once the character is whole.
    const bad = try allocator.dupe(u8, input_ok);
    defer allocator.free(bad);
    const name_at = std.mem.indexOf(u8, bad, "ok").?;
    // A character the text ends in the middle of is refused too, at the end of the text.
    for ([_][2]u8{ .{ 0xc3, 0x28 }, .{ 'o', 0xc3 } }) |pair| {
        bad[name_at] = pair[0];
        bad[name_at + 1] = pair[1];
        for (0..bad.len + 1) |cut| {
            var decoder: wire.StreamResumable(StreamMsg, .{}, stream_read) = undefined;
            decoder.init(region.bytes[0..sizes.output], region.base());
            const first = decoder.feed(bad[0..cut]);
            if (first) |_| {
                try std.testing.expectError(error.InvalidUtf8, decoder.feed(bad[cut..]));
            } else |err| try std.testing.expectEqual(error.InvalidUtf8, err);
        }
    }
    // A text over its bound is refused from its head, before any of it is read.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(allocator);
    try long.appendSlice(allocator, &.{ 0xa6, 0x62, 'i', 'd', 0x01, 0x63, 'r', 'a', 'w', 0x01, 0x64, 'b', 'l', 'o', 'b', 0x40, 0x64, 'n', 'a', 'm', 'e', 0x79, 0x0b, 0xb9 });
    var decoder: wire.StreamResumable(StreamMsg, .{}, stream_read) = undefined;
    decoder.init(region.bytes[0..sizes.output], region.base());
    try std.testing.expectError(error.LengthOutOfBounds, decoder.feed(long.items));
    // The span of a string whose position does not fit 32 bits.
    var sink: wire.WireSink = undefined;
    try std.testing.expectError(error.OffsetOutOfRange, sink.span([]const u8, 0xffff_fff0, 0x20));
    try std.testing.expectEqual(wire.Span{ .offset = 0xffff_fff0, .len = 0x0f }, try sink.span([]const u8, 0xffff_fff0, 0x0f));
    try std.testing.expectEqual(wire.Span{ .offset = 0, .len = 0 }, try sink.span([]const u8, 123, 0));
}

const StreamKeyed = struct {
    name: []const u8,
    labels: zerde.SortedMap(zerde.ByteString),
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .name = .{ .max_len = 40 }, .labels = .{ .max_len = 3, .elem = .{ .max_len = 40 } } } };
};

test "a resumable decode that leaves strings in the stream keeps a sorted map's keys, and they are compared, at every cut" {
    const read = .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 64, .max_items = 50, .max_input_bytes = 1000 };
    const Entry = zerde.SortedMap(zerde.ByteString).Entry;
    const entries = [_]Entry{ .{ .key = "a", .value = .{ .bytes = "one" } }, .{ .key = "bb", .value = .{ .bytes = "two" } }, .{ .key = "ccc", .value = .{ .bytes = "" } } };
    const expected: StreamKeyed = .{ .name = "named", .labels = .{ .entries = &entries } };
    const input = try deterministicBytes(StreamKeyed, .{}, expected);
    defer allocator.free(input);
    const sizes = comptime wire.streamRegionSizes(StreamKeyed, .{}, read);
    // Three keys of up to 64 bytes are charged, and the value strings and the name are not.
    try std.testing.expect(sizes.output >= 3 * 64 + 256);
    try std.testing.expect(wire.resumableRegionSizes(StreamKeyed, .{}, read).output >= sizes.output + 40 + 3 * 40);
    const stream: wire.Memory = .{ .base = @intFromPtr(input.ptr), .regions = &.{input} };
    var region: Region = .{};
    for (0..input.len + 1) |cut| {
        var decoder: wire.StreamResumable(StreamKeyed, .{}, read) = undefined;
        decoder.init(region.bytes[0..sizes.output], region.base());
        _ = try decoder.feed(input[0..cut]);
        _ = try decoder.feed(input[cut..]);
        const decoded = try decoder.finish();
        try std.testing.expectEqualSlices(u8, "named", try stream.bytesOf(decoded.value.name));
        const got = try region.memory().listOf(wire.Wire(Entry), decoded.value.labels.entries);
        try std.testing.expectEqual(@as(usize, 3), got.len);
        for (entries, got) |want, have| {
            try std.testing.expectEqualSlices(u8, want.key, try region.memory().bytesOf(have.key));
            try std.testing.expectEqualSlices(u8, want.value.bytes, try stream.bytesOf(have.value));
        }
    }
}

test "a resumable decode holds a Raw that fills the input in a region of exactly its bound, fed a byte at a time" {
    const BigRaw = struct {
        raw: zerde.cbor.Raw,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .raw = .{ .max_len = 20000 } } };
    };
    // The Raw's own bound and the string bound are far above what the input allows, which is what clamps the charge.
    const read = .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 20000, .max_input_bytes = 6000 };
    const sizes = comptime wire.resumableRegionSizes(BigRaw, .{}, read);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, &.{ 0xa1, 0x63, 'r', 'a', 'w', 0x59, 0x17, 0x60 });
    try input.appendNTimes(allocator, 0xff, 5984);
    try std.testing.expect(input.items.len <= 6000);
    var region: Region = .{};
    var decoder: wire.Resumable(BigRaw, .{}, read) = undefined;
    decoder.init(region.bytes[0..sizes.output], region.base());
    for (input.items) |byte| _ = try decoder.feed(&.{byte});
    const decoded = try decoder.finish();
    try std.testing.expectEqualSlices(u8, input.items[5..], try region.memory().bytesOf(decoded.value.raw));
    try std.testing.expect(decoded.used <= sizes.output);
    // The bytes it grows through are never more than the stream may still hold, wherever the item starts.
    try std.testing.expect(sizes.output <= 6000 + 256);
}

test "a fixed array read from an array of unstated length takes exactly its length, and frees what it read when it does not" {
    // JSON states no length: too few items is refused at the end, too many at the first one past it.
    try expectJsonError([3]u16, error.LengthMismatch, "[]");
    try expectJsonError([3]u16, error.LengthMismatch, "[1,2]");
    try expectJsonError([3]u16, error.LengthMismatch, "[1,2,3,4]");
    try std.testing.expectEqual([3]u16{ 1, 2, 3 }, try zerde.json.parseSlice([3]u16, allocator, "[1,2,3]"));
    // Owning elements read before the short end are freed (the testing allocator reports a leak).
    try expectJsonError([3][]const u8, error.LengthMismatch, "[\"a\",\"b\"]");
}

test "a resumable decode that leaves strings in the stream holds a text to its least length too, at every cut" {
    const Short = struct {
        name: []const u8,
        pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .name = .{ .min_len = 2, .max_len = 10 } } };
    };
    const read = .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 64, .max_input_bytes = 100 };
    const sizes = comptime wire.streamRegionSizes(Short, .{}, read);
    var region: Region = .{};
    const too_short = [_]u8{ 0xa1, 0x64, 'n', 'a', 'm', 'e', 0x61, 'x' };
    const enough = [_]u8{ 0xa1, 0x64, 'n', 'a', 'm', 'e', 0x62, 'x', 'y' };
    for (0..too_short.len + 1) |cut| {
        var decoder: wire.StreamResumable(Short, .{}, read) = undefined;
        decoder.init(region.bytes[0..sizes.output], region.base());
        const first = decoder.feed(too_short[0..cut]);
        if (first) |_| {
            try std.testing.expectError(error.LengthOutOfBounds, decoder.feed(too_short[cut..]));
        } else |err| try std.testing.expectEqual(error.LengthOutOfBounds, err);
    }
    var decoder: wire.StreamResumable(Short, .{}, read) = undefined;
    decoder.init(region.bytes[0..sizes.output], region.base());
    _ = try decoder.feed(&enough);
    try std.testing.expectEqual(wire.Span{ .offset = 7, .len = 2 }, (try decoder.finish()).value.name);
}

// ---- Keys and names of TOML, YAML, ZON, BSON and msgpack: compared where they are read --------------------------

const NameColor = enum { red, green };
const NamedFields = struct { a: u8, c: NameColor };
const NoFields = struct {};

fn allocationsOf(comptime Format: type, comptime T: type, input: []const u8) !usize {
    var counting = std.testing.FailingAllocator.init(allocator, .{});
    const value = try zerde.parseSliceAliased(Format, T, counting.allocator(), input);
    _ = value;
    return counting.allocations;
}

/// A read of declared keys and of an enum's name allocates what a read that ignores every member does: the
/// document the format builds first, and nothing for the keys and names themselves.
fn expectNamesFree(comptime Format: type, input: []const u8) !void {
    try std.testing.expectEqual(try allocationsOf(Format, NoFields, input), try allocationsOf(Format, NamedFields, input));
}

test "TOML and YAML read a declared key and an enum name without allocating" {
    try expectNamesFree(zerde.toml, "a = 1\nc = \"red\"\n");
    try expectNamesFree(zerde.toml, "a = 1\nc = \"r\\u0065d\"\n");
    try expectNamesFree(zerde.yaml, "a: 1\nc: red\n");
    try expectNamesFree(zerde.yaml, "a: 1\nc: \"red\"\n");
    const toml = try zerde.parseSliceAliased(zerde.toml, NamedFields, allocator, "a = 1\nc = \"gre\\u0065n\"\n");
    try std.testing.expectEqual(NameColor.green, toml.c);
    try std.testing.expectError(error.InvalidEnumTag, zerde.parseSliceAliased(zerde.toml, NamedFields, allocator, "a = 1\nc = \"blue\"\n"));
}

test "ZON reads an enum's name from a string literal without allocating" {
    // A literal in escapes, an enum literal and a plain literal: the same allocations as a read of no member.
    try expectNamesFree(zerde.zon, ".{ .a = 1, .c = \"r\\x65d\" }");
    try expectNamesFree(zerde.zon, ".{ .a = 1, .c = \"red\" }");
    try expectNamesFree(zerde.zon, ".{ .a = 1, .c = .red }");
    const green = try zerde.parseSliceAliased(zerde.zon, NamedFields, allocator, ".{ .a = 1, .c = \"gre\\x65n\" }");
    try std.testing.expectEqual(NameColor.green, green.c);
    // A name is the exact length of the longest one, or it is none; a longer literal is read to its end.
    try std.testing.expectError(error.InvalidEnumTag, zerde.parseSliceAliased(zerde.zon, NamedFields, allocator, ".{ .a = 1, .c = \"gre\\x65en\" }"));
    try std.testing.expectError(error.InvalidEnumTag, zerde.parseSliceAliased(zerde.zon, NamedFields, allocator, ".{ .a = 1, .c = \"reddddddddddddddddddddd\" }"));
    try std.testing.expectError(error.InvalidStringLiteral, zerde.parseSliceAliased(zerde.zon, NamedFields, allocator, ".{ .a = 1, .c = \"reddddddddddddddddddddd\\q\" }"));
    try std.testing.expectError(error.InvalidStringLiteral, zerde.parseSliceAliased(zerde.zon, NamedFields, allocator, ".{ .a = 1, .c = \"r\\q\" }"));
}

test "BSON and msgpack read a declared key and an enum name without allocating" {
    const bson = [_]u8{ 23, 0, 0, 0, 0x10, 'a', 0, 1, 0, 0, 0, 0x02, 'c', 0, 4, 0, 0, 0, 'r', 'e', 'd', 0, 0 };
    try std.testing.expectEqual(@as(usize, 0), try allocationsOf(zerde.bson, NamedFields, &bson));
    const msgpack = [_]u8{ 0x82, 0xa1, 'a', 0x01, 0xa1, 'c', 0xa3, 'r', 'e', 'd' };
    try std.testing.expectEqual(@as(usize, 0), try allocationsOf(zerde.msgpack, NamedFields, &msgpack));
    const got = try zerde.parseSliceAliased(zerde.msgpack, NamedFields, allocator, &msgpack);
    try std.testing.expectEqual(NameColor.red, got.c);
}

/// Reads `{a: 1, c: "red"}` member by member and hands every key and string read the failing allocator, so a read
/// that allocates for a key or a name, even to free it again, is `error.OutOfMemory` here whatever the document built.
fn expectKeyReadsFree(deserializer: anytype) !void {
    const none = std.testing.failing_allocator;
    try deserializer.beginObject();
    const first = (try deserializer.nextObjectField(none)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a", first.bytes);
    try std.testing.expect(!first.allocated);
    _ = try deserializer.readNumber();
    const second = (try deserializer.nextObjectField(none)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("c", second.bytes);
    try std.testing.expect(!second.allocated);
    const name = try deserializer.readString(none);
    try std.testing.expectEqualStrings("red", name.bytes);
    try std.testing.expect(!name.allocated);
    try std.testing.expectEqual(@as(?zerde.typed.StringToken, null), try deserializer.nextObjectField(none));
}

test "a key and a string are read by every format with no allocation, whatever the allocator" {
    var toml = try zerde.toml.sliceDeserializer(allocator, "a = 1\nc = \"red\"\n", .{});
    defer toml.deinit(allocator);
    try expectKeyReadsFree(&toml);
    var yaml = try zerde.yaml.sliceDeserializer(allocator, "a: 1\nc: red\n", .{});
    defer yaml.deinit(allocator);
    try expectKeyReadsFree(&yaml);
    var zon = try zerde.zon.sliceDeserializer(allocator, ".{ .a = 1, .c = .red }", .{});
    defer zon.deinit(allocator);
    try expectKeyReadsFree(&zon);
    var msgpack = try zerde.msgpack.sliceDeserializer(allocator, &.{ 0x82, 0xa1, 'a', 0x01, 0xa1, 'c', 0xa3, 'r', 'e', 'd' }, .{});
    try expectKeyReadsFree(&msgpack);
    var bson = try zerde.bson.sliceDeserializer(allocator, &.{ 23, 0, 0, 0, 0x10, 'a', 0, 1, 0, 0, 0, 0x02, 'c', 0, 4, 0, 0, 0, 'r', 'e', 'd', 0, 0 }, .{});
    try expectKeyReadsFree(&bson);
}
