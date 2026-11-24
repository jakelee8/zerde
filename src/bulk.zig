//! Scans over runs of bytes for the string paths of the JSON and CBOR backends.
//!
//! The word versions use 64-bit integer operations only, so they behave the same on every target and
//! need no SIMD: a WebAssembly build without `simd128` gets their speedup. Where the target has
//! vectors (`std.simd.suggestVectorLength`: a native target, or WebAssembly with `simd128`) the scan for
//! the end of a string uses them instead. Each function has an obvious byte-wise reference in the
//! tests, which it must match on every input.

const std = @import("std");

const ones: u64 = 0x0101010101010101;
const highs: u64 = 0x8080808080808080;

/// Whether any byte of `word` is zero (exact as a yes or no, though not as a position).
fn hasZero(word: u64) bool {
    return ((word -% ones) & ~word & highs) != 0;
}

/// Whether any byte of `word` is below `limit` (at most 128; exact as a yes or no).
fn hasBelow(word: u64, comptime limit: u8) bool {
    return ((word -% ones * limit) & ~word & highs) != 0;
}

/// The index of the first byte of `bytes` at or after `from` that a JSON string cannot hold as it
/// is: `"`, `\` or a control character below 0x20. `bytes.len` when there is none. It looks at a
/// vector of bytes at a time where the target has vectors, and a word at a time elsewhere.
pub fn findStringSpecial(bytes: []const u8, from: usize) usize {
    if (comptime std.simd.suggestVectorLength(u8)) |width| return findStringSpecialVector(width, bytes, from);
    return findStringSpecialWords(bytes, from);
}

/// `findStringSpecial` with vectors of `width` bytes.
pub fn findStringSpecialVector(comptime width: usize, bytes: []const u8, from: usize) usize {
    const Vector = @Vector(width, u8);
    var i = from;
    while (i + width <= bytes.len) : (i += width) {
        const chunk: Vector = bytes[i..][0..width].*;
        const special = (chunk == @as(Vector, @splat('"'))) | (chunk == @as(Vector, @splat('\\'))) | (chunk < @as(Vector, @splat(0x20)));
        if (std.simd.firstTrue(special)) |offset| return i + offset;
    }
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '"' or c == '\\' or c < 0x20) return i;
    }
    return bytes.len;
}

/// `findStringSpecial` a word at a time, for a target without vectors.
pub fn findStringSpecialWords(bytes: []const u8, from: usize) usize {
    var i = from;
    while (i + 8 <= bytes.len) : (i += 8) {
        const word = std.mem.readInt(u64, bytes[i..][0..8], .little);
        if (hasZero(word ^ (ones * '"')) or hasZero(word ^ (ones * '\\')) or hasBelow(word, 0x20)) break;
    }
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '"' or c == '\\' or c < 0x20) return i;
    }
    return bytes.len;
}

/// Whether `bytes` is valid UTF-8. Where the standard library skips ASCII in vector chunks (a native
/// target, or WebAssembly with `simd128`) its validator is already as fast as `validUtf8Words`, so it
/// is used; elsewhere, which includes a WebAssembly build without SIMD, the word-at-a-time one is.
pub fn validUtf8(bytes: []const u8) bool {
    if (comptime std.simd.suggestVectorLength(u8) != null) return std.unicode.utf8ValidateSlice(bytes);
    return validUtf8Words(bytes);
}

/// Whether `bytes` is valid UTF-8, skipping ASCII eight bytes at a time. Text that is not ASCII is
/// checked by the standard library's decoder, a region at a time: from the first byte of a word with
/// a high bit to the end of the run of such words.
pub fn validUtf8Words(bytes: []const u8) bool {
    var i: usize = 0;
    while (true) {
        while (i + 8 <= bytes.len and (std.mem.readInt(u64, bytes[i..][0..8], .little) & highs) == 0) i += 8;
        // A word that holds a high byte starts here, so the byte is within seven.
        while (i < bytes.len and bytes[i] < 0x80) i += 1;
        if (i >= bytes.len) return true;

        // From here to the end of the run of words that hold a high byte. The word after it has none, so no
        // sequence runs on into it; fewer than eight bytes left are part of the region, whole.
        var end = i + 1;
        while (end + 8 <= bytes.len and (std.mem.readInt(u64, bytes[end..][0..8], .little) & highs) != 0) end += 8;
        if (end + 8 > bytes.len) end = bytes.len;
        if (!std.unicode.utf8ValidateSlice(bytes[i..end])) return false;
        i = end;
    }
}

/// Writes `bytes` as the characters of a JSON string (no quotes): runs that need no escape go out in
/// one write each, and the rest as `\"`, `\\`, `\b`, `\f`, `\n`, `\r`, `\t` or `\u00xx`. The output is
/// what `std.json.Stringify.encodeJsonStringChars` writes. An escape is written straight into the
/// writer's spare buffer when it fits, which costs a fraction of going through `writeAll`.
pub fn writeEscaped(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    while (true) {
        const at = findStringSpecial(bytes, start);
        if (at > start) try writer.writeAll(bytes[start..at]);
        if (at >= bytes.len) return;
        var escape: [6]u8 = undefined;
        const length = escapeInto(&escape, bytes[at]);
        const spare = writer.buffer.len - writer.end;
        if (spare >= escape.len) {
            // `end` is how much of the buffer holds output; the escape lands after it.
            @memcpy(writer.buffer[writer.end..][0..escape.len], &escape);
            writer.end += length;
        } else {
            try writer.writeAll(escape[0..length]);
        }
        start = at + 1;
    }
}

