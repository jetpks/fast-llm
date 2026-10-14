# Reference: Dialects

A dialect is a declaration: a closed 13-key vocabulary of wire deviations that
the codec consumes as data. The default is the plain OpenAI arm; the gem ships
`:zai`, `:deepseek`, and `:fireworks` as declarations. There is no provider
detection and no base-URL constant anywhere — the consumer declares, the codec
obeys. See [Dialects as data](../explanation/why-dialects-as-data.md) for why.

## The vocabulary

Every key, its default, and its allowed values:

| Key | Default | Allowed values |
|---|---|---|
| `thinking_format` | `:openai` | `:openai`, `:zai`, `:deepseek` |
| `max_tokens_field` | `"max_completion_tokens"` | `"max_completion_tokens"`, `"max_tokens"` |
| `supports_developer_role` | `true` | boolean |
| `supports_reasoning_effort` | `true` | boolean |
| `supports_store` | `true` | boolean |
| `supports_usage_in_streaming` | `true` | boolean |
| `supports_finish_reason` | `true` | boolean |
| `requires_reasoning_content_on_assistant_messages` | `false` | boolean |
| `zai_tool_stream` | `false` | boolean |
| `thinking_token_budget_field` | `nil` | `nil`, `"thinking_token_budget"`, `"thinking_budget"`, `"thinking_budget_tokens"` |
| `supports_thinking_token_budget` | `false` | boolean |
| `send_session_affinity_headers` | `false` | boolean |
| `session_affinity_format` | `:openai` | `:openai`, `:openai_nosession`, `:openrouter` |

The vocabulary is CLOSED. An unknown key or an unknown enum value raises
`ArgumentError` at declaration time — fail loud, never silently mistranslate.
The two header keys drive the session-affinity headers `Client#stream` adds
when a `session_id` is supplied.

## What ships

The well-known trio registers at require time, verbatim:

```ruby
Dialects.declare(:zai) do
  thinking_format :zai
  zai_tool_stream true
  max_tokens_field "max_tokens"
  supports_developer_role false
  supports_reasoning_effort true
  supports_store false
end

Dialects.declare(:deepseek) do
  thinking_format :deepseek
  max_tokens_field "max_tokens"
  supports_developer_role false
  supports_reasoning_effort true
  requires_reasoning_content_on_assistant_messages true
  supports_store false
end

Dialects.declare(:fireworks)
```

(The same declarations may be written through the facade,
`Fast::Completions.dialect(:zai) do ... end`.) `:fireworks` is the empty
declaration — every key at its default, the plain arm.

## Declaring your own

Block DSL and keyword overrides combine; keywords win over the block. An empty
declaration is legal (the `:fireworks` shape):

```ruby
Fast::Completions.dialect(:acme) { max_tokens_field "max_tokens" }
Fast::Completions.dialect(:acme, max_tokens_field: "max_tokens") # same thing
Fast::Completions.dialect(:plain)                                # every default
```

Unknown keys and values raise `ArgumentError` naming the key and the allowed
set:

```ruby
Fast::Completions.dialect(:nope, thinking_format: :qwen)
# ArgumentError: invalid value :qwen for dialect key :thinking_format;
# allowed: [:openai, :zai, :deepseek]
```

## Lookup, registry, last-wins

```ruby
Fast::Completions.dialect(:zai) # the Dialect — KeyError if undeclared
Fast::Completions.dialects      # the frozen name→Dialect hash
```

Re-declaring a name OVERRIDES — last declaration wins, everywhere. That
includes models already built with the symbol: symbol dialects resolve through
the registry lazily, at use time.

## Mounting on a Model

`Model.new(dialect:)` takes a `Dialect`, a Symbol, or nothing:

- a `Dialect` instance is used as-is;
- a Symbol resolves through the registry at use time (so last-wins applies);
- nothing gives the shared plain default arm.

## Value semantics

A `Dialect` is frozen: per-key readers, `to_h` in canonical key order whatever
the declaration order was, and `==` by values. `Dialects.default` is the
shared plain arm.

## See also

[How to declare a custom dialect](../how-to/declare-a-custom-dialect.md) ·
[Reference: Errors](errors.md)
