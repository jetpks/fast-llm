# frozen_string_literal: true

module Fast
  module Completions
    # Incremental tool-args string-state machine (I02, 0.5.0). A DELIBERATE
    # departure from pi: pi re-parses the whole arguments scratch on every
    # delta (openai-completions.ts :652-658) — O(n²) across a stream and
    # the pair-in-flight vanishes until its closing quote. This machine
    # instead carries per-block parser state ACROSS deltas and walks only
    # the NEW fragment's bytes each time (O(n) total, no per-delta copy of
    # any accumulated buffer, no exception on the streaming path), growing
    # the live view (`block[:arguments]`, the root_target below) IN PLACE.
    # The authoritative whole-buffer parse still happens exactly once, at
    # finalize (Protocol.parse_streaming_json — the unchanged pi parity).
    #
    # THE LIVE-VIEW CONTRACT (frozen, Specification L1-L9). L8 totality:
    # this source throws no exceptions and installs none — the machine
    # is total on any fragment sequence: malformed input freezes the
    # live view and never crashes the stream. The frozen interface:
    # ArgsStreamer.new(
    # root_target) — the block's arguments Hash, populated in place (L1);
    # #consume(String) -> self — append to the scratch, walk the new bytes;
    # #scratch -> String — the raw bytes accumulated, for the finalize
    # parse. Everything below the interface is this file's own design.
    class ArgsStreamer
      attr_reader :scratch

      # L3 scalar classification (frozen): a scalar that terminates is
      # REPLACED by Integer/Float/true/false/nil when its raw text is a
      # WELL-FORMED scalar, and keeps its raw-text String when malformed
      # — the frozen clause's own examples are `01` and `1.`, so JSON's
      # grammar (leading zeros, dangling fractions) gates the
      # classification; the Integer/Float shapes below are the frozen
      # forms minus the leading-zero overlap the malformed clause rules
      # out. Integer for -?(0|[1-9]\d*), Float for that mantissa plus a
      # fraction and/or exponent.
      INTEGER_TEXT = /\A-?(?:0|[1-9]\d*)\z/
      FLOAT_TEXT = /\A-?(?:(?:0|[1-9]\d*)\.\d+(?:[eE][+-]?\d+)?|(?:0|[1-9]\d*)(?:\.\d+)?[eE][+-]?\d+)\z/

      # Fast path: a run of string-content bytes needing no per-byte
      # handling — not a quote, not a backslash, not a raw control char,
      # not a UTF-8 lead/continuation byte. Binary (/n) so it matches the
      # byte view of the fragment.
      PLAIN_RUN = /[^"\\\x00-\x1f\x80-\xff]+/n

      # Byte constants (structure is always ASCII; content may be any
      # byte — multibyte sequences are assembled, never mistaken for it).
      QUOTE = 0x22
      BACKSLASH = 0x5C
      COLON = 0x3A
      COMMA = 0x2C
      OPEN_BRACE = 0x7B
      CLOSE_BRACE = 0x7D
      OPEN_BRACKET = 0x5B
      CLOSE_BRACKET = 0x5D

      def initialize(root_target)
        @root = root_target
        @scratch = +""
        # Machine state (:value/:after_value refer to @stack.last; the
        # frame layout is [container, :hash|:array]):
        #   :scan_root  — before the root token (whitespace skipped)
        #   :frozen     — root closed or structurally unparseable (L7);
        #                 later bytes never mutate the live view again
        #   :key_first  — object after `{`: first key or `}`
        #   :key        — object after a comma: a key is required
        #   :colon      — between a completed key and its value
        #   :value      — a value token may start (or `]` closing an
        #                 EMPTY array, per @may_close)
        #   :after_value— expecting `,` or the container's closer
        #   :in_key / :in_string — accumulating a key / a string value
        #   :in_scalar  — accumulating raw scalar text
        #   :escape / :u_escape — mid-escape (held across deltas, L5/L6)
        @state = :scan_root
        @stack = []
        @key = nil        # completed key text for the pending pair
        @buf = nil        # the String being grown (a live value or a key)
        @str_back = nil   # :in_key or :in_string — where an escape returns
        @cell = nil       # [container, key_or_index] — the in-flight scalar slot
        @scalar = nil     # raw scalar text (replaced on termination, L3)
        @digits = nil     # collected hex digits of a \u run
        @pending_high = nil # held high surrogate (L6)
        @utf8_bytes = nil   # partial multibyte sequence being assembled
        @utf8_len = 0
        @may_close = false # :value may see `]` (freshly opened array)
      end

      # Append the fragment to the scratch and walk ONLY its bytes. An
      # empty fragment is a no-op (L8); a frozen machine still accumulates
      # the scratch — finalize, not this walk, is the authority (L9).
      def consume(fragment)
        return self unless fragment.is_a?(String)

        # Scratch discipline (L8 totality — no exception ever leaves this
        # file): the scratch stays UTF-8 so the finalize parse gets a
        # JSON-parseable string. A same-encoding or ASCII-only fragment
        # appends with no copy; anything else (a binary fragment cut
        # mid-multibyte, odd encodings) is normalized byte-for-byte to
        # UTF-8 first — invalid bytes stay invalid and finalize's repair
        # path owns them. `bytes` is the walk view: binary for the
        # byte-level regex, the fragment itself when it is ASCII-only
        # (the regex accepts an ASCII-only string in any encoding).
        bytes = fragment.ascii_only? ? fragment : fragment.b
        if fragment.encoding == Encoding::UTF_8 || fragment.ascii_only?
          @scratch << fragment
        else
          @scratch << bytes.dup.force_encoding(Encoding::UTF_8)
        end
        return self if @state == :frozen

        frag = bytes
        i = 0
        length = frag.bytesize
        while i < length
          byte = frag.getbyte(i)
          if ((@state == :in_string || @state == :in_key) && @utf8_bytes.nil?) &&
             byte != QUOTE && byte != BACKSLASH && byte >= 0x20 && byte < 0x80
            # Fast path: a plain run — one in-place append, one regex scan
            # of the NEW bytes only. A held high surrogate drops here: its
            # pair never lands (L6).
            @pending_high = nil
            run = PLAIN_RUN.match(frag, i)[0]
            @buf << run
            i += run.bytesize
            next
          end
          i += 1
          case @state
          when :in_string, :in_key
            consume_string_byte(byte) || (i -= 1) # false = reprocess the byte
          when :escape
            consume_escape_byte(byte) || (i -= 1)
          when :u_escape
            consume_unicode_byte(byte) || (i -= 1)
          when :scan_root
            case byte
            when 0x09, 0x0A, 0x0D, 0x20 then nil # whitespace skipped
            when OPEN_BRACE
              @stack.push([@root, :hash]) # the live Hash populates (L7)
              @state = :key_first
            else # array, scalar, garbage before `{` — empty and frozen
              @state = :frozen
            end
          when :key_first, :key
            case byte
            when 0x09, 0x0A, 0x0D, 0x20 then nil
            when QUOTE
              @buf = +""
              @pending_high = nil
              @utf8_bytes = nil
              @state = :in_key
            when CLOSE_BRACE
              if @state == :key_first
                close_container # `{}` — the empty object closes
              else # after a comma a key is required: unparseable
                @state = :frozen
              end
            else
              @state = :frozen
            end
          when :colon
            case byte
            when 0x09, 0x0A, 0x0D, 0x20 then nil
            when COLON
              @may_close = false
              @state = :value
            else
              @state = :frozen
            end
          when :value
            case byte
            when 0x09, 0x0A, 0x0D, 0x20 then nil
            when QUOTE then open_string_value
            when OPEN_BRACE then open_container({}, :hash)
            when OPEN_BRACKET then open_container([], :array)
            when CLOSE_BRACKET
              if @may_close # `[]`; any other `]` here is unparseable
                close_container
              else
                @state = :frozen
              end
            when CLOSE_BRACE, COMMA then @state = :frozen # no value can start with these
            else
              open_scalar(byte)
            end
          when :after_value
            case byte
            when 0x09, 0x0A, 0x0D, 0x20 then nil
            when COMMA
              if @stack.last[1] == :hash
                @state = :key
              else
                @may_close = false
                @state = :value
              end
            when CLOSE_BRACE
              @stack.last[1] == :hash ? close_container : @state = :frozen
            when CLOSE_BRACKET
              @stack.last[1] == :array ? close_container : @state = :frozen
            else
              @state = :frozen
            end
          when :in_scalar
            case byte
            when COMMA, CLOSE_BRACE, CLOSE_BRACKET, 0x09, 0x0A, 0x0D, 0x20
              # Token terminated (delimiter, closer, or whitespace): the
              # raw-text String is REPLACED in its slot by the classified
              # value (L3); the terminator itself is reprocessed below.
              @cell[0][@cell[1]] = scalar_value(@scalar)
              @state = :after_value
              i -= 1
            else
              @scalar << byte
            end
          end
        end
        self
      end

      private

      # One byte inside a key or a string value. Returns false when the
      # byte must be reprocessed (a broken multibyte sequence is dropped
      # and the offending byte starts over).
      def consume_string_byte(byte)
        if @utf8_bytes
          if byte >= 0x80 && byte <= 0xBF
            @utf8_bytes << byte
            if @utf8_bytes.size == @utf8_len
              sequence = @utf8_bytes.pack("C*").force_encoding(Encoding::UTF_8)
              @buf << sequence if sequence.valid_encoding?
              @utf8_bytes = nil
            end
          else # the sequence never completes: dropped, byte reprocessed
            @utf8_bytes = nil
            return false
          end
        elsif byte >= 0x80
          @pending_high = nil # a held high's pair never lands (L6)
          if byte >= 0xC2 && byte <= 0xF4 # a valid lead byte; anything else is dropped
            @utf8_len = byte < 0xE0 ? 2 : (byte < 0xF0 ? 3 : 4)
            @utf8_bytes = [byte]
          end
        elsif byte == QUOTE # the string closes
          @pending_high = nil # a held high's pair never lands (L6)
          if @state == :in_key
            @key = @buf
            @state = :colon
          else
            @state = :after_value
          end
        elsif byte == BACKSLASH
          @str_back = @state
          @state = :escape
        else # plain ASCII content, raw control characters included (L5)
          @pending_high = nil
          @buf << byte
        end
        true
      end

      # The byte after a backslash. Returns false when the byte must be
      # reprocessed (an invalid escape char contributes the literal
      # backslash, then the char itself is handled as content, L5).
      def consume_escape_byte(byte)
        case byte
        when 0x75 # u — the hex run starts; a held high may still pair (L6)
          @digits = +""
          @state = :u_escape
        when QUOTE then settle_escape("\"")
        when BACKSLASH then settle_escape("\\")
        when 0x2F then settle_escape("/") # \/ — repair_json parity
        when 0x62 then settle_escape("\b")
        when 0x66 then settle_escape("\f")
        when 0x6E then settle_escape("\n")
        when 0x72 then settle_escape("\r")
        when 0x74 then settle_escape("\t")
        else
          @pending_high = nil
          @buf << "\\" # invalid escape char: literal `\`, char reprocessed
          @state = @str_back
          return false
        end
        true
      end

      def settle_escape(text)
        @pending_high = nil # a held high's pair never lands (L6)
        @buf << text
        @state = @str_back
      end

      # One byte of a \u run. Returns false when the byte must be
      # reprocessed (an invalidated run contributes literal `\u` + the
      # digits collected, then the offending byte is handled as content,
      # L5 — a short run invalidated by the string's closing quote is the
      # "short at close" case).
      def consume_unicode_byte(byte)
        if hex_byte?(byte)
          @digits << byte
          if @digits.size == 4
            codepoint = @digits.to_i(16)
            if codepoint >= 0xD800 && codepoint <= 0xDBFF
              @pending_high = codepoint # held for a possible pair (L6)
            elsif codepoint >= 0xDC00 && codepoint <= 0xDFFF
              if @pending_high # the pair combines into one codepoint (L6)
                pair = 0x10000 + ((@pending_high & 0x3FF) << 10) + (codepoint & 0x3FF)
                @buf << pair
                @pending_high = nil
              end # a lone low half never enters the live value (L6)
            else
              @pending_high = nil
              @buf << codepoint
            end
            @state = @str_back
          end
        else
          @pending_high = nil
          @buf << "\\u"
          @buf << @digits
          @state = @str_back
          return false
        end
        true
      end

      def hex_byte?(byte)
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) ||
          (byte >= 0x61 && byte <= 0x66)
      end

      # A string value materializes at its OPENING quote — the slot exists
      # with "" before any content byte (L3) — and grows by in-place
      # append for the rest of the stream (L1).
      def open_string_value
        value = +""
        attach(value)
        @buf = value
        @pending_high = nil
        @utf8_bytes = nil
        @state = :in_string
      end

      # An object/array value materializes at its opening token and is
      # inserted into its parent immediately (L3), then mutated in place
      # (L1). A fresh array may still be closed empty while @may_close.
      def open_container(container, kind)
        attach(container)
        @stack.push([container, kind])
        if kind == :hash
          @state = :key_first
        else
          @may_close = true
          @state = :value
        end
      end

      # A scalar materializes as its raw-text String at its FIRST byte
      # (L3), inserted into its parent; the slot is replaced when the
      # token terminates (see :in_scalar above).
      def open_scalar(byte)
        @scalar = +""
        @scalar << byte
        attach(@scalar)
        @state = :in_scalar
      end

      # Insert a fresh value into the innermost container. Duplicate keys
      # collapse to one slot, last value wins (L2); array elements append.
      # The slot pair also serves scalar replacement — `container[key]=`
      # and `container[index]=` are the same expression for both kinds.
      def attach(value)
        frame = @stack.last
        if frame[1] == :hash
          frame[0][@key] = value
          @cell = [frame[0], @key]
        else
          @cell = [frame[0], frame[0].size]
          frame[0] << value
        end
      end

      # Close the innermost container. The root object closing (or the
      # last frame popping empty) freezes the live view (L7).
      def close_container
        @stack.pop
        @state = @stack.empty? ? :frozen : :after_value
      end

      def scalar_value(text)
        case text
        when "true" then true
        when "false" then false
        when "null" then nil
        else
          if text.match?(INTEGER_TEXT) then text.to_i
          elsif text.match?(FLOAT_TEXT) then text.to_f
          else text # malformed (`01`, `1.` at close): keeps its raw text
          end
        end
      end
    end
  end
end