/// The escape of byte `c` (a `"`, a `\` or a control character) as the characters of a JSON string,
/// written to the start of `out`; how many bytes it is.
fn escapeInto(out: *[6]u8, c: u8) usize {
    const hex = "0123456789abcdef";
    out[0] = '\\';
    switch (c) {
        '"' => out[1] = '"',
        '\\' => out[1] = '\\',
        0x08 => out[1] = 'b',
        0x0c => out[1] = 'f',
        '\n' => out[1] = 'n',
        '\r' => out[1] = 'r',
        '\t' => out[1] = 't',
        else => {
            out[1] = 'u';
            out[2] = '0';
            out[3] = '0';
            out[4] = hex[c >> 4];
            out[5] = hex[c & 0xf];
            return 6;
        },
    }
    return 2;
}

fn referenceSpecial(bytes: []const u8, from: usize) usize {
    for (bytes[from..], from..) |c, i| {
        if (c == '"' or c == '\\' or c < 0x20) return i;
    }
    return bytes.len;
}

fn expectFinder(comptime find: anytype) !void {
    // Every special byte at every offset of a buffer long enough for several words and vectors, with
    // plain bytes (ASCII and not) around it.
    var buffer: [71]u8 = undefined;
    for ([_]u8{ 'a', 0x7f, 0x80, 0xff, 0x20 }) |filler| {
        @memset(&buffer, filler);
        for (0..buffer.len) |position| {
            for ([_]u8{ '"', '\\', 0x00, 0x1f, 0x0a }) |special| {
                buffer[position] = special;
                for (0..buffer.len + 1) |from| {
                    try std.testing.expectEqual(referenceSpecial(&buffer, from), find(&buffer, from));
                }
                buffer[position] = filler;
            }
        }
        for (0..buffer.len + 1) |from| try std.testing.expectEqual(buffer.len, find(&buffer, from));
    }
    // Bytes next to the special ones are not mistaken for them: `#` is `"` plus one, `]` is `\` plus one.
    const near = "!#$[]^ ~\x7f\x80\xa2\xdc\xdd\xde";
    try std.testing.expectEqual((near ++ near ++ near).len, find(near ++ near ++ near, 0));
    var many: [64]u8 = undefined;
    for (&many, 0..) |*c, i| c.* = near[i % near.len];
    try std.testing.expectEqual(many.len, find(&many, 0));
}

fn vector8(bytes: []const u8, from: usize) usize {
    return findStringSpecialVector(8, bytes, from);
}

fn vector16(bytes: []const u8, from: usize) usize {
    return findStringSpecialVector(16, bytes, from);
}

fn vector32(bytes: []const u8, from: usize) usize {
    return findStringSpecialVector(32, bytes, from);
}

test "findStringSpecial matches the byte-wise scan at every position and length, whichever way it scans" {
    try expectFinder(findStringSpecial);
    try expectFinder(findStringSpecialWords);
    try expectFinder(vector8);
    try expectFinder(vector16);
    try expectFinder(vector32);
}

