# frozen_string_literal: true

# Client pins (Specification §6): headers, path join, error mapping,
# timeout watchdog, session-affinity headers — live against the gem's own
# MockLLMServer (§12.1). Byte-parity of the request body is pinned by the
# harness lane's wire_parity_spec; one smoke body assertion lives here too.
require "fast/completions"
require_relative "../../support/mock_llm_server"

RSpec.describe Fast::Completions::Client do
  let(:server) { MockLLMServer.new.start }
  let(:model) do
    Fast::Completions::Model.new(id: "mock-model", reasoning: false, context_window: 128_000,
      max_tokens: 64, dialect: :fireworks)
  end

  after { server.stop }

  def client(**overrides)
    described_class.new(base_url: server.url, api_key: "test-key", **overrides)
  end

  it "POSTs {base}/chat/completions with authorization/content-type/accept headers (§6)" do
    server.script([{type: :stream, content: "ok"}])
    c = client
    Async do
      c.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
      c.close
    end
    entry = server.captured_request_logs.first
    expect(entry[:path]).to eq("/v1/chat/completions")
    expect(entry[:method]).to eq("POST")
    expect(entry[:headers]["authorization"]).to eq("Bearer test-key")
    expect(entry[:headers]["content-type"]).to eq("application/json")
    expect(entry[:headers]["accept"]).to eq("application/json")
  end

  it "emits the §9 body through the wire path (plain-arm smoke: store:false, stream_options, stream:true)" do
    server.script([{type: :stream, content: "ok"}])
    c = client
    Async do
      c.stream(model: model, messages: [Fast::Completions::Message.user("hi")], instructions: "sys") { |_e| }
      c.close
    end
    body = server.captured_requests.first
    expect(body["model"]).to eq("mock-model")
    expect(body["stream"]).to be(true)
    expect(body["stream_options"]).to eq("include_usage" => true)
    expect(body["store"]).to be(false)
    expect(body["max_completion_tokens"]).to eq(64)
    expect(body["messages"].first).to eq("role" => "system", "content" => "sys")
  end

  it "streams events in order and returns the final Message carrying parsed usage" do
    server.script([{type: :stream, content: "Hello"}])
    types = []
    final = nil
    Async do
      final = client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) do |event|
        types << event.type
      end
      client.close
    end
    expect(types.first).to eq(:start)
    expect(types).to include(:text_start, :text_delta, :text_end)
    expect(types.last).to eq(:done)
    expect(final.content).to eq([{type: :text, text: "Hello"}])
    expect(final.usage.total_tokens).to eq(15) # the mock's 10+5
  end

  # ── Chunk-seam tolerance (I61): repair and drop-and-continue. ──

  it "repairs a control-char payload and flows downstream without a drop (I61)" do
    cut = %(data: {"choices":[{"delta":{"content":"a\ndata: b\t c"}}]}\n\n) # raw \n via multi-data-line join, raw \t
    finisher = %(data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n)
    server.script([{type: :stream, raw_frames: [cut, finisher, "data: [DONE]\n\n"]}])
    final = nil
    c = client
    Async do
      final = c.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
      c.close
    end
    expect(final.content).to eq([{type: :text, text: "a\nb\t c"}])
    expect(c.dropped_chunks).to eq(0)
  end

  it "counts dropped chunks on dropped_chunks and resets the counter per stream (I61)" do
    unrepairable = 'data: {"choices":[{"delta":{"content":"x"}}' # truncated, unbalanced braces
    finisher = %(data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n)
    spec = {type: :stream, raw_frames: [unrepairable + "\n\n", finisher, "data: [DONE]\n\n"]}
    server.script([spec, spec])
    c = client
    Async do
      2.times do
        c.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
        expect(c.dropped_chunks).to eq(1) # 1 on each stream: not cumulative
      end
      c.close
    end
  end

  it "maps non-2xx to the §8 tree and passes the provider message" do
    # I62: a 429 is a retry trigger at the new default — these §8 mapping
    # pins pin the single-attempt mapping (max_retries: 0); the trigger
    # classes live in the retry describe below.
    server.script([{type: :error, status: 429, message: "slow down"}])
    Async do
      expect {
        client(max_retries: 0).stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
      }.to raise_error(Fast::Completions::RateLimitError, /429: slow down/)
    end
  end

  it "detects context overflow from a 400 body (§8)" do
    server.script([{type: :error, status: 400, message: "prompt is too long: 900 tokens > 100 maximum"}])
    Async do
      expect {
        client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
      }.to raise_error(Fast::Completions::ContextLengthExceededError)
    end
  end

  it "maps network failures to ConnectionError (§6)" do
    dead = described_class.new(base_url: "http://127.0.0.1:1/v1", api_key: "k") # nothing listens on port 1
    Async do
      expect {
        dead.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
      }.to raise_error(Fast::Completions::ConnectionError)
    end
  end

  it "raises TimeoutError when no response headers arrive within the deadline (TTFB, D5)" do
    # A listener that accepts and never replies: the POST awaits forever.
    black_hole = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      io = black_hole.accept
      sleep 30 # never reply; the test tears it down
    rescue StandardError
      nil
    end
    silent = described_class.new(base_url: "http://127.0.0.1:#{black_hole.addr[1]}/v1", api_key: "k", timeout: 0.15)
    Async do
      expect {
        silent.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
      }.to raise_error(Fast::Completions::TimeoutError)
    ensure
      silent.close
      black_hole.close
    end
  end

  it "raises TimeoutError on read inactivity mid-stream (D5: same value, re-armed per chunk)" do
    # A raw chunked reply that stalls after the first byte pair.
    stall = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      io = stall.accept
      io.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
      io.write("f\r\ndata: {\"x\":1}\n\n\r\n") # one complete SSE event, then nothing
      sleep 30 # never finishes; the test tears it down
    rescue StandardError
      nil
    end
    stalled = described_class.new(base_url: "http://127.0.0.1:#{stall.addr[1]}/v1", api_key: "k", timeout: 0.2)
    Async do
      expect {
        stalled.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
      }.to raise_error(Fast::Completions::TimeoutError)
    ensure
      stalled.close
      stall.close
    end
  end

  describe "session-affinity headers (§6, pi openai-completions.ts :776-789)" do
    # The gem's mock keeps tart's NOTABLE_HEADERS capture list
    # (behavior-identical copy, §12.1), which drops x-session headers —
    # so these pins read the RAW request head off a throwaway TCP reply.
    def raw_request_headers(dialect:, session_id: "sess-1")
      listener = TCPServer.new("127.0.0.1", 0)
      head = nil
      server_thread = Thread.new do
        io = listener.accept
        head = +""
        while (line = io.gets)
          break if line == "\r\n"

          head << line
        end
        body = "data: [DONE]\n\n"
        io.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
        io.write(format("%x\r\n%s\r\n", body.bytesize, body))
        io.write("0\r\n\r\n")
        io.close
      rescue StandardError
        nil
      end
      m = Fast::Completions::Model.new(id: "m", reasoning: false, context_window: 1_000,
        max_tokens: 8, dialect: dialect)
      Async do
        c = described_class.new(base_url: "http://127.0.0.1:#{listener.addr[1]}/v1", api_key: "k")
        c.stream(model: m, messages: [Fast::Completions::Message.user("hi")], session_id: session_id) { |_e| }
        c.close
      end
      server_thread.join(2)
      listener.close
      head.to_s.split("\r\n").each_with_object({}) do |line, out|
        name, value = line.split(":", 2)
        out[name.strip.downcase] = value.strip if value
      end
    end

    it "openai format sends session_id + x-client-request-id + x-session-affinity" do
      headers = raw_request_headers(dialect: Fast::Completions.dialect(:sess_openai, send_session_affinity_headers: true))
      expect(headers).to include("session_id" => "sess-1", "x-client-request-id" => "sess-1", "x-session-affinity" => "sess-1")
    end

    it "openai_nosession format omits session_id" do
      headers = raw_request_headers(dialect: Fast::Completions.dialect(:sess_nosession,
        send_session_affinity_headers: true, session_affinity_format: :openai_nosession))
      expect(headers).not_to have_key("session_id")
      expect(headers).to include("x-client-request-id" => "sess-1", "x-session-affinity" => "sess-1")
    end

    it "openrouter format sends x-session-id" do
      headers = raw_request_headers(dialect: Fast::Completions.dialect(:sess_openrouter,
        send_session_affinity_headers: true, session_affinity_format: :openrouter))
      expect(headers).to include("x-session-id" => "sess-1")
      expect(headers).not_to have_key("session_id")
    end

    it "no headers without a session id, even when the dialect opts in" do
      headers = raw_request_headers(dialect: Fast::Completions.dialect(:sess_openai, send_session_affinity_headers: true),
        session_id: nil)
      expect(headers).not_to have_key("session_id")
    end
  end

  # ── Request-creation retry (I62 §2): pi provider-retry trigger classes.
  # The POST — creation through status receipt — retries at most ONE time
  # by default (Grounds R2), immediately, only on the trigger set; every
  # final failure raises its mapped error after the :error terminal.
  describe "request retry (I62 — pi provider-retry trigger classes)" do
    it "retries a 429 once by default and succeeds (exactly 2 captured requests, no :error terminal)" do
      server.script([{type: :error, status: 429, message: "slow down"}, {type: :stream, content: "recovered"}])
      types = []
      final = nil
      Async do
        final = client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) do |event|
          types << event.type
        end
        client.close
      end
      expect(final.content).to eq([{type: :text, text: "recovered"}])
      expect(server.captured_requests.size).to eq(2)
      expect(types).to eq([:start, :text_start, :text_delta, :text_end, :done]) # the retry is transparent on success
    end

    it "retries on x-should-retry: true even on a final-class status (400)" do
      server.script([
        {type: :error, status: 400, message: "no dice", headers: {"x-should-retry" => "true"}},
        {type: :stream, content: "ok"},
      ])
      final = nil
      Async do
        final = client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
        client.close
      end
      expect(final.content).to eq([{type: :text, text: "ok"}])
      expect(server.captured_requests.size).to eq(2)
    end

    it "treats x-should-retry: false as FINAL even on a retryable status (429): 1 request, :error, then RateLimitError" do
      server.script([{type: :error, status: 429, message: "slow down", headers: {"x-should-retry" => "false"}}])
      types = []
      Async do
        expect {
          client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |e| types << e.type }
        }.to raise_error(Fast::Completions::RateLimitError, /429: slow down/)
        client.close
      end
      expect(types).to eq([:error]) # the terminal precedes the raise; no :start for a failed creation
      expect(server.captured_requests.size).to eq(1)
    end

    it "treats a plain 400 as final: 1 request, :error, then BadRequestError" do
      server.script([{type: :error, status: 400, message: "bad"}])
      types = []
      Async do
        expect {
          client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |e| types << e.type }
        }.to raise_error(Fast::Completions::BadRequestError)
        client.close
      end
      expect(types).to eq([:error])
      expect(server.captured_requests.size).to eq(1)
    end

    it "retries a 5xx (ServerError-class status)" do
      server.script([{type: :error, status: 500, message: "boom"}, {type: :stream, content: "ok"}])
      final = nil
      Async do
        final = client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
        client.close
      end
      expect(final.content).to eq([{type: :text, text: "ok"}])
      expect(server.captured_requests.size).to eq(2)
    end

    it "retries a 409" do
      server.script([{type: :error, status: 409, message: "conflict"}, {type: :stream, content: "ok"}])
      final = nil
      Async do
        final = client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
        client.close
      end
      expect(final.content).to eq([{type: :text, text: "ok"}])
      expect(server.captured_requests.size).to eq(2)
    end

    it "retries ECONNREFUSED (nothing listening) as a statusless failure, then raises ConnectionError after the :error terminal" do
      dead = described_class.new(base_url: "http://127.0.0.1:1/v1", api_key: "k") # nothing listens on port 1
      types = []
      Async do
        expect {
          dead.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |e| types << e.type }
        }.to raise_error(Fast::Completions::ConnectionError, /Errno::ECONNREFUSED/)
        dead.close
      end
      expect(types).to eq([:error]) # the terminal precedes the raise; no :start
    end

    it "retries a TTFB watchdog fire while attempts remain — attempt 2 re-arms and answers (never raises CancelledError)" do
      # The FIRST POST stalls past the deadline (watchdog fire #1 → retry);
      # the retried attempt gets a real reply, so the turn SUCCEEDS — only
      # observable via a retry. Works whether attempt 2 reuses the pooled
      # connection or opens a fresh one (seen counts POSTs, not connects).
      stalls = TCPServer.new("127.0.0.1", 0)
      seen = 0
      seen_lock = Mutex.new
      acceptor = Thread.new do
        loop do
          io = stalls.accept
          Thread.new do
            until io.closed?
              length = 0
              loop do
                line = io.gets
                break if line.nil? || line == "\r\n"

                length = line[/Content-Length: (\d+)/i, 1].to_i if line.match?(/Content-Length/i)
              end
              break if io.closed?
              io.read(length) # drain the request body: keep the socket framing aligned for the retry
              count = seen_lock.synchronize { seen += 1 }
              next if count == 1 # attempt 1: no reply — its TTFB deadline fires and the attempt retries

              frames = ["data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"recovered\"}}]}\n\n",
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
                "data: [DONE]\n\n"]
              payload = frames.map { |f| format("%x\r\n%s\r\n", f.bytesize, f) }.join + "0\r\n\r\n"
              io.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n#{payload}")
              break
            end
          rescue StandardError, IOError
            nil
          end
        end
      rescue StandardError, IOError
        nil
      end
      silent = described_class.new(base_url: "http://127.0.0.1:#{stalls.addr[1]}/v1", api_key: "k", timeout: 0.15)
      final = nil
      Async do
        final = silent.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
        silent.close
      end
      expect(final.content).to eq([{type: :text, text: "recovered"}]) # attempt 2 answered after attempt 1's fire
    ensure
      acceptor.exit # bounded teardown: kill the stalled serve threads
      silent&.close
      stalls.close
    end

    it "stops at the bound: two failures raise after exactly 2 requests at the default" do
      server.script([
        {type: :error, status: 429, message: "slow down"},
        {type: :error, status: 429, message: "still slow"},
      ])
      Async do
        expect {
          client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
        }.to raise_error(Fast::Completions::RateLimitError)
        client.close
      end
      expect(server.captured_requests.size).to eq(2)
    end

    it "max_retries: 0 restores the single attempt" do
      server.script([
        {type: :error, status: 429, message: "slow down"},
        {type: :error, status: 429, message: "never reached"},
      ])
      Async do
        expect {
          client(max_retries: 0).stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
        }.to raise_error(Fast::Completions::RateLimitError)
        client.close
      end
      expect(server.captured_requests.size).to eq(1)
    end

    it "validates max_retries as an Integer >= 0" do
      expect { described_class.new(base_url: "http://127.0.0.1:1/v1", api_key: "k", max_retries: -1) }
        .to raise_error(ArgumentError, /max_retries/)
      expect { described_class.new(base_url: "http://127.0.0.1:1/v1", api_key: "k", max_retries: "1") }
        .to raise_error(ArgumentError, /max_retries/)
    end
  end

  # ── Mid-stream salvage (I62 §1): pi's :707-728 catch-all. Any failure
  # after a 2xx — EXCEPT cancellation — yields the ONE :error terminal
  # carrying the live partial (every streamed block + usage; the thinking
  # reasoning_details serialized into the signature as finalize would),
  # with NO block-end events after the failure, THEN raises.
  describe "mid-stream salvage (I62 — pi :707-728 catch-all)" do
    it "salvages a mid-body abort: [:start, block events, :error(partial)], no end events, then ConnectionError — exactly 1 request" do
      server.script([{type: :stream, abort: true, chunks: [
        {choices: [{delta: {role: "assistant", content: "Hel"}}]},
        {choices: [{delta: {content: "lo"}}]},
        {usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}},
        {choices: [{delta: {content: "!"}}]},
      ]}])
      types = []
      error_event = nil
      Async do
        expect {
          client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) do |event|
            types << event.type
            error_event = event if event.type == :error
          end
        }.to raise_error(Fast::Completions::ConnectionError, /EOFError/) # network family, message form preserved
        client.close
      end
      expect(types).to eq([:start, :text_start, :text_delta, :text_delta, :text_delta, :error])
      expect(types).not_to include(:text_end) # NO block-end events after the failure
      partial = error_event.message
      expect(partial.content).to eq([{type: :text, text: "Hello!"}]) # every streamed block
      expect(partial.usage.total_tokens).to eq(15) # ...and the usage that arrived before the failure
      expect(server.captured_requests.size).to eq(1) # committed to streaming after the 2xx — NEVER retried
    end

    it "salvages a creation-phase 429 (retries exhausted) with an EMPTY partial and no :start, then RateLimitError" do
      server.script([
        {type: :error, status: 429, message: "slow down"},
        {type: :error, status: 429, message: "still slow"},
      ])
      types = []
      error_event = nil
      Async do
        expect {
          client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) do |event|
            types << event.type
            error_event = event if event.type == :error
          end
        }.to raise_error(Fast::Completions::RateLimitError, /429: still slow/)
        client.close
      end
      expect(types).to eq([:error]) # no :start for a failed creation
      expect(error_event.message.content).to eq([]) # the empty accumulator
    end

    it "serializes streamed reasoning_details into the salvaged thinking block's signature, as finalize would" do
      server.script([{type: :stream, abort: true, chunks: [
        {choices: [{delta: {reasoning_content: "chain"}}]},
        {choices: [{delta: {reasoning_details: [{type: "reasoning.text", text: "detail"}]}}]},
        {choices: [{delta: {content: "ans"}}]},
      ]}])
      types = []
      error_event = nil
      Async do
        expect {
          client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) do |event|
            types << event.type
            error_event = event if event.type == :error
          end
        }.to raise_error(Fast::Completions::ConnectionError)
        client.close
      end
      expect(types).to eq([:start, :thinking_start, :thinking_delta, :text_start, :text_delta, :error])
      expect(types).not_to include(:thinking_end, :text_end)
      thinking, text = error_event.message.content
      expect(thinking).to eq({type: :thinking, thinking: "chain",
        signature: JSON.generate([{"type" => "reasoning.text", "text" => "detail"}])})
      expect(text).to eq({type: :text, text: "ans"})
    end

    it "salvages any other mid-stream StandardError the same way and re-raises it unchanged" do
      server.script([{type: :stream, content: "Hello"}])
      types = []
      error_event = nil
      Async do
        expect {
          client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) do |event|
            types << event.type
            error_event = event if event.type == :error
            raise "boom" if event.type == :text_delta
          end
        }.to raise_error(RuntimeError, /boom/) # re-raised unchanged — not mapped, not retried
        client.close
      end
      expect(types).to eq([:start, :text_start, :text_delta, :error])
      expect(error_event.message.content).to eq([{type: :text, text: "Hello"}])
    end
  end
end
