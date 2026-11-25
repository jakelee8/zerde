# Changelog

## Unreleased

### Breaking

- An integer field refuses a float with a whole value (`1.0`, `1e2`, CBOR `0xf93c00`) in CBOR, JSON and MessagePack: `error.UnexpectedType`.
- A float field refuses a finite number too large for its type (JSON `1e999`, a CBOR or MessagePack double read into `f32`) instead of rounding it to infinity: `error.FloatOutOfRange`.
- A byte field (`[N]u8`, `zerde.ByteString`) is read only from a byte string and a text field only from text, in CBOR, MessagePack and BSON: `error.UnexpectedType`.
- The CBOR reader refuses text that is not UTF-8 (`error.InvalidUtf8`), a map that repeats a key at any depth, with keys equal as RFC 8949 §5.6.1 defines it (`error.DuplicateField`), a tag other than 55799 around a typed value (`error.UnexpectedTag`), more than 128 open containers (`error.CborNestingTooDeep`), and a length that claims more items than the input has bytes.
- The JSON reader refuses text that is not UTF-8: `error.InvalidUtf8`.
- JSON, MessagePack and BSON reads refuse an object that names a key twice, at any depth (`error.DuplicateField`), typed and untyped, as CBOR, TOML, YAML and ZON already did; a JSON name is compared as decoded text. A MessagePack or BSON read refuses more than 128 open containers in a value it skips (`error.MsgpackNestingTooDeep`, `error.BsonNestingTooDeep`), and a BSON read walks a sub-document it skips, every element type sized as the BSON specification defines it, where it jumped over its length: a malformed one is refused (`error.InvalidDocumentTerminator`, `error.InvalidDocumentLength`), and so is a type byte BSON does not define (`error.UnsupportedBsonType`).
- A dynamic `Value` refuses a CBOR tag (`error.UnexpectedTag`; it was dropped) and a JSON number that is not a finite double (`error.FloatOutOfRange`; it was infinity). A `Value` read from CBOR holds a byte string as bytes; it was text.
- CBOR writes a `[N]u8` field as a byte string, as MessagePack, BSON and the binary format do; it was a text string.
- The JSON writer writes a float as the shortest digits that read back to the same value, laid out as ECMAScript's `Number::toString` (RFC 8785): `1e+21`, `5e-324`; values from 1e-6 up to 1e21 are written as before.
- The JSON writer refuses NaN and infinity (`error.NonFiniteFloat`), and the JSON string and CBOR text writers, and the JSON `.string` byte encoding, refuse text that is not UTF-8 (`error.InvalidUtf8`).
- The `sliceDeserializer` and `readerDeserializer` of CBOR, JSON, MessagePack and BSON allocate while reading (key records, extras), so a caller that uses one directly must call `deinit` on it, also for borrowed input; `parseSlice*`, `deserialize*` and `value.parse*` already do.
- `cbor.CborSerializer` takes the write mode as comptime parameters after `Config`; `cbor.serializer` builds it.
- A field `rename` that is not valid UTF-8 is a compile error.

### Added

