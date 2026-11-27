# Handoff

## State

- `feat/deterministic-cbor` is at `118e829` plus this file.
  - `118e829` keeps the F4 citation of the `code 1` row in `plans/json-scan.md` (from `9170ead` and `d3b15b8`, which the user chose to keep) and corrects it: the text is 493,062 bytes, and the row chains dependent scans and changes the first steps and the inlining together, so it carries per-string latency and does not isolate code size. Reviewed and approved; no build reads the file.
- JSON parse cost of the diagnostics work: none found. Three rounds pinned to core 3 (`taskset -c 3 zig build bench-json -Doptimize=ReleaseFast`, order rotated) of `2d9901b`, the branch tip and the tip with `peekValueKind` marked `inline`. Raw times moved by up to 30% with the `std.json` control, so ratios are taken against the control in the same run. Tip over base, medians: `parse zerde` 0.93 small, 1.00 medium, 0.95 large. `inline` was 0.99 to 1.08 of the tip, so it was not kept. Raw output: `tmp/bench/diag/`.
- Wire benchmark check: rounds 2 (old first) and 3 (new first) of `bench-bson` and `bench-toml` on `zerde-bench-old` and `zerde-bench-new` are done. Raw output: `tmp/bench/focus/`; ratios: `python3 tmp/bench/normalized.py tmp/bench/focus`.
  - toml large roundtrip: 0.831, 0.996, 1.023. No regression.
  - bson large parse: 0.965 (new first), 1.170 (old first), 1.071 (new first). The two full rounds before were old first: 1.158, 1.184. The side that runs second looks slower, so the order inflates or hides the ratio. Raw zerde medians are 73.0 ms old and 76.1 ms new, and their ranges overlap. A cost of a few percent is neither shown nor ruled out.

## Open

1. **bson large parse.** Settling it needs runs pinned to one core, alternating order, for example `taskset -c 3 zig build bench-bson -Doptimize=ReleaseFast` three times on each tree. One run takes about 16 minutes, mostly the `zig-bson` rows. The hot-path candidate is `typed.readIntOf` (`anyerror!T`), which replaces the inline int read. Add a `bench/BSON.md` entry only if a change moves the benchmark.
2. The big-endian branch of `vectorStep` in `src/bulk.zig` compiles for `s390x-linux-gnu` but has not run. The user chose not to run it under qemu.
3. Downstream code that refuses an unsorted `SortedMap` in every mode, and downstream helpers that detect repeated JSON keys, can now change. A downstream prototype can now use the wire fixes and `Diagnostic.detail`.
