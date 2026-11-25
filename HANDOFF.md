# Handoff

## State

- `feat/deterministic-cbor` is at `d3b15b8`.
  - `88d8825` merges the two-stage string scan (`4542079`), its benchmark entries and the documentation rewrite.
  - `9170ead` and `d3b15b8` add the `code 1` out-of-line result from `bench/BULK.md` (`2026-11-25 - 4542079`) to `plans/json-scan.md` F4. Whether to keep them is open.
- Checks:
  - On `e2c69b0`: `zig build test`, `tests/mutants.py --check` (705 mutants, 0 stale) and `bench-build` pass.
  - On `8ab97e4` (same source): examples, transcode, and the native and wasm32 `build-lib` also pass.
  - `zig build test` passes on `88d8825`.
- `plan/wire-fixes` is at `64b8ff4`. It holds `plans/wire.md`, a design that is not built yet.

## Open

1. The wire plan: build it or not, and settle its three open questions. The design is `plans/wire.md` on `plan/wire-fixes`. Its four items, each one commit, are: (a) a packed struct as its backing integer, (b) the `check` rebuild term in `regionSizes`, (c) an arena bound for `wire.encode` that takes the read limits, (d) `validate_bytes` for `Raw` validators.
   - A streaming read of a type whose `check` reads text: compile error (proposed), or copy the text into the output.
   - `wire.encode`: take the read limits as a new parameter (proposed), or write straight from the wire layout.
   - Validators that allocate: allowed in wire reads with a declared byte bound (proposed), or forbidden.
   - `plan/wire-fixes` predates the documentation rewrite and the scan change, so `feat/deterministic-cbor` must be merged into it first.
2. Keep or revert `9170ead` and `d3b15b8` (the F4 addition to `plans/json-scan.md`).
3. The big-endian branch of `vectorStep` in `src/bulk.zig` compiles for `s390x-linux-gnu` but has not run.
4. Downstream code that refuses an unsorted `SortedMap` in every mode, and downstream helpers that detect repeated JSON keys, can now change.
