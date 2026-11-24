# frozen_string_literal: true

module Fast
  module Embeddings
    # The frozen error taxonomy (the completions house style, standalone
    # per gem). CancelledError is deliberately NOT under Error so rescue
    # ladders that catch the API error tree never swallow a cancellation.
    class Error < StandardError; end

    # Non-2xx responses map here. #message is
    # "<status>: <provider message>" — the provider's error.message when
    # the body parses, else the raw body truncated.
    class ApiError < Error
      attr_reader :status, :body

      def initialize(status:, body: "")
        @status = status
        @body = body.to_s
        super(Errors.api_message(status, @body))
      end
    end

    class BadRequestError < ApiError; end         # 400
    class AuthenticationError < ApiError; end     # 401
    class PermissionError < ApiError; end         # 403
    class NotFoundError < ApiError; end           # 404
    class RateLimitError < ApiError; end          # 429
    class ServerError < ApiError; end             # 5xx

    # Deadline (watchdog fire): the caller's cancel surfaces as
    # CancelledError, never this (the cancel-vs-fired discipline).
    class TimeoutError < Error; end
    # ECONNREFUSED/ECONNRESET/... — the network family (message form
    # `"<class>: <message>"`).
    class ConnectionError < Error; end

    # A 2xx body that lies: it fails JSON.parse, parses to a non-Hash,
    # or whose data is not an Array of Hashes each carrying an Array
    # embedding and an Integer index. Fail loud, never silently
    # mistranslate.
    class ResponseError < Error; end

    class CancelledError < StandardError; end      # NOT < Error (D8)

    # Internal: error classification helpers.
    module Errors
      STATUS_CLASSES = {
        401 => AuthenticationError,
        403 => PermissionError,
        404 => NotFoundError,
        429 => RateLimitError,
      }.freeze

      module_function

      # Map a non-2xx status + body to the frozen class. A 400 stays a
      # BadRequestError — there is no overflow machinery on this wire.
      def class_for_status(status, body)
        case status
        when 400
          BadRequestError
        when 500..599
          ServerError
        else
          STATUS_CLASSES.fetch(status, ApiError)
        end
      end

      # ApiError#message: "<status>: <message>" — the provider's
      # error.message when parseable, else the raw body truncated to
      # ~500 chars.
      def api_message(status, body)
        "#{status}: #{provider_message(body)}"
      end

      def provider_message(body)
        raw = body.to_s
        parsed = JSON.parse(raw)
        message = parsed["error"]["message"] if parsed.is_a?(Hash) && parsed["error"].is_a?(Hash)
        message ||= parsed["message"] if parsed.is_a?(Hash)
        message || raw[0, 500]
      rescue JSON::ParserError, TypeError
        raw[0, 500]
      end
    end
  end
end
