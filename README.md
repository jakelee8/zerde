# zerde

`zerde` is a comptime-specialized serialization framework for Zig.

Point it at a Zig type and a format, and it generates a typed serializer or
deserializer for that exact combination.

What you get:

- one typed API across JSON, ZON, TOML, YAML, CBOR, BSON, MessagePack, and binary
- fast read and write paths without a required runtime value tree
- an optional `zerde.Value` tree for transcoding and schema-less tooling
- per-type and per-call customization for field renames and wire-shape policy
- owned, arena-backed, and aliased slice parse entrypoints
- corpus-backed, property-tested, and fuzz-hardened format coverage
- wasm/WASI pointer+length helpers for moving typed values across JS boundaries and parsing JSON, ZON, YAML, MessagePack, and other format payloads inside the module

Current benchmark snapshot on the repo's mixed nested workload:

- about `2.1x` faster than `std.json` on reads and `1.2x` faster on writes
- about `1.3x` faster than `std.zon` on reads and `1.1x` faster on writes
- about `1.7x` faster than `zig-toml` on reads and `1.1x` faster on writes
- about `8x` faster than `zbor` on reads and `1.8x` faster on writes
- about `2x` faster than `zig-yaml` on reads and `2.5x` faster on writes
- about `9x` faster than `zig-bson` on reads and `3x` to `4x` faster on writes
- about `4x` to `5x` faster than `bufzilla` on reads and `3x` to `4x` faster on writes

```zig
const std = @import("std");
const zerde = @import("zerde");

const StrawHat = struct {
    name: []const u8,
    bounty: u32,
    role: enum { captain, navigator, cook, shipwright },

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const crew_mate = StrawHat{
        .name = "Franky",
        .bounty = 394_000_000,
        .role = .shipwright,
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try zerde.serialize(zerde.json, &out.writer, crew_mate);

    var decoded = try zerde.parseSliceOwned(zerde.json, StrawHat, allocator, out.written());
    defer decoded.deinit();

    std.debug.print("{s}\n", .{out.written()});
}
```

## Formats

| Format | Serialize | Reader deserialize | Slice deserialize | Aliased slice parse | Notes |
| --- | --- | --- | --- | --- | --- |
| Binary | yes | yes | yes | yes | Schema-driven compact binary format |
| BSON | yes | yes | yes | yes | Typed BSON path |
| MessagePack | yes | yes | yes | yes | Typed MessagePack path |
| JSON | yes | yes | yes | yes | Fully typed fast path, benchmarked against `std.json` |
| ZON | yes | yes | yes | no | Typed ZON path, benchmarked against `std.zon`; slice parse currently owns decoded strings |
| TOML | yes | yes | yes | yes | Practical TOML subset centered on scalars, arrays, tables, and arrays-of-tables |
| CBOR | yes | yes | yes | yes | Definite-length writer, or the deterministic encoding of RFC 8949 §4.2.1; read accepts any well-formed CBOR |
| YAML | yes | yes | yes | yes | Practical block-YAML subset with block mappings, block sequences, and flow scalar arrays |

## WebAssembly / WASI

`zerde` is not limited to its compact binary transport in wasm.

The `zerde.wasm` helpers can:

- serialize typed Zig values into wasm-friendly pointer+length buffers
- parse JSON, ZON, YAML, MessagePack, and other supported payloads inside the module
- reserialize those typed values back into JSON, binary, or another format before handing bytes back to JS

```zig
const std = @import("std");
const zerde = @import("zerde");

const CrewManifest = struct {
    captainName: []const u8,
    bounty: u32,
    shipwright: bool,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

pub fn normalizeJson(allocator: std.mem.Allocator, input: []const u8) !zerde.wasm.OwnedBuffer {
    const manifest = try zerde.wasm.parseFormatWith(zerde.json, CrewManifest, allocator, zerde.wasm.sliceDescriptor(input), .{
        .rename_all = .snake_case,
    }, .{});
    defer zerde.free(allocator, manifest);

    return zerde.wasm.serializeFormatOwnedWith(zerde.json, allocator, manifest, .{
        .rename_all = .snake_case,
    }, .{});
}
```

Native format examples and browser-oriented wasm examples live in [`examples/`](examples), and you can build them with `zig build examples`.

## Install

Add `zerde` as a Zig dependency:

```sh
zig fetch --save git+https://github.com/leostera/zerde#0.1.0
```

Then import it from your `build.zig`:

```zig
const zerde_dep = b.dependency("zerde", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zerde", zerde_dep.module("zerde"));
```

And from your Zig code:

```zig
const zerde = @import("zerde");
```

Benchmark history and per-format runs live in [`bench/`](bench).

## CLI

`zerde` also ships with a small transcoder for self-describing formats.

Build it with:

