//! A packed union in a packed struct has no checked form: the walk refuses it, and so does the wire layout.
const std = @import("std");
const zerde = @import("zerde");

const Bad = packed struct(u8) { view: packed union { a: u2, b: u2 }, _: u6 = 0 };

test "typed write" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try zerde.serialize(zerde.json, &out.writer, struct { bad: Bad }{ .bad = undefined });
}

test "wire layout" {
    _ = zerde.wire.Wire(Bad);
}
