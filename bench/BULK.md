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

### Trusted text (`trusted_text`), 2026-11-24

`zig build bench-bulk -Doptimize=ReleaseFast`, native x86_64, one run. A strict CBOR read of one 270 KiB ASCII text, through the pull
reader into the JSON value writer, with UTF-8 checked on the way in and out against `trusted_text = true` on both:
75.2 µs trusted, 82.9 µs checked (1.10x). Validation is 5 µs of the 83 here (native validation runs at about 50 GiB/s on ASCII);
the rest is the scan for characters to escape and the copy, about 63 µs. So the option removes the checks but not the cost that
dominates a long-text render; a faster scan or a copy of text known to need no escapes would be what gets near a plain `memcpy`.
On wasm without SIMD validation costs more (see the table above), so the option is worth more there; it was not measured.

## 2026-11-24 - vector scan and direct escape writes

Changes since previous run: `findStringSpecial` scans a `@Vector` of `std.simd.suggestVectorLength(u8)` bytes where there is one (native; WebAssembly
with `simd128`), the word version elsewhere; `writeEscaped` writes each escape into the writer's spare buffer when it has room, instead of one
`writeAll` per escape. The JSON parser and writer both go through these two functions.

Real text, not generated: `tests/typed_tests.zig` (212,041 bytes, 7,420 to escape: source with quotes, newlines, backslashes), `src/cbor.zig`
(111,309 bytes, 2,814 to escape) and `README.md` (30,822 bytes, 558 to escape), each escaped as the characters of a JSON string. Rows compare the new
code with the code before this change (word scan, one `writeAll` per escape).

### Native (`zig build bench-bulk -Doptimize=ReleaseFast`, ns per whole input, 2000 iterations, one run)

| Input | Operation | new ns | before ns | Relative |
| --- | --- | ---: | ---: | --- |
| code 1 | find special | 117347 | 190732 | 1.63x faster |
| code 1 | escape | 161152 | 231391 | 1.44x faster |
| code 2 | find special | 49317 | 87561 | 1.78x faster |
| code 2 | escape | 57498 | 98762 | 1.72x faster |
| prose | find special | 8343 | 14839 | 1.78x faster |
| prose | escape | 11698 | 23079 | 1.97x faster |

The 270 KiB ASCII text of the first entry: escape 24.9 µs (was 62.9), find special 13.3 µs (was 68.2). The strict CBOR to JSON render of it
fell from 75.2 µs to 37.9 µs (trusted) and from 82.9 to 42.6 µs (checked).

### WebAssembly (`-target wasm32-freestanding -OReleaseFast`, Node's V8, 200 calls each, three runs: the range)

| Input | Operation | no simd128, new (µs) | no simd128, before | simd128 (vector 16), new | simd128, before |
| --- | --- | --- | --- | --- | --- |
| code 1 | find special | 182-187 | 182-193 | 146-163 | 179-186 |
| code 1 | escape | 274-305 | 342-427 | 225-249 | 371-394 |
| code 2 | find special | 78-84 | 71-80 | 56-61 | 73-80 |
| code 2 | escape | 108-140 | 133-151 | 89-99 | 138-163 |
| prose | find special | 12-19 | 11-13 | 9-15 | 11-21 |
| prose | escape | 19-22 | 24-29 | 15-22 | 24-25 |

Without simd128 the scan is the same code as before (no change, within the noise), and the direct escape write gains 10-30% on code 1 and prose
and nothing clear on code 2. With simd128 the vector scan is 1.2-1.3x faster and the escapes 1.6x faster. Escapes in this text come every 30 to 70 bytes,
so the cost is mostly per escape; on long runs without one the vector scan is what counts (the ASCII row above).