```sh
zig build transcode
```

Then use it like:

```sh
./zig-out/bin/zerde-transcode --from json --to yaml crew.json
```

It currently supports `json`, `zon`, `toml`, `yaml`, `cbor`, `bson`, and `msgpack`.

## Customization

`zerde` accepts configuration at two levels:

- call-site config passed to `serializeWith`, `deserializeWith`, `parseSliceWith`, or `parseSliceAliasedWith`
- per-type config through `pub const serde = .{ ... }`

Supported typed-layer options today:

- `rename_all`
- `omit_null_fields`
- `deny_unknown_fields`
- `field_order`: `.declaration`, `.length_first`, `.bytewise` or `.encoded_key`; unset, the format chooses
- per-field `rename`
- per-field `key`: an integer map key, for formats that allow one (CBOR)
- per-field `optional`: `.lenient` (the default), `.nullable` or `.absent`; see [Optional fields](#optional-fields)

Format-level options are passed as the last argument:

- CBOR `WriteConfig.deterministic` writes the core deterministic encoding of RFC 8949 §4.2.1:
  definite-length maps, fields in the bytewise order of their encoded keys (`field_order`
  `.encoded_key`, which for any mix of text and integer keys is the order §4.2.1 defines), and the
  shortest exact float width. Equal values then produce equal bytes, so the output can be hashed or
  signed. Asking a deterministic write for another `field_order` is a compile error. The default write
  uses indefinite maps in declaration order.
- JSON `WriteConfig.bytes` and `ReadConfig.bytes` choose how a `[N]u8` field is carried:
  `.string` (the default, raw bytes in a string), `.base64` (padded, RFC 4648 §4) or
  `.base64url` (unpadded, RFC 4648 §5). Reader and writer must agree.

Byte fields: a `[N]u8` field and a `zerde.ByteString` (`struct { bytes: []const u8 }`, for a length
known only at run time) are native byte strings in CBOR, MessagePack, BSON and the binary format. A
`[]const u8` field is always a text string in every format. A byte string is read only from a byte
string and text only from text, in CBOR, MessagePack and BSON; in JSON, which has no byte type, a byte
field is read in the configured `bytes` encoding. The `.string` encoding writes the raw bytes, so it
refuses bytes that are not UTF-8.

```zig
// The same value always encodes to the same bytes.
try zerde.serializeWith(zerde.cbor, &out.writer, spec, .{}, zerde.cbor.WriteConfig{ .deterministic = true });

// A digest as base64 in JSON.
try zerde.serializeWith(zerde.json, &out.writer, record, .{}, .{ .bytes = .base64 });
```

Example:

```zig
const std = @import("std");
const zerde = @import("zerde");

const User = struct {
    firstName: []const u8,
    createdAt: i64,
    nickname: ?[]const u8,

    pub const serde = .{
        .rename_all = .snake_case,
        .fields = .{
            .createdAt = .{ .rename = "created_at_unix" },
        },
    };
};

pub fn main() !void {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    try zerde.serializeWith(zerde.json, &out.writer, User{
        .firstName = "Franky",
        .createdAt = 42,
        .nickname = null,
    }, .{
        .omit_null_fields = true,
    }, .{});
}
```

### Unions

A tagged union (`union(enum)`) is written in CBOR and JSON as its variant name when the variant has no
payload, and as a map of one entry, the name and the payload, otherwise. The name follows `rename_all`
and per-field `rename` like a struct field. Reading takes only those two forms: one entry, a known
name, and a bare name only for a variant without a payload. Other formats do not support unions and
say so at compile time.

A variant can have an integer key like a struct field (`.fields = .{ .get = .{ .key = 2 } }`): a variant
without a payload is then the bare integer, any other is `{2: payload}`. Integer variant keys need a format
with integer keys (CBOR). Text and integer keys can mix in one union.

An enum is written as its name by default. `pub const serde = .{ .enum_repr = .integer }` on the enum, or
`.enum_repr = .integer` at the call site, writes its number instead; such an enum reads only a number, while
a name-form enum reads a name or a number.

### Optional fields

A plain `?T` field reads an absent field and `null` alike, and is written as `null` or, with
`omit_null_fields`, left out. Three more cases are expressed in the type or per field:

- `.fields = .{ .x = .{ .optional = .nullable } }`: the field must be present and may be `null`; it is
  always written. An absent field is `error.MissingField`.
- `.fields = .{ .x = .{ .optional = .absent } }`: the field may be absent but not `null`; it is never
  written as `null`. An explicit `null` is `error.UnexpectedType`.
- a nested optional, `??T`, as a struct field: absent is the outer `null`, an explicit `null` is
  `.{ null }`, and the two are written differently (left out, or `null`). Outside a struct field a nested
  optional is a compile error.

### What the CBOR and JSON readers accept

Both readers accept the well-formed forms of their format that a typed value can hold, whatever
encoding the encoder chose. For CBOR that is RFC 8949 §5.3: non-minimal heads, any float width,
unsorted maps, and indefinite-length arrays, maps and strings. Output stays deterministic: reading
changes nothing about what a value writes as. The readers do **not** accept every well-formed input.
What they refuse, and why:

- text that is not UTF-8; a byte string for a text field or the reverse; a chunk of an indefinite string
  of the wrong type (CBOR). In JSON this includes a lone surrogate escape such as `"\udc00"`, which is
  grammatical (RFC 8259 §8.2) but has no UTF-8 form (`error.InvalidUnicodeSurrogate`)
- a float for an integer field, even `1.0`; a number too large for its float field (`1e999` is
  `error.FloatOutOfRange`, not infinity)
- more than 128 open containers (`error.CborNestingTooDeep`, `error.JsonNestingTooDeep`), so a hostile
  input cannot exhaust the stack; and a CBOR length that claims more items than the input has bytes
- a CBOR map with two equal keys (`error.DuplicateField`), checked in every map including those in
  skipped values. Keys are equal as RFC 8949 §5.6.1 defines it: `1` and `1.0` are different keys, `0.0`
  and `-0.0` are the same, NaNs are the same when their significands match, and arrays, maps and tagged
  keys compare by value, so two spellings of one key are one key
- a CBOR tag other than 55799 (self-described CBOR) around a value a typed field reads
  (`error.UnexpectedTag`); a skipped value may carry any tag
- a JSON object member repeated in a field the type reads (`error.DuplicateField`); RFC 8259 §4 allows
  repeated names, so this is a policy, and one that has not been settled. A repeated member in a field
  the type does not read is skipped
- in a dynamic `Value`: a JSON number that is not a finite double or an integer within 128 bits
  (`error.InvalidNumber`, `error.FloatOutOfRange`); a CBOR map key that is not text
  (`error.UnexpectedType`), a tag (`error.UnexpectedTag`), and a simple value other than false, true and
  null (`error.UnexpectedToken`). A struct reads text and integer keys and skips a key of another type
  with its value
- a JSON text that starts with a byte order mark

### Bounds and `check`

A field can carry bounds in `serde.fields` (type or call site): `.min_len` and `.max_len` for the length of
text, a `ByteString`, a `Raw` item or an array slice, and `.min` and `.max` for an integer; they also apply
to the value inside an optional. A length is checked before the memory for it is allocated wherever the
format states it first (a CBOR definite array or string; an indefinite or JSON array is counted as it is read
and stops at `max_len`). A violation is `error.LengthOutOfBounds` or `error.ValueOutOfRange`. For a rule across
fields, a struct declares `pub fn check(self: T) !void`; it runs once the struct is read and its error is
returned as it is. Both are read-side checks: the writer does not repeat them, since a sender does not
re-validate its own output. Bounds apply to the field's own value, not to the elements of an array.

```zig
const Revision = struct {
    key: zerde.ByteString,
    level: u8,

    pub const serde = .{ .fields = .{ .key = .{ .max_len = 1024 }, .level = .{ .min = 1, .max = 9 } } };
    pub fn check(self: Revision) error{Invalid}!void {
        if (self.level == 9 and self.key.bytes.len == 0) return error.Invalid;
    }
};
```

### Extras

A struct can collect the members it does not declare: `pub const serde = .{ .extras = "rest" }` names a
field of type `zerde.Raw` (an empty map when there are none) or `?zerde.Raw` (null when there are none).
The extras are one map item of the format, and the field is not a member itself, so a key spelled `rest`
is just another extra. Unknown members go to it instead of being skipped or refused by
`deny_unknown_fields`; their keys must be text (`error.UnexpectedType` otherwise) and their values are
checked and kept as read, by the read's mode and limits. A declared member never lands in it.

In CBOR the map is definite with its keys in ascending order, so strict input gives canonical extras and
the writer merges them among the declared members in key order (`field_order` `.encoded_key`); in the
default write they follow the declared members. In JSON the object keeps the input order and its
members follow the declared ones. An extras entry that repeats a declared member is
`error.DuplicateField` on write, so no output has a member twice. A `Raw` built by hand must be in the
form a read leaves: a definite CBOR map in key order, or a JSON object.

### Pull reader

For a shape that is only known while reading, `cbor.pullReader(allocator, input, cfg)` and
`json.pullReader(...)` return a reader whose `next()` gives the events of one item in order
(`zerde.Event`: `null`, `bool`, `integer`, `float`, `text`, `bytes`, and the start and end of arrays
and maps, with their counts when the format states them) and null after the last. A map's events are its
keys and values alternately. `skip()` consumes the next value whole, `finish()` checks that the item is
complete and nothing follows, and `deinit()` releases it. A reader checks what a typed read does and
takes the same configuration: the mode, the limits, no repeated key in a CBOR map, UTF-8. A CBOR map
key must be a scalar. Text and byte strings borrow the input (which must outlive the reader) unless they
were in chunks or escaped, and are valid until the next call.

### Value writer

`cbor.valueWriter(allocator, writer, cfg)` and `json.valueWriter(...)` write a value whose shape is only
known while writing: call `writeNull`, `writeBool`, `writeInt`, `writeFloat`, `writeText`, `writeBytes`
or `writeRaw` for an item, `beginArray`/`endArray` and `beginMap`/`endMap` around a container, and
`finish()` at the end; `writeEvent` takes a `zerde.Event`, so a pull reader can be copied into a writer.
A map's items are keys and values alternately. Maps are sorted when they close: CBOR with
`.deterministic = true` orders keys by their encoded bytes (RFC 8949 §4.2.1, any item can be a key) and
writes each float in its shortest exact width, and JSON orders text keys shorter first and then bytewise
(the same order; `.sort_keys = false` keeps insertion order). A repeated key is `error.DuplicateField`;
an unbalanced container is `error.UnbalancedContainers`. CBOR arrays and maps are buffered so their
lengths are definite; JSON arrays are written as they come. JSON bytes follow the config's `bytes`
encoding, and a NaN or infinity is refused.

### Wire types with hooks

A type decides its own wire form with hooks, for a layout the typed walk cannot derive (a span, an optional
that is an array of zero or one item, a union as `[tag, payload]`). Declare any of:

- `pub fn zerdeDecode(allocator: std.mem.Allocator, reader: anytype) anyerror!T`: reads exactly one item
  from a pull reader (`next`, `skip`; see above) under the read's mode and limits. A hook that leaves part
  of its item unread is `error.HookIncomplete`.
- `pub fn zerdeEncode(self: T, encoder: anytype) anyerror!void`: writes one item through an `Encoder`:
  `writeNull`, `writeBool`, `writeInt`, `writeFloat`, `writeText`, `writeBytes`, `writeRaw`, and
  `beginArray(len)`/`endArray`, `beginMap(len)`/`endMap`. It streams, with no buffering and no
  allocation, so the caller states each length up front and writes a map's entries in the order the output
  needs (for deterministic CBOR, ascending by encoded key).
- `pub fn zerdeFree(self: T, allocator: std.mem.Allocator) void`: what `zerde.free` calls to release what
  `zerdeDecode` allocated. Without it the value is left alone.

The hooks work for any struct, union or enum, as a field, an element or an optional, in CBOR and JSON.

### Raw items

A field of type `zerde.Raw` (`struct { bytes: []const u8 }`) is one item of the format being read, checked
and kept as its own bytes instead of decoded: a CBOR item, or the text of a JSON value without the
whitespace around it. The read checks it as the mode and limits say, so a strict read refuses a
non-deterministic item inside it, and a lenient read takes any well-formed one (CBOR tags included).
Writing puts the bytes back unchanged, so a `Raw` must be written in the format it was read from. It is
copied, or borrowed from the input in an aliased parse, like a `ByteString`.

### Reader modes and limits

CBOR `ReadConfig.mode` is `.lenient` (the default, everything above) or `.strict`. A strict read
accepts only the deterministic encoding of RFC 8949 §4.2.1 with the preferred floats of §4.2.2, which is
what `WriteConfig.deterministic` writes, so it is the check a boundary that requires canonical input
uses: shortest heads, definite lengths only, map keys in strictly ascending order of their encoded bytes,
floats in the shortest exact width, NaN only as `0xf97e00`, and no tags (self-described CBOR included).
Anything else is `error.NonDeterministicEncoding`, or `error.DuplicateField` for a repeated key and
`error.UnexpectedTag` for a tag. Strict checks apply to skipped values and keys too. JSON has one form, so
it has no mode.

Both readers take limits, so a hostile input costs a bounded amount: `max_depth` (open containers; at most
128), `max_items` (data items in the whole input, keys and values each counted, `error.TooManyItems`) and
`max_string_len` (bytes of one string after decoding, `error.StringTooLong`). The input size is
`max_input_bytes` for a reader; a slice is already in memory and is not measured.

NaN and the infinities are values in CBOR (RFC 8949 §3.3) and are read into float fields and written;
JSON has none (RFC 8259 §6), so the JSON writer refuses them (`error.NonFiniteFloat`). A profile that
forbids them in CBOR sets `ReadConfig.refuse_non_finite`: any NaN or infinity, in a field, a skipped
value or a key, is then `error.NonFiniteFloat`.

