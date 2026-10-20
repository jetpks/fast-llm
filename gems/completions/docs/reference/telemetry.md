# Reference: Telemetry

`Client.new` accepts a `telemetry:` array of sink objects. The client
notifies every registered sink at a fixed set of observation points around a
completion — the gem defines observation points, nothing else. No sink ships
with the gem: a fast-prometheus adapter or an OTel-class tracer implements
the protocol below and observes completions without the gem knowing anything
about it.

## The completion

The unit of observation is a completion: ONE `Client#stream` invocation —
one logical exchange on `POST {base}/chat/completions` with `stream: true`.
Creation retries are INSIDE the completion: a completion that needed both
attempts is one completion, with one record and one TTFB (a retried
attempt's clock restarts). Tool execution — the Chat batch — is OUTSIDE it:
`Chat#step` closes the completion's record at `on_completion_end` (or
`on_completion_error`) before any tool runs.

A completion's record begins at `on_completion_start`, after the body is
serialized (the hook carries its bytesize). An exception before that point —
a malformed history raised while building the POST payload — belongs to the
caller and fires no hooks.

## Registration

```ruby
class TtfbSink
  include Fast::Completions::Telemetry::Sink

  def on_completion_ttfb(seconds)
    puts "ttfb: #{seconds}s"
  end
end

client = Fast::Completions::Client.new(
  base_url: "https://api.example.com/v1",
  api_key: "...",
  telemetry: [TtfbSink.new],
)
```

Include `Fast::Completions::Telemetry::Sink` for the no-op defaults and
override what you want, or respond to all five hooks without including
anything — registration is duck-typed. Validation is loud and happens once,
at construction: `telemetry:` must be an Array, and every element must
respond to all five hooks; anything else raises `ArgumentError` naming the
offending sink and the missing hook. The client stores its own frozen copy —
the caller's array is never frozen or mutated — and dispatches to multiple
sinks in registration order at every call site.

## Hook inventory

| Hook | Fires | Arguments |
|---|---|---|
| `on_completion_start(model_id, request_bytes)` | Exactly once per completion, before the first POST of the first attempt | `model_id`: the `Model#id` String ref, never a copy; `request_bytes`: the Integer bytesize of the serialized body actually POSTed |
| `on_completion_ttfb(seconds)` | At most once, at the FIRST item the SSE parser yields for the successful (2xx) attempt — before the `on_event` dispatches derived from that item. A retried attempt's clock restarts. Nothing fires when the completion fails before any item. Comments and keepalives never count: the parser drops them structurally | Float seconds from that attempt's POST initiation |
| `on_event(event)` | Every Event the consumer block sees, BEFORE the consumer block, same order — terminals (`:done`, `:error`) and the salvage-path `:error` included. With a registered sink and no consumer block, sinks still receive every Event | the Event ref the accumulator already allocated |
| `on_completion_end(stop_reason, duration, message)` | Exactly once, when `Client#stream` returns — after the `:done` event's dispatches | `stop_reason`: the mapped Symbol (`:stop`, `:length`, `:tool_use`); `duration`: Float from the completion-start clock; `message`: the accumulator's live assistant Message |
| `on_completion_error(error, duration)` | Exactly once on EVERY raise-out of `Client#stream` — the mapped error paths and any other raise re-raised through the ladder, including a consumer-block raise and cancellation (cancellation emits no terminal Event, but the record still closes) | `error`: a Symbol derived from the raising class — demodulized, underscored: `:rate_limit_error`, `:context_length_exceeded_error`, `:connection_error`, `:timeout_error`, `:cancelled_error`, `:stream_error`, `:runtime_error`; `duration`: Float start-to-raise on the same completion-start clock |

Terminal invariant: every completion fires `on_completion_start` exactly
once, then `on_event` zero or more times with at most one
`on_completion_ttfb` interleaved at the first payload, then EXACTLY ONE of
`on_completion_end` / `on_completion_error`.

## Ordering

For each event the sink is notified FIRST, then the consumer block; multiple
sinks dispatch in registration order. This is deliberate: telemetry is the
ground-truth record when consumer code is the suspect — a consumer block
that raises mid-stream leaves the sink's record complete. The salvage
`:error` event and the closing `on_completion_error` both fire even when the
raise came from consumer code — including a raise ON a terminal event itself
(the salvage `:error` or the `:done`), which closes the record with that
raise's symbol instead; `on_completion_end` fires only when `Client#stream`
returns.

## The read-only convention

The Message a sink receives on `on_completion_end` — and every
`event.partial` — is the accumulator's LIVE assistant Message: unfrozen by
design, the same object every event carries and `Chat` appends to history.
The protocol documents a READ-ONLY convention for sinks: observe, never
mutate. Two specifics: do not `JSON.parse` a `tool_call` block's `arguments`
on the hot path — that is an explicit opt-in cost a sink owns — and
nil-check `usage` (it may be nil by the Message contract; sinks nil-check
without allocating).

## The allocation contract

Zero added Ruby heap allocations on the existing hot paths when no sink is
registered, and zero ADDED heap objects even when a no-op sink is
registered. Every call site is guarded by a precomputed emptiness check that
short-circuits before any timestamp capture or dispatch — with no sink
there are also zero added `Process.clock_gettime` reads — and only existing
references and immediates cross the boundary: the `model.id` String ref, an
Integer bytesize, Float (flonum) durations and TTFB, Symbols, and the Event
and Message refs the accumulator already allocated. No Hash payloads, no
structs, no interpolated strings, no keyword splats. The spec suite pins all
three properties as measurement gates.

## Metric names belong to the adapter

This gem defines observation points, not metric names. A sink feeding
Prometheus, an OTel-class tracer, or a structured log owns its own naming,
units, labels, and cardinality decisions.

## See also

[Reference: Stream events](stream-events.md) ·
[Reference: Errors](errors.md)
