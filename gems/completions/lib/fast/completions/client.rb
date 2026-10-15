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

      attr_reader :timeout, :max_retries, :dropped_chunks

      def initialize(base_url:, api_key:, timeout: DEFAULT_TIMEOUT, max_retries: DEFAULT_MAX_RETRIES)
        raise ArgumentError, "max_retries must be an Integer >= 0" unless max_retries.is_a?(Integer) && max_retries >= 0

        @endpoint = Async::HTTP::Endpoint.parse(base_url)
        @api_key = api_key
        @timeout = timeout
        @max_retries = max_retries
        @client = Async::HTTP::Client.new(@endpoint)
        @path = @endpoint.path.chomp("/") + "/chat/completions"
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

        watchdog = Watchdog.new(Async::Task.current, @timeout)
        response = nil
        begin
          # The POST attempt — creation through status receipt (§2),
          # bounded-retried on pi's trigger set; every final creation
          # failure raises its mapped error from in there.
          response = create_response(headers, body, watchdog)
          yield accumulator.start_event if block # :start precedes every block event (§10.6)
          feed_stream(response, accumulator, watchdog, &block)
        rescue Async::Cancel
          watchdog.fired ? raise(TimeoutError, "no data within #{@timeout}s") : raise(CancelledError, "stream cancelled")
        rescue *NETWORK_ERRORS => e
          salvage(accumulator, &block) # the :error terminal carries the partial BEFORE the raise (§1)
          raise ConnectionError, "#{e.class}: #{e.message}"
        rescue StandardError
          salvage(accumulator, &block) # pi's catch-all: any other streaming failure — same terminal, raised unchanged
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
        raise TimeoutError, "no data within #{@timeout}s" if watchdog.fired

        deliver_terminal(accumulator, &block)
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

      def feed_stream(response, accumulator, watchdog, &block)
        parser = SSE.new
        @dropped_chunks = 0
        response.body.each do |chunk|
          watchdog.arm # re-arm the inactivity read-timeout per chunk (D5)
          parser.push(chunk).each do |item|
            next if item == SSE::DONE # terminal token; no payload

            json = parse_chunk(item)
            next if json.nil? # dropped (I61): counted, the stream continues

            events = accumulator.consume(json)
            events.each { |event| yield event } if block
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
      def deliver_terminal(accumulator, &block)
        events, outcome = accumulator.finish
        events.each { |event| yield event } if block
        if outcome[0] == :stream_error
          yield Event.new(type: :error, reason: :error, message: accumulator.partial) if block
          raise StreamError.new(outcome[1], stop_reason: :error)
        end
        yield Event.new(type: :done, reason: outcome[1], message: accumulator.partial) if block
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
        return unless block_given?

        accumulator.finish
        yield Event.new(type: :error, reason: :error, message: accumulator.partial)
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
    end
  end
end
