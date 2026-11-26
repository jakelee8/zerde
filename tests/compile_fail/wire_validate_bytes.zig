//! A validator under a wire read takes its memory from a region that the size functions reserve, and no function can derive what a
//! function pointer allocates: the field states it, with `validate_bytes` (0 for a validator that allocates nothing).
const std = @import("std");
const zerde = @import("zerde");

fn accept(_: std.mem.Allocator, _: []const u8) anyerror!void {}

const Checked = struct {
    item: zerde.cbor.Raw,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .item = .{ .max_len = 16, .validate = accept } } };
};

test "wire decodeInto" {
    var output: [64]u8 = undefined;
    var scratch: [64]u8 = undefined;
    _ = try zerde.wire.decodeInto(zerde.cbor, Checked, &output, &scratch, 0, "", .{}, .{ .mode = zerde.cbor.Mode.strict });
}
