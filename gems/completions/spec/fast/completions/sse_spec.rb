# frozen_string_literal: true

# SSE line parser pins (Specification §7). The mock's exact framing is
# the reference: `data: <json>\n\n`, `: keepalive` comments, chunked
# transfers arriving as arbitrary splits.
require "fast/completions"

RSpec.describe Fast::Completions::SSE do
  let(:parser) { described_class.new }

  def items(*chunks)
    chunks.flat_map { |chunk| parser.push(chunk) }
  end

  it "yields data payloads in order" do
    expect(items("data: {\"a\":1}\n\n", "data: {\"b\":2}\n\n")).to eq([{"a" => 1}.to_json, {"b" => 2}.to_json])
  end

  it "survives a split across chunks mid-line (chunk-boundary safety, §7 pin)" do
    expect(items("data: {\"a\"", ":1}\n", "\ndata: x\n\n")).to eq([{"a" => 1}.to_json, "x"])
  end

  it "survives a CR stranded at a chunk boundary (CRLF normalization)" do
    # the \r of the first terminator rides at the end of chunk one; a
    # blank line between the events is what separates them
    expect(items("data: one\r", "\n\r\ndata: two\r\n\r\n")).to eq(%w[one two])
    # inside a single chunk: two events, CRs stripped
    expect(items("data: a\r\n\r\ndata: b\r\n\r\n")).to eq(%w[a b])
  end

  it "ignores comment lines (the mock's keepalives)" do
    expect(items(": keepalive\n\ndata: x\n\n")).to eq(["x"])
    expect(items("data: x\n: keepalive\n\ndata: y\n\n")).to eq(%w[x y])
  end

  it "yields the distinguished DONE token for data: [DONE], not a payload" do
    expect(items("data: [DONE]\n\n")).to eq([described_class::DONE])
  end

  it "concatenates multi-data-line events with \\n (SSE spec)" do
    expect(items("data: line1\ndata: line2\n\n")).to eq(["line1\nline2"])
  end

  it "strips exactly one space after data:" do
    expect(items("data:x\n\ndata: y\n\n")).to eq(%w[x y])
  end

  it "buffers a trailing partial line until its newline arrives" do
    expect(items("data: partial")).to eq([])
    expect(parser.push(" but unfinished")).to eq([])
    expect(parser.push("\n\n")).to eq(["partial but unfinished"])
  end

  it "emits nothing for an event with no data lines" do
    expect(items("event: ping\n\ndata: x\n\n")).to eq(["x"])
  end
end
