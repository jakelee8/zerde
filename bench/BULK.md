# String Scan Benchmark

This file is a running log of the word-at-a-time string scans in `zerde.bulk` against the standard library
and a byte-wise loop.

## Environment

- Machine: `Linux x86_64` (a container)
- Zig: `0.17.1`
- Native command: `zig build bench-bulk -Doptimize=ReleaseFast`
- WebAssembly: the same functions built with `-target wasm32-freestanding -O ReleaseFast` (no `simd128`) and timed
  in Node's V8, 100 calls each on the same inputs; this was an ad hoc script, not a build step

## Workload

270 KiB inputs of three shapes: `ascii` (letters only), `escapes` (the same with a `"` or a newline every
61 bytes) and `multibyte` (the euro sign repeated). Three operations: UTF-8 validation, escaping as the
characters of a JSON string, and finding the next byte a JSON string cannot hold as it is.

## 2026-11-23 - dbbe32f

Changes since previous run: first entry. `bulk.validUtf8` is the standard library's validator where that skips
ASCII in vector chunks and `validUtf8Words` elsewhere; the table shows both.

### Native (ns per 270 KiB operation, 2000 iterations)

| Input | Operation | bulk ns | std or byte-wise ns | Relative |
| --- | --- | ---: | ---: | --- |
| ascii | validate utf-8 (`validUtf8`) | 6308 | 6020 | 0.95x (same code path, noise) |
| ascii | validate utf-8 (`validUtf8Words`) | 17129 | 5910 | 0.35x |
| ascii | escape | 72724 | 179659 | 2.47x faster |
| ascii | find special | 72997 | 162378 | 2.22x faster |
| escapes | escape | 111494 | 207105 | 1.86x faster |
| escapes | find special | 98849 | 219178 | 2.22x faster |
| multibyte | validate utf-8 (`validUtf8Words`) | 264203 | 275548 | 1.04x |
| multibyte | escape | 65646 | 175643 | 2.68x faster |
| multibyte | find special | 71608 | 168562 | 2.35x faster |

Native, the standard library's validator vectorizes the ASCII skip and beats the word-at-a-time one, which is why
`validUtf8` calls it there.

### WebAssembly without SIMD (Node/V8, ns per call)

| Input | Operation | bulk ns | std or byte-wise ns | Relative |
| --- | --- | ---: | ---: | --- |
| ascii | validate utf-8 (`validUtf8Words`) | 41270 | 152699 | 3.7x faster |
| mixed (a euro sign every 500 bytes) | validate utf-8 (`validUtf8Words`) | 37835 | 157641 | 4.2x faster |
| multibyte | validate utf-8 (`validUtf8Words`) | 329858 | 294988 | 0.89x |
| ascii | escape | 101473 | 403563 | 4.0x faster |
| mixed | escape | 88244 | 383228 | 4.3x faster |
| ascii | find special | 84693 | 150467 | 1.8x faster |

Without SIMD the standard library has no ASCII fast path, so the word-at-a-time scan is the win there.

### Notes

- `zig build bench-json -Doptimize=ReleaseFast` on the same machine after this change, against the 2026-11-23 entry in
  `JSON.md`: parse small -6.4%, medium +6.3%, large +0.7%; write small +12.3%, medium -7.8%, large +14.6%. That is inside
  the noise of that benchmark (its own write path moved by up to 10% with no change to it), and its strings are short, so
  it does not show the gain on long strings above. A repeat on the benchmark machine would settle it.
- The multibyte validation is not faster than the standard library's on either target; the scans help text that is mostly ASCII.
