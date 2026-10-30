# frozen_string_literal: true

# Telemetry pins (I01): the Telemetry::Sink hook matrix against the gem's
# MockLLMServer — every scenario asserts the frozen terminal invariant
# (exactly one on_completion_start, then exactly one of
# on_completion_end / on_completion_error) — plus the three measurement
# gates (I04 hardened form): allocation gross-regression ceiling (PIN),
# no-op-sink differential with median-quantization tolerance (|Δ| ≤ 1),
# and the clock-read differential against the four sanctioned
# instrumentation reads (Δ == 4).
require "fast/completions"
require_relative "../../support/mock_llm_server"
require_relative "../../support/recording_sink"

RSpec.describe "telemetry sink interface (I01)" do
  # Gate 3's spy: an allocation-free prepend on Process.clock_gettime,
  # defined ONCE at file load so every later measured window (any spec,
  # any random order) sees the same wrapper. The optional-arg signature
  # (no splat) keeps the wrapper allocation-free — a splat would allocate
  # inside other specs' measured windows. Explicit super args: bare super
  # from define_method is not allowed.
  CLOCK_SPY_COUNT = [0]

  Process.singleton_class.prepend(Module.new do
    define_method(:clock_gettime) do |clock, unit = nil|
      CLOCK_SPY_COUNT[0] += 1
      unit ? super(clock, unit) : super(clock)
    end
  end)

  # Provenance for the pins (I04 re-measurement): the canonical recipe —
  # one MockLLMServer with pace! (the ~10ms opt-in inter-chunk gap) on a
  # ≥ 20 entry {type: :stream, content: "Hello"} script, TCP_NODELAY +
  # declared Connection: close on the mock (the I04 honesty port), model
  # mock-model/:fireworks, ONE Message.user("hi"), ONE Client per phase,
  # a discarding consumer block, one Async block, 3 warmups per client,
  # 15 measured GC-stat-delta runs per client INTERLEAVED in the same
  # window, MEDIAN aggregate — measured at freeze with the shipped lib
  # of main @ 42088b5 (lib/ untouched by I04), this repo's Gemfile.lock,
  # ruby 4.0.9 arm64-darwin25:
  # zero-sink median 685, no-op-sink median 685 (|Δ| = 0 every run;
  # pacing makes the client-visible chunk count deterministic, so the
  # per-completion allocation count is a constant — the unpaced regime
  # drifted ±1-2 between coalesced-chunk outcomes). PIN headroom: the
  # ceiling is a GROSS-regression tripwire (a double-digit jump from a
  # wire change), deliberately generous — ±1 sensitivity is the
  # paired-measurement discipline's job, not this suite's.
  # STANDING CALIBRATION RISK, named in-file (I04): CI (.github/workflows/
  # ci.yml) runs this suite on ubuntu-latest × ruby {3.3, 3.4, 4.0} on
  # every push/PR — a regime these darwin-measured numbers were never
  # calibrated against. If a CI leg trips a pin here, re-measure on that
  # regime before touching anything: the pin, not the code, is the
  # suspect first.
  ALLOCATION_PIN = 730  # darwin-measured 685; ceiling for the CI matrix regimes

  let(:server) { MockLLMServer.new.start }
  let(:model) do
    Fast::Completions::Model.new(id: "mock-model", reasoning: false, context_window: 128_000,
      max_tokens: 64, dialect: :fireworks)
  end
  let(:message) { Fast::Completions::Message.user("hi") }
  let(:messages) { [message] }

  after { server.stop }

  def client(telemetry: [])
    Fast::Completions::Client.new(base_url: server.url, api_key: "test-key", telemetry: telemetry)
  end

  # The frozen terminal invariant (I01): exactly one start, then exactly
  # one terminal. Asserted in EVERY scenario.
  def expect_terminal_invariant(sink)
    expect(sink.starts.size).to eq(1)
    expect(sink.ends.size + sink.errors.size).to eq(1)
  end

  # The frozen ordering rule: for each event, the sink entry precedes its
  # consumer twin on the shared interleaved timeline (k-th sink event
  # before the k-th consumer event).
  def expect_sink_precedes_consumer(timeline)
    sink_positions = []
    consumer_positions = []
    timeline.each_with_index do |entry, index|
      sink_positions << index if entry[0] == :sink && entry[1] == :on_event
      consumer_positions << index if entry[0] == :consumer
    end
    expect(consumer_positions).not_to be_empty
    expect(sink_positions.size).to eq(consumer_positions.size)
    expect(sink_positions.zip(consumer_positions).all? { |s, c| s < c }).to be(true)
  end

  it "happy path: start → :start → ttfb → text events → :done → end(:stop), refs and Floats pinned" do
    server.script([{type: :stream, content: "Hello"}])
    sink = RecordingSink.new
    consumer_partials = []
    c = client(telemetry: [sink])
    Async do
      c.stream(model: model, messages: messages) do |event|
        sink.timeline << [:consumer, event.type]
        consumer_partials << event.partial
      end
      c.close
    end
    expect_terminal_invariant(sink)
    expect(sink.hooks).to eq(
      [:on_completion_start, :on_event, :on_completion_ttfb, :on_event, :on_event, :on_event, :on_event, :on_completion_end]
    )
    expect(sink.event_types).to eq([:start, :text_start, :text_delta, :text_end, :done])
    expect_sink_precedes_consumer(sink.timeline)

    expect(sink.starts.first[0]).to equal(model.id) # the Model#id String REF, never a copy
    expected_body = JSON.generate(Fast::Completions::Protocol.build_request(
      model: model, messages: messages, instructions: nil, tools: [], thinking: nil,
      max_tokens: nil, temperature: nil))
    expect(sink.starts.first[1]).to eq(expected_body.bytesize) # the Integer bytesize of the POSTed body

    ttfb = sink.ttfs.first
    stop_reason, duration, end_message = sink.ends.first
    expect(ttfb).to be_a(Float)
    expect(duration).to be_a(Float)
    expect(ttfb).to be > 0
    expect(ttfb).to be <= duration
    expect(stop_reason).to eq(:stop)
    # Every ref the consumer ever saw — each event's partial (block
    # events) or message (the :done terminal) — IS the live accumulator
    # Message the end hook received.
    consumer_refs = consumer_partials.compact
    expect(end_message).to equal(consumer_refs.first) # the LIVE accumulator Message
    expect(consumer_refs.all? { |ref| ref.equal?(end_message) }).to be(true)
  end

  it "tool-call completion: :tool_call_* events present, end(:tool_use)" do
    server.script([{type: :stream, tool_calls: [{id: "c1", name: "read", arguments: {"path" => "a"}}]}])
    sink = RecordingSink.new
    c = client(telemetry: [sink])
    Async do
      c.stream(model: model, messages: messages) { |_event| }
      c.close
    end
    expect_terminal_invariant(sink)
    expect(sink.event_types).to eq([:start, :tool_call_start, :tool_call_delta, :tool_call_delta, :tool_call_end, :done])
    expect(sink.ends.first[0]).to eq(:tool_use)
  end

  it "retry then success: ONE start, ONE ttfb, ONE end across exactly 2 requests; no error hooks" do
    server.script([{type: :error, status: 429, message: "slow down"}, {type: :stream, content: "recovered"}])
    sink = RecordingSink.new
    c = client(telemetry: [sink])
    Async do
      c.stream(model: model, messages: messages) { |_event| }
      c.close
    end
    expect(server.captured_requests.size).to eq(2)
    expect_terminal_invariant(sink)
    expect(sink.starts.size).to eq(1)
    expect(sink.ttfs.size).to eq(1) # the retried attempt's clock restarted
    expect(sink.errors).to be_empty
    expect(sink.ends.first[0]).to eq(:stop)
  end

  it "failed creation: start → :error event (EMPTY partial, no :start event) → error(:rate_limit_error)" do
    server.script([
      {type: :error, status: 429, message: "slow down"},
      {type: :error, status: 429, message: "still slow"},
    ])
    sink = RecordingSink.new
    c = client(telemetry: [sink])
    Async do
      expect { c.stream(model: model, messages: messages) { |_event| } }
        .to raise_error(Fast::Completions::RateLimitError)
      c.close
    end
    expect_terminal_invariant(sink)
    expect(sink.event_types).to eq([:error])
    expect(sink.events.first.message.content).to eq([]) # the empty accumulator
    expect(sink.ttfs).to be_empty
    expect(sink.ends).to be_empty
    expect(sink.errors.first[0]).to eq(:rate_limit_error)
    expect(sink.errors.first[1]).to be_a(Float)
  end

  it "mid-stream abort (salvage): …text events… → :error (streamed content + usage 15) → error(:connection_error); NO end" do
    server.script([{type: :stream, abort: true, chunks: [
      {choices: [{delta: {role: "assistant", content: "Hel"}}]},
      {choices: [{delta: {content: "lo"}}]},
      {usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}},
      {choices: [{delta: {content: "!"}}]},
    ]}])
    sink = RecordingSink.new
    c = client(telemetry: [sink])
    Async do
      expect { c.stream(model: model, messages: messages) { |_event| } }
        .to raise_error(Fast::Completions::ConnectionError)
      c.close
    end
    expect_terminal_invariant(sink)
    expect(sink.event_types).to eq([:start, :text_start, :text_delta, :text_delta, :text_delta, :error])
    salvaged = sink.events.last.message
    expect(salvaged.content).to eq([{type: :text, text: "Hello!"}])
    expect(salvaged.usage.total_tokens).to eq(15)
    expect(sink.ends).to be_empty
    expect(sink.errors.first[0]).to eq(:connection_error)
  end

  it "missing finish: :error terminal → error(:stream_error); NO end" do
    server.script([{type: :stream, raw_frames: [
      %(data: {"choices":[{"delta":{"content":"x"}}]}\n\n),
      "data: [DONE]\n\n",
    ]}])
    sink = RecordingSink.new
    c = client(telemetry: [sink])
    Async do
      expect { c.stream(model: model, messages: messages) { |_event| } }
        .to raise_error(Fast::Completions::StreamError)
      c.close
    end
    expect_terminal_invariant(sink)
    expect(sink.event_types).to eq([:start, :text_start, :text_delta, :text_end, :error])
    expect(sink.ends).to be_empty
    expect(sink.errors.first[0]).to eq(:stream_error)
  end

  it "TTFB black hole: start → :error (empty partial — the salvage terminal) → error(:timeout_error); NO ttfb, NO payload events" do
    # The creation-exhaustion watchdog TimeoutError raises from inside
    # create_response into stream's StandardError arm, so the frozen
    # salvage semantics apply: the sink sees the :error terminal (empty
    # accumulator, no :start) before error(:timeout_error).
    black_hole = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      io = black_hole.accept
      sleep 30 # never reply; the test tears it down
    rescue StandardError
      nil
    end
    sink = RecordingSink.new
    silent = Fast::Completions::Client.new(
      base_url: "http://127.0.0.1:#{black_hole.addr[1]}/v1", api_key: "k",
      timeout: 0.15, telemetry: [sink])
    Async do
      expect { silent.stream(model: model, messages: messages) { |_event| } }
        .to raise_error(Fast::Completions::TimeoutError)
    ensure
      silent.close
      black_hole.close
    end
    expect_terminal_invariant(sink)
    expect(sink.ttfs).to be_empty # nothing ever yielded
    expect(sink.event_types).to eq([:error]) # the salvage terminal only — no :start, no payload events
    expect(sink.events.first.message.content).to eq([])
    expect(sink.ends).to be_empty
    expect(sink.errors.first[0]).to eq(:timeout_error)
  end

  it "mid-stream read inactivity: :start → ttfb → error(:timeout_error); NO :error event (the cancel-arm discipline)" do
    stall = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      io = stall.accept
      io.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
      io.write("f\r\ndata: {\"x\":1}\n\n\r\n") # one complete SSE event, then nothing
      sleep 30 # never finishes; the test tears it down
    rescue StandardError
      nil
    end
    sink = RecordingSink.new
    stalled = Fast::Completions::Client.new(
      base_url: "http://127.0.0.1:#{stall.addr[1]}/v1", api_key: "k",
      timeout: 0.2, telemetry: [sink])
    Async do
      expect { stalled.stream(model: model, messages: messages) { |_event| } }
        .to raise_error(Fast::Completions::TimeoutError)
    ensure
      stalled.close
      stall.close
    end
    expect_terminal_invariant(sink)
    expect(sink.ttfs.size).to eq(1) # the first item arrived (it derived no events)
    expect(sink.event_types).to eq([:start]) # no :error — the Async::Cancel arm never salvages
    expect(sink.ends).to be_empty
    expect(sink.errors.first[0]).to eq(:timeout_error)
  end

  it "cancellation: …deltas… → error(:cancelled_error); NO terminal events" do
    server.script([{type: :slow_stream, content: "0123456789"}])
    sink = RecordingSink.new
    c = Fast::Completions::Client.new(base_url: server.url, api_key: "test-key", telemetry: [sink])
    chat = Fast::Completions::Chat.new(client: c, model: model)
    deltas = Queue.new
    outcome = nil
    Async do |task|
      task.async do # the sibling fiber cancels after the FIRST delta
        deltas.pop until deltas.pop == :text_delta
        chat.cancel
      end
      begin
        chat.step { |event| deltas << event.type if event.type == :text_delta }
        outcome = :returned
      rescue Fast::Completions::CancelledError
        outcome = :cancelled
      end
      c.close
    end
    expect(outcome).to eq(:cancelled)
    expect_terminal_invariant(sink)
    expect(sink.event_types.first).to eq(:start)
    expect(sink.event_types).to include(:text_delta)
    expect(sink.event_types).not_to include(:done, :error) # no terminal Event (AC3)
    expect(sink.ttfs.size).to eq(1)
    expect(sink.ends).to be_empty
    expect(sink.errors.first[0]).to eq(:cancelled_error)
  end

  it "raising consumer block: the record stays complete — salvage :error + error(:runtime_error); the sink saw strictly more events" do
    server.script([{type: :stream, content: "Hello"}])
    sink = RecordingSink.new
    consumer_types = []
    c = client(telemetry: [sink])
    Async do
      expect {
        c.stream(model: model, messages: messages) do |event|
          sink.timeline << [:consumer, event.type]
          raise "boom" if event.type == :text_delta # raise ON the delta, before recording it
          consumer_types << event.type
        end
      }.to raise_error(RuntimeError, /boom/)
      c.close
    end
    expect_terminal_invariant(sink)
    expect(consumer_types).to eq([:start, :text_start, :error]) # the delta that raised was never recorded; the salvage :error still reached the block
    expect(sink.event_types).to eq([:start, :text_start, :text_delta, :error]) # complete through the salvage terminal
    expect(sink.events.size).to be > consumer_types.size
    expect_sink_precedes_consumer(sink.timeline)
    expect(sink.ends).to be_empty
    expect(sink.errors.first[0]).to eq(:runtime_error)
  end

  it "raising consumer block ON the salvage :error: the record still closes exactly once — error(:runtime_error), not :connection_error" do
    server.script([{type: :stream, abort: true, chunks: [
      {choices: [{delta: {role: "assistant", content: "Hel"}}]},
    ]}])
    sink = RecordingSink.new
    c = client(telemetry: [sink])
    Async do
      expect {
        c.stream(model: model, messages: messages) do |event|
          raise "boom" if event.type == :error # raise ON the salvage terminal — inside a rescue arm
        end
      }.to raise_error(RuntimeError, /boom/)
      c.close
    end
    expect_terminal_invariant(sink)
    expect(sink.event_types).to eq([:start, :text_start, :text_delta, :error]) # the salvage :error reached the sink first
    expect(sink.ends).to be_empty
    expect(sink.errors.size).to eq(1)
    expect(sink.errors.first[0]).to eq(:runtime_error) # the raiser's symbol — the ConnectionError never raised
  end

  it "raising consumer block ON :done: on_completion_end never fires; the record closes with error(:runtime_error)" do
    server.script([{type: :stream, content: "Hello"}])
    sink = RecordingSink.new
    c = client(telemetry: [sink])
    Async do
      expect {
        c.stream(model: model, messages: messages) do |event|
          raise "boom" if event.type == :done
        end
      }.to raise_error(RuntimeError, /boom/)
      c.close
    end
    expect_terminal_invariant(sink)
    expect(sink.event_types).to eq([:start, :text_start, :text_delta, :text_end, :done]) # the sink saw :done; the consumer rejected it
    expect(sink.ends).to be_empty # stream never returned — end fires only on a return
    expect(sink.errors.first[0]).to eq(:runtime_error)
  end

  it "two registered sinks: identical records; sink-1 dispatch precedes sink-2 at every call site" do
    server.script([{type: :stream, content: "Hello"}])
    timeline = []
    sink_one = RecordingSink.new(timeline: timeline, tag: :sink_one)
    sink_two = RecordingSink.new(timeline: timeline, tag: :sink_two)
    c = client(telemetry: [sink_one, sink_two])
    Async do
      c.stream(model: model, messages: messages) { |_event| }
      c.close
    end
    expect_terminal_invariant(sink_one)
    expect_terminal_invariant(sink_two)
    expect(sink_one.starts).to eq(sink_two.starts)
    expect(sink_one.ttfs).to eq(sink_two.ttfs) # one shared flonum per call site
    expect(sink_one.event_types).to eq(sink_two.event_types)
    expect(sink_one.ends).to eq(sink_two.ends)
    first = timeline.each_with_index.filter_map { |entry, i| i if entry[0] == :sink_one }
    second = timeline.each_with_index.filter_map { |entry, i| i if entry[0] == :sink_two }
    expect(first).not_to be_empty
    expect(first.zip(second).all? { |a, b| a < b }).to be(true)
  end

  it "blockless call with one sink: the full event record + end" do
    server.script([{type: :stream, content: "Hello"}])
    sink = RecordingSink.new
    c = client(telemetry: [sink])
    Async do
      c.stream(model: model, messages: messages) # NO consumer block
      c.close
    end
    expect_terminal_invariant(sink)
    expect(sink.hooks).to include(:on_completion_start, :on_completion_ttfb, :on_completion_end)
    expect(sink.event_types).to eq([:start, :text_start, :text_delta, :text_end, :done])
    expect(sink.ttfs.size).to eq(1)
    expect(sink.ends.first[0]).to eq(:stop)
  end

  describe "registration validation" do
    it "rejects a non-Enumerable telemetry:" do
      expect { client(telemetry: RecordingSink.new) }
        .to raise_error(ArgumentError, /Enumerable/)
    end

    it "rejects a sink missing a hook, naming the sink and the hook" do
      half = HalfSink.new
      expect { client(telemetry: [half]) }
        .to raise_error(ArgumentError, /HalfSink.*on_event|on_event.*HalfSink/)
    end

    it "accepts a duck-typed sink (no module inclusion) and dispatches to it; the caller's array is never frozen" do
      log = []
      duck = DuckSink.new(log)
      caller_array = [duck]
      c = Fast::Completions::Client.new(base_url: server.url, api_key: "test-key", telemetry: caller_array)
      expect(caller_array).not_to be_frozen
      server.script([{type: :stream, content: "Hello"}])
      Async do
        c.stream(model: model, messages: messages) { |_event| }
        c.close
      end
      expect(log).to eq([:start_hook, :start, :ttfb_hook, :text_start, :text_delta, :text_end, :done, :end_hook])
    end

    it "accepts any Enumerable of sinks (a Set), freezing only its own copy" do
      sink = RecordingSink.new
      caller_set = Set[sink]
      c = client(telemetry: caller_set)
      expect(caller_set).not_to be_frozen
      server.script([{type: :stream, content: "Hello"}])
      Async do
        c.stream(model: model, messages: messages) { |_event| }
        c.close
      end
      expect_terminal_invariant(sink)
      expect(sink.hooks).to include(:on_completion_start, :on_completion_end)
    end
  end

  # ── The three measurement gates (I01; I04 hardened form) ──────────
  # Canonical recipe: one MockLLMServer; a ≥ 20 entry {type: :stream,
  # content: "Hello"} script; model mock-model/:fireworks (128_000 /
  # 64); ONE Message.user("hi"); a discarding consumer block; everything
  # inside ONE Async block; THREE warmups per client (runs 1-2 cost
  # 1463/710 — one-time paths; warmup is mandatory), then FIFTEEN
  # measured completions per client, each bracketed by its own
  # GC.stat(:total_allocated_objects) read; the aggregate is the MEDIAN
  # of the 15 (house allocations(times) convention — median, not mean:
  # a rare one-off spike would move a mean, never the median of 15).
  # The two clients' measured runs INTERLEAVE and the assertion runs on
  # PER-ITERATION PAIRED DELTAS (no-op minus zero, median of the 15
  # pairs): under scheduler heat the client fiber can starve past a 10ms
  # paced gap and two frames arrive as one read — a whole read-cycle
  # bundle (~16 objects, ~4 clock reads) vanishes from ONE side of ONE
  # pair (observed in-suite, ~1 run in 8 hot). Pairing plus the median
  # makes the aggregate immune (a median moves only when ≥ 8 of 15
  # pairs are polluted); a real telemetry-added allocation or clock read
  # shifts EVERY pair together and still fails. The interleaving keeps
  # adjacent pairs in the same thermal/scheduling regime.
  it "gate 1 + gate 2: zero-sink median <= PIN (gross-regression tripwire), no-op sink |median delta| <= 1 (same run)", :measurement do
    server.pace!
    server.script(Array.new(40) { {type: :stream, content: "Hello"} })
    plain = Fast::Completions::Client.new(base_url: server.url, api_key: "test-key")
    # A fresh allocation-free no-op sink, constructed once for this example.
    noop_sink = Class.new { include Fast::Completions::Telemetry::Sink }.new
    instrumented = Fast::Completions::Client.new(base_url: server.url, api_key: "test-key",
      telemetry: [noop_sink])

    zero_deltas = []
    no_op_deltas = []
    Async do
      3.times { plain.stream(model: model, messages: messages) { |_event| } }
      3.times { instrumented.stream(model: model, messages: messages) { |_event| } }
      15.times do
        before = GC.stat(:total_allocated_objects)
        plain.stream(model: model, messages: messages) { |_event| }
        zero_deltas << GC.stat(:total_allocated_objects) - before
        before = GC.stat(:total_allocated_objects)
        instrumented.stream(model: model, messages: messages) { |_event| }
        no_op_deltas << GC.stat(:total_allocated_objects) - before
      end
      plain.close
      instrumented.close
    end

    zero_sink_median = zero_deltas.sort[7]
    pair_deltas = zero_deltas.zip(no_op_deltas).map { |z, n| n - z }
    expect(zero_sink_median).to be <= ALLOCATION_PIN
    # No-op-sink overhead derivation (I04, paired-differential form): the
    # no-op sink's five hooks are empty method calls — zero allocations by
    # construction — so under a fixed read granularity every pair lands on
    # the same constant (measured 685/685 at freeze). The residual hazard
    # is receiver-side frame coalescing: under scheduler heat the client
    # fiber can fail to poll for >10ms and two paced frames arrive as ONE
    # read — one fewer watchdog arm per coalesced frame, a ~16-object
    # bundle — and it lands on ONE side of ONE pair (observed once as a
    # |Δ| of 16 between per-side medians in a hot suite run). Pairing
    # makes the aggregate immune: a polluted pair shifts by its whole
    # bundle, but the MEDIAN of 15 paired deltas moves only when ≥ 8
    # pairs are polluted (P ≈ 1e-4 at the observed per-completion rate) —
    # any real per-hook allocation shifts ALL 15 pairs together and
    # still fails. |median| <= 1 absorbs median quantization only.
    expect(pair_deltas.sort[7].abs).to be <= 1
  end

  it "gate 3: telemetry adds ZERO clock reads beyond the four sanctioned instrumentation reads (differential, same run)", :measurement do
    server.pace!
    server.script(Array.new(40) { {type: :stream, content: "Hello"} })
    plain = Fast::Completions::Client.new(base_url: server.url, api_key: "test-key")
    noop_sink = Class.new { include Fast::Completions::Telemetry::Sink }.new
    instrumented = Fast::Completions::Client.new(base_url: server.url, api_key: "test-key",
      telemetry: [noop_sink])

    zero_clock_deltas = []
    no_op_clock_deltas = []
    Async do
      3.times { plain.stream(model: model, messages: messages) { |_event| } }
      3.times { instrumented.stream(model: model, messages: messages) { |_event| } }
      15.times do
        before = CLOCK_SPY_COUNT[0]
        plain.stream(model: model, messages: messages) { |_event| }
        zero_clock_deltas << CLOCK_SPY_COUNT[0] - before
        before = CLOCK_SPY_COUNT[0]
        instrumented.stream(model: model, messages: messages) { |_event| }
        no_op_clock_deltas << CLOCK_SPY_COUNT[0] - before
      end
      plain.close
      instrumented.close
    end

    # Differential derivation (I04, paired-differential form): under a
    # fixed read granularity both sides see the identical async/async-http
    # internal read count, so every clock read in the no-op-sink window
    # that is NOT in the zero-sink window is a read TELEMETRY ADDED. The
    # sanctioned set is exactly four per completion, all
    # @telemetry_active-gated in client.rb: the completion-start clock
    # (notify_start), the per-attempt POST clock (create_response), the
    # TTFB clock (feed_stream), and the terminal duration clock
    # (notify_end / notify_error). Measured at freeze: zero-sink 73,
    # no-op-sink 77, every pair Δ = 4. Residual hazard (observed once in
    # a hot suite run as a per-side-median Δ of 0): receiver-side frame
    # coalescing under scheduler heat removes a ~4-read bundle from ONE
    # side of ONE pair — pairing plus the median of 15 makes the
    # aggregate immune (a shift needs ≥ 8 polluted pairs); any regime
    # shift moves BOTH sides of every pair and cancels. Any
    # telemetry-adjacent change that adds a fifth read shifts every pair
    # to 5 and fails.
    clock_pair_deltas = zero_clock_deltas.zip(no_op_clock_deltas).map { |z, n| n - z }
    expect(clock_pair_deltas.sort[7]).to eq(4)
  end

  # A sink defining only four of the five hooks (missing on_event) —
  # named, so the ArgumentError pin can assert the sink is named.
  HalfSink = Class.new do
    def on_completion_start(model_id, request_bytes); end

    def on_completion_ttfb(seconds); end

    def on_completion_end(stop_reason, duration, message); end

    def on_completion_error(error, duration); end
  end

  # A full duck-typed sink: responds to all five, includes nothing.
  DuckSink = Class.new do
    def initialize(log)
      @log = log
    end

    def on_completion_start(model_id, request_bytes)
      @log << :start_hook
    end

    def on_completion_ttfb(seconds)
      @log << :ttfb_hook
    end

    def on_event(event)
      @log << event.type
    end

    def on_completion_end(stop_reason, duration, message)
      @log << :end_hook
    end

    def on_completion_error(error, duration)
      @log << :error_hook
    end
  end
end
