//! Fixed-layout wire types, generated from a schema type: the decoded form of a message laid out
//! the way C lays out a struct, so that code outside Zig (TypeScript over WebAssembly linear memory,
//! say) can read it by offsets with no walk and no parser.
//!
//! `Wire(T)` is the layout of schema type `T`, the same struct, enum, union and optional types the
//! typed layer reads and writes, with every serde rule (renames, integer keys, bounds, optional
//! policies, validators) applied by the typed layer as it always is: a message is read into `T`
//! first, then copied into `Wire(T)`, so this module has no second set of rules.
//!
//!   - an integer, a float and a bool are themselves; an enum is its integer tag type;
//!   - text, a `ByteString`, a `Raw` and a slice are a `Span`: `extern struct { offset: u32, len: u32 }`,
//!     pointing at the bytes (`len` counts bytes), or at the contiguous `Wire(element)` array the
//!     decode wrote (`len` counts elements);
//!   - `?T` is `Opt(Wire(T))`: a presence byte, then the value (zero when absent);
//!   - a struct is an `extern struct` of its members, in declaration order;
//!   - a tagged union is `extern struct { tag: u8, payload: extern union { ... } }`: the tag is the
//!     variant's index in declaration order, and a variant without payload has no member in the union;
//!   - `[N]T` is `[N]Wire(T)`, and `[N]u8` is `[N]u8`.
//!
//! A span's offset is relative to a base address the caller names: 0 on wasm32, where an offset is
//! then a linear-memory address, or a real address on a native target. An offset or an end that does
//! not fit `u32` is `error.OffsetOutOfRange`; it is never truncated.
//!
//! Where the bytes are. A plain text or byte string is not copied: its span points into the input
//! (an aliased read), which must stay in place for as long as the wire value is read. A JSON string
//! with an escape, a chunked CBOR string and every array are written into the arena, so a span
//! points into the input or the arena, and both must lie in memory that `base` reaches.
//!
//! The arena is a caller-provided fixed buffer (`std.heap.FixedBufferAllocator`): a decode takes
//! one, restores it on an error, and never frees what it allocated, so it must not be a general
//! allocator. `maxArenaSize` computes at comptime how large the buffer must be, and is a compile
//! error when a field a decode reaches has no bound. The decode reads into the typed value first,
//! then copies it into the wire layout; the copy is skipped for a list of scalars, whose typed
//! array already has the wire layout, and for strings. What is still copied is every list of
//! structs, unions, optionals, enums and arrays: once as the typed array, once as the wire array.
//!
//! A wire value that came from outside is not trusted: `fromWire` and `encode` take a `Memory`,
//! the ranges a span may point into, and refuse a span outside them or misaligned for what it holds.
//!
//! `describe` gives the offset of every member, for a generator of accessors in another language.

const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = @import("meta.zig");
const reflect = @import("reflect.zig");
const typed = @import("typed.zig");
const root = @import("root.zig");

pub const Error = error{
    /// A span's offset or end does not fit `u32`, or lies before the base address.
    OffsetOutOfRange,
    /// A union tag or an enum value in a wire value names no variant or value.
    InvalidTag,
};

/// A byte range, relative to a base address.
pub const Span = extern struct {
    offset: u32,
    len: u32,
};

/// An optional value: a presence byte (0 or 1), then the value, zeroed when absent.
pub fn Opt(comptime V: type) type {
    return extern struct {
        present: u8,
        value: V,
    };
}

