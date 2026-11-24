# Changelog

## Unreleased

- changed (CBOR): under `deny_unknown_fields` without `extras`, a struct key no field declares is refused as it is read, without being checked or recorded (a chunked one was allocated)
- changed: a union's key, a bare variant name, an enum's name and (in JSON) a struct's field name are matched where they are read, into a stack buffer as long as the longest declared name, and are not allocated: an escaped JSON key or a chunked CBOR key used to be allocated and stranded in the arena behind its payload (`readStringShort`, `nextObjectKeyShort`, JSON `nextObjectFieldIndex` and `unknownKey`); `cbor.nextObjectKey` and `typed.ObjectKey` are gone. `maxArenaSize` has no term for union keys (the previous round's open-union charge is removed, and with it the open_unions and name_len fields)
- changed (`zerde.wire.maxArenaSize`): it takes the `Format` first, like `decode`, so a strict CBOR config is strict only for CBOR (`mode` is a compile error for another format; a JSON read with it had no text charged and could run out of arena); limits absent from the config are `null`, not a target-dependent sentinel
- fixed (`zerde.wire.maxArenaSize`): a CBOR read keeps a key record per open union map, now charged (eight nested unions ran out of an arena of exactly the bound); a type that recurses is charged down to `max_depth`; `Wire` refuses a pointer, which sent the compiler into endless recursion on a recursive type
- fixed (`zerde.wire.maxArenaSize`): the arithmetic is in 64 bits (it overflowed a 32-bit `usize` on wasm32 for 4,096-item lists and 4 MiB strings) and `zig build test` compiles a probe for wasm32; the typed copy and the wire copy of the same budget items are added, not taken as the most; a strict CBOR read (`mode = .strict` in the format config) is charged no rewritten text and exact list sizes
- fixed: a bound on a union variant (`serde.fields.<variant>`, such as `max_len` on a `Raw` payload) is applied by the typed read, which ignored it, and by the arena bound; `reflect.variants` reports it
- fixed (`zerde.wire.maxArenaSize`): the bound now adds the most one rewritten string takes while its buffer grows (half again and 128 bytes over its length), so a string over about 260 bytes fits an arena of exactly the bound; its doc states one rule for the text cap
- fixed (`zerde.wire`): a bool is a `u8` checked as 0 or 1 on `fromWire` and `encode`, and a list of bools is converted, not aliased (an invalid bool byte was accepted)
- changed (`zerde.wire.maxArenaSize`): lists with no bound of their own share the `max_items` budget instead of multiplying per level; only rewritten text and the reader's key scratch are charged, text at most twice `max_input_bytes`, which `decode` now enforces (`error.InputTooLarge`); an array list's growth is computed from the standard library's capacities; adversarial tests decode into an arena of exactly the bound
- fixed (JSON): `max_len` of a string or bytes field is applied while an escaped string is built (`readStringMax`, `readByteTokenMax`), so it is `error.LengthOutOfBounds` and not an arena that ran out
- `wire.Memory.resolve` takes its size and alignment at comptime
- changed: `bulk.findStringSpecial` scans a vector of bytes where the target has vectors (`findStringSpecialWords` elsewhere), and `bulk.writeEscaped` writes each escape into the writer's spare buffer; real-text numbers in `bench/BULK.md` (escape 1.4-2x on native, 1.6x on wasm with simd128)
- changed (`zerde.wire`, unreleased): `decode` takes a `*std.heap.FixedBufferAllocator` and restores it on an error; `fromWire` and `encode` take a `wire.Memory` (base and valid ranges) and refuse a span outside it, misaligned or overflowing; an enum is an 8-, 16-, 32- or 64-bit integer, and `usize`, C types and odd widths are a compile error; a list of scalars is not copied; added `maxArenaSize` and `HookedWith`
- added `tests/mutants.py --check`, which lists patterns the source no longer contains; 9 stale mutants removed and 11 re-pointed
- added `zerde.wire`: `Wire(T)`, a fixed-layout (C) type generated from a schema type, with `Span`, `Opt`, tagged unions as `{ tag, payload }`; `decode`, `encode`, `toWire`, `fromWire`, `describe` (offsets of every member), and `Hooked(T)` for a decode hook; `PullReader.readTyped` and `userData`, a `user_data` word on the CBOR and JSON deserializers, and `zerde.typed` exported
- fixed: a type with a `zerdeDecode` or `zerdeEncode` hook and no `zerdeFree` was walked into by `zerde.free`; it is left alone, as documented
- added `reader.raw()` to both pull readers (the next item whole, as its bytes) and `.validate = fn (allocator, bytes) !void` for a `Raw` field in `serde.fields`, run after the read has checked the item
- added `.elem` in `serde.fields`: the bounds (`min_len`, `max_len`, `min`, `max`, and an `elem` of their own) of each element of an array field
- added `trusted_text` to the CBOR and JSON read and write configs: skip the UTF-8 check of text for an item that is known to be valid (escapes, control characters, mode and limits are still checked); `bench/BULK.md` has the cost it removes
- changed: a write checks every `Raw` and extras value it puts out as it is (well-formed, UTF-8, nesting), and a deterministic CBOR write refuses one that is not deterministic; added `cbor.canonicalize` (the deterministic form of an item) and `cbor.validate`; the encode hook `Encoder` now enforces its stated lengths, the nesting bound, UTF-8, raw items and, in a deterministic write, ascending keys, and has `finish`
- fixed: the CBOR text writer and the JSON string writer refuse text that is not UTF-8, as the readers do
- fixed: `parseSliceAliasedWith` ignored the read configuration but `max_input_bytes`
- fixed: a decode hook that stopped short, and a slice element when an allocation failed, leaked; `max_len` stopped nothing before a chunked CBOR string was joined; a `max_depth` above 128 was clamped, it is now a compile error
- changed: `zerde.Raw` is `cbor.Raw` and `json.Raw`, so a Raw cannot be written in the other format

