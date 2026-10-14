# frozen_string_literal: true

# THE CONCURRENCY PINS (Specification §1.2): a tool batch runs its
# executable calls CONCURRENTLY (one reactor child per call — pi's
# executeToolCallsParallel shape, tart I52 mechanics): execution windows
# overlap (span < 0.9 s — the I50 bound), tool-result Messages append in
# CALL order regardless of completion order, after hooks fire per-child
# in COMPLETION order, one call's raise isolates into ITS error result
# (siblings unaffected, the join completes), and unknown tools finalize
# INLINE in call order with the exact today-bytes (no child task).
require "fast/completions"
require_relative "../../support/mock_llm_server"

RSpec.describe Fast::Completions::Chat do
  let(:server) { MockLLMServer.new.start }
  let(:model) do
    Fast::Completions::Model.new(id: "mock-model", reasoning: false, context_window: 128_000,
      max_tokens: 64, dialect: :fireworks)
  end

  after { server.stop }

  def client
    @client ||= Fast::Completions::Client.new(base_url: server.url, api_key: "test-key")
  end

  it "overlaps two 0.5 s sleep-tools in one batch (span < 0.9 s — the I50 bound)" do
    server.script([{type: :stream, content: "", tool_calls: [
      {id: "c1", name: "slow", arguments: {}}, {id: "c2", name: "slow", arguments: {}},
    ]}, {type: :stream, content: "ok"}])
    entries = []
    exits = []
    tool = Class.new(Fast::Completions::Tool) do
      tool_name "slow"
      parameters { {"type" => "object", "properties" => {}} }
      # Kernel#sleep inside execute is scheduler-interruptible under the
      # reactor — the child fiber yields and its sibling runs.
      define_method(:execute) do
        entries << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sleep 0.5
        exits << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        "slow"
      end
    end
    chat = described_class.new(client: client, model: model).with_tools(tool)

    Async do
      chat.step
      client.close
    end

    expect(entries.max).to be < exits.min # windows OVERLAP (serial: entry₂ == exit₁)
    expect(exits.max - entries.min).to be < 0.9 # concurrent ≈ 0.5 s; serial ≈ 1.0 s
    expect(chat.messages.select(&:tool_result?).map(&:tool_call_id)).to eq(%w[c1 c2]) # both land
  end

  it "appends results in CALL order under inverted completion; after hooks fire in completion order" do
    server.script([{type: :stream, content: "", tool_calls: [
      {id: "c1", name: "slow", arguments: {"seconds" => 0.5}},
      {id: "c2", name: "slow", arguments: {"seconds" => 0.2}},
    ]}, {type: :stream, content: "ok"}])
    tool = Class.new(Fast::Completions::Tool) do
      tool_name "slow"
      parameters { {"type" => "object", "properties" => {"seconds" => {"type" => "number"}}} }
      define_method(:execute) { |seconds:| sleep seconds; "slept #{seconds}" }
    end
    chat = described_class.new(client: client, model: model).with_tools(tool)
    before_ids = []
    after_ids = []
    chat.before_tool_call { |tool_call| before_ids << tool_call[:id] }
    chat.after_tool_result { |tool_call, _result| after_ids << tool_call[:id] }

    Async do
      chat.step
      client.close
    end

    expect(before_ids).to eq(%w[c1 c2]) # before hooks: the serial before-phase, call order
    expect(after_ids).to eq(%w[c2 c1]) # after hooks: per-child, COMPLETION order
    # history: CALL order (index-keyed collection), never completion order
    expect(chat.messages.select(&:tool_result?).map(&:tool_call_id)).to eq(%w[c1 c2])
  end

  it "isolates a raised StandardError into that call's error result; the sibling completes" do
    server.script([{type: :stream, content: "", tool_calls: [
      {id: "c1", name: "mixed", arguments: {"boom" => true}},
      {id: "c2", name: "mixed", arguments: {}},
    ]}, {type: :stream, content: "ok"}])
    tool = Class.new(Fast::Completions::Tool) do
      tool_name "mixed"
      parameters { {"type" => "object", "properties" => {}} }
      define_method(:execute) do |boom: false|
        raise "boom" if boom

        sleep 0.2
        "clean"
      end
    end
    chat = described_class.new(client: client, model: model).with_tools(tool)

    Async do
      expect { chat.step }.not_to raise_error # the join completes (at base the raise escapes step)
      client.close
    end

    results = chat.messages.select(&:tool_result?)
    expect(results.map(&:tool_call_id)).to eq(%w[c1 c2]) # both appended, call order
    expect(results[0].is_error).to be(true)
    expect(results[0].content).to eq("boom") # exactly e.message
    expect(results[1].is_error).to be(false)
    expect(results[1].content).to eq("clean")
  end

  it "finalizes an unknown tool INLINE in a multi-call batch, in call order" do
    server.script([{type: :stream, content: "", tool_calls: [
      {id: "c1", name: "read", arguments: {"path" => "a"}},
      {id: "c2", name: "nope", arguments: {}},
    ]}, {type: :stream, content: "ok"}])
    reader = Class.new(Fast::Completions::Tool) do
      tool_name "read"
      parameters { {"type" => "object", "properties" => {"path" => {"type" => "string"}}} }
      define_method(:execute) { |path:| "contents of #{path}" }
    end
    chat = described_class.new(client: client, model: model).with_tools(reader)
    before_ids = []
    after_ids = []
    chat.before_tool_call { |tool_call| before_ids << tool_call[:id] }
    chat.after_tool_result { |tool_call, _result| after_ids << tool_call[:id] }

    Async do
      chat.step
      client.close
    end

    results = chat.messages.select(&:tool_result?)
    expect(results.map(&:tool_call_id)).to eq(%w[c1 c2])
    expect(results[1].is_error).to be(true)
    expect(results[1].content).to eq("no such tool: nope") # the exact today-bytes
    expect(results[0].content).to eq("contents of a")
    expect(before_ids).to eq(%w[c1 c2]) # hooks fire for unknown tools too (gem continuity)
    expect(after_ids).to eq(%w[c1])
  end
end