/// The fixed-layout type of schema type `T`.
pub fn Wire(comptime T: type) type {
    return switch (comptime reflect.kindOf(T)) {
        .bool => bool,
        .int => blk: {
            // A layout that is the same on every target has no usize, no C type, and no width that
            // an extern struct refuses.
            const bits = @typeInfo(T).int.bits;
            const target_sized = T == usize or T == isize or T == c_short or T == c_ushort or T == c_int or T == c_uint or
                T == c_long or T == c_ulong or T == c_longlong or T == c_ulonglong or T == c_char;
            if (target_sized or (bits != 8 and bits != 16 and bits != 32 and bits != 64)) {
                @compileError("a wire integer is u8, u16, u32, u64 or the signed kind, never usize or a C type: " ++ @typeName(T));
            }
            break :blk T;
        },
        .float => blk: {
            if (@typeInfo(T).float.bits != 32 and @typeInfo(T).float.bits != 64) @compileError("a wire float is f32 or f64: " ++ @typeName(T));
            break :blk T;
        },
        .text, .byte_string, .raw, .list => Span,
        .byte_array => T,
        .array => [@typeInfo(T).array.len]Wire(@typeInfo(T).array.child),
        .optional => blk: {
            if (@typeInfo(@typeInfo(T).optional.child) == .optional) @compileError("a nested optional has no wire form: " ++ @typeName(T));
            break :blk Opt(Wire(@typeInfo(T).optional.child));
        },
        .pointer => Wire(@typeInfo(T).pointer.child),
        .@"enum" => EnumInt(T),
        .@"struct" => StructWire(T),
        .@"union" => UnionWire(T),
        .hook, .none => @compileError(@typeName(T) ++ " has no wire layout"),
    };
}

/// The integer an enum is on the wire: the smallest of 8, 16, 32 and 64 bits, signed when a value is
/// negative, that holds every value. (An enum's own tag type can be `u2`, which an extern struct refuses.)
fn EnumInt(comptime T: type) type {
    comptime {
        var low: i128 = 0;
        var high: i128 = 0;
        for (@typeInfo(T).@"enum".field_values) |value| {
            low = @min(low, value);
            high = @max(high, value);
        }
        const signed = low < 0;
        for ([_]u16{ 8, 16, 32, 64 }) |bits| {
            const Candidate = @Int(if (signed) .signed else .unsigned, bits);
            if (low >= std.math.minInt(Candidate) and high <= std.math.maxInt(Candidate)) return Candidate;
        }
        @compileError("an enum value does not fit 64 bits: " ++ @typeName(T));
    }
}

fn StructWire(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    if (info.is_tuple) @compileError("a tuple has no wire layout: " ++ @typeName(T));
    comptime var names: [info.field_names.len][]const u8 = undefined;
    comptime var types: [info.field_names.len]type = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, FieldType, index| {
        names[index] = name;
        types[index] = Wire(FieldType);
    }
    return @Struct(.@"extern", null, &names, &types, &@splat(.{}));
}

fn UnionWire(comptime T: type) type {
    const info = @typeInfo(T).@"union";
    if (info.tag_type == null) @compileError("a union needs a tag to have a wire layout: " ++ @typeName(T));
    if (info.field_names.len > 256) @compileError("a wire union has at most 256 variants: " ++ @typeName(T));
    comptime var names: [info.field_names.len][]const u8 = undefined;
    comptime var types: [info.field_names.len]type = undefined;
    comptime var count = 0;
    inline for (info.field_names, info.field_types) |name, PayloadType| {
        if (PayloadType == void) continue;
        names[count] = name;
        types[count] = Wire(PayloadType);
        count += 1;
    }
    const Payload = if (count == 0)
        extern union { unused: u8 }
    else
        @Union(.@"extern", null, names[0..count], types[0..count], &@splat(.{}));
    return extern struct {
        tag: u8,
        payload: Payload,
    };
}

/// The index of the variant named `name` in `T`, which is its tag on the wire.
fn variantIndex(comptime T: type, comptime name: []const u8) u8 {
    inline for (@typeInfo(T).@"union".field_names, 0..) |variant, index| {
        if (comptime std.mem.eql(u8, variant, name)) return index;
    }
    unreachable;
}

/// The span of `bytes`, as an offset from `base`.
pub fn spanOf(base: usize, bytes: []const u8) Error!Span {
    if (bytes.len == 0) return .{ .offset = 0, .len = 0 };
    const address = @intFromPtr(bytes.ptr);
    if (address < base) return error.OffsetOutOfRange;
    const offset = address - base;
    const end = std.math.add(usize, offset, bytes.len) catch return error.OffsetOutOfRange;
    if (end > std.math.maxInt(u32)) return error.OffsetOutOfRange;
    return .{ .offset = @intCast(offset), .len = @intCast(bytes.len) };
}

