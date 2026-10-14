# How to add a tool

Three moves: subclass, declare, register.

```ruby
class GetWeather < Fast::Completions::Tool
  description "Current weather for a city."
  tool_name "get_weather" # optional; default is the class basename
  parameters do
    {"type" => "object", "required" => ["city"],
     "properties" => {"city" => {"type" => "string"}}}
  end

  def execute(city:)
    {"city" => city, "temp_c" => 21}
  end
end

chat.with_tools(GetWeather) # or GetWeather.new — both accepted
```

The declared `parameters` Hash is emitted on the wire verbatim — nothing is
added, validated, or translated.

## The outcome contract

`execute` returns one of:

- a `String` (or any non-Hash) — the tool result content is its `to_s`;
- a `Hash` — JSON-generated into the tool result content;
- `{error: "..."}` (a Hash whose only key is `:error`) — an error result, with
  the message as content and `is_error` set for the provider.

## Fiber safety

`execute` runs on a reactor child — one task per call, concurrent within a
batch, results appended in call order. Never block the reactor inside it: no
blocking syscalls, no CPU-bound loops. A raising `execute` isolates to that
call's error result; siblings are unaffected. A cancel mid-batch aborts the
in-flight children with no tool results appended.

The full batch and hook contract — hooks, registration order, id-keyed
attribution — is in [Reference: Tool](../reference/tools.md).

## See also

[Tutorial: your first chat run](../tutorials/first-run.md)
