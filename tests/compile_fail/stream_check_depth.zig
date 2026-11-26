//! A sorted map is one container: the checked struct that is its value is one level below it, and `max_depth` reaches it.
const zerde = @import("zerde");

const Inner = struct {
    name: []const u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .name = .{ .max_len = 8 } } };
    pub fn check(self: Inner) !void {
        _ = self;
    }
};

const Root = struct {
    labels: zerde.SortedMap(Inner),
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .labels = .{ .max_len = 2 } } };
};

test "stream decoder" {
    // The root is the first level, the map the second and the checked struct the third.
    var decoder: zerde.wire.StreamResumable(Root, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 8, .max_items = 8, .max_depth = 3 }) = undefined;
    var output: [8]u8 = undefined;
    decoder.init(&output, 0);
}
