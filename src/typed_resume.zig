//! The resumable half of the typed read: what a container, a string or a key does when the chunk runs out.
//!
//! The typed walk (`typed.zig`) reads into a destination, and a resumable read is the same walk with a state `rc`
//! in place of `NoRead`. Each call goes down the path of open containers again, from the root, and each level
//! of it finds in `rc` how far it got and goes on from there: a struct's fields before its cursor are done, a
//! list's items before its index, a string's bytes before its `at`. What the chunk reader takes it takes whole
//! (a head, or a piece of a string) and never takes twice, so when it says `error.NeedMore` the walk can be
//! begun again at the same place with the next chunk and nothing is read twice.
//!
//! The reader is strict CBOR (`chunk.zig`), so every container states its length and every map's keys ascend. A
//! struct is therefore read as a merge over its fields in the order of their encoded keys, whatever order they are
//! declared in: a key names a rank, the fields of lower rank that were not named are resolved at once, and a rank
//! that does not rise is a repeated or an unordered key. No flag is kept for a field. A key no field declares is
//! `error.UnknownField`, so a struct read this way must `deny_unknown_fields` and have no extras.
//!
//! Every string, byte string and `Raw` is copied into an allocation of its own, since the chunk is gone when the
//! read goes on, and nothing is freed on an error: the memory is an arena or a fixed buffer (`wire.Region`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const meta = @import("meta.zig");
const bulk = @import("bulk.zig");
const cbor = @import("cbor.zig");
const chunk = @import("chunk.zig");
const sorted = @import("sorted.zig");

const ReadLevel = typed.ReadLevel;

/// The state of a resumable read, in the size the config asks for: `frames` open containers, optionals and pointers (`resumable.zig`
/// works out how many a type needs), `key_cap` bytes for the longest name a key or an enum is compared with, and a `Raw` scan of
/// at most `depth` open containers.
pub fn State(comptime frames: usize, comptime key_cap: usize, comptime depth: usize, comptime strings_in_stream: bool) type {
    return struct {
        /// Whether a string and a byte string are left in the stream (`textInto`) and not copied.
        pub const positions = strings_in_stream;

        levels: [frames]ReadLevel = @splat(.{}),
        depth: usize = 0,
        leaf: typed.ReadLeaf = .{},
        key: [key_cap]u8 = undefined,
        scan: chunk.RawScan(depth) = undefined,

        const Self = @This();

        /// The next frame. The count `frames` is a bound for every input the depth allows, so it is indexed and not checked.
        pub fn enter(self: *Self) *ReadLevel {
            self.depth += 1;
            return &self.levels[self.depth - 1];
        }

        pub fn leave(self: *Self) void {
            self.depth -= 1;
        }
    };
}

/// Copies the rest of the string in progress that the chunk has into `leaf.buf`, `error.NeedMore` while it is not all there.
fn fill(deserializer: anytype, leaf: *typed.ReadLeaf) !void {
    while (leaf.at < leaf.len) {
        const n = deserializer.takePart(leaf.buf[leaf.at..leaf.len]);
        if (n == 0) return error.NeedMore;
        leaf.at += n;
    }
}

/// A text string (`major` 3) or a byte string (2) into `dest`. Copied, as `text` does, it is the sink's text or bytes; in positions mode
/// (`State.positions`) it is not copied: the bytes are taken from the chunks as they come, checked (text as UTF-8, a piece at a time)
/// and dropped, and `dest` is where they are in the stream (`Sink.span`), which the caller's own buffer of the stream holds.
pub fn textInto(
    s: anytype,
    comptime T: type,
    dest: *@TypeOf(s).Of(T),
    comptime major: u8,
    allocator: Allocator,
    deserializer: anytype,
    comptime bounds: meta.Bounds,
    rc: anytype,
) anyerror!void {
    if (comptime !@TypeOf(rc.*).positions) {
        const bytes = try text(major, allocator, deserializer, bounds, rc);
        dest.* = if (comptime major == 2) try s.bytesOf(T, bytes) else try s.text(T, bytes);
        return;
    }
    const leaf = &rc.leaf;
    if (!leaf.started) {
        leaf.len = try deserializer.beginString(major, bounds.max_len);
        leaf.start = deserializer.streamPosition();
        leaf.at = 0;
        leaf.started = true;
    }
    while (leaf.at < leaf.len) {
        const piece = deserializer.takeView(leaf.len - leaf.at);
        if (piece.len == 0) return error.NeedMore;
        if (major == 3 and !deserializer.trustedText() and !leaf.utf8.feed(piece)) return error.InvalidUtf8;
        leaf.at += piece.len;
    }
    const start = leaf.start;
    const len = leaf.len;
    const unfinished = major == 3 and !deserializer.trustedText() and !leaf.utf8.done();
    leaf.* = .{};
    if (unfinished) return error.InvalidUtf8;
    try typed.checkLength(bounds, len);
    dest.* = try s.span(T, start, len);
}

