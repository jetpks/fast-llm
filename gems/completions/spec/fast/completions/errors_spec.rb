# frozen_string_literal: true

# Error taxonomy pins (Specification §8). The 25-pattern overflow list is
# ported verbatim from pi utils/overflow.ts :33-96.
require "fast/completions"

RSpec.describe Fast::Completions::Errors do
  def error_for(status, body)
    described_class.class_for_status(status, body).new(status: status, body: body)
  end

  it "maps the frozen status table" do
    expect(error_for(401, "x")).to be_a(Fast::Completions::AuthenticationError)
    expect(error_for(403, "x")).to be_a(Fast::Completions::PermissionError)
    expect(error_for(404, "x")).to be_a(Fast::Completions::NotFoundError)
    expect(error_for(429, "x")).to be_a(Fast::Completions::RateLimitError)
    expect(error_for(500, "x")).to be_a(Fast::Completions::ServerError)
    expect(error_for(503, "x")).to be_a(Fast::Completions::ServerError)
    expect(error_for(418, "x")).to be_a(Fast::Completions::ApiError)
  end

  it "400 defaults to BadRequestError" do
    expect(error_for(400, "nope")).to be_a(Fast::Completions::BadRequestError)
    expect(error_for(400, "nope")).not_to be_a(Fast::Completions::ContextLengthExceededError)
  end

  it "detects context overflow through ANY of pi's patterns (≥3 pinned, §8)" do
    expect(error_for(400, %(prompt is too long: 213462 tokens > 200000 maximum)))
      .to be_a(Fast::Completions::ContextLengthExceededError)                       # Anthropic/z.ai
    expect(error_for(400, %(Your input exceeds the context window of this model)))
      .to be_a(Fast::Completions::ContextLengthExceededError)                       # OpenAI
    expect(error_for(400, %(Requested token count exceeds the model's maximum context length of 131072 tokens)))
      .to be_a(Fast::Completions::ContextLengthExceededError)                       # OpenAI/LiteLLM
    expect(error_for(400, %({"error":{"message":"This model's maximum prompt length is 131072 but the request contains 537812 tokens"}})))
      .to be_a(Fast::Completions::ContextLengthExceededError)                       # xAI, nested in parsed JSON
    expect(error_for(400, %({"code":"1261","message":"Prompt too long"})))
      .to be_a(Fast::Completions::ContextLengthExceededError)                       # z.ai JSON body
    expect(error_for(400, %("the request exceeds the available context size, try increasing it")))
      .to be_a(Fast::Completions::ContextLengthExceededError)                       # llama.cpp
    expect(error_for(400, %({"error":{"message":"Range of input length should be [1, 6144]"}})))
      .to be_a(Fast::Completions::ContextLengthExceededError)                       # DashScope/Qwen
  end

  it "carries the full pattern list ported verbatim (25 patterns, pi overflow.ts :33-96)" do
    expect(described_class::OVERFLOW_PATTERNS.size).to eq(25)
  end

  it "formats ApiError#message as '<status>: <message>' from error.message, else truncated raw body" do
    parsed = error_for(429, %({"error":{"message":"slow down"}}))
    expect(parsed.message).to eq("429: slow down")
    expect(parsed.status).to eq(429)
    expect(parsed.body).to eq(%({"error":{"message":"slow down"}}))

    raw = error_for(400, "A" * 900)
    expect(raw.message).to eq("400: #{'A' * 500}")
  end

  it "keeps StreamError under Error with its stop_reason (§8)" do
    err = Fast::Completions::StreamError.new("Provider finish_reason: content_filter", stop_reason: :error)
    expect(err).to be_a(Fast::Completions::Error)
    expect(err.stop_reason).to eq(:error)
  end

  it "keeps CancelledError OUTSIDE the Error tree (D8)" do
    expect(Fast::Completions::CancelledError).to be < StandardError
    expect(Fast::Completions::CancelledError).not_to be < Fast::Completions::Error
  end
end
