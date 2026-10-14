# frozen_string_literal: true

module Fast
  module Completions
    # Replay normalization + message conversion (Specification §9.4–§9.5;
    # pi utils/transform-messages.ts + api/openai-completions.ts
    # convertMessages :1300-1402).
    #
    # Codec.normalize ports transformMessages (thinking folding, redacted
    # rules, orphaned tool-call synthetics, system hold-back). Codec
    # .to_wire_messages ports convertMessages (the wire shapes). The two
    # passes mirror pi's split: stream() resolves the transcript, then
    # convertMessages shapes it.
    module Codec
      # pi OPENAI_COMPLETIONS_REASONING_FIELDS openai-completions.ts :273.
      REASONING_FIELDS = %w[reasoning reasoning_content reasoning_text].freeze

      module_function

      # ── Pass 1: transform-messages.ts ──────────────────────────────

      def normalize(messages, model)
        transformed = messages.map { |msg| transform_message(msg, model) }
        insert_orphan_synthetic_results(transformed)
      end

      # First pass (transform-messages.ts :80-130). Same-model is the
      # three-way identity reduced to (provider, model) — the gem has no
      # provider registry; the comparison is consumer-controlled
      # (Specification §12.3 note; pi :97-99).
      def transform_message(msg, model)
        return msg unless msg.assistant?

        same_model = msg.provider == model.provider && msg.model == model.id
        content = msg.content.flat_map do |block|
          case block[:type]
          when :thinking
            normalize_thinking_block(block, same_model)
          when :text
            # Same or cross: text stays text (pi :119-123).
            {type: :text, text: block[:text]}
          else
            # tool_call: pi strips the thoughtSignature cross-model and
            # keeps it same-model (:124-134). The gem's tool_call block
            # hash may carry :signature — the openai wire never emits it,
            # so the strip/keep is a no-op at the wire layer.
            block
          end
        end
        Message.new(role: :assistant, content: content, provider: msg.provider,
          model: msg.model, api: msg.api, usage: msg.usage)
      end

      # Thinking-block rules (transform-messages.ts :103-118):
      # redacted → same-model keep, cross-model drop; same-model keeps
      # blocks WITH signatures even when the text is empty (OpenAI
      # encrypted reasoning); empty/whitespace text drops; cross-model
      # non-empty folds to a text block.
      def normalize_thinking_block(block, same_model)
        if block[:redacted]
          return same_model ? [block] : []
        end
        return [block] if same_model && block[:signature]
        return [] if block[:thinking].nil? || block[:thinking].strip.empty?
        return [block] if same_model

        [{type: :text, text: block[:thinking]}]
      end

      # Second pass (transform-messages.ts :143-201): synthetic results
      # for orphaned tool calls; system messages landing between a call
      # and its results are held back and emitted after them (:166-169).
      def insert_orphan_synthetic_results(messages)
        result = []
        pending_tool_calls = []
        satisfied_ids = []
        held_system_messages = []

        close_pending = lambda do
          if pending_tool_calls.any?
            pending_tool_calls.each do |tc|
              next if satisfied_ids.include?(tc[:id])

              result << Message.tool_result(
                tool_call_id: tc[:id], tool_name: tc[:name],
                content: "No result provided", is_error: true,
              )
            end
            pending_tool_calls = []
            satisfied_ids = []
          end
          result.concat(held_system_messages)
          held_system_messages = []
        end

        messages.each do |msg|
          if msg.assistant?
            close_pending.call
            calls = msg.content.select { |b| b[:type] == :tool_call }
            unless calls.empty?
              pending_tool_calls = calls
              satisfied_ids = []
            end
            result << msg
          elsif msg.tool_result?
            satisfied_ids << msg.tool_call_id
            result << msg
          elsif msg.system?
            if pending_tool_calls.any?
              held_system_messages << msg
            else
              result << msg
            end
          else # user
            close_pending.call
            result << msg
          end
        end
        close_pending.call
        result
      end

      # ── Pass 2: convertMessages (openai-completions.ts :1293-1465) ──

      # instructions is the ONE leading system/developer message (§9.1,
      # pi :1233): role "developer" iff model.reasoning AND
      # dialect.supports_developer_role, else "system".
      def to_wire_messages(instructions, messages, model, dialect)
        instruction_role = model.reasoning && dialect.supports_developer_role ? "developer" : "system"
        params = []
        params << {role: instruction_role, content: instructions} if instructions && !instructions.empty?

        messages.each do |msg|
          case msg.role
          when :system
            next if msg.content.to_s.empty?

            params << {role: instruction_role, content: msg.content}
          when :user
            wire_user(params, msg)
          when :assistant
            wire_assistant(params, msg, model, dialect)
          when :tool_result
            wire_tool_result(params, msg)
          end
        end
        params
      end

      # User: a String passes verbatim (fixture fact); a block array
      # passes as text parts (non-empty text only — images cut, D7);
      # all-empty blocks skip the message (pi :1319-1342).
      def wire_user(params, msg)
        if msg.content.is_a?(String)
          params << {role: "user", content: msg.content}
          return
        end

        parts = msg.content
          .select { |block| block[:type] == :text && !block[:text].to_s.empty? }
          .map { |block| {type: "text", text: block[:text]} }
        return if parts.empty?

        params << {role: "user", content: parts}
      end

      # Tool result (§9.1, pi :1404-1427): {role: "tool", content: joined,
      # tool_call_id:}; empty → "(no tool output)"; NO name key
      # (requires_tool_result_name unported, §14).
      def wire_tool_result(params, msg)
        text = text_block_texts(msg.content).join("\n")
        text = "(no tool output)" if text.empty?
        params << {role: "tool", content: text, tool_call_id: msg.tool_call_id}
      end

      # Assistant replay (§9.4, pi :1348-1402). Wire key order is pi's
      # insertion order: role, content, [reasoning field], [tool_calls],
      # [reasoning_details], [deepseek reasoning_content:""].
      def wire_assistant(params, msg, model, dialect)
        assistant = {role: "assistant", content: nil}
        text = text_block_texts(msg.content, non_whitespace: true).join("")
        thinking_blocks = msg.content.select { |b| b[:type] == :thinking }
        tool_calls = msg.content.select { |b| b[:type] == :tool_call }

        non_empty_thinking = thinking_blocks.reject { |b| b[:thinking].to_s.strip.empty? }
        # pi computes preservedReasoningDetails over ALL thinking blocks
        # (:1313-1316) and emits it independent of the non-empty branch
        # (:1382-1386) — encrypted-only blocks replay too.
        preserved_details = reasoning_details_for(thinking_blocks)
        unless non_empty_thinking.empty?
          if preserved_details.nil?
            field = non_empty_thinking.first[:signature]
            assistant[field] = non_empty_thinking.map { |b| b[:thinking] }.join("\n") if REASONING_FIELDS.include?(field)
          end
        end

        assistant[:content] = text unless text.empty?
        unless tool_calls.empty?
          assistant[:tool_calls] = tool_calls.map do |tc|
            {id: tc[:id], type: "function",
             function: {name: tc[:name], arguments: JSON.generate(tc[:arguments])}}
          end
        end
        assistant["reasoning_details"] = preserved_details if preserved_details
        # deepseek: reasoning_content:"" on every assistant when required
        # and none was emitted (§9.5, pi :1387-1393).
        if dialect.requires_reasoning_content_on_assistant_messages && model.reasoning &&
            !assistant.key?("reasoning_content")
          assistant["reasoning_content"] = ""
        end

        # Skip empty assistants (no text, no tool_calls) — pi :1394-1402.
        # A reasoning-field-only assistant (content null, no tool_calls)
        # is skipped too: pi's skip predicate checks content+tool_calls.
        has_content = assistant[:content].is_a?(String) && !assistant[:content].empty?
        return if !has_content && !assistant[:tool_calls]

        params << assistant
      end

      # §9.5: the FIRST thinking-block signature (over ALL thinking
      # blocks, pi :1313-1316) that parses as a JSON array of valid
      # reasoning_details wins — emit `reasoning_details` and no raw
      # reasoning field.
      def reasoning_details_for(thinking_blocks)
        thinking_blocks.each do |block|
          details = parse_reasoning_details(block[:signature])
          return details if details
        end
        nil
      end

      # pi parseOpenAIReasoningDetails openai-completions.ts :220-228:
      # signature → JSON array (non-empty) of valid detail objects, else
      # nil.
      def parse_reasoning_details(signature)
        return nil if signature.nil? || signature.empty?

        parsed = JSON.parse(signature)
        return nil unless parsed.is_a?(Array) && !parsed.empty?
        return nil unless parsed.all? { |detail| valid_reasoning_detail?(detail) }

        parsed
      rescue JSON::ParserError, TypeError
        nil
      end

      # pi isOpenAIReasoningDetail :135-165.
      def valid_reasoning_detail?(detail)
        return false unless detail.is_a?(Hash)

        id = detail["id"]
        return false unless id.nil? || id.is_a?(String)
        return false unless detail["format"].nil? || detail["format"].is_a?(String)
        return false unless detail["index"].nil? || detail["index"].is_a?(Numeric)

        case detail["type"]
        when "reasoning.summary" then detail["summary"].is_a?(String)
        when "reasoning.encrypted" then detail["data"].is_a?(String)
        when "reasoning.text"
          detail["text"].is_a?(String) &&
            (detail["signature"].nil? || detail["signature"].is_a?(String))
        else false
        end
      end

      # pi appendOpenAIReasoningDetail :240-265 — consecutive text/text
      # and summary/summary entries merge; encrypted entries stay opaque
      # and discrete.
      def append_reasoning_detail(details, detail)
        last = details.last
        case detail["type"]
        when "reasoning.text"
          if last.is_a?(Hash) && last["type"] == "reasoning.text"
            last["text"] = last["text"] + detail["text"]
            last["signature"] ||= detail["signature"]
            fill_missing_common_fields(last, detail)
            return
          end
        when "reasoning.summary"
          if last.is_a?(Hash) && last["type"] == "reasoning.summary"
            last["summary"] = last["summary"] + detail["summary"]
            fill_missing_common_fields(last, detail)
            return
          end
        end
        details << detail.dup
      end

      def fill_missing_common_fields(target, source)
        # JS ??= with an undefined source is a no-op on the wire (JSON
        # drops undefined) — never introduce explicit nulls.
        if target["id"].nil? && !source["id"].nil?
          target["id"] = source["id"]
        end
        if (target["format"].nil? || target["format"].empty?) && !source["format"].nil? # JS ||= (falsy overwrite)
          target["format"] = source["format"]
        end
        if target["index"].nil? && !source["index"].nil?
          target["index"] = source["index"]
        end
      end

      # ── §9.6 estimate ──────────────────────────────────────────────

      # ceil(chars / 3.5) over the message texts (pi CHARS_PER_TOKEN 3.5,
      # utils/estimate.ts :14). Texts = string contents, text/thinking
      # block texts, tool-result content.
      def estimate_tokens(instructions, messages)
        chars = instructions.to_s.length
        messages.each do |msg|
          case msg.content
          when String then chars += msg.content.length
          when Array
            msg.content.each do |block|
              if block.is_a?(Hash) && (block[:type] == :text || block[:type] == :thinking)
                chars += block[:text].to_s.length
              end
            end
          end
        end
        (chars / 3.5).ceil
      end

      module_function

      def text_block_texts(content, non_whitespace: false)
        blocks = content.is_a?(String) ? [{type: :text, text: content}] : content
        blocks.select { |b| b.is_a?(Hash) && b[:type] == :text }
          .map { |b| b[:text].to_s }
          .then { |texts| non_whitespace ? texts.reject { |t| t.strip.empty? } : texts }
      end
    end
  end
end
