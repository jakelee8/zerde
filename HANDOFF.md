# Handoff

## State

`feat/deterministic-cbor` is at `88d8825`.

- The two-stage string scan is merged (`4542079`). On targets with 64-byte vectors (AMD Zen 4 and Zen 5 builds), the scan takes two 32-byte steps before it moves to 64-byte steps. Large JSON parse is 0.89 to 0.97 of the previous tip in `bench-json`. Long-text scans are equal or faster in `bench-bulk`. See `plans/json-scan.md` and the `2026-11-25 - 4542079` entries of `bench/JSON.md` and `bench/BULK.md`.
- `README.md`, `CHANGELOG.md` (Unreleased), `CONTRIBUTING.md`, `bench/*.md` and `plans/*.md` are rewritten in Standard Technical English. Lines by the original author are unchanged.
- Checks on `e2c69b0` (the merged tree): `zig build test`, `tests/mutants.py --check` (705 mutants, 0 stale) and `bench-build` pass. On `8ab97e4` (same source), examples, transcode, and the native and wasm32 `build-lib` also pass. `zig build test` passes on `88d8825`.

## Open

1. `plans/wire.md` on branch `plan/wire-fixes` (`64b8ff4`) is a design for four wire fixes: packed structs as integers, the `check` term in `regionSizes`, an arena bound for `wire.encode`, and memory for `Raw` validators. It is not built. Its open questions are listed in the file.
2. The big-endian branch of the string scan compiles for `s390x-linux-gnu` but has not run on a big-endian host.
3. Downstream code that refuses an unsorted `SortedMap` in every mode, and downstream helpers that detect repeated JSON keys, can now change.
