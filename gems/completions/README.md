# fast-completions

`Fast::Completions` is a standalone, fiber-native client for
**the OpenAI-compatible chat-completions wire**, byte-faithful to pi's
wire behavior. It speaks `POST {base}/chat/completions` with SSE
streaming.

It does NOT speak the legacy text-completions API (`/v1/completions`) —
that legacy endpoint is a different wire, and this gem never emits it.

## What it is NOT

- No model catalog, no pricing, no provider registry. The consumer owns
  models; the gem owns the wire.
- No universal translation. Dialects are **declarations** — a closed,
  small vocabulary the codec obeys. (LiteLLM's translate-everything
  ambition is the anti-shape.)
- No retries, no images over the wire, no non-streaming requests. The
  client always streams.

## Installation

```ruby
gem "fast-completions"
```

The ONLY runtime dependency is `async-http` (`async`/`io-event` arrive
transitively). Nothing else rides along — the whole transport is the
async socketry stack.

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

Async do |task| # fiber-native: runs inside YOUR reactor
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
| `CancelledError` | task cancellation (NOT under `Error`) |

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
