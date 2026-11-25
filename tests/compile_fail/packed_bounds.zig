//! A bound does not apply to a packed struct, which is one integer.
const std = @import("std");
const zerde = @import("zerde");

const Flags = packed struct(u8) { low: u4 = 0, high: u4 = 0 };
const Bounded = struct {
    flags: Flags,
    pub const serde = .{ .fields = .{ .flags = .{ .max = 9 } } };
};

test "typed read" {
    _ = try zerde.json.parseSlice(Bounded, std.testing.allocator, "{\"flags\":1}");
}
