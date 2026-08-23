#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module QuakeSignalIOSScreenshotPlan
  class Error < StandardError; end

  class DuplicateRejectingHash < Hash
    def []=(key, value)
      raise Error, "duplicate JSON object key is forbidden: #{key.inspect}" if key?(key)

      super
    end
  end

  MANIFEST = "ios/AppStore/screenshot-manifest-v1.1-build17.template.json"
  PRODUCT = {
    "appleId" => "6800642443",
    "platform" => "iOS/iPadOS",
    "marketingVersion" => "1.1",
    "build" => 17,
    "bundleIdentifier" => "com.quakesignal.app",
    "configuration" => "Debug",
  }.freeze
  CAPTURE_EVIDENCE = {
    "sourceBaselineCommit" => nil,
    "artifactSha256" => nil,
    "xcode" => nil,
    "runtime" => nil,
    "devices" => [],
    "capturedAtUtcRange" => nil,
    "reviewer" => nil,
  }.freeze
  LOCALES = [
    {
      "directory" => "en-US",
      "appleLanguage" => "en-US",
      "appleLocale" => "en_US",
      "publicationStatus" => "approved-primary-only",
    },
    {
      "directory" => "ja",
      "appleLanguage" => "ja",
      "appleLocale" => "ja_JP",
      "publicationStatus" => "pending-name-and-availability-approval",
    },
    {
      "directory" => "zh-Hans",
      "appleLanguage" => "zh-Hans",
      "appleLocale" => "zh_CN",
      "publicationStatus" => "pending-name-and-availability-approval",
    },
  ].freeze
  DISPLAY_CLASSES = {
    "iphone-6.5" => {
      "device" => "iPhone 11 Pro Max",
      "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max",
      "portraitPixels" => [1242, 2688],
      "requiredFramesPerApprovedLocale" => 5,
    },
    "ipad-13" => {
      "device" => "iPad Pro 13-inch (M4)",
      "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB",
      "portraitPixels" => [2064, 2752],
      "requiredFramesPerApprovedLocale" => 5,
    },
  }.freeze
  BASE_FRAMES = DISPLAY_CLASSES.keys.flat_map do |display_class|
    [
      ["home", "01-home.jpg", "Home"],
      ["reports", "02-reports.jpg", "Reports"],
      ["map", "03-map.jpg", "Map"],
      ["guide", "04-guide.jpg", "Preparedness Guide"],
      ["alert-preferences", "05-alert-preferences.jpg", "Alert Sound"],
    ].map do |name, file, screen|
      ["ios-#{display_class}-#{name}", display_class, name, file, screen]
    end
  end.freeze

  module_function

  def repository_root
    Pathname.new(__dir__).join("../..").realpath
  end

  def load(repository_root: self.repository_root)
    root = Pathname.new(repository_root).realpath
    path = root.join(MANIFEST)
    source = path.read
    manifest = JSON.parse(
      source,
      object_class: DuplicateRejectingHash,
      allow_duplicate_key: false,
    )

    require_equal(
      manifest.keys.sort,
      %w[
        schemaVersion status purpose product rootDirectory captureEvidence locales
        displayClasses frames requiredBeforeApproval
      ].sort,
      "top-level keys",
    )
    require_equal(manifest.fetch("schemaVersion"), 1, "schemaVersion")
    require_equal(manifest.fetch("status"), "planned-not-captured", "status")
    require_nonempty_string(manifest.fetch("purpose"), "purpose")
    require_equal(manifest.fetch("product"), PRODUCT, "product")
    require_equal(manifest.fetch("rootDirectory"), "screenshots-v1.1-build17", "rootDirectory")
    require_equal(manifest.fetch("captureEvidence"), CAPTURE_EVIDENCE, "captureEvidence")
    require_equal(manifest.fetch("locales"), LOCALES, "locales")
    validate_display_classes!(manifest.fetch("displayClasses"))
    frames = validate_base_frames!(manifest.fetch("frames"))
    validate_required_before_approval!(manifest.fetch("requiredBeforeApproval"))

    expanded = frames.map do |frame|
      display_class = frame.fetch("displayClass")
      specification = DISPLAY_CLASSES.fetch(display_class)
      {
        "captureSelector" => frame.fetch("captureSelector"),
        "displayClass" => display_class,
        "device" => specification.fetch("device"),
        "deviceTypeIdentifier" => specification.fetch("deviceTypeIdentifier"),
        "file" => "en-US/#{display_class}/#{frame.fetch('file')}",
        "screen" => frame.fetch("screen"),
        "purpose" => frame.fetch("purpose"),
        "pixels" => specification.fetch("portraitPixels"),
        "format" => "jpeg",
      }
    end

    {
      "schemaVersion" => 1,
      "platform" => "ios-ipados",
      "locale" => "en-US",
      "appleLocale" => "en_US",
      "configuration" => "Debug",
      "scheme" => "QuakeSignal",
      "bundleIdentifier" => "com.quakesignal.app",
      "manifestFile" => MANIFEST,
      "manifestSha256" => Digest::SHA256.hexdigest(source),
      "frames" => expanded,
    }
  rescue Errno::ENOENT => error
    raise Error, "iOS/iPadOS screenshot plan manifest is missing: #{error.message}"
  rescue JSON::ParserError, KeyError, TypeError => error
    raise Error, "invalid iOS/iPadOS screenshot plan: #{error.message}"
  end

  def validate_display_classes!(classes)
    unless classes.is_a?(Hash)
      raise Error, "displayClasses must be an object"
    end
    require_equal(classes.keys, DISPLAY_CLASSES.keys, "displayClasses order")
    classes.each do |name, value|
      expected = DISPLAY_CLASSES.fetch(name).reject { |key, _value| key == "deviceTypeIdentifier" }
      require_equal(value, expected, "displayClasses.#{name}")
    end
  end
  private_class_method :validate_display_classes!

  def validate_base_frames!(frames)
    raise Error, "frames must be an array" unless frames.is_a?(Array)
    require_equal(frames.length, BASE_FRAMES.length, "frames.length")

    frames.each_with_index.map do |frame, index|
      capture_selector, display_class, name, file, screen = BASE_FRAMES.fetch(index)
      label = "frames[#{index}]"
      require_equal(
        frame.keys.sort,
        %w[captureSelector displayClass file screen purpose captureStatus].sort,
        "#{label}.keys",
      )
      require_equal(frame.fetch("captureSelector"), capture_selector, "#{label}.captureSelector")
      require_equal(frame.fetch("displayClass"), display_class, "#{label}.displayClass")
      require_equal(frame.fetch("file"), file, "#{label}.file")
      require_equal(frame.fetch("screen"), screen, "#{label}.screen")
      require_equal(frame.fetch("captureStatus"), "pending", "#{label}.captureStatus")
      require_nonempty_string(frame.fetch("purpose"), "#{label}.purpose")
      unless file.match?(/\A[0-9]{2}-[a-z0-9-]+\.jpg\z/)
        raise Error, "#{label}.file is not a safe JPEG basename"
      end
      {
        "captureSelector" => capture_selector,
        "displayClass" => display_class,
        "name" => name,
        "file" => file,
        "screen" => screen,
        "purpose" => frame.fetch("purpose"),
      }
    end
  end
  private_class_method :validate_base_frames!

  def validate_required_before_approval!(requirements)
    unless requirements.is_a?(Array) && requirements.length == 4
      raise Error, "requiredBeforeApproval must contain exactly four safeguards"
    end
    requirements.each_with_index do |value, index|
      require_nonempty_string(value, "requiredBeforeApproval[#{index}]")
    end
    joined = requirements.join(" ").downcase
    %w[sha-256 dimensions source commit reviewer].each do |required_term|
      unless joined.include?(required_term)
        raise Error, "requiredBeforeApproval is missing #{required_term.inspect} safeguard"
      end
    end
  end
  private_class_method :validate_required_before_approval!

  def require_nonempty_string(value, label)
    return if value.is_a?(String) && !value.strip.empty?

    raise Error, "#{label} must be a non-empty string"
  end
  private_class_method :require_nonempty_string

  def require_equal(actual, expected, label)
    return if actual == expected

    raise Error, "#{label} must be #{expected.inspect}; received #{actual.inspect}"
  end
  private_class_method :require_equal
end

if $PROGRAM_NAME == __FILE__
  begin
    unless (0..1).cover?(ARGV.length)
      abort "Usage: ios-screenshot-plan.rb [--json|--tsv]"
    end
    format = ARGV.fetch(0, "--json")
    plan = QuakeSignalIOSScreenshotPlan.load
    case format
    when "--json"
      puts JSON.pretty_generate(plan)
    when "--tsv"
      plan.fetch("frames").each do |frame|
        values = [
          frame.fetch("captureSelector"),
          frame.fetch("displayClass"),
          frame.fetch("deviceTypeIdentifier"),
          frame.fetch("file"),
          *frame.fetch("pixels"),
        ]
        if values.any? { |value| value.to_s.match?(/[\t\r\n]/) }
          abort "iOS/iPadOS screenshot plan contains a tab or newline"
        end
        puts values.join("\t")
      end
    else
      abort "unsupported output format #{format.inspect}; expected --json or --tsv"
    end
  rescue QuakeSignalIOSScreenshotPlan::Error => error
    warn "error: #{error.message}"
    exit 65
  end
end
