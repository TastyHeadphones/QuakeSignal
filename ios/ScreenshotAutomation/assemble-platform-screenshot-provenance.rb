#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "time"
require_relative "platform-screenshot-plan"

module QuakeSignalPlatformScreenshotProvenance
  class Error < StandardError; end

  module_function

  def assemble(platform:, capture_root:, output:, repository_root: QuakeSignalPlatformScreenshotPlan.repository_root)
    plan = QuakeSignalPlatformScreenshotPlan.load(platform, repository_root: repository_root)
    root = Pathname.new(capture_root).realpath
    output_path = Pathname.new(output)
    if output_path.exist? || output_path.symlink?
      raise Error, "capture-set provenance output already exists"
    end

    expected_pngs = plan.fetch("frames").map { |frame| frame.fetch("file") }.sort
    expected_evidence = plan.fetch("frames").map do |frame|
      "frame-capture-evidence/#{frame.fetch('captureSelector')}.json"
    end.sort
    actual_directories, actual_files = capture_inventory(root)
    expected_directories = %w[en-US frame-capture-evidence]
    expected_files = (expected_pngs + expected_evidence).sort
    unless actual_directories == expected_directories && actual_files == expected_files
      raise Error, "capture inventory differs from the exact plan: expected directories #{expected_directories.inspect} and files #{expected_files.inspect}; received directories #{actual_directories.inspect} and files #{actual_files.inspect}"
    end

    frames = plan.fetch("frames").map do |frame|
      selector = frame.fetch("captureSelector")
      screenshot_path = root.join(frame.fetch("file"))
      evidence_relative_path = "frame-capture-evidence/#{selector}.json"
      evidence_path = root.join(evidence_relative_path)
      evidence_source = evidence_path.read
      evidence = parse_json(evidence_source, evidence_relative_path)
      screenshot_sha256 = Digest::SHA256.file(screenshot_path).hexdigest

      require_equal(
        evidence.keys.sort,
        %w[captureSelector capturedAtUtc locale pixels plannedFile platform schemaVersion screenshotFile screenshotSha256 selectedSimulator status uploadApproved].sort,
        "#{selector} evidence keys",
      )
      require_equal(evidence.fetch("schemaVersion"), 1, "#{selector} evidence schemaVersion")
      require_equal(
        evidence.fetch("status"),
        "unapproved-debug-simulator-capture-evidence",
        "#{selector} evidence status",
      )
      require_equal(evidence.fetch("uploadApproved"), false, "#{selector} evidence uploadApproved")
      require_equal(evidence.fetch("platform"), platform, "#{selector} evidence platform")
      require_equal(evidence.fetch("locale"), "en", "#{selector} evidence locale")
      require_equal(evidence.fetch("captureSelector"), selector, "#{selector} evidence captureSelector")
      require_equal(evidence.fetch("plannedFile"), frame.fetch("file"), "#{selector} evidence plannedFile")
      require_equal(
        evidence.fetch("screenshotFile"),
        screenshot_path.basename.to_s,
        "#{selector} evidence screenshotFile",
      )
      require_equal(
        evidence.fetch("screenshotSha256"),
        screenshot_sha256,
        "#{selector} evidence screenshotSha256",
      )
      require_equal(evidence.fetch("pixels"), frame.fetch("pixels"), "#{selector} evidence pixels")
      captured_at = Time.iso8601(evidence.fetch("capturedAtUtc")).utc.iso8601
      selected_simulator = evidence.fetch("selectedSimulator")
      require_equal(
        selected_simulator.keys.sort,
        %w[deviceModel deviceTypeIdentifier runtimeIdentifier udid].sort,
        "#{selector} evidence selectedSimulator keys",
      )
      %w[runtimeIdentifier deviceTypeIdentifier deviceModel udid].each do |key|
        value = selected_simulator.fetch(key)
        unless value.is_a?(String) && !value.empty?
          raise Error, "#{selector} evidence selectedSimulator.#{key} is empty"
        end
      end

      {
        "captureSelector" => selector,
        "file" => frame.fetch("file"),
        "screen" => frame.fetch("screen"),
        "purpose" => frame.fetch("purpose"),
        "setup" => frame.fetch("setup"),
        "sha256" => screenshot_sha256,
        "pixels" => frame.fetch("pixels"),
        "capturedAtUtc" => captured_at,
        "selectedSimulator" => {
          "runtimeIdentifier" => selected_simulator.fetch("runtimeIdentifier"),
          "deviceTypeIdentifier" => selected_simulator.fetch("deviceTypeIdentifier"),
          "deviceModel" => selected_simulator.fetch("deviceModel"),
          "udid" => selected_simulator.fetch("udid"),
        },
        "captureEvidenceFile" => evidence_relative_path,
        "captureEvidenceSha256" => Digest::SHA256.hexdigest(evidence_source),
      }
    rescue Errno::ENOENT, KeyError, TypeError, ArgumentError => error
      raise Error, "invalid capture evidence for #{selector}: #{error.message}"
    end

    captured_at_values = frames.map { |frame| frame.fetch("capturedAtUtc") }
    aggregate = {
      "schemaVersion" => 2,
      "status" => "unapproved-debug-simulator-capture-set-evidence",
      "uploadApproved" => false,
      "releaseBinaryEvidence" => nil,
      "reviewer" => nil,
      "platform" => platform,
      "locale" => plan.fetch("locale"),
      "fixture" => "finalized-historical-reports",
      "planManifest" => {
        "file" => plan.fetch("manifestFile"),
        "sha256" => plan.fetch("manifestSha256"),
      },
      "captureWindowUtc" => {
        "startedAt" => captured_at_values.min,
        "completedAt" => captured_at_values.max,
      },
      "frames" => frames,
      "approvalRequired" => "Named visual review and runbook-required signed Release parity comparison",
    }

    output_path.dirname.mkpath
    output_path.write(JSON.pretty_generate(aggregate) + "\n", mode: "wx")
    aggregate
  rescue QuakeSignalPlatformScreenshotPlan::Error => error
    raise Error, error.message
  end

  def capture_inventory(root)
    directories = []
    files = []
    visit = lambda do |directory|
      directory.children.sort_by(&:to_s).each do |entry|
        relative = entry.relative_path_from(root).to_s
        stat = entry.lstat
        if stat.directory?
          directories << relative
          visit.call(entry)
        elsif stat.file?
          files << relative
        else
          raise Error, "capture inventory contains a symlink or non-regular entry: #{relative}"
        end
      end
    end
    visit.call(root)
    [directories.sort, files.sort]
  rescue Errno::ENOENT => error
    raise Error, "capture inventory changed while it was inspected: #{error.message}"
  end
  private_class_method :capture_inventory

  def parse_json(source, label)
    JSON.parse(
      source,
      object_class: QuakeSignalPlatformScreenshotPlan::DuplicateRejectingHash,
      allow_duplicate_key: false,
    )
  rescue JSON::ParserError, QuakeSignalPlatformScreenshotPlan::Error => error
    raise Error, "invalid JSON in #{label}: #{error.message}"
  end
  private_class_method :parse_json

  def require_equal(actual, expected, label)
    return if actual == expected

    raise Error, "#{label} must be #{expected.inspect}; received #{actual.inspect}"
  end
  private_class_method :require_equal
end

if $PROGRAM_NAME == __FILE__
  begin
    unless ARGV.length == 3
      abort "Usage: assemble-platform-screenshot-provenance.rb <tvos|visionos|watchos> <capture-root> <output.json>"
    end
    QuakeSignalPlatformScreenshotProvenance.assemble(
      platform: ARGV.fetch(0),
      capture_root: ARGV.fetch(1),
      output: ARGV.fetch(2),
    )
  rescue QuakeSignalPlatformScreenshotProvenance::Error => error
    warn "error: #{error.message}"
    exit 65
  end
end
