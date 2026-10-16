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
| `ConstrainedSamplingError` | a strict-`"require"` tool whose schema cannot be strict-rewritten, or a require tool on a dialect without `supports_strict_mode` |
| `CancelledError` | task cancellation (NOT under `Error`) |

## Status mapping

A non-2xx reply is first a retry decision (see [Request retry](#request-retry)
below): a retryable trigger with attempts remaining POSTs again. When the
failure is final — the trigger is non-retryable or the retries are exhausted
— the mapped class is raised only AFTER the client-level `:error` event. That
event carries the accumulator, still empty at creation — `:start` is never
emitted for a failed creation. The class is chosen from the status:

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

## Mid-stream salvage

Once a reply resolves 2xx the attempt is committed to streaming — no failure
after that point is ever retried. ANY exception while the body streams — the
network family mid-body (socket reset, EOF mid-chunk, …) or any other
exception except cancellation — yields the client-level `:error` event FIRST
carrying the SALVAGED partial: the live Message with every streamed block and
the usage received so far, a thinking block's streamed `reasoning_details`
serialized into its signature exactly as a completed finalize would (so a
salvaged partial replays like a completed one), and NO block-end events after
the failure. Then the raise: the network family maps to `ConnectionError`
(message form preserved), anything else re-raises unchanged. Cancellation
keeps its no-terminal-event discipline and is never salvaged, retried, or
mapped.

## Request retry

The POST attempt — creation through status receipt, structurally before the
first body byte — retries at most `max_retries` times: a constructor kwarg
(integer ≥ 0, default 1; `0` restores the single attempt). Retries are
immediate — no backoff — and each attempt is a fresh POST on the same client.
The trigger set, pi provider-retry semantics, exact:

- response header `x-should-retry: true` → retry, regardless of status;
- `x-should-retry: false` → FINAL, regardless of status (honored even on
  429/5xx);
- statusless errors — a network failure during the POST, or the TTFB watchdog
  firing before the response — → retry;
- status 408 / 409 / 429 / 5xx → retry;
- every other status (400, 401, 403, 404, …) → final.

Never after a 2xx: a mid-body failure is a mid-stream salvage (above), making
exactly one request. Cancellation is not a failure and is never retried. The
final failure of an exhausted class raises its mapped error —
`ConnectionError`, `TimeoutError`, or the §8 status mapping — after the
`:error` terminal event.

## TimeoutError

One `timeout:` value (default 30 s on `Client.new`) serves both deadlines:
the time-to-first-byte deadline before the reply starts, and read inactivity
once it streams (the watchdog re-arms after every body chunk). A fired
watchdog cancels the waiting task and surfaces `TimeoutError` — never
`CancelledError`, so a timeout is distinguishable from a user cancel. A TTFB
fire is a retry trigger (see [Request retry](#request-retry)): the retried
attempt re-arms the deadline, and only the final fire raises.

## ConnectionError

The network-error family wraps as `ConnectionError` with the original class
and message preserved: `ECONNREFUSED`, `ECONNRESET`, `EPIPE`, `EHOSTUNREACH`,
`ENETUNREACH`, `ETIMEDOUT`, `EOFError`, `IOError`, `SocketError`. At creation
it raises after the retries are exhausted; mid-body it raises after the
`:error` salvage — the partial the stream had built by then travels on that
event, never lost.

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
