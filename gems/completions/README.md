# fast-completions

`Fast::Completions` is a fast & focused HTTP client for OpenAI-compatible chat
completions APIs. It speaks `POST {base}/chat/completions` and supports SSE
streaming. It's implemented on top of [socketry/async-http] and won't block
your reactor.

## Fast & Focused

This gem is laser focused on **just the chat completions API**

It does:

* Streaming chat completions
* Tool calling ([see the tool docs])
* Pre-made & Custom "Dialects" (common API variations) ([see the dialect docs])

There are also a bunch of things `Fast::Completions` _does not_ do:

* No model catalog
* No other API shapes 
* No universal translation
* No synchronous requests (streaming only)
* No images over the wire

## Dialects

Various providers/models make slight deviations from the "official" API. To
support a wide variety of shapes, we have a concept of "Dialects." The default
dialect is `:openai`, and we also ship `:zai`, `:deepseek`, and `:fireworks`.

Custom dialects can also be declared at runtime. See the [Dialect Docs] for
more info.

## Installation

```ruby
gem "fast-completions"
```

The only runtime dependency is `async-http`.

## Quickstart

```ruby
require "fast/completions"

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

Async do |task| # fiber-native!
  chat = Fast::Completions::Chat.new(client: client, model: model)
  chat.with_instructions("You are a helpful assistant.")
      .with_tools(ReadFile)

  answer = chat.step do |event|
    puts event.delta if event.type == :text_delta
  end
  puts answer.to_h.inspect
end
```

## Dialects as data

A dialect is a declaration. The vocabulary is closed (13 keys); unknown
keys or values raise `ArgumentError` at declaration time — fail loud,
never silently mistranslate. `:zai`, `:deepseek`, and `:fireworks` ship
as declarations:

```ruby
Fast::Completions.dialect(:zai) do
  thinking_format :zai
  zai_tool_stream true
  max_tokens_field "max_tokens"
  supports_developer_role false
  supports_reasoning_effort true
  supports_store false
end

model = Fast::Completions::Model.new(..., dialect: :zai)
Fast::Completions.dialect(:zai)         # lookup (KeyError if undeclared)
Fast::Completions.dialects              # the frozen name→Dialect hash
Fast::Completions.dialect(:acme) { max_tokens_field "max_tokens" } # declare your own
```

Re-declaring a name overrides — last declaration wins.

## Error taxonomy

The error table moved to [the error docs](docs/reference/errors.md) —
every class with the status mapping, the timeout and connection families,
and why `CancelledError` stands outside `Error`.

## Parity

The request/stream codec is byte-faithful to pi's wire: a fixture
harness (recorded pi request bodies, SHA256-pinned) drives every codec
arm through the gem and asserts BYTE equality. See
`spec/fixtures/wire/` and `wire_parity_spec.rb`.

## Fiber-native

One persistent `Async::HTTP::Client` per `Fast::Completions::Client`;
requests run inside the caller's reactor — the gem never creates its
own. Cancellation (`Async::Cancel` / `Chat#cancel`) aborts the
in-flight request, discards the connection, and raises
`CancelledError` with no phantom terminal event.
[see the tool docs]: docs/reference/tools.md
[see the dialect docs]: docs/reference/dialects.md
[Dialect Docs]: docs/reference/dialects.md
[socketry/async-http]: https://github.com/socketry/async-http
