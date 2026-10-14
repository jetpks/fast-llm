# Tutorial: your first chat run

This grows the README's Quickstart into a working first run: one client, one
model, one tool, a streamed turn, the tool round trip, and a follow-up turn
that consumes the tool result. You need Ruby 3.3+ and an OpenAI-compatible
endpoint.

## 1. Install and require

```ruby
gem "fast-completions"
```

```ruby
require "fast/completions"
```

## 2. Declare a model and a client

```ruby
model = Fast::Completions::Model.new(
  id: "my-model",
  reasoning: true,
  context_window: 128_000,
  max_tokens: 4096,
)

client = Fast::Completions::Client.new(
  base_url: "https://api.example.com/v1",
  api_key: ENV["API_KEY"],
)
```

The model is consumer-owned metadata (`dialect:` mounts a dialect — see
[Reference: Dialects](../reference/dialects.md)); the client holds ONE
persistent HTTP connection pool and must run inside a reactor, which is the
next step.

## 3. Declare one tool

```ruby
class ReadFile < Fast::Completions::Tool
  description "Read file contents."
  parameters do
    {"type" => "object", "required" => ["path"],
     "properties" => {"path" => {"type" => "string"}}}
  end

  def execute(path:)
    File.read(path)
  end
end
```

The schema is emitted on the wire verbatim; `execute`'s return value becomes
the tool result. The full DSL is in [Reference: Tool](../reference/tools.md).

## 4. Stream the first turn

```ruby
Async do
  chat = Fast::Completions::Chat.new(client: client, model: model)
  chat.with_instructions("You are a helpful assistant.")
      .with_tools(ReadFile)

  answer = chat.step do |event|
    puts event.delta if event.type == :text_delta
  end
  puts answer.to_h.inspect
end
```

The block sees every event as it arrives — all twelve types are in
[Reference: Stream events](../reference/stream-events.md) — and `step` returns
the final assistant Message. The `Async do` shape matters: the request runs
inside the caller's reactor; the gem never creates its own.

## 5. What complete? means

`chat.complete?` is false exactly when the last turn ended in tool calls whose
results are waiting for the model's next turn — after a tool round trip the
chat is NOT complete yet; after a plain stop it is. The batch itself already
ran before `step` returned: one reactor task per tool call, concurrently,
results appended in call order.

## 6. The follow-up turn

The tool results are already in the history, so the follow-up is another
`step` on the same chat:

```ruby
until chat.complete?
  answer = chat.step do |event|
    print event.delta if event.type == :text_delta
  end
end
```

Each iteration sends the accumulated history — instructions, turns, tool
results — and streams the model's answer.

## 7. Close

When you are done with the client, release the pool:

```ruby
client.close
```

## See also

[How to add a tool](../how-to/add-a-tool.md) ·
[How to cancel a running chat](../how-to/cancel-a-running-chat.md)
