# Handoff

## State

- `feat/deterministic-cbor` is at `2e4e4c9`.
  - `2e4e4c9` merges the wire build branch (tip `9e04558`, same tree), which builds the wire plan `plans/wire.md`. The merge brought in `plan/wire-fixes` (`3fe0a11`) through `838fa54`. Commits: (a) `dc709da` + fix `176f3dd`; (b) `73a81eb` + fix `bd9680d`; (c) `f20ae69` + fix `e6d2c94`; (d) `d1e5220`; mutant fixes `9e04558`.
  - The full suite passed on `9e04558`.
  - `9170ead` and `d3b15b8` add the `code 1` out-of-line result from `bench/BULK.md` (`2026-11-25 - 4542079`) to `plans/json-scan.md` F4. Whether to keep them is open.
- `plan/wire-fixes` remains at `3fe0a11`, merged.

## Open

1. **Wire benchmark regression check.**
   - Done: two full rounds of every `bench-*` on the old tree (`b83900e`) and the new tree (`9e04558`, same tree as `2e4e4c9`), old always run first. Raw times drift by ±30% between runs, and competitor rows move as much as zerde's, so raw ratios are not usable. Normalised to the competitor in the same run, no regression is consistent except bson large parse (1.158, 1.184) and toml large roundtrip (1.064, 1.065).
   - Wire bounds and memory are unchanged. `src/bulk.zig` is unchanged, so its bulk deltas are noise.
   - Focused reruns of `bench-bson` and `bench-toml` alternate which side runs first. Only round 1 (new first) finished, with no regression: bson large parse 0.965, toml large roundtrip 0.831.
   - To finish: rounds 2 and 3 of `zig build bench-bson` and `zig build bench-toml` with `-Doptimize=ReleaseFast`, alternating the order, on both trees.
   - The one hot-path change found is `typed.readIntOf` (`anyerror!T`), which replaces the inline int read. Its cost is unverified.
   - Add `bench/*.md` entries only if a change moves a benchmark.
2. Keep or revert `9170ead` and `d3b15b8` (the F4 addition to `plans/json-scan.md`).
3. The big-endian branch of `vectorStep` in `src/bulk.zig` compiles for `s390x-linux-gnu` but has not run.
4. Downstream code that refuses an unsorted `SortedMap` in every mode, and downstream helpers that detect repeated JSON keys, can now change. A downstream prototype can now use the wire fixes.
