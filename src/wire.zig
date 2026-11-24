//! Fixed-layout wire types, generated from a schema type: the decoded form of a message laid out
//! the way C lays out a struct, so that code outside Zig (TypeScript over WebAssembly linear memory,
//! say) can read it by offsets with no walk and no parser.
//!
//! `Wire(T)` is the layout of schema type `T`, the same struct, enum, union and optional types the
//! typed layer reads and writes, with every serde rule (renames, integer keys, bounds, optional
//! policies, validators) applied by the typed layer as it always is: `decode` is the typed walk
//! (`typed.deserializeInto`) with `WireSink` assembling `Wire(T)` as it reads, with no `T` between,
//! so this module has no second set of rules.
//!
//!   - an integer and a float are themselves; a bool is a `u8` that must be 0 or 1; an enum is an integer;
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
//! error when a field a decode reaches has no bound. Each list is written once, at the size of its
//! elements' wire layout, as it is read: there is no typed value or typed array first.
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
const cbor = @import("cbor.zig");
const json = @import("json.zig");
const resumable = @import("resumable.zig");

pub const Error = error{
    /// A span's offset or end does not fit `u32`, or lies before the base address.
    OffsetOutOfRange,
    /// A union tag or an enum value in a wire value names no variant or value.
    InvalidTag,
    /// The input is longer than the config's `max_input_bytes`, which `maxArenaSize` relies on.
    InputTooLarge,
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
    @setEvalBranchQuota(1_000_000);
    return switch (comptime reflect.kindOf(T)) {
        .bool => u8,
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
        .pointer => @compileError("a pointer has no wire layout (it would be by value, and a recursive type has no size): use a slice, or an optional: " ++ @typeName(T)),
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
    pub inline fn resolve(self: Memory, span: Span, comptime size: usize, comptime alignment: usize) Error![]const u8 {
        if (span.len == 0) return &.{};
        const start = std.math.add(usize, self.base, span.offset) catch return error.OffsetOutOfRange;
        const length = std.math.mul(usize, span.len, size) catch return error.OffsetOutOfRange;
        const end = std.math.add(usize, start, length) catch return error.OffsetOutOfRange;
        if (start & (alignment - 1) != 0) return error.OffsetOutOfRange;
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

/// Whether a list of `Elem` is its own wire layout: integers, floats and byte arrays. (Not bools: a
/// bool is a byte that must be 0 or 1, which a wire value from outside has to be checked for.)
fn isScalarList(comptime Elem: type) bool {
    return switch (reflect.kindOf(Elem)) {
        .int, .float, .byte_array => true,
        else => false,
    };
}

/// Copies a typed value into its wire layout. Arrays are written into `allocator`, contiguously,
/// and spans point at them; text and byte strings are spans of the memory `value` already has.
pub fn toWire(comptime T: type, allocator: Allocator, base: usize, value: T) (Allocator.Error || Error)!Wire(T) {
    @setEvalBranchQuota(1_000_000);
    return switch (comptime reflect.kindOf(T)) {
        .bool => @intFromBool(value),
        .int, .float, .byte_array => value,
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
        .hook, .none, .pointer => unreachable,
    };
}

/// The typed value of a wire value, the inverse of `toWire`. Arrays are allocated in `allocator`;
/// text, byte strings, raw items and the elements of a scalar list point at the memory the spans
/// name. Every span is checked against `memory` (`error.OffsetOutOfRange`), and an enum value, a
/// union tag or a presence byte that means nothing is `error.InvalidTag`.
pub fn fromWire(comptime T: type, allocator: Allocator, memory: Memory, wire: Wire(T)) (Allocator.Error || Error)!T {
    @setEvalBranchQuota(1_000_000);
    return switch (comptime reflect.kindOf(T)) {
        .bool => switch (wire) {
            0 => false,
            1 => true,
            else => error.InvalidTag,
        },
        .int, .float, .byte_array => wire,
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
        .hook, .none, .pointer => unreachable,
    };
}

/// Reads one `T` from `input` in `Format` (`zerde.cbor` or `zerde.json`) and returns its wire
/// layout. The read is aliased and applies every rule of `T` and of `format_cfg` (strict mode,
/// limits, bounds, validators, keys, optional policies) as a typed read does. `arena` is a fixed
/// buffer of at least `maxArenaSize(Format, T, serde_cfg, format_cfg)` bytes, for the arrays and
/// strings it writes and for what the reader keeps; on an error it is put back as it was. `base` is the
/// address spans are relative to. The wire value points into `input` and `arena`, which must stay where
/// they are. `decodeInto` keeps the reader's scratch apart from the arrays, in a region of its own.
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
    return run(Format, T, arena, arena, base, input, serde_cfg, format_cfg);
}

/// The result of `decodeInto`: the wire value and the bytes of `output` that hold what it points at.
pub fn Decoded(comptime T: type) type {
    return struct { value: Wire(T), used: usize };
}

/// A decode into the caller's regions, with no allocator in the API: `output` (at least
/// `regionSizes(...).output` bytes) takes the arrays and rewritten strings the wire value points at, and
/// stays; `scratch` (at least `regionSizes(...).scratch` bytes, a size known at compile time) takes what the
/// reader keeps while it reads (the key records of a lenient CBOR read of a `Raw`), is free for reuse as soon
/// as the call returns, and is empty for a strict CBOR read and for JSON. A region too small is
/// `error.OutOfMemory`. `base` is the address spans are relative to, and the input and `output` must be
/// memory it reaches. Everything else is `decode`.
pub fn decodeInto(
    comptime Format: type,
    comptime T: type,
    output: []u8,
    scratch: []u8,
    base: usize,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !Decoded(T) {
    var out = std.heap.FixedBufferAllocator.init(output);
    var work = std.heap.FixedBufferAllocator.init(scratch);
    const value = try run(Format, T, &out, &work, base, input, serde_cfg, format_cfg);
    return .{ .value = value, .used = out.end_index };
}

/// The read of `decode` and `decodeInto`: the arrays and strings come from `arena`, what the reader keeps from `work`.
fn run(
    comptime Format: type,
    comptime T: type,
    arena: *std.heap.FixedBufferAllocator,
    work: *std.heap.FixedBufferAllocator,
    base: usize,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !Wire(T) {
    if (comptime meta.hasField(@TypeOf(format_cfg), "max_input_bytes")) {
        if (input.len > format_cfg.max_input_bytes) return error.InputTooLarge;
    }
    const regions = [2][]const u8{ input, arena.buffer };
    const sink: WireSink = .{ .base = base, .memory = .{ .base = base, .regions = &regions }, .arena = arena };
    var deserializer = try Format.sliceDeserializer(work.allocator(), input, format_cfg);
    defer deserializer.deinit(work.allocator());
    deserializer.can_borrow_strings = true;
    const value = try typed.deserializeInto(sink, T, arena.allocator(), &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

/// Builds the fixed layout as the typed walk reads, for `typed.deserializeInto`: what `typed.TypedSink`
/// does for the Zig value. Arrays are written into the arena at their exact size, and a span names them.
pub const WireSink = struct {
    base: usize,
    memory: Memory,
    arena: *std.heap.FixedBufferAllocator,

    pub fn Of(comptime T: type) type {
        return Wire(T);
    }

    pub fn scalar(_: WireSink, comptime T: type, value: T) !Wire(T) {
        return if (comptime reflect.kindOf(T) == .bool) @intFromBool(value) else value;
    }

    pub fn text(self: WireSink, comptime _: type, bytes: []const u8) !Span {
        return spanOf(self.base, bytes);
    }

    pub fn bytesOf(self: WireSink, comptime _: type, bytes: []const u8) !Span {
        return spanOf(self.base, bytes);
    }

    /// A text or a byte string left in the stream (`StreamResumable`): its span is where it is in the stream, not in memory.
    pub fn span(_: WireSink, comptime _: type, start: u64, len: usize) !Span {
        if (len == 0) return .{ .offset = 0, .len = 0 };
        const end = std.math.add(u64, start, len) catch return error.OffsetOutOfRange;
        if (end > std.math.maxInt(u32)) return error.OffsetOutOfRange;
        return .{ .offset = @intCast(start), .len = @intCast(len) };
    }

    /// The span of a list counts elements, not bytes.
    pub fn list(self: WireSink, comptime T: type, items: []Wire(@typeInfo(T).pointer.child)) !Span {
        const bytes = try spanOf(self.base, std.mem.sliceAsBytes(items));
        return .{ .offset = bytes.offset, .len = @intCast(items.len) };
    }

    /// Makes `dest` the present optional and gives its value to read into; with `init` false it is present already.
    pub fn someDest(_: WireSink, comptime T: type, dest: *Wire(T), init: bool) *Wire(@typeInfo(T).optional.child) {
        if (init) {
            dest.* = std.mem.zeroes(Wire(T));
            dest.present = 1;
        }
        return &dest.value;
    }

    pub fn none(_: WireSink, comptime T: type) !Wire(T) {
        return std.mem.zeroes(Wire(T));
    }

    pub fn enumOf(_: WireSink, comptime T: type, value: T) !Wire(T) {
        return @intCast(@backingInt(value));
    }

    /// Makes `dest` the variant `name` and gives its payload to read into; with `init` false it is that variant already.
    pub fn unionDest(_: WireSink, comptime T: type, comptime name: []const u8, dest: *Wire(T), init: bool) *@FieldType(@FieldType(Wire(T), "payload"), name) {
        if (init) {
            dest.* = std.mem.zeroes(Wire(T));
            dest.tag = variantIndex(T, name);
        }
        return &@field(dest.payload, name);
    }

    pub fn unionVoid(_: WireSink, comptime T: type, comptime name: []const u8) !Wire(T) {
        var out: Wire(T) = std.mem.zeroes(Wire(T));
        out.tag = variantIndex(T, name);
        return out;
    }

    pub fn fromDefault(self: WireSink, comptime T: type, allocator: Allocator, value: T) !Wire(T) {
        return toWire(T, allocator, self.base, value);
    }

    /// A struct's `check` takes the typed struct, so it is rebuilt from the wire struct for the call, in
    /// arena space that is handed back at once. A type without a `check` costs nothing.
    pub fn check(self: WireSink, comptime T: type, allocator: Allocator, result: *const Wire(T)) anyerror!void {
        if (comptime !@hasDecl(T, "check")) return;
        const mark = self.arena.end_index;
        defer self.arena.end_index = mark;
        const view = try fromWire(T, allocator, self.memory, result.*);
        try view.check();
    }

    /// Nothing is released: a decode that fails puts the arena back as it was.
    pub fn free(_: WireSink, comptime _: type, _: Allocator, _: anytype, _: bool) void {}
};

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
    /// What the config limits, or null where it does not: a limit that is absent is not a number.
    max_items: ?u64,
    max_string_len: ?u64,
    max_input_bytes: ?u64,
    max_depth: u64,
    /// A strict CBOR read: definite lengths only, so no list grows and no string is rewritten.
    strict: bool,
    /// A resumable read (`Resumable`): every string and `Raw` is copied into the output, since the chunk it came in is gone.
    copy: bool = false,
    /// With `copy`, a text and a byte string are left in the stream (`StreamResumable`): they cost nothing, but for a sorted map's keys.
    in_stream: bool = false,
};

fn optionalOf(comptime cfg: anytype, comptime name: []const u8) ?u64 {
    return if (meta.hasField(@TypeOf(cfg), name)) @as(u64, @field(cfg, name)) else null;
}

fn limitsOf(comptime Format: type, comptime format_cfg: anytype) Limits {
    const has_mode = meta.hasField(@TypeOf(format_cfg), "mode");
    if (has_mode and Format != cbor) @compileError("`mode` is a CBOR read setting; the format here is " ++ @typeName(Format));
    return .{
        .max_items = optionalOf(format_cfg, "max_items"),
        .max_string_len = optionalOf(format_cfg, "max_string_len"),
        .max_input_bytes = optionalOf(format_cfg, "max_input_bytes"),
        .max_depth = if (meta.hasField(@TypeOf(format_cfg), "max_depth")) @min(@field(format_cfg, "max_depth"), 128) else 128,
        .strict = has_mode and @field(format_cfg, "mode") == cbor.Mode.strict,
    };
}

/// The smaller of two limits, where either may be absent.
fn tighter(a: ?u64, b: ?u64) ?u64 {
    if (a) |x| return if (b) |y| @min(x, y) else x;
    return b;
}

/// What a field's own `max_len` and the config's limit allow, or null for no bound.
fn fieldLimit(max_len: usize, limit: ?u64) ?u64 {
    const own: ?u64 = if (max_len == (meta.Bounds{}).max_len) null else max_len;
    return tighter(own, limit);
}

/// A resource a decode takes: `fixed` bytes (or instances) that do not depend on how many items the
/// input has, and `pool` of them for each item of the shared `max_items` budget. A list with a
/// `max_len` of its own is charged in full, per element of the list that holds it. A list with none
/// draws on the one budget the whole input has, so lists nested in it do not multiply it: `pool` is how
/// much the worst use of one item costs, and combines by the most, not the sum.
const Amount = struct {
    fixed: u64 = 0,
    pool: u64 = 0,

    fn plus(a: Amount, b: Amount) Amount {
        return .{ .fixed = a.fixed + b.fixed, .pool = @max(a.pool, b.pool) };
    }

    fn times(a: Amount, n: u64) Amount {
        return .{ .fixed = a.fixed * n, .pool = a.pool };
    }

    fn most(a: Amount, b: Amount) Amount {
        return .{ .fixed = @max(a.fixed, b.fixed), .pool = @max(a.pool, b.pool) };
    }

    /// With every item of the budget at most `items` of it.
    fn total(a: Amount, comptime items: u64) u64 {
        return a.fixed + a.pool * items;
    }
};

/// What a decode takes of the arena, by what it is spent on, because each has its own limit:
///
/// - `lists`: the arrays of lists (the wire arrays);
/// - `text`: the bytes of strings that are not borrowed from the input, which are the escaped ones
///   (JSON), the chunked ones (CBOR) and the bytes JSON decodes from base64, never a definite
///   CBOR string or a plain JSON one, and never a `Raw` item; each is written once at its exact size;
/// - `scratch`: what the reader keeps to check a `Raw` item, reused from one to the next, so the
///   most of any one and not their sum;
/// - the largest list in the schema, for a bound of the lists that does not depend on the fields.
const Cost = struct {
    lists: Amount = .{},
    text: Amount = .{},
    scratch: u64 = 0,
    list_size: u64 = 0,
    list_align: u64 = 0,

    fn plus(a: Cost, b: Cost) Cost {
        return .{
            .lists = a.lists.plus(b.lists),
            .text = a.text.plus(b.text),
            .scratch = @max(a.scratch, b.scratch),
            .list_size = @max(a.list_size, b.list_size),
            .list_align = @max(a.list_align, b.list_align),
        };
    }

    fn times(a: Cost, n: u64) Cost {
        var out = a;
        out.lists = a.lists.times(n);
        out.text = a.text.times(n);
        return out;
    }

    fn most(a: Cost, b: Cost) Cost {
        return .{
            .lists = a.lists.most(b.lists),
            .text = a.text.most(b.text),
            .scratch = @max(a.scratch, b.scratch),
            .list_size = @max(a.list_size, b.list_size),
            .list_align = @max(a.list_align, b.list_align),
        };
    }
};

/// The bytes a list of `n` items of `size` and `alignment` takes in a fixed buffer, worst case: an
/// array list grows from nothing through the capacities the standard library gives it, each a new
/// allocation (the buffer reuses only the last one), and is copied to its exact size at the end.
fn growth(n: u64, size: u64, alignment: u64) u64 {
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

/// The most `growth` costs for one item of the shared budget: a list of `k` items uses `k + 1` of
/// it (its own place and its elements), and costs most per item just after it grew, so the ratio is
/// taken at one item and at each capacity boundary up to `budget` items.
fn growthPerItem(budget: u64, size: u64, alignment: u64) u64 {
    const init = @max(1, 128 / size);
    var worst = (growth(1, size, alignment) + 1) / 2;
    var capacity: u64 = 0;
    while (capacity < budget) {
        capacity = (capacity + 1) + ((capacity + 1) / 2 + init);
        const k = capacity + 1;
        worst = @max(worst, (growth(k, size, alignment) + k) / (k + 1));
    }
    return worst;
}

/// The bytes of a list of `n` items in a read: `growth` for one that is built as it is read, and the
/// exact size for one a strict CBOR read allocates once, since it states its length up front.
fn listBytes(n: u64, size: u64, alignment: u64, strict: bool) u64 {
    if (!strict) return growth(n, size, alignment);
    return if (n == 0) 0 else n * size + alignment - 1;
}

/// `growthPerItem` for `listBytes`: a list of `k` items takes `k * size + alignment - 1` of `k + 1`.
fn listPerItem(budget: u64, size: u64, alignment: u64, strict: bool) u64 {
    if (!strict) return growthPerItem(budget, size, alignment);
    return size + alignment;
}

fn bound(comptime name: []const u8, comptime limit: ?u64, comptime what: []const u8) u64 {
    return limit orelse @compileError(what ++ " has no bound a decode can rely on: " ++ name);
}

/// An upper bound, in bytes, of what the arena of `decode(Format, T, ...)` allocates, computed from
/// the bounds of `T` (`max_len` and `.elem` of each field) and from `format_cfg`: `max_items` (the
/// items of the whole input, which bounds every list that has no `max_len`, and all lists together),
/// `max_string_len`, `max_depth`, and `max_input_bytes`, which `decode` enforces.
///
/// A string that is borrowed from the input (a definite CBOR string, a JSON string without an escape)
/// and a `Raw` item cost nothing: their span points into the input. Only what is rewritten costs.
/// Each such string is measured first and written once, so it costs what it holds and nothing more while
/// it is built. With `max_input_bytes` the strings together hold at most the input (an escape takes two
/// bytes of input or more for one, a chunk only adds a head, base64 decodes to three quarters of its
/// text), and no string is longer than the
/// input, if that is less than the sum of the fields' own bounds. A list costs the capacities an array
/// list grows through, per list; lists together are charged at most `max_items` items, which is less
/// than the sum of their `max_len` when those are generous.
///
/// A key is never allocated: a union's variant and a struct's field are matched where the key is read,
/// into a buffer as long as the longest name. A strict CBOR read (`mode = .strict`, which is refused for
/// another format) is charged no rewritten text and exact lists. A pointer has no wire layout.
///
/// It is a compile error when something a decode reaches has no bound, when a struct accepts unknown
/// members (they would cost without limit: set `deny_unknown_fields`), or when it collects extras.
pub fn maxArenaSize(comptime Format: type, comptime T: type, comptime serde_cfg: anytype, comptime format_cfg: anytype) usize {
    const sizes = comptime computeSizes(Format, T, serde_cfg, format_cfg, false, false);
    return sizes.output + sizes.scratch;
}

/// The two regions of `decodeInto`, in bytes: `output` holds the arrays and rewritten strings the wire value
/// points at, `scratch` what the reader keeps while it reads (empty for a strict CBOR read and for JSON without a `Raw`; the key records of
/// a lenient CBOR `Raw` and the name spans of a JSON `Raw` otherwise), and
/// together they are `maxArenaSize`. Each is an upper bound under the same rules, so a region of exactly its
/// size is enough for any input the config allows.
pub const Sizes = struct { output: usize, scratch: usize };

pub fn regionSizes(comptime Format: type, comptime T: type, comptime serde_cfg: anytype, comptime format_cfg: anytype) Sizes {
    return comptime computeSizes(Format, T, serde_cfg, format_cfg, false, false);
}

/// `regionSizes` for a resumable decode (`Resumable`) of strict CBOR: every string, byte string and `Raw` is copied into `output`
/// as it arrives, each in an allocation of exactly its length (a `Raw`'s grows in place to at most its bound and is cut to its
/// length), so they are charged where a whole-input strict read charges nothing; the arrays are charged as it charges them, and
/// `scratch` is empty, since the reader's state is in the `Resumable`. Every string must have a bound (`max_len`, or
/// `max_string_len`), a `Raw` as well, and a `SortedMap`'s keys the config's `max_string_len`. `cbor_cfg` must say `mode = .strict`.
pub fn resumableRegionSizes(comptime T: type, comptime serde_cfg: anytype, comptime cbor_cfg: anytype) Sizes {
    return comptime computeSizes(cbor, T, serde_cfg, cbor_cfg, true, false);
}

/// The bytes of `resumableRegionSizes`, together.
pub fn maxResumableArenaSize(comptime T: type, comptime serde_cfg: anytype, comptime cbor_cfg: anytype) usize {
    const sizes = comptime resumableRegionSizes(T, serde_cfg, cbor_cfg);
    return sizes.output + sizes.scratch;
}

/// `resumableRegionSizes` for `StreamResumable`: a text and a byte string are left in the stream, so they cost nothing; the arrays, the
/// `Raw` items and a sorted map's keys are charged as `resumableRegionSizes` charges them. A type with none of the latter is bounded
/// by its arrays alone, however long its strings are.
pub fn streamRegionSizes(comptime T: type, comptime serde_cfg: anytype, comptime cbor_cfg: anytype) Sizes {
    return comptime computeSizes(cbor, T, serde_cfg, cbor_cfg, true, true);
}

/// The bytes of `streamRegionSizes`, together.
pub fn maxStreamArenaSize(comptime T: type, comptime serde_cfg: anytype, comptime cbor_cfg: anytype) usize {
    const sizes = comptime streamRegionSizes(T, serde_cfg, cbor_cfg);
    return sizes.output + sizes.scratch;
}

/// A resumable decode (see `resumable.Reading`) into `Wire(T)` in a caller region: strict CBOR fed in chunks, the arrays and every
/// string copied into `output`, which is `resumableRegionSizes(...).output` bytes for any input the config allows. Spans are offsets
/// from `base` as in `decodeInto`, and point into `output` only, since no chunk is kept. It points into itself, so it is set
/// up in place (`init`) and must not be moved. A decode that fails is not undone: `output` is the caller's to reuse.
pub fn Resumable(comptime T: type, comptime serde_cfg: anytype, comptime cbor_cfg: anytype) type {
    return ResumableIn(T, serde_cfg, cbor_cfg, false);
}

/// `Resumable` that leaves a text and a byte string in the stream: the stream is what the caller keeps whole (in JavaScript, the frame),
/// and the decode keeps none of it. The span of a text or a byte string is `{ offset = its first byte's position in the stream from
/// the stream's first byte, len }` (`error.OffsetOutOfRange` past 4 GiB), text checked as UTF-8 a piece at a time as it passes; the span of
/// an array, a `Raw` (copied, and checked once whole) or a sorted map's key (copied, to compare it with the next) is an offset
/// from `base` into `output`, which is `streamRegionSizes(...).output` bytes. Which of the two a span is follows from its field's type.
pub fn StreamResumable(comptime T: type, comptime serde_cfg: anytype, comptime cbor_cfg: anytype) type {
    return ResumableIn(T, serde_cfg, cbor_cfg, true);
}

fn ResumableIn(comptime T: type, comptime serde_cfg: anytype, comptime cbor_cfg: anytype, comptime in_stream: bool) type {
    const Reading = resumable.Reading(WireSink, T, serde_cfg, cbor_cfg, in_stream);

    return struct {
        arena: std.heap.FixedBufferAllocator,
        regions: [1][]const u8,
        reading: Reading,

        const Self = @This();

        pub fn init(self: *Self, output: []u8, base: usize) void {
            self.arena = std.heap.FixedBufferAllocator.init(output);
            self.regions = .{output};
            self.reading = Reading.init(.{
                .base = base,
                .memory = .{ .base = base, .regions = &self.regions },
                .arena = &self.arena,
            }, self.arena.allocator());
        }

        /// The next chunk, all of it; says whether the value is complete (`resumable.Reading.feed`).
        pub fn feed(self: *Self, bytes: []const u8) anyerror!bool {
            return self.reading.feed(bytes);
        }

        /// The value and the bytes of `output` it uses, once `feed` has said it is complete.
        pub fn finish(self: *Self) anyerror!Decoded(T) {
            const value = try self.reading.finish();
            return .{ .value = value, .used = self.arena.end_index };
        }
    };
}

fn computeSizes(comptime Format: type, comptime T: type, comptime serde_cfg: anytype, comptime format_cfg: anytype, comptime copy: bool, comptime in_stream: bool) Sizes {
    @setEvalBranchQuota(1_000_000);
    const limits = comptime blk: {
        var found = limitsOf(Format, format_cfg);
        if (copy and !found.strict) @compileError("a resumable read reads strict CBOR: set mode = .strict");
        found.copy = copy;
        found.in_stream = in_stream;
        break :blk found;
    };
    const cost = comptime typedOwned(T, .{}, serde_cfg, limits, 0);
    const slack = 256;
    const items = limits.max_items;

    // Arrays of lists: from the fields, and, where the items are bounded, from the budget alone.
    var lists = if (cost.lists.pool == 0) cost.lists.fixed else cost.lists.total(bound("max_items", items, "the items of the input"));
    if (items) |budget| if (cost.list_size != 0) {
        const per_item = listPerItem(budget, cost.list_size, cost.list_align, limits.strict);
        lists = @min(lists, per_item * budget);
    };

    // Text that is rewritten: from the fields, and, where the input and the items are bounded, from the input.
    var text = if (cost.text.pool == 0) cost.text.fixed else cost.text.total(bound("max_items", items, "the items of the input"));
    if (limits.max_input_bytes) |input| {
        // Every byte of a rewritten string comes from the input, once: an escape takes two or more bytes of
        // input for one, chunks only add heads, and base64 decodes to three quarters.
        text = @min(text, input);
    }
    const output = lists + text + slack;
    if (output + cost.scratch > std.math.maxInt(usize)) @compileError("the arena bound does not fit this target's usize: " ++ @typeName(T));
    return .{ .output = @intCast(output), .scratch = @intCast(cost.scratch) };
}

/// The list bound of a field, if it has one of its own: a field's `max_len` is a number of items the
/// field can hold; without it the list draws on the shared budget.
fn ownBound(comptime bounds: meta.Bounds) ?u64 {
    return if (bounds.max_len == (meta.Bounds{}).max_len) null else bounds.max_len;
}

/// What the typed read allocates for one value of `T`, beyond the storage `T` itself takes.
fn typedOwned(comptime T: type, comptime bounds: meta.Bounds, comptime cfg: anytype, comptime limits: Limits, comptime depth: u64) Cost {
    // A read refuses nesting deeper than `max_depth`, so a type that recurses through a list is
    // charged down to it and no further.
    if (depth > limits.max_depth) return .{};
    return switch (comptime reflect.kindOf(T)) {
        .bool, .int, .float, .byte_array, .@"enum", .hook, .none => .{},
        .text => blk: {
            // A strict read has only definite strings, which it never rewrites: they are spans of the input.
            if (limits.strict and (!limits.copy or limits.in_stream)) break :blk .{};
            // A string with an escape or in chunks is measured first and written once, exactly sized.
            const n: u64 = bound(@typeName(T), fieldLimit(bounds.max_len, limits.max_string_len), "a string");
            break :blk .{ .text = .{ .fixed = n } };
        },
        .byte_string => blk: {
            if (limits.strict and (!limits.copy or limits.in_stream)) break :blk .{};
            // The bytes only: base64 is decoded from the input, or from the unescaped text a chunk at a time.
            const n: u64 = bound(@typeName(T), fieldLimit(bounds.max_len, limits.max_string_len), "a byte string");
            break :blk .{ .text = .{ .fixed = n } };
        },
        .raw => blk: {
            // A strict read keeps no record of a key (it compares neighbours, and refuses a composite key that
            // holds a float zero), so a raw item of CBOR costs nothing.
            if (limits.strict) {
                // A resumable read copies it, whole, into the output.
                if (!limits.copy) break :blk .{};
                break :blk .{ .text = .{ .fixed = bound(@typeName(T), fieldLimit(bounds.max_len, limits.max_string_len), "a raw item") } };
            }
            // Checking a raw item records its map keys: at most `n / 2` records of 24 bytes, and
            // for a key that is itself an array or map its canonical bytes, once more at each level of
            // nesting that holds it (a level takes at least four bytes). They share the `n` bytes, so
            // the most of the two. JSON records a span of the input for each member (`json.KeyRef`) and
            // a member takes four bytes at least, so `n / 4 + 1` of them; the bound is for either format.
            const n: u64 = bound(@typeName(T), fieldLimit(bounds.max_len, limits.max_string_len), "a raw item");
            // The item is itself a container, below the `depth` that hold it.
            const levels = @min(limits.max_depth -| (depth + 1), n / 4 + 1);
            const json_spans = growth(n / 4 + 1, @sizeOf(json.KeyRef), @alignOf(json.KeyRef));
            break :blk .{ .scratch = @max(growth(n / 2 + 8, 24, 8), growth(n * levels, 1, 1), json_spans) };
        },
        .list => blk: {
            const Elem = @typeInfo(T).pointer.child;
            const elem_bounds: meta.Bounds = if (bounds.elem) |elem| elem.* else .{};
            const element = typedOwned(Elem, elem_bounds, cfg, limits, depth + 1);
            var own: Cost = .{ .list_size = @sizeOf(Wire(Elem)), .list_align = @alignOf(Wire(Elem)) };
            if (ownBound(bounds)) |n| {
                own.lists.fixed = listBytes(n, @sizeOf(Wire(Elem)), @alignOf(Wire(Elem)), limits.strict);
                break :blk own.plus(element.times(n));
            }
            // From the shared budget: each item costs its share of the array and what its own
            // element costs, and one item's worth of what a list nested in it costs.
            const items = bound("max_items", limits.max_items, "the items of the input");
            own.lists.pool = listPerItem(items, @sizeOf(Wire(Elem)), @alignOf(Wire(Elem)), limits.strict) + element.lists.fixed;
            own.text.pool = element.text.fixed;
            break :blk own.plus(.{
                .lists = .{ .pool = element.lists.pool },
                .text = .{ .pool = element.text.pool },
                .scratch = element.scratch,
            });
        },
        .array => typedOwned(@typeInfo(T).array.child, .{}, cfg, limits, depth + 1).times(@typeInfo(T).array.len),
        .optional => typedOwned(@typeInfo(T).optional.child, bounds, cfg, limits, depth),
        .pointer => @compileError("a pointer has no wire layout: " ++ @typeName(T)),
        .@"struct" => blk: {
            // A sorted map is a list of its entries, bounded by its field's `max_len`.
            if (comptime typed.isSortedMap(T)) break :blk typedOwned([]const T.Entry, bounds, cfg, limits, depth);
            if (!meta.effectiveDenyUnknownFields(T, cfg)) @compileError("a struct that accepts unknown members has no arena bound; set deny_unknown_fields: " ++ @typeName(T));
            var total: Cost = .{};
            for (reflect.fields(T, cfg)) |field| {
                if (field.extras) @compileError("a struct with extras has no arena bound: " ++ @typeName(T));
                // A sorted map's key is kept even where strings are left in the stream: the next key is compared with it.
                const field_limits: Limits = comptime kept: {
                    var adjusted = limits;
                    if (@hasDecl(T, "zerde_sorted_entry") and std.mem.eql(u8, field.name, "key")) adjusted.in_stream = false;
                    break :kept adjusted;
                };
                total = total.plus(typedOwned(field.type, field.bounds, cfg, field_limits, depth + 1));
            }
            break :blk total;
        },
        .@"union" => blk: {
            var most: Cost = .{};
            for (reflect.variants(T, cfg)) |variant| {
                if (variant.type != void) most = most.most(typedOwned(variant.type, variant.bounds, cfg, limits, depth + 1));
            }
            break :blk most;
        },
    };
}