/// A text string (`major` 3) or a byte string (2), copied as it arrives into one allocation of exactly its length,
/// which is allocated once the head is read and its length is within `bounds` and `max_string_len`. Text is checked
/// as UTF-8 once it is whole.
pub fn text(comptime major: u8, allocator: Allocator, deserializer: anytype, comptime bounds: meta.Bounds, rc: anytype) anyerror![]const u8 {
    const leaf = &rc.leaf;
    if (!leaf.started) {
        const len = try deserializer.beginString(major, bounds.max_len);
        leaf.buf = try allocator.alloc(u8, len);
        leaf.len = len;
        leaf.at = 0;
        leaf.started = true;
    }
    try fill(deserializer, leaf);
    const bytes = leaf.buf;
    leaf.* = .{};
    if (major == 3 and !deserializer.trustedText() and !bulk.validUtf8(bytes)) return error.InvalidUtf8;
    try typed.checkLength(bounds, bytes.len);
    return bytes;
}

/// A fixed-length byte string read into the array itself.
pub fn byteArray(comptime N: usize, dest: *[N]u8, deserializer: anytype, rc: anytype) anyerror!void {
    const leaf = &rc.leaf;
    if (!leaf.started) {
        const len = try deserializer.beginString(2, std.math.maxInt(usize));
        if (len != N) return error.LengthMismatch;
        leaf.buf = dest;
        leaf.len = N;
        leaf.at = 0;
        leaf.started = true;
    }
    try fill(deserializer, leaf);
    leaf.* = .{};
}

/// The next item as the bytes it is written in: checked as it arrives for its form (`chunk.Reader.scanItem`) and,
/// once whole, for what needs the whole (the order of its keys, its text). It is held whole while it is read, so it is
/// bounded as a string is: by its `max_len` and by `max_string_len`.
pub fn raw(comptime T: type, allocator: Allocator, deserializer: anytype, comptime bounds: meta.Bounds, rc: anytype) anyerror![]const u8 {
    if (comptime T.zerde_raw_format != .cbor) @compileError("a resumable read reads CBOR, not a " ++ @tagName(T.zerde_raw_format) ++ " Raw item");
    const leaf = &rc.leaf;
    if (!leaf.started) {
        // No item is longer than what the stream may still hold, so neither is its buffer, whatever it grows through.
        rc.scan = .{ .allocator = allocator, .cap = @min(bounds.max_len, deserializer.maxStringLen(), deserializer.inputLeft()) };
        leaf.started = true;
    }
    try deserializer.scanItem(&rc.scan);
    try cbor.verifyStrict(rc.scan.buf[0..rc.scan.filled], !deserializer.trustedText());
    try typed.checkLength(bounds, rc.scan.filled);
    const bytes = try rc.scan.finish();
    leaf.* = .{};
    if (bounds.validate) |validate| try validate(allocator, bytes);
    return bytes;
}

