# Wire decode benchmark history

`zig build bench-wire -Doptimize=ReleaseFast` decodes a commit of effects (a put for every 24 lines of
`tests/typed_tests.zig`, `src/cbor.zig` and `README.md`, a delete after each seventh) with `zerde.wire.decode`,
in strict CBOR and in JSON (bytes as base64, the text with its escapes). The corpus is this repository's own
text, so its size follows the files: compare rows by bytes and effects, not by the totals alone. "Arena used"
is `end_index` when the decode is done, "peak" the furthest byte it wrote, "bound" is `wire.maxArenaSize`.
Time is ns for one decode, 200 decodes, two runs back to back under `flock`, load about 2. The corpus changed between the
first section and the second (the files this benchmark read were edited by the work itself), so each section compares
its own before and after, measured in the same session on the same input.

## 2026-11-24 - 3bd3e6a

New rows: the decode in chunks and the render in windows, against the whole ones, on the fixed corpus of the 41c3439 section (301,382 B of
strict CBOR, 195 effects; 358,403 B of JSON). Runs under `flock`, shared machine, so ratios are read, not the absolute times (the unchanged
whole decode moved between 38 and 64 µs across three runs).

|Row|Memory|Time (three runs)|
|---|---|---|
|`wire.decode`, whole input, spans into it|arena 5,462 B (input held whole)|39.4, 63.8, 38.4 µs|
|`wire.Resumable`, chunks of 4, 16, 64 KiB|region 301,548 B (every string copied), state 9,624 B|about 2.0x of the whole (1.2x in the noisy run)|
|pull reader into `json.valueWriter`, whole|358,403 B output buffer, plus a buffer per open map|8.9 to 9.9 ms|
|`resumable.Render`, windows of 4, 16, 64 KiB|the window, state 3,408 B|0.30 to 0.46 ms (0.03 to 0.05x)|

- The decode in chunks copies the strings, so its region is about the size of the input; a mode that leaves them in the caller's buffer is the next step.
- The windowed render is far under the whole render because it buffers and sorts nothing; the windows cost nothing measurable over each other.
- The destination-passing typed read (every format) measured the same as before within the spread: bench-cbor, bench-json and bench-wire
  decode rows, base against this tree, alternating; bench-memory output identical.

## 2026-11-23 - 879332e before, direct decode after

`wire.decode` reads straight into `Wire(T)`, with no typed value and no typed array first.

| Read | Input / effects | Arena used (before, after) | Bound (before, after) | Time (before, after) |
| --- | --- | --- | --- | --- |
| strict CBOR | 723,857 B, 349 effects / 727,234 B, 353 effects | 29,323 B, 9,886 B | 344,343 B, 114,947 B | 91,024 and 105,824 ns, 86,536 and 87,328 ns |
| JSON | 858,873 B, 349 effects / 862,968 B, 353 effects | 780,995 B, 748,240 B | 18,338,751 B, 17,799,272 B | 846,156 and 911,056 ns, 849,690 and 919,839 ns |

- Memory: the arena of a strict CBOR decode falls to a third (29.3 KB to 9.9 KB: 84 to 28 bytes an effect; the typed
  array of unions and the typed puts are gone). In JSON the arena is dominated by the base64 payloads and escaped text
  that are rewritten, so the saving is the typed array only: 4%.
- Time: strict CBOR is 5 to 18% faster (it no longer walks its list twice); JSON is unchanged within the run-to-run
  spread (0.97 to 1.01 times). The sink adds no cost measured.
- The corpus grew by four effects between the two rows because the repository's files did; per effect the figures
  above hold.

## 2026-11-23 - 41c3439 before, exact-size strings after

A rewritten string (a JSON string with an escape, a chunked CBOR string, base64 bytes) is measured first and
written once, exactly sized; a base64 string with escapes is decoded from its unescaped text a chunk at a time, so
its token is never built; a skipped chunked string is checked and not buffered. The corpus here is fixed files
(`bench/common.zig`, `vendor/zig-bson/src/root.zig`, `bench/BIN.md`), so later rows compare; "json escaped" is the
same JSON with every `/` written as `\/`, as some producers do. Input 301,382 B and 195 effects in CBOR, 358,403 B
(358,651 B escaped) in JSON.

| Read | Arena used (before, after) | Bound (before, after) | Time, two runs (before; after) |
| --- | --- | --- | --- |
| strict CBOR | 5,462 B, 5,462 B | 114,947 B, 114,947 B | 43,147 and 43,559 ns; 41,918 and 41,063 ns |
| JSON | 315,587 B, 315,587 B | 17,799,272 B, 8,886,248 B | 369,190 and 362,979 ns; 420,359 and 415,063 ns |
| JSON, slashes escaped | 321,999 B, 315,587 B | 17,799,272 B, 8,886,248 B | 389,474 and 371,400 ns; 455,824 and 473,887 ns |

- Memory: the arena used is the same for plain JSON (nothing there was rewritten that was not already exact) and falls
  2% when the base64 is escaped (the token of each payload is no longer built before it is decoded). The bound falls to
  half (17.8 MB to 8.9 MB) because it no longer charges the base64 token or the growth of a string buffer; this
  is the memory this item saves, since the used arena is not what the bound measures.
- Time: JSON costs 13 to 15% more (plain) and 17 to 28% more (escaped), the second scan the item names (the measure
  pass, which also UTF-8 checks, and the write pass, which does not). Compute against memory: on this corpus the
  memory saved is the bound and the transient growth, which a fixed arena of exactly the bound cares about, and the
  time paid is the second scan of each base64 or escaped string. Strict CBOR is unchanged. Whoever decides for the kernel
  frames (strict CBOR, no rewrite) pays nothing.
