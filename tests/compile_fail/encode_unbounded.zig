//! `encode` rebuilds its value in an arena, and a list with no `max_len` and no `max_items` in the read config has no arena size.
const std = @import("std");
const zerde = @import("zerde");

const Unbounded = struct {
    rows: []const struct { a: u8, b: u8 },
    pub const serde = .{ .deny_unknown_fields = true };
};

test "encode" {
    var bytes: [64]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&bytes);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const memory: zerde.wire.Memory = .{ .base = 0, .regions = &.{} };
    try zerde.wire.encode(zerde.json, Unbounded, &arena, memory, undefined, &out.writer, .{}, .{}, .{});
}
