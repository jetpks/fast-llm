#!/usr/bin/env ruby
# frozen_string_literal: true

# Multi-ref performance comparison driver (perf-baseline). Runs the
# committed bench scripts against the gem lib at each release ref —
# v0.2.0 → v0.3.0 → v0.4.0 → 0.4.1 → 0.5.0 — through temporary READ-ONLY
# worktrees under the space's tmp/ (tags are never moved, rewritten,
# or re-pointed; the worktrees are torn down afterward), prints one
# attribution table with per-pair deltas and floor verdicts, and
# writes bench/BASELINE.md next to this script.
#
# 0.5.0 is "HEAD" — the WORKING TREE this script runs from: the lane
# tip, whose uncommitted machine IS the release under measurement (a
# worktree at HEAD's sha would measure the pre-machine code; at
# integrate time the landing commit becomes that sha). The four
# historical refs keep the worktree discipline.
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
# 0.5.0 is "HEAD": the working tree (see the header note).
REFS = [
  ["v0.2.0", "v0.2.0"],
  ["v0.3.0", "v0.3.0"],
  ["v0.4.0", "v0.4.0"],
  ["0.4.1", "ce19841"],
  ["0.5.0", "HEAD"],
].freeze

# Declared per-script ref applicability: a script runs ONLY at refs
# whose lib carries every seam it touches (bench_strict needs the
# 0.4.0 constrained-sampling engine; the other three use seams present
# since v0.2.0 — and, at 0.5.0, the incremental args machine).
# Inapplicable cells are n/a in the table, never an error.
APPLICABILITY = {
  "bench_text_stream" => %w[v0.2.0 v0.3.0 v0.4.0 0.4.1 0.5.0],
  "bench_tool_args" => %w[v0.2.0 v0.3.0 v0.4.0 0.4.1 0.5.0],
  "bench_codec" => %w[v0.2.0 v0.3.0 v0.4.0 0.4.1 0.5.0],
  "bench_strict" => %w[v0.4.0 0.4.1 0.5.0],
}.freeze

PAIRS = [
  ["v0.2.0", "v0.3.0"],
  ["v0.3.0", "v0.4.0"],
  ["v0.4.0", "0.4.1"],
  ["0.4.1", "0.5.0"],
].freeze

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

# Pair-scoped floor override (I02): the machine's own bar. tool_args on
# the 0.4.1→0.5.0 pair is gated at 60 µs/delta — 5× headroom over the
# spec-side calibration prototype's ~12 µs median, and tight enough
# that any per-delta full-buffer walk of the 24 KB workload (>100 µs)
# mechanically FINDS; the floor IS the O(n) gate. Every other path/pair
# keeps its I01 default above.
MACHINE_FLOOR = {path: "tool_args", pair: ["0.4.1", "0.5.0"], max: 60.0}.freeze

def floor_for(path, pair)
  return MACHINE_FLOOR[:max] if path == MACHINE_FLOOR[:path] && pair == MACHINE_FLOOR[:pair]

  FLOORS[path][:max]
end

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

