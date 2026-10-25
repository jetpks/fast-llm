# Changelog

Notable changes to the fast-completions gem. The format is prose-first,
one section per released version, newest first.

## 0.7.0 (unreleased)

- Telemetry sink interface: `Client.new` accepts `telemetry:` — any
  Enumerable of sink objects (an Array, a Set, …), validated loudly at
  construction (a non-Enumerable, or a
  sink not responding to all five hooks, raises `ArgumentError` naming
  the offender and the missing hook; duck-typed sinks are accepted
  without module inclusion; the client keeps its own frozen Array —
  `entries` — so the caller's container is never frozen or mutated) — and dispatches five
  observation hooks around a completion, ONE `Client#stream` invocation
  (creation retries inside, tool execution outside):
  `on_completion_start(model.id, body bytesize)` before the first POST,
  `on_completion_ttfb` at the first parser item of the successful
  attempt (a retried attempt's clock restarts), `on_event` for every
  Event — before its consumer twin, terminals and the salvage `:error`
  included, and even with no consumer block — `on_completion_end(stop
  reason, duration, live message)` when `stream` returns, and
  `on_completion_error(error Symbol derived from the raising class,
  duration)` on every raise-out, cancellation included. Multiple sinks
  dispatch in registration order. The allocation discipline is pinned
  by spec measurement gates: zero added heap objects on the hot paths
  with no sink registered, zero ADDED objects with a no-op sink (only
  refs and immediates cross the boundary, durations are flonum
  differences, every call site short-circuits on a precomputed
  emptiness check), and zero added `Process.clock_gettime` reads. The
  new reference page `docs/reference/telemetry.md` documents the
  protocol, the ordering rule (telemetry is the ground-truth record
  when consumer code is the suspect), the read-only convention for
  sinks, and that metric naming belongs to the adapter.

## 0.6.0 (2026-10-25)

- `Client#raw_stream` — the raw completions surface a proxy needs: the
  caller's body forwarded verbatim (a String as-is, anything else
  JSON-generated), every parsed SSE payload yielded to the block in
  arrival order with the wire's terminal DONE token in its wire
  position, and `nil` returned — the block is the only output channel.
  No message accumulation, no tool interpretation, no stop-reason
  mapping, no salvage, no StreamError, and exactly ONE POST attempt —
  no auto-retry of any kind; a non-2xx raises the §8 mapping
  immediately. A malformed payload still rides the I61 chunk seam:
  one repair pass, then drop-and-count on `dropped_chunks` while the
  stream continues.
- The watchdog is now two-deadline: `ttfb_timeout` (status + headers)
  and `inactivity_timeout` (re-armed after every body chunk), each an
  optional constructor kwarg and per-call override on `raw_stream`,
  validated as a positive Numeric, falling back to the shared
  `timeout` when unset; prefill-scale values (1400 s) are first-class.
  A fire surfaces the phase-named `TimeoutError` ("no response headers
  within Ns" / "no data within Ns") — never `CancelledError` — and a
  user cancel still surfaces `CancelledError`. `Client#stream` keeps
  its single shared timeout and its byte-identical behavior; the
  additive default on `Watchdog#arm` is the only existing-signature
  change.
- Authentication is optional: `api_key` defaults to nil and the
  `authorization` header is sent only when the key is present and
  non-empty — a local engine needs no key. With a key present the
  header set is unchanged.
- Docs: a README "Raw streaming" section plus the full reference page
  (`docs/reference/raw-stream.md`); the README owner-prose gate now
  rules two zones. Platform unchanged: ruby floor `>= 3.3`, CI matrix
  3.3/3.4/4.0, no new dependencies.
- Internal refactor of `Client#raw_stream` (operator review of #7): the
  method is short orchestration over three private seams — the request
  seam (payload resolution + the ONE POST under the TTFB arm), the
  each-event seam (the SSE parser, the per-chunk inactivity re-arm, the
  DONE yield, the drop-and-count reset), and the cancel→timeout
  translation — with the timeout phase derived from the response
  instead of a threading flag. Behavior-identical: signature, yielded
  events, error classes and messages, no-retry, and the
  connection-finish discipline are unchanged, and the raw_stream spec
  passes byte-unmodified.

## 0.5.0 (2026-10-17)

- Tool-args streaming is now an incremental string-state machine
  (`Fast::Completions::ArgsStreamer`, a new stdlib-only class): instead
  of eagerly re-parsing the whole arguments scratch on every delta
  (`JSON.parse` → `repair_json` → re-parse, O(n²) across a stream), each
  tool-call block owns a streamer whose parser state carries ACROSS
  deltas and only the NEW fragment's bytes are walked per delta — O(n)
  total, no per-delta copy of any accumulated buffer, and no exception
  on the streaming path (the machine is total on any fragment sequence;
  malformed input freezes the live view rather than crashing the step).
  This is a deliberate departure from pi, which re-parses per delta
  (openai-completions.ts :652-658).
- The live view of a tool-call block's `arguments` Hash is now a
  first-class feature (operator ruling, plan ENTRY 1 — “watching a
  file write is extremely nice”): the same Hash object is populated in
  place for the whole stream, nested containers materialize at their
  opening token, and an in-flight string value GROWS live — a consumer
  holding the reference sees it grow — instead of the whole pair
  vanishing until the closing quote. Escape sequences split by a delta boundary are held (the
  0.4.0/0.4.1 crash class becomes a structural non-event); invalid
  escape chars and invalidated `\u` runs contribute their literal text
  (`repair_json` parity, absorbed rather than called); surrogate halves
  never enter the live value, pairs combine; scalars materialize as raw
  text and are replaced by Integer/Float/true/false/null when the token
  terminates (malformed scalars keep their raw text). After the root
  object closes — or the stream becomes unparseable — the live view
  freezes. End states are unchanged and byte-identical to 0.4.1:
  finalize remains the sole authority, parsing the full scratch once
  (`parse_streaming_json`: the JSON.parse fast path when the stream
  completed, the repair walk and `{}` as the last resort otherwise).
  Mid-stream, the two protocol_spec pins that encoded the old
  truncation artifact as `eq({})` are amended to the growing view —
  the ONLY spec changes besides the machine's new unit spec.
- Bench harness: `compare_refs.rb` now measures a fifth ref — 0.5.0,
  the working tree at HEAD (the lane tip before the integrator's
  landing commit) — beside the four releases, pairs 0.4.1→0.5.0, and
  gains the machine's own pair-scoped floor: tool_args at 60 µs/delta
  (0.4.1 measured 877.4 µs/delta on the frozen 24 KB / 320-fragment
  workload; the machine lands in single-digit µs). BASELINE.md is
  regenerated with the 0.5.0 column. The four bench scripts stay
  byte-frozen — the workload the floors are calibrated to.

## 0.4.1 (2026-10-16)

- Fix a mid-stream crash in the tool-call live-parse (regression against
  pi, found live on zai/glm-5.3): when a delta boundary split an escape
  sequence, the arguments scratch buffer ended mid-string with a lone
  trailing backslash; `repair_json` doubled it (repaired != partial) and
  the re-parse of the still-unterminated string raised `JSON::ParserError`
  — uncaught, because Ruby rescue clauses do not cascade (an exception
  raised in one rescue body is not handled by the next rescue clause of
  the same method). The repaired re-parse now gets its own rescue (the
  same lesson `Client#parse_repaired` already had), returning `{}` as the
  last resort — pi's `parseStreamingJson` wraps the repair path in a
  try/catch and always returns a valid object; the port dropped that
  outer catch.
- Bench harness (perf-baseline): `gems/completions/bench/` ships four
  deterministic, network-free, stdlib-only benchmark scripts over the hot
  paths (text-heavy SSE+protocol stream; tool-args-heavy stream through the
  O(n²) per-delta live re-parse; Codec normalize → to_wire round-trip;
  strict-schema rewrite) and compare_refs.rb, which measures v0.2.0 →
  v0.3.0 → v0.4.0 → 0.4.1 through temporary read-only worktrees and writes
  bench/BASELINE.md — per-path × ref medians, consecutive-release deltas,
  and per-pair verdicts against frozen per-op floors. No behavior changes;
  the capture is single-machine, and future runs compare against the
  floors, never the cells.

## 0.4.0 (2026-10-14)

- Strict-sampling tool schemas (pi constrained-sampling, JSON-schema half):
  tools declare `constrained_sampling` — `false` (explicit opt-out) or
  `{"type" => "json_schema", "strict" => "prefer"|"require"}`; any other
  shape raises `ArgumentError` at declaration (grammar-constrained sampling
  stays out of scope — `type: "grammar"` raises). On a dialect declaring
  `supports_strict_mode`, a declared tool ships the strict rewrite of its
  parameters — every property required, non-required null-less properties
  wrapped in an `anyOf` of the property and `{"type": "null"}`,
  `additionalProperties: false` appended — with `"strict": true` right after
  `parameters`; every other function tool on a strict dialect ships
  `"strict": false` with parameters verbatim (the declared Hash is never
  mutated — the rewrite deep-copies); tools on non-strict dialects carry no
  strict key ever, parameters verbatim. `"prefer"` falls back to verbatim
  silently when the schema is unsupportable; `"require"` raises the new
  `ConstrainedSamplingError` with pi's message templates. The Dialect
  vocabulary grows to 14 keys (`supports_strict_mode`, default `false` —
  OpenAI compatibility alone does not imply strict tool support); the
  shipped `:zai` declares `true` (pi's glm compat).

## 0.3.0 (2026-10-15)

- Mid-stream salvage: a failure after a 2xx status — a mid-body connection
  abort, the network-error family, or any other exception except
  cancellation — no longer discards the streamed work. The client yields the
  `:error` terminal event FIRST, carrying the live partial (every streamed
  block and the usage so far; a thinking block's streamed
  `reasoning_details` are serialized into its signature exactly as finalize
  would) with no block-end events after the failure, then raises
  (`ConnectionError` for the network family, message form preserved;
  anything else re-raised unchanged). Creation-phase failures (non-2xx
  after the retry decision, network failures with retries exhausted) yield
  the same `:error` event — the accumulator still empty, `:start` still not
  emitted — before their mapped raise.
- Request-creation retry: the POST — creation through status receipt,
  structurally pre-first-body-byte — now retries bounded at ONE retry by
  default (constructor `max_retries:`, integer ≥ 0; `0` restores the single
  attempt), exactly on pi's provider-retry trigger classes: header
  `x-should-retry: true` (any status) retries; `x-should-retry: false` is
  final even on 429/5xx; statusless errors (network failures during the
  POST, a TTFB watchdog fire) retry; 408/409/429/5xx retry; every other
  status is final. Never after a 2xx — a mid-body failure salvages instead,
  making exactly one request. Cancellation is never retried; retries are
  immediate (backoff out of scope); a retried TTFB deadline re-arms per
  attempt and the final failure still surfaces `TimeoutError`, never
  `CancelledError`.
- Outgoing-string scrub (I62): every string the codec emits onto the wire
  params passes through a `String#scrub { "" }` deletion scrub (pi
  `sanitizeSurrogates`) at each emission point — the leading instructions
  and system content, user strings and text parts, the assistant's joined
  text and reasoning-field text, tool-result content, and the string
  values inside tool-call `arguments` (deep). Malformed bytes (lone
  surrogates, CESU-8 pairs, any invalid UTF-8 — Ruby's class is broader
  than JS's) are DELETED, never replaced with U+FFFD, so
  `JSON.generate` over a built request no longer raises
  `GeneratorError` from message content. Valid strings pass
  byte-identical — the canonical wire fixtures are untouched.
- `Message#stop_reason` (I62): nil-default replay metadata with no
  vocabulary validation; `to_h` emits the key only when set, `from_h`
  round-trips it, and the assistant factory accepts it.
  `Codec.normalize` skips assistants whose `stop_reason` is `:error` or
  `:aborted` entirely on replay (pi transform-messages): their tool calls
  never become pending orphans and never synthesize results, while a
  previous valid assistant's unanswered calls still do and surrounding
  user/system messages are unaffected. Histories without errored rows
  are byte-unaffected.
- Tool-call index-map backfill (I62): a tool-call fragment that resolves
  its block by id (or creation) while carrying an `index` now binds the
  block into the accumulator's index map (pi openai-completions :536-539)
  — first index wins, one index per block, ever — so the
  `{id, name}` → `{id, index, args}` → `{index, args}` fragment shape
  assembles ONE tool call instead of a spurious second block. Boundness
  is tracked accumulator-side; no scratch keys leak onto message blocks.

## 0.2.0 (2026-10-15)

- Tolerant inbound stream (I61): a malformed SSE chunk no longer kills
  the turn. The parser rejoins a data payload cut across lines by a raw
  newline (the z.ai coalesced-delta malformation observed 2026-10-15),
  the chunk seam repairs raw control characters inside strings (pi
  `parseJsonWithRepair` semantics) and re-parses, and a chunk still
  unparseable after rejoin and repair is dropped and counted
  (`Client#dropped_chunks`) while the stream continues to its natural
  terminal. `StreamError` no longer originates from chunk parsing; the
  missing-finish terminal discipline (§10.5) is unchanged. Healthy
  wires are byte-unaffected — the malformed shapes do not occur on
  them.

## 0.1.0

- Initial release. `Fast::Completions` is a standalone, fiber-native
  client for the OpenAI-compatible chat-completions wire.
- The request/stream codec is byte-faithful to pi's wire behavior
  (pi `packages/ai/src/api/openai-completions.ts` is the cited oracle
  throughout the source). Codec arms: the plain OpenAI arm (default),
  the zai arm, and the deepseek arm.
- Dialects are data: a closed 13-key declaration vocabulary via
  `Fast::Completions.dialect(:name) { ... }`, with the well-known
  `:zai`, `:deepseek`, and `:fireworks` declarations shipped. No model
  catalog, no pricing, no provider registry, no base-URL constants.
- `Client` holds one persistent `Async::HTTP::Client` and runs inside
  the caller's reactor: TTFB deadline + inactivity read-timeout, task
  cancellation that aborts the request and discards the connection, and
  the frozen error taxonomy (ApiError tree, TimeoutError,
  ConnectionError, CancelledError).
- `Chat` runs the agent turn: build → stream → yield events → execute
  the tool batch CONCURRENTLY (one reactor task per call, children of
  the step task) with results appended in call order, per-call failure
  isolation (a raised error becomes that call's error result while
  siblings complete), and the batch cancel discipline (a cancel aborts
  the in-flight calls and surfaces `CancelledError` with no partial
  results) — cancellation checkpoints and before/after hooks keyed by
  tool-call id.
- Replay normalization ports pi's cross-model thinking rules: same-model
  signature replay (`reasoning` / `reasoning_content` / `reasoning_text`),
  `reasoning_details` array replay, cross-model folding to text,
  synthetic results for orphaned tool calls, deepseek's
  `reasoning_content: ""`.
- Parity harness: the byte fixtures (lane `harness`) pin the wire
  against pi's recorded request bodies.