/// The ranges of memory a span may point into, and what its offsets are relative to.
pub const Memory = struct {
    base: usize,
    /// Typically the input and the arena. A span outside all of them is refused.
    regions: []const []const u8,

    /// The `len` items of `size` bytes and `alignment` that `span` names, or `error.OffsetOutOfRange`
    /// when any of it lies outside the regions, the address is misaligned, or a sum overflows.
    pub fn resolve(self: Memory, span: Span, size: usize, alignment: usize) Error![]const u8 {
        if (span.len == 0) return &.{};
        const start = std.math.add(usize, self.base, span.offset) catch return error.OffsetOutOfRange;
        const length = std.math.mul(usize, span.len, size) catch return error.OffsetOutOfRange;
        const end = std.math.add(usize, start, length) catch return error.OffsetOutOfRange;
        if (start % alignment != 0) return error.OffsetOutOfRange;
        for (self.regions) |region| {
            const low = @intFromPtr(region.ptr);
            if (start >= low and end <= low + region.len) {
                const pointer: [*]const u8 = @ptrFromInt(start);
                return pointer[0..length];
            }
        }
        return error.OffsetOutOfRange;
    }

    /// The bytes a span of bytes names.
    pub fn bytesOf(self: Memory, span: Span) Error![]const u8 {
        return self.resolve(span, 1, 1);
    }

    /// The elements a span of a list names.
    pub fn listOf(self: Memory, comptime Elem: type, span: Span) Error![]const Elem {
        const bytes = try self.resolve(span, @sizeOf(Elem), @alignOf(Elem));
        if (bytes.len == 0) return &.{};
        const pointer: [*]const Elem = @ptrCast(@alignCast(bytes.ptr));
        return pointer[0..span.len];
    }
};

/// Whether a list of `Elem` is its own wire layout: integers, floats, bools and byte arrays.
fn isScalarList(comptime Elem: type) bool {
    return switch (reflect.kindOf(Elem)) {
        .bool, .int, .float, .byte_array => true,
        else => false,
    };
}

/// Copies a typed value into its wire layout. Arrays are written into `allocator`, contiguously,
/// and spans point at them; text and byte strings are spans of the memory `value` already has.
pub fn toWire(comptime T: type, allocator: Allocator, base: usize, value: T) (Allocator.Error || Error)!Wire(T) {
    return switch (comptime reflect.kindOf(T)) {
        .bool, .int, .float, .byte_array => value,
        .text => try spanOf(base, value),
        .byte_string, .raw => try spanOf(base, value.bytes),
        .list => blk: {
            const Elem = @typeInfo(T).pointer.child;
            // The typed array of a scalar already has the wire layout: point at it.
            if (comptime isScalarList(Elem)) {
                const bytes = try spanOf(base, std.mem.sliceAsBytes(value));
                break :blk .{ .offset = bytes.offset, .len = @intCast(value.len) };
            }
            const items = try allocator.alloc(Wire(Elem), value.len);
            for (value, items) |item, *slot| slot.* = try toWire(Elem, allocator, base, item);
            // The span of a list counts elements, not bytes.
            const bytes = try spanOf(base, std.mem.sliceAsBytes(items));
            break :blk .{ .offset = bytes.offset, .len = @intCast(value.len) };
        },
        .array => blk: {
            var out: Wire(T) = undefined;
            for (value, &out) |item, *slot| slot.* = try toWire(@typeInfo(T).array.child, allocator, base, item);
            break :blk out;
        },
        .optional => blk: {
            const Child = @typeInfo(T).optional.child;
            var out: Wire(T) = std.mem.zeroes(Wire(T));
            if (value) |present| {
                out.present = 1;
                out.value = try toWire(Child, allocator, base, present);
            }
            break :blk out;
        },
        .pointer => try toWire(@typeInfo(T).pointer.child, allocator, base, value.*),
        .@"enum" => @intCast(@backingInt(value)),
        .@"struct" => blk: {
            var out: Wire(T) = undefined;
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, FieldType| {
                @field(out, name) = try toWire(FieldType, allocator, base, @field(value, name));
            }
            break :blk out;
        },
        .@"union" => blk: {
            var out: Wire(T) = std.mem.zeroes(Wire(T));
            switch (value) {
                inline else => |payload, tag| {
                    out.tag = variantIndex(T, @tagName(tag));
                    if (@TypeOf(payload) != void) {
                        @field(out.payload, @tagName(tag)) = try toWire(@TypeOf(payload), allocator, base, payload);
                    }
                },
            }
            break :blk out;
        },
        .hook, .none => unreachable,
    };
}

