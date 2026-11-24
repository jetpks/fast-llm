# frozen_string_literal: true

# Error taxonomy pins: the frozen status table, the ApiError message
# form, the taxonomy SHAPE (CancelledError deliberately NOT under Error;
# ResponseError is the lying-2xx surface), and the provider-message
# parse ladder.
require "fast/embeddings"

RSpec.describe Fast::Embeddings::Errors do
  def error_for(status, body)
    described_class.class_for_status(status, body).new(status: status, body: body)
  end

  it "maps the frozen status table: 400/401/403/404/429/5xx, else ApiError" do
    expect(error_for(400, "x")).to be_a(Fast::Embeddings::BadRequestError)
    expect(error_for(401, "x")).to be_a(Fast::Embeddings::AuthenticationError)
    expect(error_for(403, "x")).to be_a(Fast::Embeddings::PermissionError)
    expect(error_for(404, "x")).to be_a(Fast::Embeddings::NotFoundError)
    expect(error_for(429, "x")).to be_a(Fast::Embeddings::RateLimitError)
    expect(error_for(500, "x")).to be_a(Fast::Embeddings::ServerError)
    expect(error_for(503, "x")).to be_a(Fast::Embeddings::ServerError)
    expect(error_for(418, "x")).to be_a(Fast::Embeddings::ApiError)
  end

  it "carries NO overflow machinery: a 400 stays a plain BadRequestError" do
    expect(error_for(400, "prompt is too long: 213462 tokens > 200000 maximum"))
      .to be_a(Fast::Embeddings::BadRequestError)
    expect(Fast::Embeddings.const_defined?(:ContextLengthExceededError, false)).to be(false)
  end

  it "formats ApiError#message as '<status>: <message>' from error.message, else truncated raw body" do
    nested = error_for(429, %({"error":{"message":"slow down"}}))
    expect(nested.message).to eq("429: slow down")
    expect(nested.status).to eq(429)
    expect(nested.body).to eq(%({"error":{"message":"slow down"}}))

    top_level = error_for(400, %({"message":"bad shape"}))
    expect(top_level.message).to eq("400: bad shape")

    raw = error_for(400, "A" * 900)
    expect(raw.message).to eq("400: #{'A' * 500}")
  end

  it "pins the taxonomy SHAPE: Timeout/Connection/Response under Error; CancelledError NOT under Error" do
    expect(Fast::Embeddings::TimeoutError).to be < Fast::Embeddings::Error
    expect(Fast::Embeddings::ConnectionError).to be < Fast::Embeddings::Error
    expect(Fast::Embeddings::ResponseError).to be < Fast::Embeddings::Error
    expect(Fast::Embeddings::ApiError).to be < Fast::Embeddings::Error
    expect(Fast::Embeddings::CancelledError).not_to be < Fast::Embeddings::Error
    expect(Fast::Embeddings::CancelledError).to be < StandardError
  end

  it "builds ResponseError messages for each lying-2xx shape" do
    expect { raise Fast::Embeddings::ResponseError, "embeddings reply is not JSON: \"<html>\"".inspect }
      .to raise_error(Fast::Embeddings::ResponseError, /not JSON/)
  end

  it "keeps value objects frozen and comparable (the completions Usage house style)" do
    datum = Fast::Embeddings::Datum.new(embedding: [0.1, -2.5], index: 3)
    expect(datum).to be_frozen
    expect(datum).to eq(Fast::Embeddings::Datum.new(embedding: [0.1, -2.5], index: 3))
    expect(datum.to_h).to eq(embedding: [0.1, -2.5], index: 3)

    usage = Fast::Embeddings::Usage.new(prompt_tokens: 7, total_tokens: 9)
    expect(usage).to be_frozen
    expect(usage).to eq(Fast::Embeddings::Usage.new(prompt_tokens: 7, total_tokens: 9))
    expect(usage).not_to eq(Fast::Embeddings::Usage::ZERO)
    expect(Fast::Embeddings::Usage.for_wire(nil)).to eq(Fast::Embeddings::Usage::ZERO)
    expect(Fast::Embeddings::Usage.for_wire("garbage")).to eq(Fast::Embeddings::Usage::ZERO)

    result = Fast::Embeddings::Result.new(data: [datum], usage: usage)
    expect(result).to be_frozen
    expect(result).to eq(Fast::Embeddings::Result.new(data: [datum], usage: usage))
    expect(result.to_h).to eq(data: [datum], usage: usage)
  end
end
