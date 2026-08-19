#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module QuakeSignalPlatformScreenshotPlan
  class Error < StandardError; end

  class DuplicateRejectingHash < Hash
    def []=(key, value)
      raise Error, "duplicate JSON object key is forbidden: #{key.inspect}" if key?(key)

      super
    end
  end

  EXPECTED = {
    "tvos" => {
      manifest: "ios/AppStore/platforms/tvos/screenshot-manifest-v1.1-build8.json",
      product: {
        "platform" => "tvOS",
        "marketingVersion" => "1.1",
        "build" => 8,
        "bundleIdentifier" => "com.quakesignal.app",
        "scheme" => "QuakeSignalTV",
      },
      capture_evidence: {
        "sourceBaselineCommit" => nil,
        "signedArtifactSha256" => nil,
        "runtime" => nil,
        "device" => nil,
        "capturedAtUtc" => nil,
        "reviewer" => nil,
      },
      pixels: [1920, 1080],
      frames: [
        ["tvos-dashboard", "en-US/01-dashboard.png"],
        ["tvos-recent-reports", "en-US/02-recent-reports.png"],
        ["tvos-event-detail", "en-US/03-event-detail.png"],
      ],
    },
    "visionos" => {
      manifest: "ios/AppStore/platforms/visionos/screenshot-manifest-v1.1-build8.json",
      product: {
        "platform" => "visionOS",
        "marketingVersion" => "1.1",
        "build" => 8,
        "bundleIdentifier" => "com.quakesignal.app",
        "scheme" => "QuakeSignalVision",
      },
      capture_evidence: {
        "sourceBaselineCommit" => nil,
        "signedArtifactSha256" => nil,
        "runtime" => nil,
        "device" => nil,
        "capturedAtUtc" => nil,
        "reviewer" => nil,
        "appMotionAnswerApproved" => false,
      },
      pixels: [3840, 2160],
      frames: [
        ["visionos-home", "en-US/01-home.png"],
        ["visionos-reports", "en-US/02-reports.png"],
        ["visionos-map", "en-US/03-map.png"],
        ["visionos-guide", "en-US/04-guide.png"],
        ["visionos-alert-preferences", "en-US/05-alert-preferences.png"],
      ],
    },
    "watchos" => {
      manifest: "ios/AppStore/platforms/watchos/screenshot-manifest-v1.1-build8.json",
      product: {
        "platform" => "watchOS-companion",
        "marketingVersion" => "1.1",
        "build" => 8,
        "hostBundleIdentifier" => "com.quakesignal.app",
        "bundleIdentifier" => "com.quakesignal.app.watchkitapp",
        "scheme" => "QuakeSignalWatch",
        "delivery" => "embedded-in-ios-upload",
      },
      capture_evidence: {
        "sourceBaselineCommit" => nil,
        "signedHostArtifactSha256" => nil,
        "runtime" => nil,
        "pairedIPhone" => nil,
        "watchDevice" => nil,
        "capturedAtUtc" => nil,
        "reviewer" => nil,
      },
      pixels: [410, 502],
      frames: [
        ["watchos-headline", "en-US/01-headline.png"],
        ["watchos-recent-reports", "en-US/02-recent-reports.png"],
        ["watchos-event-detail", "en-US/03-event-detail.png"],
      ],
    },
  }.freeze

  module_function

  def repository_root
    Pathname.new(__dir__).join("../..").realpath
  end

  def load(platform, repository_root: self.repository_root)
    expected = EXPECTED.fetch(platform) do
      raise Error, "unsupported platform #{platform.inspect}; expected tvos, visionos, or watchos"
    end
    root = Pathname.new(repository_root).realpath
    manifest_path = root.join(expected.fetch(:manifest))
    source = manifest_path.read
    manifest = JSON.parse(source, object_class: DuplicateRejectingHash)

    require_equal(
      manifest.keys.sort,
      %w[captureEvidence frames locales product schemaVersion specification status].sort,
      "top-level keys",
    )
    require_equal(manifest.fetch("schemaVersion"), 1, "schemaVersion")
    require_equal(manifest.fetch("status"), "planned-not-captured", "status")
    require_equal(
      manifest.fetch("product"),
      { "appleId" => "6800642443" }.merge(expected.fetch(:product)),
      "product",
    )
    require_equal(manifest.fetch("captureEvidence"), expected.fetch(:capture_evidence), "captureEvidence")
    require_equal(
      manifest.fetch("specification").fetch("selectedPixels"),
      expected.fetch(:pixels),
      "specification.selectedPixels",
    )
    require_equal(
      manifest.fetch("locales"),
      [{ "directory" => "en-US", "publicationStatus" => "approved-primary-only" }],
      "locales",
    )

    frames = manifest.fetch("frames")
    raise Error, "frames must be an array" unless frames.is_a?(Array)
    expected_frames = expected.fetch(:frames)
    require_equal(frames.length, expected_frames.length, "frames.length")

    normalized_frames = frames.each_with_index.map do |frame, index|
      selector, file = expected_frames.fetch(index)
      label = "frames[#{index}]"
      require_equal(
        frame.keys.sort,
        %w[captureSelector captureStatus file pixels purpose screen setup sha256].sort,
        "#{label}.keys",
      )
      require_equal(frame.fetch("captureSelector"), selector, "#{label}.captureSelector")
      require_equal(frame.fetch("file"), file, "#{label}.file")
      require_equal(frame.fetch("pixels"), expected.fetch(:pixels), "#{label}.pixels")
      require_equal(frame.fetch("captureStatus"), "pending", "#{label}.captureStatus")
      require_equal(frame.fetch("sha256"), nil, "#{label}.sha256")
      %w[screen purpose setup].each do |field|
        value = frame.fetch(field)
        unless value.is_a?(String) && !value.strip.empty?
          raise Error, "#{label}.#{field} must be a non-empty string"
        end
      end
      unless file.match?(%r{\Aen-US/[0-9]{2}-[a-z0-9-]+\.png\z})
        raise Error, "#{label}.file is not a safe English PNG path"
      end

      {
        "captureSelector" => selector,
        "file" => file,
        "screen" => frame.fetch("screen"),
        "purpose" => frame.fetch("purpose"),
        "setup" => frame.fetch("setup"),
        "pixels" => expected.fetch(:pixels),
      }
    end

    {
      "schemaVersion" => 1,
      "platform" => platform,
      "locale" => "en-US",
      "manifestFile" => expected.fetch(:manifest),
      "manifestSha256" => Digest::SHA256.hexdigest(source),
      "frames" => normalized_frames,
    }
  rescue Errno::ENOENT => error
    raise Error, "screenshot plan manifest is missing: #{error.message}"
  rescue JSON::ParserError, KeyError, TypeError => error
    raise Error, "invalid #{platform} screenshot plan: #{error.message}"
  end

  def require_equal(actual, expected, label)
    return if actual == expected

    raise Error, "#{label} must be #{expected.inspect}; received #{actual.inspect}"
  end
  private_class_method :require_equal
end

if $PROGRAM_NAME == __FILE__
  begin
    unless (1..2).cover?(ARGV.length)
      abort "Usage: platform-screenshot-plan.rb <tvos|visionos|watchos> [--json|--tsv]"
    end
    platform = ARGV.fetch(0)
    format = ARGV.fetch(1, "--json")
    plan = QuakeSignalPlatformScreenshotPlan.load(platform)
    case format
    when "--json"
      puts JSON.pretty_generate(plan)
    when "--tsv"
      plan.fetch("frames").each do |frame|
        values = [
          frame.fetch("captureSelector"),
          frame.fetch("file"),
          *frame.fetch("pixels"),
        ]
        abort "screenshot plan contains a tab or newline" if values.any? { |value| value.to_s.match?(/[\t\r\n]/) }
        puts values.join("\t")
      end
    else
      abort "unsupported output format #{format.inspect}; expected --json or --tsv"
    end
  rescue QuakeSignalPlatformScreenshotPlan::Error => error
    warn "error: #{error.message}"
    exit 65
  end
end
