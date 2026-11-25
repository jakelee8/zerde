# CBOR Benchmark

This file is a running log of CBOR benchmark results for `zerde` against `zbor`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-cbor -Doptimize=ReleaseFast`

## Workload

Current harness uses the same mixed nested payload family as the JSON benchmark, encoded as CBOR:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` struct with a renamed `publicURL` field
- an `endpoints` array of structs with bools, enums, optionals, and fixed float arrays
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and fixed string arrays
- an `events` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and fixed arrays
- parse measured against one canonical CBOR document per scenario

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

The current large case produces a canonical CBOR document of about `76.22 MiB`, with write outputs of about `76.22 MiB` for `zerde` and `75.28 MiB` for `zbor`.

## 2026-11-25 - e07eb8c

Changes since previous run: the default-path fixes of `plans/api.md` (i). The writer puts out a field name and an enum name as bytes made at compile time, with no UTF-8 check on each write; the reader decides strict mode and the `max_items` count at compile time when the config does not name them, and `Header` is a `packed struct`, so the head read no longer stalls on copying its byte fields.

Base is `03beb0e`, as in the `52757c8` entry; tip is `e07eb8c`. `Linux x86_64` (WSL2, 24 cores, AMD Ryzen 9 9900X, AVX-512, shared), Zig `0.17.1`; three runs each, alternating base and tip, `zig build bench-cbor -Doptimize=ReleaseFast` under one `flock`. Load average 2 to 9; the zbor rows are the control.

| Scenario | Row | Base ns/op (3 runs) | Tip ns/op (3 runs) | Tip / base |
| --- | --- | ---: | ---: | ---: |
| small | parse zerde | 2,737 / 2,905 / 3,046 | 3,138 / 2,624 / 2,624 | 0.86 to 1.15 |
| small | parse zbor | 16,480 / 16,708 / 15,831 | 16,342 / 14,443 / 13,587 | 0.86 to 0.99 |
| small | write zerde | 1,199 / 1,286 / 1,161 | 1,182 / 998 / 995 | 0.78 to 0.99 |
| small | write zbor | 2,610 / 2,700 / 2,210 | 2,048 / 1,913 / 1,890 | 0.71 to 0.86 |
| small | roundtrip zerde | 4,608 / 4,393 / 4,374 | 4,151 / 3,796 / 3,812 | 0.86 to 0.90 |
| small | roundtrip zbor | 22,440 / 20,577 / 18,929 | 17,167 / 17,765 / 16,544 | 0.77 to 0.87 |
| medium | parse zerde | 886,699 / 897,572 / 837,354 | 754,697 / 759,237 / 742,997 | 0.85 to 0.89 |
| medium | parse zbor | 5,373,218 / 4,765,301 / 4,176,380 | 4,167,966 / 4,217,379 / 4,207,232 | 0.78 to 1.01 |
| medium | write zerde | 356,618 / 344,253 / 327,816 | 308,620 / 311,377 / 308,507 | 0.87 to 0.94 |
| medium | write zbor | 665,063 / 629,311 / 548,007 | 553,021 / 559,957 / 544,593 | 0.83 to 0.99 |
| medium | roundtrip zerde | 1,200,194 / 1,227,489 / 1,098,313 | 1,076,649 / 1,062,515 / 1,058,862 | 0.87 to 0.96 |
| medium | roundtrip zbor | 5,336,405 / 6,622,170 / 4,924,361 | 4,949,196 / 4,956,106 / 4,896,021 | 0.75 to 0.99 |
| large | parse zerde | 92,592,139 / 93,008,352 / 78,663,525 | 75,675,615 / 81,483,115 / 73,670,542 | 0.82 to 0.94 |
| large | parse zbor | 488,093,452 / 474,957,205 / 444,747,143 | 425,097,169 / 426,684,059 / 411,353,677 | 0.87 to 0.92 |
| large | write zerde | 35,065,212 / 35,463,255 / 32,371,763 | 31,607,771 / 30,862,703 / 30,869,389 | 0.87 to 0.95 |
| large | write zbor | 66,382,932 / 57,887,509 / 55,213,993 | 58,777,924 / 60,926,332 / 54,024,003 | 0.89 to 1.05 |
| large | roundtrip zerde | 126,515,395 / 109,723,623 / 111,240,588 | 113,916,387 / 111,864,574 / 103,873,126 | 0.90 to 1.02 |
| large | roundtrip zbor | 575,636,419 / 523,234,138 / 485,720,385 | 531,001,344 / 513,557,351 / 486,998,843 | 0.92 to 1.00 |

Notes:

