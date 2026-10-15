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
    server.script([{type: :error, status: 429, message: "slow down"}])
    Async do
      expect {
        client.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |_e| }
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
end
