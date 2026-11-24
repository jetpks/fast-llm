#!/usr/bin/env ruby
# frozen_string_literal: true

# Per-gem packaged-gem verify (the release workflow's pre-publish proof).
#
#   ruby script/verify-packaged.rb <gem_name> <require_path>
#   e.g. ruby script/verify-packaged.rb fast-embeddings fast/embeddings
#
# Contract: install pkg/<gem_name>-*.gem into an ISOLATED GEM_HOME
# ($RUNNER_TEMP/gemhome, per-gem suffixed so a dry-run loop never
# collides; dependencies resolve from rubygems as today — async-http is
# a real runtime dependency), then require <require_path> from OUTSIDE
# the checkout (cwd moves to the isolated GEM_HOME — the checkout's
# lib/ is never on the load path) and print the gem's VERSION constant,
# derived from the require path by camelizing each segment
# (fast/completions → Fast::Completions, fast/embeddings →
# Fast::Embeddings). The probe runs in a CHILD ruby process with
# GEM_HOME already in its environment: rubygems resolves its gem paths
# at interpreter boot, so an in-process ENV["GEM_HOME"] switch would be
# too late. This is where a file missing from spec.files or a
# require-path mistake dies — before publishing, not after. Any failure
# exits 1, loud.

gem_name = ARGV[0]
require_path = ARGV[1]
abort "usage: verify-packaged.rb <gem_name> <require_path>" unless gem_name && require_path

package = Dir.glob("pkg/#{gem_name}-*.gem").first
abort "verify-packaged: no pkg/#{gem_name}-*.gem found — build the gem first" unless package

gem_home = File.join(ENV["RUNNER_TEMP"] || Dir.tmpdir, "gemhome-#{gem_name}")
isolated = {"GEM_HOME" => gem_home, "GEM_PATH" => gem_home}

install = system(isolated, "gem", "install", "--no-document", package)
abort "verify-packaged: gem install failed for #{package}" unless install

probe = <<~RUBY
  require_path = ARGV[0]
  constant = require_path.split("/").map { |segment| segment.split("_").map(&:capitalize).join }.join("::")
  require require_path
  puts Object.const_get(constant).const_get(:VERSION)
RUBY

Dir.chdir(gem_home) # outside the checkout: the checkout's lib/ is never on the load path
probed = system(isolated, RbConfig.ruby, "-e", probe, require_path)
abort "verify-packaged: the packaged #{gem_name} failed its require/VERSION probe" unless probed
