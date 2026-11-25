# BSON Benchmark

This file is a running log of BSON benchmark results for `zerde` against `zig-bson`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-bson -Doptimize=ReleaseFast`

## Workload

Current harness uses the same mixed nested payload family as the JSON benchmark, encoded as BSON:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` struct with a renamed `publicURL` field
- an `endpoints` array of structs with bools, enums, optionals, and fixed float arrays
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and fixed string arrays
- an `events` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and fixed arrays
- parse measured against one canonical BSON document per scenario

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

This run uses a signed-integer and string-signature payload because that is the shared typed subset both libraries support cleanly.

## 2026-11-25 - 52757c8

The whole branch against its base, on the default path (no new option set).

Base is `03beb0e` (`origin/zig-0.17`, where this branch started); tip is `52757c8` (`fix/library-review`, the source of every later commit of the branch). `Linux x86_64` (WSL2, 24 cores, shared), Zig `0.17.1`; three runs each, alternating base and tip suite by suite, `zig build bench-bson -Doptimize=ReleaseFast` under one `flock`. Load average 2 to 10 during the runs; the comparison library's rows are the control for the machine.

Expected from the repeated-key change (`5870942`): a key record in an untyped read and for each unknown member a typed read skips, and MessagePack and BSON walking a skipped value; this payload has no unknown members and these rows read no untyped value, so none of it shows here (see the `5870942` section of `bench/JSON.md` for the untyped cost).

| Scenario | Row | Base ns/op (3 runs) | Tip ns/op (3 runs) | Tip / base |
| --- | --- | ---: | ---: | ---: |
| small | parse zerde | 2,763 / 2,719 / 2,582 | 2,137 / 2,151 / 2,157 | 0.77 to 0.84 |
| small | parse zig-bson | 23,461 / 22,762 / 21,732 | 22,039 / 22,119 / 21,993 | 0.94 to 1.01 |
| small | write zerde | 16,727 / 15,132 / 13,700 | 14,074 / 14,206 / 13,652 | 0.84 to 1.00 |
| small | write zig-bson | 97,569 / 88,751 / 85,688 | 87,370 / 87,723 / 84,962 | 0.90 to 0.99 |
| small | roundtrip zerde | 18,455 / 18,391 / 16,803 | 16,895 / 17,312 / 16,308 | 0.92 to 0.97 |
| small | roundtrip zig-bson | 115,661 / 112,036 / 108,371 | 109,555 / 113,150 / 107,559 | 0.95 to 1.01 |
| medium | parse zerde | 822,935 / 824,445 / 804,171 | 654,247 / 669,609 / 651,623 | 0.80 to 0.81 |
| medium | parse zig-bson | 10,430,575 / 10,344,723 / 9,487,913 | 9,616,137 / 10,750,909 / 9,142,333 | 0.92 to 1.04 |
| medium | write zerde | 1,402,716 / 1,414,045 / 1,444,227 | 1,391,890 / 1,386,812 / 1,392,332 | 0.96 to 0.99 |
| medium | write zig-bson | 14,146,985 / 13,498,975 / 12,738,047 | 13,094,462 / 12,881,380 / 12,338,125 | 0.93 to 0.97 |
| medium | roundtrip zerde | 2,279,156 / 2,227,319 / 2,209,144 | 2,078,797 / 2,081,105 / 2,061,012 | 0.91 to 0.93 |
| medium | roundtrip zig-bson | 28,002,290 / 25,546,771 / 24,988,072 | 26,320,034 / 26,567,812 / 24,865,228 | 0.94 to 1.04 |
| large | parse zerde | 82,807,414 / 81,164,470 / 80,136,323 | 65,563,183 / 68,191,471 / 65,437,230 | 0.79 to 0.84 |
| large | parse zig-bson | 1,273,635,194 / 1,279,997,585 / 1,227,002,128 | 1,303,439,478 / 1,265,660,573 / 1,248,570,125 | 0.99 to 1.02 |
| large | write zerde | 151,855,491 / 145,984,281 / 145,619,594 | 156,857,777 / 146,664,996 / 147,068,774 | 1.00 to 1.03 |
| large | write zig-bson | 1,396,840,484 / 1,371,059,878 / 1,312,273,516 | 1,382,011,421 / 1,420,293,846 / 1,315,675,571 | 0.99 to 1.04 |
| large | roundtrip zerde | 233,042,585 / 232,946,116 / 225,773,780 | 214,587,865 / 218,802,120 / 212,187,819 | 0.92 to 0.94 |
| large | roundtrip zig-bson | 2,697,862,546 / 2,659,223,369 / 2,518,652,490 | 2,805,007,495 / 2,798,834,002 / 2,566,364,205 | 1.02 to 1.05 |

Notes:

