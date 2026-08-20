#!/usr/bin/ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "ios-screenshot-plan"
require_relative "screenshot-test-temp-root"

class IOSScreenshotPlanTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../..").realpath

  def test_checked_in_plan_expands_to_exact_ten_english_frames
    plan = load_plan
    assert_equal "Debug", plan.fetch("configuration")
    assert_equal 10, plan.fetch("frames").length
    assert_equal(
      %w[
        ios-iphone-6.5-home ios-iphone-6.5-reports ios-iphone-6.5-map
        ios-iphone-6.5-guide ios-iphone-6.5-alert-preferences
        ios-ipad-13-home ios-ipad-13-reports ios-ipad-13-map
        ios-ipad-13-guide ios-ipad-13-alert-preferences
      ],
      plan.fetch("frames").map { |frame| frame.fetch("captureSelector") },
    )
    assert_equal Array.new(5, [1242, 2688]) + Array.new(5, [2064, 2752]),
                 plan.fetch("frames").map { |frame| frame.fetch("pixels") }
    assert plan.fetch("frames").all? { |frame| frame.fetch("file").start_with?("en-US/") }
  end

  def test_rejects_release_configuration
    with_fixture do |root|
      mutate(root) { |manifest| manifest.fetch("product")["configuration"] = "Release" }
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/product/, error.message)
    end
  end

  def test_rejects_alternate_display_size_or_class
    with_fixture do |root|
      mutate(root) do |manifest|
        manifest.fetch("displayClasses").fetch("iphone-6.5")["portraitPixels"] = [1284, 2778]
      end
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/iphone-6\.5/, error.message)
    end

    with_fixture do |root|
      mutate(root) do |manifest|
        manifest.fetch("displayClasses")["iphone-6.9"] =
          manifest.fetch("displayClasses").delete("iphone-6.5")
      end
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/displayClasses order/, error.message)
    end
  end

  def test_rejects_non_english_primary_or_prepublished_localization
    with_fixture do |root|
      mutate(root) do |manifest|
        manifest.fetch("locales").first["directory"] = "ja"
      end
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/locales/, error.message)
    end

    with_fixture do |root|
      mutate(root) do |manifest|
        manifest.fetch("locales").fetch(1)["publicationStatus"] = "approved-primary-only"
      end
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/locales/, error.message)
    end
  end

  def test_rejects_removed_reordered_or_preapproved_frame
    with_fixture do |root|
      mutate(root) { |manifest| manifest.fetch("frames").pop }
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/frames\.length/, error.message)
    end

    with_fixture do |root|
      mutate(root) { |manifest| manifest.fetch("frames").rotate! }
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/frames\[0\]\.(?:captureSelector|displayClass|file)/, error.message)
    end

    with_fixture do |root|
      mutate(root) { |manifest| manifest.fetch("frames").first["captureStatus"] = "approved" }
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/captureStatus/, error.message)
    end
  end

  def test_rejects_missing_cross_class_or_duplicate_explicit_selector_binding
    with_fixture do |root|
      mutate(root) { |manifest| manifest.fetch("frames").first.delete("captureSelector") }
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/frames\[0\]\.keys/, error.message)
    end

    with_fixture do |root|
      mutate(root) do |manifest|
        manifest.fetch("frames").first["displayClass"] = "ipad-13"
      end
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/frames\[0\]\.displayClass/, error.message)
    end

    with_fixture do |root|
      mutate(root) do |manifest|
        manifest.fetch("frames").fetch(1)["captureSelector"] =
          manifest.fetch("frames").first.fetch("captureSelector")
      end
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/frames\[1\]\.captureSelector/, error.message)
    end
  end

  def test_rejects_capture_hash_reviewer_or_unknown_frame_field
    with_fixture do |root|
      mutate(root) { |manifest| manifest.fetch("captureEvidence")["reviewer"] = "Premature Reviewer" }
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/captureEvidence/, error.message)
    end

    with_fixture do |root|
      mutate(root) { |manifest| manifest.fetch("frames").first["sha256"] = "0" * 64 }
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/frames\[0\]\.keys/, error.message)
    end
  end

  def test_rejects_duplicate_json_keys
    with_fixture do |root|
      path = manifest_path(root)
      source = path.read.sub(
        %Q[  "status": "planned-not-captured",\n],
        %Q[  "status": "planned-not-captured",\n  "status": "planned-not-captured",\n],
      )
      path.write(source)
      error = assert_raises(QuakeSignalIOSScreenshotPlan::Error) { load_plan(root: root) }
      assert_match(/duplicate(?: JSON object)? key/, error.message)
    end
  end

  private

  def load_plan(root: ROOT)
    QuakeSignalIOSScreenshotPlan.load(repository_root: root)
  end

  def with_fixture
    Dir.mktmpdir(
      "quakesignal-ios-plan-test",
      QuakeSignalScreenshotTestTempRoot.path.to_s,
    ) do |directory|
      root = Pathname.new(directory)
      destination = manifest_path(root)
      destination.dirname.mkpath
      FileUtils.cp(ROOT.join(QuakeSignalIOSScreenshotPlan::MANIFEST), destination)
      yield root
    end
  end

  def mutate(root)
    path = manifest_path(root)
    manifest = JSON.parse(path.read)
    yield manifest
    path.write(JSON.pretty_generate(manifest) + "\n")
  end

  def manifest_path(root)
    root.join(QuakeSignalIOSScreenshotPlan::MANIFEST)
  end
end
