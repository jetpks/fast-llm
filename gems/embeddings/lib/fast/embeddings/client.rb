# frozen_string_literal: true

require "json"
require "async"
require "async/http"

module Fast
  module Embeddings
    # ONE persistent Async::HTTP::Client per instance, fiber-native: every
    # request runs INSIDE the caller's reactor — the client never creates
    # its own.
    class Client
      DEFAULT_TIMEOUT = 30

      # Deadline watchdog: armed before the POST, no re-arm — exactly one
      # attempt per call. A fire cancels the waiting task; `fired` tells
      # the deadline apart from a user's cancel (D8).
      class Watchdog
        def initialize(task, seconds)
          @task = task
          @seconds = seconds
          @timer = nil
          @fired = false
        end

        attr_reader :fired

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

      attr_reader :timeout

      def initialize(base_url:, timeout: DEFAULT_TIMEOUT)
        unless timeout.is_a?(Numeric) && timeout.positive?
          raise ArgumentError, "timeout must be a positive Numeric"
        end

        @endpoint = Async::HTTP::Endpoint.parse(base_url)
        @timeout = timeout
        @client = Async::HTTP::Client.new(@endpoint)
        @path = @endpoint.path.chomp("/") + "/embeddings"
      end

      def close
        @client.close
        nil
      end

      # POST {base}/embeddings, read the ONE JSON reply, return a Result.
      # Runs inside the caller's task. Exactly ONE attempt — no retry
      # machinery of any kind: retries are the caller's. The body is a
      # CLOSED two-key set ({model, input}) in that key order; input
      # crosses the wire VERBATIM, in order — the gem never slices,
      # truncates, chunks, or re-orders it (batch discipline is the
      # caller's). The credential, when given, is used for this call and
      # discarded: no instance variable of this client ever holds it.
      def embed(model:, input:, api_key: nil)
        validate_model!(model)
        validate_input!(input)
        body = JSON.generate({model: model, input: input}) # key order: model, input

        watchdog = Watchdog.new(Async::Task.current, @timeout)
        response = nil
        result = nil
        begin
          watchdog.arm
          response = @client.post(@path, headers: headers_for(api_key), body: body)
          raise_api_error(response) unless (200...300).cover?(response.status)
          result = parse_result(response.body.read)
        rescue Async::Cancel
          raise(TimeoutError, "no data within #{@timeout}s") if watchdog.fired

          raise CancelledError, "embed cancelled"
        rescue *NETWORK_ERRORS => e
          raise ConnectionError, "#{e.class}: #{e.message}"
        ensure
          finish_quietly(response) # nil-safe: no response yet, or an aborted read
          watchdog.stop
        end
        raise TimeoutError, "no data within #{@timeout}s" if watchdog.fired # the post-ensure deadline raise

        result
      end

      private

      # Authorization is optional: sent only when a key is present and
      # non-empty — a local engine needs none. The key lives in this
      # local, never in an ivar.
      def headers_for(api_key)
        if api_key && !api_key.empty?
          {
            "authorization" => "Bearer #{api_key}",
            "content-type" => "application/json",
            "accept" => "application/json",
          }
        else
          {"content-type" => "application/json", "accept" => "application/json"}
        end
      end

      def validate_model!(model)
        return if model.is_a?(String) && !model.empty?

        raise ArgumentError, "model must be a non-empty String"
      end

      # A bare String also raises — the caller wraps; fail loud.
      def validate_input!(input)
        return if input.is_a?(Array) && !input.empty? && input.all?(String)

        raise ArgumentError, "input must be a non-empty Array of Strings"
      end

      # Non-2xx: read the body, map to the frozen taxonomy.
      def raise_api_error(response)
        body = response.body.read
        raise Errors.class_for_status(response.status, body).new(status: response.status, body: body)
      end

      # The 2xx body must not lie: a JSON Hash whose data is an Array of
      # Hashes each carrying an Array embedding and an Integer index.
      # Anything else raises ResponseError — never a silent
      # mistranslation. data keeps WIRE ORDER (never re-sorted by
      # index); the caller zips by index.
      def parse_result(raw)
        parsed = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          raise ResponseError, "embeddings reply is not JSON: #{raw[0, 120].inspect}"
        end
        raise ResponseError, "embeddings reply is not a JSON object" unless parsed.is_a?(Hash)

        data = parsed["data"]
        unless data.is_a?(Array) && data.all? { |entry| datum?(entry) }
          raise ResponseError, "embeddings reply data is not an Array of {embedding, index} objects"
        end

        Result.new(
          data: data.map { |entry| Datum.new(embedding: entry["embedding"], index: entry["index"]) },
          usage: Usage.for_wire(parsed["usage"]),
        )
      end

      def datum?(entry)
        entry.is_a?(Hash) && entry["embedding"].is_a?(Array) && entry["index"].is_a?(Integer)
      end

      # Complete bodies return the connection to the pool; an aborted
      # read (cancel/deadline) discards it. Nil-safe.
      def finish_quietly(response)
        response.finish
      rescue StandardError, Async::Cancel
        nil
      end
    end
  end
end
