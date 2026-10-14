# frozen_string_literal: true

# Chat loop pins (Specification §12): the tool batch runs SERIALLY with
# cancellation checkpoints, hooks dispatch in registration order keyed by
# tool_call id, complete? tracks the pending batch. Includes the
# full-turn SMOKE CHECK (instructions + tool + user against the mock).
require "fast/completions"
require_relative "../../support/mock_llm_server"

RSpec.describe Fast::Completions::Chat do
  let(:server) { MockLLMServer.new.start }
  let(:model) do
    Fast::Completions::Model.new(id: "mock-model", reasoning: false, context_window: 128_000,
      max_tokens: 64, dialect: :fireworks)
  end

  let(:reader_class) do
    Class.new(Fast::Completions::Tool) do
      tool_name "read"
      description "Read file contents."
      parameters do
        {"type" => "object", "required" => ["path"], "properties" => {"path" => {"type" => "string"}}}
      end

      define_method(:execute) { |path:| "contents of #{path}" }
    end
  end

  after { server.stop }

  def chat_with_tools
    described_class.new(client: client, model: model).with_instructions("You are terse.").with_tools(reader_class)
  end

  def client
    @client ||= Fast::Completions::Client.new(base_url: server.url, api_key: "test-key")
  end

  # THE SMOKE CHECK (lane verification): one full turn — instructions +
  # tool + user — tool round trip, hooks fired with the tool_call ids.
  it "runs a full tool turn: build → stream → execute → append results" do
    server.script([
      {type: :stream, content: "", tool_calls: [{id: "call_1", name: "read", arguments: {"path" => "src.rb"}}]},
      {type: :stream, content: "The file says: contents of src.rb"},
    ])
    chat = chat_with_tools
    before_ids = []
    after_pairs = []
    chat.before_tool_call { |tool_call| before_ids << tool_call[:id] }
    chat.after_tool_result { |tool_call, result| after_pairs << [tool_call[:id], result.content, result.is_error] }

    events = []
    answers = []
    Async do
      answers << chat.step { |event| events << event.type } # the tool_use turn
      answers << chat.step # the follow-up turn consumes the batch
      client.close
    end

    expect(events.first).to eq(:start)
    expect(events).to include(:tool_call_start, :tool_call_delta, :tool_call_end)
    expect(answers[0].content).to eq([{type: :tool_call, id: "call_1", name: "read", arguments: {"path" => "src.rb"}}])
    expect(answers[1].content).to eq([{type: :text, text: "The file says: contents of src.rb"}])
    # hooks fired with the TOOL_CALL ID (attribution key, §12)
    expect(before_ids).to eq(["call_1"])
    expect(after_pairs).to eq([["call_1", "contents of src.rb", false]])
    # history: the assistant turn + the tool result, then the next turn's assistant
    roles = chat.messages.map(&:role)
    expect(roles).to eq(%i[assistant tool_result assistant])
    expect(chat.messages[1].tool_call_id).to eq("call_1")
    expect(chat.messages[1].tool_name).to eq("read")

    body = server.captured_requests.first
    expect(body["messages"].first).to eq("role" => "system", "content" => "You are terse.")
    expect(body["tools"].first["function"]["name"]).to eq("read")
  end

  it "keeps the batch pending after a tool_use turn; complete? flips after the follow-up" do
    server.script([
      {type: :stream, content: "", tool_calls: [{id: "c1", name: "read", arguments: {"path" => "x"}}]},
      {type: :stream, content: "done"},
    ])
    chat = chat_with_tools
    Async do
      expect(chat.complete?).to be(true) # nothing pending before the first turn
      chat.step
      expect(chat.complete?).to be(false) # batch consumed on the NEXT step
      chat.step
      expect(chat.complete?).to be(true)
      client.close
    end
  end

  it "marks {error:} tool results as is_error and stringifies Hash returns (§11)" do
    failing = Class.new(Fast::Completions::Tool) do
      tool_name "read"
      parameters { {"type" => "object", "properties" => {}} }
      define_method(:execute) { |_args| {error: "permission denied"} }
    end
    hashing = Class.new(Fast::Completions::Tool) do
      tool_name "hashy"
      parameters { {"type" => "object", "properties" => {}} }
      define_method(:execute) { |_args| {a: 1} }
    end
    server.script([
      {type: :stream, content: "", tool_calls: [{id: "c1", name: "read", arguments: {}}]},
      {type: :stream, content: "", tool_calls: [{id: "c2", name: "hashy", arguments: {}}]},
      {type: :stream, content: "ok"},
    ])
    chat = described_class.new(client: client, model: model).with_tools(failing, hashing)
    Async do
      chat.step
      chat.step
      results = chat.messages.select(&:tool_result?)
      expect(results[0].content).to eq("permission denied")
      expect(results[0].is_error).to be(true)
      expect(results[1].content).to eq("{\"a\":1}") # Hash ⇒ JSON.generate
      expect(results[1].is_error).to be(false)
      client.close
    end
  end

  it "yields an error result for unknown tool names" do
    server.script([{type: :stream, content: "", tool_calls: [{id: "c1", name: "nope", arguments: {}}]},
                   {type: :stream, content: "ok"}])
    chat = chat_with_tools
    Async do
      chat.step
      chat.step
      result = chat.messages.find(&:tool_result?)
      expect(result.is_error).to be(true)
      expect(result.content).to eq("no such tool: nope")
      client.close
    end
  end

  it "dispatches MULTIPLE hooks in registration order (§12)" do
    server.script([{type: :stream, content: "", tool_calls: [{id: "c1", name: "read", arguments: {"path" => "f"}}]},
                   {type: :stream, content: "ok"}])
    chat = chat_with_tools
    order = []
    chat.before_tool_call { |tc| order << "first:#{tc[:id]}" }
    chat.before_tool_call { |tc| order << "second:#{tc[:name]}" }
    Async do
      chat.step
      expect(order).to eq(["first:c1", "second:read"])
      client.close
    end
  end

  it "executes a multi-call batch SERIALLY in tool-call order (D9)" do
    server.script([{type: :stream, content: "", tool_calls: [
      {id: "c1", name: "read", arguments: {"path" => "a"}}, {id: "c2", name: "read", arguments: {"path" => "b"}},
    ]}, {type: :stream, content: "ok"}])
    chat = chat_with_tools
    seen = []
    chat.before_tool_call { |tc| seen << tc[:id] }
    Async do
      chat.step
      expect(seen).to eq(%w[c1 c2])
      expect(chat.messages.select(&:tool_result?).map(&:tool_call_id)).to eq(%w[c1 c2])
      client.close
    end
  end

  it "chains configuration and never mutates consumer messages" do
    server.script([{type: :stream, content: "hi"}])
    chat = described_class.new(client: client, model: model)
    user = Fast::Completions::Message.user("frozen?")
    original = user.to_h
    result = chat.with_instructions("i").with_tools(reader_class).add_message(user)
        .with_thinking_level(:high).with_max_output_tokens(32)
    expect(result).to be(chat)
    expect(chat.messages).not_to equal(chat.messages) # dup'd Array (§3)
    expect(chat.messages.first).to equal(user)
    expect(user.to_h).to eq(original)
    Async do
      chat.step
      body = server.captured_requests.first
      expect(body["max_completion_tokens"]).to eq(32)
      client.close
    end
  end

  it "raises CancelledError on step after the cancel latch (no phantom turn)" do
    chat = described_class.new(client: client, model: model)
    chat.cancel
    expect { chat.step }.to raise_error(Fast::Completions::CancelledError)
  end
end
