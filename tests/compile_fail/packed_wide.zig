//! A wire integer is at most 64 bits.
const zerde = @import("zerde");

const Wide = packed struct(u128) { low: u64 = 0, high: u64 = 0 };

test "wire layout" {
    _ = zerde.wire.Wire(Wide);
}
