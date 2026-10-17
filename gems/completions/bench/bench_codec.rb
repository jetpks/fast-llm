#!/usr/bin/env ruby
# frozen_string_literal: true

# Bench (c) — Codec round-trip of a large multi-turn history with tool
# calls (BRIEF §3: every outgoing string passes String#scrub — I62 — and
# the 0.3.0+ replay rules). Codec.normalize (transform pass, orphaned
# tool-call synthetics) then Protocol-independent
# Codec.to_wire_messages (wire shapes + scrub emission points) over a
# 50-turn history. Deterministic, index-derived content; bare ruby,
# target ref's lib via -I.
require "json"

require "fast/completions/types"
require "fast/completions/dialects"
require "fast/completions/codec"

TURNS = 50
WARMUP = 1
REPS = 9

INSTRUCTIONS = ("System instructions. " * 120).freeze

def user_text(i)
  "Question #{i}: " + ("explain the tradeoff between latency and throughput for streaming parsers. " * 8)
end

def assistant_blocks(i)
  [
    {type: :text, text: "Answer #{i}: " + ("The accumulator live-reparses per delta; cost grows with scratch size. " * 6)},
    {type: :tool_call, id: "call_hist_#{i}", name: "write_file",
     arguments: {"path" => "out/answer-#{i}.md", "content" => ("# Answer #{i}\n\n" + ("body text " * 180))}},
  ]
end

def build_history(model)
  history = []
  TURNS.times do |i|
    history << Fast::Completions::Message.user(user_text(i))
    if i % 5 == 4 # every fifth turn is a thinking turn
      history << Fast::Completions::Message.assistant(
        [{type: :thinking, thinking: "Plan #{i}: " + ("consider the streaming seam. " * 30),
          signature: "reasoning_content"},
         *assistant_blocks(i)],
        provider: model.provider, model: model.id, api: "openai-completions")
    else
      history << Fast::Completions::Message.assistant(assistant_blocks(i),
        provider: model.provider, model: model.id, api: "openai-completions")
    end
    history << Fast::Completions::Message.tool_result(
      tool_call_id: "call_hist_#{i}",
      content: "wrote out/answer-#{i}.md (" + ("ok. " * 90) + ")")
  end
  history
end

def run_once(model, dialect, history)
  normalized = Fast::Completions::Codec.normalize(history, model)
  Fast::Completions::Codec.to_wire_messages(INSTRUCTIONS, normalized, model, dialect)
end

model = Fast::Completions::Model.new(id: "bench-model", reasoning: true,
  context_window: 128_000, max_tokens: 8_192, dialect: nil)
dialect = Fast::Completions::Dialects.fetch(:fireworks)
history = build_history(model)

raise "history shrank" unless history.size == TURNS * 3

WARMUP.times { run_once(model, dialect, history) }
samples = REPS.times.map do
  GC.start
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  wire = run_once(model, dialect, history)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  raise "wire collapsed" unless wire.size >= TURNS * 2

  t1 - t0
end
samples.sort!
median = samples[samples.size / 2]

puts format("turns=%d messages=%d total_ms=%.3f", TURNS, history.size, median * 1_000)
printf("RESULT path=codec metric=round_trip value=%.3f unit=ms ops=%d reps=%d median_total_ms=%.3f\n",
  median * 1_000, 1, REPS, median * 1_000)
