# frozen_string_literal: true

module Fast
  module Completions
    # Dialects are DATA (D2): a closed declaration vocabulary consumed by
    # the codec arms. Nothing here is provider detection, a catalog, or a
    # base-URL constant — the consumer declares, the codec obeys (§4).
    #
    # The vocabulary is CLOSED to the 13 keys declared below. Unknown keys
    # and unknown enum values raise ArgumentError AT DECLARATION TIME —
    # fail loud, never silently mistranslate (the no-universal-translation
    # discipline).
    class Dialect
      # key => [default, allowed-values-or-nil] in canonical (to_h-stable)
      # order; nil allowed-values = free boolean.
      VOCABULARY = {
        thinking_format: [:openai, %i[openai zai deepseek].freeze],
        max_tokens_field: ["max_completion_tokens", %w[max_completion_tokens max_tokens].freeze],
        supports_developer_role: [true, nil],
        supports_reasoning_effort: [true, nil],
        supports_store: [true, nil],
        supports_usage_in_streaming: [true, nil],
        supports_finish_reason: [true, nil],
        requires_reasoning_content_on_assistant_messages: [false, nil],
        zai_tool_stream: [false, nil],
        thinking_token_budget_field: [nil, [nil, "thinking_token_budget", "thinking_budget", "thinking_budget_tokens"].freeze],
        supports_thinking_token_budget: [false, nil],
        send_session_affinity_headers: [false, nil],
        session_affinity_format: [:openai, %i[openai openai_nosession openrouter].freeze],
      }.freeze

      attr_reader :name

      def initialize(name = nil, **overrides)
        values = {}
        VOCABULARY.each_key { |key| values[key] = VOCABULARY[key][0] }
        overrides.each do |key, value|
          unless VOCABULARY.key?(key)
            raise ArgumentError,
              "unknown dialect key #{key.inspect}; the vocabulary is closed to #{VOCABULARY.keys.inspect}"
          end

          allowed = VOCABULARY[key][1]
          unless allowed.nil? || allowed.include?(value)
            raise ArgumentError, "invalid value #{value.inspect} for dialect key #{key.inspect}; allowed: #{allowed.inspect}"
          end

          values[key] = value
        end
        @name = name
        @values = values.freeze
        freeze
      end

      VOCABULARY.each_key do |key|
        define_method(key) { @values[key] }
      end

      # Declaration-order-stable (§4): canonical key order regardless of
      # the order the consumer declared in.
      def to_h
        @values.dup
      end

      def ==(other)
        other.is_a?(Dialect) && other.to_h == to_h
      end

      def inspect
        "#<Fast::Completions::Dialect #{(@name || :anonymous).inspect} #{to_h.inspect}>"
      end

      # The declaration DSL receiver: `thinking_format :zai`-style setters
      # validating against the same closed vocabulary (§4).
      class DSL
        Dialect::VOCABULARY.each_key do |key|
          define_method(key) { |value| @overrides[key] = value }
        end

        def initialize(name)
          @name = name
          @overrides = {}
        end

        attr_reader :name, :overrides

        def build
          Dialect.new(@name, **@overrides)
        end
      end
    end

    # The declaration registry + lookup (§4). Re-declaring a name
    # OVERRIDES — last declaration wins (documented consumer contract).
    module Dialects
      module_function

      # Declare with block DSL and/or keyword overrides; empty overrides
      # declare the all-defaults dialect (the :fireworks shape). Lookup
      # goes through Fast::Completions.dialect (the facade, §3).
      def declare(name, **overrides, &block)
        dialect =
          if block
            dsl = Dialect::DSL.new(name)
            dsl.instance_eval(&block)
            Dialect.new(name, **dsl.overrides.merge(overrides))
          else
            Dialect.new(name, **overrides)
          end
        registry[name] = dialect
      end

      def fetch(name)
        registry.fetch(name) { raise KeyError, "no dialect declared under #{name.inspect}" }
      end

      def registered
        registry.keys.freeze
      end

      # Frozen name→Dialect dup (§3 .dialects).
      def all
        registry.dup.freeze
      end

      # The plain arm: every default, thinking_format :openai (§4).
      def default
        @default ||= Dialect.new(nil).freeze
      end

      def reset! # test hook only
        @registry = nil
      end

      def registry
        @registry ||= {}
      end
    end

    # The well-known trio, SHIPPED as declarations, registered at require
    # time (§4):
    # - :zai — the I46 five-key subset + pi's zai store suppression
    #   (pi openai-completions.ts detectCompat :1642-1694: zai is
    #   non-standard ⇒ no store, no developer role, max_tokens;
    #   supportsReasoningEffort re-enabled per the I46 live behavior).
    # - :deepseek — pi's deepseek detection: non-standard, max_tokens,
    #   requiresReasoningContentOnAssistantMessages.
    # - :fireworks — the empty declaration (fireworks detects nothing in
    #   pi — the plain arm).
    Dialects.declare(:zai) do
      thinking_format :zai
      zai_tool_stream true
      max_tokens_field "max_tokens"
      supports_developer_role false
      supports_reasoning_effort true
      supports_store false
    end

    Dialects.declare(:deepseek) do
      thinking_format :deepseek
      max_tokens_field "max_tokens"
      supports_developer_role false
      supports_reasoning_effort true
      requires_reasoning_content_on_assistant_messages true
      supports_store false
    end

    Dialects.declare(:fireworks)
  end
end
