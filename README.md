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
- `declared_in_order`: the struct declares its fields in the order of their CBOR encoded keys (shorter text keys first,
  integer keys before text, ascending), so the declaration is the canonical order. Any CBOR use of the type with a field
  out of that order is a compile error naming the first one (`typed.declaredOrderFault` is the check, for a test), a type
  with extras cannot declare it, and a strict CBOR read of the type is one merge walk over the fields and the keys: an
  absent field is resolved when the key after it arrives (or at the end), with no seen flags and no pass at the end for
  the fields after the last key. A lenient read and every write are as for any type. The error for an input with two faults
  can differ from the type without it (a missing field is reported when the next key arrives, not at the end)
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
  `error.FloatOutOfRange`, not infinity). JSON can opt in to the exact-value rule for integer fields with
  `.integral_numbers = true` in the read config: a number such as `1.0`, `1e2` or `12300e-2` is then taken when its
  exact decimal value, worked out from its digits and never from a binary64 value, is an integer that fits the field
  (`1.0000000000000001` and `1.5` are still `error.UnexpectedType`, `256.0` for a `u8` is `error.IntegerOverflow`).
  `-0` is the number zero, so a `u8` takes it as `-0.0` is taken with this option
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
- in a dynamic `Value`: a JSON integer beyond 128 bits or a float literal too large for a double
  (`error.InvalidNumber` for an integer beyond 128 bits, `error.FloatOutOfRange` for a float literal that overflows); a CBOR map key that is not text
  (`error.UnexpectedType`), a tag (`error.UnexpectedTag`), and a simple value other than false, true and
  null (`error.UnexpectedToken`). A struct reads text and integer keys and skips a key of another type
  with its value
- a JSON text that starts with a byte order mark

### Bounds and `check`

A field can carry bounds in `serde.fields` (type or call site): `.min_len` and `.max_len` for the length of
text, a `ByteString`, a `Raw` item or an array slice, and `.min` and `.max` for an integer; they also apply
to the value inside an optional. A length is checked before the memory for it is allocated wherever the
format states it first (a CBOR definite array or string; an indefinite or JSON array is counted as it is read
and stops at `max_len`). A violation is `error.LengthOutOfBounds` or `error.ValueOutOfRange`.
A `Raw` field (or an optional `Raw`, or the elements of an array of them through `.elem`) can also carry
`.validate = fn (allocator, bytes) !void`, which runs on the item's own bytes once the read has checked them and their
length, for a rule the read cannot know, such as a profile for metadata (text keys, scalar values, finite floats). Its
error is the read's error. It reads the item with a pull reader of the format (`cbor.pullReader(allocator, bytes, .{})`)
and uses `reader.next()`, so the profile stays in the caller's code. Like the other bounds it is checked on read only, and
it is a compile error on a field that is not a `Raw`.

`.elem` bounds each element of an array field: `.keys = .{ .max_len = 8, .elem = .{ .min_len = 1, .max_len = 1024 } }` is
at most eight keys of one to 1,024 bytes, and `.spans = .{ .elem = .{ .min = 0, .max = 65535 } }` bounds every integer.
An `elem` can have an `elem` of its own for an array of arrays, and applies inside an optional element; each element
is checked as it is read, with the same errors, and a chunked CBOR text element stops at its bound. For a rule across
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
field of type `cbor.Raw` or `json.Raw` (an empty map when there are none) or an optional one (null when there are none).
The extras are one map item of the format, and the field is not a member itself, so a key spelled `rest`
is just another extra. Unknown members go to it instead of being skipped or refused by
`deny_unknown_fields`; their keys must be text (`error.UnexpectedType` otherwise) and their values are
checked and kept as read, by the read's mode and limits. A declared member never lands in it.

In CBOR the map is definite with its keys in ascending order, so strict input gives canonical extras and
the writer merges them among the declared members in key order (`field_order` `.encoded_key`); in the
default write they follow the declared members. In JSON the object keeps the input order and its
members follow the declared ones. An extras entry that repeats a declared member is
`error.DuplicateField` on write, so no output has a member twice. A `Raw` built by hand must be in the
form a read leaves: a definite CBOR map in key order, or a JSON object. The extras are checked as any
`Raw` is on write (see below), in full before the first byte of the map.

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

