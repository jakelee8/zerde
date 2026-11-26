# zerde

## Checks for a change

- Every code change: `zig build test`. It also runs the property-style roundtrip fuzzing, the parser hardening fuzzing and the invalid-input leak tests. After an edit to `src/`, also run `python3 tests/mutants.py --check`: it fails when a mutant's pattern is gone from the source, as CI does.
- A new guard: add its mutant (the guard removed or weakened) to `tests/mutants.py`, and run `python3 tests/mutants.py` on a clean tree before you commit. Do not commit while it runs: it edits `src/`.
- Benchmarked code: the matching `zig build bench-<format> -Doptimize=ReleaseFast`. `bench/README.md` describes the benchmark workflow.
- `examples/`: `zig build examples`. `bin/`, the transcoder CLI: `zig build transcode`.

## The package

- `build.zig` exports one module, `b.addModule("zerde")` over `src/root.zig`, and returns right after it when a consumer builds it (`!b.isRoot()`), so a consumer fetches no third-party code.
- `toml`, `zbor` and `zbench` stay `.lazy = true` in `build.zig.zon`, and its `.paths` lists only what the package needs.
- `src/` imports no third-party module and no path outside `src/`.

## Benchmarks

- Timing uses `zBench`. Keep the scenario workloads and the fairness policy stable; change them only when the change is about benchmark behavior.
- Each format's history is in `bench/<FORMAT>.md` (`BIN`, `BSON`, `BULK`, `CBOR`, `JSON`, `MEMORY`, `MSGPACK`, `TOML`, `WASM`, `WIRE`, `YAML`, `ZON`). Add an entry only for a change that moves a benchmark, newest first, under a heading `## YYYY-MM-DD - <hash>`.

## Corpus

- Round-trip fixtures live in `tests/corpus/<format>/` in canonical output form; the corpus tests are generated from them.
- Invalid-input fixtures live in `tests/corpus_invalid/<format>/`. Keep each minimal, specific to its format, and named by the failure it shows.
- Name a fixture by the feature it covers, such as `null.json`, `array_float.yaml` or `object_nested.bson`.

## Workflows and docs

`.github/workflows/ci.yml` builds the native and wasm libraries and runs the tests, `python3 tests/mutants.py --check`, the examples, the transcoder and `zig build bench-build`. `bench.yml` runs the benchmarks, and `release.yml` follows the release process and its tag conventions. When the Zig version, a build step or the release process changes, change the workflow that runs it, and `README.md`, `bench/README.md` and `CONTRIBUTING.md`, in the same commit.
