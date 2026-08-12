#!/usr/bin/env ruby
# frozen_string_literal: true

# Render the release cask from the checked-in template without ever modifying
# the working tree. The protected Homebrew workflow writes this output only to
# a temporary clone of TastyHeadphones/homebrew-tap after it has verified the
# matching notarized GitHub Release and checksum manifest.

abort "usage: render-homebrew-cask.rb <template> <output> <version> <sha256>" unless ARGV.length == 4

template_path, output_path, version, sha256 = ARGV
unless version.match?(/\A[0-9]+\.[0-9]+\.[0-9]+\z/)
  abort "version must be numeric major.minor.patch"
end
abort "refusing to render the historical unsupported 0.1.0 cask" if version == "0.1.0"
unless sha256.match?(/\A[0-9a-f]{64}\z/i)
  abort "sha256 must be exactly 64 hexadecimal characters"
end

source = File.read(template_path, encoding: "UTF-8")
version_matches = source.scan(/^  version "([^"]+)"$/)
sha_matches = source.scan(/^  sha256 "([0-9a-f]{64})"$/i)
abort "template must contain exactly one cask version" unless version_matches.length == 1
abort "template must contain exactly one cask sha256" unless sha_matches.length == 1

rendered = source.sub(/^  version "[^"]+"$/, "  version \"#{version}\"")
rendered = rendered.sub(/^  sha256 "[0-9a-f]{64}"$/i, "  sha256 \"#{sha256.downcase}\"")
abort "failed to render the cask version" unless rendered.include?("  version \"#{version}\"")
abort "failed to render the cask checksum" unless rendered.include?("  sha256 \"#{sha256.downcase}\"")

File.write(output_path, rendered, mode: "w", encoding: "UTF-8")
