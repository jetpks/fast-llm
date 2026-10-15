# frozen_string_literal: true

# Malformed-wire tolerance (I61): the four frozen fixture shapes, reproduced
# as raw frames against the gem's own mock and parsed by the REAL client —
# fixture-reproducible bytes, no live wire. The frames ride the mock's
# chunked-framing discipline (raw_frames → write_chunk); a raw newline
# INSIDE a payload is what cuts it across SSE lines, exactly as observed on
# the z.ai coalesced-delta wire (RCA 2026-10-15).
require "fast/completions"
require_relative "../../support/mock_llm_server"

RSpec.describe "malformed wire tolerance (I61)" do
  let(:server) { MockLLMServer.new.start }
  let(:model) do
    Fast::Completions::Model.new(id: "mock-model", reasoning: false, context_window: 128_000,
      max_tokens: 64, dialect: :fireworks)
  end

  after { server.stop }

  # Streams one scripted response; returns [events, final message, client].
  def stream_events(spec)
    server.script([spec])
    events = []
    final = nil
    c = Fast::Completions::Client.new(base_url: server.url, api_key: "test-key")
    Async do
      final = c.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) do |event|
        events << event
      end
      c.close
    end
    [events, final, c]
  end

  def sse_frame(json)
    "data: #{json}\n\n"
  end

  def stop_frame
    sse_frame(JSON.generate({choices: [{delta: {}, finish_reason: "stop"}]}))
  end

  # ── Shape 1 (the observed shape): a coalesced delta whose JSON is cut
  # mid-string by a raw newline, remainder on the next line UNPREFIXED.
  # The intended tool arguments carry a real newline AND a real tab;
  # on the wire the newline rides as the intact \\n escape and the tab's
  # escape was LOST (emitted raw). The spurious raw newline before the
  # escape is what cuts the payload.
  def shape1_frames
    args_text = JSON.generate({path: "edit.rb", content: "alpha\nbeta\tgamma"})
    payload = JSON.generate({choices: [{delta: {tool_calls: [{index: 0, id: "call_1", type: "function",
      function: {name: "edit", arguments: args_text}}]}, finish_reason: "tool_calls"}]})
    # block form: replacement bytes verbatim (String-form sub would eat \\)
    cut = payload.sub("\\\\n") { "\n\\\\n" }.sub("\\\\t") { "\t" }
    raise "shape-1 injection failed" if cut == payload

    [sse_frame(JSON.generate({choices: [{delta: {role: "assistant"}}]})),
     sse_frame(cut), # the raw newline inside cuts this into two SSE lines
     "data: [DONE]\n\n"]
  end

  it "shape 1: rejoin + repair salvage the coalesced delta — arguments byte-intact, natural stop" do
    events, final, c = stream_events(type: :stream, raw_frames: shape1_frames)
    tool = final.content.find { |block| block[:type] == :tool_call }
    expect(tool[:arguments]).to eq({"path" => "edit.rb", "content" => "alpha\nbeta\tgamma"})
    expect(c.dropped_chunks).to eq(0)
    expect(events.map(&:type)).not_to include(:error)
    expect(events.last.type).to eq(:done)
    expect(events.last.reason).to eq(:tool_use)
  end

  # ── Shape 2: coalesced delta cut, NO continuation (the next event
  # boundary arrives). The truncated payload is unrepairable → dropped;
  # the stream completes and the tool call finalizes with the tolerant
  # OQ-4 empty-args parse. No raise.
  def shape2_frames
    opener = JSON.generate({choices: [{delta: {tool_calls: [{index: 0, id: "call_2", type: "function",
      function: {name: "edit", arguments: ""}}]}}]})
    full = JSON.generate({choices: [{delta: {tool_calls: [{index: 0, function: {
      arguments: %({"path":"a.rb","content":"x"})}}]}}]})
    truncated = full[0...-24] # cut mid-string: open quote, unbalanced braces, no control chars
    finisher = JSON.generate({choices: [{delta: {}, finish_reason: "tool_calls"}]})
    [sse_frame(opener), sse_frame(truncated), sse_frame(finisher), "data: [DONE]\n\n"]
  end

  it "shape 2: the cut chunk is dropped, the stream completes with partial args, no raise" do
    events, final, c = stream_events(type: :stream, raw_frames: shape2_frames)
    tool = final.content.find { |block| block[:type] == :tool_call }
    expect(tool[:id]).to eq("call_2")
    expect(tool[:name]).to eq("edit")
    expect(tool[:arguments]).to eq({}) # OQ-4 tolerant finalize on the lost fragment
    expect(c.dropped_chunks).to eq(1)
    expect(events.map(&:type)).not_to include(:error)
    expect(events.last.type).to eq(:done)
    expect(events.last.reason).to eq(:tool_use)
  end

  # ── Shape 3: an INTACT payload carrying raw \n and \t inside a string
  # value, delivered via the spec-correct multi-data-line event (the
  # parser joins data lines with "\n"). Repair escapes them; the text
  # flows downstream byte-intact.
  it "shape 3: raw control characters in a multi-data-line event repair and flow downstream" do
    frame = %(data: {"choices":[{"delta":{"content":"alpha\ndata: beta\tgamma"}}]}\n\n)
    events, final, c = stream_events(type: :stream, raw_frames: [frame, stop_frame, "data: [DONE]\n\n"])
    text = final.content.find { |block| block[:type] == :text }
    expect(text[:text]).to eq("alpha\nbeta\tgamma")
    expect(c.dropped_chunks).to eq(0)
    expect(events.map(&:type)).to include(:text_start, :text_delta, :text_end)
    expect(events.last.type).to eq(:done)
    expect(events.last.reason).to eq(:stop)
  end

  # ── Shape 4: a payload unrepairable for a NON-control-char reason —
  # truncated object, no continuation, unbalanced braces. Dropped; the
  # stream completes with its natural terminal.
  it "shape 4: a structurally-unrepairable payload is dropped and the stream completes" do
    truncated = %({"choices":[{"delta":{"content":"ok"}})
    events, final, c = stream_events(type: :stream, raw_frames: [sse_frame(truncated), stop_frame, "data: [DONE]\n\n"])
    expect(final.content).to eq([]) # the "ok" rode the dropped chunk
    expect(c.dropped_chunks).to eq(1)
    expect(events.map(&:type)).not_to include(:error)
    expect(events.last.type).to eq(:done)
    expect(events.last.reason).to eq(:stop)
  end

  # ── The §10.5 residual (AC3): the terminal discipline is UNCHANGED — a
  # dropped finish-carrying chunk still ends in the missing-finish error
  # path: :error emitted first, then StreamError.
  it "a dropped finish-carrying chunk still hits the missing-finish terminal (§10.5 residual)" do
    content = sse_frame(JSON.generate({choices: [{delta: {content: "hello"}}]}))
    truncated_finish = JSON.generate({choices: [{delta: {}, finish_reason: "stop"}]})[0...-6] # cut inside "stop"
    server.script([{type: :stream, raw_frames: [content, sse_frame(truncated_finish), "data: [DONE]\n\n"]}])
    events = []
    c = Fast::Completions::Client.new(base_url: server.url, api_key: "test-key")
    Async do
      expect {
        c.stream(model: model, messages: [Fast::Completions::Message.user("hi")]) { |event| events << event }
      }.to raise_error(Fast::Completions::StreamError, /finish_reason/)
      c.close
    end
    expect(c.dropped_chunks).to eq(1)
    expect(events.last.type).to eq(:error) # :error emitted FIRST (§10.5), raise right after
  end
end
