# frozen_string_literal: true

require "json"

module Fast
  module Embeddings
    # Frozen value objects (the completions `Usage` house style:
    # keyword init, freeze, to_h, ==). The wire's numbers arrive
    # VERBATIM — no Float coercion, no reordering; the caller zips
    # embeddings to its texts by index.
    class Datum
      attr_reader :embedding, :index

      def initialize(embedding:, index:)
        @embedding = embedding
        @index = index
        freeze
      end

      def to_h
        {embedding:, index:}
      end

      def ==(other)
        other.is_a?(Datum) && to_h == other.to_h
      end
    end

    # Token accounting, surfaced per call — the spend surface the
    # caller records at its embed call site. A missing or non-Hash wire
    # usage yields zeros: the honest "the provider said nothing"
    # posture.
    class Usage
      attr_reader :prompt_tokens, :total_tokens

      def initialize(prompt_tokens: 0, total_tokens: 0)
        @prompt_tokens = prompt_tokens
        @total_tokens = total_tokens
        freeze
      end

      # Surface what the wire said; zeros when it said nothing.
      def self.for_wire(raw)
        return ZERO unless raw.is_a?(Hash)

        new(prompt_tokens: raw["prompt_tokens"] || 0, total_tokens: raw["total_tokens"] || 0)
      end

      def to_h
        {prompt_tokens:, total_tokens:}
      end

      def ==(other)
        other.is_a?(Usage) && to_h == other.to_h
      end

      ZERO = new.freeze
    end

    # The one embed-call outcome: data in WIRE ORDER (never re-sorted by
    # index) plus the usage — the J-SPEND call site reads this per call.
    class Result
      attr_reader :data, :usage

      def initialize(data:, usage:)
        @data = data
        @usage = usage
        freeze
      end

      def to_h
        {data:, usage:}
      end

      def ==(other)
        other.is_a?(Result) && to_h == other.to_h
      end
    end
  end
end
