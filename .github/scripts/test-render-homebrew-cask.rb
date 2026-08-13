#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline regression tests for the cask renderer used by the protected
# Homebrew publication workflow. These tests deliberately use a synthetic
# checksum: no tag, release, credential, Homebrew tap, or network access is
# required to prove that the first supported 1.0.0 cask can be rendered safely.

require "open3"
require "rbconfig"
require "tmpdir"

REPOSITORY_ROOT = File.expand_path("../..", __dir__)
RENDERER = File.join(REPOSITORY_ROOT, ".github/scripts/render-homebrew-cask.rb")
TEMPLATE = File.join(REPOSITORY_ROOT, "packaging/homebrew-tap/Casks/quakesignal.rb")
VERSION = "1.0.0"
SHA256 = "0123456789abcdef" * 4

def fail_test(message)
  warn "test failure: #{message}"
  exit 1
end

def run_renderer(template, output, version, sha256)
  Open3.capture3(RbConfig.ruby, RENDERER, template, output, version, sha256)
end

def expect_renderer_failure(template, output, version, sha256, label)
  _stdout, stderr, status = run_renderer(template, output, version, sha256)
  fail_test("#{label} unexpectedly rendered a cask") if status.success?
  fail_test("#{label} produced no useful error") if stderr.strip.empty?
end

fail_test("renderer is missing: #{RENDERER}") unless File.file?(RENDERER)
fail_test("cask template is missing: #{TEMPLATE}") unless File.file?(TEMPLATE)

Dir.mktmpdir("quakesignal-homebrew-cask-test") do |directory|
  output = File.join(directory, "quakesignal.rb")
  stdout, stderr, status = run_renderer(TEMPLATE, output, VERSION, SHA256.upcase)
  fail_test("valid 1.0.0 render failed: #{stderr}\n#{stdout}") unless status.success?
  fail_test("valid 1.0.0 render did not create a cask") unless File.file?(output)

  rendered = File.read(output, encoding: "UTF-8")
  expected_url = 'url "https://github.com/TastyHeadphones/QuakeSignal/releases/download/v#{version}/QuakeSignal_#{version}_universal.dmg",'
  fail_test("rendered cask has the wrong version") unless rendered.scan(/^  version "#{Regexp.escape(VERSION)}"$/).length == 1
  fail_test("rendered cask has the wrong checksum") unless rendered.scan(/^  sha256 "#{SHA256}"$/).length == 1
  fail_test("rendered cask has the wrong DMG URL template") unless rendered.include?(expected_url)
  fail_test("rendered cask does not install QuakeSignal.app") unless rendered.include?("  app \"QuakeSignal.app\"")

  _syntax_stdout, syntax_stderr, syntax_status = Open3.capture3(RbConfig.ruby, "-c", output)
  fail_test("rendered cask is invalid Ruby: #{syntax_stderr}") unless syntax_status.success?

  expect_renderer_failure(TEMPLATE, output, "0.1.0", SHA256, "historical unsupported version")
  expect_renderer_failure(TEMPLATE, output, "1.0", SHA256, "non-semver version")
  expect_renderer_failure(TEMPLATE, output, VERSION, "not-a-checksum", "malformed checksum")

  duplicate_template = File.join(directory, "duplicate-template.rb")
  File.write(duplicate_template, File.read(TEMPLATE, encoding: "UTF-8") + "\n  version \"9.9.9\"\n", encoding: "UTF-8")
  expect_renderer_failure(duplicate_template, output, VERSION, SHA256, "template with duplicate version")
end

puts "Homebrew cask renderer tests passed"
