#!/usr/bin/env ruby
# frozen_string_literal: true

# Bench (b) — tool-args-heavy stream: the per-delta live re-parse worst
# case (BRIEF §3: every tool-args delta live-reparses the whole scratch —
# `JSON.parse` → `repair_json` → re-parse; O(n²) by design until a
# benchmark says otherwise; pi parity). A ~24 KB arguments JSON streams
# across ~320 fragments cut at arbitrary byte offsets, so most deltas
# hit the raise → repair-walk path on a growing scratch. Same drive
# shape as (a): SSE#push → JSON.parse → StreamAccumulator#consume,
# bare ruby, target ref's lib via -I, no async load.
#
# SAFE-CUT DISCIPLINE: fragment boundaries never leave a PARTIAL JSON
# escape at the scratch tail — the split-escape shape that crashed the
# live re-parse at v0.2.0–v0.4.0 (uncaught ParserError from the repaired
# re-parse; Ruby rescue clauses do not cascade) and that 0.4.1 fixed
# with its own rescue. That crash is a robustness property (already
# pinned by protocol_spec), not a timing metric; this bench keeps the
# COMPARABLE worst case — incomplete JSON → raise → full repair walk
# per delta, the O(n²) re-parse — running at every ref.
require "json"

require "fast/completions/types"
require "fast/completions/dialects"
require "fast/completions/sse"
require "fast/completions/codec"
require "fast/completions/protocol"

FRAGMENTS = 320 # nominal; safe-cut shifts may move a boundary by a byte
WARMUP = 1
REPS = 5
CHUNK_FRAMES = 12 # network chunks carrying several frames each

def build_args_json
  lines = 200.times.map do |i|
    format("line %04d: %s\n", i, "lorem ipsum dolor sit amet consectetur adipiscing elit sed do #{i} ")
  end
  JSON.generate({
    "path" => "bench/large/edit-#{'x' * 40}.rb",
    "notes" => 40.times.map { |i| "note #{i}: " + ("phrasing sample " * 12) },
    "content" => lines.join,
  })
end

# True when cutting here would strand a partial JSON escape sequence
# (a lone or unterminated backslash escape, including a cut \u hex run)
# at the scratch tail.
def partial_escape_tail?(prefix)
  prefix.match?(%r{\\+(?:u[0-9a-fA-F]{0,3})?\z})
end

def fragment_offsets(args, nominal)
  offsets = [0]
  pos = 0
  while pos < args.bytesize
    pos = [pos + nominal, args.bytesize].min
    pos += 1 while pos < args.bytesize && partial_escape_tail?(args.byteslice(0, pos))
    offsets << pos
  end
  offsets
end

def build_frames
  args = build_args_json
  nominal = (args.bytesize + FRAGMENTS - 1) / FRAGMENTS
  offsets = fragment_offsets(args, nominal)
  frames = []
  frames << JSON.generate({choices: [{delta: {role: "assistant", tool_calls: [{
    index: 0, id: "call_bench_1", type: "function",
    function: {name: "write_file", arguments: args.byteslice(0, offsets[1])},
  }]}}]})
  (2...offsets.size).each do |i|
    frames << JSON.generate({choices: [{delta: {tool_calls: [{
      index: 0,
      function: {arguments: args.byteslice(offsets[i - 1], offsets[i] - offsets[i - 1])},
    }]}}]})
  end
  frames << JSON.generate({choices: [{delta: {}, finish_reason: "tool_calls"}]})
  [frames, offsets.size - 1]
end

def build_wire_chunks(frames)
  wire = +""
  frames.each_slice(CHUNK_FRAMES) do |slice|
    slice.each { |f| wire << "data: #{f}\n\n" }
  end
  [wire] # one network chunk per frame-group: line-complete frames
end

def run_once(model, chunks, fragments)
  parser = Fast::Completions::SSE.new
  accumulator = Fast::Completions::Protocol::StreamAccumulator.new(model, model.dialect)
  tool_calls = 0
  chunks.each do |chunk|
    parser.push(chunk).each do |item|
      next if item == Fast::Completions::SSE::DONE

      accumulator.consume(JSON.parse(item)).each do |event|
        tool_calls += 1 if event.type == :tool_call_delta
      end
    end
  end
  events, outcome = accumulator.finish
  events.each { |event| tool_calls += 1 if event.type == :tool_call_end }
  raise "unexpected stream outcome: #{outcome.inspect}" unless outcome[0] == :done && outcome[1] == :tool_use
  raise "fragment count drift: #{tool_calls} != #{fragments + 1}" unless tool_calls == fragments + 1

  tool_calls
end

model = Fast::Completions::Model.new(id: "bench-model", reasoning: false,
  context_window: 128_000, max_tokens: 8_192)
frames, fragments = build_frames
chunks = build_wire_chunks(frames)

WARMUP.times { run_once(model, chunks, fragments) }
samples = REPS.times.map do
  GC.start
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  run_once(model, chunks, fragments)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  t1 - t0
end
samples.sort!
median = samples[samples.size / 2]

puts format("args_bytes=%<bytes>d fragments=%<frags>d total_ms=%<ms>.3f",
  bytes: build_args_json.bytesize, frags: fragments, ms: median * 1_000)
printf("RESULT path=tool_args metric=per_delta value=%.3f unit=us ops=%d reps=%d median_total_ms=%.3f\n",
  (median * 1_000_000) / fragments, fragments, REPS, median * 1_000)
