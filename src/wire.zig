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
//! not fit `u32` is `error.OffsetOutOfRange`; it is never truncated. Text and byte strings are not
//! copied: they stay where the input has them (an aliased read), so the input must stay in place for
//! as long as the wire value is read. Arrays and the typed value they were read into live in the
//! allocator the caller gives, which is meant to be a fixed buffer.
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
            if (@typeInfo(T).int.bits > 64) @compileError("a wire integer is at most 64 bits: " ++ @typeName(T));
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
        .@"enum" => @typeInfo(T).@"enum".tag_type,
        .@"struct" => StructWire(T),
        .@"union" => UnionWire(T),
        .hook, .none => @compileError(@typeName(T) ++ " has no wire layout"),
    };
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

/// The bytes a span names.
pub fn bytesOf(base: usize, span: Span) []const u8 {
    if (span.len == 0) return &.{};
    const pointer: [*]const u8 = @ptrFromInt(base + span.offset);
    return pointer[0..span.len];
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
        .@"enum" => @backingInt(value),
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
/// text, byte strings and raw items point at the memory the spans name.
pub fn fromWire(comptime T: type, allocator: Allocator, base: usize, wire: Wire(T)) (Allocator.Error || Error)!T {
    return switch (comptime reflect.kindOf(T)) {
        .bool, .int, .float, .byte_array => wire,
        .text => bytesOf(base, wire),
        .byte_string => .{ .bytes = bytesOf(base, wire) },
        .raw => .{ .bytes = bytesOf(base, wire) },
        .list => blk: {
            const Elem = @typeInfo(T).pointer.child;
            if (wire.len == 0) break :blk &.{};
            const source: [*]const Wire(Elem) = @ptrCast(@alignCast(@as([*]const u8, @ptrFromInt(base + wire.offset))));
            const items = try allocator.alloc(Elem, wire.len);
            for (source[0..wire.len], items) |item, *slot| slot.* = try fromWire(Elem, allocator, base, item);
            break :blk items;
        },
        .array => blk: {
            var out: T = undefined;
            for (wire, &out) |item, *slot| slot.* = try fromWire(@typeInfo(T).array.child, allocator, base, item);
            break :blk out;
        },
        .optional => blk: {
            const Child = @typeInfo(T).optional.child;
            break :blk switch (wire.present) {
                0 => null,
                1 => try fromWire(Child, allocator, base, wire.value),
                else => error.InvalidTag,
            };
        },
        .pointer => blk: {
            const pointer = try allocator.create(@typeInfo(T).pointer.child);
            pointer.* = try fromWire(@typeInfo(T).pointer.child, allocator, base, wire);
            break :blk pointer;
        },
        .@"enum" => std.enums.fromInt(T, wire) orelse error.InvalidTag,
        .@"struct" => blk: {
            var out: T = undefined;
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, FieldType| {
                @field(out, name) = try fromWire(FieldType, allocator, base, @field(wire, name));
            }
            break :blk out;
        },
        .@"union" => blk: {
            inline for (@typeInfo(T).@"union".field_names, @typeInfo(T).@"union".field_types, 0..) |name, PayloadType, index| {
                if (wire.tag == index) {
                    if (PayloadType == void) break :blk @unionInit(T, name, {});
                    break :blk @unionInit(T, name, try fromWire(PayloadType, allocator, base, @field(wire.payload, name)));
                }
            }
            break :blk error.InvalidTag;
        },
        .hook, .none => unreachable,
    };
}

/// Reads one `T` from `input` in `Format` (`zerde.cbor` or `zerde.json`) and returns its wire
/// layout. The read is aliased and applies every rule of `T` (and of `format_cfg`, such as strict
/// mode and limits) as a typed read does. Text and byte strings stay in `input`; arrays are written
/// into `allocator`, a fixed buffer for a call that must not grow. `base` is the address spans are
/// relative to.
pub fn decode(
    comptime Format: type,
    comptime T: type,
    allocator: Allocator,
    base: usize,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !Wire(T) {
    var deserializer = try Format.sliceDeserializer(allocator, input, format_cfg);
    defer deserializer.deinit(allocator);
    deserializer.can_borrow_strings = true;
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return try toWire(T, allocator, base, value);
}

/// Writes a wire value in `Format`, as the typed value it came from would be written: the same
/// field order, keys, optional policy and determinism. The typed value is rebuilt in `allocator`
/// first (arrays only; text still points at the memory the spans name), because the writers stream
/// and keep no memory of their own.
pub fn encode(
    comptime Format: type,
    comptime T: type,
    allocator: Allocator,
    base: usize,
    wire: Wire(T),
    writer: *std.Io.Writer,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    const value = try fromWire(T, allocator, base, wire);
    try root.serializeWith(Format, writer, value, serde_cfg, format_cfg);
}

/// A wire value as a typed-layer field: reads a `T` through the decode hook, so a message that holds
/// fixed-layout parts can be read by `typed.deserialize` as a whole. The hook gets its arena and
/// base from the deserializer: its allocator, and `user_data`, which `decode` sets and a caller that
/// builds its own deserializer sets itself (0 by default, which is right on wasm32).
pub fn Hooked(comptime T: type) type {
    return struct {
        value: Wire(T),

        pub fn zerdeDecode(allocator: Allocator, reader: anytype) anyerror!@This() {
            const value = try reader.readTyped(T, allocator, .{});
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