- The zerde parse is faster in every pair (0.77 to 0.84): a typed read matches a key to a field where it reads it (`nextObjectFieldIndex`, added with the repeated-key change). Write 0.84 to 1.03, roundtrip 0.91 to 0.97; `zig-bson` moved 0.89 to 1.05. No default-path cost.

## 2026-04-21 - ced89d0

Changes since previous run:

- reran the BSON benchmark on current `HEAD` after the parse-path intermediate string copy removal work landed in other binary backends
- no BSON-specific serializer or deserializer changes landed in this commit
- this entry refreshes the BSON baseline for the current tree

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | zig-bson ns/op | zig-bson MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,210 B | 1000000 | 2738.99 | 1465.86 | 15522.30 | 258.66 | `zerde` 5.67x faster |
| medium | 1,198,550 B | 1000 | 833628.16 | 1371.15 | 7079321.30 | 161.46 | `zerde` 8.49x faster |
| large | 118,617,999 B | 100 | 83137194.55 | 1360.68 | 880919890.43 | 128.41 | `zerde` 10.60x faster |

### Write

| Scenario | zerde Size | zig-bson Size | Iterations | zerde ns/op | zerde MiB/s | zig-bson ns/op | zig-bson MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,210 B | 4,210 B | 1000000 | 8329.64 | 482.01 | 36153.72 | 111.05 | `zerde` 4.34x faster |
| medium | 1,198,550 B | 1,198,550 B | 1000 | 2084018.40 | 548.47 | 6580587.45 | 173.70 | `zerde` 3.16x faster |
| large | 118,617,999 B | 118,617,999 B | 100 | 241016454.99 | 469.36 | 741682658.72 | 152.52 | `zerde` 3.08x faster |

### Roundtrip

| Scenario | zerde Size | zig-bson Size | Iterations | zerde ns/op | zerde MiB/s | zig-bson ns/op | zig-bson MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,210 B | 4,210 B | 1000000 | 11375.14 | 705.92 | 58730.76 | 136.72 | `zerde` 5.16x faster |
| medium | 1,198,550 B | 1,198,550 B | 1000 | 2864707.79 | 798.01 | 14374452.91 | 159.04 | `zerde` 5.02x faster |
| large | 118,617,999 B | 118,617,999 B | 100 | 321414933.71 | 703.91 | 1546148385.86 | 146.33 | `zerde` 4.81x faster |

### Notes

- BSON remains one of the strongest baseline wins in the package even on a rerun with no BSON-specific code changes.
- Large write regressed from the last BSON-focused optimization run, but `zerde` still stays clearly ahead on parse, write, and roundtrip.

## 2026-04-21 - 352166c

Changes since previous run:

- flattened BSON serialization into one contiguous output buffer
- switched nested BSON documents and arrays to in-place length backpatching instead of per-frame temporary buffers
- removed the remaining nested-document copy step on the write path

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | zig-bson ns/op | zig-bson MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,210 B | 1000000 | 2722.57 | 1474.70 | 14822.31 | 270.87 | `zerde` 5.44x faster |
| medium | 1,198,550 B | 1000 | 838012.67 | 1363.97 | 6124481.34 | 186.63 | `zerde` 7.31x faster |
| large | 118,617,999 B | 100 | 81112045.45 | 1394.65 | 803683736.26 | 140.76 | `zerde` 9.91x faster |

### Write

| Scenario | zerde Size | zig-bson Size | Iterations | zerde ns/op | zerde MiB/s | zig-bson ns/op | zig-bson MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,210 B | 4,210 B | 1000000 | 6961.70 | 576.72 | 33324.54 | 120.48 | `zerde` 4.79x faster |
| medium | 1,198,550 B | 1,198,550 B | 1000 | 1698452.53 | 672.98 | 5733876.78 | 199.35 | `zerde` 3.38x faster |
| large | 118,617,999 B | 118,617,999 B | 100 | 183895481.26 | 615.15 | 598149069.24 | 189.12 | `zerde` 3.25x faster |

### Roundtrip

| Scenario | zerde Size | zig-bson Size | Iterations | zerde ns/op | zerde MiB/s | zig-bson ns/op | zig-bson MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,210 B | 4,210 B | 1000000 | 10794.47 | 743.89 | 50223.86 | 159.88 | `zerde` 4.65x faster |
| medium | 1,198,550 B | 1,198,550 B | 1000 | 2529969.59 | 903.59 | 11894976.17 | 192.19 | `zerde` 4.70x faster |
| large | 118,617,999 B | 118,617,999 B | 100 | 266686571.24 | 848.36 | 1401168325.44 | 161.47 | `zerde` 5.25x faster |

### Notes

- The BSON rewrite turned write from the slowest part of the comparison into a clear win in every scenario.
- BSON now joins CBOR as a binary format where `zerde` is substantially ahead on parse, write, and roundtrip.
