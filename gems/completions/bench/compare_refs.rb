#!/usr/bin/env ruby
# frozen_string_literal: true

# Multi-ref performance comparison driver (perf-baseline). Runs the
# committed bench scripts against the gem lib at each release ref —
# v0.2.0 → v0.3.0 → v0.4.0 → 0.4.1 — through temporary READ-ONLY
# worktrees under the space's tmp/ (tags are never moved, rewritten,
# or re-pointed; the worktrees are torn down afterward), prints one
# attribution table with per-pair deltas and floor verdicts, and
# writes bench/BASELINE.md next to this script.
#
# FINDINGS DISCIPLINE: a pair whose NEWER ref exceeds its frozen floor
# is a FINDING (printed, counted, carried in BASELINE.md) — never a
# driver failure. The driver exits nonzero ONLY on infrastructure
# breakage (missing ref, worktree failure, a script failing at an
# applicable ref).
require "fileutils"
require "open3"
require "set"

BENCH_DIR = __dir__
REPO = File.expand_path("../..", __dir__) # gems/completions/bench → repo root

# [label, git rev]. 0.4.1 is the local-only SHA ce19841 (BRIEF §4) —
# origin/main sits at v0.4.0; the label is the release name only.
REFS = [
  ["v0.2.0", "v0.2.0"],
  ["v0.3.0", "v0.3.0"],
  ["v0.4.0", "v0.4.0"],
  ["0.4.1", "ce19841"],
].freeze

# Declared per-script ref applicability: a script runs ONLY at refs
# whose lib carries every seam it touches (bench_strict needs the
# 0.4.0 constrained-sampling engine; the other three use seams present
# since v0.2.0). Inapplicable cells are n/a in the table, never an
# error.
APPLICABILITY = {
  "bench_text_stream" => %w[v0.2.0 v0.3.0 v0.4.0 0.4.1],
  "bench_tool_args" => %w[v0.2.0 v0.3.0 v0.4.0 0.4.1],
  "bench_codec" => %w[v0.2.0 v0.3.0 v0.4.0 0.4.1],
  "bench_strict" => %w[v0.4.0 0.4.1],
}.freeze

PAIRS = [["v0.2.0", "v0.3.0"], ["v0.3.0", "v0.4.0"], ["v0.4.0", "0.4.1"]].freeze

# FROZEN FLOORS (iteration Specification; do not tune in-lane): absolute
# per-op ceilings, generous to single-machine noise. The client is
# network-bound: the bar is per-chunk and per-request CPU staying far
# under per-chunk network latency — every floor is µs/ms-scale while
# per-chunk network latency is 10–100 ms. Calibrated 2026-10-17 on the
# spec machine (observed: text ~10 µs, tool_args ~890 µs, codec ~0.28
# ms, strict ~18 µs) with 2.8–10× headroom.
FLOORS = {
  "text_stream" => {unit: "us/delta", max: 100.0},
  "tool_args" => {unit: "us/delta", max: 2500.0},
  "codec" => {unit: "ms/round_trip", max: 1.5},
  "strict" => {unit: "us/rewrite", max: 100.0},
}.freeze

MACHINE_NOTE = ENV.fetch("BENCH_MACHINE_NOTE",
  "single-machine wall-clock medians; shared developer laptop, no isolation")

# The space's tmp/ (this driver may run from the integration checkout
# or a lane worktree — both live inside the space). Ascend from the
# repo root until a space.yaml + tmp/ pair appears; fall back to a
# system temp dir when run outside any space.
def worktree_root
  dir = REPO
  loop do
    return File.join(dir, "tmp") if File.file?(File.join(dir, "space.yaml")) && File.directory?(File.join(dir, "tmp"))

    parent = File.dirname(dir)
    return require("tmpdir").then { Dir.mktmpdir("fast-completions-bench") } if parent == dir

    dir = parent
  end
end

def git(*args)
  out, status = Open3.capture2e("git", "-C", REPO, *args)
  return out if status.success?

  abort "git #{args.join(' ')} failed:\n#{out}"
end

def resolve_rev(rev)
  out, status = Open3.capture2e("git", "-C", REPO, "rev-parse", "--verify", "--quiet", "#{rev}^{commit}")
  abort "ref not resolvable in this clone: #{rev}" unless status.success? && !out.strip.empty?

  out.strip
end

# Remove a possibly-stale worktree/dir; never aborts (a leftover from a
# crashed run is cleaned, not fatal).
def discard_worktree(path)
  _, status = Open3.capture2e("git", "-C", REPO, "worktree", "remove", "--force", path)
  FileUtils.rm_rf(path) unless status.success? && !File.directory?(path)
  _, _ = Open3.capture2e("git", "-C", REPO, "worktree", "prune")
end

def prepare_worktree(path, sha)
  discard_worktree(path)
  git("worktree", "add", "--detach", path, sha)
end

