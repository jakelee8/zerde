//! The text that a check could not see is found through a list.
const zerde = @import("zerde");

const Inner = struct {
    name: []const u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .name = .{ .max_len = 8 } } };
};

const Checked = struct {
    held: []const Inner,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .held = .{ .max_len = 2 } } };
    pub fn check(self: Checked) !void {
        _ = self;
    }
};

test "stream region sizes" {
    _ = zerde.wire.streamRegionSizes(Checked, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 8, .max_items = 8 });
}
