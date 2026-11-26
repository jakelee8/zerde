//! The size function of a stream read raises the same error, for a caller that sizes its own regions.
const zerde = @import("zerde");

const Checked = struct {
    name: []const u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .name = .{ .max_len = 8 } } };
    pub fn check(self: Checked) !void {
        if (self.name.len == 0) return error.Empty;
    }
};

test "stream region sizes" {
    _ = zerde.wire.streamRegionSizes(Checked, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 8, .max_items = 8 });
}
