//! A map whose keys are data, kept as a slice of entries sorted by their encoded key.
//!
//! A struct is the right type where a map's keys are known; where they are data (labels, history, limits) a `SortedMap(V)`
//! holds the entries as they come off the wire, in the order of the encoded text keys that deterministic CBOR writes (shorter
//! keys first, then bytewise), and finds one by binary search. There is no hash table and no copy of a key: in an aliased
//! read a key is a span of the input, and in a decode into `wire.Wire` the map is `{ entries: Span }` over an array of
//! `{ key: Span, value: Wire(V) }`.
//!
//! The typed layer reads and writes it as a map of text keys in CBOR and JSON. A read refuses a key that does not sort
//! after the one before it (`error.NonDeterministicEncoding` when it sorts before, `error.DuplicateField` when equal), in
//! every mode, so what it holds is sorted and has no repeat; a write refuses entries that are not (the same errors), so what it
//! puts out is in key order and a deterministic CBOR write is canonical. A field's `max_len` bounds the entries, and
//! `.elem` bounds each value. A resumable write of one is a compile error.

const std = @import("std");

pub fn SortedMap(comptime V: type) type {
    return struct {
        entries: []const Entry,

        pub const Entry = struct {
            key: []const u8,
            value: V,
            pub const serde = .{ .deny_unknown_fields = true };
            pub const zerde_sorted_entry = {};
        };
        pub const Value = V;
        pub const zerde_sorted_map = {};

        const Self = @This();

        /// The position of `key` among the entries, by binary search, or null.
        pub fn index(self: Self, key: []const u8) ?usize {
            var low: usize = 0;
            var high: usize = self.entries.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                switch (order(self.entries[middle].key, key)) {
                    .lt => low = middle + 1,
                    .gt => high = middle,
                    .eq => return middle,
                }
            }
            return null;
        }

        pub fn get(self: Self, key: []const u8) ?V {
            return if (self.index(key)) |at| self.entries[at].value else null;
        }

        pub fn getPtr(self: *const Self, key: []const u8) ?*const V {
            return if (self.index(key)) |at| &self.entries[at].value else null;
        }

        /// Whether the entries are in order with no repeat, which a read and a write guarantee and a hand-built value may not.
        pub fn isSorted(self: Self) bool {
            for (self.entries[@min(1, self.entries.len)..], 0..) |entry, before| {
                if (order(self.entries[before].key, entry.key) != .lt) return false;
            }
            return true;
        }
    };
}

/// The order of two text keys by their encoded bytes in CBOR (RFC 8949 section 4.2.1): the head states the length, so a shorter
/// key sorts first, and keys of one length sort bytewise.
pub fn order(a: []const u8, b: []const u8) std.math.Order {
    if (a.len != b.len) return std.math.order(a.len, b.len);
    return std.mem.order(u8, a, b);
}

/// Whether `T` is a `SortedMap`.
pub fn isSortedMap(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zerde_sorted_map");
}
