# Reference: Errors

| Error | Raised for |
|---|---|
| `Fast::Completions::Error` | base of the API error tree |
| `ApiError(status:, body:)` | any non-2xx (`"<status>: <message>"`) |
| `BadRequestError` | 400 |
| `ContextLengthExceededError` | 400 matching a context-overflow pattern |
| `AuthenticationError` / `PermissionError` / `NotFoundError` / `RateLimitError` | 401 / 403 / 404 / 429 |
| `ServerError` | 5xx |
| `TimeoutError` | TTFB deadline or read inactivity (one timeout value) |
| `ConnectionError` | ECONNREFUSED, ECONNRESET, … |
| `StreamError` | terminal stream errors (emits `:error` first) |
| `CancelledError` | task cancellation (NOT under `Error`) |

## Status mapping

A non-2xx reply raises before the first `:start` event — an error reply never
yields stream events. The class is chosen from the status:

- 400 → `BadRequestError`, upgraded to `ContextLengthExceededError` (a
  subclass) when any string in the parsed body — or the raw body — matches a
  context-overflow pattern. The pattern set is pi's, ported verbatim as data:
  OpenAI, Anthropic, z.ai, Bedrock, Google, xAI, Groq, OpenRouter, Together,
  MiniMax, Mistral, llama.cpp, LM Studio, Ollama, DashScope, and generic
  fallbacks.
- 401 / 403 / 404 / 429 → `AuthenticationError` / `PermissionError` /
  `NotFoundError` / `RateLimitError`.
- 500–599 → `ServerError`.
- every other non-2xx → `ApiError`.

`ApiError#message` is `"<status>: <provider message>"` — the body's
`error.message` (or top-level `message`) when the JSON parses, else the raw
body truncated to 500 characters. `#status` and `#body` carry the response.

## TimeoutError

One `timeout:` value (default 30 s on `Client.new`) serves both deadlines:
the time-to-first-byte deadline before the reply starts, and read inactivity
once it streams (the watchdog re-arms after every body chunk). A fired
watchdog cancels the waiting task and surfaces `TimeoutError` — never
`CancelledError`, so a timeout is distinguishable from a user cancel.

## ConnectionError

The network-error family wraps as `ConnectionError` with the original class
and message preserved: `ECONNREFUSED`, `ECONNRESET`, `EPIPE`, `EHOSTUNREACH`,
`ENETUNREACH`, `ETIMEDOUT`, `EOFError`, `IOError`, `SocketError`.

## StreamError

The terminal stream discipline: a provider error `finish_reason`, or a stream
that ends without the `finish_reason` the dialect expects, emits the
client-level `:error` event FIRST and then raises `StreamError`
(`#stop_reason` is `:error`).

A malformed stream chunk no longer raises. The tolerant inbound-stream class
(I61): a payload the wire mangled is repaired at the chunk seam — raw control
characters inside strings escaped, pi `parseJsonWithRepair` semantics — and
flows downstream as if the wire had been well-formed; the SSE parser first
rejoins a payload cut across lines by a raw newline. A chunk still
unparseable after rejoin and repair is dropped — counted on
`Client#dropped_chunks`, never raised — and the stream continues to its
natural terminal. Two consequences are already-tolerant: a dropped chunk that
would have carried the `finish_reason` leaves the stream without one, which
still lands in this missing-finish error path; and a lost arguments fragment
leaves partial arguments, which the tolerant tool-args finalize and the
consumer's input validation handle as a clean tool error (the model re-calls
the tool). See
[Reference: Stream events](stream-events.md) for the event.

## CancelledError is not under Error

`Error` — and the whole `ApiError` tree under it — is the rescue target for
API failures. `CancelledError` deliberately does NOT inherit it: a rescue
ladder that catches `Fast::Completions::Error` never swallows a cancellation.
`CancelledError` inherits `StandardError` directly, and `Async::Cancel` itself
inherits `Exception`, passing beneath every `StandardError` rescue. The
consumer-facing discipline is in
[How to cancel a running chat](../how-to/cancel-a-running-chat.md).