/// A text string compared with names: read into `rc.key` when it fits `cap` and dropped when it does not, so it is
/// `.long`, which no name is. A struct's key is not checked as UTF-8 (`check_text` false): it is a name or it is refused.
fn shortText(deserializer: anytype, comptime cap: usize, comptime check_text: bool, rc: anytype) anyerror!typed.ShortText {
    const leaf = &rc.leaf;
    if (!leaf.started) {
        leaf.len = try deserializer.beginString(3, std.math.maxInt(usize));
        leaf.at = 0;
        leaf.started = true;
    }
    while (leaf.at < leaf.len) {
        var n: usize = undefined;
        if (leaf.len <= cap) {
            n = deserializer.takePart(rc.key[leaf.at..leaf.len]);
        } else {
            // No name is this long, so the text is not kept, but a text that is not UTF-8 is still refused.
            const piece = deserializer.takeView(leaf.len - leaf.at);
            if (check_text and !deserializer.trustedText() and !leaf.utf8.feed(piece)) return error.InvalidUtf8;
            n = piece.len;
        }
        if (n == 0) return error.NeedMore;
        leaf.at += n;
    }
    const len = leaf.len;
    const unfinished = !leaf.utf8.done();
    leaf.* = .{};
    if (len > cap) {
        if (check_text and !deserializer.trustedText() and unfinished) return error.InvalidUtf8;
        return .long;
    }
    const bytes = rc.key[0..len];
    if (check_text and !deserializer.trustedText() and !bulk.validUtf8(bytes)) return error.InvalidUtf8;
    return .{ .text = bytes };
}

/// A map key: text or an integer, which a union or a struct is matched by, or of another kind, which is only its major type.
const Key = union(enum) { text: []const u8, integer: i128, long, other: u8 };

/// The next key, as the whole-input reader takes a union's or a struct's.
fn shortKey(deserializer: anytype, comptime cap: usize, comptime check_text: bool, rc: anytype) anyerror!Key {
    if (!rc.leaf.started) {
        switch (try deserializer.peekKind()) {
            .string => {},
            .number => return switch (try deserializer.readNumber()) {
                .integer => |n| .{ .integer = n },
                .float => .{ .other = 7 },
            },
            .bytes => return .{ .other = 2 },
            .array => return .{ .other = 4 },
            .object => return .{ .other = 5 },
            .bool, .null => return .{ .other = 7 },
        }
    }
    return switch (try shortText(deserializer, cap, check_text, rc)) {
        .text => |bytes| .{ .text = bytes },
        .long => .long,
    };
}

/// An enum read as its name or its number.
pub fn enumValue(comptime T: type, deserializer: anytype, comptime cfg: anytype, rc: anytype) anyerror!T {
    if (!rc.leaf.started) {
        switch (try deserializer.peekKind()) {
            // An enum written as its number reads only a number.
            .string => if (comptime meta.effectiveEnumRepr(T, cfg) == .integer) return error.UnexpectedType,
            .number => {
                const raw_tag = switch (try deserializer.readNumber()) {
                    .integer => |n| n,
                    .float => return error.UnexpectedType,
                };
                const cast_tag = std.math.cast(@typeInfo(T).@"enum".tag_type, raw_tag) orelse return error.InvalidEnumTag;
                return std.enums.fromInt(T, cast_tag) orelse error.InvalidEnumTag;
            },
            else => return error.UnexpectedType,
        }
    }
    const cap = comptime typed.longestEnumName(@typeInfo(T).@"enum");
    return switch (try shortText(deserializer, cap, true, rc)) {
        .text => |bytes| std.meta.stringToEnum(T, bytes) orelse error.InvalidEnumTag,
        .long => error.InvalidEnumTag,
    };
}

