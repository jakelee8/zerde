//! A packed struct whose field is as wide as the target says (`usize`) is not the same integer on every target.
const std = @import("std");
const zerde = @import("zerde");

const Bad = packed struct { size: usize };

test "typed read" {
    _ = try zerde.json.parseSlice(struct { bad: Bad }, std.testing.allocator, "{\"bad\":1}");
}