test "validUtf8 and validUtf8Words agree with the standard library on valid and invalid input" {
    const valid = [_][]const u8{
        "",             "a",                 "plain ascii text that is longer than a word",
        "h\xc3\xa9llo", "\xe2\x82\xac euro", "\xf0\x9f\x98\x80 grin",
        "\x7f\x00\x01", "\xc2\x80",          "\xdf\xbf",
        "\xe0\xa0\x80", "\xed\x9f\xbf",      "\xee\x80\x80",
        "\xef\xbf\xbf", "\xf0\x90\x80\x80",  "\xf4\x8f\xbf\xbf",
    };
    for (valid) |text| {
        try std.testing.expect(validUtf8(text));
        try std.testing.expect(validUtf8Words(text));
    }
    const invalid = [_][]const u8{
        "\x80",             "\xbf",                     "\xc0\x80",
        "\xc1\xbf",         "\xc2",                     "\xc2\x20",
        "\xe0\x80\x80",     "\xe0\x9f\xbf",             "\xed\xa0\x80",
        "\xed\xbf\xbf",     "\xe2\x82",                 "\xf0\x80\x80\x80",
        "\xf0\x8f\xbf\xbf", "\xf4\x90\x80\x80",         "\xf5\x80\x80\x80",
        "\xff",             "\xfe",                     "abcdefgh\xc3",
        "abcdefgh\x80",     "abcdefghijklmnop\xe2\x82",
    };
    for (invalid) |text| {
        try std.testing.expect(!validUtf8(text));
        try std.testing.expect(!validUtf8Words(text));
    }
    // Every one- to three-byte prefix pattern, against the standard library: no disagreement.
    var buffer: [3]u8 = undefined;
    var a: usize = 0;
    while (a < 256) : (a += 1) {
        buffer[0] = @intCast(a);
        try std.testing.expectEqual(std.unicode.utf8ValidateSlice(buffer[0..1]), validUtf8Words(buffer[0..1]));
        var b: usize = 0;
        while (b < 256) : (b += 1) {
            buffer[1] = @intCast(b);
            try std.testing.expectEqual(std.unicode.utf8ValidateSlice(buffer[0..2]), validUtf8Words(buffer[0..2]));
            var c: usize = 0;
            while (c < 256) : (c += 16) {
                buffer[2] = @intCast(c);
                try std.testing.expectEqual(std.unicode.utf8ValidateSlice(buffer[0..3]), validUtf8Words(buffer[0..3]));
            }
        }
    }
    // A valid sequence that straddles the end of a word, and an invalid byte in a later word.
    var padded: [40]u8 = @splat('x');
    @memcpy(padded[7..9], "\xc3\xa9");
    try std.testing.expect(validUtf8Words(&padded));
    padded[30] = 0xff;
    try std.testing.expect(!validUtf8Words(&padded));
    // Every position of a two- and a three-byte character in a longer ASCII text, valid and cut short.
    var text: [41]u8 = @splat('x');
    for (0..text.len - 2) |position| {
        @memset(&text, 'x');
        @memcpy(text[position..][0..3], "\xe2\x82\xac");
        try std.testing.expect(validUtf8Words(&text));
        text[position + 2] = 'x';
        try std.testing.expect(!validUtf8Words(&text));
        text[position + 2] = 0xac;
        text[position + 1] = 'x';
        try std.testing.expect(!validUtf8Words(&text));
    }
    // Several non-ASCII words in a row, the last character ending just past a word.
    const run = "\xe2\x82\xac\xe2\x82\xac\xe2\x82\xac\xe2\x82\xac\xe2\x82\xac\xe2\x82\xac\xe2\x82\xac\xe2\x82\xactail";
    try std.testing.expect(validUtf8Words(run));
    try std.testing.expect(!validUtf8Words(run[0 .. run.len - 6]));
}

test "writeEscaped writes what the standard library writes" {
    // Every single byte that is valid UTF-8 on its own (ASCII), and the multi-byte text around them.
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    var byte: u8 = 0;
    while (byte < 0x80) : (byte += 1) {
        out.clearRetainingCapacity();
        expected.clearRetainingCapacity();
        const text = [_]u8{ 'a', byte, 'b' };
        try writeEscaped(&out.writer, &text);
        try std.json.Stringify.encodeJsonStringChars(&text, .{}, &expected.writer);
        try std.testing.expectEqualStrings(expected.written(), out.written());
    }
    // A long string with specials at several places, a run of them, and non-ASCII text.
    const text = "A \"quoted\" word, a back\\slash,\nnew line\ttab\x01\x1f\x7f and h\xc3\xa9llo \xe2\x82\xac, then plain text for a while ......................\"\"\"\\\\\n\n";
    out.clearRetainingCapacity();
    expected.clearRetainingCapacity();
    try writeEscaped(&out.writer, text);
    try std.json.Stringify.encodeJsonStringChars(text, .{}, &expected.writer);
    try std.testing.expectEqualStrings(expected.written(), out.written());
    // And empty.
    out.clearRetainingCapacity();
    try writeEscaped(&out.writer, "");
    try std.testing.expectEqualStrings("", out.written());
}

test "writeEscaped fills the spare room of the writer exactly, and falls back when an escape does not fit" {
    const text = "\"\\\n\x01 plain \t\"\x1f\r\"";
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    try std.json.Stringify.encodeJsonStringChars(text, .{}, &expected.writer);
    // A buffer of exactly the output: the last escapes do not have six bytes of room and must not overrun.
    var exact: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(exact[0..expected.written().len]);
    try writeEscaped(&writer, text);
    try std.testing.expectEqualStrings(expected.written(), writer.buffered());
    // One byte less is an error, not a write past the buffer.
    var short = std.Io.Writer.fixed(exact[0 .. expected.written().len - 1]);
    try std.testing.expectError(error.WriteFailed, writeEscaped(&short, text));
    // A buffer too small to hold an escape at all drains as it goes.
    var sink: [3]u8 = undefined;
    var counting = std.Io.Writer.Discarding.init(&sink);
    try writeEscaped(&counting.writer, text);
    try std.testing.expectEqual(@as(u64, expected.written().len), counting.fullCount() + counting.writer.end);
    // Output already in the buffer is kept in front of the escape.
    var prefixed: [64]u8 = undefined;
    var after = std.Io.Writer.fixed(&prefixed);
    try after.writeAll("pre:");
    try writeEscaped(&after, "\"x\n");
    try std.testing.expectEqualStrings("pre:\\\"x\\n", after.buffered());
}
