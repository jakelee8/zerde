# Streaming: resumable writes and reads that are not built yet

Design notes for work that is deferred. Each item states the problem with evidence in `src/`, a proposed design, the open
questions, and the measurement or test that would accept it. Line numbers are those of the commit that added this file.

## (a) A resumable gather

**Problem.** `gather.encode` (`src/gather.zig:35`) writes the whole skeleton of a frame into one caller region. A host that
streams large frames, with many byte strings left out of the skeleton, needs a region as large as the whole skeleton,
which for thousands of entries is hundreds of kilobytes. `resumable.Writer.fill` (`src/resumable.zig:66`) writes in windows
but knows nothing of gather: `CborSerializer.emitBytesPart` and `emitRawPart` (`src/cbor.zig:336`, `:408`) always copy.

**Proposed design.**

- When a gather write is on (the serializer's `gather` state, `src/cbor.zig:270`), `emitBytesPart` and `emitRawPart`
  record a `GatherRef` for an item of at least `min_len` bytes and leave its bytes out, as `emitBytes` and `emitRaw` do.
- A full refs slice is `error.WindowFull`, so the caller drains the refs with the window.
- `resumable.Writer.fill` returns the window's refs, each `skeleton_offset` relative to the window.

**Open questions.** Whether the refs slice belongs to the cursor or is passed to each `fill`; how a caller learns that
a window ended because the refs, not the bytes, were full.

**Acceptance.** Compute within 1.15× of `gather.encode` on the same rows of a new `bench-wire` case; a test that joins the
windows and their refs and compares with `serializeWith`, for every window size from `min_window` up.

## (b) The per-token cost of the resumable writer

**Problem.** A resumable write of a frame that fits in one window costs more than `serializeWith`, by a fixed amount per
`fill` and per token: every token reserves room first (`typed.ResumeState.reserve`, `src/typed.zig:298`), and the state
holds a level for every possible depth (`ResumeState.levels`, `src/typed.zig:282`), which `fill` initializes.

**Proposed design.** Measure the fixed cost of one `fill` on a frame that fits one window before choosing. Candidates:

- a speculative write of the whole item with a rollback when the window is short; exact for CBOR, while JSON's serializer
  stack needs a snapshot;
- `ResumeState.levels` sized from the type's depth, as the reader's `frameCount` does (`src/resumable.zig:187`);
- room reserved once for a subtree whose size is bounded at compile time.

**Open questions.** Which of the candidates the measurement favours; whether a caller should instead use the whole write
when the frame's bound fits the window.

**Acceptance.** Within 1.15× of `serializeWith` on small frames (hundreds of bytes) in `bench-wire`, ReleaseFast and
ReleaseSafe.

## (c) A resumable canonicalizer (open)

**Problem.** `cbor.canonicalizeInto` (`src/cbor.zig:1749`) has no resumable form. Each map is sorted before its first
member is written (`CanonicalWriter`, `src/cbor.zig:1756`), so a window cannot be written until the map's entries are
indexed.

**Proposed design.** None yet. A bounded design would index the entries of the open maps in caller scratch and write the
sorted entries a window at a time; it needs an upper bound on the entries of one map.

**Open questions.** Whether such a bound is acceptable to callers, or whether the canonicalizer stays whole-buffer only.

**Acceptance.** Output equal to `canonicalizeInto` for every window size, on the canonicalize tests' inputs.

## (d) Resumable lenient-CBOR and JSON readers (open)

**Problem.** `resumable.Decoder` and `wire.Resumable` read strict CBOR only (`src/resumable.zig:191-197`). A server that
streams a public body, which arrives as lenient CBOR or JSON, has no resumable read.

**Proposed design.** Chunked readers for lenient CBOR and JSON that implement the same deserializer protocol as
`chunk.Reader`, so the typed walk (`src/typed_resume.zig`) is reused. JSON needs a tokenizer that can stop inside a
number, a literal or an escape.

**Open questions.** How a lenient read's key record (repeated keys, `src/repeat.zig`) is kept across chunks without the
input, which the record now borrows from.

**Acceptance.** For every cut and pair of cuts of the corpus inputs, the value or the error of the whole read.

## (e) Decoder state that can move between calls (open)

**Problem.** The copy-mode decoder's state points into itself: `wire.ResumableIn.init` stores `&self.regions` and
`&self.arena` (`src/wire.zig:885-892`), and the typed walk's `ReadLevel` holds pointers into the region. A host that
keeps many uploads in flight cannot copy a decoder's state out and back.

**Proposed design.** Three options:

1. a snapshot and restore at the same address;
2. `feed(allocator, bytes)`, with no self-reference in `wire.ResumableIn`;
3. offsets from the region base in place of the pointers in `ReadLevel`.

**Open questions.** Which option keeps the read allocation-free; what the cost of offsets is on every access.

**Acceptance.** A test that moves the state (a `@memcpy` to another address) between every pair of chunks and gets the
whole read's value.

## (f) `SortedMap` keys in positions mode

**Problem.** In positions mode (`wire.StreamResumable`), a `SortedMap` key is copied so that the next key can be compared
with it, and each key is charged `max_string_len` in the bound (`src/wire.zig`, `typedOwned`, the `zerde_sorted_entry`
case). A frame with many maps then needs a much larger region.

**Proposed design.** Compare the next key with the previous one in the stream, by its position, without a copy.

**Open questions.** The previous key may be in a chunk already gone; the comparison needs the reader to keep it or a
prefix-and-hash summary of it.

**Acceptance.** `streamRegionSizes` drops the per-key charge; the sorted-map resumable tests pass at every cut.

## (g) A differential property test of the canonical paths

**Problem.** Three paths produce canonical CBOR (`canonicalItem`, `src/cbor.zig:1264`; `CanonicalWriter`, `:1756`; the
value writer's sort on close), and several checks refuse non-canonical input (strict read, `verifyStrict`, the
deterministic write's check of a `Raw`). Each has its own tests; none checks that they agree.

**Proposed design.** A property test over generated items: every canonical path gives the same bytes, and every strict
check refuses the same inputs.

**Open questions.** The generator: a shared one with the fuzz layer of `plans/structure.md` (c).

**Acceptance.** The property test runs under `zig build test` and finds no disagreement; a mutant that changes one
path's order is caught by it.
