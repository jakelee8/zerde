# Handoff

## State

`feat/deterministic-cbor` holds the library review (`5032c15`) and the default-path performance fixes (`perf/default-path`, merged at `b9af132`).

- The default-path cost of `plans/api.md` (i) is fixed and recorded there under "Outcome (`e07eb8c`)". Four causes: UTF-8 checks of compile-time names on write, `std.simd.firstTrue` in the 64-lane string scan, CBOR strict and `max_items` checks per head with the `Header` copy stall, and the JSON read UTF-8 check of ASCII runs. The benchmarks are the `2026-11-25 - e07eb8c` sections of `bench/CBOR.md`, `bench/JSON.md` and `bench/BULK.md`.
- A cheaper JSON check was made. The large JSON parse stays 1.04 to 1.05 of the base when pinned to one core (0.99 to 1.17 in the suite); this is documented as accepted.
- Checks on `cbb13fc` (same tree as the merge): `zig build test`, `tests/mutants.py --check` (702 mutants, 0 stale), examples, transcode, `bench-build`, and native and wasm32 `build-lib` pass; `zig build test` passes on `b9af132`. Every new or retargeted mutant was run and killed by a test.

## Open

1. Gather as a comptime parameter (step 6 of the library review) was measured and not built: no write row moved beyond the spread.
2. `plans/api.md` (j), BSON element types a typed read does not know, is an open design item.
3. Downstream code that refuses an unsorted `SortedMap` in every mode, and downstream helpers that detect repeated JSON keys, can now change.
