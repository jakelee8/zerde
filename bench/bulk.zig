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

    // A strict CBOR read of a long text, rendered as JSON: checked on the way in and out, and trusted.
    var cbor_text: std.Io.Writer.Allocating = .init(allocator);
    defer cbor_text.deinit();
    var writer = zerde.cbor.valueWriter(allocator, &cbor_text.writer, .{ .deterministic = true });
    defer writer.deinit();
    try writer.writeText(ascii);
    try report(out, "ascii", "cbor to json render, trusted vs checked", try time(io, renderTrusted, cbor_text.written(), &sink.writer), try time(io, renderChecked, cbor_text.written(), &sink.writer), ascii.len);
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

fn scanByte(bytes: []const u8, _: *std.Io.Writer) anyerror!usize {
    var count: usize = 0;
    for (bytes) |c| {
        if (c == '"' or c == '\\' or c < 0x20) count += 1;
    }
    return count;
}