`reader.raw()` returns the next item whole as the bytes it was read from, where a value is expected (the item
`readRaw` gives a `Raw` field, checked by the mode and limits; an end or a map key where a value is due is
`error.UnexpectedType`). A decode hook uses it to keep the span it consumed.

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

Containers are the one place a value writer buffers, so `max_container_bytes` in the config (default unbounded; a runtime
field of the writer too) bounds it: the most output one open container may hold (a CBOR array or map; a JSON map with
the arrays inside it). A write or a close that would pass it is `error.ContainerTooLarge`, decided from the size of the
item before anything is allocated for it, so a megabyte of text into a small container costs nothing. Sizes are counted
up to a few bytes high per item (a CBOR head as nine bytes, a JSON separator), never low. Output outside every container
goes straight to the writer and is not counted. A map's index of entries (24 bytes each, at most one per two bytes of
the container) comes on top.

### Wire types with hooks

A type decides its own wire form with hooks, for a layout the typed walk cannot derive (a span, an optional
that is an array of zero or one item, a union as `[tag, payload]`). Declare any of:

- `pub fn zerdeDecode(allocator: std.mem.Allocator, reader: anytype) anyerror!T`: reads exactly one item
  from a pull reader (`next`, `skip`; see above) under the read's mode and limits. A hook that leaves part
  of its item unread is `error.HookIncomplete`.
- `pub fn zerdeEncode(self: T, encoder: anytype) anyerror!void`: writes one item through an `Encoder`:
  `writeNull`, `writeBool`, `writeInt`, `writeFloat`, `writeText`, `writeBytes`, `writeRaw`, and
  `beginArray(len)`/`endArray`, `beginMap(len)`/`endMap`. It streams, with no buffering and no
  allocation, so the caller states each length up front and meets it exactly (twice as many items
  for a map: key, value, ...), and writes a map's entries in the order the output needs. It keeps the
  guarantees of `cbor.valueWriter` that it can: a wrong count is `error.LengthMismatch`, nesting is at most
  128, text must be UTF-8, `writeRaw` takes one checked item, and the item is complete when the hook returns.
  In a deterministic CBOR write each key must sort after the one before it by its encoded bytes
  (`error.NonDeterministicEncoding`, `error.DuplicateField`); a key is a scalar or `writeRaw` item of at most
  1024 encoded bytes (`error.KeyTooLong`, `error.UnexpectedType` for an array or map).
- `pub fn zerdeFree(self: T, allocator: std.mem.Allocator) void`: what `zerde.free` calls to release what
  `zerdeDecode` allocated. Without it the value is left alone.

The hooks work for any struct, union or enum, as a field, an element or an optional, in CBOR and JSON.

### Reflection

`zerde.reflect` describes a schema type as the typed layer sees it, for generators (declarations,
grammars, printers) that should not re-derive its rules. Everything is comptime and takes the `cfg` a read
or write takes (`.{}` for none), because call-site overrides and `rename_all` change the wire form:

- `kindOf(T)` is a `Kind`: `bool`, `int`, `float`, `text`, `byte_string`, `byte_array`, `raw`, `optional`,
  `array`, `list`, `pointer`, `enum`, `struct`, `union`, `hook` or `none`.
- `fields(T, cfg)` lists a struct's fields in declaration order: the Zig `name`, the `wire` key (text or
  integer), the field `type` and its `kind`, its `bounds`, its `optional` policy, `nested_optional`,
  `has_default` and whether it is the `extras` field. `defaultOf(T, name)` gives a default.
- `writeOrder(T, Format, cfg, format_cfg)` gives the indexes of the members a write emits, in order,
  for example `zerde.reflect.writeOrder(T, zerde.cbor, .{}, .{ .deterministic = true })`.
- `variants(T, cfg)` lists a union's variants with their `wire` key and payload type; `enumInfo(T, cfg)`
  an enum's values and how a write carries them; `intRange(T)` and `childOf(T)`.

A description is shallow: a field carries its `type`, and a generator describes that in turn, so recursive
types need no care. `tests/typed_tests.zig` builds a small declaration generator from it.

### Bulk string scans

