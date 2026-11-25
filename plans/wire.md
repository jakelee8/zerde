# Wire: fixes from a downstream prototype

A downstream use of zerde found three problems: a packed struct cannot be
read as a field (design 3's `Flags` spelling); `regionSizes` does not count the rebuild for a `check` (the prototype adds
`checkPeak`) and has no encode-arena bound; `.validate` on a `Raw` returns `OutOfMemory` under `wire.decodeInto`. The proposals below are a packed struct as its
backing integer, a `check` term in the region sizes, the read limits as a new `wire.encode` parameter, and validators run
on a region `regionSizes` reserves.

Each item states the problem with evidence, the design, what is open, and what would accept it. One branch, one commit
per item, in the order below; (b) and (c) both edit `computeSizes`, so (c) starts from (b)'s reviewed tip.

## (a) A packed struct is one integer

**Problem.** No walk has a packed-struct case; each treats it as a struct of named fields.
- Read: `deserializeValue` sends it to `deserializeStruct` (`src/typed.zig:979-988`, `1522`), which wants an object with
  every field, the padding `_: u6` included (`fillField`, `typed.zig:1888-1907`, `error.MissingField`); an integer is
  refused (`src/cbor.zig:770-772`, `src/json.zig:611-614`).
- `Wire(T)` builds one extern member per field (`StructWire`, `src/wire.zig:128-137`), so `_: u6` reaches the integer
  rule, which takes only 8, 16, 32 and 64 bits (`wire.zig:79-88`): a compile error for any type holding the field.
- Write, `reflect.fields` (`src/reflect.zig:101-125`), `meta.applyCase` (`src/meta.zig:274`, `337`: `_` becomes `""`
  under `rename_all`), the resumable key and frame counts (`src/resumable.zig:92-101`, `137`, `167-178`), and TOML/YAML
  (`src/toml.zig:388-391`, `src/yaml.zig:423`, a table) all list `_` as a member.

**Design.** A `packed struct` is a scalar whose value is its backing integer, as an enum is its number under
`enum_repr = .integer`, and as `std.Io.Writer` prints one (`lib/std/Io/Writer.zig:976-977`).
- Write `@backingInt(value)` through `emitInteger`. Read an integer of the backing type and `@fromBackingInt` it; any bit
  that belongs to a field named `_` must be zero, else `error.InvalidValue` (the name of the existing error the
  implementer finds closest to the enum's refusal of an unknown number; one error, documented).
- `Wire(T)` of a packed struct is `Wire(Backing)`; `toWire`/`fromWire`/`describe` and `WireSink` treat it as that
  integer, with the same padding check on `fromWire`; `typedOwned` costs it 0 and does not demand
  `deny_unknown_fields`. A backing width `Wire` has no integer for is the existing compile error.
- `reflect.kindOf` is `.int` (its `intRange` is the backing type's), so generators see one integer.
- TOML and YAML write and read it as an integer; the resumable counts treat it as a scalar.
- One predicate, `meta.isPacked(T)`, is the only place that recognises the layout; every arm above calls it.
- A field override on a packed struct field that only applies to structs (`rename_all`, `fields`) is a compile error.
  `min`/`max` bounds stay refused as for any struct (the existing compile error).

**Open.** None. The bit-for-bit form is the one the type itself defines. Text output by field name
(a `packed_repr = .fields`) is not proposed.

**Acceptance.** Round trips of a `packed struct(u8)` field with padding in every format; the wire form is the backing
integer (bytes compared); a set padding bit is refused on read and on `fromWire`; an object where the integer is due is
refused; `regionSizes` of a type holding one equals that of the same type with a `u8` field; a mutant for the padding
check and for the scalar dispatch.

## (b) `regionSizes` does not count the rebuild a `check` needs

**Problem.** `WireSink.check` (`wire.zig:505-511`) rebuilds the checked struct with `fromWire` in the output arena, runs
`check`, and gives the arena back. The rebuild allocates, for each list of non-scalar elements in the checked subtree,
`n * @sizeOf(Elem)` of the typed element (`fromWire`, `wire.zig:309`), which can be twice the wire size; text, bytes,
`Raw` and scalar lists alias and cost nothing (`wire.zig:302-303`). It runs when the read has already filled the output
for that subtree, so the region's peak is what the decode wrote plus one rebuild. `computeSizes` (`wire.zig:908-946`)
never counts it, and the documented guarantee that a region of `regionSizes().output` is enough for any input
(`wire.zig:822`, `README.md:643-646`) is false for a type with `check`. The resumable read calls the same check with the
same arena (`src/typed_resume.zig:450`).

**Design.** `computeSizes` gains a term `check` = the rebuild cost of the root, charged only when a type reachable from
the root declares `check`, else 0. It is `typedOwned`'s list algebra with typed element sizes, exact allocation (no
growth: `fromWire` allocates each list once), and text, bytes, `Raw` and scalar lists at 0. `output` becomes
`lists + text + check + slack`, for `regionSizes`, `resumableRegionSizes` and `maxArenaSize`. A nested check's rebuild is
no larger than the root's and each rebuild is given back before the next, so one term bounds them all.

**Defect found on the same path: `StreamResumable` checks the wrong bytes.** In a stream read a text or byte string
stays in the stream and its span holds a stream offset (`WireSink.span`, `wire.zig:453-459`), but the check's rebuild
resolves spans against the output region alone (`wire.zig:887-890`). So `check` reads output bytes at that offset, or
gets `error.OffsetOutOfRange`: it never sees the text. Design: a type reachable from the root that declares `check` and
holds text, bytes or `Raw` is a compile error for `StreamResumable`, with the reason in the message and the README, since
the check cannot see bytes that are still in the stream. A type whose check reads only scalars and lists keeps working.

**Open.** Whether a stream read should instead copy the text a checked struct holds into the output so `check`
can see it; that costs output bytes the stream mode exists to avoid, so it is not proposed.

**Acceptance.** A test whose checked list's typed element is larger than its wire form (for example
`struct { name: []const u8, n: u32 }`) decodes into a region of exactly `regionSizes().output` at the type's limits and
fails with `OutOfMemory` at one byte less; the same for the resumable read; the stream-mode compile error by a
compile-fail case or a `@compileError` message test as the repo already does; mutants for the new term.

