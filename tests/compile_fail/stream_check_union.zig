//! The text that a check could not see is found through a union payload.
const zerde = @import("zerde");

const Inner = struct {
    name: []const u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .name = .{ .max_len = 8 } } };
};
const Choice = union(enum) { a: Inner, b: u8 };

const Checked = struct {
    held: Choice,
    pub const serde = .{ .deny_unknown_fields = true };
    pub fn check(self: Checked) !void {
        _ = self;
    }
};

test "stream decoder" {
    var decoder: zerde.wire.StreamResumable(Checked, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 8, .max_items = 8 }) = undefined;
    var output: [8]u8 = undefined;
    decoder.init(&output, 0);
}
