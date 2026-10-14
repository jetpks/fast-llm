# frozen_string_literal: true

module Fast
  module Completions
    # The frozen error taxonomy (Specification §8). CancelledError is
    # deliberately NOT under Error so rescue ladders that catch the API
    # error tree never swallow a cancellation (D8).
    class Error < StandardError; end

    # Non-2xx responses map here (pi maps the OpenAI SDK status error).
    # #message is "<status>: <provider message>" — the provider's
    # error.message when the body parses, else the raw body truncated.
    class ApiError < Error
      attr_reader :status, :body

      def initialize(status:, body: "")
        @status = status
        @body = body.to_s
        super(Errors.api_message(status, @body))
      end
    end

    class BadRequestError < ApiError; end            # 400
    class ContextLengthExceededError < BadRequestError; end # 400 + overflow pattern
    class AuthenticationError < ApiError; end        # 401
    class PermissionError < ApiError; end            # 403
    class NotFoundError < ApiError; end              # 404
    class RateLimitError < ApiError; end             # 429
    class ServerError < ApiError; end                # 5xx

    class TimeoutError < Error; end                  # TTFB deadline / read inactivity (D5)
    class ConnectionError < Error; end               # ECONNREFUSED/ECONNRESET/... (§6)

    # Terminal stream errors (pi throws inside stream; the gem emits the
    # :error event first, then raises this — §10.5).
    class StreamError < Error
      attr_reader :stop_reason

      def initialize(message, stop_reason:)
        @stop_reason = stop_reason
        super(message)
      end
    end

    class CancelledError < StandardError; end        # NOT < Error (D8)

    # Internal: error classification helpers (Specification §8).
    module Errors
      # pi utils/overflow.ts :33-96 — the FULL pattern list, ported
      # verbatim as data (regexes already case-insensitive).
      OVERFLOW_PATTERNS = [
        /prompt (?:is )?too long/i,                                  # Anthropic and z.ai token overflow
        /prompt exceeds max length/i,                                # z.ai CN endpoint token overflow
        /request_too_large/i,                                        # Anthropic request byte-size overflow (HTTP 413)
        /input is too long for requested model/i,                    # Amazon Bedrock
        /exceeds the context window/i,                               # OpenAI (Completions & Responses API)
        /exceeds (?:the )?(?:model'?s )?maximum context length(?: of [\d,]+ tokens?|\s*\([\d,]+\))/i, # LiteLLM
        /input token count.*exceeds the maximum/i,                   # Google (Gemini)
        /maximum prompt length is \d+/i,                             # xAI (Grok)
        /reduce the length of the messages/i,                        # Groq
        /maximum context length is \d+ tokens/i,                     # OpenRouter (most backends)
        /exceeds (?:the )?maximum allowed input length of [\d,]+ tokens?/i, # OpenRouter/Poolside
        /input \(\d+ tokens\) is longer than the model'?s context length \(\d+ tokens\)/i, # Together AI
        /exceeds the limit of \d+/i,                                 # GitHub Copilot
        /exceeds the available context size/i,                       # llama.cpp server
        /greater than the context length/i,                          # LM Studio
        /context window exceeds limit/i,                             # MiniMax
        /exceeded model token limit/i,                               # Kimi For Coding
        /too large for model with \d+ maximum context length/i,      # Mistral
        /prompt has [\d,]+ tokens?, but the configured context size is [\d,]+ tokens?/i, # DS4 server
        /model_context_window_exceeded/i,                            # z.ai non-standard finish_reason as error text
        /prompt too long; exceeded (?:max )?context length/i,        # Ollama explicit overflow error
        /range of input length should be/i,                          # DashScope / Qwen Token Plan
        /context[_ ]length[_ ]exceeded/i,                            # Generic fallback
        /too many tokens/i,                                          # Generic fallback
        /token limit exceeded/i,                                     # Generic fallback
      ].freeze

      STATUS_CLASSES = {
        401 => AuthenticationError,
        403 => PermissionError,
        404 => NotFoundError,
        429 => RateLimitError,
      }.freeze

      module_function

      # Map a non-2xx status + body to the frozen class. 400 classifies
      # as ContextLengthExceededError when ANY string in the parsed body
      # (or the raw body) matches any overflow pattern (§8).
      def class_for_status(status, body)
        case status
        when 400
          overflow?(body) ? ContextLengthExceededError : BadRequestError
        when 500..599
          ServerError
        else
          STATUS_CLASSES.fetch(status, ApiError)
        end
      end

      def overflow?(body)
        raw = body.to_s
        strings_in(raw).any? do |text|
          OVERFLOW_PATTERNS.any? { |pattern| pattern.match?(text) }
        end
      end

      # ApiError#message: "<status>: <message>" — the provider's
      # error.message when parseable, else the raw body truncated to
      # ~500 chars (Specification §8).
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

      # Every string value in a (possibly JSON) body — the pattern set is
      # matched against each, so a nested {"error":{"message": ...}} is
      # covered without pinning one shape.
      def strings_in(raw)
        strings = [raw]
        parsed = JSON.parse(raw)
        walk = ->(node) do
          case node
          when String then strings << node
          when Array then node.each { |item| walk.call(item) }
          when Hash then node.each_value { |item| walk.call(item) }
          end
        end
        walk.call(parsed) if parsed.is_a?(Hash) || parsed.is_a?(Array)
        strings
      rescue JSON::ParserError, TypeError
        strings
      end
    end
  end
end
