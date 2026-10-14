# Reference: Stream events

`Client#stream` and `Chat#step` yield `Fast::Completions::Event` value objects
to the block, in stream order. Fields are per-type; the ones a type doesn't
carry are nil. Every block event carries `partial`; block events also carry
`content_index`, the block's position in `partial.content`.

| Type | Fields | Fires when |
|---|---|---|
| `:start` | `partial` | Before the first block event of every streamed reply |
| `:text_start` | `content_index` | A text block opens |
| `:text_delta` | `content_index`, `delta` | Text appends to the open text block |
| `:text_end` | `content_index`, `content` | The text block finalizes |
| `:thinking_start` | `content_index` | A thinking block opens |
| `:thinking_delta` | `content_index`, `delta` | Thinking appends |
| `:thinking_end` | `content_index`, `content` | The thinking block finalizes |
| `:tool_call_start` | `content_index` | A tool_call block opens |
| `:tool_call_delta` | `content_index`, `delta` | Raw argument bytes arrive (live-parsed into `partial`) |
| `:tool_call_end` | `content_index`, `tool_call` | Arguments finalize as `{id:, name:, arguments:}` |
| `:error` | `reason`, `message` | Client-level: the failed terminal — `StreamError` raises right after |
| `:done` | `reason`, `message` | Client-level terminal: the finish reason — `:stop`, `:length`, or `:tool_use` |

## partial is live

`partial` is the ONE assistant Message the stream accumulator mutates in
place. Events carry that instance, never a copy — by the time you handle an
event, the message already contains everything streamed so far, and the
`:done` event's `message` IS the final answer `step` returns.

## Thinking blocks

The first non-empty of `reasoning_content`, `reasoning`, `reasoning_text` in a
delta names the thinking block; later deltas carrying the same field append to
it. Provider `reasoning_details` accumulate separately and serialize into the
block's signature once, at `thinking_end`.

## The step block contract

```ruby
answer = chat.step do |event|
  puts event.delta if event.type == :text_delta
end
```

The block receives every event as it arrives, on the streaming fiber — keep it
cheap, never block the reactor. `step` returns the final assistant Message. A
`:done` with reason `:tool_use` means the tool batch runs before `step`
returns; the batch contract is in [Reference: Tool](tools.md).

## See also

[Tutorial: your first chat run](../tutorials/first-run.md) ·
[Reference: Errors](errors.md)
