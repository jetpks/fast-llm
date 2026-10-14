# Why streaming only

Every request this gem makes is `stream: true`. There is no synchronous chat
API, by design.

A chat-completions reply takes seconds and arrives as server-sent events the
whole time. A synchronous request would pin the calling fiber for that entire
window while the answer exists on the wire from the first token — on a
reactor, that stalls every other fiber sharing it, for no benefit: a caller
that wanted the whole answer can simply ignore the events and read the
returned Message.

So the gem's stance is fiber-native end to end. `#step` yields every delta to
your block the moment it lands, and the gem never holds a fiber hostage
waiting for a complete body outside the stream. Requests are cheap to start
and cheap to abandon: a cancel unwinds the read mid-flight instead of waiting
it out.

The wire is the OpenAI streaming shape, byte-faithful to pi's — one POST, one
streaming reply, `stream_options.include_usage` where the dialect supports it.
Having no non-streaming arm also removes an entire codec surface that could
drift from the oracle: there is exactly one request shape and one reply shape
to keep byte-identical.

The mechanics — one persistent HTTP client, requests as reactor tasks, the
watchdog, cancellation — are in
[The fiber-native design](fiber-native-design.md); the event vocabulary is in
[Reference: Stream events](../reference/stream-events.md).
