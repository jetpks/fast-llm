# fast-llm

The fast-llm monorepo: a collection of small, standalone, releasable
Ruby gems, each named for the API it speaks.

## What lives here

- [`gems/completions`](gems/completions/README.md) — `fast-completions`
  (`Fast::Completions`), a fiber-native client for the
  OpenAI-compatible chat-completions wire, byte-faithful to pi. Docs live
  under [`gems/completions/docs/`](gems/completions/docs/).
- [`gems/embeddings`](gems/embeddings/README.md) — `fast-embeddings`
  (`Fast::Embeddings`), a fiber-native client for the OpenAI embeddings
  wire: one POST per call, one JSON reply back — no dialects, no
  extensions, credentials per call.

## The naming rule

Gems are named for the wire API they speak, not for a vendor:
`fast-completions` speaks chat completions. Siblings (fast-messages,
fast-responses) will follow the same rule.

## Releases

Release tags are cut by hand at landing; the loop never pushes and never
cuts tags. Tags are per gem, named `<gem>-v<semver>` — e.g.
`completions-v0.11.0` or `embeddings-v0.1.0`. A bare `v*` tag is
rejected loudly by the release workflow — there is no legacy path. The
workflow (`.github/workflows/release.yml`) maps each tag prefix to its
gem (directory, gemspec, require path) and publishes via RubyGems
trusted publishing; a `workflow_dispatch` run dry-runs build + verify
of every packaged gem without publishing.

See the gem READMEs under `gems/` for installation, quickstart, and the
exact guarantees each gem makes.