The JSON and CBOR backends find the end of a string, escape text and validate UTF-8 over runs of
bytes (`zerde.bulk`). The scan for the end of a string uses vectors where the target has them (native, or
WebAssembly with `simd128`) and 64-bit integer operations elsewhere, so a build without `simd128` still gets
a speedup. Escaping is a run at a time, writes each escape into the writer's spare buffer when it fits, and writes
exactly what `std.json.Stringify` writes. UTF-8 validation uses the standard library's validator where
that skips ASCII in vector chunks (native, or WebAssembly with SIMD) and the word-at-a-time one
(`validUtf8Words`) elsewhere. `zig build bench-bulk -Doptimize=ReleaseFast` compares them; numbers are in
[`bench/BULK.md`](bench/BULK.md).

### Names are matched, not allocated

A map key or string that is only compared with names a type declares (a union's variants, a struct's fields, an enum's
names) is read without allocating, in CBOR and JSON: the format hands the typed layer the bytes (the input's own, or
the chunks or unescaped characters joined in a stack buffer as long as the longest declared name), and a key longer than
every name is `.long`, read to its end and checked, and no name. `readStringShort`, `nextObjectKeyShort` and, in JSON,
`nextObjectFieldIndex` do it. A key that no field declares is allocated only for the repeated-key check of a CBOR read that
accepts unknown members (not under `deny_unknown_fields` without `extras`, where it is refused as it is read), and for `extras`.

### Raw items

A field of type `cbor.Raw` or `json.Raw` (each a `struct { bytes: []const u8 }` that carries its format in its type) is one item of that format, checked
and kept as its own bytes instead of decoded: a CBOR item, or the text of a JSON value without the
whitespace around it. The read checks it as the mode and limits say, so a strict read refuses a
non-deterministic item inside it, and a lenient read takes any well-formed one (CBOR tags included).
A `cbor.Raw` cannot be written as JSON, nor a `json.Raw` as CBOR: that does not compile. It is
copied, or borrowed from the input in an aliased parse, like a `ByteString`.

A write checks a `Raw` again, whatever made it, and refuses what would not read back: malformed CBOR
or JSON, text that is not UTF-8, nesting beyond 128 (`error.InvalidUtf8`, `error.CborNestingTooDeep`,
`error.TrailingCharacters`, and the parse errors). A deterministic CBOR write also refuses a `Raw` that is not
itself deterministic, with `error.NonDeterministicEncoding` (or `error.UnexpectedTag`), because it promises
that equal values give equal bytes and cannot do it for bytes it must put out as they are. The write
has no allocator, so it does not rewrite them: `zerde.cbor.canonicalize(allocator, bytes)` returns the
deterministic form of an item (shortest heads, definite lengths, joined strings, the shortest exact
float, maps in key order; a tag or a repeated key is an error), and a lenient read's `Raw` or extras
field goes through it before a deterministic write. A non-deterministic write puts a well-formed `Raw`
back as it is. `zerde.cbor.validate(allocator, bytes)` checks that one item is well-formed with no
repeated key. The checks that need no allocation do not look for a repeated key outside a deterministic
write.

`zerde.cbor.canonicalizeInto(dst, scratch, bytes)` is the same with no allocator: it writes the deterministic form
to the front of `dst` (never longer than `bytes`, so a `dst` of that length is enough; `error.NoSpaceLeft` otherwise)
and returns it. A map is put in key order through an index of its entries in `scratch`, 8 bytes an entry, each
entry then written once, from the input, in order: there is no working buffer and no copy of the result.
`zerde.cbor.canonicalScratchSize(n)` is the scratch for `n` map entries open at once (a map's own and those of the
maps that hold it; `error.OutOfMemory` when short). It differs from `canonicalize` in one way, so the two accept different inputs: `canonicalize` takes a map key that is
an array or a map, and `canonicalizeInto` refuses it with `error.UnexpectedType`, as the pull reader does, because ordering it would need its own
canonical form kept, which has no bound. Repeated keys (any spelling, and 0.0 with -0.0) are `error.DuplicateField`.

JSON writes a float as the shortest digits that read back to the same value, laid out as ECMAScript's Number::toString does
(RFC 8785): decimal from 1e-6 up to 1e21 (a whole number has no point: `100`), otherwise scientific with a signed exponent
(`1e+21`, `1.2345e-7`), so `JSON.stringify` writes the same bytes; negative zero is the one difference, written `-0`
so it reads back as itself. No float is longer than 25 bytes (`f64`) or 41 (`f128`).

