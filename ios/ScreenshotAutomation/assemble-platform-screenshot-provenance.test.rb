#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "assemble-platform-screenshot-provenance"

class PlatformScreenshotProvenanceTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../..").realpath

  def test_assembles_exact_unapproved_frame_inventory
    with_capture_fixture("tvos") do |capture_root, output|
      aggregate = assemble("tvos", capture_root, output)
      assert_equal 2, aggregate.fetch("schemaVersion")
      assert_equal false, aggregate.fetch("uploadApproved")
      assert_nil aggregate.fetch("releaseBinaryEvidence")
      assert_nil aggregate.fetch("reviewer")
      assert_equal 3, aggregate.fetch("frames").length
      assert_equal(
        %w[tvos-dashboard tvos-recent-reports tvos-event-detail],
        aggregate.fetch("frames").map { |frame| frame.fetch("captureSelector") },
      )
      assert output.file?
    end
  end

  def test_rejects_missing_or_unexpected_png
    with_capture_fixture("watchos") do |capture_root, output|
      capture_root.join("en-US/02-recent-reports.png").delete
      capture_root.join("en-US/99-unplanned.png").binwrite("unexpected")
      error = assert_raises(QuakeSignalPlatformScreenshotProvenance::Error) do
        assemble("watchos", capture_root, output)
      end
      assert_match(/inventory differs/, error.message)
      refute output.exist?
    end
  end

  def test_rejects_extra_files_symlinks_and_unreviewed_evidence_fields
    with_capture_fixture("tvos") do |capture_root, output|
      capture_root.join("frame-capture-evidence/unreviewed.json").write("{}\n")
      error = assert_raises(QuakeSignalPlatformScreenshotProvenance::Error) do
        assemble("tvos", capture_root, output)
      end
      assert_match(/inventory differs/, error.message)
      refute output.exist?
    end

    with_capture_fixture("tvos") do |capture_root, output|
      capture_root.join("unreviewed-link").make_symlink(capture_root.join("en-US"))
      error = assert_raises(QuakeSignalPlatformScreenshotProvenance::Error) do
        assemble("tvos", capture_root, output)
      end
      assert_match(/symlink or non-regular/, error.message)
      refute output.exist?
    end

    with_capture_fixture("tvos") do |capture_root, output|
      evidence_path = capture_root.join("frame-capture-evidence/tvos-dashboard.json")
      evidence = JSON.parse(evidence_path.read)
      evidence["reviewer"] = "Unreviewed Person"
      evidence_path.write(JSON.pretty_generate(evidence) + "\n")
      error = assert_raises(QuakeSignalPlatformScreenshotProvenance::Error) do
        assemble("tvos", capture_root, output)
      end
      assert_match(/evidence keys/, error.message)
      refute output.exist?
    end
  end

  def test_rejects_hash_or_selector_mismatch
    with_capture_fixture("visionos") do |capture_root, output|
      evidence_path = capture_root.join("frame-capture-evidence/visionos-map.json")
      evidence = JSON.parse(evidence_path.read)
      evidence["captureSelector"] = "visionos-home"
      evidence_path.write(JSON.pretty_generate(evidence) + "\n")
      error = assert_raises(QuakeSignalPlatformScreenshotProvenance::Error) do
        assemble("visionos", capture_root, output)
      end
      assert_match(/captureSelector/, error.message)
      refute output.exist?
    end
  end

  private

  def assemble(platform, capture_root, output)
    QuakeSignalPlatformScreenshotProvenance.assemble(
      platform: platform,
      capture_root: capture_root,
      output: output,
      repository_root: ROOT,
    )
  end

  def with_capture_fixture(platform)
    Dir.mktmpdir("quakesignal-platform-provenance-test") do |directory|
      capture_root = Pathname.new(directory).join("capture")
      capture_root.join("en-US").mkpath
      capture_root.join("frame-capture-evidence").mkpath
      plan = QuakeSignalPlatformScreenshotPlan.load(platform, repository_root: ROOT)
      plan.fetch("frames").each_with_index do |frame, index|
        screenshot_path = capture_root.join(frame.fetch("file"))
        screenshot_path.binwrite("frame-#{index}-#{frame.fetch('captureSelector')}")
        evidence = {
          "schemaVersion" => 1,
          "status" => "unapproved-debug-simulator-capture-evidence",
          "uploadApproved" => false,
          "platform" => platform,
          "locale" => "en",
          "captureSelector" => frame.fetch("captureSelector"),
          "plannedFile" => frame.fetch("file"),
          "screenshotFile" => screenshot_path.basename.to_s,
          "screenshotSha256" => Digest::SHA256.file(screenshot_path).hexdigest,
          "pixels" => frame.fetch("pixels"),
          "capturedAtUtc" => "2026-08-19T01:0#{index}:00Z",
          "selectedSimulator" => {
            "runtimeIdentifier" => "runtime-#{index}",
            "deviceTypeIdentifier" => "device-type-#{index}",
            "deviceModel" => "Device #{index}",
            "udid" => "udid-#{index}",
          },
        }
        evidence_path = capture_root.join(
          "frame-capture-evidence/#{frame.fetch('captureSelector')}.json",
        )
        evidence_path.write(JSON.pretty_generate(evidence) + "\n")
      end
      yield capture_root, Pathname.new(directory).join("aggregate.json")
    end
  end
end
