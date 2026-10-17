# fast-completions perf baseline — hardening arc v0.2.0 → 0.5.0

Captured 2026-10-17T04:02:50Z by `gems/completions/bench/compare_refs.rb` (frozen floors and workload sizes live in that script; the numbers below are a single-machine capture, not a test oracle — future runs re-run the driver and compare against the FLOORS, never against these cells).

- ruby: `ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM [arm64-darwin23]`
- machine: `Darwin 25.6.0 arm64` — single-machine wall-clock medians; shared developer laptop, no isolation
- refs: v0.2.0 = 43ea169, v0.3.0 = 6ceba1f, v0.4.0 = ef79e82, 0.4.1 = ce19841, 0.5.0 = 81a39b5 (0.4.1 is the local-only SHA, BRIEF §4; 0.5.0 is the working tree at HEAD — the pre-landing lane tip)

## Per-path × ref (median of the script's reps)

| path | v0.2.0 | v0.3.0 | v0.4.0 | 0.4.1 | 0.5.0 | floor |
|---|---|---|---|---|---|---|
| bench_text_stream | 11.3 | 11 | 10.3 | 10.1 | 11 | 100 us/delta |
| bench_tool_args | 940.9 | 890.5 | 887.8 | 878.6 | 5.722 | 2500 us/delta |
| bench_codec | 0.235 | 0.28 | 0.307 | 0.311 | 0.312 | 1.5 ms/round_trip |
| bench_strict | n/a | n/a | 19.6 | 19.6 | 19.8 | 100 us/rewrite |

## Consecutive-release deltas (newer vs older, same units)

| path | v0.2.0→v0.3.0 | v0.3.0→v0.4.0 | v0.4.0→0.4.1 | 0.4.1→0.5.0 |
|---|---|---|---|---|
| text_stream | -2.7% | -6.5% | -1.6% | +8.7% |
| tool_args | -5.4% | -0.3% | -1.0% | -99.3% |
| codec | +19.1% | +9.6% | +1.3% | +0.3% |
| strict | n/a | n/a | +0.5% | +0.7% |

## Floor verdicts (absolute per-op ceilings)

One table per consecutive-release pair, rows in the canonical path order (same as every other table in this file). Every cell is judged on the same uniform per-path floors. `headroom` = (floor − value) / floor; a value over the floor is a FINDING — also counted in the trailer and the driver's exit code.

### v0.2.0 → v0.3.0

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| text_stream | 10.993 | 100 | us/delta | +89% | OK |
| tool_args | 890.456 | 2500 | us/delta | +64% | OK |
| codec | 0.28 | 1.5 | ms/round_trip | +81% | OK |

### v0.3.0 → v0.4.0

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| text_stream | 10.277 | 100 | us/delta | +90% | OK |
| tool_args | 887.847 | 2500 | us/delta | +64% | OK |
| codec | 0.307 | 1.5 | ms/round_trip | +80% | OK |
| strict | 19.55 | 100 | us/rewrite | +80% | OK |

### v0.4.0 → 0.4.1

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| text_stream | 10.108 | 100 | us/delta | +90% | OK |
| tool_args | 878.619 | 2500 | us/delta | +65% | OK |
| codec | 0.311 | 1.5 | ms/round_trip | +79% | OK |
| strict | 19.648 | 100 | us/rewrite | +80% | OK |

### 0.4.1 → 0.5.0

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| text_stream | 10.985 | 100 | us/delta | +89% | OK |
| tool_args | 5.722 | 2500 | us/delta | +100% | OK |
| codec | 0.312 | 1.5 | ms/round_trip | +79% | OK |
| strict | 19.777 | 100 | us/rewrite | +80% | OK |

PAIRS_CHECKED=15 FINDINGS=0
