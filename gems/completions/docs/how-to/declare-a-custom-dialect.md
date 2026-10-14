# How to declare a custom dialect

Three moves: declare, mount, override later.

## 1. Declare

```ruby
Fast::Completions.dialect(:acme) do
  max_tokens_field "max_tokens"
  supports_store false
end
```

The keyword form works too, and keywords override the block when both are
given. An empty declaration is legal — every key at its default.

```ruby
Fast::Completions.dialect(:acme, max_tokens_field: "max_tokens")
```

## 2. Mount on a Model

```ruby
model = Fast::Completions::Model.new(
  id: "acme-large",
  reasoning: true,
  context_window: 128_000,
  max_tokens: 4096,
  dialect: :acme,
)
```

A Symbol dialect resolves through the registry at use time, so a later
re-declaration under `:acme` overrides every model mounted on the symbol.
Pass an explicit `Dialect` instance instead if you want to pin the values.

## 3. Last-wins override

Re-declaring a name replaces the earlier declaration — last declaration wins,
deterministically, everywhere:

```ruby
Fast::Completions.dialect(:acme) { supports_store true } # replaces the one above
```

## The closed-vocabulary failure

Only the 13 vocabulary keys exist. An unknown key or an unknown value raises
`ArgumentError` at declaration time, with the allowed set spelled out — a
typo fails loud instead of mistranslating on the wire:

```ruby
Fast::Completions.dialect(:acme) { supports_stores false }
# ArgumentError: unknown dialect key :supports_stores; the vocabulary is closed to [:thinking_format, ...]
```

Every key, default, and allowed value is tabled in
[Reference: Dialects](../reference/dialects.md); the reasoning behind the
closed vocabulary is in
[Dialects as data](../explanation/why-dialects-as-data.md).
