//! Benchmark of the word-at-a-time string scans against the standard library's.
//!
//! Each case runs the same input through `zerde.bulk` and through the code it replaced, on text of the
//! shapes a body holds: a long ASCII string, the same with escapes, and text in which most bytes are
//! multi-byte. The numbers are ns per operation on the whole input.

const std = @import("std");
const zerde = @import("zerde");

const iterations = 2000;

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.writeAll("zerde bulk string scans vs the standard library\n");

    const size = 270 * 1024;
    const ascii = try allocator.alloc(u8, size);
    defer allocator.free(ascii);
    for (ascii, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));

    const escapes = try allocator.dupe(u8, ascii);
    defer allocator.free(escapes);
    var at: usize = 7;
    while (at < size) : (at += 61) escapes[at] = if (at % 2 == 0) '"' else '\n';

    const multibyte = try allocator.alloc(u8, size / 3 * 3);
    defer allocator.free(multibyte);
    for (0..multibyte.len / 3) |i| @memcpy(multibyte[i * 3 ..][0..3], "\xe2\x82\xac");

    const inputs = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "ascii", .bytes = ascii },
        .{ .name = "escapes", .bytes = escapes },
        .{ .name = "multibyte", .bytes = multibyte },
    };

    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    for (inputs) |input| {
        try report(out, input.name, "validate utf-8", try time(io, validateBulk, input.bytes, &sink.writer), try time(io, validateStd, input.bytes, &sink.writer), input.bytes.len);
        try report(out, input.name, "validate words", try time(io, validateWords, input.bytes, &sink.writer), try time(io, validateStd, input.bytes, &sink.writer), input.bytes.len);
        try report(out, input.name, "escape", try time(io, escapeBulk, input.bytes, &sink.writer), try time(io, escapeStd, input.bytes, &sink.writer), input.bytes.len);
        try report(out, input.name, "find special", try time(io, scanBulk, input.bytes, &sink.writer), try time(io, scanByte, input.bytes, &sink.writer), input.bytes.len);
    }

    // Real text: source files (many quotes, newlines, backslashes) and prose, as the JSON string they would be.
    const corpora = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "code 1", .bytes = @embedFile("corpus_code") },
        .{ .name = "code 2", .bytes = @embedFile("corpus_more_code") },
        .{ .name = "prose", .bytes = @embedFile("corpus_prose") },
    };
    var big_sink: std.Io.Writer.Allocating = .init(allocator);
    defer big_sink.deinit();
    try big_sink.ensureTotalCapacity(8 * 1024 * 1024);
    try out.writeAll("string scans on real text, vectors or words and one write per escape against the code before\n");
    for (corpora) |corpus| {
        var specials: usize = 0;
        for (corpus.bytes) |c| specials += @intFromBool(c == '"' or c == '\\' or c < 0x20);
        try out.print("  {s}: {d} bytes, {d} bytes to escape\n", .{ corpus.name, corpus.bytes.len, specials });
        try report(out, corpus.name, "find special", try time(io, scanBulk, corpus.bytes, &big_sink.writer), try time(io, scanWords, corpus.bytes, &big_sink.writer), corpus.bytes.len);
        try report(out, corpus.name, "escape", try time(io, escapeBulk, corpus.bytes, &big_sink.writer), try time(io, escapeBefore, corpus.bytes, &big_sink.writer), corpus.bytes.len);
    }

    // A strict CBOR read of a long text, rendered as JSON: checked on the way in and out, and trusted.
    var cbor_text: std.Io.Writer.Allocating = .init(allocator);
    defer cbor_text.deinit();
    var writer = zerde.cbor.valueWriter(allocator, &cbor_text.writer, .{ .deterministic = true });
    defer writer.deinit();
    try writer.writeText(ascii);
    try report(out, "ascii", "cbor to json render, trusted vs checked", try time(io, renderTrusted, cbor_text.written(), &sink.writer), try time(io, renderChecked, cbor_text.written(), &sink.writer), ascii.len);

    // Every sixth byte a quote: the windowed escape and render, where "bulk" is the windowed path and "std" the whole-buffer one.
    const escapes6 = try allocator.dupe(u8, ascii);
    defer allocator.free(escapes6);
    at = 5;
    while (at < size) : (at += 6) escapes6[at] = '"';
    try report(out, "escapes6", "escape, 64 KiB windows", try time(io, escapeWindowed, escapes6, &sink.writer), try time(io, escapeBulk, escapes6, &sink.writer), escapes6.len);
    var cbor_escapes: std.Io.Writer.Allocating = .init(allocator);
    defer cbor_escapes.deinit();
    var escapes_writer = zerde.cbor.valueWriter(allocator, &cbor_escapes.writer, .{ .deterministic = true });
    defer escapes_writer.deinit();
    try escapes_writer.writeText(escapes6);
    try report(out, "escapes6", "render, 64 KiB windows", try time(io, renderWindowed, cbor_escapes.written(), &sink.writer), try time(io, renderChecked, cbor_escapes.written(), &sink.writer), escapes6.len);
    try out.flush();
}

fn render(bytes: []const u8, sink: *std.Io.Writer, comptime trusted: bool) !usize {
    var pull = try zerde.cbor.pullReader(std.heap.page_allocator, bytes, .{ .mode = .strict, .trusted_text = trusted });
    defer pull.deinit();
    var json = zerde.json.valueWriter(std.heap.page_allocator, sink, .{ .trusted_text = trusted });
    defer json.deinit();
    while (try pull.next()) |event| try json.writeEvent(event);
    return sink.end;
}

