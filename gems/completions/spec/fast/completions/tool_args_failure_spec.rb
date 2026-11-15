# frozen_string_literal: true

# I06 serving-stack tool honesty — the loud in-band finalize failure for
# tool-call arguments. A NON-EMPTY arguments scratch that fails the
# finalize whole-buffer parse (even after the control-character repair
# walk) must surface as the ToolArgumentsFailure marker carrying the RAW
# scratch — never a silent arguments = {} (the fallback that made a
# gateway double-emit look like model incompetence; the muse-glimmer
# lineage, gateway-ab EVIDENCE.md "client-side consequence chain").
# The wire shapes below mirror the frozen gateway-ab corpus captures
# (the doubled complete-call-on-terminal-chunk of gateway-1.sse.txt, the
# single complete call of direct-1.sse.txt) — inlined by shape, not by
# file, so the gem suite stays portable and hermetic.
require "fast/completions"

RSpec.describe "tool arguments finalize failure surface" do
  let(:dialect) { Fast::Completions::Dialect.new(nil) }
  let(:model) do
    Fast::Completions::Model.new(
      id: "muse-glimmer-30b", reasoning: true, context_window: 131_072, max_tokens: 16_384,
    )
  end

  def accumulator
    Fast::Completions::Protocol::StreamAccumulator.new(model, dialect)
  end

  def chunk(delta, extra = {})
    {"choices" => [{"delta" => delta}]}.merge(extra)
  end

  def tool_call_entry(arguments, id: nil, name: nil, index: 0)
    entry = {"index" => index}
    entry["id"] = id if id
    function = {}
    function["name"] = name if name
    function["arguments"] = arguments
    entry["function"] = function
    entry
  end

  # The engine's complete call (direct-1.sse.txt, the corpus's exact
  # arguments bytes).
  let(:full_args_text) do
    '{"query": "Antikythera mechanism", "numResults": 5, "includeText": false}'
  end
  let(:full_args) { {"query" => "Antikythera mechanism", "numResults" => 5, "includeText" => false} }

  def marker_for(raw)
    Fast::Completions::ToolArgumentsFailure.marker(raw)
  end

  describe "the doubled scratch (the gateway-1 shape)" do
    it "finalizes to the loud marker with the raw doubled scratch — never {} — and finish returns" do
      acc = accumulator
      # The gateway's first emission: the COMPLETE call riding the
      # terminal chunk (finish_reason + tool_calls on one delta).
      acc.consume({"choices" => [{"delta" => {"tool_calls" => [tool_call_entry(full_args_text,
        id: "77bbb949", name: "web_search")]}, "finish_reason" => "tool_calls"}]})
      # The gateway's second emission: the SAME complete call again.
      acc.consume(chunk({"tool_calls" => [tool_call_entry(full_args_text, id: "77bbb949", name: "web_search")]}))

      end_events, outcome = acc.finish
      expect(outcome).to eq([:done, :tool_use]) # the stream completed; no raise

      tool = acc.partial.content.find { |block| block[:type] == :tool_call }
      expect(tool[:name]).to eq("web_search")
      expect(tool[:arguments]).to eq(marker_for(full_args_text * 2))
      expect(tool[:arguments]).not_to eq({})
      expect(tool[:arguments].keys).to eq(%i[error raw_arguments])
      expect(tool[:arguments][:raw_arguments]).to include("Antikythera mechanism") # the raw scratch rides
      expect(Fast::Completions::ToolArgumentsFailure.marker?(tool[:arguments])).to be(true)

      end_event = end_events.find { |event| event.type == :tool_call_end }
      expect(end_event.tool_call[:arguments]).to equal(tool[:arguments]) # the marker rides the event too
    end
  end

  describe "the truncated scratch" do
    it "finalizes to the loud marker carrying the partial bytes" do
      acc = accumulator
      acc.consume(chunk({"tool_calls" => [tool_call_entry("", id: "c1", name: "web_search")]}))
      acc.consume(chunk({"tool_calls" => [tool_call_entry('{"query": "Antikythera mech')]}))
      acc.consume({"choices" => [{"delta" => {}, "finish_reason" => "tool_calls"}]})

      _events, outcome = acc.finish
      expect(outcome).to eq([:done, :tool_use])
      tool = acc.partial.content.find { |block| block[:type] == :tool_call }
      expect(tool[:arguments]).to eq(marker_for('{"query": "Antikythera mech'))
    end

    it "marks a scratch that the repair walk CHANGED but could not save (the marker reports the original bytes)" do
      acc = accumulator
      # Raw control chars AND truncation: repair_json escapes the control
      # chars (repaired != partial), yet the re-parse still fails on the
      # unterminated string — the marker carries the ORIGINAL scratch.
      acc.consume(chunk({"tool_calls" => [tool_call_entry("{\"q\": \"a\r\nb")]}))
      acc.consume({"choices" => [{"delta" => {}, "finish_reason" => "tool_calls"}]})
      acc.finish
      tool = acc.partial.content.find { |block| block[:type] == :tool_call }
      expect(tool[:arguments]).to eq(marker_for("{\"q\": \"a\r\nb"))
    end
  end

  describe "the repairable control-char scratch (the good repair path is NOT a failure)" do
    it "still repairs to valid arguments at finalize" do
      acc = accumulator
      acc.consume(chunk({"tool_calls" => [tool_call_entry("{\"path\":\"line1\r\nline\t2\"}", id: "c1", name: "edit")]}))
      acc.consume({"choices" => [{"delta" => {}, "finish_reason" => "tool_calls"}]})
      _events, outcome = acc.finish
      expect(outcome).to eq([:done, :tool_use])
      tool = acc.partial.content.find { |block| block[:type] == :tool_call }
      expect(tool[:arguments]).to eq({"path" => "line1\r\nline\t2"})
      expect(Fast::Completions::ToolArgumentsFailure.marker?(tool[:arguments])).to be(false)
    end
  end

  describe "the clean stream (the direct-1 shape) is unchanged" do
    it "yields the full arguments hash exactly — no extra keys, no reordering" do
      acc = accumulator
      # direct-1: ONE terminal chunk carries the complete call.
      acc.consume({"choices" => [{"delta" => {"tool_calls" => [tool_call_entry(full_args_text,
        id: "6af3ad9a", name: "web_search")]}, "finish_reason" => "tool_calls"}]})
      _events, outcome = acc.finish
      expect(outcome).to eq([:done, :tool_use])
      tool = acc.partial.content.find { |block| block[:type] == :tool_call }
      expect(tool[:arguments]).to eq(full_args)
      expect(tool[:arguments].keys).to eq(%w[query numResults includeText]) # document order, nothing added
      expect(tool.keys).to contain_exactly(:type, :id, :name, :arguments)   # no new block keys
      expect(Fast::Completions::ToolArgumentsFailure.marker?(tool[:arguments])).to be(false)
    end
  end

  describe "the empty scratch stays {} (the honest zero-bytes case)" do
    it "finalizes a no-fragment block to a deliberate empty call" do
      acc = accumulator
      acc.consume(chunk({"tool_calls" => [tool_call_entry("", id: "c1", name: "clock")]}))
      acc.consume({"choices" => [{"delta" => {}, "finish_reason" => "tool_calls"}]})
      _events, outcome = acc.finish
      expect(outcome).to eq([:done, :tool_use])
      tool = acc.partial.content.find { |block| block[:type] == :tool_call }
      expect(tool[:arguments]).to eq({})
    end
  end

  describe "collision-proofing" do
    it "legitimate wire arguments with STRING keys named error/raw_arguments parse normally — not a marker" do
      acc = accumulator
      wire = '{"error": "boom", "raw_arguments": "x"}'
      acc.consume(chunk({"tool_calls" => [tool_call_entry(wire, id: "c1", name: "t")]}))
      acc.consume({"choices" => [{"delta" => {}, "finish_reason" => "tool_calls"}]})
      acc.finish
      tool = acc.partial.content.find { |block| block[:type] == :tool_call }
      expect(tool[:arguments]).to eq({"error" => "boom", "raw_arguments" => "x"})
      expect(Fast::Completions::ToolArgumentsFailure.marker?(tool[:arguments])).to be(false)
    end

    it "marker? is false for non-Hashes and partial look-alikes" do
      expect(Fast::Completions::ToolArgumentsFailure.marker?(nil)).to be(false)
      expect(Fast::Completions::ToolArgumentsFailure.marker?("s")).to be(false)
      expect(Fast::Completions::ToolArgumentsFailure.marker?({error: "x"})).to be(false)
      expect(Fast::Completions::ToolArgumentsFailure.marker?({"error" => "x", "raw_arguments" => "y"})).to be(false)
    end
  end

  describe "Protocol.parse_streaming_json unit surface" do
    it "parses clean JSON, repairs control chars, and marks the unparseable" do
      protocol = Fast::Completions::Protocol
      expect(protocol.parse_streaming_json(full_args_text)).to eq(full_args)
      expect(protocol.parse_streaming_json('{"a":"x\ry"}')).to eq({"a" => "x\ry"})
      expect(protocol.parse_streaming_json('{"a":1}{"a":1}')).to eq(marker_for('{"a":1}{"a":1}'))
      expect(protocol.parse_streaming_json("  ")).to eq({})
      expect(protocol.parse_streaming_json(nil)).to eq({})
    end
  end
end
