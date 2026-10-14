# frozen_string_literal: true

# Fast::Completions — a fiber-native client for the OpenAI-compatible
# chat-completions wire, byte-faithful to pi. One require loads the whole
# surface (§1).
require "json"

require_relative "completions/version"
require_relative "completions/errors"
require_relative "completions/types"
require_relative "completions/dialects"
require_relative "completions/sse"
require_relative "completions/codec"
require_relative "completions/protocol"
require_relative "completions/client"
require_relative "completions/tool"
require_relative "completions/cancellation"
require_relative "completions/chat"

module Fast
  # The dialect DSL entry (§4): declare with a block, look up without.
  # Re-declaring a name OVERRIDES — last declaration wins.
  module Completions
    class << self
      # Declare with a block (and/or keyword overrides); look up without —
      # raises KeyError if undeclared (§3). Re-declaring a name OVERRIDES
      # — last declaration wins.
      def dialect(name, **overrides, &block)
        return Dialects.fetch(name) if block.nil? && overrides.empty?

        Dialects.declare(name, **overrides, &block)
      end

      def dialects
        Dialects.all
      end
    end
  end
end