fn renderTrusted(bytes: []const u8, sink: *std.Io.Writer) anyerror!usize {
    return render(bytes, sink, true);
}

fn renderChecked(bytes: []const u8, sink: *std.Io.Writer) anyerror!usize {
    return render(bytes, sink, false);
}

/// The JSON string of `bytes`, written through a 64 KiB window that is emptied each time it fills.
fn escapeWindowed(bytes: []const u8, _: *std.Io.Writer) anyerror!usize {
    var window: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&window);
    var state: zerde.typed.TextState = .{};
    var total: usize = 0;
    while (true) {
        zerde.json.writeEscapedPart(&w, bytes, &state, true) catch |err| switch (err) {
            error.WindowFull => {
                total += w.end;
                w.end = 0;
                continue;
            },
            else => return err,
        };
        return total + w.end;
    }
}

/// Stored strict CBOR rendered as JSON through a 64 KiB window.
fn renderWindowed(bytes: []const u8, _: *std.Io.Writer) anyerror!usize {
    var window: [64 * 1024]u8 = undefined;
    var render_state = zerde.resumable.Render(.{}).init();
    var total: usize = 0;
    while (true) {
        const filled = try render_state.fill(bytes, &window);
        total += filled.len;
        if (filled.done) return total;
    }
}

fn report(out: *std.Io.Writer, input: []const u8, what: []const u8, bulk_ns: u64, std_ns: u64, bytes: usize) !void {
    const per_bulk = @as(f64, @floatFromInt(bulk_ns)) / iterations;
    const per_std = @as(f64, @floatFromInt(std_ns)) / iterations;
    const mib = @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
    try out.print("  {s:<10} {s:<15} bulk {d:>10.0} ns ({d:>7.0} MiB/s)   std {d:>10.0} ns ({d:>7.0} MiB/s)   {d:.2}x\n", .{
        input, what, per_bulk, mib / (per_bulk / 1e9), per_std, mib / (per_std / 1e9), per_std / per_bulk,
    });
}

const Func = *const fn ([]const u8, *std.Io.Writer) anyerror!usize;

fn time(io: std.Io, func: Func, bytes: []const u8, sink: *std.Io.Writer) !u64 {
    var keep: usize = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        sink.end = 0;
        keep +%= try func(bytes, sink);
    }
    const elapsed: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
    std.mem.doNotOptimizeAway(keep);
    return elapsed;
}

fn validateBulk(bytes: []const u8, _: *std.Io.Writer) anyerror!usize {
    return @intFromBool(zerde.bulk.validUtf8(bytes));
}

fn validateWords(bytes: []const u8, _: *std.Io.Writer) anyerror!usize {
    return @intFromBool(zerde.bulk.validUtf8Words(bytes));
}

fn validateStd(bytes: []const u8, _: *std.Io.Writer) anyerror!usize {
    return @intFromBool(std.unicode.utf8ValidateSlice(bytes));
}

fn escapeBulk(bytes: []const u8, sink: *std.Io.Writer) anyerror!usize {
    try zerde.bulk.writeEscaped(sink, bytes);
    return sink.end;
}

fn escapeStd(bytes: []const u8, sink: *std.Io.Writer) anyerror!usize {
    try std.json.Stringify.encodeJsonStringChars(bytes, .{}, sink);
    return sink.end;
}

fn scanBulk(bytes: []const u8, _: *std.Io.Writer) anyerror!usize {
    var count: usize = 0;
    var at: usize = 0;
    while (true) {
        at = zerde.bulk.findStringSpecial(bytes, at);
        if (at >= bytes.len) return count;
        count += 1;
        at += 1;
    }
}

fn scanWords(bytes: []const u8, _: *std.Io.Writer) anyerror!usize {
    var count: usize = 0;
    var at: usize = 0;
    while (true) {
        at = zerde.bulk.findStringSpecialWords(bytes, at);
        if (at >= bytes.len) return count;
        count += 1;
        at += 1;
    }
}

/// `writeEscaped` as it was before the direct write: the word scan and one `writeAll` per escape.
fn escapeBefore(bytes: []const u8, sink: *std.Io.Writer) anyerror!usize {
    var start: usize = 0;
    while (true) {
        const at = zerde.bulk.findStringSpecialWords(bytes, start);
        if (at > start) try sink.writeAll(bytes[start..at]);
        if (at >= bytes.len) return sink.end;
        switch (bytes[at]) {
            '"' => try sink.writeAll("\\\""),
            '\\' => try sink.writeAll("\\\\"),
            0x08 => try sink.writeAll("\\b"),
            0x0c => try sink.writeAll("\\f"),
            '\n' => try sink.writeAll("\\n"),
            '\r' => try sink.writeAll("\\r"),
            '\t' => try sink.writeAll("\\t"),
            else => |c| {
                const hex = "0123456789abcdef";
                try sink.writeAll(&.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf] });
            },
        }
        start = at + 1;
    }
}

fn scanByte(bytes: []const u8, _: *std.Io.Writer) anyerror!usize {
    var count: usize = 0;
    for (bytes) |c| {
        if (c == '"' or c == '\\' or c < 0x20) count += 1;
    }
    return count;
}
