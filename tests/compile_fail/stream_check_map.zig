//! The text that a check could not see is found through a sorted map's value.
const zerde = @import("zerde");

const Inner = struct {
    name: []const u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .name = .{ .max_len = 8 } } };
};

const Checked = struct {
    held: zerde.SortedMap(zerde.ByteString),
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .held = .{ .max_len = 2, .elem = .{ .max_len = 8 } } } };
    pub fn check(self: Checked) !void {
        _ = self;
    }
};

test "stream decoder" {
    var decoder: zerde.wire.StreamResumable(Checked, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 8, .max_items = 8 }) = undefined;
    var output: [8]u8 = undefined;
    decoder.init(&output, 0);
}
