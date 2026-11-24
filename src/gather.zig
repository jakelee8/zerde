//! Gather encode: a CBOR frame written as a skeleton and a list of references.
//!
//! A frame that carries large byte strings (payloads, provenance, metadata) costs a copy of each of them every time it is
//! built whole. `encode` writes everything else, the heads and keys and small values, into `skeleton`, and for each
//! `ByteString` or `Raw` of at least `min_len` bytes writes its head and leaves its bytes out, recording where they go
//! and where the caller holds them: a `Ref` is `{ skeleton_offset, offset, len }`, the bytes at `offset` from `base` (an
//! address, as for `wire.Span`) being inserted at `skeleton_offset` of the skeleton. A caller that owns the buffer, such as
//! a JavaScript host, enqueues the pieces itself and the payload never enters the region the skeleton is in. `assemble`
//! builds the whole frame for a caller that wants it; it is the same bytes as `serializeWith` writes.
//!
//! The skeleton is a caller region and so is the list: no allocator, `error.NoSpaceLeft` when either is short. The bytes
//! a `Ref` names must be in memory the value points into (a `[N]u8` field is copied into the skeleton instead, since
//! the walk holds only a copy of it). The result is CBOR only: JSON would encode the bytes.

const std = @import("std");
const typed = @import("typed.zig");
const cbor = @import("cbor.zig");
const wire = @import("wire.zig");

pub const Ref = cbor.GatherRef;

/// The skeleton and the references of a frame, in output order.
pub const Gathered = struct {
    skeleton: []const u8,
    refs: []const Ref,

    /// The length of the whole frame.
    pub fn len(self: Gathered) usize {
        var total = self.skeleton.len;
        for (self.refs) |ref| total += ref.len;
        return total;
    }
};

pub fn encode(
    comptime T: type,
    skeleton: []u8,
    refs: []Ref,
    base: usize,
    min_len: usize,
    value: T,
    comptime serde_cfg: anytype,
    comptime cbor_cfg: anytype,
) !Gathered {
    var writer = std.Io.Writer.fixed(skeleton);
    var serializer = cbor.serializer(&writer, cbor_cfg);
    var state: cbor.GatherState = .{ .refs = refs, .base = base, .min_len = min_len };
    serializer.gather = &state;
    typed.serializeInto(&serializer, value, serde_cfg, cbor, cbor_cfg) catch |err| switch (err) {
        error.WriteFailed => return error.NoSpaceLeft,
        else => return err,
    };
    return .{ .skeleton = writer.buffered(), .refs = refs[0..state.count] };
}

/// The whole frame in `dst`: the skeleton with each referenced range of `memory` put in its place. A range outside
/// `memory`, or misaligned for nothing (bytes have no alignment), is `error.OffsetOutOfRange`; `dst` short is `error.NoSpaceLeft`.
pub fn assemble(dst: []u8, gathered: Gathered, memory: wire.Memory) ![]u8 {
    if (gathered.len() > dst.len) return error.NoSpaceLeft;
    var out: usize = 0;
    var from: usize = 0;
    for (gathered.refs) |ref| {
        const piece = gathered.skeleton[from..ref.skeleton_offset];
        @memcpy(dst[out..][0..piece.len], piece);
        out += piece.len;
        from = ref.skeleton_offset;
        const bytes = try memory.bytesOf(.{ .offset = ref.offset, .len = ref.len });
        @memcpy(dst[out..][0..bytes.len], bytes);
        out += bytes.len;
    }
    const rest = gathered.skeleton[from..];
    @memcpy(dst[out..][0..rest.len], rest);
    return dst[0 .. out + rest.len];
}
