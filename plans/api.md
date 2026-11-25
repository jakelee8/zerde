# API: options and shapes to decide

Design notes for deferred changes to the public interface. Each item states the problem with evidence in `src/`, a
proposed design, the open questions, and what would accept it. Line numbers are those of the commit that added this file.

## (a) An integer as decimal text, per field

**Problem.** A JSON reader in another language may hold every number as a binary64, so an integer beyond 2^53 is not safe
to send as a JSON number. Hosts that pass 64-bit identifiers or amounts through such readers send them as strings. zerde
has no way to read or write an integer field as a string.

**Proposed design.** A per-field option, `serde.fields.<f> = .{ .int_text = true }`: the field is written as a JSON
string of JSON-integer digits (an optional `-`, no `+`, no leading zero) and read only from such a string. A strict reader
accepts text only on fields that ask for it. Not a global flag: a global flag would change every integer of a frame.

**Open questions.** Whether CBOR ignores the option (CBOR integers are exact to 64 bits) or refuses it at compile time;
whether `zerde.value` needs a way to say the same.

**Acceptance.** Round-trip tests at the edges (`0`, `-1`, `maxInt(u64)`, `minInt(i64)`); refusals of `"+1"`, `"01"`,
`"1.0"`, `"1e2"` and a number where a string is due; mutants for each refusal.

## (b) `json.WriteConfig.sort_keys`

**Problem.** `sort_keys` defaults to `true` with CBOR's length-first order (`src/json.zig:60-61`): shorter keys first,
then bytewise. That is neither insertion order nor RFC 8785's order (UTF-16 code units), and `value.serialize` writes a
map in its stored order. A caller who reads "sort keys" expects a lexicographic order.

**Proposed design.** Either default `false` (insertion order), or rename it to say what it does, for example
`cbor_key_order`. `resumable.Render` claims to write what `valueWriter` writes byte for byte; stored deterministic input
is already in length-first order, so check that the claim holds under the new default.

**Open questions.** Which callers depend on the current default; whether an RFC 8785 order is wanted as a third choice.

**Acceptance.** The render-equivalence tests pass under the new default; the change is a `### Breaking` entry.

## (c) Fewer, clearer wire entry points

**Problem.**

- Six size functions in three pairs: `regionSizes` / `maxArenaSize`, `resumableRegionSizes` / `maxResumableArenaSize`,
  `streamRegionSizes` / `maxStreamArenaSize` (`src/wire.zig:813-852`).
- `resumable.Reading` takes a public `positions: bool` (`src/resumable.zig:197`).
- `gather.Ref` is `cbor.GatherRef` under a second name (`src/gather.zig:20`).
- `chunk.Reader` and `chunk.RawScan` (`src/chunk.zig:50`, `:84`) are public through `zerde.chunk` (`src/root.zig:44`)
  though only the resumable read uses them.

**Proposed design.** One `Sizes` per read mode with a mode argument and a `total()`; named types for the two `Reading`
layouts in place of the flag; one home for the gather reference; a decision on whether `chunk` is public.

**Open questions.** Whether to keep the old names for a release (the project's convention is a clean cutover).

**Acceptance.** Every caller in `src/`, `tests/`, `bench/`, `examples/` and `bin/` moved; the README's wire section
names only the new entry points.

## (d) `typed_resume.zig` and CBOR

**Problem.** The resumable typed walk imports `cbor` directly (`src/typed_resume.zig:24`). Its module doc says the reader
is strict CBOR, which is true, but the import is what would stop a resumable lenient-CBOR or JSON reader from reusing the
walk.

**Proposed design.** Move the CBOR parts behind the deserializer protocol (as `isStrict` and `keysAscend` are), when a
second resumable reader is built.

**Open questions.** Depends on (d) of `plans/streaming.md`: without a second resumable reader there is nothing to gain.

**Acceptance.** `typed_resume.zig` no longer imports `cbor.zig`, and the resumable read tests pass unchanged.

## (e) The size of a default JSON deserializer

**Problem.** Every `JsonDeserializer` carries the lists that only an extras field uses (`extras`, `extra_keys`,
`src/json.zig:384-385`), in every read.

**Proposed design.** One lazily created struct for the extras state, so a read without extras carries one pointer.

**Open questions.** Whether the saving shows in any benchmark; the deserializer is on the stack.

**Acceptance.** `@sizeOf` of the deserializer falls; `bench-json` rows unchanged or better.

## (f) The cost of a `zerde.value` read

**Problem.** An untyped read grows each array and object one item at a time (`parseObjectValue`, `src/value.zig:241`)
and copies every key (`Bytes.fromTokenOwned`), even into an arena. Since every read refuses a repeated key, the
untyped JSON read also keeps a key record; see `bench/JSON.md` for its cost.

**Proposed design.** Pre-size from `objectLen` and `beginArrayLen` where the format states a count; let an arena-backed
parse keep borrowed keys.

**Open questions.** How a borrowed key is freed by `Value.deinit` when the parse was not arena-backed.

**Acceptance.** The `value parse` rows of `bench-json` improve; the value tests pass under the testing allocator.

## (g) A byte order mark

**Problem.** A JSON text that starts with a byte order mark is refused (`error.UnexpectedToken`; `README.md:311`). RFC
8259 §8.1 lets a parser ignore one. YAML 1.2 requires a reader to accept one; no handling of it is in
`src/yaml_read.zig` (no `0xEF` or `U+FEFF`).

**Proposed design.** Document that callers strip it, or add `skip_bom` to the JSON read config; accept one in YAML.

**Open questions.** Whether a BOM is ever seen by callers.

**Acceptance.** Tests of a BOM-prefixed JSON (refused or skipped as decided) and YAML (accepted).

## (h) MessagePack ignores `enum_repr`

**Problem.** `MsgpackDeserializer.readEnumTag` (`src/msgpack.zig:355`) takes a number or a name whatever the enum's
`enum_repr`, so an enum declared `.integer` reads a string in MessagePack but not in CBOR or JSON.

**Proposed design.** Honour `enum_repr` in `readEnumTag` as `typed.decodeEnumValue` does.

**Open questions.** None.

**Acceptance.** A MessagePack read of a string into an `.integer` enum is `error.UnexpectedType`, with a mutant.

## (i) Default-path cost

**Problem.** Measured against the branch's base (`03beb0e`), with no new option set, three alternating runs per suite
(the `2026-11-25 - 52757c8` sections of `bench/JSON.md`, `bench/CBOR.md`, `bench/MSGPACK.md`, `bench/BSON.md` and
`bench/MEMORY.md`), two formats are slower on the typed default path, by more than 10% in every pair:

| Format | Row | Tip / base, three pairs |
| --- | --- | --- |
| CBOR | write | 1.61 to 2.11 small, 1.33 to 1.54 medium, 1.45 to 1.50 large |
| CBOR | roundtrip | 1.36 to 1.45 small, 1.31 to 1.34 medium, 1.30 to 1.32 large |
| CBOR | parse | 1.24 to 1.29 small, 1.19 to 1.20 medium, 1.19 to 1.23 large |
| JSON | parse | 1.20 to 1.31 small, 1.28 to 1.37 medium, 1.25 to 1.36 large |
| JSON | roundtrip (medium, large) | 1.15 to 1.25 medium, 1.22 to 1.34 large |

The JSON small roundtrip (1.07 to 1.19) has one pair under 10%, so it is context, not one of these rows. The comparison
libraries (zbor, `std.json`) moved within 0.83 to 1.18 on the same runs, but for one `std.json` medium roundtrip run
(1.37). MessagePack and BSON are as fast
or faster; JSON allocates fewer bytes, every other format the same. The repeated-key check is not the cause: the typed
JSON parse was unchanged across it (`5870942` section of `bench/JSON.md`), and the CBOR rows do not touch it. A comptime
gather parameter for the CBOR writer was measured and moved nothing.

**Proposed design.** Profile one typed CBOR write and one typed JSON parse at the base and at the tip, and attribute the
difference to the branch's changes on that path (UTF-8 checks of every string, the deterministic and negative-zero
checks, read limits, the destination-passing walk, the resumable context). Then remove what costs without serving a
default read or write.

