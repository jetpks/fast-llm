# Changelog

Notable changes to the fast-completions gem. The format is prose-first,
one section per released version, newest first.

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
