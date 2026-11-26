//! The rules for the fields of a packed struct hold for each packed struct nested in it.
const std = @import("std");
const zerde = @import("zerde");

const Inner = packed struct(u32) { c: c_int = 0 };
const Bad = packed struct(u32) { inner: Inner };

test "typed write" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try zerde.serialize(zerde.json, &out.writer, struct { bad: Bad }{ .bad = undefined });
}
