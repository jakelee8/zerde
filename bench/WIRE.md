# Wire decode benchmark history

`zig build bench-wire -Doptimize=ReleaseFast` decodes a commit of effects with `zerde.wire.decode`, in strict CBOR and in JSON (bytes as base64, the text with its escapes). The commit has a put for every 24 lines of `tests/typed_tests.zig`, `src/cbor.zig` and `README.md`, and a delete after each seventh put. The corpus is this repository's own text, so its size follows the files: compare rows by bytes and effects, not by totals alone. "Arena used" is `end_index` when the decode is done, "peak" is the furthest byte written, and "bound" is `wire.maxArenaSize`.
Time is ns for one decode, over 200 decodes, in two runs back to back under `flock` at load about 2. The corpus changes when the files it reads change, so each section compares only its own before and after, measured in the same session on the same input.

## 2026-11-24 - 3bd3e6a

New rows: the decode in chunks and the render in windows, against the whole-input versions, on the fixed corpus of the `2026-11-23 - e343755` section (301,382 B of strict CBOR, 195 effects; 358,403 B of JSON). The runs were under `flock` on a shared machine, so read the ratios, not the absolute times: the unchanged whole decode moved between 38 and 64 µs across three runs.

|Row|Memory|Time (three runs)|
|---|---|---|
|`wire.decode`, whole input, spans into it|arena 5,462 B (input held whole)|39.4, 63.8, 38.4 µs|
|`wire.Resumable`, chunks of 4, 16, 64 KiB|region 301,548 B (every string copied), state 9,624 B|about 2.0x of the whole (1.2x in the noisy run)|
|`wire.StreamResumable`, chunks of 4 and 64 KiB (strings left in the stream)|region 5,460 B (the arrays only; bound 114,947 B)|1.7 to 1.9x of the whole, two runs|
|pull reader into `json.valueWriter`, whole|358,403 B output buffer, plus a buffer per open map|8.9 to 9.9 ms|
|`resumable.Render`, windows of 4, 16, 64 KiB|the window, state 3,408 B|0.30 to 0.46 ms (0.03 to 0.05x)|

- The chunked decode copies the strings, so its region is about the size of the input. `wire.StreamResumable` leaves them in the stream.
- The windowed render is far faster than the whole render because it buffers and sorts nothing. Window size makes no measurable difference.
- The destination-passing typed read (every format) measured the same as before within the spread. The comparison used the bench-cbor, bench-json and bench-wire decode rows, base against this tree, alternating. The bench-memory output is identical.

## 2026-11-23 - e343755

A rewritten string (a JSON string with an escape, a chunked CBOR string, base64 bytes) is measured first and then written once, exactly sized. A base64 string with escapes is decoded from its unescaped text one chunk at a time, so its token is never built. A skipped chunked string is checked and not buffered. The corpus here is fixed files (`bench/common.zig`, `vendor/zig-bson/src/root.zig`, `bench/BIN.md`), so later rows compare. "json escaped" is the same JSON with every `/` written as `\/`, as some producers do. Input is 301,382 B and 195 effects in CBOR, and 358,403 B (358,651 B escaped) in JSON. Before is `41c3439`, after is `e343755`.

| Read | Arena used (before, after) | Bound (before, after) | Time, two runs (before; after) |
| --- | --- | --- | --- |
| strict CBOR | 5,462 B, 5,462 B | 114,947 B, 114,947 B | 43,147 and 43,559 ns; 41,918 and 41,063 ns |
| JSON | 315,587 B, 315,587 B | 17,799,272 B, 8,886,248 B | 369,190 and 362,979 ns; 420,359 and 415,063 ns |
| JSON, slashes escaped | 321,999 B, 315,587 B | 17,799,272 B, 8,886,248 B | 389,474 and 371,400 ns; 455,824 and 473,887 ns |

- Memory: the arena used is the same for plain JSON, where nothing was rewritten that was not already exact. It falls 2% when the base64 is escaped, because the token of each payload is no longer built before it is decoded. The bound falls by half (17.8 MB to 8.9 MB) because it no longer charges the base64 token or the growth of a string buffer. This is the memory the change saves; the used arena is not what the bound measures.
- Time: JSON costs 13 to 15% more (plain) and 17 to 28% more (escaped). The cause is a second scan: the measure pass, which also checks UTF-8, and the write pass, which does not. On this corpus the memory saved is the bound and the transient growth, which matters for a fixed arena of exactly the bound size. The time paid is the second scan of each base64 or escaped string. Strict CBOR is unchanged: it rewrites nothing, so it pays nothing.

## 2026-11-23 - 4e60dfc

`wire.decode` reads straight into `Wire(T)`, with no intermediate typed value or typed array. Before is `879332e`, after is `4e60dfc`.

| Read | Input / effects | Arena used (before, after) | Bound (before, after) | Time (before, after) |
| --- | --- | --- | --- | --- |
| strict CBOR | 723,857 B, 349 effects / 727,234 B, 353 effects | 29,323 B, 9,886 B | 344,343 B, 114,947 B | 91,024 and 105,824 ns, 86,536 and 87,328 ns |
| JSON | 858,873 B, 349 effects / 862,968 B, 353 effects | 780,995 B, 748,240 B | 18,338,751 B, 17,799,272 B | 846,156 and 911,056 ns, 849,690 and 919,839 ns |

- Memory: the arena of a strict CBOR decode falls to a third (29.3 KB to 9.9 KB, or 84 to 28 bytes an effect) because the typed array of unions and the typed puts are gone. In JSON the rewritten base64 payloads and escaped text dominate the arena (the `2026-11-23 - e343755` section), so the saving is the typed array only: 4%.
- Time: strict CBOR is 5 to 18% faster because it no longer walks its list twice. JSON is unchanged within the run-to-run spread (0.97 to 1.01 times). The sink adds no measured cost.
- The corpus grew by four effects between the two rows because the repository's files changed. The per-effect figures above hold.
