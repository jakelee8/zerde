//! Benchmark of `zerde.wire.decode` on real text: a commit of effects whose payloads are the lines of this
//! repository's own source files and README, in strict CBOR (definite lengths, spans of the input) and in
//! JSON (escapes and base64 that are rewritten).
//!
//! For each read it prints the arena it took when done and at its peak, the bound the schema gives, and ns per
//! decode. The input is never generated load: the corpus is `corpus_code`, `corpus_more_code` and `corpus_prose`.

const std = @import("std");
const zerde = @import("zerde");
const wire = zerde.wire;

const iterations = 200;
const lines_per_effect = 24;

const Put = struct {
    key: zerde.ByteString,
    payload: zerde.ByteString,
    note: []const u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{
        .key = .{ .max_len = 16 },
        .payload = .{ .max_len = 1 << 20 },
        .note = .{ .max_len = 1 << 20 },
    } };
};

const Effect = union(enum) {
    put: Put,
    delete: zerde.ByteString,
    pub const serde = .{ .fields = .{ .delete = .{ .max_len = 16 } } };
};

const Commit = struct {
    effects: []const Effect,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .effects = .{ .max_len = 4096 } } };
};

const read_cbor = .{ .mode = zerde.cbor.Mode.strict, .max_items = 40_000, .max_string_len = 1 << 20, .max_input_bytes = 8 << 20 };
const read_json = .{ .bytes = zerde.json.BytesEncoding.base64, .max_items = 40_000, .max_string_len = 1 << 20, .max_input_bytes = 8 << 20 };

const corpora = [_][]const u8{ @embedFile("wire_corpus_code"), @embedFile("wire_corpus_more_code"), @embedFile("wire_corpus_prose") };

/// The effects: a put for every `lines_per_effect` lines of the corpora, a delete after each seventh.
fn effects(allocator: std.mem.Allocator, keys: *std.ArrayList([8]u8)) ![]Effect {
    var list: std.ArrayList(Effect) = .empty;
    for (corpora) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var start: usize = 0;
        var count: usize = 0;
        while (true) {
            const line = lines.next() orelse break;
            count += 1;
            if (count % lines_per_effect != 0) continue;
            const end = @intFromPtr(line.ptr) - @intFromPtr(text.ptr) + line.len;
            const chunk = text[start..end];
            start = end + 1;
            const index = list.items.len;
            try keys.append(allocator, std.mem.toBytes(std.mem.nativeToBig(u64, index)));
            const key = &keys.items[keys.items.len - 1];
            try list.append(allocator, if (index % 7 == 6) .{ .delete = .{ .bytes = key } } else .{ .put = .{ .key = .{ .bytes = key }, .payload = .{ .bytes = chunk }, .note = chunk } });
        }
    }
    return list.toOwnedSlice(allocator);
}

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.writeAll("zerde wire decode on the source of this repository\n");

    var keys: std.ArrayList([8]u8) = .empty;
    try keys.ensureTotalCapacity(allocator, 4096);
    const list = try effects(allocator, &keys);
    const commit: Commit = .{ .effects = list };

    try measure(io, out, allocator, zerde.cbor, "cbor strict", false, commit, .{ .deterministic = true }, read_cbor);
    try measure(io, out, allocator, zerde.json, "json", false, commit, .{ .bytes = zerde.json.BytesEncoding.base64 }, read_json);
    // The same JSON with every slash written as `\/`, as some producers do: the base64 and the text are all rewritten.
    try measure(io, out, allocator, zerde.json, "json escaped", true, commit, .{ .bytes = zerde.json.BytesEncoding.base64 }, read_json);
    try measureWindows(io, out, allocator, zerde.cbor, "cbor", commit, .{ .deterministic = true });
    try measureWindows(io, out, allocator, zerde.json, "json", commit, .{ .bytes = zerde.json.BytesEncoding.base64 });
    try measureStreams(io, out, allocator, commit);
    try out.flush();
}