- Every zerde row is at or below the base but for one small parse run (1.15, its pair ran just after load 9); the plan's acceptance (write within 1.10, parse within 1.05) holds in every other pair. zbor moved 0.71 to 1.05 on the same runs, so the base runs were slowed too.
- Pinned to one core (`taskset -c 3`), best of 15 repetitions of the same payload in a standalone probe: small write 970 to 977 ns against 1,001, parse 2,470 to 2,482 against 2,495 to 2,561; large write 41.5 against 42.5 ms, parse 87.6 to 89.2 against 86.4 to 87.4 ms (1.01 to 1.03).

## 2026-11-25 - 52757c8

The whole branch against its base, on the default path (no new option set).

Base is `03beb0e` (`origin/zig-0.17`, where this branch started); tip is `52757c8` (`fix/library-review`, the source of every later commit of the branch). `Linux x86_64` (WSL2, 24 cores, shared), Zig `0.17.1`; three runs each, alternating base and tip suite by suite, `zig build bench-cbor -Doptimize=ReleaseFast` under one `flock`. Load average 2 to 10 during the runs; the comparison library's rows are the control for the machine.

Expected from the repeated-key change (`5870942`): a key record in an untyped read and for each unknown member a typed read skips, and MessagePack and BSON walking a skipped value; this payload has no unknown members and these rows read no untyped value, so none of it shows here (see the `5870942` section of `bench/JSON.md` for the untyped cost).

| Scenario | Row | Base ns/op (3 runs) | Tip ns/op (3 runs) | Tip / base |
| --- | --- | ---: | ---: | ---: |
| small | parse zerde | 2,871 / 2,576 / 2,545 | 3,704 / 3,190 / 3,152 | 1.24 to 1.29 |
| small | parse zbor | 14,397 / 13,678 / 13,505 | 15,650 / 14,026 / 13,519 | 1.00 to 1.09 |
| small | write zerde | 1,032 / 1,036 / 1,014 | 2,178 / 1,681 / 1,637 | 1.61 to 2.11 |
| small | write zbor | 2,052 / 1,945 / 1,919 | 2,072 / 1,914 / 1,877 | 0.98 to 1.01 |
| small | roundtrip zerde | 3,804 / 3,693 / 3,637 | 5,535 / 5,025 / 5,033 | 1.36 to 1.45 |
| small | roundtrip zbor | 17,780 / 16,714 / 16,519 | 17,487 / 17,032 / 16,384 | 0.98 to 1.02 |
| medium | parse zerde | 799,794 / 787,411 / 777,556 | 951,972 / 936,934 / 930,515 | 1.19 to 1.20 |
| medium | parse zbor | 4,441,216 / 4,080,208 / 4,080,617 | 4,195,665 / 4,452,784 / 4,034,856 | 0.94 to 1.09 |
| medium | write zerde | 357,129 / 324,543 / 321,198 | 475,163 / 498,835 / 467,529 | 1.33 to 1.54 |
| medium | write zbor | 553,657 / 555,782 / 545,388 | 560,979 / 560,402 / 544,394 | 1.00 to 1.01 |
| medium | roundtrip zerde | 1,120,124 / 1,114,270 / 1,100,376 | 1,462,837 / 1,491,129 / 1,449,539 | 1.31 to 1.34 |
| medium | roundtrip zbor | 5,389,083 / 4,931,104 / 4,939,238 | 5,227,493 / 5,159,146 / 4,821,192 | 0.97 to 1.05 |
| large | parse zerde | 81,499,614 / 77,632,275 / 76,799,577 | 98,297,260 / 95,834,089 / 91,620,769 | 1.19 to 1.23 |
| large | parse zbor | 444,759,306 / 434,793,866 / 402,923,170 | 437,628,691 / 418,256,706 / 397,334,635 | 0.96 to 0.99 |
| large | write zerde | 34,868,052 / 33,124,857 / 32,230,361 | 52,222,203 / 48,076,968 / 47,129,465 | 1.45 to 1.50 |
| large | write zbor | 61,724,796 / 53,888,883 / 53,319,087 | 59,008,642 / 54,342,611 / 54,062,096 | 0.96 to 1.01 |
| large | roundtrip zerde | 116,518,666 / 110,060,465 / 108,862,282 | 153,673,572 / 143,130,211 / 142,517,663 | 1.30 to 1.32 |
| large | roundtrip zbor | 555,008,799 / 491,674,360 / 484,758,130 | 536,255,392 / 492,654,241 / 477,767,420 | 0.97 to 1.00 |

Notes:

- Every zerde row is slower in every pair: parse 1.19 to 1.29, write 1.33 to 2.11, roundtrip 1.30 to 1.46; zbor stayed within 0.94 to 1.09. The write regression is the largest default-path cost of the branch. A comptime gather parameter (removing the one optional branch of `emitBytes` and `emitRaw`) was measured and did not move the write rows (1,643 to 1,675 ns against 1,686 to 1,707 ns, small), so it was not committed. Which of the branch's write changes costs it is not measured here.
- Listed under "Default-path cost" in `plans/api.md`.

## 2026-11-23 - 4881395

Changes since previous run:

- reads validate text as UTF-8, check a length against the bytes left, record unknown map keys for a duplicate check, and match a struct key before validating it; the map is read through `nextObjectFieldIndex` with integer keys
- an integer field refuses a float, tags other than 55799 are refused, and a skipped value is walked with a depth bound

Environment for this entry only (not the machine above): `Linux x86_64`, Zig `0.17.1`. "Before" is `6e4bf79` built and run on the same machine in the same session, so only the two columns of this entry compare with each other. One run each, `zig build bench-cbor -Doptimize=ReleaseFast`.

| Operation | Scenario | Before zerde ns/op | After zerde ns/op | Change |
| --- | --- | ---: | ---: | ---: |
| parse | small | 6064.34 | 7205.65 | +18.8% |
| parse | medium | 1681485.84 | 1659759.61 | -1.3% |
| parse | large | 193767058.05 | 175726440.29 | -9.3% |
| write | small | 2962.43 | 2604.94 | -12.1% |
| write | medium | 757547.02 | 783635.11 | +3.4% |
| write | large | 85328802.81 | 84677747.56 | -0.8% |
| roundtrip | small | 9619.30 | 9936.19 | +3.3% |
| roundtrip | medium | 2833846.68 | 2422839.82 | -14.5% |
| roundtrip | large | 279455937.58 | 258466240.68 | -7.5% |

Notes:

- the write path moved by up to 12% on code that did not change for this payload, so changes under about 12% are inside this machine's run-to-run noise
- the small parse case is the one that may have slowed (+18.8%, outside that noise), and the medium and large cases do not show it; the likely cause is the per-string UTF-8 check and per-document setup, which weigh most on a small document [INFERENCE: not profiled]
- the payload has no unknown keys, so the duplicate check records nothing; a repeat run on the benchmark machine would settle the small parse case

## 2026-04-20 - 49d8ca8

Changes since previous run:

- added the first CBOR benchmark harness and `bench-cbor` build step
- parse measures `zerde` against `zbor` on the same canonical CBOR document per scenario
- the `zbor` parse timing includes `DataItem.new(...)` because that validation wrapper is part of its public typed parse path
- write and roundtrip use each library's own CBOR output size because the two serializers do not emit the exact same document

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | zbor ns/op | zbor MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,936 B | 1000000 | 2963.69 | 944.76 | 24204.02 | 115.68 | `zerde` 8.17x faster |
| medium | 806,470 B | 1000 | 934998.21 | 822.58 | 8219954.67 | 93.57 | `zerde` 8.79x faster |
| large | 79,925,027 B | 100 | 91059739.59 | 837.06 | 796041867.08 | 95.75 | `zerde` 8.74x faster |

### Write

| Scenario | zerde Size | zbor Size | Iterations | zerde ns/op | zerde MiB/s | zbor ns/op | zbor MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,936 B | 2,880 B | 1000000 | 1700.21 | 1646.85 | 2925.42 | 938.87 | `zerde` 1.72x faster |
| medium | 806,470 B | 796,256 B | 1000 | 491605.00 | 1564.49 | 941530.54 | 806.53 | `zerde` 1.91x faster |
| large | 79,925,027 B | 78,933,633 B | 100 | 50543477.08 | 1508.06 | 91421371.67 | 823.41 | `zerde` 1.81x faster |

### Roundtrip

| Scenario | zerde Size | zbor Size | Iterations | zerde ns/op | zerde MiB/s | zbor ns/op | zbor MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,936 B | 2,880 B | 1000000 | 4737.94 | 1181.94 | 30631.48 | 179.33 | `zerde` 6.46x faster |
| medium | 806,470 B | 796,256 B | 1000 | 1403336.92 | 1096.12 | 10050243.33 | 151.11 | `zerde` 7.16x faster |
| large | 79,925,027 B | 78,933,633 B | 100 | 139319860.41 | 1094.21 | 999369348.75 | 150.65 | `zerde` 7.17x faster |

### Notes

- `zbor` emits a slightly smaller document on this workload, but `zerde` still wins write throughput in all three scenarios.
- The biggest CBOR gap is parse and roundtrip, where the baseline's required `DataItem` validation step shows up clearly in the end-to-end numbers.
