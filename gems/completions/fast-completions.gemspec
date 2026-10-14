# frozen_string_literal: true

require_relative "lib/fast/completions/version"

Gem::Specification.new do |spec|
  spec.name = "fast-completions"
  spec.version = Fast::Completions::VERSION
  spec.summary = "A fiber-native client for the OpenAI-compatible chat-completions wire, byte-faithful to pi."
  spec.description = <<~DESC
    Fast::Completions speaks the OpenAI-compatible chat-completions wire.
    One wire protocol, dialects as data, async-http as the only runtime
    dependency. Byte-faithful to pi's request/stream behavior.
  DESC

  spec.authors = ["Eric Jacobs"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/jetpks/fast-completions"

  spec.required_ruby_version = ">= 3.3"
  spec.required_rubygems_version = ">= 3.5.3"

  spec.files = Dir.glob(["{lib}/**/*", "*.md"], File::FNM_DOTMATCH, base: __dir__).select { |f| File.file?(f) }
  spec.require_paths = ["lib"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # The ONLY runtime dependency. async/io-event/protocol-* arrive transitively.
  spec.add_dependency "async-http", "~> 0.95"
end
