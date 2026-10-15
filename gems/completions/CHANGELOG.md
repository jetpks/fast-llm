# Changelog

Notable changes to the fast-completions gem. The format is prose-first,
one section per released version, newest first.

## Unreleased

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
