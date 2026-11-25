# Wire: fixes from a downstream prototype

A prototype of a downstream use of zerde found three problems:

- A packed struct cannot be read as a field.
- `regionSizes` does not count the rebuild for a `check`, and has no encode-arena bound.
- `.validate` on a `Raw` returns `OutOfMemory` under `wire.decodeInto`.

The fixes are:

- Treat a packed struct as its backing integer.
- Add a `check` term to the region sizes.
- Pass the read limits to `wire.encode` as a new parameter.
- Run validators on a region that `regionSizes` reserves.

Line numbers are those of `aaaf864`.

Each item states the problem with evidence, the design, open questions, and acceptance criteria. Each item is one branch
with one commit, in the order below. Items (b) and (c) both edit `computeSizes`, so (c) starts from the reviewed tip of
(b).

## (a) A packed struct is one integer

**Problem.** No walk has a packed-struct case. Each walk treats a packed struct as a struct of named fields.
- Read: `deserializeValue` sends it to `deserializeStruct` (`src/typed.zig:979-988`, `1522`). That function wants an
  object with every field, including the padding `_: u6` (`fillField`, `typed.zig:1888-1907`, `error.MissingField`). An
  integer is refused (`src/cbor.zig:770-772`, `src/json.zig:611-614`).
- `Wire(T)` builds one extern member per field (`StructWire`, `src/wire.zig:128-137`). So `_: u6` reaches the integer
  rule, which accepts only 8, 16, 32 and 64 bits (`wire.zig:79-88`). Any type that holds the field fails to compile.
- These places list `_` as a member:
  - the write walk;
  - `reflect.fields` (`src/reflect.zig:101-125`);
  - `meta.applyCase` (`src/meta.zig:274`, `337`: `_` becomes `""` under `rename_all`);
  - the resumable key and frame counts (`src/resumable.zig:92-101`, `137`, `167-178`);
  - TOML and YAML (`src/toml.zig:388-391`, `src/yaml.zig:423`, a table).

**Design.** A `packed struct` is a scalar whose value is its backing integer. An enum is its number under
`enum_repr = .integer`, and `std.Io.Writer` prints a packed struct the same way (`lib/std/Io/Writer.zig:976-977`).
- One predicate, `meta.isPacked(T)`, recognises the layout. Two functions in `meta` convert:
  - `packedToInt(T, value)` is `@backingInt(value)`.
  - `packedFromInt(T, int) !T` refuses any bit pattern the type does not define, then calls `@fromBackingInt`. The
    refused patterns are:
    - a set bit of a field named `_`;
    - a field of an exhaustive enum type whose bits name no tag;
    - the same two cases in each field of a nested packed struct, checked field by field over `field_names` at compile
      time.
  - The refusal is `error.InvalidValue`, or the existing error closest to the enum's refusal of an unknown number. One
    error is used and documented.
  - A field of any other type (integer, bool, non-exhaustive enum) defines every pattern. So `@fromBackingInt` never
    sees a value it would trap on.
  - The checks work on bits. The backing value is `@bitCast` to the unsigned integer of the same width, then masked and
    shifted per field. A signed backing is checked the same way as an unsigned one.
- Each walk tests `isPacked(T)` at its dispatch, before its struct arm, and continues with `T`'s backing integer type.
  The walks are:
  - the typed write (`typed.zig:486`) and read (`typed.zig:979`);
  - `freeTypedPartial` (`typed.zig:2114`), which frees nothing for a packed struct;
  - `deserializeBounded` (`typed.zig:1992-2002`): a packed field with a `min` or `max` bound gets its own compile error,
    which says that bounds do not apply to a packed struct, ahead of the struct arm's error;
  - the resumable write and read (`typed_resume.zig`);
  - `Wire`, `toWire`, `fromWire`, `describe`, `WireSink` and `typedOwned` (`wire.zig:75-105`, `265-271`, `330-336`,
    `604-615`, `480-481`, `1008-1014`);
  - the resumable key and frame counts (`resumable.zig:92-101`, `137`, `167-178`);
  - TOML and YAML (`toml.zig:388-391`, `yaml.zig:423`).

  The read calls `packedFromInt` on what the integer arm returns. `fromWire` does the same. No `.int` arm changes,
  because none sees the packed type.
