# frozen_string_literal: true

# Docs gates (I53 Specification §2.4, AC6): the diataxis tree resolves, the
# owner's four dangling README labels land at their ruled destinations, every
# quadrant is non-empty, and the owner's README prose is preserved against the
# byte-frozen 4736ddc fixture copy (Grounds D9/D10 — the ONLY allowed README
# diffs are the four link definitions + the one moved Error-taxonomy section).
# Pure file checks: no network, no lib behavior.

RSpec.describe "fast-completions docs — links, quadrants, owner-prose preservation" do
  GEM_ROOT = File.expand_path("../../..", __dir__)
  REPO_ROOT = File.expand_path("../..", GEM_ROOT)
  README = File.join(GEM_ROOT, "README.md")
  FIXTURE = File.expand_path("../../fixtures/readme/owner-4736ddc.md", __dir__)

  LINK_DEFINITION = /\A\[[^\]]+\]:\s*\S/

  # The scoped markdown (§2.4-2). spec/fixtures/** is excluded BY CONSTRUCTION:
  # the frozen owner copy dangles by design (four ruled labels, no definitions).
  def scoped_files
    [File.join(REPO_ROOT, "README.md"), README, File.join(GEM_ROOT, "CHANGELOG.md")] +
      Dir.glob(File.join(GEM_ROOT, "docs", "**", "*.md")).sort
  end

  # Lines outside ``` / ~~~ fences (§2.4-2: fenced code blocks skipped).
  def prose_sections(lines)
    fence = nil
    lines.filter_map do |line|
      if fence
        fence = nil if line.start_with?(fence)
        next nil
      end
      if (m = line.match(/\A\s*(```|~~~)/))
        fence = m[1]
        next nil
      end
      line
    end
  end

  # Reference definitions (label→target) and inline-link targets in one file.
  def link_inventory(path)
    definitions = {}
    inline = []
    prose_sections(File.readlines(path, chomp: true)).each do |line|
      if (m = line.match(/\A {0,3}\[([^\]]+)\]:\s*(\S+)/))
        definitions[m[1]] = m[2]
      else
        line.scan(/\[[^\]]*\]\(([^)]+)\)/) { |(target)| inline << target }
      end
    end
    [definitions, inline]
  end

  # Reference-style USAGES: bracket labels that are not link definitions and
  # not the text of an inline link.
  def used_labels(path)
    labels = []
    prose_sections(File.readlines(path, chomp: true)).each do |line|
      next if line.match?(/\A {0,3}\[[^\]]+\]:\s*\S/)

      stripped = line.gsub(/\[[^\]]*\]\([^)]*\)/, "")
      stripped.scan(/\[([^\]]+)\]/) { |(label)| labels << label }
    end
    labels
  end

  # A relative target resolves when the file (or directory — the root README
  # links the docs/ tree) exists next to the linking file; anchors are
  # stripped; absolute http(s) URLs pass (§2.4-2).
  def resolves?(path, target)
    bare = target.sub(/\A</, "").sub(/>\z/, "").sub(/#.*\z/, "")
    return true if bare.empty?
    return true if %r{\Ahttps?://}.match?(bare)

    File.exist?(File.expand_path(bare, File.dirname(path)))
  end

  # Line-LCS diff (README-scale; §2.4-1): [removed, added] as
  # [line, index-in-its-own-array] pairs.
  def lcs_diff(old_lines, new_lines)
    table = Array.new(old_lines.length + 1) { Array.new(new_lines.length + 1, 0) }
    (old_lines.length - 1).downto(0) do |i|
      (new_lines.length - 1).downto(0) do |j|
        table[i][j] =
          if old_lines[i] == new_lines[j]
            table[i + 1][j + 1] + 1
          else
            [table[i + 1][j], table[i][j + 1]].max
          end
      end
    end
    removed = []
    added = []
    i = 0
    j = 0
    while i < old_lines.length && j < new_lines.length
      if old_lines[i] == new_lines[j]
        i += 1
        j += 1
      elsif table[i + 1][j] >= table[i][j + 1]
        removed << [old_lines[i], i]
        i += 1
      else
        added << [new_lines[j], j]
        j += 1
      end
    end
    while i < old_lines.length
      removed << [old_lines[i], i]
      i += 1
    end
    while j < new_lines.length
      added << [new_lines[j], j]
      j += 1
    end
    [removed, added]
  end

  # Sort (line, new_lines-index) additions into the two ruled zones and
  # an unruled remainder: zone B (I03, Raw streaming) and zone A (the
  # errors pointer) are index ranges of the NEW README — structural,
  # because blank-line LCS matches make diff-run contiguity
  # uncomputable.
  def classify(structural:, b_range:, a_range:)
    zone_b = []
    zone_a = []
    unruled = []
    structural.each do |(line, at)|
      if b_range.cover?(at)
        zone_b << [line, at]
      elsif a_range.cover?(at)
        zone_a << [line, at]
      else
        unruled << [line, at]
      end
    end
    [zone_b, zone_a, unruled]
  end

  it "lands the four owner labels at their ruled destinations (§2.4-4)" do
    definitions, = link_inventory(README)
    expect(definitions["see the tool docs"]).to eq("docs/reference/tools.md")
    expect(definitions["see the dialect docs"]).to eq("docs/reference/dialects.md")
    expect(definitions["Dialect Docs"]).to eq("docs/reference/dialects.md")
    expect(definitions["socketry/async-http"]).to eq("https://github.com/socketry/async-http")
  end

  it "resolves every reference definition and inline link in the scoped markdown (§2.4-2)" do
    broken = []
    scoped_files.each do |path|
      definitions, inline = link_inventory(path)
      (definitions.values + inline).each do |target|
        next if resolves?(path, target)

        broken << "#{path}: #{target}"
      end
    end
    expect(broken).to be_empty, "dangling links: #{broken.inspect}"
  end

  it "closes every used reference label over its same-file definitions (§2.4-3)" do
    dangling = []
    scoped_files.each do |path|
      definitions, = link_inventory(path)
      used_labels(path).each do |label|
        next if definitions.key?(label)

        dangling << "#{path}: [#{label}]"
      end
    end
    expect(dangling).to be_empty, "undefined labels: #{dangling.inspect}"
  end

  it "keeps every diataxis quadrant non-empty (§2.4-5)" do
    %w[tutorials how-to reference explanation].each do |quadrant|
      pages = Dir.glob(File.join(GEM_ROOT, "docs", quadrant, "*.md"))
      expect(pages).not_to be_empty, "docs/#{quadrant}/ is empty"
    end
  end

  it "preserves the owner's README prose: removals stay inside the Error-taxonomy section; additions are link definitions plus the two ruled zones (§2.4-1, Grounds D9; zone B added I03)" do
    expect(File.file?(FIXTURE)).to be(true)
    old_lines = File.readlines(FIXTURE, chomp: true)
    new_lines = File.readlines(README, chomp: true)
    removed, added = lcs_diff(old_lines, new_lines)

    # The Error-taxonomy section of the FIXTURE: "## Error taxonomy"
    # inclusive … "## Parity" exclusive.
    from = old_lines.index("## Error taxonomy")
    to = old_lines.index("## Parity")
    expect(from).not_to be_nil
    expect(to).not_to be_nil
    section = old_lines[from...to]

    outside = removed.reject { |(line, _)| section.include?(line) }
    expect(outside).to be_empty,
      "removed owner prose outside the Error-taxonomy section: #{outside.map(&:first).inspect}"

    # The two ruled addition zones, derived STRUCTURALLY from new_lines:
    # blank-line LCS matches make diff-run contiguity uncomputable, so
    # zones are ranges in the NEW file, not runs of the diff. Blank and
    # link-definition additions are neutral — present anywhere without
    # rule consequences.
    dialects_at = new_lines.index { |line| line.start_with?("## Dialects as data") }
    parity_at = new_lines.index("## Parity")
    fiber_at = new_lines.index { |line| line.start_with?("## Fiber-native") }
    raw_at = new_lines.index("## Raw streaming")
    first_definition_at = new_lines.index { |line| line.match?(LINK_DEFINITION) }
    expect(dialects_at).not_to be_nil
    expect(parity_at).not_to be_nil
    expect(fiber_at).not_to be_nil
    expect(raw_at).not_to be_nil, "README lost its ## Raw streaming section (I03 zone B)"
    expect(first_definition_at).not_to be_nil
    expect(raw_at).to be > fiber_at # zone B sits after ## Fiber-native...
    expect(raw_at).to be < first_definition_at # ...and before the trailing link definitions

    substantive = added.reject { |(line, _)| line.strip.empty? || line.match?(LINK_DEFINITION) }
    zone_b, zone_a, unruled = classify(structural: substantive,
      b_range: raw_at...first_definition_at, a_range: (dialects_at + 1)...parity_at)
    expect(unruled).to be_empty,
      "non-definition additions outside the two ruled zones: #{unruled.map(&:first).inspect}"

    # Zone A — the errors pointer, rules unchanged from I53: ONE
    # block of at most 6 non-definition lines, linking
    # docs/reference/errors.md, between "Dialects as data" and "## Parity".
    expect(zone_a).not_to be_empty
    expect(zone_a.size).to be <= 6
    expect(zone_a.map(&:first).join("\n")).to include("docs/reference/errors.md")

    # Zone B — I03, the Raw streaming section: additions there must
    # include the heading line and link docs/reference/raw-stream.md.
    expect(zone_b).not_to be_empty
    expect(zone_b.map(&:first)).to include("## Raw streaming")
    expect(zone_b.map(&:first).join("\n")).to include("docs/reference/raw-stream.md")
  end
end