### Resumable writes

`zerde.resumable.Writer(Format, T, serde_cfg, format_cfg)` writes a `T` as JSON or CBOR in fixed windows. `init()`
makes the cursor (a few words per open container, about 1 KB; the caller owns it) and `fill(value, window)` writes
the next piece into `window` and returns `.{ .len, .done }`, so a stream can be fed a value of any size from one
window of, say, 64 KiB, a window at a time as the consumer has room. Nothing is buffered, sorted or written twice: a
window ends at a token or inside a long string, byte string or `Raw`, which goes on from its byte, and the next call
goes down the same path of containers by the indexes the cursor keeps. It is the typed walk of `serializeWith`, so the
bytes are the same and every rule of the schema holds. A window must hold one token, `Writer.min_window` (64 bytes for a number or head, which holds any float of either format,
plus the longest field name escaped and 7: `error.WindowTooSmall` below it). Not supported (compile errors): extras,
encode hooks and `bin`'s sequence path. The value must be the same in every call. `zig build bench-wire` measures
the windows against the whole write on real text (`bench/WIRE.md`).

`zerde.resumable.Render(json_cfg)` renders stored CBOR as JSON in windows: `fill(stored, window)` writes the bytes that reading the item
with `cbor.pullReader` (strict) into `json.valueWriter` gives, with nothing buffered or sorted (a deterministic item's keys are stored in the
order the value writer sorts them into) and a long string or byte string going through the window a piece at a time. The first window decides
everything that can fail for the whole item, so no window of an item that cannot be rendered is written: the item must be strict CBOR
(`cbor.verifyStrict`), every map key text (`error.UnexpectedType`), every float finite (`error.NonFiniteFloat`) and, with bytes written as JSON
strings (the default), every byte string UTF-8 (`error.InvalidUtf8`). Its state is a word or two for each open container, about 3.4 KB, and
a window needs `Render.min_window` (64) bytes. `zig build bench-wire` measures it against the whole render.

### Resumable reads

`zerde.resumable.Decoder(T, serde_cfg, cbor_cfg).init(.{}, allocator)` reads a `T` from strict CBOR that arrives in pieces, as a
request body does. `feed(chunk)` takes a whole chunk and says whether the value is complete (`true`) or more is due (`false`);
`finish()` gives the value, or `error.UnexpectedEndOfInput` if the input ended first. The chunks may be cut anywhere, a head
and a string included, and a one-byte chunk is as good as a large one: the value, or the error, is the whole-input strict read's
(`mode = .strict`, which `cbor_cfg` must say), for every way the input is cut. Bytes after the value are `error.TrailingCharacters`,
and an error is the same for every later call. `zerde.chunk.Reader(Config)` is the reader under it: it keeps no input, only a head
cut by the end of a chunk (8 bytes), the limits and three counters.

What it keeps is bounded by the config: the typed walk is the one of `parseSlice` (every rule of the schema, bound, optional policy
and key is applied by the same functions) written into a destination (`typed.deserializeValue` takes a `*Of(T)`), so what a
container has read so far is in the value and a frame of the cursor keeps where it is, a few words per open container, optional
or pointer. The cursor is sized at compile time from `max_depth` and from the type (`resumable.zig`), and the whole stream is
bounded by `max_input_bytes` and `max_items` however it is cut. Each call goes down the same path of containers again and each
level goes on from where it was, as in the resumable write.

The differences from a whole read, each a deliberate one:

- **Every string, byte string and `Raw` is copied**, once, into an allocation of exactly its length (a `Raw` grows as it arrives, within
  its bound, and is cut to its length), since the chunk is gone when the read goes on. A length is checked against `max_len`,
  `max_string_len` and what the stream may still hold before anything is allocated for it. A `Raw` is bounded as a string is: by its
  `max_len` and by `max_string_len`. Nothing is freed on an error, so the allocator must be an arena or a fixed buffer.
- **A struct is read as a merge over its fields in the order of their encoded keys**, with no flag for a field, whatever order it is
  declared in: a key that does not rise is `error.DuplicateField` or `error.NonDeterministicEncoding`, and a required field with no key is
  `error.MissingField`, said after the last key. A struct must `deny_unknown_fields` and have no extras (a key no field declares is
  `error.UnknownField`); a struct key that is neither text nor an integer is refused where it is met, without being read to its end,
  which is the one case where the whole read may report a malformed key before it reports the unknown one.