- Hooks win. Each walk keeps its hook test first, as `reflect.kindOf` does (`reflect.zig:54`). A packed struct with
  `zerdeEncode` or `zerdeDecode` keeps using them. `isPacked` is tested after the hooks and before the struct arm.
- A packed struct's own `check` runs after `packedFromInt` on every read path: the typed read, the resumable read, and
  `fromWire` under a wire decode. It runs through the sink's existing `check` (`TypedSink.check`, `typed.zig:864-866`;
  `WireSink.check`, `wire.zig:506`), so a declared rule is never skipped. Its rebuild in (b) costs 0, because a packed
  struct holds no list.
- `reflect` gets its own kind, `.@"packed"`, and a `backing` type for it. A generator then sees one integer of that
  type. The `.int` arms that read `@typeInfo(T).int` (`grep -n '\.int\b.*=>' src/*.zig`, 25 arms) never receive a
  struct type.
- A field override that applies only to structs (`rename_all`, `fields`) is a compile error on a packed struct field.
  `min` and `max` bounds stay refused as for any struct (the existing compile error).
- On the wire, the backing integer is widened to the smallest of `u8`, `u16`, `u32` and `u64` that holds it. The
  signedness is kept: a signed backing widens to `i8` through `i64`. `std.os.linux.SCHED`, `packed struct(i32)`, has a
  signed backing. An enum's wire integer works the same way (`EnumInt`, `wire.zig:109-124`). So `packed struct(u3)` has
  a wire form, and `packed struct(i32)` keeps its negative values.
  - A backing integer wider than 64 bits is a compile error that names this rule.
  - The widening is the integer's own value (zero- or sign-extension), so the backing's bits come back unchanged.
  - `fromWire` narrows with `std.math.cast` between the two integers of the same signedness. That call refuses exactly
    a value outside the backing's range: for `u3`, a set bit above bit 2; for `i3`, anything outside -4..3. It refuses
    with the packed refusal's error, before `packedFromInt`.
  - The typed read reads the backing type itself through the integer arm. That arm refuses a number outside the type's
    range with `error.IntegerOverflow`, as it does for any integer field. The docs name both errors:
    `IntegerOverflow` for a number that is too wide, and the packed refusal for a pattern the type does not define.

**Open.** None. The bit-for-bit form is the one the type itself defines. Text output by field name
(`packed_repr = .fields`) is not included.

**Acceptance.**
- Round trips of a `packed struct(u8)` field with padding pass in every format.
- The wire form is the backing integer (bytes compared).
- Read and `fromWire` refuse:
  - a set padding bit;
  - an unnamed pattern of an exhaustive-enum field (`packed struct(u8){ mode: enum(u2){ a, b, c }, _: u6 }` with mode
    bits 3);
  - the same pattern inside a nested packed struct;
  - for a `packed struct(u3)`, a wire `u8` of `0x20` and a read number of 32.
- A `packed struct(i32)` with a negative backing value round-trips in every format and through `toWire`/`fromWire`.
- A `packed struct(i3)` refuses a wire `i8` of `-5`.
- An object where the integer is due is refused.
- `regionSizes` of a type that holds a packed struct equals that of the same type with a `u8` field.
- A packed struct with hooks is written and read by its hooks.
- A packed struct whose `check` fails is refused on the typed, resumable and wire reads.
- Mutants cover each refusal and the dispatch.

## (b) `regionSizes` does not count the rebuild a `check` needs

**Problem.** `WireSink.check` (`wire.zig:505-511`) rebuilds the checked struct with `fromWire` in the output arena, runs
`check`, and gives the arena back. The rebuild allocates `n * @sizeOf(Elem)` of the typed element for each list of
non-scalar elements in the checked subtree (`fromWire`, `wire.zig:309`). That can be twice the wire size. Text, bytes,
`Raw` and scalar lists alias and cost nothing (`wire.zig:302-303`).

The rebuild runs after the read has filled the output for that subtree. So the region's peak is what the decode wrote
plus one rebuild. `computeSizes` (`wire.zig:908-946`) never counts the rebuild. The documented guarantee that a region
of `regionSizes().output` is enough for any input (`wire.zig:822`, `README.md:643-646`) is therefore false for a type
with `check`. The resumable read calls the same check with the same arena (`src/typed_resume.zig:450`).

