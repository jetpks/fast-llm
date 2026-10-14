# How to cancel a running chat

Call `chat.cancel` from another task on the same reactor:

```ruby
Async do |task|
  chat = build_chat
  give_up = task.async do
    sleep 5
    chat.cancel
  end

  chat.step { |event| render(event) }

  give_up.stop
end
```

## Mid-stream

`cancel` sets the latch and cancels the task running `#step`. The HTTP read
unwinds, the connection is discarded, and `step` raises
`Fast::Completions::CancelledError`. There is NO phantom terminal: the event
block never sees a trailing `:error` or `:done` after a cancel, and the
half-streamed turn is not appended to the history.

## Mid-batch

During a tool batch every call runs on its own reactor child. A cancel aborts
the in-flight children at their next checkpoint; `step` raises
`CancelledError`, NO tool results are appended, and no after hooks fire for
the aborted calls — nothing half-executed reaches the history. A tool that
cancels from inside itself cancels the step task: the whole batch unwinds and
`CancelledError` surfaces from `step`.

## The latch

`cancel` also latches the chat: any later `step` raises `CancelledError`
immediately ("chat cancelled") without issuing a request. A cancelled chat
does not revive; build a new one to continue.

## Connections

An aborted read discards its connection — a cancelled connection is never
reused. Complete responses return theirs to the pool. `client.close` releases
the whole pool when you are done. The mechanics are in
[The fiber-native design](../explanation/fiber-native-design.md).

## See also

[Reference: Errors](../reference/errors.md) — where `CancelledError` sits and
why it is not under `Error`.
