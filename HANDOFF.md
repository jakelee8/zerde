# Handoff

## State

- `feat/deterministic-cbor` is at `d3b15b8`.
  - `88d8825` merges the two-stage string scan (`4542079`), its benchmark entries and the documentation rewrite.
  - `9170ead` and `d3b15b8` add the `code 1` out-of-line result from `bench/BULK.md` (`2026-11-25 - 4542079`) to `plans/json-scan.md` F4. Whether to keep them is open.
- Checks:
  - On `e2c69b0`: `zig build test`, `tests/mutants.py --check` (705 mutants, 0 stale) and `bench-build` pass.
  - On `8ab97e4` (same source): examples, transcode, and the native and wasm32 `build-lib` also pass.
  - `zig build test` passes on `88d8825`.
- `plan/wire-fixes` is at `3fe0a11`, up to date with `feat/deterministic-cbor` (merge `783e4e0`). It holds `plans/wire.md`, a design that is not built yet. Its three open questions are decided: the three proposals in the file are the decisions.
  - Two premises have no probe record. A packed union panics with "panic: invalid enum value" (probed by hand); a skipped JSON value is reclaimed (settled by reading `src/json.zig:654-663`).

## Open

1. Build the wire plan. Its four items, each one commit, are: (a) a packed struct as its backing integer, (b) the `check` rebuild term in `regionSizes`, (c) an arena bound for `wire.encode` that takes the read limits, (d) `validate_bytes` for `Raw` validators.
2. Keep or revert `9170ead` and `d3b15b8` (the F4 addition to `plans/json-scan.md`).
3. The big-endian branch of `vectorStep` in `src/bulk.zig` compiles for `s390x-linux-gnu` but has not run.
4. Downstream code that refuses an unsorted `SortedMap` in every mode, and downstream helpers that detect repeated JSON keys, can now change.
