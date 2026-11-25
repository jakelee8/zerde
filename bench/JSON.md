# JSON Benchmark

This file is a running log of JSON benchmark results for `zerde` against Zig's `std.json`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-json -Doptimize=ReleaseFast`

## Workload

Current harness, starting at `8a3a0a9`, uses a mixed nested payload with:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` struct with a renamed `publicURL` field
- an `endpoints` array of structs with bools, enums, optionals, and fixed float arrays
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and fixed string arrays
- an `events` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and fixed arrays

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

The current large case produces a JSON document of about `107.58 MiB`.

Runs before `8a3a0a9` used the older simpler payload, so they are not directly comparable to the newer mixed-payload runs.

## 2026-11-25 - e07eb8c

Changes since previous run: default-path fixes from `plans/api.md` (item i). The string scan reads its first match as a bit mask; `std.simd.firstTrue` took a horizontal minimum over 64 lanes. The scan also notes whether a run holds a byte of 0x80 or above, so an ASCII run skips the UTF-8 check. The writer emits field names and enum names as bytes built at compile time.

Base is `03beb0e`, as in the `52757c8` entry; tip is `e07eb8c`. Environment: `Linux x86_64` (WSL2, 24 cores, AMD Ryzen 9 9900X, AVX-512, shared), Zig `0.17.1`. Command: `zig build bench-json -Doptimize=ReleaseFast` under one `flock`, alternating base and tip. The table shows a set of three pairs at load 2 to 5. An earlier set at load 2 to 12 is noisier (the `std.json` control moved 0.99 to 1.25); its parse rows follow the table.

| Scenario | Row | Base ns/op (3 runs) | Tip ns/op (3 runs) | Tip / base |
| --- | --- | ---: | ---: | ---: |
| small | parse zerde | 4,362 / 4,477 / 4,296 | 4,145 / 4,274 / 4,285 | 0.95 to 1.00 |
| small | parse std.json | 7,843 / 7,936 / 7,828 | 7,814 / 8,534 / 7,754 | 0.99 to 1.08 |
| small | write zerde | 3,405 / 3,412 / 3,447 | 2,947 / 2,928 / 2,869 | 0.83 to 0.87 |
| small | write std.json | 3,949 / 3,909 / 3,912 | 3,843 / 3,875 / 3,817 | 0.97 to 0.99 |
| small | roundtrip zerde | 8,426 / 8,361 / 9,653 | 7,306 / 7,467 / 7,337 | 0.76 to 0.89 |
| small | roundtrip std.json | 13,029 / 12,738 / 13,210 | 12,666 / 14,291 / 12,462 | 0.94 to 1.12 |
| medium | parse zerde | 1,232,638 / 1,213,688 / 1,232,783 | 1,297,257 / 1,253,299 / 1,324,229 | 1.03 to 1.07 |
| medium | parse std.json | 2,336,482 / 2,231,743 / 2,826,390 | 2,450,578 / 2,340,124 / 2,238,098 | 0.79 to 1.05 |
| medium | write zerde | 958,634 / 947,272 / 1,016,852 | 774,761 / 744,034 / 732,183 | 0.72 to 0.81 |
| medium | write std.json | 1,097,580 / 1,077,382 / 1,129,367 | 1,088,111 / 1,128,965 / 1,079,413 | 0.96 to 1.05 |
| medium | roundtrip zerde | 2,214,639 / 2,204,145 / 2,245,266 | 2,261,713 / 2,048,737 / 2,002,912 | 0.89 to 1.02 |
| medium | roundtrip std.json | 3,535,611 / 3,408,501 / 3,483,469 | 3,406,240 / 3,444,362 / 3,364,090 | 0.96 to 1.01 |
| large | parse zerde | 132,295,106 / 123,867,856 / 136,191,280 | 137,931,135 / 145,028,796 / 134,249,843 | 0.99 to 1.17 |
| large | parse std.json | 227,015,694 / 223,074,371 / 224,078,599 | 226,849,074 / 240,354,209 / 224,392,942 | 1.00 to 1.08 |
| large | write zerde | 92,967,951 / 92,653,629 / 94,181,370 | 75,230,277 / 74,491,980 / 72,207,548 | 0.77 to 0.81 |
| large | write std.json | 106,118,215 / 105,974,634 / 106,773,277 | 105,371,084 / 106,428,196 / 106,857,267 | 0.99 to 1.00 |
| large | roundtrip zerde | 226,073,225 / 219,563,687 / 216,152,418 | 196,538,963 / 201,898,766 / 205,117,878 | 0.87 to 0.95 |
| large | roundtrip std.json | 362,526,159 / 355,546,739 / 333,878,049 | 335,800,990 / 333,428,909 / 332,642,493 | 0.93 to 1.00 |

Parse rows of the set at load 2 to 12:

| Scenario | Row | Base ns/op (3 runs) | Tip ns/op (3 runs) | Tip / base |
| --- | --- | ---: | ---: | ---: |
| small | parse zerde | 4,200 / 4,254 / 4,344 | 4,208 / 4,668 / 4,113 | 0.95 to 1.10 |
| small | parse std.json | 7,921 / 8,021 / 7,838 | 8,046 / 9,479 / 7,725 | 0.99 to 1.18 |
| medium | parse zerde | 1,257,437 / 1,365,033 / 1,213,585 | 1,437,319 / 1,444,077 / 1,247,557 | 1.03 to 1.14 |
| medium | parse std.json | 2,243,243 / 2,217,791 / 2,237,544 | 2,611,169 / 2,715,773 / 2,351,927 | 1.05 to 1.22 |
| large | parse zerde | 127,600,087 / 139,801,705 / 121,681,496 | 150,305,731 / 150,151,805 / 140,157,420 | 1.07 to 1.18 |
| large | parse std.json | 227,227,331 / 244,368,303 / 222,994,576 | 283,734,866 / 276,511,630 / 228,832,755 | 1.03 to 1.25 |

Notes:

- Small parse is at the base (0.95 to 1.00). Medium parse is 1.03 to 1.07 and large parse 0.99 to 1.17, while `std.json` moved 0.79 to 1.08 on the same pairs. Write is 0.72 to 0.87 and roundtrip 0.76 to 1.02.
- Steady-state parse, pinned to one core (`taskset -c 3`), best of 12 (large) or 400 (medium) parses in one process with a retained arena: large 116.4 to 117.6 ms (tip) against 113.7 to 115.1 ms (base); medium 1,114,000 to 1,124,000 ns against 1,091,000 to 1,106,000 ns. Both ratios are about 1.02.
- The remaining large-parse cost is not attributed. Gating the `max_items` count at compile time, as the CBOR reader does, did not move the medium parse (1,175,000 to 1,188,000 ns).

## 2026-11-25 - 52757c8

The whole branch against its base, on the default path (no new option set).

Base is `03beb0e` (`origin/zig-0.17`); tip is `52757c8` (`fix/library-review`). Environment: `Linux x86_64` (WSL2, 24 cores, shared), Zig `0.17.1`. Command: `zig build bench-json -Doptimize=ReleaseFast` under one `flock`, three runs each, alternating base and tip suite by suite. Load average was 2 to 10. The comparison library's rows control for machine load.

The repeated-key change (`5870942`) adds a key record to an untyped read and to each unknown member that a typed read skips. MessagePack and BSON also walk each skipped value. This payload has no unknown members and these rows read no untyped value, so none of that cost shows here. The `5870942` entry below gives the untyped cost.

| Scenario | Row | Base ns/op (3 runs) | Tip ns/op (3 runs) | Tip / base |
| --- | --- | ---: | ---: | ---: |
| small | parse zerde | 4,553 / 4,306 / 4,173 | 5,460 / 5,642 / 5,387 | 1.20 to 1.31 |
| small | parse std.json | 8,554 / 9,486 / 7,941 | 7,904 / 7,867 / 7,679 | 0.83 to 0.97 |
| small | write zerde | 3,791 / 3,866 / 3,380 | 4,107 / 3,813 / 3,693 | 0.99 to 1.09 |
| small | write std.json | 4,342 / 4,420 / 3,896 | 3,917 / 4,013 / 3,849 | 0.90 to 0.99 |
| small | roundtrip zerde | 8,952 / 8,113 / 7,912 | 9,568 / 9,689 / 9,305 | 1.07 to 1.19 |
| small | roundtrip std.json | 13,759 / 12,932 / 12,586 | 12,608 / 12,894 / 12,390 | 0.92 to 1.00 |
| medium | parse zerde | 1,317,897 / 1,219,791 / 1,232,755 | 1,693,376 / 1,665,682 / 1,628,898 | 1.28 to 1.37 |
| medium | parse std.json | 2,435,126 / 2,392,516 / 2,288,067 | 2,277,747 / 2,305,354 / 2,229,883 | 0.94 to 0.97 |
| medium | write zerde | 1,063,792 / 947,730 / 931,892 | 1,037,989 / 1,045,238 / 1,024,263 | 0.98 to 1.10 |
| medium | write std.json | 1,193,365 / 1,094,399 / 1,082,511 | 1,114,360 / 1,125,439 / 1,077,175 | 0.93 to 1.03 |
| medium | roundtrip zerde | 2,362,280 / 2,212,770 / 2,187,343 | 2,707,661 / 2,760,847 / 2,661,195 | 1.15 to 1.25 |
| medium | roundtrip std.json | 3,936,448 / 3,566,339 / 3,368,251 | 3,527,318 / 4,884,455 / 3,398,454 | 0.90 to 1.37 |
| large | parse zerde | 139,041,044 / 127,926,873 / 124,800,033 | 173,697,068 / 174,334,566 / 165,430,531 | 1.25 to 1.36 |
| large | parse std.json | 236,067,404 / 230,138,257 / 228,781,311 | 240,039,975 / 233,706,440 / 223,133,861 | 0.98 to 1.02 |
| large | write zerde | 97,250,963 / 96,876,569 / 91,413,290 | 111,421,542 / 102,416,601 / 100,896,647 | 1.06 to 1.15 |
| large | write std.json | 108,038,928 / 108,972,292 / 105,366,798 | 127,636,997 / 110,204,889 / 106,166,260 | 1.01 to 1.18 |
| large | roundtrip zerde | 225,912,855 / 219,647,458 / 215,110,652 | 302,445,863 / 268,702,885 / 264,633,642 | 1.22 to 1.34 |
| large | roundtrip std.json | 345,835,036 / 342,191,323 / 330,302,559 | 392,901,862 / 344,054,666 / 335,757,349 | 1.01 to 1.14 |

Notes:

- The typed zerde parse is 1.20 to 1.37 times the base in every pair and scenario. The roundtrip is 1.07 to 1.34 and the write 0.98 to 1.15. The `std.json` control moved 0.83 to 1.18, except one medium roundtrip run (1.37). The parse cost comes from the branch, not from the repeated-key check: the `5870942` entry measured the typed parse unchanged across that commit. These runs do not show which read change (UTF-8 checks on every string, limits, the destination-passing walk) causes it.
- `plans/api.md` lists this under "Default-path cost".

## 2026-11-24 - 5870942

Changes since previous run:

- every read refuses an object that names a key twice: the JSON deserializer records each key it returns (and each unknown key a typed read skips, unless the type denies unknown members) and checks the keys when the object closes
- new rows `value parse zerde` and `value parse std.json`: the same input into `zerde.value` and into `std.json.Value` (both refuse a repeated name)

Environment: `Linux x86_64` (WSL2, 24 cores, shared; load average 3 to 10), Zig `0.17.1`. "Before" is `1ed10b9`, which added the value rows; "after" is `5870942`. Command: `zig build bench-json -Doptimize=ReleaseFast` under one `flock`, three runs each, alternating before and after. Cells give ns/op for run 1 / run 2 / run 3.

| Row | Scenario | Before | After |
| --- | --- | ---: | ---: |
| value parse zerde | small | 7939 / 8265 / 7913 | 10334 / 10056 / 10221 |
| value parse zerde | medium | 2411320 / 2408970 / 2441306 | 3295482 / 3075614 / 3475500 |
| value parse zerde | large | 252130956 / 249342836 / 255650040 | 330518157 / 319929492 / 334972429 |
| value parse std.json | small | 15644 / 15513 / 15336 | 16260 / 15013 / 15626 |
| value parse std.json | large | 528656169 / 479105537 / 485833036 | 518953828 / 479640622 / 483995081 |
| parse zerde (typed) | small | 5513 / 5485 / 6456 | 5776 / 5418 / 5748 |
| parse zerde (typed) | large | 165406066 / 163523097 / 165058272 | 169912025 / 166403705 / 168057518 |

Notes:

- the untyped read costs 25 to 35% more for the repeated-key check (a key record and a sort per object); it stays about 1.5x faster than `std.json.Value`, which makes the same check
- the typed parse is unchanged within the spread: a typed read records only unknown keys, and the payload has none

## 2026-11-23 - 4881395

Changes since previous run:

- strings are checked for UTF-8 on every path, integer fields refuse `1.0` and `1e2`, float fields refuse an overflowing number, skipped numbers are not converted, and the writer checks that a float is finite

Environment for this entry: `Linux x86_64`, Zig `0.17.1`. "Before" is `6e4bf79`, built and run on the same machine in the same session; compare only the two columns of this entry. Command: `zig build bench-json -Doptimize=ReleaseFast`, one run each.

| Operation | Scenario | Before zerde ns/op | After zerde ns/op | Change |
| --- | --- | ---: | ---: | ---: |
| parse | small | 12493.67 | 13486.23 | +7.9% |
| parse | medium | 3833978.95 | 3663706.54 | -4.4% |
| parse | large | 403884062.45 | 385666066.25 | -4.5% |
| write | small | 9476.61 | 8526.60 | -10.0% |
| write | medium | 2621730.71 | 2860680.71 | +9.1% |
| write | large | 251300831.55 | 238833656.78 | -5.0% |
| roundtrip | small | 23812.16 | 21550.11 | -9.5% |
| roundtrip | medium | 6113220.87 | 6559989.84 | +7.3% |
| roundtrip | large | 636839147.98 | 611484324.65 | -4.0% |

Notes:

- the write path moved by up to 10% in both directions on code that changed by one comparison, so changes under about 10% are within this machine's run-to-run noise
- no parse or write regression stands out; a repeat run on the benchmark machine would settle the small parse case

## 2026-04-21 - a7c1073

Changes since previous run:

- added JSON-native `readInt(T)` and `readFloat(T)` so the typed layer no longer forces integer and float fields through the generic `Number` token path
- factored number scanning into a reusable parser helper so the JSON backend can parse once and then decode directly into the requested numeric type
- kept the simpler object-field path; earlier JSON-specific field-index experiments were slower and were not kept

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 1000000 | 6040.24 | 614.02 | 13229.65 | 280.34 | `zerde` 2.19x faster |
| medium | 1,139,497 B | 1000 | 1840889.39 | 590.32 | 3873659.17 | 280.54 | `zerde` 2.10x faster |
| large | 112,803,589 B | 100 | 183837443.31 | 585.18 | 384019271.25 | 280.14 | `zerde` 2.09x faster |

### Write

| Scenario | zerde Size | std.json Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 4,289 B | 1000000 | 5530.54 | 670.61 | 6528.60 | 626.52 | `zerde` 1.18x faster |
| medium | 1,139,497 B | 1,202,217 B | 1000 | 1454993.16 | 746.88 | 1782102.04 | 643.35 | `zerde` 1.22x faster |
| large | 112,803,589 B | 118,794,235 B | 100 | 142903280.83 | 752.80 | 176081635.85 | 643.40 | `zerde` 1.23x faster |

### Roundtrip

| Scenario | zerde Size | std.json Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 4,289 B | 1000000 | 11715.38 | 633.16 | 20137.24 | 406.24 | `zerde` 1.72x faster |
| medium | 1,139,497 B | 1,202,217 B | 1000 | 3316687.39 | 655.30 | 5781347.66 | 396.63 | `zerde` 1.74x faster |
| large | 112,803,589 B | 118,794,235 B | 100 | 325798481.31 | 660.40 | 563453299.13 | 402.13 | `zerde` 1.73x faster |

### Notes

- This was a JSON read-path optimization, so the important result is parse moving back above `2x` on all three scenarios.
- No JSON write-path logic changed in this commit; any write movement in this rerun should be treated as incidental rather than as a new serializer claim.

## 2026-04-21 - ced89d0

Changes since previous run:

- reran the JSON benchmark on current `HEAD` after the parse-path intermediate string copy removal work landed in other backends
- no JSON-specific serializer or deserializer logic changed in this commit
- this entry refreshes the JSON baseline for the current tree

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 1000000 | 6960.21 | 532.95 | 13179.55 | 281.51 | `zerde` 1.89x faster |
| medium | 1,139,497 B | 1000 | 2214637.38 | 490.75 | 3883109.63 | 279.74 | `zerde` 1.75x faster |
| large | 112,803,589 B | 100 | 221890132.90 | 484.83 | 382975143.81 | 280.90 | `zerde` 1.73x faster |

### Write

| Scenario | zerde Size | std.json Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 4,289 B | 1000000 | 4989.50 | 743.39 | 5749.57 | 711.62 | `zerde` 1.15x faster |
| medium | 1,139,497 B | 1,202,217 B | 1000 | 1417287.86 | 766.84 | 1657872.43 | 691.24 | `zerde` 1.17x faster |
| large | 112,803,589 B | 118,794,235 B | 100 | 140076900.40 | 767.99 | 163364282.92 | 693.49 | `zerde` 1.17x faster |

### Roundtrip

| Scenario | zerde Size | std.json Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 4,289 B | 1000000 | 11988.20 | 618.14 | 19358.46 | 422.31 | `zerde` 1.61x faster |
| medium | 1,139,497 B | 1,202,217 B | 1000 | 3671194.40 | 592.06 | 5643909.37 | 406.16 | `zerde` 1.54x faster |
| large | 112,803,589 B | 118,794,235 B | 100 | 359774314.60 | 598.03 | 549229499.99 | 412.55 | `zerde` 1.53x faster |

### Notes

- `std.json` still produces a larger document on this workload, so write and roundtrip throughput use per-library byte counts.
- This run is slower than the previous JSON-only snapshot, but `zerde` still stays clearly ahead on parse, write, and roundtrip in all three scenarios.

## 2026-04-20 - b9b03f2

Changes since previous run:

- added end-to-end JSON roundtrip benchmarks
- roundtrip now validates `typed -> bytes -> typed` correctness once per scenario before entering the timed loop
- the harness records separate `std.json` write sizes because `std.json` emits a larger document than `zerde` on the shared mixed payload

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 1000000 | 5610.85 | 661.01 | 12880.34 | 287.95 | `zerde` 2.30x faster |
| medium | 1,139,497 B | 1000 | 1742032.13 | 623.82 | 3815532.38 | 284.81 | `zerde` 2.19x faster |
| large | 112,803,589 B | 100 | 173975188.75 | 618.35 | 376462378.75 | 285.76 | `zerde` 2.16x faster |

### Write

| Scenario | zerde Size | std.json Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 4,289 B | 1000000 | 4784.75 | 775.14 | 5506.06 | 742.87 | `zerde` 1.15x faster |
| medium | 1,139,497 B | 1,202,217 B | 1000 | 1292649.25 | 840.68 | 1533028.00 | 747.88 | `zerde` 1.19x faster |
| large | 112,803,589 B | 118,794,235 B | 100 | 127489172.09 | 843.82 | 149742352.09 | 756.57 | `zerde` 1.17x faster |

### Roundtrip

| Scenario | zerde Size | std.json Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 4,289 B | 1000000 | 10421.09 | 711.80 | 18902.82 | 432.77 | `zerde` 1.81x faster |
| medium | 1,139,497 B | 1,202,217 B | 1000 | 3054196.46 | 711.62 | 5414850.13 | 423.47 | `zerde` 1.77x faster |
| large | 112,803,589 B | 118,794,235 B | 100 | 299403212.50 | 718.62 | 531540714.17 | 426.27 | `zerde` 1.78x faster |

### Notes

- `std.json` still parses the same canonical `zerde` input in the parse benchmark, but its own serializer produces a larger output on this workload, so write and roundtrip throughput now use per-library byte counts.
- Roundtrip correctness is checked once before timing for each scenario so the measured numbers stay focused on serialization and deserialization work.

## 2026-04-20 - 8ae56d3

Changes since previous run:

- removed the old runtime `Value` fallback path, so the package now relies on typed format backends only
- renamed the aliased JSON slice parse API to `parseSliceAliased`
- added README and source-level documentation across the package

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 5498.19 | 674.73 | 12760.10 | 290.73 | `zerde` 2.32x faster |
| medium | 1,139,498 B | 1000 | 1693899.29 | 641.54 | 3816176.96 | 284.76 | `zerde` 2.25x faster |
| large | 112,803,590 B | 100 | 168851010.00 | 637.12 | 377039325.00 | 285.32 | `zerde` 2.23x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 4676.09 | 793.35 | 5518.36 | 672.26 | `zerde` 1.18x faster |
| medium | 1,139,498 B | 1000 | 1266087.50 | 858.32 | 1528167.92 | 711.12 | `zerde` 1.21x faster |
| large | 112,803,590 B | 100 | 125885706.25 | 854.57 | 150331443.33 | 715.60 | `zerde` 1.19x faster |

### Notes

- Performance stayed within noise of the previous aliased-slice run, which is what we want from a cleanup and documentation pass.
- This run was taken on a clean commit after removing the runtime tree fallback, not on a dirty working tree.

## 2026-04-20 - 1804f43

Changes since previous run:

- added an explicit slice-parse path that can alias unescaped JSON strings directly from the input buffer when the caller keeps the input alive
- switched the benchmark to compare `zerde`'s aliased parse path against `std.json.parseFromSliceLeaky`, so both parsers are allowed to reuse the input slice

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 5457.33 | 679.78 | 12809.68 | 289.61 | `zerde` 2.35x faster |
| medium | 1,139,498 B | 1000 | 1686185.67 | 644.48 | 3800610.25 | 285.93 | `zerde` 2.25x faster |
| large | 112,803,590 B | 100 | 168133617.50 | 639.84 | 376343222.09 | 285.85 | `zerde` 2.24x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 4671.43 | 794.14 | 5510.73 | 673.19 | `zerde` 1.18x faster |
| medium | 1,139,498 B | 1000 | 1262402.46 | 860.83 | 1521429.42 | 714.27 | `zerde` 1.21x faster |
| large | 112,803,590 B | 100 | 125214744.17 | 859.15 | 150374654.17 | 715.40 | `zerde` 1.20x faster |

### Notes

- Parse improved by about `4.2%` on small, `3.1%` on medium, and `3.3%` on large compared with the previous mixed-payload run.
- Write stayed in the same range as the previous run because this change only affects the typed JSON read path.

## 2026-04-20 - 8a3a0a9

Changes since previous run:

- replaced the benchmark payload with a more realistic nested document that exercises strings, bools, signed and unsigned integers, floats, optionals, enums, fixed arrays, slices, and nested structs
- switched benchmark iteration counts to fixed values: `1_000_000` for small, `1_000` for medium, and `100` for large

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 5687.70 | 652.25 | 12836.01 | 289.01 | `zerde` 2.26x faster |
| medium | 1,139,498 B | 1000 | 1737680.04 | 625.38 | 3804823.33 | 285.61 | `zerde` 2.19x faster |
| large | 112,803,590 B | 100 | 173746168.75 | 619.17 | 380069327.50 | 283.05 | `zerde` 2.19x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 4649.56 | 797.88 | 5479.65 | 677.01 | `zerde` 1.18x faster |
| medium | 1,139,498 B | 1000 | 1264018.00 | 859.73 | 1514801.38 | 717.39 | `zerde` 1.20x faster |
| large | 112,803,590 B | 100 | 124516359.16 | 863.97 | 149503560.42 | 719.57 | `zerde` 1.20x faster |

### Notes

- This is the first run using the richer mixed payload, so compare it against future entries with the same workload rather than the older simpler runs below.
- The large workload is now truly mixed data rather than a tiny wrapper around one dominant numeric array.

## 2026-04-20 - 5187fab

Changes since previous run:

- kept original integer and float types through the serializer instead of widening everything to `i128` and `f64`
- switched JSON string escaping to `std.json.Stringify.encodeJsonString`, which writes contiguous runs instead of emitting normal bytes one at a time

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 594 B | 100000 | 1061.25 | 533.79 | 2344.17 | 241.66 | `zerde` 2.21x faster |
| medium | 1,193,982 B | 56 | 3026555.80 | 376.23 | 6045828.86 | 188.34 | `zerde` 2.00x faster |
| large | 108,926,312 B | 1 | 302906792.00 | 342.94 | 575346375.00 | 180.55 | `zerde` 1.90x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 594 B | 100000 | 543.63 | 1042.05 | 672.06 | 842.90 | `zerde` 1.24x faster |
| medium | 1,193,982 B | 56 | 1058150.29 | 1076.09 | 1213110.13 | 938.64 | `zerde` 1.15x faster |
| large | 108,926,312 B | 1 | 139605667.00 | 744.10 | 154164167.00 | 673.83 | `zerde` 1.10x faster |

### Notes

- Parse stayed in the same range as the previous run.
- Write throughput flipped from slower-than-`std.json` to faster-than-`std.json` in all three scenarios.

## 2026-04-20 - 0407065

Changes since previous run:

- initial scenario-based benchmark harness with `small`, `medium`, and `large` payloads

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 594 B | 100000 | 1117.14 | 507.08 | 2338.16 | 242.28 | `zerde` 2.09x faster |
| medium | 1,193,982 B | 56 | 3038775.30 | 374.71 | 5983440.48 | 190.30 | `zerde` 1.97x faster |
| large | 108,926,312 B | 1 | 300554833.00 | 345.63 | 575630916.00 | 180.46 | `zerde` 1.91x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 594 B | 100000 | 752.66 | 752.64 | 667.38 | 848.81 | `zerde` 12.8% slower |
| medium | 1,193,982 B | 56 | 1365147.32 | 834.10 | 1203385.41 | 946.22 | `zerde` 13.4% slower |
| large | 108,926,312 B | 1 | 169926625.00 | 611.32 | 161201958.00 | 644.41 | `zerde` 5.4% slower |