/// A tagged union: a variant's name or integer key alone (a variant without payload), or a map of one entry, the key and
/// the payload. `phase` is 0 before the form is known, 1 reading the key, 2 reading the payload, 3 and 4 a bare name and a
/// bare integer.
pub fn unionValue(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Union,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*@import("diagnostic.zig").Diagnostic,
    comptime track_diagnostics: bool,
    rc: anytype,
) anyerror!void {
    const cap = comptime typed.longestVariantName(T, info, cfg);
    const integer_keys = comptime typed.unionHasIntegerKeys(T, info, cfg);
    const level = rc.enter();
    defer rc.leave();
    if (level.phase == 0) {
        switch (try deserializer.peekKind()) {
            .string => level.phase = 3,
            .number => {
                if (!integer_keys) return error.UnexpectedType;
                level.phase = 4;
            },
            .object => {
                const count = try deserializer.beginMapLen();
                if (count == 0) return error.LengthMismatch;
                level.count = count;
                level.phase = 1;
            },
            else => return error.UnexpectedType,
        }
    }
    if (level.phase == 3) {
        const name = switch (try shortText(deserializer, cap, true, rc)) {
            .text => |bytes| bytes,
            .long => return error.InvalidEnumTag,
        };
        inline for (info.field_names, info.field_types) |variant, FieldType| {
            if (FieldType == void and typed.variantHasText(T, variant, cfg, name)) {
                dest.* = try s.unionVoid(T, variant);
                level.* = .{};
                return;
            }
        }
        return error.InvalidEnumTag;
    }
    if (level.phase == 4) {
        const number = switch (try deserializer.readNumber()) {
            .integer => |n| n,
            .float => return error.UnexpectedType,
        };
        inline for (info.field_names, info.field_types) |variant, FieldType| {
            if (FieldType == void and typed.variantHasInteger(T, variant, cfg, number)) {
                dest.* = try s.unionVoid(T, variant);
                level.* = .{};
                return;
            }
        }
        return error.InvalidEnumTag;
    }
    if (level.phase == 1) {
        const key = try shortKey(deserializer, cap, true, rc);
        if (key == .other) return error.UnexpectedType;
        var matched = false;
        inline for (info.field_names, info.field_types, 0..) |name, FieldType, index| {
            const matches = switch (key) {
                .text => |bytes| typed.variantHasText(T, name, cfg, bytes),
                .integer => |number| typed.variantHasInteger(T, name, cfg, number),
                .long, .other => false,
            };
            if (FieldType != void and matches) {
                matched = true;
                level.pick = index;
                _ = s.unionDest(T, name, dest, true);
            }
        }
        if (!matched) return error.InvalidEnumTag;
        level.phase = 2;
    }
    inline for (info.field_names, info.field_types, 0..) |name, FieldType, index| {
        if (FieldType != void and level.pick == index) {
            try typed.deserializeFieldValue(s, FieldType, s.unionDest(T, name, dest, false), allocator, deserializer, cfg, diagnostics, track_diagnostics, name, meta.effectiveBounds(T, name, cfg), rc);
        }
    }
    // A union is one entry: a second one is not another variant.
    if (level.count != 1) return error.LengthMismatch;
    deserializer.endContainer();
    level.* = .{};
}

/// The position among `order` of the field `index`.
fn rankOf(comptime order: anytype, index: usize) usize {
    inline for (order, 0..) |field, rank| {
        if (field == index) return rank;
    }
    unreachable;
}

/// The error for a key no field declares: `UnknownField`, unless the key is not after the one before it (a declared field's,
/// the one at rank `cursor - 1`), which a strict read finds first, as `NonDeterministicEncoding` or `DuplicateField`.
fn unknownKey(comptime T: type, comptime info: std.builtin.Type.Struct, comptime cfg: anytype, comptime order: anytype, level: *const ReadLevel, key: Key) anyerror {
    if (level.index == 0) return error.UnknownField;
    const prior: []const u8 = blk: {
        inline for (0..order.len) |rank| {
            if (level.cursor == rank + 1) break :blk comptime cbor.encodeKey(meta.effectiveFieldKey(T, info.field_names[order[rank]], cfg));
        }
        unreachable;
    };
    var encoded: [9 + typed.longestFieldName(T, cfg)]u8 = undefined;
    const len = switch (key) {
        .text => |bytes| blk: {
            const head = cbor.writeHead(&encoded, 3, bytes.len);
            @memcpy(encoded[head..][0..bytes.len], bytes);
            break :blk head + bytes.len;
        },
        .integer => |number| if (number >= 0) cbor.writeHead(&encoded, 0, @intCast(number)) else cbor.writeHead(&encoded, 1, @intCast(-1 - number)),
        // A text longer than every name sorts after the key before it.
        .long => return error.UnknownField,
        // A key of another kind is after the one before it when its major type is: they are never the same.
        .other => |major| return if (major > prior[0] >> 5) error.UnknownField else error.NonDeterministicEncoding,
    };
    return switch (std.mem.order(u8, prior, encoded[0..len])) {
        .lt => error.UnknownField,
        // A key equal to the one before it would have matched its field.
        .eq, .gt => error.NonDeterministicEncoding,
    };
}