- A decode hook is a compile error; `max_depth` above 128 is one.

`wire.Resumable(T, serde_cfg, cbor_cfg)` is the same into `wire.Wire(T)` in a caller region: `init(&self, output, base)` sets it up in
place (it points into itself), `feed` and `finish` as above, `finish` giving the value and the bytes of `output` it used.
`wire.resumableRegionSizes(T, serde_cfg, cbor_cfg)` (and `maxResumableArenaSize`) is its bound at compile time, as `regionSizes` is
for `decodeInto`, with the strings and `Raw` items charged, since they are copied (a whole-input strict read charges none): a
region of exactly that size holds any input the config allows, and `scratch` is empty. Every string needs a bound (`max_len` or
`max_string_len`), and a `SortedMap`'s keys need `max_string_len`.

### Sorted maps

`zerde.SortedMap(V)` is a map whose keys are data (labels, history, limits): a slice of `Entry { key, value }` sorted by
encoded text key (shorter first, then bytewise), found with `get`, `getPtr` and `index` by binary search, with no hash table
and no copy of a key (an aliased read keeps the input's bytes; in a decode into `wire.Wire` it is `{ entries: Span }` over
`{ key: Span, value: Wire(V) }`). CBOR and JSON read and write it as a map of text keys. A read refuses a key that does
not sort after the one before it in every mode (`error.NonDeterministicEncoding`, or `error.DuplicateField` when equal),
a write refuses entries that are not in order (the same errors), a field's `max_len` bounds the entries (checked from the map's
head when its length is stated, and at each entry otherwise) and `.elem` bounds each value. A resumable write of one goes entry by entry
(a key longer than the window goes through it a piece at a time, and a key follows `trusted_text` as any text does), refusing an entry out of
order when it reaches it.

### Gather encode

`zerde.gather.encode(T, skeleton, refs, base, min_len, value, serde_cfg, cbor_cfg)` writes a CBOR frame without copying
its large byte strings: everything else (heads, keys, small values) goes into the caller's `skeleton`, and each
`ByteString` or `Raw` of at least `min_len` bytes has its head written and its bytes left out, with a `gather.Ref`
`{ skeleton_offset, offset, len }` recorded in `refs` (the bytes at `offset` from `base`, an address as in `wire.Span`, go
at `skeleton_offset`). A host that owns the buffer enqueues the pieces itself, so the payload never enters the region
the skeleton is in. `gather.assemble(dst, gathered, memory)` builds the whole frame, which is the bytes `serializeWith`
writes. Both regions are the caller's (`error.NoSpaceLeft` when short), a byte below `base` or beyond `u32` is
`error.OffsetOutOfRange`, and a `[N]u8` field is copied into the skeleton, since the walk holds only a copy of it.

### Fixed-layout wire types

`zerde.wire` generates, from a schema type, the same value laid out the way C lays out a struct, for code that
reads it by offset out of linear memory (TypeScript over WebAssembly, say) with no parser:

- `wire.Wire(T)` is the type. Integers are u8, u16, u32, u64 or the signed kind (`usize`, `isize`, C types and other
  widths are a compile error, so the layout is the same on every target); floats are f32 or f64; a bool is a `u8`
  that must be 0 or 1 (`error.InvalidTag` otherwise); an
  enum is the smallest 8-, 16-, 32- or 64-bit integer that holds its values (signed if one is negative); `[N]T` is
  `[N]Wire(T)`; text, a `ByteString`, a `Raw` and any slice are a `wire.Span` (`extern struct { offset: u32, len: u32 }`:
  `len` counts bytes, or elements for a slice, which is a contiguous `Wire(element)` array); `?T` is `wire.Opt(Wire(T))`
  (a presence byte, 0 or 1, then the value, zero when absent); a struct is an `extern struct` of its members in declaration
  order; a tagged union is `extern struct { tag: u8, payload: extern union { ... } }`, the tag being the variant's index
  in declaration order and a variant without payload having no member in the union.
