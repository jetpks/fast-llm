# fast-completions perf baseline — hardening arc v0.2.0 → 0.4.1

Captured 2026-10-17T01:52:17Z by `gems/completions/bench/compare_refs.rb` (frozen floors and workload sizes live in that script; the numbers below are a single-machine capture, not a test oracle — future runs re-run the driver and compare against the FLOORS, never against these cells).

- ruby: `ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM [arm64-darwin23]`
- machine: `Darwin 25.6.0 arm64` — single-machine wall-clock medians; shared developer laptop, no isolation
- refs: v0.2.0 = 43ea169, v0.3.0 = 6ceba1f, v0.4.0 = ef79e82, 0.4.1 = ce19841 (0.4.1 is the local-only SHA, BRIEF §4)

## Per-path × ref (median of the script's reps)

| path | v0.2.0 | v0.3.0 | v0.4.0 | 0.4.1 | floor |
|---|---|---|---|---|---|
| bench_text_stream | 10 | 9.983 | 10.1 | 10.1 | 100 us/delta |
| bench_tool_args | 869.3 | 881.5 | 918.5 | 877.4 | 2500 us/delta |
| bench_codec | 0.237 | 0.277 | 0.285 | 0.275 | 1.5 ms/round_trip |
| bench_strict | n/a | n/a | 18 | 17.8 | 100 us/rewrite |

## Consecutive-release deltas (newer vs older, same units)

- text_stream v0.2.0→v0.3.0: -0.5%
- tool_args v0.2.0→v0.3.0: +1.4%
- codec v0.2.0→v0.3.0: +16.9%
- strict v0.2.0→v0.3.0: n/a
- text_stream v0.3.0→v0.4.0: +0.7%
- tool_args v0.3.0→v0.4.0: +4.2%
- codec v0.3.0→v0.4.0: +2.9%
- strict v0.3.0→v0.4.0: n/a
- text_stream v0.4.0→0.4.1: +0.6%
- tool_args v0.4.0→0.4.1: -4.5%
- codec v0.4.0→0.4.1: -3.5%
- strict v0.4.0→0.4.1: -1.4%

## Floor verdicts (absolute per-op ceilings)

FLOOR path=text_stream unit=us/delta max=100
FLOOR path=tool_args unit=us/delta max=2500
FLOOR path=codec unit=ms/round_trip max=1.5
FLOOR path=strict unit=us/rewrite max=100
VERDICT path=text_stream pair=v0.2.0->v0.3.0 newer=9.983 floor=100 unit=us/delta status=OK
VERDICT path=text_stream pair=v0.3.0->v0.4.0 newer=10.05 floor=100 unit=us/delta status=OK
VERDICT path=text_stream pair=v0.4.0->0.4.1 newer=10.114 floor=100 unit=us/delta status=OK
VERDICT path=tool_args pair=v0.2.0->v0.3.0 newer=881.497 floor=2500 unit=us/delta status=OK
VERDICT path=tool_args pair=v0.3.0->v0.4.0 newer=918.456 floor=2500 unit=us/delta status=OK
VERDICT path=tool_args pair=v0.4.0->0.4.1 newer=877.366 floor=2500 unit=us/delta status=OK
VERDICT path=codec pair=v0.2.0->v0.3.0 newer=0.277 floor=1.5 unit=ms/round_trip status=OK
VERDICT path=codec pair=v0.3.0->v0.4.0 newer=0.285 floor=1.5 unit=ms/round_trip status=OK
VERDICT path=codec pair=v0.4.0->0.4.1 newer=0.275 floor=1.5 unit=ms/round_trip status=OK
VERDICT path=strict pair=v0.3.0->v0.4.0 newer=18.037 floor=100 unit=us/rewrite status=OK
VERDICT path=strict pair=v0.4.0->0.4.1 newer=17.787 floor=100 unit=us/rewrite status=OK
PAIRS_CHECKED=11 FINDINGS=0
