# frozen_string_literal: true

# THE BATCH CANCEL PINS (Specification §1.3, I51 D8 extended to the
# batch): a cancel during the join aborts the in-flight children —
# CancelledError surfaces fast (≤ 0.2 s — the I52 bound) with NO phantom
# terminals (zero tool-result Messages, zero after-hook fires, no
# :error/:done after the cancel); a cancel latched by a before hook
# stops the batch at the next phase checkpoint before ANY tool executes.
require "fast/completions"
require_relative "../../support/mock_llm_server"

RSpec.describe "batch cancel discipline" do
  let(:server) { MockLLMServer.new.start }
  let(:model) do
    Fast::Completions::Model.new(id: "mock-model", reasoning: false, context_window: 128_000,
      max_tokens: 64, dialect: :fireworks)
  end

  after { server.stop }

  def client
    @client ||= Fast::Completions::Client.new(base_url: server.url, api_key: "test-key")
  end

  # The turn runs in a DEDICATED thread + reactor (the stream_cancel_spec
  # idiom); the sibling fiber (same reactor) waits for the FIRST tool's
  # entry signal (a Queue handshake — no sleep race), settles 0.05 s (both
  # children provably in flight — they enter within the first scheduler
  # tick), then cancels. The cancelled reactor is left WITHOUT a
  # client.close (the stream_cancel_spec precedent — close may await
  # inside a cancelled task); the example tears the server down in after.
  def cancelled_batch
    server.script([{type: :stream, content: "", tool_calls: [
      {id: "c1", name: "slow", arguments: {"tag" => "c1"}},
      {id: "c2", name: "slow", arguments: {"tag" => "c2"}},
    ]}])
    chat = Fast::Completions::Chat.new(client: client, model: model)
    entered_ids = []
    signals = Queue.new
    after_ids = []
    chat.after_tool_result { |tool_call, _result| after_ids << tool_call[:id] }
    tool = Class.new(Fast::Completions::Tool) do
      tool_name "slow"
      parameters { {"type" => "object", "properties" => {"tag" => {"type" => "string"}}} }
      define_method(:execute) do |tag:|
        entered_ids << tag # BOTH entries are the RED discriminator (at base c2 never enters)
        signals << tag # the handshake: the sibling waits for the FIRST
        sleep 0.5
        "slow #{tag}"
      end
    end
    chat.with_tools(tool)

    events = []
    evidence = {}
    Thread.new do
      Async do |task|
        task.async do # the sibling fiber
          signals.pop # the FIRST entry signal
          sleep 0.05 # settle: both children in flight
          evidence[:cancel_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          chat.cancel
        end
        begin
          chat.step { |event| events << event.type }
          evidence[:outcome] = :no_raise
        rescue Fast::Completions::CancelledError
          evidence[:outcome] = :cancelled
        ensure
          evidence[:raised_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end.wait
    end.value
    evidence[:entered] = entered_ids
    evidence[:after] = after_ids
    evidence[:events] = events
    evidence[:chat] = chat
    evidence
  end

  it "a cancel during the join aborts BOTH in-flight children fast — no phantom terminals" do
    evidence = cancelled_batch

    expect(evidence[:outcome]).to eq(:cancelled)
    expect(evidence[:entered]).to eq(%w[c1 c2]) # BOTH entered (at base: c2 never enters — RED)
    expect(evidence[:raised_at] - evidence[:cancel_at]).to be <= 0.2 # abort ≪ natural completion (~0.45 s away — the I52 bound)
    expect(evidence[:chat].messages.select(&:tool_result?)).to be_empty # ZERO tool-result Messages
    expect(evidence[:after]).to be_empty # ZERO after-hook fires
    expect(evidence[:events].last).to eq(:done) # the observed events end at the stream's :done
    expect(evidence[:events].count(:done)).to eq(1)
    expect(evidence[:events]).not_to include(:error) # no phantom terminal after the cancel
  end

  it "a cancel latched by a before hook stops the batch at the next checkpoint — NO tool executes" do
    server.script([{type: :stream, content: "", tool_calls: [
      {id: "c1", name: "quick", arguments: {"tag" => "c1"}},
      {id: "c2", name: "quick", arguments: {"tag" => "c2"}},
    ]}])
    chat = Fast::Completions::Chat.new(client: client, model: model)
    ran = []
    before_ids = []
    tool = Class.new(Fast::Completions::Tool) do
      tool_name "quick"
      parameters { {"type" => "object", "properties" => {"tag" => {"type" => "string"}}} }
      define_method(:execute) { |tag:| ran << tag; "quick #{tag}" }
    end
    chat.with_tools(tool)
    chat.before_tool_call do |tool_call|
      before_ids << tool_call[:id]
      chat.cancel if tool_call[:id] == "c1" # c1's own hook latches the cancel
    end

    Async do
      expect { chat.step }.to raise_error(Fast::Completions::CancelledError)
      client.close
    end

    expect(ran).to be_empty # NO tool executed (at base: c1 still runs — RED)
    expect(before_ids).to eq(%w[c1]) # c2's before hooks never fired
    expect(chat.messages.select(&:tool_result?)).to be_empty # no tool-result Messages
  end
end
