# JSON string scan: findings and design

Findings from profiling the large JSON parse, the design they lead to, and the
alternatives considered. The investigation covered the cause of the slower large parse, the 64-byte against 32-byte
vector width from `std.simd.suggestVectorLength`, the approach of simdjson, tuning of a two-stage scan length, running
one x86_64 binary on several processors (Intel, AMD and others), and the time, speedup and memory of a classification
pass.

Machine: AMD Ryzen 9 9900X (Zen 5, AVX-512), WSL2, Zig 0.17.1, `-OReleaseFast`, native CPU (`znver5`). Timings are best of
12 (large) or 400 (medium) parses in one process with a retained arena, pinned with `taskset -c 3`, with base and
variants alternated. The probes were `bis.zig` and `skip.zig` (parse variants and a token census), and `micro.zig`,
`micro2.zig`, `real.zig`, `tune.zig`, `cpu.zig` and `dis.zig` (scan microbenchmarks, CPU model checks and a
disassembly). The probe sources and logs are not part of the repository.

## Findings

### F1. The large and medium parse are about 1.02 of the base

| Build | Large parse | Medium parse |
| --- | ---: | ---: |
| base `03beb0e` | 113.7 to 115.1 ms | 1.091 to 1.106 ms |
| `e07eb8c` (merged) | 116.4 to 117.6 ms | 1.114 to 1.124 ms |

### F2. The cause is the 64-byte string scan

- Both builds parse byte-identical input (`large-base.json`, `large-tip.json`). Against the base, the tip retires 15%
  fewer instructions with 13% fewer branch mispredictions and the same cache misses and page faults, but takes more
  cycles.
- Capping only the vector width of `bulk.findSpecial`, with everything else equal:

| Scan width | Large parse | Medium parse |
| --- | ---: | ---: |
| 64 (as merged) | 116.4 to 117.6 ms | 1.114 to 1.124 ms |
| 32 | 108.3 to 109.6 ms | 1.035 to 1.051 ms |
| 16 | 107.4 to 108.2 ms | 1.030 to 1.034 ms |
| words (no vectors) | 111.5 to 112.7 ms | not measured |

- JSON write did not move with the width.

### F3. Which targets scan 64 bytes

`std.simd.suggestVectorLength(u8)` returns 512 bits for an x86 CPU with AVX-512F, unless its LLVM model sets
`prefer_256_bit` or `prefer_128_bit`. Its source calls the rule "guesswork" (`lib/std/simd.zig:11-22`). The width per
model, checked with Zig 0.17.1 (`cpu.zig`):

| `-mcpu` | prefer_256 | width |
| --- | --- | ---: |
| `x86_64` baseline | no | 16 |
| `x86_64_v3`, `alderlake`, `znver3` | no | 32 |
| `x86_64_v4` | yes | 32 |
| `skylake_avx512`, `icelake_server`, `sapphirerapids`, `graniterapids` | yes | 32 |
| `znver4`, `znver5` | no | 64 |

Only builds that target AMD Zen 4 or Zen 5 scan 64 bytes. Every other x86 target scans 32 or 16 bytes. The run-time
vendor is not consulted: the compiler fixes the width from the target CPU.

### F4. Mechanism: latency per string is one candidate; code size and layout is another

- The compiled scan is the same instruction sequence at 32 and 64 bytes, with wider registers (`dis.zig`, objdump). Code
  size per inlined call site and instruction encoding length were not compared. Whole-run instruction counts are 34.98 G
  (64) against 34.88 G (16-byte cap), 0.3% apart. Cycles are 1.944 to 1.948 against 1.769 to 1.774 s over two profiled
  runs each, about 10% apart.
- In the hottest parse function (`typed.deserializeStruct`), the vector and mask instructions take 0.20 s of cycles at 64
  against 0.09 s at 16. That is about 0.11 s of the 0.17 to 0.18 s gap; the rest is not attributed. Other functions moved
  in both directions between the two builds (`readBool` 0.057 s at 64 against 0.082 s at 16; `startObjectKey` 0.057
  against 0.088 s) because the builds inline differently, so per-function figures do not compare across them. A core-wide
  slowdown is not ruled out, such as the Zen 5 AVX-512 IPC throttling that Chips and Cheese measured on this CPU model
  (link in F8).
