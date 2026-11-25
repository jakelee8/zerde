# JSON string scan: findings and design options

Findings from profiling the large JSON parse, and the design options they
open. No option is chosen here.

Machine: AMD Ryzen 9 9900X (Zen 5, AVX-512), WSL2, Zig 0.17.1, `-OReleaseFast`, native CPU (`znver5`). Timings are
best of 12 (large) or 400 (medium) parses in one process with a retained arena, pinned with `taskset -c 3`, base and
variants alternated. Scratch evidence: `tmp/perf2/` (probes `bis.zig`, `skip.zig`; variant sources `exp-*`; logs) and
`tmp/simd/` (`micro.zig`, `micro2.zig`, `real.zig`, `tune.zig`, `cpu.zig`, `dis.zig`) in the main checkout.

## Findings

### F1. The large and medium parse are about 1.02 of the base, not 1.04 to 1.05

| Build | Large parse | Medium parse |
| --- | ---: | ---: |
| base `03beb0e` | 113.7 to 115.1 ms | 1.091 to 1.106 ms |
| `e07eb8c` (merged) | 116.4 to 117.6 ms | 1.114 to 1.124 ms |

`bench/JSON.md` (`e07eb8c` section) and `plans/api.md` (i) record the pinned large parse as 1.04 to 1.05 and medium as
at the base. That figure came from an earlier probe that built a fresh arena for each repetition and timed two parses
per repetition; its absolute large figures (154.5 to 163.3 ms) are about 35% above the steady-state 114 to 117 ms on the
same input. Why its ratio differs is not known: a fault cost equal for both builds would pull the ratio toward 1.0, not
away from it, and that probe's source is gone, so it was not re-run. Both records are still uncorrected.

### F2. The cause is the 64-byte string scan

- Both builds parse byte-identical input (`large-base.json`, `large-tip.json`). Against the base the tip retires 15%
  fewer instructions with 13% fewer branch mispredictions and the same cache misses and page faults, but more cycles.
- Capping only `bulk.findSpecial`'s vector width, everything else equal:

| Scan width | Large parse | Medium parse |
| --- | ---: | ---: |
| 64 (as merged) | 116.4 to 117.6 ms | 1.114 to 1.124 ms |
| 32 | 108.3 to 109.6 ms | 1.035 to 1.051 ms |
| 16 | 107.4 to 108.2 ms | 1.030 to 1.034 ms |
| words (no vectors) | 111.5 to 112.7 ms | not measured |

- JSON write did not move with the width.

### F3. Why 64 bytes is chosen here

`std.simd.suggestVectorLength(u8)` returns 512 bits for an x86 CPU with AVX-512F unless its LLVM model sets
`prefer_256_bit` or `prefer_128_bit`; its source calls the rule "guesswork" (`lib/std/simd.zig:11-22`). Checked per
model with Zig 0.17.1 (`tmp/simd/cpu.zig`):

| `-mcpu` | prefer_256 | width |
| --- | --- | ---: |
| `x86_64` baseline | no | 16 |
| `x86_64_v3`, `alderlake`, `znver3` | no | 32 |
| `x86_64_v4` | yes | 32 |
| `skylake_avx512`, `icelake_server`, `sapphirerapids`, `graniterapids` | yes | 32 |
| `znver4`, `znver5` | no | 64 |

So only builds targeting AMD Zen 4 or Zen 5 scan 64 bytes; every other x86 target scans 32 or 16. The vendor is not
consulted at run time: the width is fixed when the code is compiled, from the target CPU.

### F4. Mechanism: latency per string is one candidate; code size and layout is another

- The compiled scan is the same instruction sequence at 32 and 64 bytes with wider registers (`tmp/simd/dis.zig`,
  objdump). Code size per inlined call site and instruction encoding length were not compared. Whole-run instruction
  counts: 34.98 G (64) against 34.88 G (16-byte cap), 0.3% apart; cycles 1.944 against 1.774 s, about 10% apart.
- In the hottest parse function (`typed.deserializeStruct`) the vector and mask instructions take 0.20 s of cycles at 64
  against 0.09 s at 16, about 0.11 s of the 0.17 s gap; the rest is not attributed. Other functions moved in both
  directions between the two builds (`readBool` 0.057 s at 64 against 0.082 s at 16; `startObjectKey` 0.057 against
  0.088 s) because the builds inline differently, so per-function figures do not compare across them. A core-wide
  slowdown, such as the Zen 5 AVX-512 IPC throttling Chips and Cheese measured on this CPU model (link below), is not
  ruled out.
