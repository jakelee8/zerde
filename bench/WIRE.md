# Wire decode benchmark history

`zig build bench-wire -Doptimize=ReleaseFast` decodes a commit of effects (a put for every 24 lines of
`tests/typed_tests.zig`, `src/cbor.zig` and `README.md`, a delete after each seventh) with `zerde.wire.decode`,
in strict CBOR and in JSON (bytes as base64, the text with its escapes). The corpus is this repository's own
text, so its size follows the files: compare rows by bytes and effects, not by the totals alone. "Arena used"
is `end_index` when the decode is done, "peak" the furthest byte it wrote, "bound" is `wire.maxArenaSize`.
Time is ns for one decode, 200 decodes, two runs back to back under `flock`, load about 2.

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
