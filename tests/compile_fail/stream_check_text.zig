//! In a stream read a text stays in the stream, and a `check` rebuilds its struct from the output region alone, so it could not see it.
const zerde = @import("zerde");

const Checked = struct {
    name: []const u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .name = .{ .max_len = 8 } } };
    pub fn check(self: Checked) !void {
        if (self.name.len == 0) return error.Empty;
    }
};

test "stream decoder" {
    var decoder: zerde.wire.StreamResumable(Checked, .{}, .{ .mode = zerde.cbor.Mode.strict, .max_string_len = 8, .max_items = 8 }) = undefined;
    var output: [8]u8 = undefined;
    decoder.init(&output, 0);
}