**Design.** `computeSizes` gains a term `check`. It is the largest rebuild cost among the types reachable from the root
that declare `check`. It is 0 when no type declares `check`, and 0 for a packed struct's own check, which rebuilds
nothing.
- A type's rebuild cost is `typedOwned`'s list algebra over that type, with typed element sizes. The allocation is
  exact, with no growth, because `fromWire` allocates each list once. Text, bytes, `Raw` and scalar lists cost 0. The
  limits that reach the type apply.
- `output` becomes `lists + text + check + slack`, for `regionSizes`, `resumableRegionSizes` and `maxArenaSize`.
- Each rebuild is given back before the next check runs, so the largest one bounds them all.

**Defect on the same path: `StreamResumable` checks the wrong bytes.** In a stream read, a text or byte string stays in
the stream, and its span holds a stream offset (`WireSink.span`, `wire.zig:453-459`). The check's rebuild resolves spans
against the output region alone (`wire.zig:887-890`). So `check` reads output bytes at that offset, or gets
`error.OffsetOutOfRange`. It never sees the text.

Design: a type reachable from the root that declares `check` and holds text, bytes or `Raw` is a compile error for
`StreamResumable`. The message and the README give the reason: the check cannot see bytes that are still in the stream.
A type whose check reads only scalars and lists keeps working.

**Open.** Whether a stream read should instead copy the text of a checked struct into the output, so that `check` can
see it. That costs output bytes, which the stream mode exists to avoid, so the design does not include it.

**Acceptance.** The region sizes are upper bounds: `computeSizes` adds a 256-byte slack and pools bounds conservatively
(`wire.zig:930`). So tests measure tightness against what a read uses, as the existing tests do
(`tests/typed_tests.zig:4487`, `7265`).

For a type whose checked list has a typed element larger than its wire form (for example
`struct { name: []const u8, n: u32 }`), at its limits:
- The decode succeeds in a region of `regionSizes().output`.
- The size is at least the observed peak, which is the decode's `used` plus the rebuild.
- The decode fails with `OutOfMemory` in a region of that peak minus one.
- The same holds for the resumable read.

The stream-mode compile error is tested by a compile-fail case or a `@compileError` message test, as the repo already
does. Mutants cover the new term.

## (c) `wire.encode` has no arena bound

**Problem.** `wire.encode` (`wire.zig:522-533`) rebuilds the whole value with `fromWire` in its arena and writes it. No
size function covers that arena (`README.md:649`). The writers allocate nothing else (`CborSerializer`,
`src/cbor.zig:267`, and `JsonSerializer`, `src/json.zig:112-118`, hold no allocator).

A wire value that the caller built is not bounded by any limit. `Memory.resolve` checks a span's region and alignment
only (`wire.zig:190-206`). So a list may be longer than its `max_len`. Spans may also alias, so one array can be rebuilt
many times.

**Design.** `encode` takes the read config as a new comptime parameter, `read_cfg`, after `format_cfg`. It is the config
that a decode of the same type uses.
- `fromWire` applies every bound the read refuses on while it rebuilds for `encode`. It uses the functions the read
  uses: `typed.checkLength` and the field and element bounds of `meta.Bounds`, `min_len` included. So any value `encode`
  writes reads back under `read_cfg`.
- It counts every element it rebuilds against `max_items` (`error.TooManyItems`). Counting rebuilt elements, not stored
  ones, bounds aliasing and a span that names its own container. Each level of nesting rebuilds at least one element,
  so `max_items` bounds the depth too.
- A new function, `encodeArenaSize(Format, T, serde_cfg, read_cfg)`, returns the rebuild cost of (b)'s algebra over the
  whole of `T`. A region of that size is enough for any wire value `encode` accepts.
- `WireSink.check` keeps calling `fromWire` without the checks, because a decoded value is already within its limits.
  The checking is a comptime parameter of `fromWire`, not a copy of it.

**Open.** The alternative to the new parameter is to write straight from the wire layout with `describe`. That needs no
arena, but it repeats the write rules that the module keeps in one place (`wire.zig:1-30`). The design uses the new
parameter.

**Acceptance.**
- `encode` of a value built at the limits succeeds in `encodeArenaSize`, which is at least its observed peak. It fails
  at that peak minus one.
- `encode` refuses a list longer than its `max_len`, a list shorter than its `min_len`, and a value whose spans alias
  past `max_items`.
- Existing encode tests pass the new parameter.
- README and CHANGELOG state the new parameter and size function.
- Mutants cover each refusal.