- `serde.fields.<f>` options `key` (an integer map key, CBOR) and `optional` (`.lenient`, `.nullable`, `.absent`), and nested optional fields (`??T`), so an absent field can differ from `null`.
- Field bounds in `serde.fields`: `min_len`, `max_len`, `min` and `max`, checked before allocation where the length is known and applied to union variants too (`error.LengthOutOfBounds`, `error.ValueOutOfRange`); `.elem` bounds each element of an array field; a struct-level `check` runs after a read.
- `serde.field_order` (`.declaration` by default, `.length_first`, `.bytewise`, `.encoded_key`), per call or per type.
- `serde.declared_in_order`: the fields are declared in CBOR encoded-key order, a compile error otherwise, and a strict read of the type is a merge walk over fields and keys.
- `serde.extras` (CBOR and JSON): a `cbor.Raw` or `json.Raw` field, or an optional one, collects the unknown text-keyed members as one map and merges them back in key order on write; an entry that repeats a declared member is `error.DuplicateField`.
- Tagged unions (`union(enum)`) for CBOR and JSON: the variant name for a variant without a payload, else a one-entry map of name and payload; integer variant keys (`.fields = .{ .v = .{ .key = N } }`, CBOR). Other formats refuse a union at compile time.
- `serde.enum_repr = .integer`: an enum is written as its number and read only from a number.
- `zerde.ByteString`, a variable-length byte string: a CBOR byte string, MessagePack `bin`, BSON binary, or a JSON string in the configured `bytes` encoding; `[]const u8` stays text.
- JSON `WriteConfig.bytes` and `ReadConfig.bytes` (`.string` by default, `.base64`, `.base64url`) for byte fields; a base64 field that does not decode is `error.InvalidBytes`.
- `cbor.Raw` and `json.Raw`: a field kept as the bytes of one validated item (checked by the read's mode and limits, at any depth, and refusing an object that names a member twice, `error.DuplicateField`) and written back unchanged; a write checks each `Raw` and extras item it puts out, and a deterministic CBOR write refuses one that is not deterministic. A `Raw` of one format cannot be written in another. `.validate = fn (allocator, bytes) !void` in `serde.fields` runs after the read has checked the item.
- CBOR `ReadConfig.mode` (`.lenient` by default, `.strict`): strict accepts only the RFC 8949 §4.2.1/§4.2.2 deterministic encoding (`error.NonDeterministicEncoding`) and refuses tags; an enum written as its number where the type writes its name is `error.NonDeterministicEncoding`, in the slice and the resumable read. Its repeated-key check compares neighbours and allocates nothing, also in a `Raw` and in skipped values; a key that is an array or map holding a float zero is `error.NonDeterministicEncoding`.
- Read limits `max_depth` (128 by default and at most, a compile error above), `max_items` and `max_string_len` (unbounded by default) for CBOR and JSON: `error.TooManyItems`, `error.StringTooLong`.
- CBOR `ReadConfig.refuse_non_finite` (default `false`): NaN and infinity anywhere in the input are `error.NonFiniteFloat`.
- CBOR `ReadConfig.refuse_negative_zero` (default `false`): a float -0 of any width, also in skipped values, keys and a `Raw`, is `error.NegativeZero`.
- CBOR `WriteConfig.normalize_negative_zero` (default `false`): the typed, value, hook and resumable writers write a float zero as +0, and `cbor.canonicalizeWith` / `cbor.canonicalizeIntoWith` take the write options; a typed or hook write refuses a `Raw` or extras item that holds -0.0.
- CBOR `WriteConfig.deterministic` (default `false`): the core deterministic encoding of RFC 8949 §4.2.1 (definite lengths, keys in the bytewise order of their encoding, shortest exact float width, canonical NaN).
- CBOR indefinite-length byte and text strings on read, and tag 55799 (self-described CBOR).
- JSON `ReadConfig.integral_numbers` (default `false`): an integer field takes `1.0`, `1e2`, `12300e-2` when the number's exact decimal value is an integer in range; a fraction left is `error.UnexpectedType`, out of range `error.IntegerOverflow`.
- `trusted_text` in the CBOR and JSON read and write configs (default `false`): skips the UTF-8 check of text known to be valid; see `bench/BULK.md`.
- `cbor.canonicalize` (the deterministic form of an item) and `cbor.validate`.
- `cbor.canonicalizeInto(dst, scratch, bytes)` and `cbor.canonicalScratchSize(n)`: `canonicalize` into caller buffers with no allocator; the result is never longer than the input, and a map key that is an array or map is `error.UnexpectedType`.
- `cbor.pullReader` and `json.pullReader`: an event reader (`zerde.Event`) over one item, with `skip`, `raw()` (the next item whole), `readTyped`, the mode and limits of a typed read, and the repeated-key check.
- `cbor.valueWriter` and `json.valueWriter`: a writer for runtime-defined values with `writeEvent`, definite CBOR lengths, maps sorted on close (CBOR deterministic: encoded-key order; JSON: length-first `sort_keys`), and `error.DuplicateField` for a repeated key.
- `max_container_bytes` for `cbor.valueWriter` and `json.valueWriter` (unbounded by default): the most output one open container buffers; a write or close past it is `error.ContainerTooLarge`, decided before any allocation.
- Wire-type hooks `zerdeDecode` (over a pull reader), `zerdeEncode` (over a streaming `Encoder` that enforces its stated lengths, nesting, UTF-8 and, when deterministic, ascending keys) and `zerdeFree`, for CBOR and JSON; `error.HookIncomplete`. A type with a hook and no `zerdeFree` is left alone by `zerde.free`.
- `zerde.SortedMap(V)`: a map with text keys as a slice of entries sorted by encoded key, with binary-search `get`, `getPtr` and `index`, `max_len` and `.elem` bounds, and the wire layout `{ entries: Span }`. Every read refuses a repeated key (`error.DuplicateField`); a strict CBOR read also refuses a key that does not sort after the one before it (`error.NonDeterministicEncoding`), and any other read (lenient CBOR, JSON) sorts the entries; a write refuses entries out of order. The serializers write a map entry's key between `beginMapEntry` and `endMapKey`.
- `zerde.wire`: `Wire(T)`, a fixed-layout (C) type generated from a schema type, with `Span`, `Opt` and tagged unions as `{ tag, payload }`; `decode`, `encode`, `toWire`, `fromWire`, `describe`, `Hooked(T)` and `HookedWith`. `decode` reads straight into `Wire(T)` from one `*std.heap.FixedBufferAllocator`, restored on an error; `fromWire` and `encode` take a `wire.Memory` and refuse a span outside it, misaligned or overflowing (`Memory.resolve`). A bool is a `u8` checked as 0 or 1, and an enum is an 8-, 16-, 32- or 64-bit integer.
- `wire.maxArenaSize(Format, T, ...)`: an upper bound at compile time on what `decode` allocates, computed in 64 bits; `decode` refuses text over twice `max_input_bytes` (`error.InputTooLarge`).
- `wire.decodeInto(Format, T, output, scratch, base, input, serde_cfg, format_cfg)` decodes into caller byte regions with no allocator, and `wire.regionSizes` gives their sizes at compile time.
- `zerde.resumable.Decoder(T, serde_cfg, cbor_cfg)` (`Reading(Sink, ...)` for another layout): reads strict CBOR that arrives in chunks (`feed`, `finish`), with the value or the error of the whole-input strict read for every way the input is cut. A struct must `deny_unknown_fields`, and nothing is freed on an error, so the allocator is an arena or a fixed buffer. `zerde.chunk.Reader`, `bulk.Utf8Stream` and `cbor.verifyStrict` serve it.
- `wire.Resumable(T, serde_cfg, cbor_cfg)`: the resumable decode into `wire.Wire(T)` in a caller region, with its bound `wire.resumableRegionSizes` / `wire.maxResumableArenaSize`.
- `wire.StreamResumable(T, serde_cfg, cbor_cfg)`: the resumable decode that leaves text and byte strings in the stream (a span is a stream position), with `wire.streamRegionSizes` and `wire.maxStreamArenaSize`.
- `zerde.resumable.Writer(Format, T, serde_cfg, format_cfg)`: a typed value written as JSON or CBOR in fixed windows with a caller-owned cursor (`fill(value, window)`), the same bytes as `serializeWith`; `min_window` is the smallest window that always makes progress. Extras, encode hooks and the sequence fast path are compile errors in a resumable write.
- `zerde.resumable.Render(json_cfg)`: renders stored strict CBOR as JSON in windows (`fill(stored, window)`), byte for byte what the strict pull reader into `json.valueWriter` writes; the first window checks the whole item, so nothing is written of an item that cannot be rendered.
- `zerde.gather` (`encode`, `assemble`, `Ref`): a CBOR frame as a skeleton plus references to the byte strings and `Raw` items of at least `min_len` bytes it leaves out, into caller regions with no allocator; `typed.serializeInto` takes a serializer the caller made.
- `zerde.typed`, exported: the typed walk, generic over a sink (`typed.TypedSink` builds the Zig value, `wire.WireSink` the fixed layout).
- `zerde.bulk`: word- and vector-at-a-time scans for the end of a JSON string, escaping by runs, and UTF-8 validation, used by the JSON and CBOR backends; `zig build bench-bulk`.
- `zerde.reflect`: comptime reflection of fields, write order, union variants and enums, for generators.
- `tests/mutants.py`: the mutants the tests must kill; `--check` lists patterns the source no longer contains.

### Changed

- A struct field name (JSON), a union key, a bare variant name and an enum's name are matched where they are read, in a stack buffer as long as the longest declared name, and are not allocated; ZON reads an enum name the same way.
- A rewritten string (a JSON string with an escape, a chunked CBOR string, bytes decoded from base64) is measured first and written once into an allocation of exactly its length; a skipped chunked CBOR string is checked and not buffered.
- CBOR: under `deny_unknown_fields` without `extras`, an undeclared struct key is refused as it is read (`error.UnknownField`), without being checked or recorded.
- JSON no longer converts a number it skips, so a number too large for any type in a skipped field is accepted.
- Ported the library, tests, examples, transcoder CLI and benchmark harness to Zig 0.17.0; `minimum_zig_version` is `0.17.0`, and CI installs it.
- Adapted the typed reflection layer to the 0.17 `@typeInfo` shape and the ZON backend to the 0.17 `std.zig.Ast`, `Zoir` and `std.zon.Serializer` signatures.
- Updated the `toml` (`zig-toml`), `zbor` and `zbench` dependencies to 0.17-compatible commits, and patched the vendored `bufzilla`, `msgpack-zig`, `zig-bson` and `zig-yaml` benchmark baselines for 0.17.
- `zig build test` runs the corpus, invalid-input, fuzz, property and `value.zig` test modules; Zig collects tests only from the test root's own module, so these were not run before.
- TOML and YAML parse failures report the failing input offset in `Diagnostic`.
- YAML writes an empty array as `[]` and reads an empty document as an empty struct.
- Corrected corpus fixtures: no trailing newline for JSON, YAML and ZON, MessagePack and BSON strings encoded as str rather than bin, and YAML string arrays as block sequences.

### Fixed

- JSON: `-0` read into an unsigned integer is 0; it was `error.IntegerOverflow`.
- A fixed-length array of elements that own memory (`[2][]const u8`), and a slice whose allocation failed, leaked the elements already read when a later one failed.
- `parseSliceAliasedWith` ignored every read option but `max_input_bytes`.
- Named `ReadConfig` values (`json.ReadConfig{ .borrow_strings = true }`) compile; only anonymous literals did.
- BSON: a dynamic `Value` can be read from a document; the root had no kind.
- The ZON reader freed twice when a document had compile errors.

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
