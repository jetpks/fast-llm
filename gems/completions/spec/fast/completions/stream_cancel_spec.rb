# frozen_string_literal: true

# THE AC3 PIN (stream-cancel gate): a :slow_stream script, cancel from a
# sibling fiber after the first delta ⇒ CancelledError surfaces, NO
# :error/:done event after the cancel, the connection is torn down (never
# reused — the next request on the SAME client succeeds), and tool
# execution observes Cancellation.check checkpoints (D8).
require "fast/completions"
require_relative "../../support/mock_llm_server"

RSpec.describe "stream cancel discipline" do
  let(:server) { MockLLMServer.new.start }
  let(:model) do
    Fast::Completions::Model.new(id: "mock-model", reasoning: false, context_window: 128_000,
      max_tokens: 64, dialect: :fireworks)
  end

  after { server.stop }

  def client
    @client ||= Fast::Completions::Client.new(base_url: server.url, api_key: "test-key")
  end

  # The turn runs in a DEDICATED reactor; the sibling fiber (same
  # reactor) cancels the in-flight stream AFTER the first delta (a Queue
  # handshake makes the ordering deterministic, not a sleep race).
  def cancelled_turn(events)
    server.rearm!
    server.script([{type: :slow_stream, content: "0123456789"}])
    chat = Fast::Completions::Chat.new(client: client, model: model)
    deltas = Queue.new
    Thread.new do
      Async do |task|
        task.async do # the sibling fiber
          deltas.pop until deltas.pop == :text_delta # wait for the FIRST delta
          chat.cancel
        end
        begin
          chat.step { |event| deltas << event.type if event.type == :text_delta; events << event.type }
          :no_raise
        rescue Fast::Completions::CancelledError
          :cancelled
        end
      end.wait # .wait: the block's value (Async itself returns the Task)
    end.value
  end

  it "aborts mid-stream: CancelledError surfaces, NO :error/:done after the cancel (AC3)" do
    events = []
    expect(cancelled_turn(events)).to eq(:cancelled)

    expect(events.first).to eq(:start)                 # the stream truly began
    expect(events).to include(:text_delta)             # ...and delivered deltas before the cancel
    expect(events).not_to include(:done, :error)       # the observed sequence ends at the last delta
  end

  it "the next request on the SAME client succeeds (cancelled connection never reused)" do
    events = []
    expect(cancelled_turn(events)).to eq(:cancelled)

    server.rearm!
    server.script([{type: :stream, content: "fresh connection"}])
    final = nil
    Async do
      final = client.stream(model: model, messages: [Fast::Completions::Message.user("again")]) { |_e| }
      client.close
    end
    expect(final.content).to eq([{type: :text, text: "fresh connection"}])
  end

  it "the tool batch stops at the next Cancellation.check once cancelled (D8)" do
    server.rearm!
    server.script([{type: :stream, content: "", tool_calls: [
      {id: "c1", name: "read", arguments: {"path" => "a"}},
      {id: "c2", name: "read", arguments: {"path" => "b"}},
    ]}])
    chat = Fast::Completions::Chat.new(client: client, model: model)
    ran = []
    tool = Class.new(Fast::Completions::Tool) do
      tool_name "read"
      parameters { {"type" => "object", "properties" => {"path" => {"type" => "string"}}} }
      # record FIRST, then cancel from inside the first execution: the
      # batch must never reach the second call's checkpoint-and-execute.
      define_method(:execute) { |path:| ran << path; chat.cancel; "ran #{path}" }
    end
    chat.with_tools(tool)

    Async do
      expect { chat.step }.to raise_error(Fast::Completions::CancelledError)
      client.close
    end
    expect(ran).to eq(["a"]) # tool c2 never executed
  end

  it "step after the cancel latch raises without touching the wire" do
    server.rearm!
    server.script([{type: :stream, content: "ok"}])
    chat = Fast::Completions::Chat.new(client: client, model: model)
    chat.cancel
    expect { chat.step }.to raise_error(Fast::Completions::CancelledError)
    expect(server.captured_requests).to be_empty # no phantom turn (AC3)
  end
end