- added `zerde.bulk`: word-at-a-time scans for the end of a JSON string, escaping by runs, and UTF-8 validation, used by the JSON and CBOR backends; 3 to 5 times faster scanning and escaping, and 4 times faster validation of ASCII text on WebAssembly without SIMD; `zig build bench-bulk`
- added `zerde.reflect`: comptime reflection of fields (wire keys, kinds, bounds, optional policies, defaults, extras), write order, union variants and enums, for generators
- added wire-type hooks `zerdeDecode` (over a pull reader), `zerdeEncode` (over a streaming `Encoder`) and `zerdeFree`, for CBOR and JSON; `error.HookIncomplete`; `cbor.PullReader` and `json.PullReader` now hold a pointer to their deserializer
- added `cbor.valueWriter` and `json.valueWriter`: a writer for runtime-defined values with `writeEvent`, definite CBOR lengths, maps sorted on close (CBOR with `deterministic`: encoded-key order and shortest floats; JSON: length-first `sort_keys`) and `error.DuplicateField` for a repeated key
- added `cbor.pullReader` and `json.pullReader`: an event reader (`zerde.Event`) over one item, with `skip`, the mode and limits of a typed read, and the duplicate-key check
- added `serde.extras` (CBOR and JSON): a `cbor.Raw` or `json.Raw` field, or an optional one, collects the unknown text-keyed members as one map, merged back in key order on write; an entry that repeats a declared member is `error.DuplicateField`
- `json.sliceDeserializer` now allocates while collecting extras, so a caller that uses it directly must call `deinit` on the result (as for `cbor.sliceDeserializer`); `parseSlice*` already does
- added field bounds (`min_len`, `max_len`, `min`, `max` in `serde.fields`; `error.LengthOutOfBounds`, `error.ValueOutOfRange`), checked before allocation where the length is known, and a struct-level `check` run after a read
- added `cbor.Raw` and `json.Raw` (one `typed.RawOf(format)` each, so a Raw cannot be written in another format): a field kept as the bytes of one validated CBOR item or JSON value (checked by the read's mode and limits, written back unchanged)
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
