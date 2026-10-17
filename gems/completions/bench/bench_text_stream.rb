#!/usr/bin/env ruby
# frozen_string_literal: true

# Bench (a) — text-heavy SSE + protocol stream (BRIEF §3: `SSE#push`
# appends and consumes by line, amortized O(bytes); the per-delta
# accumulator path). Deterministic, network-free: a fixed wire script is
# fed through SSE#push → JSON.parse → StreamAccumulator#consume exactly
# as Client#feed_stream drives them, minus the socket. Runs under bare
# `ruby` with the target ref's lib on $LOAD_PATH via -I; loads ONLY the
# files it exercises (never client/chat — no async dependency).
require "json"

require "fast/completions/types"
require "fast/completions/dialects"
require "fast/completions/sse"
require "fast/completions/codec"
require "fast/completions/protocol"

DELTAS = 3_000
WARMUP = 1
REPS = 5
CHUNK_BYTES = 16 * 1_024

def build_wire_chunks
  model_words = %w[the quick brown fox jumps over a lazy dog while streaming tokens arrive]
  frames = +""
  frames << "data: #{JSON.generate({choices: [{delta: {role: "assistant"}}]})}\n\n"
  DELTAS.times do |i|
    # Index-derived text only — no PRNG, byte-identical on every run.
    text = (model_words.rotate(i % model_words.size) * 4).join(" ")
    payload = JSON.generate({choices: [{delta: {content: text}}]})
    frames << "data: #{payload}\n\n"
  end
  frames << "data: #{JSON.generate({choices: [{delta: {}, finish_reason: "stop"}]})}\n\n"
  frames << "data: [DONE]\n\n"

  chunks = []
  offset = 0
  while offset < frames.bytesize
    chunks << frames.byteslice(offset, CHUNK_BYTES)
    offset += CHUNK_BYTES
  end
  chunks
end

def run_once(model, chunks)
  parser = Fast::Completions::SSE.new
  accumulator = Fast::Completions::Protocol::StreamAccumulator.new(model, model.dialect)
  events = 0
  chunks.each do |chunk|
    parser.push(chunk).each do |item|
      next if item == Fast::Completions::SSE::DONE

      accumulator.consume(JSON.parse(item)).each { events += 1 }
    end
  end
  _events, outcome = accumulator.finish
  raise "unexpected stream outcome: #{outcome.inspect}" unless outcome[0] == :done && outcome[1] == :stop

  events
end

model = Fast::Completions::Model.new(id: "bench-model", reasoning: false,
  context_window: 128_000, max_tokens: 8_192)
chunks = build_wire_chunks

WARMUP.times { run_once(model, chunks) }
samples = REPS.times.map do
  GC.start
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  events = run_once(model, chunks)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  [t1 - t0, events]
end
samples.sort_by!(&:first)
median, events = samples[samples.size / 2]

total_ms = (median * 1_000)
per_delta_us = (median * 1_000_000) / DELTAS
puts format("events=%<events>d deltas=%<deltas>d total_ms=%<ms>.3f", events: events, deltas: DELTAS, ms: total_ms)
printf("RESULT path=text_stream metric=per_delta value=%.3f unit=us ops=%d reps=%d median_total_ms=%.3f\n",
  per_delta_us, DELTAS, REPS, total_ms)
