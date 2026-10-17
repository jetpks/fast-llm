# fast-completions perf baseline — hardening arc v0.2.0 → 0.5.0

Captured 2026-10-17T03:36:21Z by `gems/completions/bench/compare_refs.rb` (frozen floors and workload sizes live in that script; the numbers below are a single-machine capture, not a test oracle — future runs re-run the driver and compare against the FLOORS, never against these cells).

- ruby: `ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM [arm64-darwin23]`
- machine: `Darwin 25.6.0 arm64` — single-machine wall-clock medians; shared developer laptop, no isolation
- refs: v0.2.0 = 43ea169, v0.3.0 = 6ceba1f, v0.4.0 = ef79e82, 0.4.1 = ce19841, 0.5.0 = a74a00f (0.4.1 is the local-only SHA, BRIEF §4; 0.5.0 is the working tree at HEAD — the pre-landing lane tip)

## Per-path × ref (median of the script's reps)

| path | v0.2.0 | v0.3.0 | v0.4.0 | 0.4.1 | 0.5.0 | floor |
|---|---|---|---|---|---|---|
| bench_text_stream | 11.7 | 11.6 | 11.3 | 11.3 | 11.2 | 100 us/delta |
| bench_tool_args | 959.4 | 943.7 | 950 | 949.5 | 5.738 | 2500 us/delta |
| bench_codec | 0.265 | 0.305 | 0.308 | 0.309 | 0.314 | 1.5 ms/round_trip |
| bench_strict | n/a | n/a | 19.6 | 19.7 | 19.7 | 100 us/rewrite |

## Consecutive-release deltas (newer vs older, same units)

- text_stream v0.2.0→v0.3.0: -0.4%
- tool_args v0.2.0→v0.3.0: -1.6%
- codec v0.2.0→v0.3.0: +15.1%
- strict v0.2.0→v0.3.0: n/a
- text_stream v0.3.0→v0.4.0: -2.7%
- tool_args v0.3.0→v0.4.0: +0.7%
- codec v0.3.0→v0.4.0: +1.0%
- strict v0.3.0→v0.4.0: n/a
- text_stream v0.4.0→0.4.1: +0.4%
- tool_args v0.4.0→0.4.1: -0.1%
- codec v0.4.0→0.4.1: +0.3%
- strict v0.4.0→0.4.1: +0.3%
- text_stream 0.4.1→0.5.0: -0.9%
- tool_args 0.4.1→0.5.0: -99.4%
- codec 0.4.1→0.5.0: +1.6%
- strict 0.4.1→0.5.0: +0.0%

## Floor verdicts (absolute per-op ceilings)

FLOOR path=text_stream unit=us/delta max=100
FLOOR path=tool_args unit=us/delta max=2500
FLOOR path=codec unit=ms/round_trip max=1.5
FLOOR path=strict unit=us/rewrite max=100
FLOOR path=tool_args pair=0.4.1->0.5.0 unit=us/delta max=60
VERDICT path=text_stream pair=v0.2.0->v0.3.0 newer=11.611 floor=100 unit=us/delta status=OK
VERDICT path=text_stream pair=v0.3.0->v0.4.0 newer=11.296 floor=100 unit=us/delta status=OK
VERDICT path=text_stream pair=v0.4.0->0.4.1 newer=11.346 floor=100 unit=us/delta status=OK
VERDICT path=text_stream pair=0.4.1->0.5.0 newer=11.243 floor=100 unit=us/delta status=OK
VERDICT path=tool_args pair=v0.2.0->v0.3.0 newer=943.678 floor=2500 unit=us/delta status=OK
VERDICT path=tool_args pair=v0.3.0->v0.4.0 newer=950.022 floor=2500 unit=us/delta status=OK
VERDICT path=tool_args pair=v0.4.0->0.4.1 newer=949.484 floor=2500 unit=us/delta status=OK
VERDICT path=tool_args pair=0.4.1->0.5.0 newer=5.738 floor=60 unit=us/delta status=OK
VERDICT path=codec pair=v0.2.0->v0.3.0 newer=0.305 floor=1.5 unit=ms/round_trip status=OK
VERDICT path=codec pair=v0.3.0->v0.4.0 newer=0.308 floor=1.5 unit=ms/round_trip status=OK
VERDICT path=codec pair=v0.4.0->0.4.1 newer=0.309 floor=1.5 unit=ms/round_trip status=OK
VERDICT path=codec pair=0.4.1->0.5.0 newer=0.314 floor=1.5 unit=ms/round_trip status=OK
VERDICT path=strict pair=v0.3.0->v0.4.0 newer=19.648 floor=100 unit=us/rewrite status=OK
VERDICT path=strict pair=v0.4.0->0.4.1 newer=19.708 floor=100 unit=us/rewrite status=OK
VERDICT path=strict pair=0.4.1->0.5.0 newer=19.712 floor=100 unit=us/rewrite status=OK
PAIRS_CHECKED=15 FINDINGS=0
