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

## 2026-11-25 - e07eb8c

Changes since previous run: the vector scan for a string's end reads its first match as a bit mask on a little-endian target; `std.simd.firstTrue` took a horizontal minimum, which on this machine (64-lane vectors, AVX-512) cost more than the scan. The scan can also note a byte of 0x80 or above, which the JSON reader uses and these rows do not.

"Before" is `025086f`, "after" `e07eb8c`; `Linux x86_64` (WSL2, 24 cores, AMD Ryzen 9 9900X, AVX-512, shared), Zig `0.17.1`; three runs each, alternating, `zig build bench-bulk -Doptimize=ReleaseFast` under one `flock`. The "bulk" column, µs per operation. "code 2" is `src/cbor.zig`, which this change edits, so it is left out.

| Row | Before µs (3 runs) | After µs (3 runs) | After / before |
| --- | ---: | ---: | ---: |
| ascii, escape | 5.0 / 5.3 / 5.1 | 4.6 / 4.7 / 4.6 | 0.88 to 0.91 |
| ascii, find special | 3.6 / 3.1 / 3.1 | 2.5 / 2.6 / 2.6 | 0.71 to 0.82 |
| escapes, escape | 55.0 / 58.5 / 54.3 | 22.1 / 22.2 / 21.9 | 0.38 to 0.40 |
| escapes, find special | 52.6 / 56.3 / 52.6 | 20.0 / 19.9 / 20.1 | 0.35 to 0.38 |
| multibyte, escape | 5.1 / 5.2 / 5.3 | 4.7 / 4.7 / 4.6 | 0.88 to 0.91 |
| multibyte, find special | 3.1 / 3.1 / 3.1 | 2.5 / 2.7 / 2.6 | 0.81 to 0.85 |
| code 1, find special | 183.6 / 184.5 / 183.0 | 69.2 / 70.0 / 69.2 | 0.38 to 0.38 |
| code 1, escape | 200.4 / 201.8 / 199.3 | 90.8 / 93.2 / 90.5 | 0.45 to 0.46 |
| prose, find special | 9.0 / 9.0 / 8.9 | 3.5 / 3.4 / 3.5 | 0.38 to 0.39 |
| prose, escape | 9.9 / 9.8 / 9.8 | 4.5 / 4.7 / 4.5 | 0.45 to 0.48 |
| ascii, cbor to json render (trusted) | 12.3 / 13.3 / 12.3 | 11.5 / 12.4 / 11.6 | 0.93 to 0.94 |
| escapes6, escape, 64 KiB windows | 573.0 / 587.7 / 573.4 | 233.6 / 236.4 / 229.4 | 0.40 to 0.41 |
| escapes6, render, 64 KiB windows | 577.1 / 577.7 / 577.7 | 232.0 / 235.1 / 234.5 | 0.40 to 0.41 |

## 2026-11-24 - 52757c8

Changes since previous run: the windowed JSON escape (`json.writeEscapedPart`) writes an escape straight into the window
instead of through a temporary, and `resumable.Render` skips the UTF-8 check of each text it writes, which its first window
has already made. New rows on `escapes6` (270 KiB of `a`..`z` with every sixth byte a `"`): "escape, 64 KiB windows"
(the windowed escape, trusted, against `escapeBulk` into one buffer) and "render, 64 KiB windows" (`resumable.Render`
against the pull reader into the JSON value writer). The "bulk" column is the windowed path, "std" the whole-buffer one.

"Before" is `ea4de6f` (the rows, unchanged code), "after" `52757c8`; three runs each, alternating, under one `flock`, on a
shared 24-core WSL2 machine. µs per operation, run 1 / run 2 / run 3.

| Row | Before: windowed | Before: whole | After: windowed | After: whole |
| --- | ---: | ---: | ---: | ---: |
| escape, 64 KiB windows | 610 / 591 / 649 | 554 / 551 / 544 | 579 / 601 / 582 | 550 / 584 / 557 |
| render, 64 KiB windows | 619 / 603 / 589 | 577 / 564 / 564 | 620 / 592 / 602 | 577 / 573 / 574 |

The windowed escape gains a few percent (0.84 to 0.93 of the whole-buffer speed before, 0.95 to 0.97 after); the render
moves within the run-to-run spread, so the check it no longer repeats was not a measurable part of its cost here. Both
windowed paths are within 10% of the whole-buffer ones.

## 2026-11-24 - ad684a0

Changes since previous run: the JSON value writer no longer measures a key, text or byte string (`escapedLen`, a second scan of
the whole string) when `max_container_bytes` is unbounded, the default. The only row that writes through it is the render
of a long ASCII text; the scans above are unchanged code. Measured on the same machine (a Linux x86_64 container, Zig 0.17.1,
`zig build bench-bulk -Doptimize=ReleaseFast` under the executor lock), `dfe52b1` (before) against the tree with this change
(after), one run each in turn; the first run of `dfe52b1` was not kept, so it has two runs.

| Run | before: trusted ns | before: checked ns | after: trusted ns | after: checked ns |
| --- | ---: | ---: | ---: | ---: |
| 1 | not kept | not kept | 35008 | 48132 |
| 2 | 61026 | 61594 | 38999 | 50421 |
| 3 | 46993 | 59585 | 35739 | 50828 |

Each is ns for one render of the 270 KiB ASCII text, from strict CBOR into the JSON value writer ("cbor to json render, trusted
vs checked" in the output; trusted skips the UTF-8 check on the way in and out). The run-to-run spread of the unchanged code
is large (the other rows of the same runs moved by up to 20%), so the figures show the direction, not a ratio. A render of
unicode text is not a row of this benchmark and was not measured here.

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

## 2026-11-24 - 3461d9c

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
