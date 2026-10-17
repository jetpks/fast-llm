# fast-completions perf baseline — hardening arc v0.2.0 → 0.5.0

Captured 2026-10-17T03:53:58Z by `gems/completions/bench/compare_refs.rb` (frozen floors and workload sizes live in that script; the numbers below are a single-machine capture, not a test oracle — future runs re-run the driver and compare against the FLOORS, never against these cells).

- ruby: `ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM [arm64-darwin23]`
- machine: `Darwin 25.6.0 arm64` — single-machine wall-clock medians; shared developer laptop, no isolation
- refs: v0.2.0 = 43ea169, v0.3.0 = 6ceba1f, v0.4.0 = ef79e82, 0.4.1 = ce19841, 0.5.0 = aa7812f (0.4.1 is the local-only SHA, BRIEF §4; 0.5.0 is the working tree at HEAD — the pre-landing lane tip)

## Per-path × ref (median of the script's reps)

| path | v0.2.0 | v0.3.0 | v0.4.0 | 0.4.1 | 0.5.0 | floor |
|---|---|---|---|---|---|---|
| bench_text_stream | 11.5 | 10.1 | 11.4 | 11.4 | 11.4 | 100 us/delta |
| bench_tool_args | 974.8 | 972.4 | 954.5 | 958.5 | 5.734 | 2500 us/delta |
| bench_codec | 0.236 | 0.311 | 0.316 | 0.314 | 0.308 | 1.5 ms/round_trip |
| bench_strict | n/a | n/a | 19.8 | 20 | 19.8 | 100 us/rewrite |

## Consecutive-release deltas (newer vs older, same units)

| path | v0.2.0→v0.3.0 | v0.3.0→v0.4.0 | v0.4.0→0.4.1 | 0.4.1→0.5.0 |
|---|---|---|---|---|
| text_stream | -12.1% | +12.6% | +0.2% | -0.1% |
| tool_args | -0.2% | -1.8% | +0.4% | -99.4% |
| codec | +31.8% | +1.6% | -0.6% | -1.9% |
| strict | n/a | n/a | +0.9% | -0.9% |

## Floor verdicts (absolute per-op ceilings)

One table per consecutive-release pair; within each, rows sort tightest first, so any FINDING and the riskiest margins sit at the top. All pairs share the per-path floors except 0.4.1→0.5.0 tool_args, which carries the machine's own stricter 60 µs/delta gate from I02 (flagged inline). `headroom` = (floor − value) / floor.

### v0.2.0 → v0.3.0

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| tool_args | 972.381 | 2500 | us/delta | +61% | OK |
| codec | 0.311 | 1.5 | ms/round_trip | +79% | OK |
| text_stream | 10.116 | 100 | us/delta | +90% | OK |

### v0.3.0 → v0.4.0

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| tool_args | 954.45 | 2500 | us/delta | +62% | OK |
| codec | 0.316 | 1.5 | ms/round_trip | +79% | OK |
| strict | 19.79 | 100 | us/rewrite | +80% | OK |
| text_stream | 11.386 | 100 | us/delta | +89% | OK |

### v0.4.0 → 0.4.1

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| tool_args | 958.487 | 2500 | us/delta | +62% | OK |
| codec | 0.314 | 1.5 | ms/round_trip | +79% | OK |
| strict | 19.97 | 100 | us/rewrite | +80% | OK |
| text_stream | 11.411 | 100 | us/delta | +89% | OK |

### 0.4.1 → 0.5.0

| path | value | floor | unit | headroom | status |
|---|---|---|---|---|---|
| codec | 0.308 | 1.5 | ms/round_trip | +79% | OK |
| strict | 19.79 | 100 | us/rewrite | +80% | OK |
| text_stream | 11.404 | 100 | us/delta | +89% | OK |
| tool_args (machine bar) | 5.734 | 60 | us/delta | +90% | OK |

PAIRS_CHECKED=15 FINDINGS=0
