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
        # The additive seconds parameter (I03) lets one watchdog arm
        # deadlines of different lengths — raw_stream's split phases —
        # while a bare arm keeps the constructor value (stream, unchanged).
        def arm(seconds = @seconds)
          stop
          @fired = false
          @timer = Async do
            sleep seconds
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

      attr_reader :timeout, :max_retries, :dropped_chunks, :ttfb_timeout, :inactivity_timeout

      def initialize(base_url:, api_key: nil, timeout: DEFAULT_TIMEOUT, max_retries: DEFAULT_MAX_RETRIES,
        ttfb_timeout: nil, inactivity_timeout: nil, telemetry: [])
        raise ArgumentError, "max_retries must be an Integer >= 0" unless max_retries.is_a?(Integer) && max_retries >= 0
        validate_deadline!(:ttfb_timeout, ttfb_timeout)
        validate_deadline!(:inactivity_timeout, inactivity_timeout)
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
        @ttfb_timeout = ttfb_timeout
        @inactivity_timeout = inactivity_timeout
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

        # I01 §1: completion start — the completion clock (every duration
        # below is a flonum difference from it) and on_completion_start,
        # before create_response's FIRST POST of the FIRST attempt. The
        # args are existing refs/immediates: the Model#id String ref and
        # the request body's bytesize Integer. Guarded: with no sink,
        # zero clock reads are added (gate 3).
        if @telemetry_active
          @telemetry_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @telemetry_ttfb_fired = false
          @telemetry.each { |sink| sink.on_completion_start(model.id, body.bytesize) }
        end

        watchdog = Watchdog.new(Async::Task.current, @timeout)
        response = nil
        begin
          # The POST attempt — creation through status receipt (§2),
          # bounded-retried on pi's trigger set; every final creation
          # failure raises its mapped error from in there.
          response = create_response(headers, body, watchdog)
          if block || @telemetry_active # I01 §4: sinks see :start even blockless
            start_event = accumulator.start_event
            notify_event(start_event) # the sink first, then its consumer twin
            yield start_event if block
          end
          feed_stream(response, accumulator, watchdog, &block)
        rescue Async::Cancel
          # Cancel never salvages (AC3); I01 §7 closes the record at the
          # raise either way — a fired watchdog is TimeoutError, a user
          # cancel CancelledError (no terminal Event, but the sink's
          # record closes with on_completion_error).
          if watchdog.fired
            notify_error(:timeout_error)
            raise(TimeoutError, "no data within #{@timeout}s")
          end
          notify_error(:cancelled_error)
          raise(CancelledError, "stream cancelled")
        rescue *NETWORK_ERRORS => e
          salvage(accumulator, &block) # the :error terminal carries the partial BEFORE the raise (§1)
          notify_error(:connection_error) # I01 §7: the symbol of the ConnectionError about to raise
          raise ConnectionError, "#{e.class}: #{e.message}"
        rescue StandardError => e
          salvage(accumulator, &block) # pi's catch-all: any other streaming failure — same terminal, raised unchanged
          notify_error(telemetry_symbol_for(e)) # I01 §7: derived from the re-raised class
          raise
        ensure
          # Complete bodies return the connection to the pool; an aborted
          # read (cancel/timeout) discards it — a cancelled connection is
          # never reused (AC3/D8).
          begin
            response.finish
          rescue StandardError, Async::Cancel
            nil
          end
          watchdog.stop
        end
        if watchdog.fired
          notify_error(:timeout_error) # I01 §7: the post-ensure watchdog raise
          raise TimeoutError, "no data within #{@timeout}s"
        end

        deliver_terminal(accumulator, &block)
      end

      # The raw surface a proxy needs (I03, BRIEF §3): the caller's
      # request body forwarded VERBATIM (a String as-is, anything else
      # JSON.generate'd — no merging, no filtering, no stream
      # injection, no Model/dialect involvement, no session-affinity
      # headers), every parsed SSE data payload yielded to the block in
      # arrival order — the SSE::DONE sentinel in its wire position —
      # and nil returned: the block is the only output channel. No
      # Message accumulation, no tool interpretation, no stop-reason
      # mapping, no salvage, no StreamError — a stream that ends without
      # the terminal token simply ends. Exactly ONE POST attempt: no
      # create_response, no retry logic, no x-should-retry consultation;
      # a non-2xx raises the existing §8 mapping (raise_api_error).
      #
      # Watchdog, split by I03: two deadlines. TTFB (status + headers)
      # arms before the POST; from response receipt on the inactivity
      # deadline re-arms after every body chunk (D5). Each resolves per
      # phase — call kwarg > client kwarg > the shared timeout. A fire
      # cancels the waiting task and surfaces the phase-named
      # TimeoutError, never CancelledError (D8); a user cancel surfaces
      # CancelledError. Runs inside the caller's task (§6).
      #
      # I05 revision (operator review of #7 — "the raw_stream method
      # is way too long and not idiomatic ruby"): the method is now
      # short orchestration over three private seams — the request seam
      # (post_raw_body), the each-event seam (each_raw_event), and the
      # cancel translation (raise_raw_cancel). The phase a timeout
      # fires in is derived from the response itself — headers are
      # outstanding exactly until the POST returns — so no phase flag
      # threads through the ladder.
      def raw_stream(body, ttfb_timeout: nil, inactivity_timeout: nil, &block)
        ttfb = resolve_deadline(:ttfb_timeout, ttfb_timeout, @ttfb_timeout)
        idle = resolve_deadline(:inactivity_timeout, inactivity_timeout, @inactivity_timeout)

        watchdog = Watchdog.new(Async::Task.current, ttfb)
        response = nil
        begin
          response = post_raw_body(body, watchdog)
          raise_api_error(response) unless (200...300).cover?(response.status)

          each_raw_event(response, idle, watchdog, &block)
        rescue Async::Cancel
          raise_raw_cancel(watchdog, response, ttfb, idle)
        rescue *NETWORK_ERRORS => e
          raise ConnectionError, "#{e.class}: #{e.message}"
        ensure
          finish_quietly(response)
          watchdog.stop
        end
        nil
      end

      private

      def default_headers
        # Authorization is optional (I03): sent only when a key is
        # present and non-empty — a local engine needs none. With a key
        # the header set is byte-identical to before.
        if @api_key && !@api_key.empty?
          {
            "authorization" => "Bearer #{@api_key}",
            "content-type" => "application/json",
            "accept" => "application/json",
          }
        else
          {"content-type" => "application/json", "accept" => "application/json"}
        end
      end

      # The deadline knobs (I03): nil = unset (resolution falls through
      # to the shared timeout); any explicitly-given value must be a
      # positive Numeric. Applies at the constructor and, via
      # resolve_deadline, to per-call overrides on raw_stream.
      def validate_deadline!(name, value)
        return if value.nil?
        return if value.is_a?(Numeric) && value.positive?

        raise ArgumentError, "#{name} must be a positive Numeric"
      end

      # Per-phase deadline resolution for raw_stream (I03): the call
      # kwarg, else the client's, else the shared timeout. A call kwarg
      # validates even though the client's own did — both are public
      # surfaces. Runs BEFORE any reactor dependency, so a bad knob
      # raises ArgumentError outside a reactor too.
      def resolve_deadline(name, call_value, client_value)
        validate_deadline!(name, call_value) unless call_value.nil?
        call_value || client_value || @timeout
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

      # The raw request seam (I05 revision): resolve the payload (a
      # String verbatim, anything else JSON-generated) and make the ONE
      # POST, the TTFB deadline armed for creation through status
      # receipt. The status check stays with the caller — raw_stream's
      # ensure ladder must see even a non-2xx response to keep the
      # connection-finish discipline (raise_api_error reads the body;
      # finish then returns the connection to the pool).
      def post_raw_body(body, watchdog)
        payload = body.is_a?(String) ? body : JSON.generate(body)
        watchdog.arm
        @client.post(@path, headers: default_headers, body: payload)
      end

      # The raw each-event seam (I05 revision) — a reusable "each
      # event" concern: owns the SSE parser, the per-chunk inactivity
      # re-arm (D5 — the first chunk's arm is the TTFB→inactivity
      # transition), and the I61 drop-and-count reset; yields the DONE
      # sentinel in its wire position and every surviving payload
      # parsed. The block is optional — a blockless call drains.
      def each_raw_event(response, idle, watchdog, &block)
        parser = SSE.new
        @dropped_chunks = 0
        response.body.each do |chunk|
          watchdog.arm(idle) # re-arm the inactivity read-timeout per chunk (D5)
          parser.push(chunk).each do |item|
            if item.equal?(SSE::DONE) # the wire's terminal token: yielded in place, no payload
              block&.call(item)
              next
            end

            json = parse_chunk(item)
            next if json.nil? # dropped (I61): counted, the stream continues

            block&.call(json)
          end
        end
      end

      # Cancel→timeout translation (I05 revision): a watchdog fire
      # surfaces the PHASE-named TimeoutError — headers while the POST
      # is outstanding (the response is still nil), read inactivity
      # once the body has begun — while a user's cancel stays
      # CancelledError (D8). The phase needs no flag: headers are
      # outstanding exactly until post_raw_body returns.
      def raise_raw_cancel(watchdog, response, ttfb, idle)
        if watchdog.fired
          message = response.nil? ? "no response headers within #{ttfb}s" : "no data within #{idle}s"
          raise TimeoutError, message
        end
        raise CancelledError, "stream cancelled"
      end

      def feed_stream(response, accumulator, watchdog, &block)
        parser = SSE.new
        @dropped_chunks = 0
        response.body.each do |chunk|
          watchdog.arm # re-arm the inactivity read-timeout per chunk (D5)
          parser.push(chunk).each do |item|
            # I01 §3: TTFB at the FIRST item the parser yields for the
            # successful attempt — before the on_event dispatches
            # derived from this item; the per-attempt POST clock
            # restarted at every retry (create_response). Comments and
            # keepalives never yield items (sse.rb drops them
            # structurally). A flonum difference — no heap.
            if @telemetry_active && !@telemetry_ttfb_fired
              @telemetry_ttfb_fired = true
              elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @telemetry_post_started_at
              @telemetry.each { |sink| sink.on_completion_ttfb(elapsed) }
            end
            next if item == SSE::DONE # terminal token; no payload

            json = parse_chunk(item)
            next if json.nil? # dropped (I61): counted, the stream continues

            events = accumulator.consume(json)
            if block || @telemetry_active # I01 §3: sinks see events even blockless
              events.each do |event|
                notify_event(event) # the sink first, then its consumer twin
                yield event if block
              end
            end
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
      # on_completion_end fires after the :done dispatches — before the
      # return. This method runs OUTSIDE the rescue ladder, so the frozen
      # terminal invariant's "including when the consumer block raises"
      # clause is carried by the yield guards below: a consumer raise at
      # any terminal yield closes the record with on_completion_error
      # (the raiser's symbol) before the unchanged re-raise — on
      # StandardError, the ladder's own catch scope, so cancel and
      # Exception-class raises keep their today escape semantics.
      def deliver_terminal(accumulator, &block)
        events, outcome = accumulator.finish
        if block || @telemetry_active
          events.each do |event|
            notify_event(event) # the sink first, then its consumer twin
            begin
              yield event if block
            rescue StandardError => e
              notify_error(telemetry_symbol_for(e))
              raise
            end
          end
        end
        if outcome[0] == :stream_error
          if block || @telemetry_active
            error_event = Event.new(type: :error, reason: :error, message: accumulator.partial)
            notify_event(error_event)
            begin
              yield error_event if block
            rescue StandardError => e
              notify_error(telemetry_symbol_for(e))
              raise
            end
          end
          notify_error(:stream_error) # the symbol of the StreamError about to raise
          raise StreamError.new(outcome[1], stop_reason: :error)
        end
        if block || @telemetry_active
          done_event = Event.new(type: :done, reason: outcome[1], message: accumulator.partial)
          notify_event(done_event)
          begin
            yield done_event if block
          rescue StandardError => e
            notify_error(telemetry_symbol_for(e))
            raise
          end
        end
        notify_end(outcome[1], accumulator.partial) # after the :done dispatches, before returning
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
          # I01 §2: the per-attempt POST clock for TTFB — restarted at
          # every retry; guarded so the no-sink path adds zero clock
          # reads (gate 3).
          if @telemetry_active
            @telemetry_post_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
          begin
            response = @client.post(@path, headers: headers, body: body)
          rescue Async::Cancel
            raise unless watchdog.fired # the user's cancel is not a failure — never retried (D8)
            raise TimeoutError, "no data within #{@timeout}s" if remaining.zero?
            remaining -= 1
            next
          rescue *NETWORK_ERRORS => e
            # Statusless — no response was received (pi's statusless trigger).
            raise ConnectionError, "#{e.class}: #{e.message}" if remaining.zero?
            remaining -= 1
            next
          end
          return response if (200...300).cover?(response.status)

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
      def salvage(accumulator)
        # I01 §6: the :error terminal reaches the sinks even blockless;
        # with NO sinks AND no block the early return keeps today's
        # behavior byte-identical.
        return if !block_given? && !@telemetry_active

        accumulator.finish
        error_event = Event.new(type: :error, reason: :error, message: accumulator.partial)
        notify_event(error_event) # the sink first, then its consumer twin
        # The frozen terminal invariant: salvage runs INSIDE a rescue arm,
        # and a raise inside a rescue body is not offered to the sibling
        # arms — a consumer raise on this :error event would escape the
        # ladder entirely, so the yield guard closes the record here
        # (the raiser's symbol) before the unchanged re-raise. No-op
        # unless sinks are registered.
        begin
          yield error_event if block_given?
        rescue StandardError => e
          notify_error(telemetry_symbol_for(e))
          raise
        end
      end

      # Complete bodies return the connection to the pool; an aborted read
      # (cancel/timeout) discards it — a cancelled connection is never
      # reused (AC3/D8). Same discipline as stream's ensure.
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
      # Process.clock_gettime reads. Durations are flonum differences
      # off the completion-start clock; dispatch is in registration
      # order; the loop block itself is never materialized, so a no-op
      # sink adds zero heap objects (gate 2).

      def notify_event(event)
        return unless @telemetry_active

        @telemetry.each { |sink| sink.on_event(event) }
      end

      def notify_end(stop_reason, message)
        return unless @telemetry_active

        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @telemetry_started_at
        @telemetry.each { |sink| sink.on_completion_end(stop_reason, duration, message) }
      end

      def notify_error(error)
        return unless @telemetry_active

        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @telemetry_started_at
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
