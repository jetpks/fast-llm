# Reference: Raw streaming

`Client#raw_stream` is the low-level completions surface a proxy or
gateway needs: the caller's request body forwarded verbatim, the parsed
SSE payloads yielded as they arrive, and nothing else. `Client#stream`
(and `Chat` on top of it) remains the convenience surface — message
accumulation, tool interpretation, stop-reason mapping, and the bounded
creation retry all live there and are untouched.

## Signature

```ruby
client = Fast::Completions::Client.new(
  base_url: "http://127.0.0.1:8080/v1", # no api_key: a local engine needs none
  ttfb_timeout: 300,                    # wait for the response headers
  inactivity_timeout: 1400,             # max gap between body chunks
)

client.raw_stream(body, ttfb_timeout: nil, inactivity_timeout: nil) do |item|
  # item: each parsed SSE data payload, and the Fast::Completions::SSE::DONE
  # sentinel in its wire position
end # => nil
```

The block is optional — a blockless call drains the stream. The method
returns `nil`: the block is the only output channel.

## The contract

- **Body.** A `String` is the request body verbatim; anything else is
  passed through `JSON.generate` (Hash insertion order preserved). No
  merging, no filtering, no `stream` injection, no Model or dialect
  involvement, no session-affinity headers. The caller's JSON is the
  contract.
- **Yields.** Every completed SSE `data:` payload, parsed, in arrival
  order. The wire's terminal DONE token is yielded as-is, in its wire
  position — `Fast::Completions::SSE::DONE`, a distinguished sentinel,
  not a string. A `finish_reason` stays the raw string; a usage chunk
  stays the raw Hash. There is no `Event` envelope (that is
  `Client#stream`'s shape — see
  [Reference: Stream events](stream-events.md)).
- **No accumulation.** No `Message` is built, no partial is kept, no
  salvage exists: a stream that ends without the terminal token simply
  ends — no `StreamError`, no stop-reason discipline.
- **No retry.** Exactly ONE `POST {base}/chat/completions`. A non-2xx
  raises the mapped API error (the §8 status mapping) immediately; the
  `x-should-retry` header is never consulted. Network failures raise
  `ConnectionError` on the first attempt.

## The two-deadline watchdog

| Deadline | Bounds | Armed | Fires as |
|---|---|---|---|
| `ttfb_timeout` | the wait for the response status + headers | before the POST | `TimeoutError` "no response headers within Ns" |
| `inactivity_timeout` | the gap between body chunks | at response receipt, re-armed after every chunk | `TimeoutError` "no data within Ns" |

Each deadline resolves independently per phase: the per-call kwarg,
else the constructor kwarg, else the shared `timeout` (default 30 s).
Prefill-scale values are first-class: a whole-context prefill at
~200 tok/s can legitimately take minutes between chunks, so
`inactivity_timeout: 1400` is a normal setting, not an outlier.

Every explicitly-given value — constructor or per-call — must be a
positive `Numeric`, else `ArgumentError` ("<name> must be a positive
Numeric") raises before any request is made. Both constructor knobs are
exposed as readers (`#ttfb_timeout`, `#inactivity_timeout`).

A fired watchdog cancels the waiting task and surfaces the phase-named
`TimeoutError` — never `CancelledError` — so a timeout is
distinguishable from a user cancel. A user cancel surfaces
`CancelledError` ("stream cancelled") with no retry.

## Optional authentication

`api_key` is an optional constructor kwarg. The `authorization`
header is sent only when the key is present and non-empty; with no key
the request carries just `content-type` and `accept`. With a key
present, the header set is identical to `Client#stream`'s.

## Errors

| Error | Raised for |
|---|---|
| `ApiError` subtree (`BadRequestError`, `RateLimitError`, `ServerError`, …) | a non-2xx response, the §8 status mapping (see [Reference: Errors](errors.md)) |
| `ConnectionError` | the network family — ECONNREFUSED, ECONNRESET, … — message form `"<class>: <message>"` |
| `TimeoutError` | a fired watchdog, phase-named (see the table above) |
| `CancelledError` | the caller's task was cancelled (NOT under `Error`) |

There is no `StandardError` catch-all on this surface and no
`StreamError`: whatever the block raises propagates unchanged.

## The drop-and-count seam

A malformed payload rides the same chunk seam as `Client#stream`
(I61): the SSE parser first rejoins a payload cut across lines, then
`JSON.parse`, then ONE repair pass (raw control characters inside
strings escaped). A payload still unparseable after repair is dropped
— counted on `Client#dropped_chunks`, never raised — and the stream
continues to its natural terminal.

## A worked proxy example

A local inference engine, no key, prefill-scale inactivity budget —
forward the caller's body untouched and relay the parsed payloads:

```ruby
require "fast/completions"

upstream = Fast::Completions::Client.new(
  base_url: "http://127.0.0.1:8080/v1",   # the local engine
  ttfb_timeout: 300,                      # zombie-child detection
  inactivity_timeout: 1400,               # one full-context prefill counts as ONE idle gap
)

def relay(upstream, request_json, out)    # request_json: the caller's body, verbatim
  upstream.raw_stream(request_json) do |item|
    if item.equal?(Fast::Completions::SSE::DONE)
      out << "data: [DONE]\n\n"           # re-emit the wire's terminal token
    else
      out << "data: #{JSON.generate(item)}\n\n"
    end
  end
end
```

The proxy never inspects or rewrites the body, never accumulates a
message, and never retries: one request in, the wire relayed out. See
the README's [Raw streaming](../../README.md#raw-streaming) section
for the orientation and [Reference: Errors](errors.md) for the full
error taxonomy.