- `wire.decode(Format, T, arena, base, input, serde_cfg, format_cfg)` reads one `T` from `input` (CBOR or JSON) and returns
  its `Wire(T)`. The read is the typed read, aliased, with every rule of `T` and of the config (strict mode, limits, bounds,
  validators, integer keys, optional policies): it is the typed walk with a sink that builds `Wire(T)` as it reads (a
  struct's own `check` is called on the typed struct rebuilt for the call in arena space that is handed back at once), so there is no second set of rules
  to drift. `arena` is a `*std.heap.FixedBufferAllocator` and must be one: nothing is freed, and on an error it is put back as
  it was. Spans are offsets from `base`: 0 on wasm32, where an offset is a linear-memory address, or the address of a region
  that holds both the input and the arena on a native target. An offset or an end beyond `u32`, or an address before `base`, is
  `error.OffsetOutOfRange`.
- Where the bytes are: a plain text or byte string and a `Raw` stay in `input` (it must stay put while the wire value is
  read); a JSON string with an escape, a chunked CBOR string, bytes JSON decodes from base64 and every array of structs,
  unions, optionals, enums, bools or arrays are written into the arena, once, as the wire array (there is no typed array
  before it: the read builds the wire layout directly). A list of integers and floats is the same array of its own elements.
  So a span points into the input or the arena, and both must be in memory `base` reaches.
- `wire.maxArenaSize(Format, T, serde_cfg, format_cfg)` is an upper bound, computed at comptime, of the bytes a decode takes
  from the arena. It uses the `max_len` and `.elem` of each field and, from `format_cfg`: `max_items` (items in the whole
  input, which bounds every list without a `max_len` and all lists together, so nesting such lists does not multiply it),
  `max_string_len`, `max_depth`, `max_input_bytes`, which `decode` enforces (`error.InputTooLarge`), and `mode`: a strict
  CBOR read has only definite strings and lengths, so it rewrites no string and allocates each list once, at its exact size.
  `mode` is a CBOR setting and a compile error for another `Format`. A key is never allocated (see below), so there is no term for the keys of unions or structs. A pointer has no wire layout (use a
  slice or an optional); a type that recurses through a list is charged down to `max_depth`.
  The bound is worked out in 64 bits and is a compile error only when it does not fit the target's `usize`. A bound set on a
  union variant (`serde.fields.<variant>`) applies to its payload, in the read and in the bound. Only what is
  rewritten costs: a rewritten string (a JSON string with an escape, a chunked CBOR string, bytes decoded from base64) is measured first and written once, so it costs its length and nothing while it is built, and the strings together hold at most the input; a list the capacities an array list grows through, and a `Raw` item
  only what the CBOR reader keeps to check its map keys (once, reused from one item to the next). It is a compile error when
  something a decode reaches has no bound, when a struct accepts unknown members (set `deny_unknown_fields`) or collects
  extras. It is not tight, but is within a small factor of the worst input: tests decode adversarial requests (escaped
  and chunked strings, base64 payloads, a chain of maps used as keys) into an arena of exactly the bound, and the bound is
  between one and four times what they use. Without `max_input_bytes` the text bound is the sum of the fields' own
  `max_len`, which with a large `max_len` is large.
- `wire.decodeInto(Format, T, output, scratch, base, input, serde_cfg, format_cfg)` is `decode` with no allocator in the
  API: `output` and `scratch` are byte slices, and it returns `Decoded(T)`, the value and `used`, the bytes of `output`
  that hold what it points at. `wire.regionSizes(Format, T, serde_cfg, format_cfg)` gives at compile time their sizes,
  `.output` for the arrays and rewritten strings (which stay) and `.scratch` for what the reader keeps while it reads
  (the key records of a lenient CBOR read of a `Raw`; nothing for a strict CBOR read or for JSON), which together are
  `maxArenaSize` and are each an upper bound of their own. The scratch is free again when the call returns, so one
  region serves every decode and the output region stays as small as the value. A region too small is `error.OutOfMemory`.
  A resumable decode into a region (`wire.Resumable`, see Resumable reads) has its own `wire.resumableRegionSizes`.
- `wire.encode(Format, T, arena, memory, wire, writer, serde_cfg, format_cfg)` writes a wire value as the typed value would be
  written (same order, keys, optional policy, determinism). It rebuilds the typed value first, in `arena` (put back after), because
  the writers stream and keep no memory of their own. A wire value that came from outside is not trusted: `memory` is a
  `wire.Memory`, the base and the ranges a span may point into (the input and the arena), and a span outside them, misaligned
  for what it holds, or whose sum overflows is `error.OffsetOutOfRange`; an enum value, tag or presence byte that means nothing
  is `error.InvalidTag`. `wire.toWire` and `wire.fromWire` are the conversions, and `wire.spanOf` and `Memory.bytesOf` convert a span.
- `wire.describe(T, cfg)` returns the layout as a comptime tree (`Node`: kind, size, alignment, and for each member its name, wire key
  and `@offsetOf` offset), so a generator of accessors for another language needs no layout rule of its own.
- `wire.Hooked(T)` (and `wire.HookedWith(T, serde_cfg)`, to give the inner type a call site's config) is a struct field type for a
  wire value inside a larger typed message: its decode hook reads a `T` with `reader.readTyped(T, allocator, serde_cfg)` and converts it,
  taking the base from `reader.userData()`, the word a caller sets on a deserializer it builds itself (`d.user_data = base`;
  `zerde.typed.deserialize` reads through it; 0 by default, which is right on wasm32). Like `decode` it needs a fixed-buffer
  allocator. It has no encode hook: an encode hook streams and has no allocator to rebuild the typed value in, so write a wire value
  with `wire.encode`.

A type with no wire layout (a hook type, a tuple, an untagged union, a nested optional) is a compile error.

### Reader modes and limits

CBOR `ReadConfig.mode` is `.lenient` (the default, everything above) or `.strict`. A strict read
accepts only the deterministic encoding of RFC 8949 §4.2.1 with the preferred floats of §4.2.2, which is
what `WriteConfig.deterministic` writes, so it is the check a boundary that requires canonical input
uses: shortest heads, definite lengths only, map keys in strictly ascending order of their encoded bytes,
floats in the shortest exact width, NaN only as `0xf97e00`, and no tags (self-described CBOR included).
Anything else is `error.NonDeterministicEncoding`, or `error.DuplicateField` for a repeated key and
`error.UnexpectedTag` for a tag. Strict checks apply to skipped values and keys too. JSON has one form, so
it has no mode.

A strict read finds a repeated key as its neighbour and keeps no record and no sort for it: one data item has
one deterministic encoding, so equal keys are adjacent in the ascending order and compared as bytes, and the
bound of a `Raw` item has no key scratch. The one pair of different encodings that are one key is 0.0 and -0.0
(RFC 8949 §5.6.1): a map with both is `error.DuplicateField` (checked with two flags per map), and a key that
is an array or a map and holds a float zero anywhere inside it is `error.NonDeterministicEncoding`, the one input
a strict read refuses that is well-formed and valid, because telling its repeats needs a record. A deterministic
write applies the same rule to the `Raw` and extras values it puts out.

Both readers take limits, so a hostile input costs a bounded amount: `max_depth` (open containers; at most
128, a larger value is a compile error), `max_items` (data items in the whole input, keys and values each counted, `error.TooManyItems`) and
`max_string_len` (bytes of one string after decoding, `error.StringTooLong`). The input size is
`max_input_bytes` for a reader; a slice is already in memory and is not measured.

NaN and the infinities are values in CBOR (RFC 8949 §3.3) and are read into float fields and written;
JSON has none (RFC 8259 §6), so the JSON writer refuses them (`error.NonFiniteFloat`). A profile that
forbids them in CBOR sets `ReadConfig.refuse_non_finite`: any NaN or infinity, in a field, a skipped
value or a key, is then `error.NonFiniteFloat`.

`trusted_text = true` (a `ReadConfig` field of both formats) skips the UTF-8 check of text and keys, for an item that has
been checked once already, such as plaintext this library wrote and a store authenticated. Everything else is still
checked: escapes, control characters, the mode, the limits. `WriteConfig.trusted_text` skips the check a writer makes of text
on the way out (`error.InvalidUtf8`) for typed strings, the value writers and the hook encoders, so a render of text read
under a trusted read does not check it twice. With either set, bytes that are not UTF-8 pass as text, so never set one for
input that has not been checked: the output of a write that skipped the check may not read back. A `Raw` is still checked in
full when it is written. Measured in `bench/BULK.md`: it saves the check, which is small natively, not the escape scan.
