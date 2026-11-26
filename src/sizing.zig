//! What a reader and a decode keep in a fixed buffer, computed at comptime. One rule, used by the arena bounds of `wire` and by the
//! scratch a validator states for itself (`cbor.validateScratch`, `cbor.pullReaderScratch`, `json.pullReaderScratch`), so there is
//! no second rule that could differ.

/// The bytes a list of `n` items of `size` and `alignment` takes in a fixed buffer, worst case: an
/// array list grows from nothing through the capacities the standard library gives it, each a new
/// allocation (the buffer reuses only the last one), and is copied to its exact size at the end.
pub fn growth(n: u64, size: u64, alignment: u64) u64 {
    if (n == 0) return 0;
    const init = @max(1, 128 / size);
    var capacity: u64 = 0;
    var total: u64 = 0;
    while (capacity < n) {
        capacity = (capacity + 1) + ((capacity + 1) / 2 + init);
        total += capacity * size + alignment - 1;
    }
    return total + n * size + alignment - 1;
}
