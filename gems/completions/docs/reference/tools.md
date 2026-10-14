# Reference: Tool

`Fast::Completions::Tool` is the base class for tool calling. A subclass declares
its wire schema with the class-level DSL and implements `execute`; the Chat turns
the declaration into the request's `tools` entries and runs the batch.

## Class-level DSL

| Declaration | Rule |
|---|---|
| `description "text"` | The function description sent on the wire. |
| `tool_name "name"` | Optional wire-name override. |
| `parameters(schema)` | The JSON Schema Hash sent as `function.parameters` — a literal Hash… |
| `parameters { schema }` | …or a block returning one. Both forms store the Hash verbatim. |

The default schema, when `parameters` is never called, is
`{"type" => "object", "properties" => {}}`.

**The wire name rule.** The declared `tool_name` if set, else the class
basename: a subclass `ReadFile` is `"ReadFile"` on the wire; nested class names
are split on `::` first.

**Parameters are emitted VERBATIM.** The consumer's schema IS the wire bytes.
The gem adds no fields, validates nothing, and translates nothing — a
`parameters` Hash reaches the request exactly as declared.

## execute

Subclasses implement `execute`; the Chat calls it with the parsed argument JSON
splashed as keywords (the wire's string keys are symbolized for the call; the
history block itself is never mutated). The base implementation raises
`NotImplementedError`.

The outcome contract:

| `execute` returns | Tool result |
|---|---|
| a `String` — or any non-Hash | content is its `to_s`, success |
| a `Hash` | content is `JSON.generate` of it, success |
| `{error: "..."}` — a Hash whose only key is `:error` | content is the message, `is_error: true` |

## Registration

`Chat#with_tools` takes classes or instances; classes are instantiated at
registration and declaration order is preserved:

```ruby
chat.with_tools(ReadFile, GetWeather.new)
```

## Batch semantics

During a turn that ends in tool calls, the Chat runs the batch:

- **One reactor task per call — concurrent.** A batch of N executable calls
  runs as N children of the step task. Never block the reactor inside
  `execute`: no blocking syscalls, no CPU-bound loops; yield (sleep, async IO)
  or offload.
- **Results land in call order.** Whatever the completion order, tool-result
  messages append to the history in the order the model asked — history bytes
  identical to a serial run.
- **A raising `execute` isolates.** Any other `StandardError` becomes that
  call's error result (content = the message, `is_error: true`); siblings are
  unaffected and the turn completes. `CancelledError` is re-raised, never
  laundered into a result.
- **Cancel aborts the batch.** A cancel mid-batch aborts the in-flight
  children; `step` raises `CancelledError` and NO tool results are appended.
  See [How to cancel a running chat](../how-to/cancel-a-running-chat.md).

An unknown tool name finalizes immediately as the error result
`"no such tool: <name>"` — nothing executes for it.

## Hooks

```ruby
chat.before_tool_call { |tool_call| ... }       # tool_call = {id:, name:, arguments:}
chat.after_tool_result { |tool_call, result| ... }
```

Multiple hooks register and dispatch IN REGISTRATION ORDER, attributed by the
tool_call's `id` — no fiber-local pairing anywhere. Before hooks fire in the
serial before-phase, in call order, for every parsed tool_call block (unknown
tools included). After hooks fire inside each call's task as that call
completes — in completion order within a concurrent batch, each keyed by its
own call's id.

## See also

[How to add a tool](../how-to/add-a-tool.md) ·
[Tutorial: your first chat run](../tutorials/first-run.md) ·
[The fiber-native design](../explanation/fiber-native-design.md)
