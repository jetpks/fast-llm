# frozen_string_literal: true

require "json"

module Fast
  module Completions
    # Frozen value objects (Specification §5). Public factory methods
    # freeze; the stream accumulator (§3 `partial`, pi's shared live
    # AssistantMessage) builds its Message via .new and mutates it in
    # place — that instance is the one sanctioned mutable Message.

    # The consumer-owned model metadata. `provider` is metadata ONLY —
    # it never reaches the wire; it drives same-model replay comparison
    # (Specification §12.3 note, §9.4).
    class Model
      # pi models.ts :1222 EXTENDED_THINKING_LEVELS, restricted to the
      # frozen Specification §9.3 ladder. (pi also carries :minimal;
      # the frozen ladder omits it — documented in the 0.1.0 notes.)
      LADDER = %i[off low medium high xhigh max].freeze

      attr_reader :id, :reasoning, :context_window, :max_tokens,
        :thinking_level_map, :provider

      def initialize(id:, reasoning:, context_window:, max_tokens:,
        thinking_level_map: nil, dialect: nil, provider: "fast-completions")
        raise ArgumentError, "id is required" unless id.is_a?(String) && !id.empty?
        raise ArgumentError, "reasoning is required (boolean)" unless reasoning == true || reasoning == false
        raise ArgumentError, "context_window is required (Integer)" unless context_window.is_a?(Integer)
        raise ArgumentError, "max_tokens is required (Integer)" unless max_tokens.is_a?(Integer)
        if thinking_level_map && !thinking_level_map.is_a?(Hash)
          raise ArgumentError, "thinking_level_map must be a Hash"
        end

        @id = id.dup.freeze
        @reasoning = reasoning
        @context_window = context_window
        @max_tokens = max_tokens
        @thinking_level_map = normalize_map(thinking_level_map)
        @dialect = dialect # Symbol resolves through the registry lazily (last declaration wins).
        @provider = provider.dup.freeze
        freeze
      end

      # The dialect for THIS model: an explicit Dialect, the registered
      # declaration for the symbol, or the plain default arm.
      def dialect
        case @dialect
        when Dialect then @dialect
        when Symbol then Dialects.fetch(@dialect)
        else Dialects.default
        end
      end

      # pi getSupportedThinkingLevels models.ts :1224-1232: :off when
      # non-reasoning; else the ladder filtered — a level is supported
      # when the map omits it or maps it non-nil; :xhigh/:max only when
      # the map names them.
      def supported_thinking_levels
        return %i[off].freeze unless reasoning

        LADDER.filter do |level|
          named = @thinking_level_map&.key?(level)
          mapped = named ? @thinking_level_map[level] : nil
          if level == :xhigh || level == :max
            named && !mapped.nil?
          else
            !named || !mapped.nil? # omitted, or mapped non-nil
          end
        end.freeze
      end

      # pi clampThinkingLevel models.ts :1235-1256: supported levels
      # pass through; an unknown level snaps to the first supported;
      # otherwise walk UP from the requested rung, then DOWN, else the
      # first supported.
      def clamp_thinking_level(level)
        available = supported_thinking_levels
        return level if available.include?(level)

        requested_index = LADDER.index(level)
        return available.first if requested_index.nil?

        LADDER.each_index do |i|
          next if i < requested_index

          candidate = LADDER[i]
          return candidate if available.include?(candidate)
        end
        requested_index.downto(0) do |i|
          candidate = LADDER[i]
          return candidate if available.include?(candidate)
        end
        available.first
      end

      private

      # Symbol-keyed, defensively dup'd — consumers pass {off: "none", ...}.
      def normalize_map(map)
        return nil if map.nil?

        map.each_with_object({}) { |(k, v), out| out[k.to_sym] = v.dup }.freeze
      end
    end

    # Token accounting (§10.1, pi parseChunkUsage openai-completions.ts
    # :1519-1547). total_tokens is NATIVE (OQ-9): the parser computes it
    # pi's way (input+output+cacheRead+cacheWrite), never re-summed later.
    class Usage
      attr_reader :input, :output, :cache_read, :cache_write, :reasoning, :total_tokens

      def initialize(input: 0, output: 0, cache_read: 0, cache_write: 0, reasoning: 0, total_tokens: 0)
        @input = input
        @output = output
        @cache_read = cache_read
        @cache_write = cache_write
        @reasoning = reasoning
        @total_tokens = total_tokens
        freeze
      end

      def to_h
        {input:, output:, cache_read:, cache_write:, reasoning:, total_tokens:}
      end

      def ==(other)
        other.is_a?(Usage) && to_h == other.to_h
      end

      ZERO = new.freeze
    end

    # History value object (§3, §5). Roles: :system / :user / :assistant
    # / :tool_result. Assistant content is an Array of block Hashes with
    # symbol keys: {type: :text, text:}, {type: :thinking, thinking:,
    # signature:}, {type: :tool_call, id:, name:, arguments:}.
    class Message
      ROLES = %i[system user assistant tool_result].freeze

      attr_reader :role, :content, :provider, :model, :api, :usage,
        :tool_call_id, :tool_name, :is_error, :response_id, :response_model

      def initialize(role:, content:, provider: nil, model: nil, api: nil,
        tool_call_id: nil, tool_name: nil, is_error: false, usage: nil)
        unless ROLES.include?(role)
          raise ArgumentError, "role must be one of #{ROLES.inspect}, got #{role.inspect}"
        end

        @role = role
        @content = deep_dup(content)
        @provider = provider
        @model = model
        @api = api
        @tool_call_id = tool_call_id
        @tool_name = tool_name
        @is_error = is_error == true
        @usage = usage
        @response_id = nil
        @response_model = nil
      end

      # Stream-internal mutation surface: the §3 shared `partial`
      # accumulator is ONE live Message (pi's output object, stream()
      # :312-327). These only work on unfrozen instances — factory-built
      # messages are frozen and raise FrozenError if mutated.
      def append_block(block)
        @content << block
      end

      def set_usage(usage)
        @usage = usage
      end

      def set_response_id(id) # first wins (§10)
        @response_id ||= id
      end

      def set_response_model(name)
        @response_model ||= name
      end

      # The public factories freeze (value semantics). The stream
      # accumulator constructs via .new and mutates — §3's shared
      # `partial` contract.
      def self.user(content)
        new(role: :user, content: content).freeze
      end

      def self.system(content)
        new(role: :system, content: content).freeze
      end

      def self.assistant(content, provider: nil, model: nil, api: nil)
        unless content.is_a?(Array)
          raise ArgumentError, "assistant content must be an Array of block hashes"
        end

        new(role: :assistant, content: content, provider: provider, model: model, api: api).freeze
      end

      def self.tool_result(tool_call_id:, content:, tool_name: nil, is_error: false)
        new(role: :tool_result, content: content, tool_call_id: tool_call_id,
          tool_name: tool_name, is_error: is_error).freeze
      end

      def user? = role == :user
      def assistant? = role == :assistant
      def system? = role == :system
      def tool_result? = role == :tool_result

      def to_h
        out = {role:, content: deep_dup(@content)}
        out[:provider] = @provider if @provider
        out[:model] = @model if @model
        out[:api] = @api if @api
        out[:tool_call_id] = @tool_call_id if @tool_call_id
        out[:tool_name] = @tool_name if @tool_name
        out[:is_error] = true if @is_error
        out[:usage] = @usage.to_h if @usage
        out[:response_id] = @response_id if @response_id
        out[:response_model] = @response_model if @response_model
        out
      end

      def self.from_h(hash)
        hash = hash.transform_keys(&:to_sym)
        message = new(
          role: hash.fetch(:role).to_sym,
          content: hash.fetch(:content),
          provider: hash[:provider],
          model: hash[:model],
          api: hash[:api],
          tool_call_id: hash[:tool_call_id],
          tool_name: hash[:tool_name],
          is_error: hash[:is_error] == true,
          usage: hash[:usage] && Usage.new(**hash[:usage].transform_keys(&:to_sym)),
        )
        message.set_response_id(hash[:response_id]) if hash[:response_id]
        message.set_response_model(hash[:response_model]) if hash[:response_model]
        message
      end

      private

      # Plain-Hash/Array deep dup — consumers hand us their structures;
      # the gem never mutates a consumer message (§12).
      def deep_dup(node)
        case node
        when Hash then node.each_with_object({}) { |(k, v), out| out[k] = deep_dup(v) }
        when Array then node.map { |item| deep_dup(item) }
        when String then node.dup
        else node
        end
      end
    end

    # Stream events (§3; pi types.ts :794-816 AssistantMessageEvent
    # vocabulary, Ruby symbols). Fields are per-type; unknown ones are nil.
    class Event
      attr_reader :type, :content_index, :delta, :content, :tool_call,
        :message, :reason, :partial

      def initialize(type:, content_index: nil, delta: nil, content: nil,
        tool_call: nil, message: nil, reason: nil, partial: nil)
        @type = type
        @content_index = content_index
        @delta = delta
        @content = content
        @tool_call = tool_call
        @message = message
        @reason = reason
        @partial = partial
        freeze
      end
    end
  end
end
