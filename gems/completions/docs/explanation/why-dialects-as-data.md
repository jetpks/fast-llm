# Dialects as data

Provider differences — the token field name, thinking-block shapes, whether
`store` may be sent — are usually papered over with universal translation: a
library detects the vendor, often from the base URL, and silently rewrites
your request to what it thinks that vendor means. That shape fails in a
specific, miserable way: the rewrite is a guess, the guess is invisible, and
when a provider changes you find out on the wire.

This gem takes the opposite stance. A dialect is a DECLARATION the consumer
makes and the codec obeys:

- **The vocabulary is closed.** Thirteen keys, each with a frozen set of
  allowed values. Nothing else exists.
- **Fail loud at declaration.** An unknown key or value raises `ArgumentError`
  immediately, with the allowed set in the message — never silently
  mistranslate.
- **No detection anywhere.** No provider registry, no base-URL sniffing, no
  model catalog. The gem cannot guess wrong because it never guesses.
- **Declarations are frozen data.** A `Dialect` is a frozen value object;
  re-declaring a name replaces it — last declaration wins,
  deterministically.

The cost is honesty: you must know (or read) your provider's deviations. The
payment is that what goes on the wire is exactly what you declared, the
shipped `:zai` / `:deepseek` / `:fireworks` declarations are three readable
declarations rather than three branches of vendor-sniffing code, and a new
provider is a five-line declaration instead of a library release.

The vocabulary table is in [Reference: Dialects](../reference/dialects.md);
the task is in
[How to declare a custom dialect](../how-to/declare-a-custom-dialect.md).
