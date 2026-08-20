#!/usr/bin/ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "maccatalyst-screenshot-plan"

class MacCatalystScreenshotPlanTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../..").realpath

  def test_loads_exact_native_retina_plan
    plan = QuakeSignalMacCatalystScreenshotPlan.load(repository_root: ROOT)

    assert_equal "maccatalyst", plan.fetch("platform")
    assert_equal [2_560, 1_600], plan.fetch("frames").first.fetch("pixels")
    assert_equal QuakeSignalMacCatalystScreenshotPlan::FRAMES.map(&:first),
                 plan.fetch("frames").map { |frame| frame.fetch("captureSelector") }
    assert_match(/\A[0-9a-f]{64}\z/, plan.fetch("manifestSha256"))
  end

  def test_rejects_unreviewed_selector_pixels_or_approval
    assert_manifest_mutation_rejected do |manifest|
      manifest.fetch("frames").first["captureSelector"] = "maccatalyst-unreviewed"
    end
    assert_manifest_mutation_rejected do |manifest|
      manifest.fetch("specification")["selectedPixels"] = [1_280, 800]
    end
    assert_manifest_mutation_rejected do |manifest|
      manifest.fetch("frames").first["pixels"] = [1_280, 800]
    end
    assert_manifest_mutation_rejected do |manifest|
      manifest.fetch("captureEvidence")["uploadApproved"] = true
    end
  end

  def test_rejects_duplicate_json_keys
    with_manifest_source('{"schemaVersion":1,"schemaVersion":1}') do |temporary_root|
      error = assert_raises(QuakeSignalMacCatalystScreenshotPlan::Error) do
        QuakeSignalMacCatalystScreenshotPlan.load(repository_root: temporary_root)
      end
      assert_match(/duplicate JSON object key/, error.message)
    end
  end

  private

  def assert_manifest_mutation_rejected
    manifest = JSON.parse(ROOT.join(QuakeSignalMacCatalystScreenshotPlan::MANIFEST).read)
    yield manifest
    with_manifest_source(JSON.pretty_generate(manifest) + "\n") do |temporary_root|
      assert_raises(QuakeSignalMacCatalystScreenshotPlan::Error) do
        QuakeSignalMacCatalystScreenshotPlan.load(repository_root: temporary_root)
      end
    end
  end

  def with_manifest_source(source)
    Dir.mktmpdir("quakesignal-maccatalyst-plan-test") do |directory|
      root = Pathname.new(directory)
      path = root.join(QuakeSignalMacCatalystScreenshotPlan::MANIFEST)
      path.dirname.mkpath
      path.write(source)
      yield root
    end
  end
end
