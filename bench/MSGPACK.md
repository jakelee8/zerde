# MessagePack Benchmark

This file is a running log of MessagePack benchmark results for `zerde` against `msgpack.zig`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-msgpack -Doptimize=ReleaseFast`

## Workload

Current harness uses the same mixed nested payload family as the JSON benchmark, encoded as MessagePack:

- top-level scalars, enums, optionals, and slices
- a nested `metadata` struct with booleans, integers, and strings
- an `endpoints` array of structs with bools, enums, optionals, and float slices
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and string-slice labels
- an `events` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and scalar slices
- parse measured against one canonical MessagePack document per scenario

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

This run uses the baseline library's MessagePack output as the shared parse input so both libraries consume the same enum representation.

## 2026-11-25 - 52757c8

The whole branch against its base, on the default path (no new option set).

Base is `03beb0e` (`origin/zig-0.17`, where this branch started); tip is `52757c8` (`fix/library-review`, the source of every later commit of the branch). `Linux x86_64` (WSL2, 24 cores, shared), Zig `0.17.1`; three runs each, alternating base and tip suite by suite, `zig build bench-msgpack -Doptimize=ReleaseFast` under one `flock`. Load average 2 to 10 during the runs; the comparison library's rows are the control for the machine.

Expected from the repeated-key change (`5870942`): a key record in an untyped read and for each unknown member a typed read skips, and MessagePack and BSON walking a skipped value; this payload has no unknown members and these rows read no untyped value, so none of it shows here (see the `5870942` section of `bench/JSON.md` for the untyped cost).

| Scenario | Row | Base ns/op (3 runs) | Tip ns/op (3 runs) | Tip / base |
| --- | --- | ---: | ---: | ---: |
| small | parse zerde | 2,533 / 2,496 / 2,407 | 2,169 / 2,173 / 2,104 | 0.86 to 0.87 |
| small | parse msgpack.zig | 2,823 / 2,513 / 2,681 | 2,711 / 2,517 / 2,494 | 0.93 to 1.00 |
| small | write zerde | 787 / 774 / 767 | 773 / 763 / 774 | 0.98 to 1.01 |
| small | write msgpack.zig | 921 / 892 / 888 | 935 / 901 / 898 | 1.01 to 1.02 |
| small | roundtrip zerde | 3,264 / 3,254 / 3,306 | 3,373 / 3,011 / 2,938 | 0.89 to 1.03 |
| small | roundtrip msgpack.zig | 3,434 / 3,416 / 3,644 | 3,543 / 3,469 / 3,430 | 0.94 to 1.03 |
| medium | parse zerde | 809,462 / 799,090 / 796,477 | 798,249 / 715,726 / 687,802 | 0.86 to 0.99 |
| medium | parse msgpack.zig | 629,254 / 616,432 / 679,691 | 751,639 / 648,928 / 655,918 | 0.97 to 1.19 |
| medium | write zerde | 249,853 / 229,551 / 240,004 | 283,269 / 229,833 / 241,065 | 1.00 to 1.13 |
| medium | write msgpack.zig | 283,299 / 274,568 / 273,192 | 282,273 / 275,940 / 288,222 | 1.00 to 1.06 |
| medium | roundtrip zerde | 1,064,337 / 1,035,046 / 1,033,608 | 942,708 / 972,003 / 934,037 | 0.89 to 0.94 |
| medium | roundtrip msgpack.zig | 906,091 / 895,956 / 951,486 | 916,963 / 1,095,685 / 945,251 | 0.99 to 1.22 |
| large | parse zerde | 81,125,238 / 78,832,933 / 78,886,053 | 73,924,362 / 79,478,138 / 68,319,441 | 0.87 to 1.01 |
| large | parse msgpack.zig | 63,600,188 / 62,365,409 / 67,392,749 | 68,486,144 / 67,545,444 / 66,387,899 | 0.99 to 1.08 |
| large | write zerde | 27,004,328 / 24,425,320 / 24,157,972 | 25,043,731 / 23,952,615 / 24,175,908 | 0.93 to 1.00 |
| large | write msgpack.zig | 28,859,357 / 27,505,269 / 27,648,889 | 30,198,679 / 29,536,715 / 27,662,345 | 1.00 to 1.07 |
| large | roundtrip zerde | 109,496,266 / 104,521,820 / 102,216,902 | 99,153,629 / 95,192,977 / 92,595,337 | 0.91 to 0.91 |
| large | roundtrip msgpack.zig | 95,004,705 / 91,408,879 / 94,414,055 | 96,883,309 / 95,184,813 / 93,584,291 | 0.99 to 1.04 |

Notes:

- The zerde parse is faster (0.86 to 1.01), the write unchanged (0.93 to 1.13) and the roundtrip faster (0.89 to 1.03); `msgpack.zig` moved 0.93 to 1.22. No default-path cost.

## 2026-04-21 - 500513c

Changes since previous run:

- definite-length streaming arrays now consume their known element counts directly and close once, instead of paying an item-boundary call for every element
- MessagePack object reads now resolve map keys straight to typed field indexes on the hot path
- shared typed field matching now buckets candidate names by length before falling back to exact byte comparison

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 1000000 | 2824.97 | 904.06 | 3280.92 | 778.42 | `zerde` 1.16x faster |
| medium | 728,807 B | 1000 | 886409.36 | 784.11 | 866966.33 | 801.70 | `msgpack.zig` 1.02x faster |
| large | 72,267,214 B | 100 | 88089157.45 | 782.38 | 86595374.62 | 795.88 | `msgpack.zig` 1.02x faster |

### Write

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 1381.92 | 1848.12 | 1356.43 | 1882.84 | `msgpack.zig` 1.02x faster |
| medium | 728,679 B | 728,807 B | 1000 | 404100.75 | 1719.68 | 416559.07 | 1668.54 | `zerde` 1.03x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 40200141.61 | 1714.13 | 41283827.11 | 1669.40 | `zerde` 1.03x faster |

### Roundtrip

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 4228.69 | 1207.91 | 4958.97 | 1030.03 | `zerde` 1.17x faster |
| medium | 728,679 B | 728,807 B | 1000 | 1291313.37 | 1076.30 | 1291738.82 | 1076.14 | `zerde` 1.00x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 127788007.04 | 1078.48 | 128469128.33 | 1072.93 | `zerde` 1.01x faster |

### Notes

- This pass closes most of the remaining MessagePack read gap without changing the wire format or narrowing supported semantics.
- Parse is now clearly ahead on the small case and within about `2%` on the medium and large cases; write stays ahead on the medium and large cases.

## 2026-04-21 - 565b6be

Changes since previous run:

- pre-encoded MessagePack field keys at comptime so repeated struct field names no longer rebuild their string headers at runtime
- added direct inline field-value emission for scalar, string, byte, optional, and scalar-sequence fields
- specialized MessagePack scalar-sequence writes for arrays and slices of bools, numbers, enums, strings, and bytes
- tightened enum-tag and field-name handling on the read path without changing the wire format under test

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 1000000 | 3419.00 | 746.98 | 3388.02 | 753.81 | `msgpack.zig` 1.01x faster |
| medium | 728,807 B | 1000 | 1057704.96 | 657.13 | 914704.48 | 759.86 | `msgpack.zig` 1.16x faster |
| large | 72,267,214 B | 100 | 107489919.15 | 641.17 | 91732676.23 | 751.31 | `msgpack.zig` 1.17x faster |

### Write

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 1424.37 | 1793.03 | 1405.30 | 1817.37 | `msgpack.zig` 1.01x faster |
| medium | 728,679 B | 728,807 B | 1000 | 414245.29 | 1677.56 | 420558.14 | 1652.67 | `zerde` 1.02x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 41162997.88 | 1674.04 | 41914015.83 | 1644.30 | `zerde` 1.02x faster |

### Roundtrip

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 4875.79 | 1047.60 | 5154.56 | 990.94 | `zerde` 1.06x faster |
| medium | 728,679 B | 728,807 B | 1000 | 1467359.60 | 947.17 | 1343465.95 | 1034.70 | `msgpack.zig` 1.09x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 147602240.87 | 933.70 | 134519315.01 | 1024.68 | `msgpack.zig` 1.10x faster |

### Notes

- This pass nearly eliminated the MessagePack write gap: the baseline's `~22%` write lead on medium and large is now a slight `zerde` win.
- Parse is still the main remaining deficit, so roundtrip improved but does not yet beat the baseline on the medium and large scenarios.

## 2026-04-21 - 42e7ed3

Changes since previous run:

- added the first MessagePack benchmark harness and `bench-msgpack` build step
- vendored and patched `msgpack.zig` for Zig `0.16`
- switched `zerde`'s MessagePack enum encoding to compact numeric tags
- parse measures both libraries against the same baseline-encoded MessagePack payload per scenario

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 1000000 | 3345.77 | 763.33 | 3325.23 | 768.05 | `msgpack.zig` 0.6% faster |
| medium | 728,807 B | 1000 | 1031567.20 | 673.78 | 910726.20 | 763.18 | `msgpack.zig` 1.13x faster |
| large | 72,267,214 B | 100 | 103025607.49 | 668.95 | 90392317.13 | 762.45 | `msgpack.zig` 1.14x faster |

### Write

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 1691.64 | 1509.74 | 1334.71 | 1913.48 | `msgpack.zig` 1.27x faster |
| medium | 728,679 B | 728,807 B | 1000 | 498382.62 | 1394.36 | 408262.15 | 1702.45 | `msgpack.zig` 1.22x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 49482804.21 | 1392.57 | 40453282.10 | 1703.68 | `msgpack.zig` 1.22x faster |

### Roundtrip

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 5096.78 | 1002.18 | 4890.09 | 1044.54 | `msgpack.zig` 1.04x faster |
| medium | 728,679 B | 728,807 B | 1000 | 1540764.22 | 902.05 | 1322876.74 | 1050.81 | `msgpack.zig` 1.16x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 153151492.98 | 899.87 | 130947336.23 | 1052.63 | `msgpack.zig` 1.17x faster |

### Notes

- Numeric enum tags closed the output-size gap, but the baseline still wins raw parse and write throughput.
- `zerde` now emits a slightly smaller document than `msgpack.zig` on the medium and large scenarios, so the remaining gap is execution cost rather than inflated output size.
