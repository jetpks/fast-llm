# The fiber-native design

The gem runs entirely inside the caller's `Async` reactor. It never creates a
thread and never creates a reactor of its own — every wait is an async wait,
cooperative with everything else sharing the reactor.

## One client, one pool

`Fast::Completions::Client` holds ONE persistent `Async::HTTP::Client`, built
at initialization; every request reuses its connection pool. Complete
responses return their connections to the pool; an aborted read — a cancel or
a timeout — discards its connection rather than reuse it.
`client.close` releases the pool.

## Requests are reactor tasks

`Client#stream` runs inside the caller's task. A watchdog task — armed with
the single `timeout:` value — enforces the time-to-first-byte deadline and
re-arms itself after every body chunk as the read-inactivity timer. The
watchdog is a sibling task on the same reactor, not a thread.

## Cancellation is Async::Cancel

`Chat#cancel` — or `Async::Cancel` on the enclosing task — unwinds the
in-flight read. The rescue ladder distinguishes a fired watchdog
(`TimeoutError`) from a user cancel (`CancelledError`), and a cancel never
produces a terminal event: no `:error`, no `:done`, no half-written history.
Off-reactor there is nothing to cancel; the checkpoints are no-ops.

## The batch executor

When a turn ends in tool calls, the Chat runs the batch as ONE reactor child
per call — children of the step task. The calls execute concurrently; the
join re-raises immediately on cancel, never waiting out natural completion;
tool results append to the history in CALL order after the join, so the wire
bytes match a serial run exactly. A raising `execute` isolates to that call's
error result; `CancelledError` re-raises, never laundered into a result.
There is no concurrency knob — a single-call batch is the degenerate case.

The consumer-facing discipline is in
[How to cancel a running chat](../how-to/cancel-a-running-chat.md); the batch
and hook contract is in [Reference: Tool](../reference/tools.md).