/// A struct, as a merge over its fields in the order of their encoded keys (see the file's comment). `phase` is 0 before the
/// head, 1 where a key is due and 2 in a field's value; `index` counts the entries done, `cursor` the ranks resolved and
/// `pick` the rank of the key just read.
pub fn structValue(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*@import("diagnostic.zig").Diagnostic,
    comptime track_diagnostics: bool,
    rc: anytype,
) anyerror!void {
    if (comptime meta.extrasField(T) != null) @compileError("a resumable read cannot collect extras: " ++ @typeName(T));
    if (comptime !meta.effectiveDenyUnknownFields(T, cfg)) @compileError("a resumable read refuses a key no field declares, so the struct must deny_unknown_fields: " ++ @typeName(T));
    const fields = info.field_names.len;
    const order = comptime typed.structFieldOrder(T, cbor, info, cfg, .{ .default = .encoded_key, .required = true });
    const cap = comptime typed.longestFieldName(T, cfg);
    const level = rc.enter();
    defer rc.leave();
    if (level.phase == 0) {
        level.count = try deserializer.beginMapLen();
        level.phase = 1;
    }
    while (level.index < level.count) {
        if (level.phase == 1) {
            const rank: usize = blk: {
                const key = try shortKey(deserializer, cap, false, rc);
                switch (key) {
                    .text => |bytes| if (typed.matchStructFieldIndex(T, cfg, bytes)) |field| break :blk rankOf(order, field),
                    .integer => |number| if (typed.matchStructFieldIndexInteger(T, cfg, number)) |field| break :blk rankOf(order, field),
                    .long, .other => {},
                }
                return unknownKey(T, info, cfg, order, level, key);
            };
            // The keys ascend, so the ranks do: one that does not is a key repeated, or one out of order.
            if (level.index > 0 and rank < level.cursor) return if (rank + 1 == level.cursor) error.DuplicateField else error.NonDeterministicEncoding;
            // A key names a field, so every field before it that was not named is absent.
            inline for (0..fields) |lower| {
                if (lower < rank and lower >= level.cursor) {
                    typed.fillField(s, T, info, cfg, allocator, dest, order[lower]) catch |err| switch (err) {
                        // Said at the end, after every key, as the whole read says it: a key out of order is found first.
                        error.MissingField => level.missing = true,
                        else => return err,
                    };
                    level.cursor = lower + 1;
                }
            }
            level.pick = rank;
            level.phase = 2;
        }
        inline for (0..fields) |rank| {
            if (level.pick == rank) {
                const field = order[rank];
                try typed.deserializeStructField(s, T, info.field_names[field], info.field_types[field], &@field(dest.*, info.field_names[field]), allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
            }
        }
        level.cursor = level.pick + 1;
        level.index += 1;
        level.phase = 1;
    }
    inline for (0..fields) |rank| {
        if (rank >= level.cursor) {
            typed.fillField(s, T, info, cfg, allocator, dest, order[rank]) catch |err| switch (err) {
                error.MissingField => level.missing = true,
                else => return err,
            };
            level.cursor = rank + 1;
        }
    }
    if (level.missing) return error.MissingField;
    try s.check(T, allocator, dest);
    deserializer.endContainer();
    level.* = .{};
}

/// A slice of items: its head gives the length, which is bounded before the one allocation that holds the items, and the
/// items are read in place, one after another, from the first the chunk had not finished.
pub fn list(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Pointer,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*@import("diagnostic.zig").Diagnostic,
    comptime track_diagnostics: bool,
    comptime bounds: meta.Bounds,
    rc: anytype,
) anyerror!void {
    const Item = @TypeOf(s).Of(info.child);
    const level = rc.enter();
    defer rc.leave();
    if (level.phase == 0) {
        const len = try deserializer.beginArrayLen();
        try typed.checkLength(bounds, len);
        const items = try allocator.alloc(Item, len);
        level.items = @ptrCast(items.ptr);
        level.count = len;
        level.phase = 1;
    }
    const items = @as([*]Item, @ptrCast(@alignCast(level.items.?)))[0..level.count];
    while (level.index < level.count) {
        try typed.deserializeElement(s, info.child, &items[level.index], allocator, deserializer, cfg, diagnostics, track_diagnostics, level.index, bounds, rc);
        level.index += 1;
    }
    deserializer.endContainer();
    dest.* = try s.list(T, items);
    level.* = .{};
}

/// A fixed-length array of items, read in place.
pub fn array(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Array,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*@import("diagnostic.zig").Diagnostic,
    comptime track_diagnostics: bool,
    rc: anytype,
) anyerror!void {
    if (info.child == u8) return byteArray(info.len, dest, deserializer, rc);
    const level = rc.enter();
    defer rc.leave();
    if (level.phase == 0) {
        if (try deserializer.beginArrayLen() != info.len) return error.LengthMismatch;
        level.phase = 1;
    }
    while (level.index < info.len) {
        try typed.deserializeIndexedValue(s, info.child, &dest[level.index], allocator, deserializer, cfg, diagnostics, track_diagnostics, level.index, rc);
        level.index += 1;
    }
    deserializer.endContainer();
    level.* = .{};
}

/// A pointer to one value: the value is allocated at the head and read into.
pub fn one(
    s: anytype,
    comptime T: type,
    comptime info: std.builtin.Type.Pointer,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*@import("diagnostic.zig").Diagnostic,
    comptime track_diagnostics: bool,
    rc: anytype,
) anyerror!void {
    const level = rc.enter();
    defer rc.leave();
    if (level.phase == 0) {
        dest.* = try allocator.create(@TypeOf(s).Of(info.child));
        level.phase = 1;
    }
    try typed.deserializeValue(s, info.child, @constCast(dest.*), allocator, deserializer, cfg, diagnostics, track_diagnostics, rc);
    level.* = .{};
}

/// A `SortedMap`: its head gives the entries, bounded before the one allocation that holds them, and each key is copied
/// as it arrives and compared with the one before it, which is `level.prev`. `phase` is 1 where a key is due, 2 in a value.
pub fn sortedMap(
    s: anytype,
    comptime T: type,
    dest: *@TypeOf(s).Of(T),
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
    diagnostics: ?*@import("diagnostic.zig").Diagnostic,
    comptime track_diagnostics: bool,
    comptime bounds: meta.Bounds,
    rc: anytype,
) anyerror!void {
    const Item = @TypeOf(s).Of(T.Entry);
    const level = rc.enter();
    defer rc.leave();
    if (level.phase == 0) {
        const count = try deserializer.beginMapLen();
        try typed.checkLength(bounds, count);
        const entries = try allocator.alloc(Item, count);
        level.items = @ptrCast(entries.ptr);
        level.count = count;
        level.phase = 1;
    }
    const entries = @as([*]Item, @ptrCast(@alignCast(level.items.?)))[0..level.count];
    while (level.index < level.count) {
        if (level.phase == 1) {
            const key = try text(3, allocator, deserializer, .{}, rc);
            if (level.index > 0) switch (sorted.order(level.prev, key)) {
                .lt => {},
                .eq => return error.DuplicateField,
                .gt => return error.NonDeterministicEncoding,
            };
            level.prev = key;
            entries[level.index].key = try s.text([]const u8, key);
            level.phase = 2;
        }
        try typed.deserializeElement(s, T.Value, &entries[level.index].value, allocator, deserializer, cfg, diagnostics, track_diagnostics, level.index, bounds, rc);
        level.index += 1;
        level.phase = 1;
    }
    deserializer.endContainer();
    dest.* = .{ .entries = try s.list([]const T.Entry, entries) };
    level.* = .{};
}
