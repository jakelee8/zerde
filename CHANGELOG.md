# Changelog

## Unreleased

### Breaking

- Requires Zig 0.17.0 (`minimum_zig_version`). The `toml`, `zbor` and `zbench` dependencies and the vendored benchmark baselines are updated to match.
- An integer field rejects a float with a whole value (`1.0`, `1e2`, CBOR `0xf93c00`) in CBOR, JSON and MessagePack with `error.UnexpectedType`. JSON accepts such numbers with `ReadConfig.integral_numbers`.
- A float field rejects a finite number too large for its type (JSON `1e999`, a CBOR or MessagePack double read into `f32`) with `error.FloatOutOfRange`. It no longer rounds to infinity.
- CBOR, MessagePack and BSON read a byte field (`[N]u8`, `zerde.ByteString`) only from a byte string, and a text field only from text. Other types give `error.UnexpectedType`.
- CBOR writes a `[N]u8` field as a byte string, as MessagePack, BSON and the binary format do. It was a text string.
- The CBOR reader rejects:
  - text that is not UTF-8 (`error.InvalidUtf8`);
  - a map that repeats a key at any depth, with keys compared as RFC 8949 §5.6.1 defines (`error.DuplicateField`);
  - a tag other than 55799 around a typed value (`error.UnexpectedTag`);
  - more than 128 open containers (`error.CborNestingTooDeep`);
  - a length that claims more items than the input has bytes.
