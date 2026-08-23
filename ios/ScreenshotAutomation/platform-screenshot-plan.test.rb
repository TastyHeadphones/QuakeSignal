#!/usr/bin/ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "platform-screenshot-plan"

class PlatformScreenshotPlanTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../..").realpath

  def test_checked_in_plans_have_the_exact_reviewed_inventory
    assert_equal 3, load_plan("tvos").fetch("frames").length
    assert_equal 5, load_plan("visionos").fetch("frames").length
    assert_equal 3, load_plan("watchos").fetch("frames").length

    assert_equal(
      %w[visionos-home visionos-reports visionos-map visionos-guide visionos-alert-preferences],
      load_plan("visionos").fetch("frames").map { |frame| frame.fetch("captureSelector") },
    )
  end

  def test_rejects_removed_frame
    with_fixture do |root|
      mutate_manifest(root, "tvos") { |manifest| manifest.fetch("frames").pop }
      error = assert_raises(QuakeSignalPlatformScreenshotPlan::Error) do
        load_plan("tvos", root: root)
      end
      assert_match(/frames\.length/, error.message)
    end
  end

  def test_rejects_selector_drift
    with_fixture do |root|
      mutate_manifest(root, "visionos") do |manifest|
        manifest.fetch("frames").fetch(2)["captureSelector"] = "visionos-unreviewed"
      end
      error = assert_raises(QuakeSignalPlatformScreenshotPlan::Error) do
        load_plan("visionos", root: root)
      end
      assert_match(/captureSelector/, error.message)
    end
  end

  def test_rejects_wrong_watch_size
    with_fixture do |root|
      mutate_manifest(root, "watchos") do |manifest|
        manifest.fetch("specification")["selectedPixels"] = [422, 514]
      end
      error = assert_raises(QuakeSignalPlatformScreenshotPlan::Error) do
        load_plan("watchos", root: root)
      end
      assert_match(/selectedPixels/, error.message)
    end
  end

  def test_rejects_a_non_pending_or_prehashed_frame
    with_fixture do |root|
      mutate_manifest(root, "tvos") do |manifest|
        frame = manifest.fetch("frames").first
        frame["captureStatus"] = "approved"
        frame["sha256"] = "0" * 64
      end
      error = assert_raises(QuakeSignalPlatformScreenshotPlan::Error) do
        load_plan("tvos", root: root)
      end
      assert_match(/captureStatus/, error.message)
    end
  end

  def test_rejects_preexisting_capture_evidence_or_unreviewed_frame_fields
    with_fixture do |root|
      mutate_manifest(root, "visionos") do |manifest|
        manifest.fetch("captureEvidence")["reviewer"] = "Unreviewed Person"
      end
      error = assert_raises(QuakeSignalPlatformScreenshotPlan::Error) do
        load_plan("visionos", root: root)
      end
      assert_match(/captureEvidence/, error.message)
    end

    with_fixture do |root|
      mutate_manifest(root, "tvos") do |manifest|
        manifest.fetch("frames").first["uploadApproved"] = true
      end
      error = assert_raises(QuakeSignalPlatformScreenshotPlan::Error) do
        load_plan("tvos", root: root)
      end
      assert_match(/frames\[0\]\.keys/, error.message)
    end
  end

  def test_rejects_duplicate_json_keys
    with_fixture do |root|
      path = manifest_path(root, "tvos")
      source = path.read.sub(
        %Q[  "status": "planned-not-captured",\n],
        %Q[  "status": "planned-not-captured",\n  "status": "planned-not-captured",\n],
      )
      path.write(source)
      error = assert_raises(QuakeSignalPlatformScreenshotPlan::Error) do
        load_plan("tvos", root: root)
      end
      assert_match(/duplicate(?: JSON object)? key/, error.message)
    end
  end

  private

  def load_plan(platform, root: ROOT)
    QuakeSignalPlatformScreenshotPlan.load(platform, repository_root: root)
  end

  def with_fixture
    Dir.mktmpdir("quakesignal-platform-plan-test") do |directory|
      root = Pathname.new(directory)
      destination = root.join("ios/AppStore/platforms")
      destination.dirname.mkpath
      FileUtils.cp_r(ROOT.join("ios/AppStore/platforms"), destination)
      yield root
    end
  end

  def mutate_manifest(root, platform)
    path = manifest_path(root, platform)
    manifest = JSON.parse(path.read)
    yield manifest
    path.write(JSON.pretty_generate(manifest) + "\n")
  end

  def manifest_path(root, platform)
    root.join("ios/AppStore/platforms", platform, "screenshot-manifest-v1.1-build11.json")
  end
end
