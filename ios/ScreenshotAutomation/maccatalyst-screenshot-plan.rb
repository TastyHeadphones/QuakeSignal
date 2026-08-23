#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module QuakeSignalMacCatalystScreenshotPlan
  class Error < StandardError; end

  class DuplicateRejectingHash < Hash
    def []=(key, value)
      raise Error, "duplicate JSON object key is forbidden: #{key.inspect}" if key?(key)

      super
    end
  end

  MANIFEST = "ios/AppStore/platforms/maccatalyst/screenshot-manifest-v1.1-build12.json"
  PIXELS = [2_560, 1_600].freeze
  PRODUCT = {
    "appleId" => "6800642443",
    "platform" => "macOS-maccatalyst",
    "marketingVersion" => "1.1",
    "build" => 12,
    "bundleIdentifier" => "com.quakesignal.app",
    "scheme" => "QuakeSignal",
    "destination" => "platform=macOS,variant=Mac Catalyst",
    "designedForIPadOnMac" => false,
  }.freeze
  CAPTURE_EVIDENCE = {
    "sourceBaselineCommit" => nil,
    "debugArtifactSha256" => nil,
    "signedReleaseArtifactSha256" => nil,
    "macOSVersion" => nil,
    "xcodeVersion" => nil,
    "device" => nil,
    "capturedAtUtc" => nil,
    "reviewer" => nil,
    "signedReleaseParityApproved" => false,
    "uploadApproved" => false,
  }.freeze
  SPECIFICATION = {
    "officialUrl" => "https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/",
    "minimumCount" => 1,
    "maximumCount" => 10,
    "acceptedLandscapePixels" => [
      [1_280, 800],
      [1_440, 900],
      [2_560, 1_600],
      [2_880, 1_800],
    ],
    "selectedPixels" => PIXELS,
    "acceptedFormats" => %w[jpeg jpg png],
    "alphaAllowed" => false,
  }.freeze
  FRAMES = [
    ["maccatalyst-home", "en-US/01-home.png"],
    ["maccatalyst-reports", "en-US/02-reports.png"],
    ["maccatalyst-map", "en-US/03-map.png"],
    ["maccatalyst-guide", "en-US/04-guide.png"],
    ["maccatalyst-alert-preferences", "en-US/05-alert-preferences.png"],
  ].freeze

  module_function

  def repository_root
    Pathname.new(__dir__).join("../..").realpath
  end

  def load(repository_root: self.repository_root)
    root = Pathname.new(repository_root).realpath
    manifest_path = root.join(MANIFEST)
    source = manifest_path.read
    manifest = JSON.parse(
      source,
      object_class: DuplicateRejectingHash,
      allow_duplicate_key: false,
    )

    require_equal(
      manifest.keys.sort,
      %w[captureEvidence frames locales product schemaVersion specification status].sort,
      "top-level keys",
    )
    require_equal(manifest.fetch("schemaVersion"), 1, "schemaVersion")
    require_equal(manifest.fetch("status"), "planned-unapproved", "status")
    require_equal(manifest.fetch("product"), PRODUCT, "product")
    require_equal(manifest.fetch("specification"), SPECIFICATION, "specification")
    require_equal(manifest.fetch("captureEvidence"), CAPTURE_EVIDENCE, "captureEvidence")
    require_equal(
      manifest.fetch("locales"),
      [{ "directory" => "en-US", "publicationStatus" => "source-only-unapproved" }],
      "locales",
    )

    frames = manifest.fetch("frames")
    require_equal(frames.length, FRAMES.length, "frames.length")
    normalized_frames = frames.each_with_index.map do |frame, index|
      selector, file = FRAMES.fetch(index)
      label = "frames[#{index}]"
      require_equal(
        frame.keys.sort,
        %w[captureSelector captureStatus file pixels purpose screen setup sha256].sort,
        "#{label}.keys",
      )
      require_equal(frame.fetch("captureSelector"), selector, "#{label}.captureSelector")
      require_equal(frame.fetch("file"), file, "#{label}.file")
      require_equal(frame.fetch("pixels"), PIXELS, "#{label}.pixels")
      require_equal(frame.fetch("captureStatus"), "pending", "#{label}.captureStatus")
      require_equal(frame.fetch("sha256"), nil, "#{label}.sha256")
      %w[screen purpose setup].each do |field|
        value = frame.fetch(field)
        unless value.is_a?(String) && !value.strip.empty?
          raise Error, "#{label}.#{field} must be a non-empty string"
        end
      end

      {
        "captureSelector" => selector,
        "file" => file,
        "screen" => frame.fetch("screen"),
        "purpose" => frame.fetch("purpose"),
        "setup" => frame.fetch("setup"),
        "pixels" => PIXELS,
      }
    end

    {
      "schemaVersion" => 1,
      "platform" => "maccatalyst",
      "locale" => "en-US",
      "manifestFile" => MANIFEST,
      "manifestSha256" => Digest::SHA256.hexdigest(source),
      "frames" => normalized_frames,
    }
  rescue Errno::ENOENT => error
    raise Error, "Mac Catalyst screenshot manifest is missing: #{error.message}"
  rescue JSON::ParserError, KeyError, TypeError, NoMethodError => error
    raise Error, "invalid Mac Catalyst screenshot plan: #{error.message}"
  end

  def require_equal(actual, expected, label)
    return if actual == expected

    raise Error, "#{label} must be #{expected.inspect}; received #{actual.inspect}"
  end
  private_class_method :require_equal
end

if $PROGRAM_NAME == __FILE__
  begin
    unless (0..1).cover?(ARGV.length)
      abort "Usage: maccatalyst-screenshot-plan.rb [--json|--tsv]"
    end
    format = ARGV.fetch(0, "--json")
    plan = QuakeSignalMacCatalystScreenshotPlan.load
    case format
    when "--json"
      puts JSON.pretty_generate(plan)
    when "--tsv"
      plan.fetch("frames").each do |frame|
        values = [frame.fetch("captureSelector"), frame.fetch("file"), *frame.fetch("pixels")]
        abort "screenshot plan contains a tab or newline" if values.any? { |value| value.to_s.match?(/[\t\r\n]/) }
        puts values.join("\t")
      end
    else
      abort "unsupported output format #{format.inspect}; expected --json or --tsv"
    end
  rescue QuakeSignalMacCatalystScreenshotPlan::Error => error
    warn "error: #{error.message}"
    exit 65
  end
end
