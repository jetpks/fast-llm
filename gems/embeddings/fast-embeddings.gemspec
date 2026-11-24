# frozen_string_literal: true

require_relative "lib/fast/embeddings/version"

Gem::Specification.new do |spec|
  spec.name = "fast-embeddings"
  spec.version = Fast::Embeddings::VERSION
  spec.summary = "A fiber-native client for the OpenAI embeddings wire."
  spec.description = <<~DESC
    Fast::Embeddings speaks the OpenAI embeddings wire. One wire
    protocol, one POST per call, one JSON reply back — no dialects, no
    extensions. async-http is the only runtime dependency; credentials
    ride per call and are never stored.
  DESC

  spec.authors = ["Eric Jacobs"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/jetpks/fast-llm"

  spec.required_ruby_version = ">= 3.4"
  spec.required_rubygems_version = ">= 3.5.3"

  # RubyGems loads gemspecs via eval: __dir__ is the dirname of the path AS
  # PASSED (relative when invoked relatively), Dir.glob(base:) returns
  # BASE-RELATIVE names, and `gem build` validates/packages spec.files
  # against the INVOCATION cwd. Keep the names gemspec-dir-relative (the
  # form that packages correctly from this directory) but resolve the
  # filter against the gemspec dir so foreign-cwd loads see the true file
  # list — and a foreign-cwd `gem build` fails LOUDLY instead of silently
  # packaging a .gem with no lib/. (I51 judge ruling: the repo-root
  # `gem build gems/<gem>/…gemspec` form is RubyGems-impossible for
  # a nested monorepo gemspec — build from this directory.)
  spec.files = Dir.glob(["{lib}/**/*", "*.md"], File::FNM_DOTMATCH, base: File.expand_path(__dir__))
    .select { |f| File.file?(File.expand_path(f, __dir__)) }
  spec.require_paths = ["lib"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/gems/embeddings/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # The ONLY runtime dependency. async/io-event/protocol-* arrive transitively.
  spec.add_dependency "async-http", "~> 0.95"
end
