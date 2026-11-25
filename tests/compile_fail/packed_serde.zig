//! `rename_all` and `fields` name the members of a struct; a packed struct is one integer and has none.
const std = @import("std");
const zerde = @import("zerde");

const Renamed = packed struct(u8) {
    low: u4 = 0,
    high: u4 = 0,
    pub const serde = .{ .rename_all = .PascalCase };
};

test "typed write" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try zerde.serialize(zerde.json, &out.writer, struct { renamed: Renamed }{ .renamed = .{} });
}
