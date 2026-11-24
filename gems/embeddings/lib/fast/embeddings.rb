# frozen_string_literal: true

# Fast::Embeddings — a fiber-native client for the OpenAI embeddings
# wire. One require loads the whole surface.
require "json"

require_relative "embeddings/version"
require_relative "embeddings/errors"
require_relative "embeddings/types"
require_relative "embeddings/client"

module Fast
  # The embeddings wire, and nothing else: POST {base}/embeddings with
  # {model, input}, one JSON reply back. Model naming belongs to the
  # caller; batch discipline belongs to the caller; retries belong to
  # the caller; credentials ride per call and are never stored.
  module Embeddings
  end
end