- Payload strings: 7.57 million keys and values per large parse (F9's census, which skips escaped quotes), all but one
  under 16 bytes. `tmp/simd/real.zig` took its scan starts from every second quote character, 7.66 million starts.
- Scanning from those starts as independent calls: 0.78 to 0.79 ns per start at 16 and 32, 0.83 at 64 (about 6%). In a
  chain where each scan's start depends on the previous result (`tmp/simd/micro.zig`), 64 bytes adds about 0.3 ns per
  string with an aligned start and another 0.2 to 0.4 ns when the read crosses a cache line. A 64-byte read at a random
  offset crosses a 64-byte line 63 times in 64.
- Candidate 1 (inference): in the parser the next read waits on where the string ended, so the scan's latency, not its
  throughput, sets the cost. No published Zen 5 latency figure for a split 64-byte load was found.
- Candidate 2: code size and layout. Inlining alone moves the parse by 13% (F6: 124.2 against 109.7 ms), more than the
  whole width effect, and a wider scan inlines a larger body at each call site.
- The sizes do not match: the parse gap is about 9 ms over 7.57 million strings, about 1.2 ns per string, against 0.05
  ns (independent) and 0.3 to 0.7 ns (chained) in the microbenchmarks. Neither candidate is established.

### F5. Long ASCII and multibyte text pays for a narrower scan; escape-dense text does not

`taskset -c 3 zig build bench-bulk -Doptimize=ReleaseFast` from three checkouts of `aaaf864` that differ only in
`src/bulk.zig`, five runs each, alternating, the "bulk" column, ns, lowest to highest (logs:
`tmp/review-scan/bulk/w{64,32,16}-{1..5}.log`):

| Row | 64 | 32 cap | 16 cap |
| --- | ---: | ---: | ---: |
| ascii, find special | 2,603 to 3,252 | 5,051 to 6,927 | 9,871 to 10,380 |
| ascii, escape | 4,771 to 5,951 | 7,512 to 8,849 | 12,824 to 14,805 |
| escapes, find special | 20,265 to 20,969 | 19,379 to 20,697 | 20,962 to 21,603 |
| multibyte, find special | 2,594 to 2,773 | 4,990 to 5,565 | 9,954 to 11,308 |
| code 1, find special | 72,203 to 74,034 | 83,491 to 87,827 | 116,050 to 124,370 |
| prose, find special | 3,455 to 3,683 | 3,342 to 3,586 | 3,816 to 4,456 |
| escapes6, escape, 64 KiB windows | 242,082 to 244,896 | 217,704 to 226,969 | 203,712 to 223,223 |

Ranges overlap between widths on the "escapes, find special" and prose rows. On the ascii, multibyte and code rows the
wider scan is faster with no overlap; on the escape-dense 64 KiB windows row the 64-byte scan is the slowest, with no
overlap against 32.

### F6. Two-stage scans

Chained-scan microbenchmark (`tmp/simd/tune.zig`, ps per string, mean of three start offsets, two runs):

| Length | 64 | 32 | 32, then 64 | 32 ×2, then 64 | 16, then 64 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 4 | 4,423 to 4,907 | 4,015 to 4,079 | 3,837 to 3,849 | 3,843 to 3,856 | 3,675 to 3,683 |
| 24 | 4,599 to 4,809 | 4,052 to 4,059 | 3,863 to 3,901 | 3,821 to 3,864 | 4,672 to 4,797 |
| 40 | 4,430 to 4,564 | 4,358 to 4,457 | 4,562 to 4,611 | 4,167 to 4,201 | 4,574 to 4,744 |
| 100 | 4,663 to 4,665 | 4,824 | 4,860 to 4,902 | 4,415 to 4,435 | 4,835 to 4,839 |
| 400 | 6,842 to 6,896 | 9,367 to 9,512 | 6,903 to 6,937 | 6,704 to 6,738 | 7,090 to 7,102 |
| 4000 | 40,668 to 40,753 | 76,025 to 76,090 | 41,944 to 42,260 | 41,511 to 41,965 | 41,252 to 41,512 |

In the parser (two 32-byte steps then 64, `tmp/perf2/exp-U`, `exp-V`):

| Variant | Large parse | Medium parse |
| --- | ---: | ---: |
| all stages inline at each call site (`exp-U`) | 124.2 to 124.5 ms | 1.195 to 1.202 ms |
| 32-byte steps inline, 64-byte loop `never_inline` (`exp-V`) | 109.7 to 112.6 ms | 1.036 to 1.049 ms |
| 32 cap (`exp-D`), same runs | 108.4 to 109.3 ms | 1.048 to 1.051 ms |

`exp-V`'s long-string speed was not measured (`bench-bulk` not run on it). Its first stage reads the mask with
`@bitCast` and `@ctz` without the big-endian branch the merged scan has.

### F7. What simdjson does

- First pass: the string and escape masks are built in `src/generic/stage1/json_string_scanner.h`, the structural
  classification in `json_scanner.h`, and the positions are written in `json_structural_indexer.h`. It classifies the
  whole document in 64-byte blocks into bit
  masks (quotes, backslashes, escaped quotes, inside-string, structural characters) and writes the positions of
  structural characters and value starts. A block is 2 × 32-byte registers on AVX2, 1 × 64 on its AVX-512 kernel, and 4
  × 16 on NEON and SSE. Its cost is per input byte; no step waits on where a string ended.
- Second pass: walks the positions; strings are copied and unescaped by `copy_and_find`, `BYTES_PROCESSED` 32 on
  Haswell, ARM64 and Westmere, 64 on the AVX-512 kernel (`include/simdjson/*/stringparsing_defs.h`). That kernel needs
  AVX-512 F, DQ, CD, BW, VL and VBMI2 (`include/simdjson/icelake/implementation.h`), which Zen 4 and Zen 5 have.
- Requires 64 bytes of readable padding after the input and stores whole chunks unconditionally.
- Index allocation: `max_structures = ROUNDUP_N(capacity, 64) + 9` `uint32` positions, one per input byte
  (`include/simdjson/generic/dom_parser_implementation.h:60-70`).
- Chooses a kernel at run time by CPU features (runtime dispatch).

### F8. Other processors and prior art (web)

- Zen 5 desktop has full 512-bit datapaths and two 512-bit loads per cycle
  ([Chips and Cheese, Hot Chips 2024](https://chipsandcheese.com/p/discussing-amds-zen-5-at-hot-chips-2024)). Heavy
  512-bit memory traffic on the 9900X's faster CCD can lower IPC for tens of milliseconds
  ([Chips and Cheese](https://old.chipsandcheese.com/2025/02/28/zen-5s-avx-512-frequency-behavior/)).
- Intel: AVX-512 license downclocking is small from Ice Lake on
  ([Travis Downs](https://travisdowns.github.io/blog/2020/08/19/icl-avx512-freq.html)); LLVM keeps `prefer-256` for
  Intel models, and [llvm#231086](https://github.com/llvm/llvm-project/issues/231086) debates removing it from
  `x86-64-v4`. glibc's default AVX-512 string functions use 256-bit EVEX registers, chiefly to avoid RTM aborts and
  `vzeroupper`; its later 512-bit variants report up to 30% fewer cycles depending on length
  ([Phoronix](https://www.phoronix.com/news/Glibc-More-AVX-512-October-2022)). A `tolower` study found 256-bit faster
  than 512-bit for small numbers of chunks ([dotat](https://dotat.at/@/2024-07-31-tolower-small.html)).
- ARM: M1 and Graviton 4 have 16-byte vectors, Graviton 3 32-byte SVE. ClickHouse kept 16-byte NEON over 32-byte SVE for
  substring search on Graviton 3 ([StringZilla PR #4](https://github.com/ClickHouse/StringZilla/pull/4)); ARM's
  optimized-routines found its SVE string routines slower for short or unaligned input
  ([PR #65](https://github.com/ARM-software/optimized-routines/pull/65)).
- Zig has no built-in function multiversioning ([#1018](https://github.com/ziglang/zig/issues/1018), open since 2018);
  runtime dispatch is done by hand with `std.zig.system` detection or a library such as
  [oma](https://github.com/ATTron/oma).

### F9. Size of a classification pass's job on this payload

- Large document: 112.8 MB; 16.2 M structural characters, 7.57 M strings, 6.39 M numbers or literals (`tmp/perf2/
  skip.zig` census): about 30 M tokens, one per 3.7 bytes. Medium: 1.14 MB, 306 k tokens.
- Parse: 116.5 ms (about 1 GB/s, 3.9 ns per token).
- Three different measures of what a first pass could remove, not one ceiling: scanning every string as independent
  calls takes 6.0 to 6.4 ms (about 5.5% of the parse); the width effect alone is about 9 ms (F2's 64 against 16); the
  profile share of the string and key functions, which also copy strings and match keys, is about 20%. The pass itself
  reads every byte and writes every position. No first pass was built or measured.
- Index memory: 4 bytes per position. Exact for this document 121 MB (1.2 MB medium); simdjson-style reservation of one
  position per input byte 451 MB (4.6 MB medium). A typed read today allocates only its output, so a whole-document
  index would be a new term in the wire region sizes (`wire.regionSizes`, `resumableRegionSizes`).

### F10. Skipping values is slower than reading them

Reading the large document into `struct {}`, which skips every value through `JsonDeserializer.skipValue`
(`src/json.zig:777`), takes 149.3 to 150.7 ms against 116.5 to 116.6 ms for the full typed read (medium: 1.46 to 1.47
against 1.12 to 1.14 ms). Not investigated further.

## Design options

### A. Scan width on 64-byte targets (Zen 4/5 builds only)

- **A1. Keep 64.** Long ASCII, multibyte and code text keep their speed, and the escape-dense 64 KiB windows row stays
  the slowest of the three widths (F5); large and medium parse stay about 1.02 of the base (F1).
- **A2. Cap at 32 in `bulk.findSpecial`.** Parse 108 to 110 ms (F2); long text slower on some bulk rows (F5); every x86
  target then scans at most 32 (F3).
- **A3. Cap at 16.** Parse 107 to 108 ms (F2); long text slower than at 32 on the same rows (F5).
- **A4. Two-stage: two 32-byte steps inline, then the 64-byte loop out of line.** Parse about the 32 cap's (F6);
  long-text speed predicted near 64 by the microbenchmark but not measured in this form; adds a second code path and
  needs the endian branch in the first stage.
- **A5. Keep 64 and avoid the cache-line split.** Load the aligned 64-byte block that holds `from` and shift the bits
  before `from` off the mask, as aligned-block scanners do. Tests F4's split-load part directly; not measured. The
  aligned block can start before the input slice and end after it (the input is the caller's, at any alignment), so the
  first and last blocks need a clamped or byte-wise path, or a documented padding requirement like simdjson's.
- **A6. A build option for the width,** so a build chooses 16, 32 or 64 instead of the comptime default.
- **A7. Runtime dispatch by CPU.** Compile the scan per CPU level or model and choose at startup (F7, F8). A binary
  built for a CPU level runs on Intel and AMD alike and has one width today (F3: 16 for baseline, 32 for `x86_64_v3`
  and `_v4`); dispatch would let such a binary use another width on CPUs that have it. A build for a specific CPU, such
  as zerde's users compiling from source for their own target, fixes the width at compile time.

Each of A2 to A7 changes `src/bulk.zig` (A6 also `build.zig`), its tests and `tests/mutants.py`, and needs `bench-json`, `bench-cbor`
(CBOR to JSON transcoding uses the same scan) and `bench-bulk` runs with log entries. Every option is independent of
correcting the F1 records.

### B. A classification first pass (simdjson-style)

- **B0. None.** The reader keeps scanning per string.
- **B1. Whole-document index.** One pass over the input, then the reader takes positions from the index. Memory: up to
  4 bytes per input byte, or exact per token after a counting pass (F9); a new term in the wire region sizes.
- **B2. Windowed index.** Index a fixed window (for example 64 KiB of input, at most 256 KiB of positions) and carry the
  inside-string and escape state across windows; fixed memory; the resumable reader must handle positions that cross a
  window.

Any of B1 and B2 changes the JSON reader's token functions (string, key, whitespace, skip, `Raw`) and error positions.
F9 gives three measures of the share it could remove on this payload.

### C. The skip path (F10)

- **C0. Leave it.**
- **C1. Profile `skipValue` and make it no slower than a typed read of the same value.**

### D. The records

- **D0. Leave them.**
- **D1. Correct `bench/JSON.md` and `plans/api.md` (i) to the steady-state figures of F1**, stating that the earlier
  probe's ratio is not reproduced and its cause is not known.
