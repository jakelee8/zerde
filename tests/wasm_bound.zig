//! Compiled for wasm32 by `zig build test`: `wire.maxArenaSize` for limits that overflow a 32-bit `usize` when
//! computed in it (4,096-item lists of 4 MiB strings) must compile there, with the figures in 64 bits.

const zerde = @import("zerde");
const wire = zerde.wire;
const Big = struct {
    names: []const []const u8,
    pub const serde = .{ .deny_unknown_fields = true, .fields = .{ .names = .{ .max_len = 4096 } } };
};
const cfg = .{ .max_items = 8192, .max_string_len = 4 * 1024 * 1024, .max_input_bytes = 8 * 1024 * 1024 };
const Many = struct {
    xs: []const []const u8,
    pub const serde = .{ .deny_unknown_fields = true };
};
export fn big() u32 {
    return wire.maxArenaSize(Big, .{}, cfg);
}
export fn lists4096() u32 {
    return wire.maxArenaSize(Many, .{}, .{ .max_items = 4096, .max_string_len = 4 * 1024 * 1024, .max_input_bytes = 8 * 1024 * 1024 });
}
