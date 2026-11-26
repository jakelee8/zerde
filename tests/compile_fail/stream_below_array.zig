//! A checked struct that holds a text, below an array of the root: the walk reaches it.
const zerde = @import("zerde");

const Checked = struct {
    name: []const u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .name = .{ .max_len = 8 } } };
    pub fn check(self: Checked) !void {
        _ = self;
    }
};
const Choice = union(enum) { a: Checked, b: u8 };

const Root = struct {
    held: [2]Checked,
    pub const serde = .{ .deny_unknown_fields = true };
};

test "stream decoder" {
    var decoder: zerde.wire.StreamResumable(Root, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 8, .max_items = 8 }) = undefined;
    var output: [8]u8 = undefined;
    decoder.init(&output, 0);
}
