# fast-completions perf baseline — hardening arc v0.2.0 → 0.5.0

Captured 2026-10-17T04:00:25Z by `gems/completions/bench/compare_refs.rb` (frozen floors and workload sizes live in that script; the numbers below are a single-machine capture, not a test oracle — future runs re-run the driver and compare against the FLOORS, never against these cells).

- ruby: `ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM [arm64-darwin23]`
- machine: `Darwin 25.6.0 arm64` — single-machine wall-clock medians; shared developer laptop, no isolation
- refs: v0.2.0 = 43ea169, v0.3.0 = 6ceba1f, v0.4.0 = ef79e82, 0.4.1 = ce19841, 0.5.0 = bd526f0 (0.4.1 is the local-only SHA, BRIEF §4; 0.5.0 is the working tree at HEAD — the pre-landing lane tip)

## Per-path × ref (median of the script's reps)

| path | v0.2.0 | v0.3.0 | v0.4.0 | 0.4.1 | 0.5.0 | floor |
|---|---|---|---|---|---|---|
| bench_text_stream | 11.1 | 11.3 | 11.3 | 11.4 | 11.2 | 100 us/delta |
| bench_tool_args | 947.8 | 967.7 | 950 | 935.5 | 5.706 | 2500 us/delta |
| bench_codec | 0.261 | 0.311 | 0.315 | 0.308 | 0.309 | 1.5 ms/round_trip |
| bench_strict | n/a | n/a | 19.9 | 19.6 | 19.6 | 100 us/rewrite |

## Consecutive-release deltas (newer vs older, same units)

| path | v0.2.0→v0.3.0 | v0.3.0→v0.4.0 | v0.4.0→0.4.1 | 0.4.1→0.5.0 |
|---|---|---|---|---|
| text_stream | +1.0% | +0.8% | +0.4% | -1.2% |
| tool_args | +2.1% | -1.8% | -1.5% | -99.4% |
| codec | +19.2% | +1.3% | -2.2% | +0.3% |
| strict | n/a | n/a | -1.3% | -0.4% |

## Floor verdicts (absolute per-op ceilings)

One table per consecutive-release pair, rows in the canonical path order (same as every other table in this file). All pairs share the per-path floors except 0.4.1→0.5.0 tool_args, which carries the machine's own stricter 60 µs/delta gate from I02 (flagged inline). `headroom` = (floor − value) / floor; a value over the floor is a FINDING — also counted in the trailer and the driver's exit code.

### v0.2.0 → v0.3.0

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| text_stream | 11.253 | 100 | us/delta | +89% | OK |
| tool_args | 967.656 | 2500 | us/delta | +61% | OK |
| codec | 0.311 | 1.5 | ms/round_trip | +79% | OK |

### v0.3.0 → v0.4.0

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| text_stream | 11.34 | 100 | us/delta | +89% | OK |
| tool_args | 949.994 | 2500 | us/delta | +62% | OK |
| codec | 0.315 | 1.5 | ms/round_trip | +79% | OK |
| strict | 19.913 | 100 | us/rewrite | +80% | OK |

### v0.4.0 → 0.4.1

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| text_stream | 11.389 | 100 | us/delta | +89% | OK |
| tool_args | 935.456 | 2500 | us/delta | +63% | OK |
| codec | 0.308 | 1.5 | ms/round_trip | +79% | OK |
| strict | 19.648 | 100 | us/rewrite | +80% | OK |

### 0.4.1 → 0.5.0

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| text_stream | 11.247 | 100 | us/delta | +89% | OK |
| tool_args (machine bar) | 5.706 | 60 | us/delta | +90% | OK |
| codec | 0.309 | 1.5 | ms/round_trip | +79% | OK |
| strict | 19.575 | 100 | us/rewrite | +80% | OK |

PAIRS_CHECKED=15 FINDINGS=0
