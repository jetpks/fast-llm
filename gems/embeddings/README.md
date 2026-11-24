# fast-embeddings

`Fast::Embeddings` is a fast & focused HTTP client for OpenAI-compatible
embeddings APIs. It speaks `POST {base}/embeddings` — one request, one
JSON reply. It's implemented on top of [socketry/async-http] and won't
block your reactor.

## Fast & Focused

This gem is laser focused on **just the embeddings API**.

It does:

* One POST per call with the closed two-key body `{model, input}`
* `data` surfaced in wire order, numbers verbatim, never re-sorted by
  index (the caller zips embeddings to texts by `index`)
* `usage` surfaced per call (zeros when the provider omits it)
* A watchdog-bounded deadline and a frozen error taxonomy

There are also a bunch of things `Fast::Embeddings` _does not_ do:

* No model catalog — the caller owns model naming; the `model:` string
  is opaque wire data
* No batch policy — the caller slices by its own `batch_max_texts` /
  `input_max_chars` admission control; the gem never slices, truncates,
  chunks, or re-orders `input`
* No retries — exactly one POST attempt per call; the caller retries
* No stored credentials — `api_key:` is a per-call kwarg, used for the
  call and discarded, never retained on the instance
* No other API shapes, no universal translation, no dialects
* No synchronous requests, no wire extensions — ever

## Installation

```ruby
gem "fast-embeddings"
```

The only runtime dependency is `async-http`.

## Quickstart

```ruby
require "fast/embeddings"

client = Fast::Embeddings::Client.new(base_url: "https://api.example.com/v1")

Async do |task| # fiber-native!
  result = client.embed(
    model: "text-embedding-3-small",
    input: ["first text", "second text"],
    api_key: ENV["API_KEY"], # optional; sent only when present and non-empty
  )
  result.data.each do |datum|
    puts "index #{datum.index}: #{datum.embedding.size} dims"
  end
  puts "usage: #{result.usage.to_h.inspect}"
  client.close
end
```

## Errors

Non-2xx replies map onto a frozen taxonomy; a lying 2xx body fails loud,
never silently.

| Class | Raised when |
|---|---|
| `BadRequestError` | HTTP 400 |
| `AuthenticationError` | HTTP 401 |
| `PermissionError` | HTTP 403 |
| `NotFoundError` | HTTP 404 |
| `RateLimitError` | HTTP 429 |
| `ServerError` | HTTP 5xx |
| `ApiError` | any other non-2xx (`#message` is `"<status>: <provider message>"`) |
| `TimeoutError` | no reply within `timeout:` |
| `ConnectionError` | network family (ECONNREFUSED, ECONNRESET, EOF, ...) |
| `ResponseError` | a 2xx body that is not valid embeddings JSON |
| `CancelledError` | the caller cancelled the task (deliberately NOT under `Error`) |

[socketry/async-http]: https://github.com/socketry/async-http
