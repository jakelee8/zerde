//! Scans over runs of bytes, a word at a time, for the string paths of the JSON and CBOR backends.
//!
//! They use 64-bit integer operations only, so they behave the same on every target and need no SIMD:
//! a WebAssembly build without `simd128` gets the same speedup, and one with it is not qualified
//! differently. Each function has an obvious byte-wise reference in the tests, which it must match
//! on every input.

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
/// is: `"`, `\` or a control character below 0x20. `bytes.len` when there is none.
pub fn findStringSpecial(bytes: []const u8, from: usize) usize {
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
/// what `std.json.Stringify.encodeJsonStringChars` writes.
pub fn writeEscaped(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    while (true) {
        const at = findStringSpecial(bytes, start);
        if (at > start) try writer.writeAll(bytes[start..at]);
        if (at >= bytes.len) return;
        switch (bytes[at]) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => |c| {
                const hex = "0123456789abcdef";
                try writer.writeAll(&.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf] });
            },
        }
        start = at + 1;
    }
}

fn referenceSpecial(bytes: []const u8, from: usize) usize {
    for (bytes[from..], from..) |c, i| {
        if (c == '"' or c == '\\' or c < 0x20) return i;
    }
    return bytes.len;
}

test "findStringSpecial matches the byte-wise scan at every position and length" {
    // Every special byte at every offset of a buffer long enough for several words, with plain bytes
    // (ASCII and not) around it.
    var buffer: [37]u8 = undefined;
    for ([_]u8{ 'a', 0x7f, 0x80, 0xff, 0x20 }) |filler| {
        @memset(&buffer, filler);
        for (0..buffer.len) |position| {
            for ([_]u8{ '"', '\\', 0x00, 0x1f, 0x0a }) |special| {
                buffer[position] = special;
                for (0..buffer.len + 1) |from| {
                    try std.testing.expectEqual(referenceSpecial(&buffer, from), findStringSpecial(&buffer, from));
                }
                buffer[position] = filler;
            }
        }
        for (0..buffer.len + 1) |from| try std.testing.expectEqual(buffer.len, findStringSpecial(&buffer, from));
    }
    // Bytes next to the special ones are not mistaken for them: `#` is `"` plus one, `]` is `\` plus one.
    const near = "!#$[]^ ~\x7f\x80\xa2\xdc\xdd\xde";
    try std.testing.expectEqual((near ++ near ++ near).len, findStringSpecial(near ++ near ++ near, 0));
    var many: [64]u8 = undefined;
    for (&many, 0..) |*c, i| c.* = near[i % near.len];
    try std.testing.expectEqual(many.len, findStringSpecial(&many, 0));
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