## (c) `wire.encode` has no arena bound

**Problem.** `wire.encode` (`wire.zig:522-533`) rebuilds the whole value with `fromWire` in its arena and writes it; no
size function covers that arena (`README.md:649`). The writers allocate nothing else (`CborSerializer`,
`src/cbor.zig:267`, and `JsonSerializer`, `src/json.zig:112-118`, hold no allocator). A wire value the caller built is not
bounded by any limit: `Memory.resolve` checks a span's region and alignment only (`wire.zig:190-206`), so a list may be
longer than its `max_len`, and spans may alias, so one array can be rebuilt many times.

**Design.** `encode` takes the read limits as a new comptime parameter, `read_cfg` (the config a decode of the same type
uses: `max_items`, each field's `max_len`), after `format_cfg`. As `fromWire` rebuilds for `encode` it refuses a list
longer than its field's `max_len` (`error.LengthOutOfBounds`) and counts every element it rebuilds against `max_items`
(`error.TooManyItems`), so aliasing and a span that names its own container are bounded too. A new
`encodeArenaSize(Format, T, serde_cfg, read_cfg)` returns the rebuild cost of (b)'s algebra over the whole of `T`, and a
region of that size is enough for any wire value `encode` accepts. `WireSink.check` keeps calling `fromWire` without the
counting, since a decoded value is already within its limits; the counting is a parameter of `fromWire`, not a copy.

**Open.** The alternative to the new parameter is to write straight from the wire layout with `describe`, which
needs no arena but repeats the write rules the module keeps in one place (`wire.zig:1-30`); the new parameter is proposed.

**Acceptance.** `encode` of a value built at the limits fits in exactly `encodeArenaSize` and fails at one byte less; a
list longer than its `max_len`, and a value whose spans alias past `max_items`, are refused; existing encode tests pass
the new parameter; README and CHANGELOG state the new parameter and size function; mutants for both refusals.

## (d) A `Raw` validator under `wire.decodeInto` takes the output region

**Problem.** `readRawSlice` calls `validate(allocator, token.bytes)` with the typed walk's allocator (`typed.zig:1517`),
which under `decodeInto` is the output region (`wire.zig:394-419`), and `computeSizes`' `.raw` arm reserves nothing for
it (`wire.zig:966-983`). The built-in `cbor.validate` records map keys there (`cbor.zig:1695-1703`), and the validator the
README shows (`README.md:321-326`) starts with `allocator.create(CborDeserializer)`, about 7 KB with its 128-entry stack
(`cbor.zig:536`), so it fails on the first `Raw`. `Bounds.validate` is a function pointer (`meta.zig:84`), whose cost no
size function can derive. The same arm has a smaller copy: `json.readRaw` passes the walk's allocator to `skipValue`
(`json.zig:770-776`), which decodes an escaped string into it and frees it.

**Design.**
- A field option `validate_bytes: usize` states the most bytes the validator allocates for one item. Under a wire decode
  a `validate` without `validate_bytes` is a compile error; the typed (non-wire) read keeps accepting it as today.
- `readRawSlice` runs the validator on a `FixedBufferAllocator` of `validate_bytes` taken from the reader's own scratch
  for the call and given back after it, so the cost does not grow with the number of items. `computeSizes` adds the
  largest `validate_bytes` reachable from the root to `scratch`. The typed read without a wire region keeps passing its
  allocator.
- `cbor` and `json` export the scratch their own validators need as a comptime function of a read config
  (`cbor.validateScratch(cfg)`, and the size of a pull reader for the README form), so a caller can state
  `validate_bytes` without guessing.
- `json.readRaw` uses the reader's own allocator, as `cbor.readRaw` does (`cbor.zig:717-722`), so a `json.Raw` takes
  nothing from the output.

**Open.** Whether a validator that allocates should be allowed under a wire decode at all; the alternative is a
compile error for any `validate` there, which keeps the API smaller but drops the README's own example.

**Acceptance.** `decodeInto` of a list of `Raw` items with the README validator and with `cbor.validate` succeeds in
regions of exactly `regionSizes()` and fails with `OutOfMemory` at one byte less of scratch; a validator that allocates
more than its `validate_bytes` fails with `OutOfMemory`, not a write past the region; a `json.Raw` with an escaped string
leaves `used` unchanged; a mutant for each new guard.

## Checks

`zig build test`, `python3 tests/mutants.py --check` and each new mutant, `zig build examples`, `zig build transcode`,
`zig build bench-build -Doptimize=ReleaseFast`, native and wasm32 `build-lib`. The wire benchmark (`zig build bench-wire
-Doptimize=ReleaseFast`) and `bench/WIRE.md` only if (a) to (d) change its rows; none of its types holds a `check`, a
packed struct or a validator (`bench/wire.zig`), so none is expected.