## (d) A `Raw` validator under `wire.decodeInto` takes the output region

**Problem.** A `Raw` validator runs with the walk's allocator on two paths, and no size counts what it takes:
- `readRawSlice` calls `validate(allocator, token.bytes)` (`typed.zig:1517`). Under `decodeInto` that allocator is the
  output region (`wire.zig:394-419`). The `.raw` arm of `computeSizes` reserves nothing for it (`wire.zig:966-983`).
- The resumable read calls `validate(allocator, bytes)` (`typed_resume.zig:158`) with the output arena.
  `resumableRegionSizes` has no scratch at all (`wire.zig:833`).

The built-in `cbor.validate` records map keys (`cbor.zig:1695-1703`). The validator that the README shows
(`README.md:321-326`) starts with `allocator.create(CborDeserializer)`. That object is about 7 KB with its 128-entry
stack (`cbor.zig:536`), so the validator fails on the first `Raw`. `Bounds.validate` is a function pointer
(`meta.zig:84`), so no size function can derive its cost.

The same arm has a smaller copy: `json.readRaw` passes the walk's allocator to `skipValue` (`json.zig:770-776`). That
function decodes an escaped string into the allocator and frees it.

**Design.**
- A field option `validate_bytes: usize` states the most bytes the validator allocates for one item. Under a wire
  decode, a `validate` without `validate_bytes` is a compile error. The typed (non-wire) read keeps accepting it as
  today.
- Both call sites run the validator on a `FixedBufferAllocator` over a block of `validate_bytes`. They give the block
  back right after the call. So growth stranded inside the block never outlives the call, and the cost does not grow
  with the number of items.
  - `readRawSlice` takes the block from the reader's own allocator. That is the `allocator` field of the deserializer,
    which `run` builds on `work`: the scratch region under `decodeInto`, and the one arena under `decode`
    (`wire.zig:368`, `416`). The block is allocated last and freed first, so the fixed-buffer allocator under it
    reclaims it. `computeSizes` adds the largest `validate_bytes` reachable from the root to `scratch`. `maxArenaSize`
    already adds `scratch` to `decode`'s one arena.
  - The resumable read has no scratch. It takes the block from the end of the output arena, with a mark and restore of
    `end_index`, as the `check` rebuild does. `resumableRegionSizes` and `streamRegionSizes` add the largest
    `validate_bytes` to `output`. Their doc line that `scratch` is empty stays true.
  - The typed read without a wire region keeps passing its allocator.
- `cbor` and `json` export the scratch their own validators need as a comptime function of a read config
  (`cbor.validateScratch(cfg)`, and the size of a pull reader for the README form). A caller can then state
  `validate_bytes` without guessing. These sizes come from the existing list-growth algebra (`growth`,
  `wire.zig:749-795`, which the `.raw` arm already uses at `wire.zig:983`), because a validator grows lists in a fixed
  buffer that can resize only its last allocation. There is no second sizing rule.
- `json.readRaw` uses the reader's own allocator, as `cbor.readRaw` does (`cbor.zig:717-722`). So a `json.Raw` takes
  nothing from the output.

**Open.** Whether a validator that allocates should be allowed under a wire decode at all. The alternative is a compile
error for any `validate` there. That keeps the API smaller but drops the README's own example.

**Acceptance.**
- `decodeInto` of a list of `Raw` items, with the README validator and with `cbor.validate`, succeeds in regions of
  `regionSizes()`. Its scratch is at least the observed peak. It fails with `OutOfMemory` at that peak minus one.
- The same holds through the resumable read with `resumableRegionSizes()`.
- A validator that allocates more than its `validate_bytes` fails with `OutOfMemory`, not a write past the region.
- A `json.Raw` with an escaped string leaves `used` unchanged.
- A mutant covers each new guard.

## Checks

- `zig build test`
- `python3 tests/mutants.py --check` and each new mutant
- `zig build examples`
- `zig build transcode`
- `zig build bench-build -Doptimize=ReleaseFast`
- native and wasm32 `build-lib`

Run the wire benchmark (`zig build bench-wire -Doptimize=ReleaseFast`) and update `bench/WIRE.md` only if (a) to (d)
change its rows. None of its types holds a `check`, a packed struct or a validator (`bench/wire.zig`), so no change is
expected.
