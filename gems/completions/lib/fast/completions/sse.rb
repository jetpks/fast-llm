# frozen_string_literal: true

module Fast
  module Completions
    # SSE line parser (Specification §7): arbitrary byte-chunk boundaries
    # in, complete `data:` payloads out, in order.
    #
    # Rules (SSE): events separated by a blank line; `data:` prefix
    # (one space) stripped; `:`-prefixed lines are comments and ignored
    # (the mock's keepalives); CR is stripped (\r\n normalized); a
    # multi-data-line event concatenates with "\n"; `data: [DONE]` is the
    # terminal token and surfaces as the distinguished SSE::DONE
    # sentinel, NOT a payload.
    class SSE
      # Distinguished terminal token for `data: [DONE]` (§7).
      DONE = Object.new.freeze

      def initialize
        @buffer = +""
        @data_lines = []
      end

      # Feed one network chunk; returns an Array of completed items for
      # this push — String payloads and/or the DONE sentinel, in order.
      # Only COMPLETE lines are consumed; a trailing partial line stays
      # buffered until its \n arrives (chunk-boundary safety).
      def push(chunk)
        @buffer << chunk
        items = []
        while (newline = @buffer.index("\n"))
          line = @buffer.slice!(0..newline).chomp
          item = handle_line(line)
          items << item unless item.nil?
        end
        items
      end

      private

      def handle_line(line)
        # CR stripped: \r\n normalized even when the CR rides at the end
        # of a split chunk's last complete line.
        line = line.delete_suffix("\r")
        if line.start_with?(":") # comment (keepalive) — ignored (§7)
          return nil
        end

        if line.empty? # blank line = event boundary → dispatch
          return flush_event
        end

        if line.start_with?("data:")
          payload = line.delete_prefix("data:")
          payload = payload[1..] if payload.start_with?(" ") # strip exactly one space
          @data_lines << payload
        end
        # event:/id:/retry: and anything else: not on this wire; ignored.
        nil
      end

      def flush_event
        return nil if @data_lines.empty?

        payload = @data_lines.join("\n") # multi-data-line concat (SSE spec)
        @data_lines = []
        payload == "[DONE]" ? DONE : payload
      end
    end
  end
end