/// The typed value of a wire value, the inverse of `toWire`. Arrays are allocated in `allocator`;
/// text, byte strings, raw items and the elements of a scalar list point at the memory the spans
/// name. Every span is checked against `memory` (`error.OffsetOutOfRange`), and an enum value, a
/// union tag or a presence byte that means nothing is `error.InvalidTag`.
pub fn fromWire(comptime T: type, allocator: Allocator, memory: Memory, wire: Wire(T)) (Allocator.Error || Error)!T {
    return switch (comptime reflect.kindOf(T)) {
        .bool, .int, .float, .byte_array => wire,
        .text => try memory.bytesOf(wire),
        .byte_string => .{ .bytes = try memory.bytesOf(wire) },
        .raw => .{ .bytes = try memory.bytesOf(wire) },
        .list => blk: {
            const Elem = @typeInfo(T).pointer.child;
            const source = try memory.listOf(Wire(Elem), wire);
            if (comptime isScalarList(Elem)) break :blk source;
            const items = try allocator.alloc(Elem, source.len);
            for (source, items) |item, *slot| slot.* = try fromWire(Elem, allocator, memory, item);
            break :blk items;
        },
        .array => blk: {
            var out: T = undefined;
            for (wire, &out) |item, *slot| slot.* = try fromWire(@typeInfo(T).array.child, allocator, memory, item);
            break :blk out;
        },
        .optional => blk: {
            const Child = @typeInfo(T).optional.child;
            break :blk switch (wire.present) {
                0 => null,
                1 => try fromWire(Child, allocator, memory, wire.value),
                else => error.InvalidTag,
            };
        },
        .pointer => blk: {
            const pointer = try allocator.create(@typeInfo(T).pointer.child);
            pointer.* = try fromWire(@typeInfo(T).pointer.child, allocator, memory, wire);
            break :blk pointer;
        },
        .@"enum" => blk: {
            const tag = std.math.cast(@typeInfo(T).@"enum".tag_type, wire) orelse break :blk error.InvalidTag;
            break :blk std.enums.fromInt(T, tag) orelse error.InvalidTag;
        },
        .@"struct" => blk: {
            var out: T = undefined;
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, FieldType| {
                @field(out, name) = try fromWire(FieldType, allocator, memory, @field(wire, name));
            }
            break :blk out;
        },
        .@"union" => blk: {
            inline for (@typeInfo(T).@"union".field_names, @typeInfo(T).@"union".field_types, 0..) |name, PayloadType, index| {
                if (wire.tag == index) {
                    if (PayloadType == void) break :blk @unionInit(T, name, {});
                    break :blk @unionInit(T, name, try fromWire(PayloadType, allocator, memory, @field(wire.payload, name)));
                }
            }
            break :blk error.InvalidTag;
        },
        .hook, .none => unreachable,
    };
}