def run_script(label, script, lib_dir)
  # The -I must point at the intended lib: a bogus path would silently
  # fall through to whatever else provides fast/completions (an
  # installed gem) and measure the WRONG code.
  abort "lib dir missing for #{label}: #{lib_dir}" unless File.directory?(lib_dir)

  out, status = Open3.capture2e({},
    RbConfig.ruby, "-I", lib_dir,
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
worktrees = REFS.each_with_object({}) do |(label, rev), hash|
  hash[label] = File.join(root, "bench-#{label}") unless rev == "HEAD"
end

results = {} # [script, label] => measurement
begin
  REFS.each do |label, rev|
    lib_dir =
      if rev == "HEAD"
        # 0.5.0 is the working tree this driver runs from — the lane
        # tip's own lib, no worktree (see the header note).
        File.join(BENCH_DIR, "..", "lib")
      else
        prepare_worktree(worktrees[label], shas[label])
        File.join(worktrees[label], "gems", "completions", "lib")
      end
    APPLICABILITY.each do |script, labels|
      next unless labels.include?(label)

      results[[script, label]] = run_script(label, script, lib_dir)
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
lines << "# fast-completions perf baseline — hardening arc v0.2.0 → 0.5.0"
lines << ""
lines << "Captured #{stamp} by `gems/completions/bench/compare_refs.rb` (frozen floors " \
          "and workload sizes live in that script; the numbers below are a single-machine " \
          "capture, not a test oracle — future runs re-run the driver and compare against " \
          "the FLOORS, never against these cells)."
lines << ""
lines << "- ruby: `#{ruby_note}`"
lines << "- machine: `#{machine_note}` — #{MACHINE_NOTE}"
lines << "- refs: " + REFS.map { |label, _| "#{label} = #{shas[label][0, 7]}" }.join(", ") +
          " (0.4.1 is the local-only SHA, BRIEF §4; 0.5.0 is the working tree at HEAD — the pre-landing lane tip)"
lines << ""
lines << "## Per-path × ref (median of the script's reps)"
lines << ""
lines << "| path | v0.2.0 | v0.3.0 | v0.4.0 | 0.4.1 | 0.5.0 | floor |"
lines << "|---|---|---|---|---|---|---|"
paths.each do |path|
  script = "bench_#{path}"
  row = ["| #{script} |"] + REFS.map { |label, _| " #{cell(results, script, label)} |" }
  row << " #{format("%g", FLOORS[path][:max])} #{FLOORS[path][:unit]} |"
  lines << row.join
end
lines << ""
lines << "## Consecutive-release deltas (newer vs older, same units)"
lines << ""
lines << ["| path |", *PAIRS.map { |older, newer| " #{older}→#{newer} |" }].join
lines << "|---|" + "---|" * PAIRS.size
paths.each do |path|
  script = "bench_#{path}"
  cells = PAIRS.map do |older, newer|
    a = results[[script, older]]
    b = results[[script, newer]]
    a && b ? format("%+.1f%%", (b[:value] - a[:value]) / a[:value] * 100) : "n/a"
  end
  lines << ["| #{path} |", *cells.map { |c| " #{c} |" }].join
end
lines << ""
lines << "## Floor verdicts (absolute per-op ceilings)"
lines << ""
lines << "Every pair's newer cell must sit at or under its floor. One pair " \
          "carries a stricter, pair-scoped bar: 0.4.1→0.5.0 tool_args (the " \
          "machine's own 60 µs/delta gate from I02). `headroom` = " \
          "(floor − value) / floor; rows sort tightest first, so any FINDING " \
          "and the riskiest margins sit at the top."
lines << ""
lines << "| path | pair | value | floor | unit | headroom | status |"
lines << "|---|---|---|---|---|---|---|"
pairs_checked = 0
findings = 0
rows = []
paths.each do |path|
  script = "bench_#{path}"
  PAIRS.each do |older, newer|
    newer_value = results[[script, newer]]
    next if newer_value.nil?

    pairs_checked += 1
    floor = floor_for(path, [older, newer])
    machine_pair = path == MACHINE_FLOOR[:path] && [older, newer] == MACHINE_FLOOR[:pair]
    status = newer_value[:value] <= floor ? "OK" : "FINDING"
    findings += 1 if status == "FINDING"
    rows << {
      path: path,
      pair: "#{older}→#{newer}#{machine_pair ? " (machine bar)" : ""}",
      value: newer_value[:value],
      floor: floor,
      unit: FLOORS[path][:unit],
      headroom: (floor - newer_value[:value]) / floor * 100,
      status: status,
    }
  end
end
rows.sort_by! { |row| [row[:status] == "FINDING" ? 0 : 1, row[:headroom]] }
rows.each do |row|
  lines << format("| %s | %s | %g | %g | %s | %+.0f%% | %s |",
    row[:path], row[:pair], row[:value], row[:floor], row[:unit], row[:headroom], row[:status])
end
lines << ""
# Machine trailer — the driver's exit contract (the judge greps this line).
lines << format("PAIRS_CHECKED=%d FINDINGS=%d", pairs_checked, findings)

table = lines.join("\n") + "\n"
File.write(File.join(BENCH_DIR, "BASELINE.md"), table)
puts table