/// The write of the commit whole into one growing buffer, and in windows of 4, 16 and 64 KiB with `zerde.resumable`
/// into one window that is reused: the memory is the buffer against the window, the time what the windows cost.
fn measureWindows(
    io: std.Io,
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    comptime Format: type,
    name: []const u8,
    commit: Commit,
    comptime write_cfg: anytype,
) !void {
    var whole_ns: u64 = 0;
    var size: usize = 0;
    {
        var sink = try std.Io.Writer.Allocating.initCapacity(allocator, 1 << 20);
        defer sink.deinit();
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..iterations) |_| {
            sink.clearRetainingCapacity();
            try zerde.serializeWith(Format, &sink.writer, commit, .{}, write_cfg);
        }
        whole_ns = @intCast(start.untilNow(io).raw.nanoseconds);
        size = sink.written().len;
    }
    try out.print("  {s:<5} write whole   output {d:>8} B in one buffer              {d:>9.0} ns\n", .{ name, size, @as(f64, @floatFromInt(whole_ns)) / iterations });
    inline for (.{ 4096, 16384, 65536 }) |window_len| {
        const window = try allocator.alloc(u8, window_len);
        defer allocator.free(window);
        var windows: usize = 0;
        var total: usize = 0;
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..iterations) |_| {
            var resumed = zerde.resumable.Writer(Format, Commit, .{}, write_cfg).init();
            windows = 0;
            total = 0;
            while (true) {
                const filled = try resumed.fill(commit, window);
                windows += 1;
                total += filled.len;
                if (filled.done) break;
            }
        }
        const elapsed: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        std.debug.assert(total == size);
        try out.print("  {s:<5} window {d:>6} B  {d:>4} windows, state {d} B                  {d:>9.0} ns ({d:.2}x)\n", .{
            name,
            window_len,
            windows,
            @sizeOf(zerde.resumable.Writer(Format, Commit, .{}, write_cfg)),
            @as(f64, @floatFromInt(elapsed)) / iterations,
            @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(whole_ns)),
        });
    }
}

/// The decode of the deterministic CBOR of the commit whole (`wire.decode`, spans into the input) against the same in chunks of 4, 16 and
/// 64 KiB (`wire.Resumable`, every string copied into the region), and the render of it as JSON whole (the strict pull reader into the value
/// writer) against `zerde.resumable.Render` in windows of the same sizes. Each says what its memory is and what it costs against the whole.
fn measureStreams(io: std.Io, out: *std.Io.Writer, allocator: std.mem.Allocator, commit: Commit) !void {
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try zerde.serializeWith(zerde.cbor, &encoded.writer, commit, .{}, .{ .deterministic = true });
    const stored = encoded.written();

    const whole_bound = comptime wire.maxArenaSize(zerde.cbor, Commit, .{}, read_cbor);
    const block = try allocator.alignedAlloc(u8, .@"16", stored.len + whole_bound);
    defer allocator.free(block);
    @memcpy(block[0..stored.len], stored);
    var arena = std.heap.FixedBufferAllocator.init(block[stored.len..]);
    var start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        arena.reset();
        _ = try wire.decode(zerde.cbor, Commit, &arena, @intFromPtr(block.ptr), block[0..stored.len], .{}, read_cbor);
    }
    const decode_whole: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
    try out.print("  cbor  decode whole   input {d:>8} B in memory, arena {d:>8} B                           {d:>9.0} ns\n", .{ stored.len, arena.end_index, @as(f64, @floatFromInt(decode_whole)) / iterations });

    const sizes = comptime wire.resumableRegionSizes(Commit, .{}, read_cbor);
    const region = try allocator.alignedAlloc(u8, .@"16", sizes.output);
    defer allocator.free(region);
    inline for (.{ 4096, 16384, 65536 }) |chunk_len| {
        var used: usize = 0;
        var chunks: usize = 0;
        start = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..iterations) |_| {
            var decoder: wire.Resumable(Commit, .{}, read_cbor) = undefined;
            decoder.init(region, @intFromPtr(region.ptr));
            var at: usize = 0;
            chunks = 0;
            while (at < stored.len) {
                const end = @min(at + chunk_len, stored.len);
                _ = try decoder.feed(stored[at..end]);
                at = end;
                chunks += 1;
            }
            used = (try decoder.finish()).used;
        }
        const elapsed: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        try out.print("  cbor  decode chunks {d:>6} B  {d:>4} chunks, region {d:>8} B (bound {d:>8} B), state {d} B  {d:>9.0} ns ({d:.2}x)\n", .{
            chunk_len,
            chunks,
            used,
            sizes.output,
            @sizeOf(wire.Resumable(Commit, .{}, read_cbor)),
            @as(f64, @floatFromInt(elapsed)) / iterations,
            @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(decode_whole)),
        });
    }

    const stream_sizes = comptime wire.streamRegionSizes(Commit, .{}, read_cbor);
    const stream_region = try allocator.alignedAlloc(u8, .@"16", stream_sizes.output);
    defer allocator.free(stream_region);
    inline for (.{ 4096, 65536 }) |chunk_len| {
        var used: usize = 0;
        start = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..iterations) |_| {
            var decoder: wire.StreamResumable(Commit, .{}, read_cbor) = undefined;
            decoder.init(stream_region, @intFromPtr(stream_region.ptr));
            var at: usize = 0;
            while (at < stored.len) {
                const end = @min(at + chunk_len, stored.len);
                _ = try decoder.feed(stored[at..end]);
                at = end;
            }
            used = (try decoder.finish()).used;
        }
        const elapsed: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        try out.print("  cbor  stream chunks {d:>6} B  strings left in the stream, region {d:>8} B (bound {d:>8} B)      {d:>9.0} ns ({d:.2}x)\n", .{
            chunk_len,
            used,
            stream_sizes.output,
            @as(f64, @floatFromInt(elapsed)) / iterations,
            @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(decode_whole)),
        });
    }

    const json_cfg = .{ .bytes = zerde.json.BytesEncoding.base64 };
    var rendered_len: usize = 0;
    start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        var reader = try zerde.cbor.pullReader(allocator, stored, .{ .mode = zerde.cbor.Mode.strict });
        defer reader.deinit();
        var sink: std.Io.Writer.Allocating = .init(allocator);
        defer sink.deinit();
        var writer = zerde.json.valueWriter(allocator, &sink.writer, json_cfg);
        defer writer.deinit();
        while (try reader.next()) |event| try writer.writeEvent(event);
        try writer.finish();
        rendered_len = sink.written().len;
    }
    const render_whole: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
    try out.print("  json  render whole   output {d:>8} B in one buffer, pull reader into the value writer     {d:>9.0} ns\n", .{ rendered_len, @as(f64, @floatFromInt(render_whole)) / iterations });
    inline for (.{ 4096, 16384, 65536 }) |window_len| {
        const window = try allocator.alloc(u8, window_len);
        defer allocator.free(window);
        var windows: usize = 0;
        var total: usize = 0;
        start = std.Io.Clock.Timestamp.now(io, .awake);
        for (0..iterations) |_| {
            var render = zerde.resumable.Render(json_cfg).init();
            windows = 0;
            total = 0;
            while (true) {
                const filled = try render.fill(stored, window);
                windows += 1;
                total += filled.len;
                if (filled.done) break;
            }
        }
        const elapsed: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
        std.debug.assert(total == rendered_len);
        try out.print("  json  render window {d:>6} B  {d:>4} windows, state {d} B                              {d:>9.0} ns ({d:.2}x)\n", .{
            window_len,
            windows,
            @sizeOf(zerde.resumable.Render(json_cfg)),
            @as(f64, @floatFromInt(elapsed)) / iterations,
            @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(render_whole)),
        });
    }
}

