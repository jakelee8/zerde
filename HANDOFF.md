# Handoff

## State

- `feat/deterministic-cbor` is at `5342c17`.
  - `5342c17` merges `feat/detailed-diagnostics` (tip `2b56b2f`), which builds detailed parse diagnostics (JSON and CBOR first; the typed-layer details reach every format). Commits: `2d9901b` bench rows for the diagnostic parse path; `7fd2ee1` path recorded on unwind; `f785b34` `Diagnostic.detail`, format hooks, tests and mutants; `2b56b2f` bench log entries.
  - `zig build test` (724 tests), examples, transcode, bench-build and `mutants.py --check` pass on `2b56b2f`.
  - The 16 changed or new mutants (indices 35 125 294 521 619 807-817) were all killed. The full mutant run was not made; the run was scoped to those.
  - `2e4e4c9` merged the wire plan `plans/wire.md`. `9170ead` and `d3b15b8` add the `code 1` out-of-line result from `bench/BULK.md` (`2026-11-25 - 4542079`) to `plans/json-scan.md` F4. Whether to keep them is open.

## Open

1. **Diagnostics follow-up.** In `bench/JSON.md` (`2026-11-26 - f785b34`), JSON `parse zerde` without diagnostics was 1.00 to 1.08 of the base in all nine runs (medians 1.01 to 1.05). It passes the plan's rule, and the `std.json` control moved 0.95 to 1.09, so a cost of a few percent is neither shown nor ruled out. CBOR shows no cost. The diagnostic path is cheaper than before on CBOR (0.75 to 0.97) and about equal on JSON.
   - The likely candidate is the `peekValueKind` factoring out of `JsonDeserializer.peekKind`, which is not marked `inline`.
   - Method to settle it: mark `peekValueKind` in `src/json.zig` `inline`, then rerun base and tip pinned to one core with `taskset -c 3 zig build bench-json -Doptimize=ReleaseFast`, alternating the two.
2. **Wire benchmark regression check.**
   - Done: two full rounds of every `bench-*` on the old tree (`b83900e`) and the new tree (`9e04558`, same tree as `2e4e4c9`), old always run first. Raw times drift by ±30% between runs, and competitor rows move as much as zerde's, so raw ratios are not usable. Normalised to the competitor in the same run, no regression is consistent except bson large parse (1.158, 1.184) and toml large roundtrip (1.064, 1.065).
   - Wire bounds and memory are unchanged. `src/bulk.zig` is unchanged, so its bulk deltas are noise.
   - Focused reruns of `bench-bson` and `bench-toml` alternate which side runs first. Only round 1 (new first) finished, with no regression: bson large parse 0.965, toml large roundtrip 0.831.
   - To finish: rounds 2 and 3 of `zig build bench-bson` and `zig build bench-toml` with `-Doptimize=ReleaseFast`, alternating the order, on both trees.
   - The one hot-path change found is `typed.readIntOf` (`anyerror!T`), which replaces the inline int read. Its cost is unverified.
   - Add `bench/*.md` entries only if a change moves a benchmark.
3. Keep or revert `9170ead` and `d3b15b8` (the F4 addition to `plans/json-scan.md`).
4. The big-endian branch of `vectorStep` in `src/bulk.zig` compiles for `s390x-linux-gnu` but has not run.
5. Downstream code that refuses an unsorted `SortedMap` in every mode, and downstream helpers that detect repeated JSON keys, can now change. A downstream prototype can now use the wire fixes and the new `Diagnostic.detail`.