- The JSON reader rejects text that is not UTF-8 (`error.InvalidUtf8`).
- JSON, MessagePack and BSON reads reject an object that repeats a key at any depth, typed or untyped (`error.DuplicateField`), as CBOR, TOML, YAML and ZON already did. JSON compares decoded names.
- MessagePack and BSON reads reject more than 128 open containers in a skipped value (`error.MsgpackNestingTooDeep`, `error.BsonNestingTooDeep`).
- A BSON read walks a skipped sub-document and sizes every element as the BSON specification defines. It previously jumped over the declared length. Malformed documents give `error.InvalidDocumentTerminator` or `error.InvalidDocumentLength`. An undefined type byte gives `error.UnsupportedBsonType`.
- A dynamic `Value` rejects a CBOR tag (`error.UnexpectedTag`; it was dropped) and a JSON number that is not a finite double (`error.FloatOutOfRange`; it was infinity). A `Value` read from CBOR holds a byte string as bytes; it was text.
- The JSON writer writes a float as the shortest digits that read back to the same value, laid out as ECMAScript `Number::toString` (RFC 8785): `1e+21`, `5e-324`. Values from 1e-6 up to 1e21 are unchanged.
- The JSON writer rejects NaN and infinity (`error.NonFiniteFloat`). The JSON string writer, the CBOR text writer and the JSON `.string` byte encoding reject text that is not UTF-8 (`error.InvalidUtf8`).
- `sliceDeserializer` and `readerDeserializer` of CBOR, JSON, MessagePack and BSON allocate while reading. A caller that uses one directly must call `deinit`, also for borrowed input. `parseSlice*`, `deserialize*` and `value.parse*` already do.
- `cbor.CborSerializer` takes a second comptime parameter after `Config`: `deterministic`. `cbor.serializer` builds the type from the write config.
- A field `rename` that is not valid UTF-8 is a compile error.
- A `Raw` field's `validate` under a wire read (`wire.decode`, `wire.decodeInto`, `wire.Resumable`, `wire.StreamResumable`) needs the new field option `validate_bytes`, the most bytes the validator allocates for one item, and is a compile error without it; use `0` for a validator that allocates nothing. A typed read is unchanged unless it states `validate_bytes`.
- A struct with a `check` that holds a text or byte string is a compile error under `wire.StreamResumable` itself, and under `streamRegionSizes`: the string stays in the stream and the check read output bytes at its stream offset (or got `error.OffsetOutOfRange`) instead of the text. A `Raw` and a sorted map's key are copied into the output and keep working.
- `wire.encode` takes the read config of a decode of the same type as a new last comptime parameter, `read_cfg`, and holds its rebuild to that read's limits (`error.LengthOutOfBounds`, `error.TooManyItems`, the format's nesting error). Every list that is not a list of scalars needs a bound for it (a field's `max_len`, or `max_items` in `read_cfg`): a compile error otherwise. `wire.fromWire` takes a new second parameter, `limited`: `null` for what it did, or `wire.Limited(Format, serde_cfg, read_cfg)`.
- `reflect.Kind` has a new value, `.@"packed"`, so a `switch` over every value of it no longer compiles until it handles it.
- `Diagnostic.pushField`, `pushIndex` and `pop` are removed. A path longer than 64 segments now keeps its innermost segments and prints `root[...]` before them.

### Added

#### Field and type options

- `serde.fields.<f>` options `key` (an integer map key, CBOR) and `optional` (`.lenient`, `.nullable`, `.absent`). Nested optional fields (`??T`) distinguish an absent field from `null`.
- Field bounds in `serde.fields`: `min_len`, `max_len`, `min` and `max`. Bounds apply to union variants and are checked before allocation where the length is known. Violations give `error.LengthOutOfBounds` or `error.ValueOutOfRange`. `.elem` bounds each element of an array field. A struct-level `check` runs after a read.
- `serde.field_order` (`.declaration` by default, `.length_first`, `.bytewise`, `.encoded_key`), set per call or per type.
- `serde.declared_in_order` asserts that fields are declared in CBOR encoded-key order. It is a compile error otherwise. A strict read of such a type is a merge walk over fields and keys.
- `serde.extras` (CBOR and JSON): a `cbor.Raw` or `json.Raw` field, or an optional one, collects the unknown text-keyed members as one map. A write merges them back in key order. An entry that repeats a declared member gives `error.DuplicateField`.
- Tagged unions (`union(enum)`) for CBOR and JSON. A variant without a payload is its name. Other variants are a one-entry map of name and payload. CBOR supports integer variant keys (`.fields = .{ .v = .{ .key = N } }`). Other formats reject a union at compile time.
- `serde.enum_repr = .integer`: an enum is written as its number and read only from a number.
- `zerde.ByteString`, a variable-length byte string: a CBOR byte string, MessagePack `bin`, BSON binary, or a JSON string in the configured `bytes` encoding. `[]const u8` stays text.
- JSON `WriteConfig.bytes` and `ReadConfig.bytes` (`.string` by default, `.base64`, `.base64url`) select the byte-field encoding. A base64 field that does not decode gives `error.InvalidBytes`.
- `zerde.SortedMap(V)`: a map with text keys, stored as a slice of entries sorted by encoded key. It provides `get`, `getPtr` and `index` by binary search, `max_len` and `.elem` bounds, and the wire layout `{ entries: Span }`. Reads reject a repeated key (`error.DuplicateField`). A strict CBOR read also rejects a key that does not sort after its predecessor (`error.NonDeterministicEncoding`). Other reads (lenient CBOR, JSON) sort the entries. A write rejects entries out of order. Serializers write a map entry's key between `beginMapEntry` and `endMapKey`.
- `zerde.reflect`: comptime reflection of fields, write order, union variants and enums, for generators.

#### CBOR and JSON reading and writing

- `cbor.Raw` and `json.Raw`: a field kept as the bytes of one validated item and written back unchanged.
  - A read validates the item with the read's mode and limits at any depth, and rejects an object that repeats a member (`error.DuplicateField`).
  - A write checks each `Raw` and extras item it emits. A deterministic CBOR write rejects an item that is not deterministic.
  - A `Raw` of one format cannot be written in another.
  - `.validate = fn (allocator, bytes) !void` in `serde.fields` runs after the read validates the item.
- CBOR `ReadConfig.mode` (`.lenient` by default, `.strict`). Strict accepts only the deterministic encoding of RFC 8949 §4.2.1 and §4.2.2 (`error.NonDeterministicEncoding`) and rejects tags. An enum written as its number where the type writes its name gives `error.NonDeterministicEncoding`, in the slice and the resumable read. A key that is an array or map holding a float zero gives the same error. The repeated-key check compares neighbours and allocates nothing, also in a `Raw` and in skipped values.
- Read limits `max_depth`, `max_items` and `max_string_len` for CBOR and JSON. `max_depth` is 128 by default and at most 128; a larger value is a compile error. The others are unbounded by default. Violations give `error.TooManyItems` or `error.StringTooLong`.
- CBOR `ReadConfig.refuse_non_finite` (default `false`): NaN and infinity anywhere in the input give `error.NonFiniteFloat`.
- CBOR `ReadConfig.refuse_negative_zero` (default `false`): a float -0 of any width gives `error.NegativeZero`, also in skipped values, keys and a `Raw`.
- CBOR `WriteConfig.normalize_negative_zero` (default `false`): the typed, value, hook and resumable writers write a float zero as +0. A typed or hook write rejects a `Raw` or extras item that holds -0.0. `cbor.canonicalizeWith` and `cbor.canonicalizeIntoWith` take the write options.
- CBOR `WriteConfig.deterministic` (default `false`): the core deterministic encoding of RFC 8949 §4.2.1: definite lengths, keys in bytewise order of their encoding, shortest exact float width, canonical NaN.
- CBOR reads indefinite-length byte and text strings and tag 55799 (self-described CBOR).
- JSON `ReadConfig.integral_numbers` (default `false`): an integer field accepts `1.0`, `1e2` or `12300e-2` when the exact decimal value is an in-range integer. A remaining fraction gives `error.UnexpectedType`. An out-of-range value gives `error.IntegerOverflow`.
- `trusted_text` in the CBOR and JSON read and write configs (default `false`) skips the UTF-8 check of text known to be valid. See `bench/BULK.md`.
- `cbor.canonicalize` returns the deterministic form of an item. `cbor.validate` checks an item.
- `cbor.canonicalizeInto(dst, scratch, bytes)` and `cbor.canonicalScratchSize(n)` canonicalize into caller buffers without an allocator. The result is never longer than the input. A map key that is an array or map gives `error.UnexpectedType`.
- `cbor.pullReader` and `json.pullReader`: an event reader (`zerde.Event`) over one item. It provides `skip`, `raw()` (the next item whole) and `readTyped`, and applies the mode, limits and repeated-key check of a typed read.
- `cbor.valueWriter` and `json.valueWriter`: writers for runtime-defined values with `writeEvent`. CBOR lengths are definite. Maps are sorted on close (CBOR deterministic: encoded-key order; JSON: length-first `sort_keys`). A repeated key gives `error.DuplicateField`.
- `max_container_bytes` for both value writers (unbounded by default) limits the output one open container buffers. A write or close past it gives `error.ContainerTooLarge`, before any allocation.
- Wire-type hooks `zerdeDecode` (over a pull reader), `zerdeEncode` and `zerdeFree` for CBOR and JSON. `zerdeEncode` receives a streaming `Encoder` that enforces its stated lengths, nesting, UTF-8 and, when deterministic, ascending keys. An unfinished hook gives `error.HookIncomplete`. `zerde.free` leaves a type with a hook and no `zerdeFree` alone.
- `Diagnostic.detail` (`zerde.DiagnosticDetail`, `zerde.DiagnosticKind`) gives the expected and found kind, the bounds or range, or the missing, duplicate or unknown field; for JSON and CBOR a value's failure points at the value's first byte.

#### Fixed-layout decoding

- `zerde.wire`: `Wire(T)`, a fixed-layout (C) type generated from a schema type. It uses `Span`, `Opt` and tagged unions as `{ tag, payload }`. A bool is a `u8` checked as 0 or 1. An enum is an 8-, 16-, 32- or 64-bit integer. The module provides `decode`, `encode`, `toWire`, `fromWire`, `describe`, `Hooked(T)` and `HookedWith`.
  - `decode` reads straight into `Wire(T)` from one `*std.heap.FixedBufferAllocator`, which it restores on an error.
  - `fromWire` and `encode` take a `wire.Memory` and reject a span that is outside it, misaligned or overflowing (`Memory.resolve`).
- `wire.encodeArenaSize(Format, T, serde_cfg, read_cfg)` is the size of the arena that `wire.encode` needs for any wire value it accepts, and `wire.Limited` holds a rebuild to a read's limits. The arena of `encode` had no size function, and a wire value the caller built was bound by no limit (a list could be longer than its `max_len`, spans could alias, a span could name its own container).
- `wire.maxArenaSize(Format, T, ...)` is a compile-time upper bound, computed in 64 bits, on what `decode` allocates. `decode` rejects text over twice `max_input_bytes` (`error.InputTooLarge`).
- `wire.decodeInto(Format, T, output, scratch, base, input, serde_cfg, format_cfg)` decodes into caller byte regions without an allocator. `wire.regionSizes` gives their sizes at compile time.
- `zerde.typed` is exported: the typed walk, generic over a sink. `typed.TypedSink` builds the Zig value and `wire.WireSink` builds the fixed layout.

#### Packed structs

- A `packed struct` is one integer, its backing integer, in every format and in `wire.Wire(T)` (widened to 8, 16, 32 or 64 bits, with its signedness). It was read as a struct of its fields, so a field of the type could not be read and `Wire(T)` did not compile for a type that held one. A read refuses a pattern the type does not define with `error.InvalidValue` (a set `_` bit, an exhaustive enum field that names no tag, the same in a nested packed struct); a number too wide for the backing integer is `error.IntegerOverflow`. `wire.fromWire` refuses with `error.InvalidValue` (`wire.Error`). The type's own `check` runs after the read. Hooks win.
- A packed struct with a `packed union` field, or with a `usize`, `isize`, C integer or enum-of-those field (in it or in a packed struct nested in it), is a compile error, as is a backing integer of more than 64 bits on the wire, a bound on a field that holds one, and a struct-only option (`rename_all`, `fields`, `extras`, `omit_null_fields`, `deny_unknown_fields`, `field_order`, `declared_in_order`) in the packed type's `serde`.
- `reflect.kindOf` gives `.@"packed"` and `reflect.backing(T)` its integer type.
- `zig build test` compiles the sources in `tests/compile_fail` and expects each to fail with the error its table in `build.zig` names.

#### Raw validators

- `serde.fields.<f>` option `validate_bytes` (with `validate`): the most bytes a `Raw` validator allocates for one item. Every read runs the validator on a block of that size taken from its allocator and given back after the call, so a validator that needs more fails with `error.OutOfMemory`, also in a typed read. A wire read takes the block from the reader's scratch region (`decodeInto`, `decode`) or from the end of the output (`Resumable`, `StreamResumable`), and `regionSizes`, `resumableRegionSizes`, `streamRegionSizes` and `maxArenaSize` count the largest one.
- `cbor.validateScratch(n)`, `cbor.pullReaderScratch(cfg, n)` and `json.pullReaderScratch(cfg, n)` are the bytes that `cbor.validate`, and a validator that reads an item of at most `n` bytes with `cbor.pullReader` or `json.pullReader`, take. They use the list-growth rule of the arena bounds (`sizing.growth`), as `.raw` fields do. `cbor.itemScratch` and `json.itemScratch` are the terms of a lenient CBOR and a JSON `Raw` that the size functions use.

#### Chunked and windowed I/O

- `zerde.resumable.Decoder(T, serde_cfg, cbor_cfg)` (`Reading(Sink, ...)` for another layout) reads strict CBOR that arrives in chunks (`feed`, `finish`). For every way the input is cut, it returns the value or error of the whole-input strict read. A struct must set `deny_unknown_fields`. Nothing is freed on an error, so the allocator must be an arena or a fixed buffer. `zerde.chunk.Reader`, `bulk.Utf8Stream` and `cbor.verifyStrict` support it.
- `wire.Resumable(T, serde_cfg, cbor_cfg)` runs the resumable decode into `wire.Wire(T)` in a caller region. Its bounds are `wire.resumableRegionSizes` and `wire.maxResumableArenaSize`.
- `wire.StreamResumable(T, serde_cfg, cbor_cfg)` runs the resumable decode but leaves text and byte strings in the stream; a span is a stream position. Its bounds are `wire.streamRegionSizes` and `wire.maxStreamArenaSize`.
- `zerde.resumable.Writer(Format, T, serde_cfg, format_cfg)` writes a typed value as JSON or CBOR in fixed windows with a caller-owned cursor (`fill(value, window)`). The bytes equal those of `serializeWith`. `min_window` is the smallest window that always makes progress. Extras, encode hooks and the sequence fast path are compile errors in a resumable write.
- `zerde.resumable.Render(json_cfg)` renders stored strict CBOR as JSON in windows (`fill(stored, window)`). The output equals that of the strict pull reader into `json.valueWriter`. The first window checks the whole item, so nothing is written for an item that cannot be rendered.
- `zerde.gather` (`encode`, `assemble`, `Ref`) writes a CBOR frame as a skeleton plus references to the byte strings and `Raw` items of at least `min_len` bytes that it leaves out. It uses caller regions and no allocator. `typed.serializeInto` takes a serializer the caller made.
- `zerde.bulk`: word- and vector-at-a-time scans for the end of a JSON string, escaping by runs, and UTF-8 validation. The JSON and CBOR backends use them. Run `zig build bench-bulk` to benchmark them.

### Changed

- CBOR under `deny_unknown_fields` without `extras` rejects an undeclared struct key as it is read (`error.UnknownField`), without checking or recording it.
- JSON no longer converts a number it skips, so a skipped field accepts a number too large for any type.
- TOML and YAML parse failures report the failing input offset in `Diagnostic`.
- YAML writes an empty array as `[]` and reads an empty document as an empty struct.
- JSON struct field names, union keys, bare variant names and enum names are matched where they are read, in a stack buffer as long as the longest declared name, without allocation. ZON reads an enum name the same way.
- A rewritten string (a JSON string with an escape, a chunked CBOR string, bytes decoded from base64) is measured first and written once into an allocation of exactly its length. A skipped chunked CBOR string is checked and not buffered.
- CBOR and JSON write struct field names and enum names as bytes made at compile time and check them as UTF-8 then, not on every write.
- The JSON reader checks a string as UTF-8 only when the scan for its end saw a byte of 0x80 or above, so ASCII text takes one pass.
- The CBOR reader decides strict mode and the `max_items` count at compile time. A read config that names neither `mode` nor `max_items` carries no per-head check.

### Fixed

- JSON: `-0` read into an unsigned integer is 0. It was `error.IntegerOverflow`.
- A fixed-length array of elements that own memory (`[2][]const u8`) leaked the elements already read when a later one failed. A slice whose allocation failed leaked the same way.
- `parseSliceAliasedWith` ignored every read option except `max_input_bytes`.
- Named `ReadConfig` values (`json.ReadConfig{ .borrow_strings = true }`) compile. Only anonymous literals did.
- BSON: a dynamic `Value` can be read from a document. The root had no kind.
- The ZON reader freed memory twice when a document had compile errors.
- The rebuild walks that the sizes use (`check` and `encode`) count a sorted map as one container, as a read does, and apply the `elem` bound of the field that holds it to each entry's value. A struct with a `check` below a sorted map, at `max_depth`, was missed.
- Under a wire decode a `Raw` validator ran with the output region as its allocator, which no size counted: the README's own validator (a pull reader is some 8 KB) failed on the first item with `error.OutOfMemory`. It now runs on a block of `validate_bytes` from the scratch region, or from the end of the output in a resumable read. `json.Raw` decoded an escaped string or member name into the output as it checked it; it now uses the reader's memory, as `cbor.Raw` does, and the JSON scratch size counts those strings.
- The arena bound of a list that draws on the shared `max_items` budget (`regionSizes`, `maxArenaSize`, the resumable sizes, `encodeArenaSize`) ignored the element size of the lists nested below it, so a larger nested list could exceed the bound; it also dropped the largest `validate_bytes` below such a list. Both are counted now.
- The documented bound of a wire decode (`wire.regionSizes`, `resumableRegionSizes`, `streamRegionSizes`, `maxArenaSize`) was not enough for a type with a struct `check`. The check runs on a typed copy that the sink rebuilds in the output region once the read has filled it, and no size counted that rebuild (a list of non-scalar elements can take twice its wire size). Each size now adds the largest rebuild over the structs with a `check`, so a region of the documented size is enough; the sizes grow for such a type. A stream read checked the wrong bytes of a text that stays in the stream; see Breaking.

## 0.1.0

First public release of `zerde`.

- added a comptime-specialized typed serialization layer for Zig structs, enums, arrays, slices, optionals, and scalar values
- added format backends for binary, BSON, CBOR, JSON, MessagePack, TOML, and YAML behind one shared typed API
- added owned, arena-backed, and aliased slice parse entrypoints, plus recursive cleanup helpers for owned decode paths
- added wasm/WASI helpers for pointer+length interop and format-aware parsing and serialization inside wasm modules
- added structured parse diagnostics with field-path and input-location reporting
- added corpus-driven roundtrip tests across all supported formats
- added per-format benchmark suites and benchmark history, including comparisons against standard-library or ecosystem baselines where available
- added CI, benchmark, and tag-based release workflows for GitHub Actions
