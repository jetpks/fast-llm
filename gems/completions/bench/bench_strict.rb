#!/usr/bin/env ruby
# frozen_string_literal: true

# Bench (d) — strict-sampling schema rewrite (I63, 0.4.0+ only):
# ConstrainedSampling.make_strict_json_schema over a realistic nested
# tool schema (deep objects, arrays via items, an anyOf variant, enums)
# — the per-request wire-build cost strict dialects pay once per
# declared tool. Bare ruby, target ref's lib via -I. APPLICABILITY:
# v0.4.0 and 0.4.1 only (the engine does not exist at older refs —
# those rows are n/a in the comparison table, never an error).
require "json"

require "fast/completions/tool"
require "fast/completions/constrained_sampling"

WARMUP = 1
REPS = 5
INNER = 400

class BenchEditTool < Fast::Completions::Tool
  description "Edit a file with structured options."
  tool_name "edit"
  parameters(
    "type" => "object",
    "required" => ["path", "content"],
    "properties" => {
      "path" => {"type" => "string", "minLength" => 1},
      "content" => {"type" => "string"},
      "encoding" => {"type" => "string", "enum" => ["utf8", "latin1"]},
      "backup" => {"type" => "boolean"},
      "metadata" => {
        "type" => "object",
        "properties" => {
          "author" => {"type" => "string"},
          "tags" => {"type" => "array", "items" => {"type" => "string"}},
          "review" => {
            "type" => "object",
            "properties" => {
              "approved" => {"type" => "boolean"},
              "level" => {"type" => "integer"},
            },
          },
        },
      },
      "style" => {"anyOf" => [{"type" => "string"}, {"type" => "integer"}]},
    },
  )

  def execute(**_args)
    "bench: tool not executed"
  end
end

def run_once(tool)
  INNER.times do
    schema = Fast::Completions::ConstrainedSampling.make_strict_json_schema(tool.parameters)
    raise "rewrite lost a property" unless schema["properties"].size == 6
  end
end

tool = BenchEditTool.new
run_once(tool) # warmup + shape sanity: 6 properties at the root

samples = REPS.times.map do
  GC.start
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  run_once(tool)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  t1 - t0
end
samples.sort!
median = samples[samples.size / 2]

puts format("rewrites_per_rep=%d total_ms=%.3f", INNER, median * 1_000)
printf("RESULT path=strict metric=per_rewrite value=%.3f unit=us ops=%d reps=%d median_total_ms=%.3f\n",
  (median * 1_000_000) / INNER, INNER, REPS, median * 1_000)