**Open questions.** Which of those changes the profile names; whether the cost belongs to a check the default should
make (UTF-8 is one: it is the reason text is refused on read and write).

**Acceptance.** The typed CBOR write within 1.10× of the base and the CBOR and JSON parse within 1.05× on `bench-cbor`
and `bench-json`, three alternating runs, with every refusal the branch added still in place.

**Outcome (`e07eb8c`).** Profiled with `gprofng` and a per-commit bisection; four causes, each fixed:

1. `357dd04`: the CBOR writer, and the JSON writer too, checked every field name and enum name as UTF-8 on each write.
   They are known at compile time; they are now checked and encoded then.
2. `3461d9c`: the vector string scan found its first match with `std.simd.firstTrue`, a horizontal minimum that at 64
   lanes (AVX-512) cost more than the scan. It reads a bit mask now.
3. `21c5f15`: the CBOR reader checked strict mode and counted `max_items` on every head at run time, which kept the head
   read out of line; inlining it exposed a store-forwarding stall copying `Header`'s byte fields. Both checks are decided
   at compile time when the config does not name them, and `Header` is packed.
4. `4881395`: the JSON reader's UTF-8 check of every string, a refusal the default keeps. The string scan now notes a byte
   of 0x80 or above and an ASCII run skips the check.

On `bench-cbor` (the `e07eb8c` section of `bench/CBOR.md`) every zerde row is at or below the base but two pairs: one
small parse run (1.15, after a load-9 base run) and one large roundtrip run (1.02). On `bench-json` small parse is 0.95
to 1.00, medium 1.03 to 1.07 and large 0.99 to 1.17, with `std.json` at 0.79 to 1.08; pinned to one core, with a
retained arena, medium and large parse are both about 1.02 (the 1.04 to 1.05 first recorded here came from a probe that
timed two parses per fresh arena, and its ratio is not reproduced; `plans/json-scan.md`, F1). JSON write is 0.72 to
0.87 of the base. Narrowing the first steps of the 64-byte string scan removes that remainder on a Zen 5 native build
(`plans/json-scan.md`; the two-stage scan chosen there). What the cheaper check did not recover is accepted and recorded here. Every refusal stays: the mutants of each guard on the changed path are killed.

## (j) BSON element types a typed read does not know

**Problem.** The typed BSON reader maps nine element types (`readTag`, `src/bson.zig:510-523`) and refuses any other
with `error.UnsupportedBsonType`, even for a member it would skip; the walk of a skipped sub-document
(`skipElement`) sizes every type the BSON specification defines. So an unknown top-level member of type ObjectId or
datetime is refused, while the same member inside a skipped sub-document is read past.

**Proposed design.** Let `nextObjectField` and `nextObjectFieldIndex` keep the raw type byte, and skip an unknown
member of any defined type with `skipElement`; keep the refusal for a declared field whose type the reader cannot map.

**Open questions.** Whether `zerde.value` should map more BSON types (ObjectId as bytes, datetime as an integer).

**Acceptance.** A struct with an unknown ObjectId, datetime, regex and decimal128 member reads; a declared field of
one of them is refused; mutants for both.
