# Structure: tests, build, fuzzing, documentation and CI

Design notes for deferred work on how the repository is laid out and checked. Each item states the problem with
evidence, a proposed design, the open questions, and the test that accepts it.

## (a) Split `tests/typed_tests.zig`

**Problem.** `tests/typed_tests.zig` is one file of about 8,700 lines and about 270 tests, in sections by feature. A
change to one feature recompiles all of it, and two branches that add tests to it conflict.

**Proposed design.**

- First freeze copies of `README.md` and `tests/typed_tests.zig` under `bench/corpus/`, and point the `corpus_prose` and
  `corpus_code` benchmark inputs at them (`build.zig:450-452`). The inputs of `bench-bulk` and `bench-wire` then stop
  changing with every edit.
- Split the file into one file per feature. The files share helpers (`expectJsonError`, `writeCbor`, `Region`,
  `readInChunks`, …) through `tests/support.zig`, and one loop in `build.zig` registers them.
- Record in `tests/mutants.py` which test file kills each mutant, so a run can build only that file.

**Open questions.** Whether the mutant runner should build per file or keep running `zig build test` whole.

**Acceptance.** `zig build test` runs the same number of tests before and after. `python3 tests/mutants.py` kills every
mutant it killed before.

## (b) Generate the corpus test modules from one table

**Problem.** `build.zig` builds eight corpus test modules by hand, one per format. Each copy opens its directory with the
panic text "failed to open JSON corpus directory" (`build.zig:75`), whatever the format.

**Proposed design.** One table of `{ format, directory, extension }` and one loop that builds the modules. The panic
names the directory it failed on.

**Open questions.** None.

**Acceptance.** The same corpus tests run. The panic for a missing directory names it.

## (c) A shared fuzz layer

**Problem.** `tests/fuzz_tests.zig` seeds each format's parser from its invalid corpus, and `tests/property_tests.zig`
round-trips typed values. No coverage-guided entry point (`std.testing.fuzz`) exists for every reader, and the oracles
that each test checks differ by format.

**Proposed design.** `tests/fuzz_support.zig` with `fuzzReader(T, Format, cfgs, seeds)`:

- seeds from both `tests/corpus/<format>` and `tests/corpus_invalid/<format>`;
- oracles:
  - no crash and no leak;
  - read, then write, then read gives the same value;
  - for strict CBOR, accepted bytes re-encode to themselves;
  - canonicalize is idempotent, and `canonicalizeInto` equals `canonicalize`;
  - a resumable read at fuzzer-chosen cuts equals the whole read;
  - `wire.decode` agrees with the typed read;
  - strict acceptance implies lenient acceptance of the same value;
- runs over a flat struct, the fuzz document type, a union, integer keys, `SortedMap` and `Raw`.

Document `zig build test --fuzz` in `CONTRIBUTING.md`.

**Open questions.** How long a CI fuzz run may take. Whether findings are kept as corpus files.

**Acceptance.** Each oracle has a mutant it kills. A short `--fuzz` run in CI finds nothing on the tip.

## (d) A shorter README

**Problem.** `README.md` is about 700 lines. Its "Current benchmark snapshot" (`README.md:18`) has no date or commit.

**Proposed design.** About 150 lines of README (what the library is, install, a typed read and write, the formats,
links), and `docs/*.md` for strict CBOR, the resumable read and write, `wire`, and the limits. Date the benchmark
snapshot with its commit, or replace it with a link to `bench/`.

**Open questions.** Whether the frozen `bench/corpus/` copy of (a) lands first, so the benchmark input does not shrink.

**Acceptance.** Every section of the current README is in the README or a `docs/` page. No link is broken.

## (e) CI

**Problem.** `.github/workflows/ci.yml` runs the tests in Debug only, does not check formatting, and runs no mutant. It
runs only `tests/mutants.py --check`, which checks that the patterns are still in the source.

**Proposed design.**

- one `zig build test -Doptimize=ReleaseSafe` run on ubuntu;
- `zig fmt --check src tests bench bin examples build.zig`;
- a scheduled full `python3 tests/mutants.py` run on a clean checkout, which fails on a survivor.

**Open questions.** The time budget of the scheduled mutant run. Each mutant is a full test build.

**Acceptance.** The jobs run green on the tip. A deliberately surviving mutant fails the scheduled run.

## (f) Where the tests live

**Problem.** The `test` block of `src/root.zig` (`src/root.zig:674`) imports a list of modules for their tests, while most
tests live in `tests/`. A new module's own tests run only if the module is added to that list.

**Proposed design.** Either state in `CONTRIBUTING.md` that tests live in `tests/` and keep the list for module-local
tests, or use `std.testing.refAllDecls` so no module is missed.

**Open questions.** Whether `refAllDecls` also compiles every public declaration in the wasm32 build.

**Acceptance.** A module added without a list entry still has its tests run.