- Payload strings: 7.57 million keys and values per large parse (F9's census, which skips escaped quotes), all but one
  under 16 bytes. `real.zig` took its scan starts from every second quote character, which gave 7.66 million starts.
- Scanning from those starts as independent calls takes 0.78 to 0.79 ns per start at 16 and 32 bytes, and 0.83 ns at 64
  (about 6% more). In a chain where each scan's start depends on the previous result (`micro.zig`), 64 bytes adds about
  0.3 ns per string with an aligned start, and another 0.2 to 0.4 ns when the read crosses a cache line. A 64-byte read at
  a random offset crosses a 64-byte line 63 times in 64.
- Candidate 1 (inference): in the parser the next read waits on where the string ended, so the latency of the scan, not
  its throughput, sets the cost. No published Zen 5 latency figure for a split 64-byte load was found.
- Candidate 2: code size and layout. Inlining alone moves the parse by 13% (F6: 124.2 against 109.7 ms), more than the
  whole width effect. A wider scan also inlines a larger body at each call site. The two-stage scan adds direct evidence:
  on the 270 KiB `code 1` text it runs the same 64-byte loop after 64 bytes of 32-byte steps, but out of line, and the
  row is 0.90 to 0.92 of the inlined loop (`bench/BULK.md`, `2026-11-25 - 4542079`). No per-string latency is involved
  there.
- The sizes do not match. The parse gap is about 9 ms over 7.57 million strings, about 1.2 ns per string. The
  microbenchmarks give 0.05 ns (independent) and 0.3 to 0.7 ns (chained). Neither candidate is established.

### F5. Long ASCII and multibyte text pays for a narrower scan; escape-dense text does not

Command: `taskset -c 3 zig build bench-bulk -Doptimize=ReleaseFast` from three checkouts of `aaaf864` that differ only in
`src/bulk.zig`, five alternating runs each. The table gives the "bulk" column in ns, lowest to highest:

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
wider scan is faster, with no overlap. On the escape-dense 64 KiB windows row the 64-byte scan is the slowest, with no
overlap against 32.

### F6. Two-stage scans

Chained-scan microbenchmark (`tune.zig`, ps per string, mean of three start offsets, two runs):

| Length | 64 | 32 | 32, then 64 | 32 ×2, then 64 | 16, then 64 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 4 | 4,423 to 4,907 | 4,015 to 4,079 | 3,837 to 3,849 | 3,843 to 3,856 | 3,675 to 3,683 |
| 24 | 4,599 to 4,809 | 4,052 to 4,059 | 3,863 to 3,901 | 3,821 to 3,864 | 4,672 to 4,797 |
| 40 | 4,430 to 4,564 | 4,358 to 4,457 | 4,562 to 4,611 | 4,167 to 4,201 | 4,574 to 4,744 |
| 100 | 4,663 to 4,665 | 4,824 | 4,860 to 4,902 | 4,415 to 4,435 | 4,835 to 4,839 |
| 400 | 6,842 to 6,896 | 9,367 to 9,512 | 6,903 to 6,937 | 6,704 to 6,738 | 7,090 to 7,102 |
| 4000 | 40,668 to 40,753 | 76,025 to 76,090 | 41,944 to 42,260 | 41,511 to 41,965 | 41,252 to 41,512 |

In the parser (two 32-byte steps, then 64; variants `exp-U`, `exp-V` and `exp-D`):

| Variant | Large parse | Medium parse |
| --- | ---: | ---: |
| all stages inline at each call site (`exp-U`) | 124.2 to 124.5 ms | 1.195 to 1.202 ms |
| 32-byte steps inline, 64-byte loop `never_inline` (`exp-V`) | 109.7 to 112.6 ms | 1.036 to 1.049 ms |
| 32 cap (`exp-D`), same runs | 108.4 to 109.3 ms | 1.048 to 1.051 ms |

The long-string speed of `exp-V` was not measured (`bench-bulk` was not run on it). Its first stage reads the mask with
`@bitCast` and `@ctz`, without the big-endian branch that the merged scan has.

### F7. What simdjson does

- First pass: it builds the string and escape masks in `src/generic/stage1/json_string_scanner.h`, classifies structural
  characters in `json_scanner.h`, and writes the positions in `json_structural_indexer.h`. It classifies the whole
  document in 64-byte blocks into bit masks (quotes, backslashes, escaped quotes, inside-string, structural characters)
  and writes the positions of structural characters and value starts. A block is 2 × 32-byte registers on AVX2, 1 × 64 on
  its AVX-512 kernel, and 4 × 16 on NEON and SSE. The cost is per input byte, and no step waits on where a string ended.
- Second pass: it walks the positions. `copy_and_find` copies and unescapes strings, with `BYTES_PROCESSED` 32 on
  Haswell, ARM64 and Westmere, and 64 on the AVX-512 kernel (`include/simdjson/*/stringparsing_defs.h`). That kernel
  needs AVX-512 F, DQ, CD, BW, VL and VBMI2 (`include/simdjson/icelake/implementation.h`), which Zen 4 and Zen 5 have.
- It requires 64 bytes of readable padding after the input and stores whole chunks unconditionally.
- Index allocation: `max_structures = ROUNDUP_N(capacity, 64) + 9` `uint32` positions, one per input byte
  (`include/simdjson/generic/dom_parser_implementation.h:60-70`).
- It chooses a kernel at run time by CPU features (runtime dispatch).

### F8. Other processors and prior art (web)

- Zen 5 desktop has full 512-bit datapaths and two 512-bit loads per cycle
  ([Chips and Cheese, Hot Chips 2024](https://chipsandcheese.com/p/discussing-amds-zen-5-at-hot-chips-2024)). Heavy
  512-bit memory traffic on the faster CCD of the 9900X can lower IPC for tens of milliseconds
  ([Chips and Cheese](https://old.chipsandcheese.com/2025/02/28/zen-5s-avx-512-frequency-behavior/)).
- Intel: AVX-512 license downclocking is small from Ice Lake on
  ([Travis Downs](https://travisdowns.github.io/blog/2020/08/19/icl-avx512-freq.html)). LLVM keeps `prefer-256` for
  Intel models, and [llvm#231086](https://github.com/llvm/llvm-project/issues/231086) debates removing it from
  `x86-64-v4`. The default AVX-512 string functions of glibc use 256-bit EVEX registers, chiefly to avoid RTM aborts and
  `vzeroupper`. Its later 512-bit variants report up to 30% fewer cycles, depending on length
  ([Phoronix](https://www.phoronix.com/news/Glibc-More-AVX-512-October-2022)). A `tolower` study found 256-bit faster
  than 512-bit for small numbers of chunks ([dotat](https://dotat.at/@/2024-07-31-tolower-small.html)).
- ARM: M1 and Graviton 4 have 16-byte vectors, and Graviton 3 has 32-byte SVE. ClickHouse kept 16-byte NEON over 32-byte
  SVE for substring search on Graviton 3 ([StringZilla PR #4](https://github.com/ClickHouse/StringZilla/pull/4)). ARM's
  optimized-routines found its SVE string routines slower for short or unaligned input
  ([PR #65](https://github.com/ARM-software/optimized-routines/pull/65)).
- Zig has no built-in function multiversioning ([#1018](https://github.com/ziglang/zig/issues/1018), open since 2018).
  Runtime dispatch is done by hand with `std.zig.system` detection or a library such as
  [oma](https://github.com/ATTron/oma).

### F9. Size of a classification pass's job on this payload

- Large document: 112.8 MB, with 16.2 M structural characters, 7.57 M strings and 6.39 M numbers or literals
  (`skip.zig` census). That is about 30 M tokens, one per 3.7 bytes. Medium document: 1.14 MB, 306 k tokens.
- Parse: 116.5 ms (about 1 GB/s, 3.9 ns per token).
- Three measures of what a first pass could remove, each different and none a ceiling:
  - scanning every string as independent calls takes 6.0 to 6.4 ms (about 5.5% of the parse);
  - the width effect alone is about 9 ms (F2's 64 against 16);
  - the profile share of the string and key functions, which also copy strings and match keys, is about 20%.

  The pass itself reads every byte and writes every position. No first pass was built or measured.
- Index memory: 4 bytes per position. Exact for this document: 121 MB (1.2 MB medium). With simdjson-style reservation of
  one position per input byte: 451 MB (4.6 MB medium). A typed read today allocates only its output, so a whole-document
  index would add a term to the wire region sizes (`wire.regionSizes`, `resumableRegionSizes`).

### F10. Skipping values is slower than reading them

Reading the large document into `struct {}`, which skips every value through `JsonDeserializer.skipValue`
(`src/json.zig:777`), takes 149.3 to 150.7 ms. The full typed read takes 116.5 to 116.6 ms. For the medium document the
figures are 1.46 to 1.47 ms against 1.12 to 1.14 ms. The cause is not investigated.

## Design

- **A4. Two-stage scan on 64-byte targets (Zen 4 and Zen 5 builds).** Two 32-byte steps run inline, then the 64-byte
  loop runs out of line. Parse time matches the 32 cap (F6), and long-text speed stays near the 64-byte scan. It adds a
  second code path; both stages keep the big-endian branch.
- **B0. No classification pass.** The reader keeps scanning per string.
- **C0. Leave the skip path as it is** (F10).
- **D1. Correct the records.** `bench/JSON.md` and `plans/api.md` (i) carry the steady-state figures of F1.

A4 changes `src/bulk.zig`, its tests and `tests/mutants.py`, and is measured with `bench-json` and `bench-bulk`.

## Considered alternatives

### A. Scan width on 64-byte targets (Zen 4 and Zen 5 builds only)

- **A1. Keep 64.** Long ASCII, multibyte and code text keep their speed. The escape-dense 64 KiB windows row stays the
  slowest of the three widths (F5). Large and medium parse stay about 1.02 of the base (F1).
- **A2. Cap at 32 in `bulk.findSpecial`.** Parse takes 108 to 110 ms (F2). Long text is slower on some bulk rows (F5).
  Every x86 target then scans at most 32 bytes (F3).
- **A3. Cap at 16.** Parse takes 107 to 108 ms (F2). Long text is slower than at 32 on the same rows (F5).
- **A5. Keep 64 and avoid the cache-line split.** Load the aligned 64-byte block that holds `from`, and shift the bits
  before `from` off the mask, as aligned-block scanners do. This tests the split-load part of F4 directly; it was not
  measured. The aligned block can start before the input slice and end after it, because the input is the caller's, at
  any alignment. The first and last blocks therefore need a clamped or byte-wise path, or a documented padding
  requirement like that of simdjson.
- **A6. A build option for the width,** so a build chooses 16, 32 or 64 instead of the comptime default.
- **A7. Runtime dispatch by CPU.** Compile the scan per CPU level or model and choose at startup (F7, F8). A binary built
  for a CPU level runs on Intel and AMD alike and has one width today (F3: 16 for baseline, 32 for `x86_64_v3` and
  `_v4`). Dispatch would let such a binary use another width on CPUs that have it. A build for a specific CPU, such as
  one that a user compiles from source for their own target, fixes the width at compile time.

A2 to A7 each change `src/bulk.zig` (A6 also `build.zig`), its tests and `tests/mutants.py`, and need `bench-json`,
`bench-cbor` and `bench-bulk` runs with log entries.

### B. A classification first pass (simdjson-style)

- **B1. Whole-document index.** One pass over the input, then the reader takes positions from the index. Memory is up to
  4 bytes per input byte, or exact per token after a counting pass (F9). It adds a term to the wire region sizes.
- **B2. Windowed index.** Index a fixed window (for example 64 KiB of input, at most 256 KiB of positions) and carry the
  inside-string and escape state across windows. Memory is fixed. The resumable reader must handle positions that cross a
  window.

B1 and B2 each change the token functions of the JSON reader (string, key, whitespace, skip, `Raw`) and its error
positions. F9 gives three measures of the share a first pass could remove on this payload.

### C. The skip path (F10)

- **C1. Profile `skipValue` and make it no slower than a typed read of the same value.**
