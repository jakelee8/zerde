//! `encodeArenaSize` has the same rule: a list with no `max_len` and no `max_items` in the read config has no size.
const zerde = @import("zerde");

const Unbounded = struct {
    rows: []const struct { a: u8, b: u8 },
    pub const serde = .{ .deny_unknown_fields = true };
};

test "encodeArenaSize" {
    _ = zerde.wire.encodeArenaSize(zerde.json, Unbounded, .{}, .{});
}
