//! An enum whose tag is as wide as the target says is as target-dependent as a `usize` field.
const std = @import("std");
const zerde = @import("zerde");

const Wide = enum(usize) { a, b };
const Bad = packed struct { w: Wide };

test "typed read" {
    _ = try zerde.json.parseSlice(struct { bad: Bad }, std.testing.allocator, "{\"bad\":1}");
}
