# Changelog

## Unreleased

- added `cbor.pullReader` and `json.pullReader`: an event reader (`zerde.Event`) over one item, with `skip`, the mode and limits of a typed read, and the duplicate-key check
- added `serde.extras` (CBOR and JSON): a `zerde.Raw` or `?zerde.Raw` field collects the unknown text-keyed members as one map, merged back in key order on write; an entry that repeats a declared member is `error.DuplicateField`
- `json.sliceDeserializer` now allocates while collecting extras, so a caller that uses it directly must call `deinit` on the result (as for `cbor.sliceDeserializer`); `parseSlice*` already does
- added field bounds (`min_len`, `max_len`, `min`, `max` in `serde.fields`; `error.LengthOutOfBounds`, `error.ValueOutOfRange`), checked before allocation where the length is known, and a struct-level `check` run after a read
- added `zerde.Raw`: a field kept as the bytes of one validated CBOR item or JSON value (checked by the read's mode and limits, written back unchanged)
- added CBOR `ReadConfig.mode` (`.lenient`, `.strict`): strict accepts only RFC 8949 §4.2.1/§4.2.2 deterministic encoding (`error.NonDeterministicEncoding`, tags refused); added `max_depth`, `max_items` and `max_string_len` limits to the CBOR and JSON readers (`error.TooManyItems`, `error.StringTooLong`)
- added integer union variant keys (`.fields = .{ .v = .{ .key = N } }` on a union; CBOR) and `enum_repr = .integer`, which writes an enum as its number and reads only a number
- added CBOR `ReadConfig.refuse_non_finite`: NaN and infinity anywhere in the input are `error.NonFiniteFloat`
- added `field_order` to the typed-layer config (`.declaration`, `.length_first`, `.bytewise`, `.encoded_key`), settable per call or per type; `.length_first` and `.bytewise` are for text keys, `.encoded_key` is the bytewise order of the encoded keys
- added CBOR `WriteConfig.deterministic`: the core deterministic encoding of RFC 8949 §4.2.1 (definite-length maps, keys in the bytewise order of their encoded form, which is right for integer and mixed keys as well as text, shortest exact float width, canonical NaN)
- added `zerde.ByteString`, a variable-length byte string: a CBOR byte string, MessagePack `bin`, BSON binary, and a JSON string in the configured `bytes` encoding; `[]const u8` stays text
- added tagged unions (`union(enum)`) for CBOR and JSON: the variant name for a variant without a payload, else a one-entry map of name and payload; other formats refuse a union at compile time
- added per-field `key` (an integer map key, CBOR) and `optional` (`.lenient`, `.nullable`, `.absent`), and nested optional struct fields (`??T`), so an absent field can differ from `null`
- added CBOR support for indefinite-length byte and text strings on read, and for tag 55799 (self-described CBOR)
- CBOR and JSON readers accept the well-formed forms a typed value can hold (RFC 8949 §5.3 for CBOR) and keep writing the same bytes. They refuse: text that is not UTF-8 (`error.InvalidUtf8`; a JSON lone surrogate escape is `error.InvalidUnicodeSurrogate`, as before); a CBOR map that repeats a key (`error.DuplicateField`, also in skipped values), with keys equal as RFC 8949 §5.6.1 defines it (`0.0` is `-0.0`, NaNs by significand, arrays, maps and tags by value); a CBOR tag other than 55799 around a typed value (`error.UnexpectedTag`); more than 128 open containers (`error.CborNestingTooDeep`; a skipped CBOR value used to recurse without a bound); a CBOR length that claims more items than the input has bytes; and a repeated JSON member in a field the type reads (`error.DuplicateField`, as before; the policy is unsettled). A BOM before JSON is refused
- a dynamic `Value` now refuses a CBOR tag (`error.UnexpectedTag`; it was dropped) and a JSON number that is not a finite double (`error.FloatOutOfRange`; it was infinity); it still refuses a CBOR map key that is not text, a simple value other than false, true and null, and a JSON integer beyond 128 bits
- `cbor.sliceDeserializer` and `cbor.readerDeserializer` now allocate while reading maps (the duplicate-key records), so a caller that uses them directly must call `deinit` on the result, also for borrowed input; `parseSlice*`, `deserialize*` and `value.parse*` already do
- a field `rename` that is not valid UTF-8 is a compile error
- BSON: a dynamic `Value` can be read from a document (the root had no kind); `value.zig`'s tests now run under `zig build test`
- an integer field no longer accepts a float with a whole value (`1.0`, `1e2`, CBOR `0xf93c00`): CBOR, JSON, MessagePack and the typed layer return `error.UnexpectedType`; it also removes a safety panic on `1e300`
- a float field refuses a finite number too large for its type (`error.FloatOutOfRange`) instead of rounding to infinity: JSON `1e999`, a CBOR double read into `f32`, a MessagePack double read into `f32`
- JSON no longer converts a number it skips, so a number too large for any type in a skipped field is fine; the JSON writer refuses NaN and infinity (`error.NonFiniteFloat`) and the `.string` byte encoding refuses bytes that are not UTF-8 (`error.InvalidUtf8`)
- a byte field is read only from a byte string, and a text field only from text: CBOR no longer reads a byte string as text or the reverse, and the typed layer, MessagePack and BSON no longer read text into a byte field (`[N]u8`, `zerde.ByteString`)
- a dynamic `Value` read from CBOR holds a byte string as bytes; it was read as text
- added JSON `WriteConfig.bytes` and `ReadConfig.bytes` to carry `[N]u8` fields as `.string`, `.base64` or `.base64url`
- CBOR writes `[N]u8` fields as byte strings, as MessagePack, BSON and the binary format do; they were text strings, which RFC 8949 requires to be UTF-8
- named `ReadConfig` values (for example `json.ReadConfig{ .borrow_strings = true }`) compile; only anonymous literals did
- ported the library, tests, examples, transcoder CLI, and benchmark harness to Zig 0.17.0; `minimum_zig_version` is now `0.17.0`
- adapted the typed reflection layer to the 0.17 `@typeInfo` shape (`field_names`, `field_types`, `field_attrs`, `attrs.@"const"`)
- adapted the ZON backend to the 0.17 `std.zig.Ast`, `Zoir`, and `std.zon.Serializer` signatures
- CI installs Zig 0.17.0
- updated the `toml` (`zig-toml`), `zbor`, and `zbench` dependencies to 0.17-compatible commits
- patched the vendored `bufzilla`, `msgpack-zig`, `zig-bson`, and `zig-yaml` benchmark baselines for 0.17
- `zig build test` now runs the corpus, invalid-input, fuzz, and property test modules; Zig only collects tests from the test root's own module, so these were not being run before
- fixed a double free in the ZON reader when a document has compile errors
- TOML and YAML parse failures now report the failing input offset in `Diagnostic`
- YAML now writes empty arrays as `[]` (inline) and reads an empty document as an empty struct
- corrected corpus fixtures: no trailing newline for JSON, YAML, and ZON, MessagePack and BSON strings encoded as str rather than bin, and YAML string arrays as block sequences

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
