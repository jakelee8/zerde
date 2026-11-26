//! A sorted map is one container: a text below it in a checked struct is within `max_depth`, which the struct and the map fill.
const zerde = @import("zerde");

const Checked = struct {
    labels: zerde.SortedMap(zerde.ByteString),
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .labels = .{ .max_len = 2, .elem = .{ .max_len = 8 } } } };
    pub fn check(self: Checked) !void {
        _ = self;
    }
};

test "stream decoder" {
    var decoder: zerde.wire.StreamResumable(Checked, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 8, .max_items = 8, .max_depth = 2 }) = undefined;
    var output: [8]u8 = undefined;
    decoder.init(&output, 0);
}
