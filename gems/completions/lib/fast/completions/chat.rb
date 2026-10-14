# frozen_string_literal: true

require "json"

module Fast
  module Completions
    # The agent turn (Specification §12): build → stream → yield events →
    # on :tool_use execute the tool batch CONCURRENTLY (pi's
    # executeToolCallsParallel shape, tart I52's fiber mechanics) — a
    # serial before-phase, one reactor child per executable call, results
    # appended IN CALL ORDER — and return the final assistant Message.
    # Hooks dispatch IN REGISTRATION ORDER; attribution is BY tool_call
    # id — no Thread/fiber-local pairing anywhere (the I49 discipline).
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

      # Cancel the in-flight turn (stream or tool batch): latch +
      # Async::Cancel into the task running #step. The turn aborts,
      # CancelledError surfaces, and NO phantom terminal event is emitted
      # (AC3/D8). Cancelling from the step task ITSELF (inside a HOOK
      # execution — hooks run on the calling fiber) sets the latch only —
      # a self-cancelled async task would swallow the unwinding; the
      # checkpoints below honor the latch instead. A tool execution runs
      # on a batch child, so a cancel from inside a tool task-cancels the
      # step task: async stops the sibling children and the join
      # re-raises (D5).
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

        add_message(final) # the Chat's own output (stamped by the accumulator, §12)
        if reason == :tool_use
          @tool_batch_pending = true
          run_tool_batch(final)
        else
          @tool_batch_pending = false
        end
        # @in_flight covers the WHOLE turn — stream AND batch: the batch's
        # children hang off this task, so a cancel landing during the
        # batch (sibling-called or tool-called) reaches them via async's
        # stop-children semantics and re-raises from the join (D5).
        @in_flight = nil
        final
      rescue Async::Cancel
        # A cancel landing between awaits (inside hook execution —
        # async raises Async::Cancel synchronously on self-cancel):
        # surface the gem's CancelledError (D8).
        raise CancelledError, "chat cancelled"
      end

      private

      # Two-phase batch executor (§1.1 — pi executeToolCallsParallel's
      # shape). PHASE A, serial on the calling fiber per tool_call block
      # IN CALL ORDER: the D8 checkpoints (latch + Cancellation.check),
      # the before hooks (registration order), then executability
      # resolution — an unknown tool finalizes INLINE with the exact
      # result bytes, NO child task (the immediate arm; before hooks fire
      # for it too — gem continuity over pi's look-up-first). PHASE B:
      # ONE reactor child per executable call (children of the step task
      # — the Sync-inline reactor discipline, tart I52's shape). Results
      # collect INDEX-KEYED (call position) and append IN CALL ORDER
      # after the join — history bytes identical to the serial executor's
      # for every batch (wire-neutral by construction, D7). The join
      # re-raises immediately on cancel — never waits out natural
      # completion — so an aborted batch appends NOTHING and fires NO
      # after hooks (no phantom terminals, D5).
      def run_tool_batch(final)
        results = Array.new(final.content.size)
        executable = [] # ordered specs: [block index, tool_call, tool]

        final.content.each_with_index do |block, index|
          next unless block.is_a?(Hash) && block[:type] == :tool_call

          # D8 checkpoint: the async task AND the cancel latch (a cancel
          # from inside a hook cannot task-cancel itself, §12).
          raise CancelledError, "chat cancelled" if @cancelled

          tool_call = {id: block[:id], name: block[:name], arguments: block[:arguments]}
          Cancellation.check # D8: checkpoint before EACH call's hooks
          @before_tool_hooks.each { |hook| hook.call(tool_call) }
          tool = @tools.find { |candidate| candidate.name == tool_call[:name] }
          unless tool
            # Immediate arm (D3): the unknown-tool outcome, verbatim.
            results[index] = Message.tool_result(
              tool_call_id: tool_call[:id], tool_name: tool_call[:name],
              content: "no such tool: #{tool_call[:name]}", is_error: true)
            next
          end
          executable << [index, tool_call, tool]
        end

        parent = Async::Task.current
        children = executable.map do |index, tool_call, tool|
          parent.async { run_tool_child(tool_call, tool, index, results) }
        end
        begin
          children.map(&:wait) # the join: re-raises immediately on cancel
        ensure
          # The join surfaces WITHOUT waiting out natural completion — but
          # the children would outlive it: #step's ladder converts the
          # join's Async::Cancel into CancelledError (a StandardError), so
          # async's own stop-children transition never runs and the
          # reactor reparents still-running children. Cancel them HERE:
          # no after hooks, no dangling results for aborted calls (D5 —
          # the serial executor's raise-aborts-the-batch semantics). A
          # no-op for children that already finished.
          children.each(&:cancel)
        end

        results.each { |result| add_message(result) if result } # CALL ORDER (D7)
      end

      # ONE batch child (Phase B): the opening D8 checkpoint (a cancel
      # that landed during Phase A or a sibling's execution kills THIS
      # child here — its tool never runs), execute with failure
      # isolation, after hooks INSIDE the child as the call completes
      # (keyed by tool_call id through this closure — never
      # completion-shared state), INDEX-keyed collection.
      def run_tool_child(tool_call, tool, index, results)
        raise CancelledError, "chat cancelled" if @cancelled
        Cancellation.check
        result = execute_tool_result(tool_call, tool)
        @after_tool_hooks.each { |hook| hook.call(tool_call, result) }
        results[index] = result
      end

      # §11 outcome + D4 failure isolation: a StandardError from the
      # tool's own execution becomes THIS call's error result (siblings
      # unaffected, the join completes — pi executePreparedToolCall);
      # CancelledError re-raises (never a result); Async::Cancel passes
      # through (< Exception, not caught here). An ArgumentError
      # re-raises too: Ruby raises it at the DISPATCH boundary — the
      # tool's execute signature cannot accept the provider's arguments
      # (the tool body never ran) — a tool-declaration defect with no pi
      # analog (JS dispatch ignores arity); today's raise-through
      # behavior is kept for it.
      def execute_tool_result(tool_call, tool)
        Message.tool_result(
          tool_call_id: tool_call[:id], tool_name: tool_call[:name],
          **execute_tool_call(tool_call, tool))
      rescue CancelledError
        raise
      rescue ArgumentError
        raise
      rescue StandardError => e
        Message.tool_result(
          tool_call_id: tool_call[:id], tool_name: tool_call[:name],
          content: e.message.to_s, is_error: true)
      end

      # §11: String → content; Hash → JSON.generate; {error:} → is_error.
      # The block's arguments stay string-keyed (provider JSON bytes); the
      # execute splash symbolizes without mutating the history block.
      def execute_tool_call(tool_call, tool)
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
