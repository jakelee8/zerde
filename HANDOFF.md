# Handoff

## State

`feat/deterministic-cbor` holds the library-review changes (19 commits of `fix/library-review`, merged at `5032c15`).

- Checks on the merged tree: `zig build test` passes. On `c24e7c4` (same source): `tests/mutants.py --check` (696 mutants, 0 stale), native and wasm32 `build-lib`, `examples`, `transcode` and `bench-build` pass. Every new or re-targeted mutant was run and killed.
- `plans/` holds `streaming.md`, `structure.md` and `api.md`.

## Open

1. Default-path cost of the whole branch, measured against `03beb0e` in three alternating pairs per suite: typed CBOR write is 1.33 to 2.11 times slower, CBOR parse and roundtrip 1.19 to 1.46, JSON typed parse 1.20 to 1.37. `plans/api.md` (i) and the `2026-11-25 - 52757c8` sections of `bench/CBOR.md` and `bench/JSON.md` record it. Profiling and fixing it is the next step.
2. Gather as a comptime parameter (step 6 of the review plan) was measured and not built: no write row moved beyond the spread (small 1,643 to 1,675 ns before, 1,686 to 1,707 ns after).
3. `plans/api.md` (j), BSON element types a typed read does not know, is an open design item.
4. Downstream code that refuses an unsorted `SortedMap` in every mode, and downstream helpers that detect repeated JSON keys, can now change.
