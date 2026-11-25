//! The keys of the objects a read has open, innermost last, each object's checked for a repeat when it closes.
//!
//! A key is never copied: each format's `Key` holds a slice of the deserializer's input, which outlives the read. An object
//! of no key or one key costs no sort.

const std = @import("std");

pub fn Record(comptime Key: type, comptime order: fn (Key, Key) std.math.Order) type {
    return struct {
        keys: std.ArrayList(Key) = .empty,

        const Self = @This();

        /// Where the next object's keys will start.
        pub fn mark(self: *const Self) usize {
            return self.keys.items.len;
        }

        pub fn add(self: *Self, allocator: std.mem.Allocator, key: Key) std.mem.Allocator.Error!void {
            try self.keys.append(allocator, key);
        }

        /// The object whose keys start at `first` has closed: `error.DuplicateField` when two are equal under `order`; its
        /// keys are dropped.
        pub fn close(self: *Self, first: usize) error{DuplicateField}!void {
            const names = self.keys.items[first..];
            defer self.keys.items.len = first;
            if (names.len < 2) return;
            std.sort.pdq(Key, names, {}, struct {
                fn less(_: void, a: Key, b: Key) bool {
                    return order(a, b) == .lt;
                }
            }.less);
            for (names[1..], 0..) |name, before| if (order(names[before], name) == .eq) return error.DuplicateField;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.keys.deinit(allocator);
        }
    };
}
