# frozen_string_literal: true

require "json"
require "async"
require "async/http"

module Fast
  module Completions
    # ONE persistent Async::HTTP::Client per instance, fiber-native: every
    # request runs INSIDE the caller's reactor — the client never creates
    # its own (§6).
    class Client
      DEFAULT_TIMEOUT = 30
      # Bounded creation retry (I62, Grounds R2): ONE retry (two attempts)
      # by default so a transient 429/5xx/connection refusal no longer
      # kills the turn; `max_retries: 0` restores the single attempt.
      DEFAULT_MAX_RETRIES = 1

      # TTFB deadline + inactivity read-timeout watchdog (D5/OQ-1): one
      # value serves both. A fire cancels the waiting task; `fired` tells
      # the cancel apart from a user's (D8).
      class Watchdog
        def initialize(task, seconds)
          @task = task
          @seconds = seconds
          @timer = nil
          @fired = false
        end

        attr_reader :fired

        # (Re)arm: TTFB deadline before the POST, re-armed as the
        # inactivity read-timeout after every body chunk. The fired flag
        # resets with the timer: a retried attempt (I62) must not inherit
        # the previous attempt's fire, or the post-stream guard and the
        # cancel-vs-fired discipline would misread attempt 2 (D5/D8).
        def arm
          stop
          @fired = false
          @timer = Async do
            sleep @seconds
            @fired = true
            @task.cancel
          end
        end

        def stop
          @timer&.stop
          @timer = nil
        end
      end

      NETWORK_ERRORS = [
        Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE, Errno::EHOSTUNREACH,
        Errno::ENETUNREACH, Errno::ETIMEDOUT, EOFError, IOError, SocketError,
      ].freeze

      # The five Telemetry::Sink hooks a registered sink must respond to
      # (I01). Checked ONCE at construction — the only sanctioned
      # respond_to? use; notification-time dispatch never reflects.
      TELEMETRY_HOOKS = %i[
        on_completion_start on_completion_ttfb on_event on_completion_end on_completion_error
      ].freeze

      attr_reader :timeout, :max_retries, :dropped_chunks

      def initialize(base_url:, api_key:, timeout: DEFAULT_TIMEOUT, max_retries: DEFAULT_MAX_RETRIES,
        telemetry: [])
        raise ArgumentError, "max_retries must be an Integer >= 0" unless max_retries.is_a?(Integer) && max_retries >= 0
        unless telemetry.is_a?(Array)
          raise ArgumentError, "telemetry must be an Array of sink objects, got #{telemetry.class}"
        end

        telemetry.each do |sink|
          missing = TELEMETRY_HOOKS.reject { |hook| sink.respond_to?(hook) }
          next if missing.empty?

          raise ArgumentError,
            "telemetry sink #{sink.inspect} does not respond to #{missing.join(", ")} (Telemetry::Sink hooks)"
        end

        @endpoint = Async::HTTP::Endpoint.parse(base_url)
        @api_key = api_key
        @timeout = timeout
        @max_retries = max_retries
        @client = Async::HTTP::Client.new(@endpoint)
        @path = @endpoint.path.chomp("/") + "/chat/completions"
        # I01: the client's own frozen copy (the caller's array is never
        # frozen or mutated) + the precomputed emptiness check every
        # call site short-circuits on — zero allocation, zero added
        # clock reads when no sink is registered.
        @telemetry = telemetry.dup.freeze
        @telemetry_active = !@telemetry.empty?
      end

      def close
        @client.close
        nil
      end

      # POST {base}/chat/completions, stream the SSE reply, yield every
      # Event to the block, return the final assistant Message (the
      # accumulator itself — §3). Runs inside the caller's task.
      #
      # Failure discipline (I62): EVERY failure raises AFTER the one
      # `:error` terminal event — a streaming-phase failure carries the
      # salvaged partial (pi :707-728 catch-all), a creation-phase
      # failure an empty accumulator (:start is never emitted for a
      # failed creation) — except cancellation, which keeps its
      # no-terminal-event discipline (D8), and the watchdog's read
      # inactivity, reached as Async::Cancel through the same untouched
      # ladder. The rescue order is load-bearing: Async::Cancel first
      # (cancel never salvages, never retries), then the network family,
      # then the StandardError catch-all.
      def stream(model:, messages:, instructions: nil, tools: [], thinking: nil,
        max_tokens: nil, temperature: nil, session_id: nil, &block)
        request = Protocol.build_request(
          model: model, messages: messages, instructions: instructions,
          tools: tools, thinking: thinking, max_tokens: max_tokens,
          temperature: temperature,
        )
        headers = default_headers.merge(session_headers(model.dialect, session_id))
        body = JSON.generate(request)
        accumulator = Protocol::StreamAccumulator.new(model, model.dialect)
        started_at = notify_start(model.id, body.bytesize) # I01 §1: the completion clock, nil without sinks
        watchdog = Watchdog.new(Async::Task.current, @timeout)
        response = nil
        post_started_at = nil # the committed attempt's POST clock (I01 §2), set by create_response's yield
        begin
          response = create_response(headers, body, watchdog) { |t0| post_started_at = t0 }
          if block || @telemetry_active # :start even blockless (I01 §4); a consumer raise flies to the ladder
            dispatch_event(accumulator.start_event, &block)
          end
          feed_stream(response, accumulator, watchdog, post_started_at, &block)
        rescue Async::Cancel
          if watchdog.fired # I01 §7: fired → timeout, else user cancel (D8); cancel never salvages (AC3)
            notify_error(:timeout_error, started_at)
            raise(TimeoutError, "no data within #{@timeout}s")
          end
          notify_error(:cancelled_error, started_at)
          raise(CancelledError, "stream cancelled")
        rescue *NETWORK_ERRORS => e
          salvage(accumulator, started_at, &block) # the :error terminal carries the partial BEFORE the raise (§1)
          notify_error(:connection_error, started_at) # I01 §7: the symbol of the ConnectionError about to raise
          raise ConnectionError, "#{e.class}: #{e.message}"
        rescue StandardError => e
          salvage(accumulator, started_at, &block) # pi's catch-all: same terminal, raised unchanged
          notify_error(telemetry_symbol_for(e), started_at) # I01 §7: derived from the re-raised class
          raise
        ensure
          finish_quietly(response) # nil-safe: no response yet, or an aborted read (AC3/D8)
          watchdog.stop
        end
        if watchdog.fired # I01 §7: the post-ensure watchdog raise
          notify_error(:timeout_error, started_at)
          raise TimeoutError, "no data within #{@timeout}s"
        end
        deliver_terminal(accumulator, started_at, &block)
      end

      private

      def default_headers
        {
          "authorization" => "Bearer #{@api_key}",
          "content-type" => "application/json",
          "accept" => "application/json",
        }
      end

      # Session-affinity headers per dialect when a session id is supplied
      # (§6; pi openai-completions.ts :776-789, compat-schema.ts :4-9).
      def session_headers(dialect, session_id)
        return {} unless dialect.send_session_affinity_headers && session_id

        case dialect.session_affinity_format
        when :openrouter
          {"x-session-id" => session_id}
        when :openai_nosession
          {"x-client-request-id" => session_id, "x-session-affinity" => session_id}
        else # :openai
          {"session_id" => session_id, "x-client-request-id" => session_id, "x-session-affinity" => session_id}
        end
      end

      # The wire read (§3): SSE parse → accumulator → dispatch. TTFB
      # fires at the FIRST parser-yielded item of the SUCCESSFUL attempt
      # (I01 §3 — a `[DONE]` sentinel counts; comments and keepalives
      # never yield items, sse.rb drops them structurally), measured
      # from that attempt's POST (post_started_at, threaded in from
      # create_response; a retried attempt's clock restarts), at most
      # once per completion. Consumer raises here fly to stream's
      # ladder, which closes the record after salvage.
      def feed_stream(response, accumulator, watchdog, post_started_at, &block)
        parser = SSE.new
        @dropped_chunks = 0
        ttfb_fired = false
        response.body.each do |chunk|
          watchdog.arm # re-arm the inactivity read-timeout per chunk (D5)
          parser.push(chunk).each do |item|
            if @telemetry_active && !ttfb_fired # before this item's dispatches; a flonum difference — no heap
              ttfb_fired = true
              notify_ttfb(Process.clock_gettime(Process::CLOCK_MONOTONIC) - post_started_at)
            end
            next if item == SSE::DONE # terminal token; no payload

            json = parse_chunk(item)
            next if json.nil? # dropped (I61): counted, the stream continues

            accumulator.consume(json).each { |event| dispatch_event(event, &block) }
          end
        end
      end

      # The chunk seam (I61): parse, on failure ONE repair pass (pi
      # parseJsonWithRepair — raw control characters inside strings
      # escaped) and re-parse. StreamError no longer originates from
      # chunk parsing; §10.5's missing-finish path still covers a dropped
      # finish-carrying chunk.
      def parse_chunk(item)
        JSON.parse(item)
      rescue JSON::ParserError
        parse_repaired(item)
      end

      # The repair re-parse (its own method: a rescue body's exception
      # needs its own rescue). A payload repair cannot fix is DROPPED —
      # counted, never raised; the stream continues (I61).
      def parse_repaired(item)
        JSON.parse(Protocol.repair_json(item))
      rescue JSON::ParserError
        @dropped_chunks += 1
        nil
      end

      # Finalize blocks, then the terminal discipline (§10.5): an error
      # stop and a missing finish both emit :error FIRST, then raise
      # StreamError; otherwise :done with the mapped reason. Cancel never
      # reaches here — it unwinds mid-read with NO terminal event (AC3).
      # I01 §5: every terminal dispatch reaches the sinks (blockless
      # included), on_completion_error rides the StreamError raise, and
      # on_completion_end fires after the :done dispatches. The terminal
      # Events are built only under the observer guard (zero-path
      # discipline); every yield below is a ladder-UNCOVERED site — this
      # method runs AFTER the ladder — so dispatch_event closes the
      # record on a consumer raise here (see dispatch_event).
      def deliver_terminal(accumulator, started_at, &block)
        events, outcome = accumulator.finish
        if block || @telemetry_active
          events.each { |event| dispatch_event(event, started_at, closing: true, &block) }
          if outcome[0] == :stream_error
            dispatch_event(Event.new(type: :error, reason: :error, message: accumulator.partial),
              started_at, closing: true, &block)
            notify_error(:stream_error, started_at) # the symbol of the StreamError about to raise
          else
            dispatch_event(Event.new(type: :done, reason: outcome[1], message: accumulator.partial),
              started_at, closing: true, &block)
            notify_end(outcome[1], accumulator.partial, started_at) # after the :done dispatches, before the return
          end
        end
        raise StreamError.new(outcome[1], stop_reason: :error) if outcome[0] == :stream_error

        accumulator.partial
      end

      # The bounded creation retry (I62 §2, pi retryProviderRequest around
      # chat.completions.create — the attempt is creation through status
      # receipt, structurally pre-first-body-byte, Grounds R4). At most
      # @max_retries immediate retries, exactly on pi's trigger set
      # (provider-retry.ts :25-38): header x-should-retry true (any
      # status) / false (FINAL, even on a retryable status), statusless
      # errors (NETWORK_ERRORS at the POST, a TTFB watchdog fire),
      # statuses 408/409/429/5xx. NEVER after a 2xx — the attempt is
      # committed to streaming and any later failure is §1 salvage, never
      # a retry. Cancellation is not a failure and is never retried. Each
      # final failure raises its mapped error; stream's ladder adds the
      # :error terminal before it (the accumulator is still empty — no
      # :start was emitted).
      def create_response(headers, body, watchdog)
        remaining = @max_retries
        loop do
          watchdog.arm # re-armed per attempt: a retried TTFB deadline restarts (D5)
          t0 = @telemetry_active ? Process.clock_gettime(Process::CLOCK_MONOTONIC) : nil # I01 §2, guarded (gate 3)
          begin
            response = @client.post(@path, headers: headers, body: body)
          rescue Async::Cancel
            raise unless watchdog.fired # the user's cancel is not a failure — never retried (D8)
            raise TimeoutError, "no data within #{@timeout}s" if remaining.zero?
            remaining -= 1
            next
          rescue *NETWORK_ERRORS => e
            raise ConnectionError, "#{e.class}: #{e.message}" if remaining.zero? # statusless trigger
            remaining -= 1
            next
          end
          if (200...300).cover?(response.status) # committed to streaming: never retried past a 2xx
            yield(t0) if block_given? # the committed attempt's POST clock → stream's TTFB local (allocation-free)
            return response
          end

          if retry_response?(response) && remaining.positive?
            finish_quietly(response) # the discarded attempt's connection returns to the pool
            remaining -= 1
            next
          end
          raise_api_error(response) # final non-2xx: the §8 mapping, reached only after the retry decision
        end
      end

      # pi provider-retry.ts :26-34, exact: the header beats the status
      # both ways (strict "true"/"false"); then 408/409/429/5xx; every
      # other status is final.
      def retry_response?(response)
        flag = retry_header(response.headers)
        return true if flag == "true"
        return false if flag == "false"

        [408, 409, 429].include?(response.status) || (500..599).cover?(response.status)
      end

      # Header NAMES arrive in wire case (HTTP/1); Protocol::HTTP::Headers
      # collects repeated fields into arrays — scan case-insensitively and
      # unwrap, pi headers.get("x-should-retry") shape.
      def retry_header(headers)
        headers.each do |key, value|
          return Array(value).first if key.to_s.downcase == "x-should-retry"
        end
        nil
      end

      # The salvage arm (pi openai-completions.ts :707-728 catch-all): a
      # streaming-phase failure yields the ONE error-terminal event FIRST
      # — the live partial (every streamed block + usage so far) — with NO
      # block-end events after the failure; the rescue ladder raises
      # after. pi's catch applies the same scratch finalization to the
      # partial (applyStreamedReasoningDetails): `finish` runs
      # finalize_blocks — the thinking reasoning_details serialized into
      # the signature, tool arguments finalized — whose end events we
      # discard here, so a salvaged partial replays like a completed one's.
      # The yield below runs INSIDE a rescue arm — ladder-uncovered — so
      # dispatch_event closes the record on a consumer raise; the early
      # return keeps the blockless-no-sink path byte-identical (I01 §6).
      def salvage(accumulator, started_at, &block)
        return unless block_given? || @telemetry_active # the blockless-no-sink early return (I01 §6)

        accumulator.finish
        dispatch_event(Event.new(type: :error, reason: :error, message: accumulator.partial),
          started_at, closing: true, &block)
      end

      # Complete bodies return the connection to the pool; an aborted read
      # (cancel/timeout) discards it — a cancelled connection is never
      # reused (AC3/D8). Serves the discarded retry attempt and stream's
      # ensure; nil-safe (no response yet → the rescue swallows the
      # NoMethodError exactly as the inline form did).
      def finish_quietly(response)
        response.finish
      rescue StandardError, Async::Cancel
        nil
      end

      # Non-2xx: read the body, map per §8. Now reached only after the
      # retry decision (I62) — stream's ladder yields the :error terminal
      # before this raise.
      def raise_api_error(response)
        body = response.body.read
        raise Errors.class_for_status(response.status, body).new(status: response.status, body: body)
      end

      # ── I01 telemetry dispatch ─────────────────────────────────────
      # Every helper short-circuits on the precomputed emptiness check
      # BEFORE any clock read or dispatch: with no sink registered the
      # call sites cost one no-op method call, zero allocations, zero
      # Process.clock_gettime reads. Per-completion state (the
      # completion-start clock, the per-attempt POST clock, the
      # ttfb-once flag) is threaded as locals/args, never Client ivars
      # (I03); durations are flonum differences; dispatch is in
      # registration order; the loop block itself is never materialized,
      # so a no-op sink adds zero heap objects (gate 2).

      # The ONE event dispatch seam: sinks first, consumer second (I01
      # §4/§5 — telemetry is the ground-truth record). `closing:` marks
      # yield sites the rescue ladder does NOT cover — deliver_terminal
      # runs after it, salvage inside a rescue arm — where a consumer
      # raise closes the record here (the raiser's symbol) before the
      # unchanged, backtrace-preserving re-raise; on StandardError only,
      # the ladder's own catch scope, so cancel and Exception-class
      # raises keep today's escape semantics. At the ladder-covered
      # sites the StandardError arm does the closing (after salvage) —
      # closing here too would double-fire the record. Dispatch is
      # implicit yield/block_given? (no captured &block of its own — no
      # Proc materialization, gate 2); callers forward their
      # already-captured Proc at the call site, which is free.
      def dispatch_event(event, started_at = nil, closing: false)
        return unless block_given? || @telemetry_active

        notify_event(event)
        if closing
          begin
            yield event if block_given?
          rescue StandardError => e
            notify_error(telemetry_symbol_for(e), started_at)
            raise
          end
        else
          yield event if block_given?
        end
      end

      # I01 §1: the completion clock (every duration below differs from
      # it) + on_completion_start, before the first POST of the first
      # attempt. Returns the clock — nil without a sink, zero added
      # clock reads (gate 3).
      def notify_start(model_id, request_bytes)
        return nil unless @telemetry_active

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @telemetry.each { |sink| sink.on_completion_start(model_id, request_bytes) }
        started_at
      end

      def notify_ttfb(elapsed)
        return unless @telemetry_active

        @telemetry.each { |sink| sink.on_completion_ttfb(elapsed) }
      end

      def notify_event(event)
        return unless @telemetry_active

        @telemetry.each { |sink| sink.on_event(event) }
      end

      def notify_end(stop_reason, message, started_at)
        return unless @telemetry_active

        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        @telemetry.each { |sink| sink.on_completion_end(stop_reason, duration, message) }
      end

      def notify_error(error, started_at)
        return unless @telemetry_active

        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        @telemetry.each { |sink| sink.on_completion_error(error, duration) }
      end

      # The re-raise arm's error Symbol: derived from the raising class —
      # demodulized, underscored (RateLimitError → :rate_limit_error,
      # RuntimeError → :runtime_error). Computed only on the raise path,
      # under the active guard; an anonymous class has no name.
      def telemetry_symbol_for(error)
        name = error.class.name
        return :anonymous_error if name.nil?

        name.split("::").last
          .gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase.to_sym
      end
    end
  end
end
