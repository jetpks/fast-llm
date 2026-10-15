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
        # inactivity read-timeout after every body chunk.
        def arm
          stop
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

      attr_reader :timeout, :dropped_chunks

      def initialize(base_url:, api_key:, timeout: DEFAULT_TIMEOUT)
        @endpoint = Async::HTTP::Endpoint.parse(base_url)
        @api_key = api_key
        @timeout = timeout
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
      def stream(model:, messages:, instructions: nil, tools: [], thinking: nil,
        max_tokens: nil, temperature: nil, session_id: nil, &block)
        request = Protocol.build_request(
          model: model, messages: messages, instructions: instructions,
          tools: tools, thinking: thinking, max_tokens: max_tokens,
          temperature: temperature,
        )
        headers = default_headers.merge(session_headers(model.dialect, session_id))
        accumulator = Protocol::StreamAccumulator.new(model, model.dialect)

        watchdog = Watchdog.new(Async::Task.current, @timeout)
        begin
          watchdog.arm
          response = @client.post(@path, headers: headers, body: JSON.generate(request))
          begin
            raise_api_error(response) unless (200...300).cover?(response.status)
            yield accumulator.start_event if block # :start precedes every block event (§10.6)
            feed_stream(response, accumulator, watchdog, &block)
          ensure
            # Complete bodies return the connection to the pool; an aborted
            # read (cancel/timeout) discards it — a cancelled connection is
            # never reused (AC3/D8).
            begin
              response.finish
            rescue StandardError, Async::Cancel
              nil
            end
          end
        rescue Async::Cancel
          watchdog.fired ? raise(TimeoutError, "no data within #{@timeout}s") : raise(CancelledError, "stream cancelled")
        rescue *NETWORK_ERRORS => e
          raise ConnectionError, "#{e.class}: #{e.message}"
        ensure
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

      # Non-2xx: read the body, map per §8.
      def raise_api_error(response)
        body = response.body.read
        raise Errors.class_for_status(response.status, body).new(status: response.status, body: body)
      end
    end
  end
end
