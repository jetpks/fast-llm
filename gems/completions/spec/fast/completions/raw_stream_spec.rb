# frozen_string_literal: true

# raw_stream pins (I03 Specification, BRIEF §3): the verbatim-body /
# parsed-payloads / no-retry contract, the two-phase watchdog, optional
# auth — live against the gem's own MockLLMServer plus the client_spec
# raw-TCP rigs. Async 2.46 discipline: raise_error matchers sit INSIDE
# the Async do … end block (a top-level task exception is logged and
# swallowed, never re-raised to the caller).
require "fast/completions"
require_relative "../../support/mock_llm_server"

RSpec.describe Fast::Completions::Client, "#raw_stream" do
  let(:server) { MockLLMServer.new.start }

  after { server.stop }

  def client(**overrides)
    described_class.new(base_url: server.url, api_key: "test-key", **overrides)
  end

  # The mock replies with SSE when the request body carries "stream":true
  # — the raw bodies below include it (Tool guidance, verify don't trust).
  it "yields every parsed SSE payload verbatim and in order, DONE sentinel last, returning nil (no accumulation, no Event envelope)" do
    server.script([{type: :stream, content: "ok"}])
    items = []
    returned = nil
    c = client
    Async do
      returned = c.raw_stream({"model" => "m", "stream" => true}) { |item| items << item }
      c.close
    end
    expect(returned).to be_nil
    expect(items).to eq([
      {"choices" => [{"delta" => {"role" => "assistant", "content" => "ok"}}]},
      {"choices" => [{"delta" => {}, "finish_reason" => "stop"}]}, # raw string, no stop-reason mapping
      {"usage" => {"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}},
      Fast::Completions::SSE::DONE,
    ])
  end

  it "forwards a Hash body verbatim: unknown fields survive the round trip untouched" do
    server.script([{type: :stream, content: "ok"}])
    body = {"model" => "m", "stream" => true, "x_experimental" => {"nested" => [1, {"deep" => true}]}}
    c = client
    Async do
      c.raw_stream(body) { |_item| }
      c.close
    end
    expect(server.captured_requests.first).to eq(body)
  end

  it "forwards a String body as the request body verbatim" do
    # The raw-TCP rig (client_spec shape): non-canonical spacing in the
    # hand-written JSON — a re-generated body could never match it
    # byte-for-byte.
    listener = TCPServer.new("127.0.0.1", 0)
    sent = nil
    server_thread = Thread.new do
      io = listener.accept
      head = +""
      while (line = io.gets)
        break if line == "\r\n"

        head << line
      end
      sent = io.read(head[/Content-Length: (\d+)/i, 1].to_i)
      reply = %(data: {"choices":[{"delta":{"role":"assistant"}}]}\n\ndata: [DONE]\n\n)
      io.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
      io.write(format("%x\r\n%s\r\n", reply.bytesize, reply))
      io.write("0\r\n\r\n")
      io.close
    rescue StandardError
      nil
    end
    raw_body = '{"model":"m",   "stream":true}'
    Async do
      c = described_class.new(base_url: "http://127.0.0.1:#{listener.addr[1]}/v1", api_key: "k")
      c.raw_stream(raw_body) { |_item| }
      c.close
    end
    server_thread.join(2)
    listener.close
    expect(sent).to eq(raw_body)
  end

  it "raises the mapped ServerError on a 5xx and makes exactly ONE request (no auto-retry)" do
    server.script([{type: :error, status: 500, message: "boom"}])
    c = client
    Async do
      expect {
        c.raw_stream({"model" => "m", "stream" => true}) { |_item| }
      }.to raise_error(Fast::Completions::ServerError, /500: boom/)
      c.close
    end
    expect(server.captured_request_logs.size).to eq(1)
  end

  it "maps connection refusal to ConnectionError (dead port, single attempt)" do
    dead = described_class.new(base_url: "http://127.0.0.1:1/v1", api_key: "k") # nothing listens on port 1
    Async do
      expect {
        dead.raw_stream({"model" => "m", "stream" => true}) { |_item| }
      }.to raise_error(Fast::Completions::ConnectionError, /Errno::ECONNREFUSED/)
      dead.close
    end
  end

  it "fires the TTFB deadline (per-call knobs, black hole): TimeoutError naming headers, fast" do
    # inactivity_timeout: 10 cross-wires measurably: a swapped arm would
    # wait 10 s, not the 0.15 s TTFB bound (elapsed < 2.0 s discriminates).
    black_hole = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      io = black_hole.accept
      sleep 30 # never reply; the test tears it down
    rescue StandardError
      nil
    end
    silent = described_class.new(base_url: "http://127.0.0.1:#{black_hole.addr[1]}/v1", api_key: "k")
    elapsed = nil
    Async do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect {
        silent.raw_stream({"model" => "m", "stream" => true}, ttfb_timeout: 0.15, inactivity_timeout: 10) { |_item| }
      }.to raise_error(Fast::Completions::TimeoutError, /headers/)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    ensure
      silent.close
      black_hole.close
    end
    expect(elapsed).to be < 2.0
  end

  it "fires the inactivity deadline (client-level split, stall after the first chunk): TimeoutError naming data, fast" do
    # ttfb_timeout: 10 cross-wires measurably: a swapped arm would never
    # fire at the 0.2 s read stall (elapsed < 2.0 s discriminates).
    stall = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      io = stall.accept
      io.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
      io.write("f\r\ndata: {\"x\":1}\n\n\r\n") # one complete SSE event, then nothing
      sleep 30 # never finishes; the test tears it down
    rescue StandardError
      nil
    end
    stalled = described_class.new(base_url: "http://127.0.0.1:#{stall.addr[1]}/v1", api_key: "k",
      ttfb_timeout: 10, inactivity_timeout: 0.2)
    elapsed = nil
    Async do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect {
        stalled.raw_stream({"model" => "m", "stream" => true}) { |_item| }
      }.to raise_error(Fast::Completions::TimeoutError, /data/)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    ensure
      stalled.close
      stall.close
    end
    expect(elapsed).to be < 2.0
  end

  it "re-arms the inactivity deadline per chunk: a slow stream outlives the whole-stream budget and completes" do
    # :slow_stream paces ~1.1 s of 0.1 s gaps (keepalive comments between
    # deltas) — every gap clears the 0.5 s inactivity deadline, but a
    # whole-deadline implementation would fire at 0.5 s.
    server.script([{type: :slow_stream, content: "hello world"}])
    items = []
    c = client(inactivity_timeout: 0.5)
    Async do
      c.raw_stream({"model" => "m", "stream" => true}) { |item| items << item }
      c.close
    end
    expect(items.last).to equal(Fast::Completions::SSE::DONE)
  end

  it "represents prefill-scale deadlines on a fast stream" do
    server.script([{type: :stream, content: "ok"}])
    items = []
    c = client(ttfb_timeout: 1400, inactivity_timeout: 1400) # a whole context window at ~200 tok/s
    Async do
      c.raw_stream({"model" => "m", "stream" => true}) { |item| items << item }
      c.close
    end
    expect(c.ttfb_timeout).to eq(1400)
    expect(c.inactivity_timeout).to eq(1400)
    expect(items.last).to equal(Fast::Completions::SSE::DONE)
  end

  it "falls back to the shared timeout for both phases when no split values are given" do
    black_hole = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      io = black_hole.accept
      sleep 30 # never reply; the test tears it down
    rescue StandardError
      nil
    end
    silent = described_class.new(base_url: "http://127.0.0.1:#{black_hole.addr[1]}/v1", api_key: "k", timeout: 0.15)
    elapsed = nil
    Async do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect {
        silent.raw_stream({"model" => "m", "stream" => true}) { |_item| }
      }.to raise_error(Fast::Completions::TimeoutError, /headers/)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    ensure
      silent.close
      black_hole.close
    end
    expect(elapsed).to be < 2.0
  end

  it "omits the authorization header when api_key is nil or empty" do
    server.script([{type: :stream, content: "ok"}, {type: :stream, content: "ok"}])
    nil_key = described_class.new(base_url: server.url, api_key: nil)
    empty_key = described_class.new(base_url: server.url, api_key: "")
    Async do
      nil_key.raw_stream({"model" => "m", "stream" => true}) { |_item| }
      empty_key.raw_stream({"model" => "m", "stream" => true}) { |_item| }
      nil_key.close
      empty_key.close
    end
    headers = server.captured_request_logs.map { |entry| entry[:headers] }
    expect(headers).not_to be_empty
    headers.each do |captured|
      expect(captured).not_to have_key("authorization")
      expect(captured).to include("content-type" => "application/json", "accept" => "application/json")
    end
  end

  it "drops an unparseable payload after the repair pass, counts it, and keeps streaming" do
    broken = 'data: {"choices":[{"delta":{"content":"x"}}' # truncated, unbalanced braces
    healthy = %(data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n)
    server.script([{type: :stream, raw_frames: [broken + "\n\n", healthy, "data: [DONE]\n\n"]}])
    items = []
    c = client
    Async do
      c.raw_stream({"model" => "m", "stream" => true}) { |item| items << item }
      c.close
    end
    expect(items).to eq([
      {"choices" => [{"delta" => {}, "finish_reason" => "stop"}]},
      Fast::Completions::SSE::DONE,
    ])
    expect(c.dropped_chunks).to eq(1)
  end

  it "validates the deadline knobs: positive Numeric or ArgumentError" do
    expect { described_class.new(base_url: "http://127.0.0.1:1/v1", api_key: "k", ttfb_timeout: 0) }
      .to raise_error(ArgumentError, /ttfb_timeout must be a positive Numeric/)
    expect { described_class.new(base_url: "http://127.0.0.1:1/v1", api_key: "k", inactivity_timeout: -1) }
      .to raise_error(ArgumentError, /inactivity_timeout must be a positive Numeric/)
    c = described_class.new(base_url: "http://127.0.0.1:1/v1", api_key: "k") # valid knobs never touch the wire
    expect { c.raw_stream({"stream" => true}, ttfb_timeout: "5") { |_item| } }
      .to raise_error(ArgumentError, /ttfb_timeout must be a positive Numeric/)
    expect { c.raw_stream({"stream" => true}, inactivity_timeout: -0.5) { |_item| } }
      .to raise_error(ArgumentError, /inactivity_timeout must be a positive Numeric/)
    expect(server.captured_request_logs).to be_empty
  end

  it "raises CancelledError, not TimeoutError, when the user cancels mid-stream (D8)" do
    # Dedicated reactor (stream_cancel_spec pattern): the sibling fiber
    # cancels the task AFTER the first payload (a Queue handshake, not a
    # sleep race); the outcome is asserted outside the block.
    server.script([{type: :slow_stream, content: "0123456789"}])
    payloads = Queue.new
    outcome = Thread.new do
      Async do |task|
        task.async do # the sibling fiber
          payloads.pop # wait for the first payload
          task.cancel
        end
        c = described_class.new(base_url: server.url, api_key: "k")
        begin
          c.raw_stream({"model" => "m", "stream" => true}) { |item| payloads << item }
          :no_raise
        rescue Fast::Completions::CancelledError
          :cancelled
        rescue Fast::Completions::TimeoutError
          :timeout
        end
      end.wait # .wait: the block's value (Async itself returns the Task)
    end.value
    expect(outcome).to eq(:cancelled)
  end
end
