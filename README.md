# fast-llm

The fast-llm monorepo: a collection of small, standalone, releasable
Ruby gems, each named for the API it speaks.

## What lives here

- [`gems/completions`](gems/completions/README.md) — `fast-completions`
  (`Fast::Completions`), a fiber-native client for the
  OpenAI-compatible chat-completions wire, byte-faithful to pi. Docs live
  under [`gems/completions/docs/`](gems/completions/docs/).

## The naming rule

Gems are named for the wire API they speak, not for a vendor:
`fast-completions` speaks chat completions. Siblings (fast-messages,
fast-responses) will follow the same rule.

## Releases

Release tags are cut by hand at landing; the loop never pushes and never
cuts tags.

See the gem READMEs under `gems/` for installation, quickstart, and the
exact guarantees each gem makes.
