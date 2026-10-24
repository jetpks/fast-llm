# frozen_string_literal: true

require_relative "args_streamer"

module Fast
  module Completions
    # THE BYTE CONTRACT (Specification §9): Ruby Hash insertion order +
    # JSON.generate must reproduce pi's wire bytes. Key emission order is
    # pi buildParams (openai-completions.ts :802-1000): model, messages,
    # stream, stream_options, store, max_tokens|max_completion_tokens,
    # temperature, tools (+tool_stream), thinking arms, thinking budget.
    # NOTHING else (§14: no tool_choice, no sampling, no prompt_cache_*).
    module Protocol
      # pi api/simple-options.ts :66-73.
      DEFAULT_THINKING_BUDGETS = {minimal: 1024, low: 2048, medium: 8192, high: 16384}.freeze
      MIN_ANSWER_TOKENS = 1024           # pi simple-options.ts :66
      CONTEXT_SAFETY_TOKENS = 4096       # pi simple-options.ts :11
      CHARS_PER_TOKEN = 3.5              # pi utils/estimate.ts :14

      module_function

      # Build the request Hash. `thinking` is the raw requested level
      # (nil = off-equivalent: no effort — pi streamSimple :760-763).
      def build_request(model:, messages:, instructions: nil, tools: [],
        thinking: nil, max_tokens: nil, temperature: nil)
        dialect = model.dialect
        effort = resolve_effort(model, thinking)
        normalized = Codec.normalize(messages, model)

        params = {
          model: model.id,
          messages: Codec.to_wire_messages(instructions, normalized, model, dialect),
          stream: true,
        }
        params[:stream_options] = {include_usage: true} if dialect.supports_usage_in_streaming # §9.4
        params[:store] = false if dialect.supports_store                                       # §9.5

        effective_max = clamp_max_tokens(model, instructions, messages, max_tokens)
        if effective_max # §9.6: key omitted only when no cap exists at all
          params[dialect.max_tokens_field == "max_tokens" ? :max_tokens : :max_completion_tokens] = effective_max
        end

        params[:temperature] = temperature unless temperature.nil? # §9.7: only when explicitly set

        apply_tools(params, tools, messages, dialect)     # §9.8
        apply_thinking_arms(params, model, dialect, effort, effective_max) # §9.9-9.10
        params
      end

      # pi streamSimple :760-763: clamp, then :off means NO effort.
      def resolve_effort(model, thinking)
        return nil if thinking.nil?

        clamped = model.clamp_thinking_level(thinking)
        clamped == :off ? nil : clamped
      end

      # §9.6 / pi clampMaxTokensToContext simple-options.ts :13-19:
      # min(requested || model.max_tokens, context − estimate − 4096), at
      # least 1; nil only when no requested cap AND model.max_tokens nil.
      def clamp_max_tokens(model, instructions, messages, max_tokens)
        requested = max_tokens || model.max_tokens
        return nil if requested.nil?
        return [1, requested].max if model.context_window <= 0

        available = model.context_window - Codec.estimate_tokens(instructions, messages) - CONTEXT_SAFETY_TOKENS
        [requested, [1, available].max].min
      end

      # §9.8 / pi buildParams :853-863: tools iff declared (declaration
      # order). Parameters stay VERBATIM — the consumer's schema is the
      # bytes — EXCEPT the I63 strict arm: a tool declaring
      # constrained_sampling on a strict dialect ships the strict REWRITE
      # (pi convertTools :1505-1516, getJsonSchemaToolParameters) and the
      # function object carries "strict" right after "parameters" (pi key
      # order: name, description, parameters, strict) — declared-strict
      # true, undeclared/loose false. VERBATIM remains the discipline for
      # undeclared tools and non-strict dialects: no strict key ever there,
      # and the emitted parameters are the declared object itself
      # (object-identity emission). zai tool_stream right after; the
      # `tools: []` fallback when tool history exists with no declared
      # tools.
      def apply_tools(params, tools, messages, dialect)
        if tools.any?
          strict_capable = dialect.supports_strict_mode
          params[:tools] = tools.map do |tool|
            strict = ConstrainedSampling.resolve_json_schema_strict_sampling(tool, strict_capable)
            function = {
              "name" => tool.name,
              "description" => tool.description,
              "parameters" => strict == true ? ConstrainedSampling.make_strict_json_schema(tool.parameters) : tool.parameters,
            }
            # pi :1513 — the explicit key on EVERY function tool when the
            # dialect supports strict mode ("Some reject unknown fields").
            function["strict"] = strict || false if strict_capable
            {"type" => "function", "function" => function}
          end
          params[:tool_stream] = true if dialect.zai_tool_stream
        elsif tool_history?(messages)
          params[:tools] = []
        end
      end

      # pi hasToolHistory openai-completions.ts :93-101.
      def tool_history?(messages)
        messages.any? do |msg|
          msg.tool_result? ||
            (msg.assistant? && msg.content.any? { |block| block[:type] == :tool_call })
        end
      end

      # §9.9 — model.reasoning gates EVERY arm (a non-reasoning model
      # emits none; pi's arm chain is entered only under
      # thinkingFormat checks conjoint with model.reasoning).
      def apply_thinking_arms(params, model, dialect, effort, effective_max)
        case dialect.thinking_format
        when :zai
          if model.reasoning # pi :880-892
            params[:thinking] = effort ? {"type" => "enabled", "clear_thinking" => false} : {"type" => "disabled"}
            if effort && dialect.supports_reasoning_effort
              mapped = mapped_effort(model, effort)
              params[:reasoning_effort] = mapped if mapped.is_a?(String)
            end
          end
        when :deepseek
          if model.reasoning # pi :928-937
            if effort
              params[:thinking] = {"type" => "enabled"}
            elsif deepseek_emits_disabled?(model)
              # pi: thinkingLevelMap?.off !== null — a map WITHOUT :off
              # also emits disabled; only an explicit off:null suppresses.
              params[:thinking] = {"type" => "disabled"}
            end
            if effort && dialect.supports_reasoning_effort
              params[:reasoning_effort] = mapped_effort(model, effort)
            end
          end
        else # the openai arm, pi :949-957
          if effort && model.reasoning && dialect.supports_reasoning_effort
            params[:reasoning_effort] = mapped_effort(model, effort)
          elsif !effort && model.reasoning && dialect.supports_reasoning_effort
            off = model.thinking_level_map&.[](:off)
            params[:reasoning_effort] = off if off.is_a?(String) # the off-floor
          end
        end
        apply_thinking_budget(params, model, dialect, effort, effective_max) # §9.10
      end

      # pi map-else-level: thinkingLevelMap?.[effort] ?? effort.
      def mapped_effort(model, effort)
        mapped = model.thinking_level_map&.[](effort)
        mapped.nil? ? effort.to_s : mapped
      end

      def deepseek_emits_disabled?(model)
        map = model.thinking_level_map
        map.nil? || !map.key?(:off) || !map[:off].nil?
      end

      # §9.10 / pi :961-963 + resolveClampedThinkingBudget :1012-1023:
      # budget = DEFAULT_THINKING_BUDGETS[clampReasoning(effort)] clamped
      # to answer room; emitted ONLY when > 0, AFTER the thinking arms.
      def apply_thinking_budget(params, model, dialect, effort, effective_max)
        field = dialect.thinking_token_budget_field ||
          (dialect.supports_thinking_token_budget ? "thinking_token_budget" : nil)
        return unless field && effort && model.reasoning

        budget = DEFAULT_THINKING_BUDGETS.fetch(clamp_reasoning(effort))
        ceiling = params[:max_tokens] || params[:max_completion_tokens] || model.max_tokens
        budget = [budget, [0, ceiling - MIN_ANSWER_TOKENS].max].min
        params[field.to_sym] = budget if budget > 0
      end

      # pi clampReasoning simple-options.ts :76-79: xhigh/max → high.
      def clamp_reasoning(effort)
        effort == :xhigh || effort == :max ? :high : effort
      end

      # ── §10 delta parse ────────────────────────────────────────────
      # (pi stream :304-734 — the per-chunk order, block machinery, and
      # stream-end discipline.)

      # pi parseChunkUsage :1519-1547. total_tokens NATIVE (OQ-9):
      # input+output+cache_read+cache_write, pi's formula.
      def parse_chunk_usage(raw)
        return Usage::ZERO unless raw.is_a?(Hash)

        details = raw["prompt_tokens_details"].is_a?(Hash) ? raw["prompt_tokens_details"] : {}
        cache_read = [details["cached_tokens"], raw["prompt_cache_hit_tokens"], raw["cached_tokens"]].compact.first || 0
        cache_write = details["cache_write_tokens"] || 0
        prompt = raw["prompt_tokens"] || 0
        input = [0, prompt - cache_read - cache_write].max
        output = raw["completion_tokens"] || 0
        reasoning_details = raw["completion_tokens_details"].is_a?(Hash) ? raw["completion_tokens_details"] : {}
        reasoning = reasoning_details["reasoning_tokens"] || 0
        Usage.new(
          input: input, output: output, cache_read: cache_read,
          cache_write: cache_write, reasoning: reasoning,
          total_tokens: input + output + cache_read + cache_write,
        )
      end

      # §10.2 / pi mapStopReason :1562-1589 → [reason, error_message].
      def map_stop_reason(raw_reason)
        case raw_reason
        when nil then [:stop, nil]
        when "stop", "end" then [:stop, nil]
        when "length" then [:length, nil]
        when "function_call", "tool_calls" then [:tool_use, nil]
        else [:error, "Provider finish_reason: #{raw_reason}"]
        end
      end

      # OQ-4: control-character repair (pi utils/json-parse.ts repairJson
      # :20-77), {} as the last resort (pi's partial-json fallback). The
      # repaired re-parse gets its OWN method — a rescue body's exception
      # is not caught by a later rescue clause of the same method (the
      # 0.4.0 leak: a delta boundary splitting an escape sequence left the
      # scratch buffer mid-string with a trailing backslash; repair "fixed"
      # it, the re-parse raised, and the step died). pi's outer try/catch
      # absorbs this; so do we.
      def parse_streaming_json(partial)
        return {} if partial.nil? || partial.strip.empty?

        JSON.parse(partial)
      rescue JSON::ParserError
        repaired = repair_json(partial)
        repaired == partial ? {} : parse_repaired_json(repaired)
      end

      def parse_repaired_json(repaired)
        JSON.parse(repaired)
      rescue JSON::ParserError
        {}
      end

      # Escape raw control characters inside strings; double backslashes
      # before invalid escape characters (pi repairJson, verbatim port).
      def repair_json(json)
        valid_escapes = %w[" \\ / b f n r t]
        repaired = +""
        in_string = false
        index = 0
        length = json.length
        while index < length
          char = json[index]
          unless in_string
            repaired << char
            in_string = true if char == '"'
            index += 1
            next
          end
          if char == '"'
            repaired << char
            in_string = false
            index += 1
            next
          end
          if char == "\\"
            nxt = json[index + 1]
            if nxt.nil?
              repaired << "\\\\"
              index += 1
              next
            end
            if nxt == "u"
              digits = json[index + 2, 4].to_s
              if digits.match?(/\A[0-9a-fA-F]{4}\z/)
                repaired << "\\u#{digits}"
                index += 6
                next
              end
            end
            if valid_escapes.include?(nxt)
              repaired << "\\" << nxt
              index += 2
              next
            end
            repaired << "\\\\"
            index += 1
            next
          end
          repaired << (char.ord <= 0x1f ? escape_control_character(char) : char)
          index += 1
        end
        repaired
      end

      def escape_control_character(char)
        case char
        when "\b" then "\\b"
        when "\f" then "\\f"
        when "\n" then "\\n"
        when "\r" then "\\r"
        when "\t" then "\\t"
        else format("\\u%04x", char.ord)
        end
      end

      # The live stream accumulator (pi stream :312-707). `partial` is
      # THE shared Message — events carry it, never a copy (§3).
      class StreamAccumulator
        attr_reader :partial

        def initialize(model, dialect)
          @model = model
          @dialect = dialect
          # pi output seed :312-327: usage zeros, stop pending.
          @partial = Message.new(role: :assistant, content: [],
            provider: model.provider, model: model.id, api: "openai-completions",
            usage: Usage::ZERO)
          @text_block = nil
          @thinking_block = nil
          @tool_by_index = {}
          @tool_by_id = {}
          @args_streamers = {}.compare_by_identity # per-block ArgsStreamer (I02); each owns its scratch
          @streamed_details = nil # :334-341
          @has_finish_reason = false
          @stop_reason = nil
          @error_message = nil
        end

        # No event precedes :start (§10.6; pi types.ts :789-794).
        def start_event
          Event.new(type: :start, partial: @partial)
        end

        # One JSON chunk in, ordered events out (pi per-chunk loop
        # :558-655).
        def consume(chunk)
          events = []
          chunk = {} unless chunk.is_a?(Hash)

          # OpenAI docs: every chunk carries the same completion id (pi
          # :561-566). First wins; a differing model name is recorded once.
          @partial.set_response_id(chunk["id"]) if chunk["id"]
          chunk_model = chunk["model"]
          if chunk_model.is_a?(String) && !chunk_model.empty? && chunk_model != @model.id
            @partial.set_response_model(chunk_model)
          end
          @partial.set_usage(Protocol.parse_chunk_usage(chunk["usage"])) if chunk["usage"]

          choice = chunk["choices"].is_a?(Array) ? chunk["choices"][0] : nil
          return events unless choice.is_a?(Hash)

          # Moonshot fallback: usage on choice.usage (pi :582-585).
          if !chunk["usage"] && choice["usage"]
            @partial.set_usage(Protocol.parse_chunk_usage(choice["usage"]))
          end

          if choice["finish_reason"] # §10.3 / pi :587-597
            @stop_reason, @error_message = Protocol.map_stop_reason(choice["finish_reason"])
            @has_finish_reason = true
          end

          delta = choice["delta"]
          events.concat(consume_delta(delta)) if delta.is_a?(Hash)
          events
        end

        # §10.5: finalize blocks in content order (pi finishBlock loop
        # :679-687), then resolve the terminal discipline. Returns
        # [events, outcome] where outcome = [:done, reason] or
        # [:stream_error, message].
        def finish
          events = finalize_blocks

          if !@has_finish_reason && !@dialect.supports_finish_reason
            # Infer from content (pi :690-692).
            @stop_reason = @partial.content.any? { |block| block[:type] == :tool_call } ? :tool_use : :stop
          end
          if @stop_reason == :error
            return events, [:stream_error, @error_message || "Provider returned an error stop reason"]
          end
          if (@dialect.supports_finish_reason && !@has_finish_reason) || @stop_reason.nil?
            return events, [:stream_error, "Stream ended without finish_reason"]
          end
          [events, [:done, @stop_reason]]
        end

        private

        def consume_delta(delta)
          events = []
          if delta["content"].is_a?(String) && !delta["content"].empty?
            block = ensure_text_block(events)
            block[:text] = block[:text] + delta["content"]
            events << Event.new(type: :text_delta, content_index: content_index(block),
              delta: delta["content"], partial: @partial)
          end

          # FIRST non-empty of reasoning_content/reasoning/reasoning_text
          # (pi :616-641); the FIELD NAME is the block signature.
          field = %w[reasoning_content reasoning reasoning_text].find do |name|
            delta[name].is_a?(String) && !delta[name].empty?
          end
          if field
            block = ensure_thinking_block(events, field)
            block[:thinking] = block[:thinking] + delta[field]
            events << Event.new(type: :thinking_delta, content_index: content_index(block),
              delta: delta[field], partial: @partial)
          end

          if delta["tool_calls"].is_a?(Array)
            delta["tool_calls"].each { |entry| events.concat(consume_tool_call(entry)) }
          end

          # reasoning_details deltas (pi :664-677): validated entries
          # accumulate; serialized into the signature at finalize.
          if delta["reasoning_details"].is_a?(Array)
            delta["reasoning_details"].each do |detail|
              next unless Codec.valid_reasoning_detail?(detail)

              ensure_thinking_block(events, "")
              @streamed_details ||= []
              Codec.append_reasoning_detail(@streamed_details, detail)
            end
          end
          events
        end

        def consume_tool_call(entry)
          events = []
          entry = {} unless entry.is_a?(Hash)
          index = entry["index"].is_a?(Integer) ? entry["index"] : nil
          name = entry.dig("function", "name") || ""

          block = index && @tool_by_index[index]
          block ||= @tool_by_id[entry["id"]] if entry["id"]
          unless block
            block = {type: :tool_call, id: entry["id"] || "", name: name, arguments: {}}
            @tool_by_id[block[:id]] = block unless block[:id].empty?
            @partial.append_block(block)
            events << Event.new(type: :tool_call_start, content_index: content_index(block), partial: @partial)
          end
          if block[:id].empty? && entry["id"] # id backfill (pi :666-668)
            block[:id] = entry["id"]
            @tool_by_id[block[:id]] = block
          end
          block[:name] = name if block[:name].empty? && !name.empty?
          # Index-map backfill (I62, pi :536-539): a fragment that resolved
          # its block — by index, by id, or by creation — while CARRYING an
          # index the block has never bound, binds it here. FIRST index
          # wins; one index per block, ever. Boundness is tracked
          # accumulator-side (identity-keyed, like @args_streamers): the
          # blocks ARE message content — no scratch keys on them.
          @tool_index_bound ||= {}.compare_by_identity
          if index && !@tool_index_bound.key?(block)
            @tool_by_index[index] = block
            @tool_index_bound[block] = true
          end

          raw = entry.dig("function", "arguments")
          raw = "" unless raw.is_a?(String)
          # I02 (0.5.0): the incremental args machine. The old seam — a
          # full-buffer copy plus an eager whole-scratch re-parse per delta
          # — is gone. This is a DELIBERATE departure from pi, which
          # re-parses per delta (openai-completions.ts :652-658): the
          # streamer carries parser state across deltas, walks ONLY the
          # new fragment's bytes, and grows the live view in place (the
          # block's arguments Hash); the one authoritative whole-buffer
          # parse still happens at finalize (finalize_blocks below).
          (@args_streamers[block] ||= ArgsStreamer.new(block[:arguments])).consume(raw)
          events << Event.new(type: :tool_call_delta, content_index: content_index(block),
            delta: raw, partial: @partial)
          events
        end

        def finalize_blocks
          events = []
          @partial.content.each do |block|
            index = content_index(block)
            case block[:type]
            when :text
              events << Event.new(type: :text_end, content_index: index, content: block[:text], partial: @partial)
            when :thinking
              # Replay metadata serialized ONCE at finalize (pi :436-443).
              block[:signature] = JSON.generate(@streamed_details) if @streamed_details
              events << Event.new(type: :thinking_end, content_index: index, content: block[:thinking], partial: @partial)
            when :tool_call
              streamer = @args_streamers.delete(block)
              raw = streamer ? streamer.scratch : "" # no-fragment blocks finalize an empty scratch
              # Finalize is the SOLE authority (L9): one whole-buffer parse
              # of the raw bytes — the JSON.parse fast path when the stream
              # completed, the repair walk + {} last resort otherwise
              # (pi :453 / utils/json-parse.ts :20-90). The live Hash the
              # machine grew is replaced here, exactly once.
              block[:arguments] = Protocol.parse_streaming_json(raw)
              events << Event.new(type: :tool_call_end, content_index: index,
                tool_call: {id: block[:id], name: block[:name], arguments: block[:arguments]},
                partial: @partial)
            end
          end
          events
        end

        # pi ensureTextBlock/ensureThinkingBlock (:518-533): creating the
        # block pushes its *_start event (§3: content_index present on
        # block events).
        def ensure_text_block(events)
          unless @text_block
            @text_block = {type: :text, text: ""}
            @partial.append_block(@text_block)
            events << Event.new(type: :text_start, content_index: content_index(@text_block), partial: @partial)
          end
          @text_block
        end

        def ensure_thinking_block(events, signature)
          unless @thinking_block
            @thinking_block = {type: :thinking, thinking: "", signature: signature}
            @partial.append_block(@thinking_block)
            events << Event.new(type: :thinking_start, content_index: content_index(@thinking_block), partial: @partial)
          end
          @thinking_block
        end

        # Identity scan — pi blocks.indexOf (content_index is positional).
        def content_index(block)
          @partial.content.index { |candidate| candidate.equal?(block) }
        end
      end
    end
  end
end