def run_script(label, script, worktree)
  out, status = Open3.capture2e({},
    RbConfig.ruby, "-I", File.join(worktree, "gems", "completions", "lib"),
    File.join(BENCH_DIR, "#{script}.rb"))
  unless status.success?
    abort "#{script} FAILED at #{label} (an applicable ref — this is an " \
          "iteration failure, not a finding):\n#{out}"
  end

  line = out.lines.find { |l| l.start_with?("RESULT ") }
  abort "#{script} printed no RESULT line at #{label}:\n#{out}" if line.nil?

  fields = line.chomp.split(" ").each_with_object({}) do |token, hash|
    key, value = token.split("=", 2)
    hash[key] = value if key && value
  end
  path = fields.fetch("path")
  abort "#{script} RESULT path=#{path.inspect} does not match its file name" unless path == script.delete_prefix("bench_")

  {value: fields.fetch("value").to_f, unit: fields.fetch("unit"),
   ops: fields.fetch("ops").to_i, total_ms: fields.fetch("median_total_ms").to_f}
end

paths = FLOORS.keys
scripts = APPLICABILITY.keys
abort "FLOORS keys must match APPLICABILITY scripts" unless paths.to_set == scripts.map { |s| s.delete_prefix("bench_") }.to_set

shas = REFS.to_h { |label, rev| [label, resolve_rev(rev)] }
root = worktree_root
worktrees = REFS.to_h { |label, _| [label, File.join(root, "bench-#{label}")] }

results = {} # [script, label] => measurement
begin
  REFS.each do |label, _rev|
    prepare_worktree(worktrees[label], shas[label])
    APPLICABILITY.each do |script, labels|
      next unless labels.include?(label)

      results[[script, label]] = run_script(label, script, worktrees[label])
    end
  end
ensure
  worktrees.each_value { |path| discard_worktree(path) }
end

def cell(results, script, label)
  entry = results[[script, label]]
  return "n/a" if entry.nil?

  format("%g", entry[:value].round(entry[:value] < 10 ? 3 : 1))
end

ruby_note = RUBY_DESCRIPTION
machine_note = `uname -srm`.strip
stamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

lines = []
lines << "# fast-completions perf baseline — hardening arc v0.2.0 → 0.4.1"
lines << ""
lines << "Captured #{stamp} by `gems/completions/bench/compare_refs.rb` (frozen floors " \
          "and workload sizes live in that script; the numbers below are a single-machine " \
          "capture, not a test oracle — future runs re-run the driver and compare against " \
          "the FLOORS, never against these cells)."
lines << ""
lines << "- ruby: `#{ruby_note}`"
lines << "- machine: `#{machine_note}` — #{MACHINE_NOTE}"
lines << "- refs: " + REFS.map { |label, _| "#{label} = #{shas[label][0, 7]}" }.join(", ") +
          " (0.4.1 is the local-only SHA, BRIEF §4)"
lines << ""
lines << "## Per-path × ref (median of the script's reps)"
lines << ""
lines << "| path | v0.2.0 | v0.3.0 | v0.4.0 | 0.4.1 | floor |"
lines << "|---|---|---|---|---|---|"
paths.each do |path|
  script = "bench_#{path}"
  row = ["| #{script} |"] + REFS.map { |label, _| " #{cell(results, script, label)} |" }
  row << " #{format("%g", FLOORS[path][:max])} #{FLOORS[path][:unit]} |"
  lines << row.join
end
lines << ""
lines << "## Consecutive-release deltas (newer vs older, same units)"
lines << ""
PAIRS.each do |older, newer|
  paths.each do |path|
    script = "bench_#{path}"
    a = results[[script, older]]
    b = results[[script, newer]]
    delta = a && b ? format("%+.1f%%", (b[:value] - a[:value]) / a[:value] * 100) : "n/a"
    lines << "- #{path} #{older}→#{newer}: #{delta}"
  end
end
lines << ""
lines << "## Floor verdicts (absolute per-op ceilings)"
lines << ""
FLOORS.each do |path, floor|
  lines << "FLOOR path=#{path} unit=#{floor[:unit]} max=#{format("%g", floor[:max])}"
end
pairs_checked = 0
findings = 0
verdicts = []
paths.each do |path|
  script = "bench_#{path}"
  PAIRS.each do |older, newer|
    newer_value = results[[script, newer]]
    next if newer_value.nil?

    pairs_checked += 1
    status = newer_value[:value] <= FLOORS[path][:max] ? "OK" : "FINDING"
    findings += 1 if status == "FINDING"
    verdicts << format("VERDICT path=%s pair=%s->%s newer=%g floor=%g unit=%s status=%s",
      path, older, newer, newer_value[:value], FLOORS[path][:max], FLOORS[path][:unit], status)
  end
end
lines.concat(verdicts)
lines << format("PAIRS_CHECKED=%d FINDINGS=%d", pairs_checked, findings)

table = lines.join("\n") + "\n"
File.write(File.join(BENCH_DIR, "BASELINE.md"), table)
puts table
