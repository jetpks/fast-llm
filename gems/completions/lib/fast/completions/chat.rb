# frozen_string_literal: true

require "json"

module Fast
  module Completions
    # The agent turn (Specification §12): build → stream → yield events →
    # on :tool_use execute the tool batch SERIALLY on the calling fiber
    # (D9), append results, return the final assistant Message. Hooks
    # dispatch IN REGISTRATION ORDER; attribution is BY tool_call id —
    # no Thread/fiber-local pairing anywhere (the I49 discipline).
    class Chat
      def initialize(client:, model:)
        @client = client
        @model = model
        @instructions = nil
        @messages = []
        @tools = []
        @thinking_level = nil
        @max_output_tokens = nil
        @before_tool_hooks = []
        @after_tool_hooks = []
        @cancelled = false
        @tool_batch_pending = false
        @in_flight = nil
      end

      # Chainable history configuration. with_instructions replaces (may
      # be called once — later call replaces, §3).
      def with_instructions(text)
        @instructions = text
        self
      end

      # Additive; Tool classes or instances.
      def with_tools(*tools)
        @tools.concat(tools.map { |tool| tool.is_a?(Class) ? tool.new : tool })
        self
      end

      # The gem never mutates a consumer message (§12).
      def add_message(message)
        @messages << message
        self
      end

      def messages
        @messages.dup
      end

      # The ladder + nil (nil = off-equivalent: no effort); clamped at
      # request build (§9.3).
      def thinking_level=(level)
        @thinking_level = level
      end

      def with_thinking_level(level)
        @thinking_level = level
        self
      end

      def with_max_output_tokens(tokens)
        @max_output_tokens = tokens
        self
      end

      # Multiple blocks register; dispatch in registration order (§12).
      def before_tool_call(&block)
        @before_tool_hooks << block
        self
      end

      def after_tool_result(&block)
        @after_tool_hooks << block
        self
      end

      # True when the last turn ended with no pending tool batch (§12).
      def complete?
        !@tool_batch_pending
      end

      # Cancel the in-flight stream: latch + Async::Cancel into the task
      # running #step. The stream aborts, CancelledError surfaces, and NO
      # phantom terminal event is emitted (AC3/D8). Cancelling from the
      # step task ITSELF (inside a hook/tool execution) sets the latch
      # only — a self-cancelled async task would swallow the unwinding;
      # the batch checkpoints below honor the latch instead.
      def cancel
        @cancelled = true
        current = (Async::Task.current rescue nil)
        @in_flight&.cancel unless current&.equal?(@in_flight)
        nil
      end

      # One assistant turn + tool execution (§12). Returns the final
      # assistant Message.
      def step(&block)
        raise CancelledError, "chat cancelled" if @cancelled
        Cancellation.check # D8 checkpoint at stream start
        @in_flight = Async::Task.current
        reason = nil
        final = @client.stream(
          model: @model, messages: @messages, instructions: @instructions,
          tools: @tools, thinking: @thinking_level, max_tokens: @max_output_tokens,
        ) do |event|
          reason = event.reason if event.type == :done
          block&.call(event)
        end
        @in_flight = nil

        add_message(final) # the Chat's own output (stamped by the accumulator, §12)
        if reason == :tool_use
          @tool_batch_pending = true
          run_tool_batch(final)
        else
          @tool_batch_pending = false
        end
        final
      rescue Async::Cancel
        # A cancel landing between awaits (inside hooks/tool execution —
        # async raises Async::Cancel synchronously on self-cancel):
        # surface the gem's CancelledError (D8).
        raise CancelledError, "chat cancelled"
      end

      private

      # Serial execution on the calling fiber (D9): per tool call —
      # cancellation checkpoint, before hooks, execute, after hooks,
      # append the tool_result Message.
      def run_tool_batch(final)
        final.content.each do |block|
          next unless block.is_a?(Hash) && block[:type] == :tool_call

          # D8 checkpoint: the async task AND the cancel latch (a cancel
          # from inside a hook/tool cannot task-cancel itself, §12).
          raise CancelledError, "chat cancelled" if @cancelled

          tool_call = {id: block[:id], name: block[:name], arguments: block[:arguments]}
          Cancellation.check # D8: checkpoint before EACH execution
          @before_tool_hooks.each { |hook| hook.call(tool_call) }
          result = Message.tool_result(
            tool_call_id: tool_call[:id], tool_name: tool_call[:name],
            **execute_tool_call(tool_call),
          )
          @after_tool_hooks.each { |hook| hook.call(tool_call, result) }
          add_message(result)
        end
      end

      # §11: String → content; Hash → JSON.generate; {error:} → is_error.
      # The block's arguments stay string-keyed (provider JSON bytes); the
      # execute splash symbolizes without mutating the history block.
      def execute_tool_call(tool_call)
        tool = @tools.find { |candidate| candidate.name == tool_call[:name] }
        return {content: "no such tool: #{tool_call[:name]}", is_error: true} unless tool

        outcome = tool.execute(**symbolize_keys(tool_call[:arguments]))
        if outcome.is_a?(Hash) && outcome.keys == [:error]
          {content: outcome[:error].to_s, is_error: true}
        elsif outcome.is_a?(Hash)
          {content: JSON.generate(outcome), is_error: false}
        else
          {content: outcome.to_s, is_error: false}
        end
      end

      def symbolize_keys(hash)
        hash.each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
      end
    end
  end
end
