# Changelog

Notable changes to the fast-embeddings gem. The format is prose-first,
one section per released version, newest first.

## 0.1.0 (2026-11-24)

- Initial release: the pure OpenAI embeddings wire as a gem.
  `Client#embed(model:, input:, api_key: nil)` POSTs `{base}/embeddings`
  with the closed two-key body `{model, input}` and surfaces the reply's
  `data` (in wire order, verbatim numbers, never re-sorted by index) and
  `usage` (zeros when the provider omits it). Fiber-native on
  async-http — the only runtime dependency — one persistent HTTP client
  per instance, running inside the caller's reactor. Exactly one POST
  attempt per call: no retry machinery, no batch policy, no model
  catalog — slicing, retries, and model naming are the caller's.
  Credentials ride per call and are never stored.