fn measure(
    io: std.Io,
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    comptime Format: type,
    name: []const u8,
    escape_slashes: bool,
    commit: Commit,
    comptime write_cfg: anytype,
    comptime read_cfg: anytype,
) !void {
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try zerde.serializeWith(Format, &encoded.writer, commit, .{}, write_cfg);
    if (escape_slashes) {
        var escaped: std.Io.Writer.Allocating = .init(allocator);
        for (encoded.written()) |c| {
            if (c == '/') try escaped.writer.writeByte('\\');
            try escaped.writer.writeByte(c);
        }
        encoded.deinit();
        encoded = escaped;
    }
    const bound = comptime wire.maxArenaSize(Format, Commit, .{}, read_cfg);

    // One block holds the input and the arena, so a span is an offset from its start.
    const block = try allocator.alignedAlloc(u8, .@"16", encoded.written().len + bound);
    defer allocator.free(block);
    const input = block[0..encoded.written().len];
    @memcpy(input, encoded.written());
    var arena = std.heap.FixedBufferAllocator.init(block[input.len..]);
    const base = @intFromPtr(block.ptr);

    var used: usize = 0;
    var peak: usize = 0;
    {
        // The peak is the furthest byte a decode wrote: the arena starts as 0xaa.
        @memset(arena.buffer, 0xaa);
        _ = try wire.decode(Format, Commit, &arena, base, input, .{}, read_cfg);
        used = arena.end_index;
        peak = arena.buffer.len;
        while (peak > 0 and arena.buffer[peak - 1] == 0xaa) peak -= 1;
    }

    var keep: u32 = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        arena.reset();
        const decoded = try wire.decode(Format, Commit, &arena, base, input, .{}, read_cfg);
        keep +%= decoded.effects.len;
    }
    const elapsed: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
    std.mem.doNotOptimizeAway(keep);
    try out.print("  {s:<12} input {d:>8} B, {d:>4} effects   arena used {d:>8} B  peak {d:>8} B  bound {d:>9} B   {d:>9.0} ns a decode ({d:.0} MiB/s)\n", .{
        name,
        input.len,
        commit.effects.len,
        used,
        peak,
        bound,
        @as(f64, @floatFromInt(elapsed)) / iterations,
        (@as(f64, @floatFromInt(input.len)) / (1024 * 1024)) / (@as(f64, @floatFromInt(elapsed)) / iterations / 1e9),
    });
}