/// Reads one `T` from `input` in `Format` (`zerde.cbor` or `zerde.json`) and returns its wire
/// layout. The read is aliased and applies every rule of `T` and of `format_cfg` (strict mode,
/// limits, bounds, validators, keys, optional policies) as a typed read does. `arena` is a fixed
/// buffer of at least `maxArenaSize(T, serde_cfg, format_cfg)` bytes; on an error it is put back as
/// it was. `base` is the address spans are relative to. The wire value points into `input` and
/// `arena`, which must stay where they are.
pub fn decode(
    comptime Format: type,
    comptime T: type,
    arena: *std.heap.FixedBufferAllocator,
    base: usize,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !Wire(T) {
    const mark = arena.end_index;
    errdefer arena.end_index = mark;
    const allocator = arena.allocator();
    var deserializer = try Format.sliceDeserializer(allocator, input, format_cfg);
    defer deserializer.deinit(allocator);
    deserializer.can_borrow_strings = true;
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return try toWire(T, allocator, base, value);
}

/// Writes a wire value in `Format`, as the typed value it came from would be written: the same
/// field order, keys, optional policy and determinism. The typed value is rebuilt in `arena`
/// first (the arrays of structs, unions, optionals, enums and arrays; text and scalar lists point at
/// the memory the spans name), because the writers stream and keep no memory of their own. Every
/// span is checked against `memory`; `arena` is put back as it was when the write is done.
pub fn encode(
    comptime Format: type,
    comptime T: type,
    arena: *std.heap.FixedBufferAllocator,
    memory: Memory,
    wire: Wire(T),
    writer: *std.Io.Writer,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    const mark = arena.end_index;
    defer arena.end_index = mark;
    const value = try fromWire(T, arena.allocator(), memory, wire);
    try root.serializeWith(Format, writer, value, serde_cfg, format_cfg);
}

/// A wire value as a typed-layer field: reads a `T` through the decode hook, so a message that holds
/// fixed-layout parts can be read by `typed.deserialize` as a whole. Like `decode` it needs the
/// deserializer's allocator to be a fixed buffer: nothing is freed. The hook takes the base from
/// `reader.userData()`, the word a caller sets on a deserializer it builds itself
/// (`d.user_data = base`; 0 by default, which is right on wasm32).
pub fn Hooked(comptime T: type) type {
    return HookedWith(T, .{});
}

/// `Hooked` that reads `T` with `serde_cfg`, as a call site's config for it.
pub fn HookedWith(comptime T: type, comptime serde_cfg: anytype) type {
    return struct {
        value: Wire(T),

        pub fn zerdeDecode(allocator: Allocator, reader: anytype) anyerror!@This() {
            const value = try reader.readTyped(T, allocator, serde_cfg);
            return .{ .value = try toWire(T, allocator, reader.userData(), value) };
        }
    };
}

/// Where a member is in its parent and what it holds.
pub const Member = struct {
    /// The Zig field or variant name.
    name: []const u8,
    /// The wire key the typed layer reads and writes it under.
    wire: meta.FieldKey,
    /// Bytes from the start of the parent struct (or union payload, which starts at 0).
    offset: usize,
    node: Node,
};

/// The layout of one wire type.
pub const Node = struct {
    kind: reflect.Kind,
    size: usize,
    alignment: usize,
    /// The members of a struct, or the variants of a union (in tag order; offsets are into the
    /// payload, and a variant without payload has size 0).
    members: []const Member = &.{},
    /// The element of a list (what its span points at), an array or an optional.
    element: ?*const Node = null,
    /// A list or array's element count (an array only).
    len: usize = 0,
    /// An optional's value offset; its presence byte is at 0. A union's payload offset; its tag is at 0.
    value_offset: usize = 0,
};

/// The layout of `Wire(T)`, with the offset of every member, for a generator of accessors.
pub fn describe(comptime T: type, comptime cfg: anytype) Node {
    @setEvalBranchQuota(200_000);
    const W = Wire(T);
    const kind = comptime reflect.kindOf(T);
    switch (kind) {
        .list => {
            const element = comptime describe(@typeInfo(T).pointer.child, cfg);
            return .{ .kind = kind, .size = @sizeOf(W), .alignment = @alignOf(W), .element = &element };
        },
        .array => {
            const element = comptime describe(@typeInfo(T).array.child, cfg);
            return .{ .kind = kind, .size = @sizeOf(W), .alignment = @alignOf(W), .element = &element, .len = @typeInfo(T).array.len };
        },
        .optional => {
            const element = comptime describe(@typeInfo(T).optional.child, cfg);
            return .{ .kind = kind, .size = @sizeOf(W), .alignment = @alignOf(W), .element = &element, .value_offset = @offsetOf(W, "value") };
        },
        .pointer => return describe(@typeInfo(T).pointer.child, cfg),
        .@"struct" => {
            const info = reflect.fields(T, cfg);
            comptime var members: [info.len]Member = undefined;
            inline for (info, 0..) |field, index| {
                members[index] = .{ .name = field.name, .wire = field.wire, .offset = @offsetOf(W, field.name), .node = describe(field.type, cfg) };
            }
            const final = members;
            return .{ .kind = kind, .size = @sizeOf(W), .alignment = @alignOf(W), .members = &final };
        },
        .@"union" => {
            const info = reflect.variants(T, cfg);
            comptime var members: [info.len]Member = undefined;
            inline for (info, 0..) |variant, index| {
                members[index] = .{
                    .name = variant.name,
                    .wire = variant.wire,
                    .offset = 0,
                    .node = if (variant.type == void) .{ .kind = .none, .size = 0, .alignment = 1 } else describe(variant.type, cfg),
                };
            }
            const final = members;
            return .{ .kind = kind, .size = @sizeOf(W), .alignment = @alignOf(W), .members = &final, .value_offset = @offsetOf(W, "payload") };
        },
        else => return .{ .kind = kind, .size = @sizeOf(W), .alignment = @alignOf(W) },
    }
}

// ---- the arena a decode needs -----------------------------------------------------------------------------------

const Limits = struct {
    max_items: usize,
    max_string_len: usize,
};

fn limitsOf(comptime format_cfg: anytype) Limits {
    return .{
        .max_items = if (meta.hasField(@TypeOf(format_cfg), "max_items")) @field(format_cfg, "max_items") else std.math.maxInt(usize),
        .max_string_len = if (meta.hasField(@TypeOf(format_cfg), "max_string_len")) @field(format_cfg, "max_string_len") else std.math.maxInt(usize),
    };
}

/// The bytes a list of `n` items of `size` and `alignment` can take while it grows (an array list
/// grows by half again, so what it left behind is under twice what it holds) and is shrunk to fit.
fn growth(n: usize, size: usize, alignment: usize) usize {
    return (3 * n + 64) * size + 40 * alignment;
}

fn bound(comptime name: []const u8, comptime limit: usize, comptime what: []const u8) usize {
    if (limit == std.math.maxInt(usize)) @compileError(what ++ " has no bound a decode can rely on: " ++ name);
    return limit;
}

/// An upper bound, in bytes, of what the arena of `decode(Format, T, ...)` allocates for the
/// typed value and its wire copy, plus what the reader keeps while it checks a `Raw` item. It is
/// computed from the bounds of `T`: `max_len` and `.elem` of every field, and `max_items` and
/// `max_string_len` of `format_cfg` where a field has none. It is a compile error when something a
/// decode reaches has no bound, when a struct accepts unknown members (they would cost without
/// limit: set `deny_unknown_fields`), or when it collects extras. The bound is not tight: it takes
/// the worst case of every list and string at once. Strings that are not escaped or chunked cost
/// nothing, and a list of scalars costs only its typed array.
pub fn maxArenaSize(comptime T: type, comptime serde_cfg: anytype, comptime format_cfg: anytype) usize {
    @setEvalBranchQuota(1_000_000);
    const limits = comptime limitsOf(format_cfg);
    const slack = 256;
    return comptime typedOwned(T, .{}, serde_cfg, limits) + wireOwned(T, .{}, serde_cfg, limits) + slack;
}

/// What the typed read allocates for one value of `T`, beyond the storage `T` itself takes.
fn typedOwned(comptime T: type, comptime bounds: meta.Bounds, comptime cfg: anytype, comptime limits: Limits) usize {
    return switch (comptime reflect.kindOf(T)) {
        .bool, .int, .float, .byte_array, .@"enum" => 0,
        .text, .byte_string => blk: {
            const n: usize = bound(@typeName(T), @min(bounds.max_len, limits.max_string_len), "a string");
            break :blk growth(n, 1, 1);
        },
        .raw => blk: {
            // Checking a raw item records its map keys: at most one entry per two bytes.
            const n: usize = bound(@typeName(T), @min(bounds.max_len, limits.max_string_len), "a raw item");
            break :blk 3 * (n / 2 + 8) * 40 + 3 * n + 40 * 8;
        },
        .list => blk: {
            const Elem = @typeInfo(T).pointer.child;
            const n: usize = bound(@typeName(T), @min(bounds.max_len, limits.max_items), "a list");
            const elem_bounds: meta.Bounds = if (bounds.elem) |elem| elem.* else .{};
            break :blk growth(n, @sizeOf(Elem), @alignOf(Elem)) + n * typedOwned(Elem, elem_bounds, cfg, limits);
        },
        .array => @typeInfo(T).array.len * typedOwned(@typeInfo(T).array.child, .{}, cfg, limits),
        .optional => typedOwned(@typeInfo(T).optional.child, bounds, cfg, limits),
        .pointer => @sizeOf(@typeInfo(T).pointer.child) + 16 + typedOwned(@typeInfo(T).pointer.child, .{}, cfg, limits),
        .@"struct" => blk: {
            if (!meta.effectiveDenyUnknownFields(T, cfg)) @compileError("a struct that accepts unknown members has no arena bound; set deny_unknown_fields: " ++ @typeName(T));
            var total: usize = 0;
            for (reflect.fields(T, cfg)) |field| {
                if (field.extras) @compileError("a struct with extras has no arena bound: " ++ @typeName(T));
                total += typedOwned(field.type, field.bounds, cfg, limits);
            }
            break :blk total;
        },
        .@"union" => blk: {
            var most: usize = 0;
            for (reflect.variants(T, cfg)) |variant| {
                if (variant.type != void) most = @max(most, typedOwned(variant.type, .{}, cfg, limits));
            }
            break :blk most;
        },
        .hook, .none => 0,
    };
}

/// What the copy into the wire layout allocates for one value of `T`: the arrays of its lists.
fn wireOwned(comptime T: type, comptime bounds: meta.Bounds, comptime cfg: anytype, comptime limits: Limits) usize {
    return switch (comptime reflect.kindOf(T)) {
        .bool, .int, .float, .byte_array, .@"enum", .text, .byte_string, .raw, .hook, .none => 0,
        .list => blk: {
            const Elem = @typeInfo(T).pointer.child;
            if (isScalarList(Elem)) break :blk 0;
            const n: usize = @min(bounds.max_len, limits.max_items);
            const elem_bounds: meta.Bounds = if (bounds.elem) |elem| elem.* else .{};
            break :blk n * @sizeOf(Wire(Elem)) + 16 + n * wireOwned(Elem, elem_bounds, cfg, limits);
        },
        .array => @typeInfo(T).array.len * wireOwned(@typeInfo(T).array.child, .{}, cfg, limits),
        .optional => wireOwned(@typeInfo(T).optional.child, bounds, cfg, limits),
        .pointer => wireOwned(@typeInfo(T).pointer.child, .{}, cfg, limits),
        .@"struct" => blk: {
            var total: usize = 0;
            for (reflect.fields(T, cfg)) |field| total += wireOwned(field.type, field.bounds, cfg, limits);
            break :blk total;
        },
        .@"union" => blk: {
            var most: usize = 0;
            for (reflect.variants(T, cfg)) |variant| {
                if (variant.type != void) most = @max(most, wireOwned(variant.type, .{}, cfg, limits));
            }
            break :blk most;
        },
    };
}
