# fast-completions perf baseline — hardening arc v0.2.0 → 0.5.0

Captured 2026-10-17T03:52:23Z by `gems/completions/bench/compare_refs.rb` (frozen floors and workload sizes live in that script; the numbers below are a single-machine capture, not a test oracle — future runs re-run the driver and compare against the FLOORS, never against these cells).

- ruby: `ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM [arm64-darwin23]`
- machine: `Darwin 25.6.0 arm64` — single-machine wall-clock medians; shared developer laptop, no isolation
- refs: v0.2.0 = 43ea169, v0.3.0 = 6ceba1f, v0.4.0 = ef79e82, 0.4.1 = ce19841, 0.5.0 = 0a60039 (0.4.1 is the local-only SHA, BRIEF §4; 0.5.0 is the working tree at HEAD — the pre-landing lane tip)

## Per-path × ref (median of the script's reps)

| path | v0.2.0 | v0.3.0 | v0.4.0 | 0.4.1 | 0.5.0 | floor |
|---|---|---|---|---|---|---|
| bench_text_stream | 11.3 | 11.4 | 11.3 | 11.5 | 10.9 | 100 us/delta |
| bench_tool_args | 932.9 | 977.7 | 948.8 | 938.2 | 5.762 | 2500 us/delta |
| bench_codec | 0.26 | 0.307 | 0.31 | 0.311 | 0.314 | 1.5 ms/round_trip |
| bench_strict | n/a | n/a | 20 | 19.5 | 18.7 | 100 us/rewrite |

## Consecutive-release deltas (newer vs older, same units)

| path | v0.2.0→v0.3.0 | v0.3.0→v0.4.0 | v0.4.0→0.4.1 | 0.4.1→0.5.0 |
|---|---|---|---|---|
| text_stream | +1.1% | -1.5% | +2.1% | -5.3% |
| tool_args | +4.8% | -3.0% | -1.1% | -99.4% |
| codec | +18.1% | +1.0% | +0.3% | +1.0% |
| strict | n/a | n/a | -2.6% | -4.3% |

## Floor verdicts (absolute per-op ceilings)

Every pair's newer cell must sit at or under its floor. One pair carries a stricter, pair-scoped bar: 0.4.1→0.5.0 tool_args (the machine's own 60 µs/delta gate from I02). `headroom` = (floor − value) / floor; rows sort tightest first, so any FINDING and the riskiest margins sit at the top.

| path | pair | value | floor | unit | headroom | status |
|---|---|---|---|---|---|---|
| tool_args | v0.2.0→v0.3.0 | 977.681 | 2500 | us/delta | +61% | OK |
| tool_args | v0.3.0→v0.4.0 | 948.803 | 2500 | us/delta | +62% | OK |
| tool_args | v0.4.0→0.4.1 | 938.203 | 2500 | us/delta | +62% | OK |
| codec | 0.4.1→0.5.0 | 0.314 | 1.5 | ms/round_trip | +79% | OK |
| codec | v0.4.0→0.4.1 | 0.311 | 1.5 | ms/round_trip | +79% | OK |
| codec | v0.3.0→v0.4.0 | 0.31 | 1.5 | ms/round_trip | +79% | OK |
| codec | v0.2.0→v0.3.0 | 0.307 | 1.5 | ms/round_trip | +80% | OK |
| strict | v0.3.0→v0.4.0 | 20.027 | 100 | us/rewrite | +80% | OK |
| strict | v0.4.0→0.4.1 | 19.497 | 100 | us/rewrite | +81% | OK |
| strict | 0.4.1→0.5.0 | 18.655 | 100 | us/rewrite | +81% | OK |
| text_stream | v0.4.0→0.4.1 | 11.498 | 100 | us/delta | +89% | OK |
| text_stream | v0.2.0→v0.3.0 | 11.436 | 100 | us/delta | +89% | OK |
| text_stream | v0.3.0→v0.4.0 | 11.264 | 100 | us/delta | +89% | OK |
| text_stream | 0.4.1→0.5.0 | 10.883 | 100 | us/delta | +89% | OK |
| tool_args | 0.4.1→0.5.0 (machine bar) | 5.762 | 60 | us/delta | +90% | OK |

PAIRS_CHECKED=15 FINDINGS=0
