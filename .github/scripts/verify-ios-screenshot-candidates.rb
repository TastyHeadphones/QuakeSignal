#!/usr/bin/env ruby
# frozen_string_literal: true

# Fail-closed integrity validation for the preserved QuakeSignal 1.1 (8)
# iPhone/iPad Debug Simulator candidate set. These bytes are historical and
# permanently ineligible for upload. Current-source eligibility is a separate,
# mandatory contract in verify-apple-screenshot-release-set.rb.

require "digest"
require "json"
require "open3"
require "pathname"
require "set"
require "time"
require "yaml"

class IOSBuild8ScreenshotCandidateValidationError < StandardError; end

class DuplicateRejectingJSONObject < Hash
  def []=(key, value)
    if key?(key)
      raise IOSBuild8ScreenshotCandidateValidationError,
            "duplicate JSON object key is forbidden: #{key.inspect}"
    end

    super
  end
end

class IOSBuild8ScreenshotSourceGuard
  APP_SOURCE_PATHS = %w[
    ios/QuakeSignal
    ios/QuakeSignalShared
    ios/project.yml
    ios/QuakeSignal.xcodeproj/project.pbxproj
    ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignal.xcscheme
  ].freeze

  def initialize(root)
    @root = Pathname.new(root).realpath
  end

  def validate!(source_commit)
    run_git!("cat-file", "-e", "#{source_commit}^{commit}", failure: "source baseline commit is unavailable")
    run_git!(
      "merge-base", "--is-ancestor", source_commit, "HEAD",
      failure: "source baseline commit is not an ancestor of HEAD",
    )

    _output, error_output, status = Open3.capture3(
      "git", "-C", @root.to_s, "diff", "--no-ext-diff", "--quiet", source_commit, "--", *APP_SOURCE_PATHS,
    )
    case status.exitstatus
    when 0
      # No tracked app-source drift from the captured source commit.
    when 1
      raise IOSBuild8ScreenshotCandidateValidationError,
            "iOS app source changed after the screenshot source baseline commit"
    else
      detail = error_output.strip
      suffix = detail.empty? ? "" : ": #{detail}"
      raise IOSBuild8ScreenshotCandidateValidationError, "could not compare iOS app source to baseline#{suffix}"
    end

    untracked, = run_git!(
      "ls-files", "--others", "--exclude-standard", "--", *APP_SOURCE_PATHS,
      failure: "could not inspect untracked iOS app source",
    )
    return if untracked.strip.empty?

    paths = untracked.lines.map(&:strip).reject(&:empty?).join(", ")
    raise IOSBuild8ScreenshotCandidateValidationError,
          "untracked iOS app source exists after screenshot capture: #{paths}"
  end

  private

  def run_git!(*arguments, failure:)
    output, error_output, status = Open3.capture3("git", "-C", @root.to_s, *arguments)
    return [output, error_output] if status.success?

    detail = error_output.strip
    detail = output.strip if detail.empty?
    suffix = detail.empty? ? "" : ": #{detail}"
    raise IOSBuild8ScreenshotCandidateValidationError, "#{failure}#{suffix}"
  end
end

class IOSBuild8ScreenshotHistoricalCommitGuard
  def initialize(root)
    @root = Pathname.new(root).realpath
  end

  def validate!(source_commit)
    run_git!("cat-file", "-e", "#{source_commit}^{commit}", failure: "historical source commit is unavailable")
    run_git!(
      "merge-base", "--is-ancestor", source_commit, "HEAD",
      failure: "historical source commit is not an ancestor of HEAD",
    )
    true
  end

  private

  def run_git!(*arguments, failure:)
    output, error_output, status = Open3.capture3("git", "-C", @root.to_s, *arguments)
    return output if status.success?

    detail = error_output.strip
    detail = output.strip if detail.empty?
    suffix = detail.empty? ? "" : ": #{detail}"
    raise IOSBuild8ScreenshotCandidateValidationError, "#{failure}#{suffix}"
  end
end

class SipsScreenshotInspector
  def inspect(path)
    output, status = Open3.capture2e(
      "sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", "-g", "hasAlpha", path.to_s,
    )
    unless status.success?
      raise IOSBuild8ScreenshotCandidateValidationError,
            "could not inspect screenshot #{path}: #{output.strip}"
    end

    properties = output.each_line.each_with_object({}) do |line, values|
      match = line.match(/^\s*(pixelWidth|pixelHeight|format|hasAlpha):\s*(.+?)\s*$/)
      values[match[1]] = match[2] if match
    end
    {
      width: Integer(properties.fetch("pixelWidth")),
      height: Integer(properties.fetch("pixelHeight")),
      format: properties.fetch("format").downcase,
      has_alpha: properties.fetch("hasAlpha").downcase != "no",
    }
  rescue KeyError, ArgumentError => error
    raise IOSBuild8ScreenshotCandidateValidationError,
          "could not read screenshot properties for #{path}: #{error.message}"
  end
end

class ListingAssetsWorkflowContract
  CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1".freeze
  FORBIDDEN_STEP_KEYS = %w[shell working-directory env if continue-on-error].freeze
  FORBIDDEN_WORKFLOW_KEYS = %w[env defaults].freeze
  FORBIDDEN_JOB_KEYS = %w[if continue-on-error env defaults].freeze
  REQUIRED_PATHS = %w[
    assets/app-icon.svg
    ios/AppStore/**
    ios/ScreenshotAutomation/**
    ios/QuakeSignal/**
    ios/QuakeSignalShared/**
    ios/QuakeSignalTV/**
    ios/QuakeSignalVision/**
    ios/QuakeSignalWatch/**
    ios/project.yml
    ios/QuakeSignal.xcodeproj/project.pbxproj
    ios/QuakeSignal.xcodeproj/project.xcworkspace/contents.xcworkspacedata
    ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignal.xcscheme
    ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/**
    .github/scripts/verify-ios-screenshot-candidates.rb
    .github/scripts/verify-ios-screenshot-candidates.test.rb
    .github/scripts/verify-store-assets.rb
    .github/scripts/verify-store-assets.test.rb
    .github/scripts/verify-native-apple-screenshot-candidates.rb
    .github/scripts/verify-native-apple-screenshot-candidates.test.rb
    .github/scripts/verify-apple-screenshot-release-set.rb
    .github/scripts/verify-apple-screenshot-release-set.test.rb
    .github/scripts/verify-ios-release-contract.mjs
    .github/scripts/verify-ios-release-contract.test.mjs
    .github/workflows/apple-platform-screenshots.yml
    .github/workflows/listing-assets.yml
    .github/workflows/workflow-lint.yml
  ].freeze
  REQUIRED_COMMANDS = %w[
    ruby\ .github/scripts/verify-store-assets.rb
    ruby\ .github/scripts/verify-store-assets.test.rb
    ruby\ .github/scripts/verify-ios-screenshot-candidates.test.rb
    ruby\ .github/scripts/verify-ios-screenshot-candidates.rb
    ruby\ .github/scripts/verify-native-apple-screenshot-candidates.test.rb
    ruby\ .github/scripts/verify-native-apple-screenshot-candidates.rb
    ruby\ .github/scripts/verify-apple-screenshot-release-set.test.rb
    ruby\ .github/scripts/verify-apple-screenshot-release-set.rb
  ].freeze

  def self.validate!(source)
    workflow = YAML.safe_load(source, aliases: false)
    unless workflow.is_a?(Hash)
      raise IOSBuild8ScreenshotCandidateValidationError, "listing-assets workflow must be a mapping"
    end
    forbidden_workflow_keys = workflow.keys & FORBIDDEN_WORKFLOW_KEYS
    unless forbidden_workflow_keys.empty?
      raise IOSBuild8ScreenshotCandidateValidationError,
            "listing-assets workflow must not define inherited execution settings: " \
            "#{forbidden_workflow_keys.sort.join(', ')}"
    end

    triggers = workflow["on"] || workflow[true]
    unless triggers.is_a?(Hash)
      raise IOSBuild8ScreenshotCandidateValidationError, "listing-assets workflow triggers are missing"
    end

    %w[push pull_request].each do |event|
      paths = triggers.fetch(event).fetch("paths")
      missing = REQUIRED_PATHS - paths
      next if missing.empty?

      raise IOSBuild8ScreenshotCandidateValidationError,
            "listing-assets #{event} paths do not cover screenshot candidate inputs: #{missing.join(', ')}"
    end

    jobs = workflow.fetch("jobs")
    validate_job = jobs.fetch("validate")
    forbidden_job_keys = validate_job.keys & FORBIDDEN_JOB_KEYS
    unless forbidden_job_keys.empty?
      raise IOSBuild8ScreenshotCandidateValidationError,
            "listing-assets validate job must not define execution modifiers: " \
            "#{forbidden_job_keys.sort.join(', ')}"
    end
    steps = validate_job.fetch("steps")
    checkout_steps = steps.select { |step| step["uses"].to_s.start_with?("actions/checkout@") }
    unless checkout_steps.length == 1
      raise IOSBuild8ScreenshotCandidateValidationError,
            "listing-assets workflow must contain exactly one checkout step"
    end
    checkout = checkout_steps.first
    unless checkout.fetch("uses") == CHECKOUT_ACTION
      raise IOSBuild8ScreenshotCandidateValidationError,
            "listing-assets checkout action must use the reviewed pinned commit"
    end
    unless checkout.fetch("with", {}) == { "fetch-depth" => 0 }
      raise IOSBuild8ScreenshotCandidateValidationError,
            "listing-assets checkout must use only fetch-depth: 0 for source-ancestor validation"
    end
    reject_skippable_step!(checkout, "listing-assets checkout")

    REQUIRED_COMMANDS.each do |command|
      related_steps = steps.select do |candidate|
        run = candidate["run"]
        run.is_a?(String) && run.include?(command)
      end
      unless related_steps.length == 1 && related_steps.first.fetch("run").strip == command
        raise IOSBuild8ScreenshotCandidateValidationError,
              "listing-assets validator must be one exact command: #{command}"
      end
      reject_skippable_step!(related_steps.first, "listing-assets #{command}")
    end
    true
  rescue Psych::SyntaxError, KeyError, NoMethodError => error
    raise IOSBuild8ScreenshotCandidateValidationError,
          "invalid listing-assets workflow contract: #{error.message}"
  end

  def self.reject_skippable_step!(step, label)
    forbidden = step.keys & FORBIDDEN_STEP_KEYS
    unless forbidden.empty?
      raise IOSBuild8ScreenshotCandidateValidationError,
            "#{label} step must not use execution modifiers: #{forbidden.sort.join(', ')}"
    end
  end
end

class IOSBuild8ScreenshotCandidateValidator
  MANIFEST_NAME = "screenshot-manifest-v1.1-build10.json"
  PROVENANCE_NAME = "screenshot-provenance-v1.1-build10.json"
  SCREENSHOT_ROOT = "screenshots-v1.1-build10"
  BUILD_EVIDENCE_ROOT = "screenshot-evidence-v1.1-build10"
  BUILD_EVIDENCE_FILES = {
    "buildInvocation" => File.join(BUILD_EVIDENCE_ROOT, "build-invocation.txt"),
    "normalizedBuildSettings" => File.join(BUILD_EVIDENCE_ROOT, "normalized-build-settings.txt"),
    "normalizedBuildLog" => File.join(BUILD_EVIDENCE_ROOT, "normalized-build.log"),
    "transformationRecord" => File.join(BUILD_EVIDENCE_ROOT, "simulator-install-transformation.txt"),
    "sourceNonWatchInventory" => File.join(BUILD_EVIDENCE_ROOT, "source-non-watch-inventory.txt"),
    "installCopyNonWatchInventory" => File.join(BUILD_EVIDENCE_ROOT, "install-copy-non-watch-inventory.txt"),
    "nonWatchDiff" => File.join(BUILD_EVIDENCE_ROOT, "non-watch.diff"),
  }.freeze
  TOP_LEVEL_BUILD_EVIDENCE_FILES = %w[buildInvocation normalizedBuildSettings normalizedBuildLog].freeze
  TRANSFORMATION_EVIDENCE_FILES = %w[
    transformationRecord
    sourceNonWatchInventory
    installCopyNonWatchInventory
    nonWatchDiff
  ].freeze
  EXPECTED_BUILD_INVOCATION = [
    "<XCODE_APP>/Contents/Developer/usr/bin/xcodebuild",
    "build",
    "-project ios/QuakeSignal.xcodeproj",
    "-target QuakeSignal",
    "-configuration Debug",
    "-sdk iphonesimulator26.5",
    "SYMROOT=<ARTIFACT_ROOT>/build/Products",
    "OBJROOT=<ARTIFACT_ROOT>/build/Intermediates",
    "SHARED_PRECOMPS_DIR=<ARTIFACT_ROOT>/build/PrecompiledHeaders",
    "MODULE_CACHE_DIR=<ARTIFACT_ROOT>/build/ModuleCache",
    "ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon",
    "CODE_SIGNING_ALLOWED=NO",
  ].join(" ").freeze
  EXPECTED_BUILD_SETTINGS_INVOCATION = EXPECTED_BUILD_INVOCATION.sub(
    "/usr/bin/xcodebuild build ",
    "/usr/bin/xcodebuild -showBuildSettings ",
  ).freeze
  REQUIRED_BUILD_SETTINGS = {
    "CONFIGURATION" => "Debug",
    "PLATFORM_NAME" => "iphonesimulator",
    "EFFECTIVE_PLATFORM_NAME" => "-iphonesimulator",
    "SDK_VERSION" => "26.5",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.quakesignal.app",
    "MARKETING_VERSION" => "1.1",
    "CURRENT_PROJECT_VERSION" => "10",
    "CODE_SIGNING_ALLOWED" => "NO",
    "QUAKESIGNAL_API_BASE_URL" => "https://quakesignal-staging.invalid",
    "TARGETED_DEVICE_FAMILY" => "1,2",
    "PRODUCT_NAME" => "QuakeSignal",
  }.freeze
  EXPECTED_NON_WATCH_INVENTORY_PATHS = %w[
    ./ATTRIBUTION.md
    ./AppIcon60x60@2x.png
    ./AppIcon76x76@2x~ipad.png
    ./Assets.car
    ./Info.plist
    ./PkgInfo
    ./PrivacyInfo.xcprivacy
    ./QuakeSignal
    ./en.lproj/InfoPlist.strings
    ./en.lproj/Localizable.strings
    ./ja.lproj/InfoPlist.strings
    ./ja.lproj/Localizable.strings
    ./quakesignal_japanese_voice.caf
    ./quakesignal_urgent.caf
    ./zh-Hans.lproj/InfoPlist.strings
    ./zh-Hans.lproj/Localizable.strings
  ].freeze
  EMPTY_SHA256 = Digest::SHA256.hexdigest("").freeze
  CANDIDATE_STATUS = "unapproved-debug-simulator-candidate"
  FRAMES = %w[
    01-home.jpg
    02-reports.jpg
    03-map.jpg
    04-guide.jpg
    05-alert-preferences.jpg
  ].freeze
  DISPLAY_CLASSES = {
    "iphone-6.5" => [1242, 2688],
    "ipad-13" => [2064, 2752],
  }.freeze
  DEVICES = {
    "iphone-6.5" => {
      "model" => "iPhone 11 Pro Max",
      "modelIdentifier" => "iPhone12,5",
      "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max",
    },
    "ipad-13" => {
      "model" => "iPad Pro 13-inch (M4)",
      "modelIdentifier" => "iPad16,6",
      "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB",
    },
  }.freeze
  EXPECTED_RELATIVE_PATHS = DISPLAY_CLASSES.keys.flat_map do |display_class|
    FRAMES.map { |frame| File.join("en-US", display_class, frame) }
  end.freeze

  def initialize(
    root:,
    image_inspector: SipsScreenshotInspector.new,
    historical_commit_guard: nil
  )
    requested_root = Pathname.new(root).expand_path
    if requested_root.symlink?
      raise IOSBuild8ScreenshotCandidateValidationError,
            "screenshot validation root must not be a symlink: #{requested_root}"
    end
    @root = requested_root.realpath
    ios_root = @root.join("ios")
    ensure_plain_directory!(ios_root, "iOS source root")
    app_store = ios_root.join("AppStore")
    ensure_plain_directory!(app_store, "iOS App Store root")
    @ios_store = app_store.realpath
    @image_inspector = image_inspector
    # The preserved package proves its own historical source binding and byte
    # integrity. It must not claim that today's app source still equals that old
    # commit. The unchanged IOSBuild8ScreenshotSourceGuard remains intact for
    # its direct contract tests; active sets use the stricter cross-platform
    # NativeAppleScreenshotSourceGuard and do not weaken or bypass either gate.
    @historical_commit_guard =
      historical_commit_guard || IOSBuild8ScreenshotHistoricalCommitGuard.new(@root)
  end

  def validate_optional!
    manifest_path = @ios_store.join(MANIFEST_NAME)
    provenance_path = @ios_store.join(PROVENANCE_NAME)
    screenshot_root = @ios_store.join(SCREENSHOT_ROOT)
    build_evidence_root = @ios_store.join(BUILD_EVIDENCE_ROOT)
    components = {
      manifest_path => regular_file_within_store?(manifest_path),
      provenance_path => regular_file_within_store?(provenance_path),
      screenshot_root => screenshot_root.directory? && !screenshot_root.symlink?,
      build_evidence_root => build_evidence_root.directory? && !build_evidence_root.symlink?,
    }
    any_component_exists = components.keys.any? { |path| path.exist? || path.symlink? }
    return :absent unless any_component_exists

    unless components.values.all?
      missing = components.select { |_path, valid| !valid }.keys
      raise IOSBuild8ScreenshotCandidateValidationError,
            "partial build-8 screenshot candidate evidence is forbidden; missing or invalid #{missing.join(', ')}"
    end

    manifest = parse_json_object!(manifest_path)
    provenance = parse_json_object!(provenance_path)
    validate_manifest!(manifest)
    validate_provenance!(manifest, provenance)
    validate_inventory_and_files!(manifest, provenance)
    :validated
  end

  private

  def parse_json_object!(path)
    value = JSON.parse(
      path.read,
      object_class: DuplicateRejectingJSONObject,
      allow_duplicate_key: false,
    )
    return value if value.is_a?(Hash)

    raise IOSBuild8ScreenshotCandidateValidationError, "#{path} must contain a JSON object"
  rescue JSON::ParserError, SystemCallError => error
    raise IOSBuild8ScreenshotCandidateValidationError, "could not read #{path}: #{error.message}"
  end

  def validate_manifest!(manifest)
    require_exact_keys!(
      manifest,
      %w[
        schemaVersion
        status
        uploadApproved
        signedReleaseEvidence
        product
        rootDirectory
        captureEvidence
        locales
        displayClasses
        frames
      ],
      label: "manifest",
    )
    require_equal!(manifest.fetch("schemaVersion"), 1, "manifest schemaVersion")
    require_candidate_state!(manifest, "manifest")
    require_equal!(manifest.fetch("signedReleaseEvidence"), false, "manifest signedReleaseEvidence")
    reject_release_approval!(manifest, "manifest")

    product = manifest.fetch("product")
    require_exact_keys!(
      product,
      %w[appleId platform marketingVersion build bundleIdentifier configuration],
      label: "manifest product",
    )
    validate_product!(product, "manifest product", require_simulator_fields: false)
    require_equal!(manifest.fetch("rootDirectory"), SCREENSHOT_ROOT, "manifest rootDirectory")

    locales = manifest.fetch("locales").map.with_index do |locale, index|
      require_exact_keys!(locale, %w[directory], label: "manifest locale #{index}")
      locale.fetch("directory")
    end
    require_equal!(locales, ["en-US"], "manifest captured locales")

    display_classes = manifest.fetch("displayClasses")
    require_exact_keys!(display_classes, DISPLAY_CLASSES.keys, label: "manifest displayClasses")
    require_equal!(display_classes.keys.to_set, DISPLAY_CLASSES.keys.to_set, "manifest display classes")
    DISPLAY_CLASSES.each do |display_class, expected_pixels|
      specification = display_classes.fetch(display_class)
      require_exact_keys!(
        specification,
        %w[portraitPixels requiredFramesPerApprovedLocale],
        label: "manifest #{display_class} specification",
      )
      pixels = specification.fetch("portraitPixels")
      require_equal!(pixels, expected_pixels, "manifest #{display_class} pixels")
      require_equal!(
        specification.fetch("requiredFramesPerApprovedLocale"),
        FRAMES.length,
        "manifest #{display_class} frame count",
      )
    end

    frames = manifest.fetch("frames")
    frames.each_with_index do |frame, index|
      require_exact_keys!(frame, %w[file captureStatus], label: "manifest frame #{index}")
    end
    require_equal!(frames.map { |frame| frame.fetch("file") }, FRAMES, "manifest frame sequence")
    frames.each do |frame|
      require_equal!(frame.fetch("captureStatus"), CANDIDATE_STATUS, "manifest frame captureStatus")
    end

    capture = manifest.fetch("captureEvidence")
    require_exact_keys!(
      capture,
      %w[sourceBaselineCommit artifactSha256 capturedAtUtcRange reviewer],
      label: "manifest captureEvidence",
    )
    validate_source_commit!(capture.fetch("sourceBaselineCommit"), "manifest sourceBaselineCommit")
    validate_sha256!(capture.fetch("artifactSha256"), "manifest artifactSha256")
    require_nil!(capture.fetch("reviewer"), "manifest reviewer")
  rescue KeyError, TypeError, ArgumentError, NoMethodError => error
    raise IOSBuild8ScreenshotCandidateValidationError, "invalid build-8 screenshot manifest: #{error.message}"
  end

  def validate_provenance!(manifest, provenance)
    require_exact_keys!(
      provenance,
      %w[
        schemaVersion
        status
        uploadApproved
        signedReleaseEvidence
        product
        capture
        automationGates
        fixture
        buildEvidence
        files
      ],
      label: "provenance",
    )
    require_equal!(provenance.fetch("schemaVersion"), 1, "provenance schemaVersion")
    require_candidate_state!(provenance, "provenance")
    require_equal!(provenance.fetch("signedReleaseEvidence"), false, "provenance signedReleaseEvidence")
    reject_release_approval!(provenance, "provenance")

    product = provenance.fetch("product")
    require_exact_keys!(
      product,
      %w[appleId platform marketingVersion build bundleIdentifier configuration sdk signing],
      label: "provenance product",
    )
    validate_product!(product, "provenance product", require_simulator_fields: true)
    capture = provenance.fetch("capture")
    require_exact_keys!(
      capture,
      %w[
        sourceBaselineCommit
        sourceTreeState
        capturedAtUtcRange
        xcode
        runtime
        devices
        reviewer
      ],
      optional: %w[hostMacOS],
      label: "provenance capture",
    )
    source_commit = capture.fetch("sourceBaselineCommit")
    validate_source_commit!(source_commit, "provenance sourceBaselineCommit")
    require_equal!(
      source_commit,
      manifest.fetch("captureEvidence").fetch("sourceBaselineCommit"),
      "manifest/provenance sourceBaselineCommit",
    )
    require_equal!(capture.fetch("sourceTreeState"), "clean", "provenance sourceTreeState")
    require_nil!(capture.fetch("reviewer"), "provenance reviewer")
    validate_capture_times!(manifest.fetch("captureEvidence"), capture)
    validate_host_tools!(capture)
    validate_runtime!(capture.fetch("runtime"))
    validate_devices!(capture.fetch("devices"))
    validate_automation_gates!(provenance.fetch("automationGates"))
    validate_fixture!(provenance.fetch("fixture"))
    build_evidence = provenance.fetch("buildEvidence")
    require_exact_keys!(
      build_evidence,
      %w[
        mainExecutableSha256
        debugLocalOverridePresent
        buildInvocation
        normalizedBuildSettings
        normalizedBuildLog
        targetBuildLogSha256
        simulatorInstallTransformation
      ],
      label: "provenance buildEvidence",
    )
    executable_sha256 = build_evidence.fetch("mainExecutableSha256")
    validate_sha256!(executable_sha256, "provenance mainExecutableSha256")
    require_equal!(
      executable_sha256,
      manifest.fetch("captureEvidence").fetch("artifactSha256"),
      "manifest/provenance executable SHA-256",
    )
    validate_debug_local_override!(build_evidence)
    validate_build_evidence!(build_evidence)
    @historical_commit_guard.validate!(source_commit)
  rescue KeyError, TypeError, ArgumentError, NoMethodError => error
    raise IOSBuild8ScreenshotCandidateValidationError, "invalid build-8 screenshot provenance: #{error.message}"
  end

  def validate_product!(product, label, require_simulator_fields:)
    require_equal!(product.fetch("appleId"), "6800642443", "#{label} appleId")
    require_equal!(product.fetch("platform"), "iOS/iPadOS", "#{label} platform")
    require_equal!(product.fetch("marketingVersion"), "1.1", "#{label} marketingVersion")
    require_equal!(product.fetch("build"), 10, "#{label} build")
    require_equal!(product.fetch("bundleIdentifier"), "com.quakesignal.app", "#{label} bundleIdentifier")
    require_equal!(product.fetch("configuration"), "Debug", "#{label} configuration")
    return unless require_simulator_fields

    sdk = product.fetch("sdk")
    unless sdk.is_a?(String) && sdk.match?(/\Aiphonesimulator[0-9.]+\z/)
      raise IOSBuild8ScreenshotCandidateValidationError, "#{label} sdk must identify an iPhone Simulator SDK"
    end
    require_equal!(product.fetch("signing"), "disabled", "#{label} signing")
  end

  def validate_capture_times!(manifest_capture, provenance_capture)
    manifest_range = manifest_capture.fetch("capturedAtUtcRange")
    provenance_range = provenance_capture.fetch("capturedAtUtcRange")
    require_equal!(manifest_range, provenance_range, "manifest/provenance capturedAtUtcRange")
    unless provenance_range.is_a?(Array) && provenance_range.length == 2
      raise IOSBuild8ScreenshotCandidateValidationError,
            "provenance capturedAtUtcRange must contain the first and last capture times"
    end

    parsed = provenance_range.map.with_index do |value, index|
      unless value.is_a?(String) && value.end_with?("Z")
        raise IOSBuild8ScreenshotCandidateValidationError,
              "provenance capturedAtUtcRange[#{index}] must be an explicit UTC timestamp"
      end
      timestamp = Time.iso8601(value)
      unless timestamp.utc?
        raise IOSBuild8ScreenshotCandidateValidationError,
              "provenance capturedAtUtcRange[#{index}] must be UTC"
      end
      timestamp
    end
    return if parsed.first <= parsed.last

    raise IOSBuild8ScreenshotCandidateValidationError,
          "provenance capturedAtUtcRange must be chronological"
  rescue ArgumentError => error
    raise IOSBuild8ScreenshotCandidateValidationError,
          "invalid provenance capture timestamp: #{error.message}"
  end

  def validate_runtime!(runtime)
    require_exact_keys!(runtime, %w[name version build identifier], label: "provenance runtime")
    name = runtime.fetch("name")
    version = runtime.fetch("version")
    build = runtime.fetch("build")
    identifier = runtime.fetch("identifier")
    unless name.is_a?(String) && !name.strip.empty? &&
        version.is_a?(String) && version.match?(/\A[0-9]+(?:\.[0-9]+)+\z/) &&
        build.is_a?(String) && !build.strip.empty?
      raise IOSBuild8ScreenshotCandidateValidationError,
            "provenance runtime needs a name, dotted version, and build"
    end
    expected_identifier = "com.apple.CoreSimulator.SimRuntime.iOS-#{version.tr('.', '-')}"
    require_equal!(identifier, expected_identifier, "provenance runtime identifier")
  end

  def validate_host_tools!(capture)
    validate_version_and_build!(capture.fetch("xcode"), "provenance Xcode")
    return unless capture.key?("hostMacOS")

    validate_version_and_build!(capture.fetch("hostMacOS"), "provenance host macOS")
  end

  def validate_version_and_build!(value, label)
    return if value.is_a?(String) && value.match?(/\A[0-9]+(?:\.[0-9]+)+ \([0-9A-Za-z]+\)\z/)

    raise IOSBuild8ScreenshotCandidateValidationError,
          "#{label} must record a dotted version and parenthesized build"
  end

  def validate_devices!(devices)
    unless devices.is_a?(Array) && devices.length == DEVICES.length
      raise IOSBuild8ScreenshotCandidateValidationError,
            "provenance must record exactly the iPhone and iPad capture Simulators"
    end

    by_class = devices.each_with_object({}) do |device, values|
      require_exact_keys!(
        device,
        %w[
          displayClass
          name
          model
          modelIdentifier
          deviceTypeIdentifier
          udid
          width
          height
        ],
        label: "provenance capture device",
      )
      display_class = device.fetch("displayClass")
      if values.key?(display_class)
        raise IOSBuild8ScreenshotCandidateValidationError,
              "duplicate provenance capture device for #{display_class}"
      end
      values[display_class] = device
    end
    require_equal!(by_class.keys.to_set, DEVICES.keys.to_set, "provenance capture device classes")

    DEVICES.each do |display_class, expected_identity|
      device = by_class.fetch(display_class)
      expected_identity.each do |field, expected_value|
        require_equal!(device.fetch(field), expected_value, "provenance #{display_class} #{field}")
      end
      width, height = DISPLAY_CLASSES.fetch(display_class)
      require_equal!(device.fetch("width"), width, "provenance #{display_class} width")
      require_equal!(device.fetch("height"), height, "provenance #{display_class} height")
      name = device.fetch("name")
      udid = device.fetch("udid")
      unless name.is_a?(String) && !name.strip.empty?
        raise IOSBuild8ScreenshotCandidateValidationError,
              "provenance #{display_class} device name must be nonempty"
      end
      unless udid.is_a?(String) && udid.match?(/\A[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\z/)
        raise IOSBuild8ScreenshotCandidateValidationError,
              "provenance #{display_class} device UDID must be a full Simulator UUID"
      end
    end
  end

  def validate_automation_gates!(gates)
    require_exact_keys!(
      gates,
      %w[requiredLaunchArgument requiredEnvironment bothSupplied sourceConstraint],
      label: "provenance automationGates",
    )
    require_equal!(
      gates.fetch("requiredLaunchArgument"),
      "--quakesignal-screenshot-automation",
      "provenance screenshot launch gate",
    )
    environment = gates.fetch("requiredEnvironment")
    require_exact_keys!(
      environment,
      %w[QUAKESIGNAL_SCREENSHOT_AUTOMATION],
      label: "provenance screenshot environment",
    )
    require_equal!(
      environment,
      { "QUAKESIGNAL_SCREENSHOT_AUTOMATION" => "1" },
      "provenance screenshot environment gate",
    )
    require_equal!(gates.fetch("bothSupplied"), true, "provenance screenshot dual-gate evidence")
    require_equal!(
      gates.fetch("sourceConstraint"),
      "DEBUG && targetEnvironment(simulator)",
      "provenance screenshot source constraint",
    )
  end

  def validate_fixture!(fixture)
    require_exact_keys!(fixture, %w[identifier warning training], label: "provenance fixture")
    require_equal!(fixture.fetch("identifier"), "finalized-historical-reports", "provenance fixture identifier")
    require_equal!(fixture.fetch("warning"), false, "provenance fixture warning flag")
    require_equal!(fixture.fetch("training"), false, "provenance fixture training flag")
  end

  def validate_debug_local_override!(build_evidence)
    require_equal!(
      build_evidence.fetch("debugLocalOverridePresent"),
      false,
      "provenance debugLocalOverridePresent",
    )
    override = @root.join("ios", "QuakeSignal", "Supporting", "Debug.local.xcconfig")
    return unless override.exist? || override.symlink?

    raise IOSBuild8ScreenshotCandidateValidationError,
          "Debug.local.xcconfig must be absent for reproducible screenshot candidates"
  end

  def validate_build_evidence!(build_evidence)
    evidence_root = @ios_store.join(BUILD_EVIDENCE_ROOT)
    validate_file_names!(evidence_root, BUILD_EVIDENCE_FILES.values.map { |path| File.basename(path) })

    top_level_contents = TOP_LEVEL_BUILD_EVIDENCE_FILES.to_h do |field|
      [field, validate_build_evidence_file_record!(build_evidence.fetch(field), field)]
    end
    target_build_log_sha256 = build_evidence.fetch("targetBuildLogSha256")
    validate_sha256!(target_build_log_sha256, "provenance targetBuildLogSha256")
    normalized_log_source_sha256 = build_evidence.fetch("normalizedBuildLog").fetch("sourceLogSha256")
    validate_sha256!(normalized_log_source_sha256, "provenance normalizedBuildLog sourceLogSha256")
    require_equal!(
      normalized_log_source_sha256,
      target_build_log_sha256,
      "normalized/raw target build log SHA-256 binding",
    )
    require_equal!(
      top_level_contents.fetch("buildInvocation"),
      "#{EXPECTED_BUILD_INVOCATION}\n",
      "normalized Debug Simulator build invocation",
    )
    settings = parse_normalized_build_settings!(top_level_contents.fetch("normalizedBuildSettings"))
    REQUIRED_BUILD_SETTINGS.each do |key, expected_value|
      require_equal!(settings.fetch(key), expected_value, "normalized build setting #{key}")
    end
    validate_normalized_build_log!(top_level_contents.fetch("normalizedBuildLog"))

    transformation = build_evidence.fetch("simulatorInstallTransformation")
    require_exact_keys!(
      transformation,
      %w[
        embeddedWatchRemovalOnly
        nonWatchDiffEmpty
        mainExecutableUnchanged
        sourceExecutableSha256
        installedExecutableSha256
        transformationRecord
        sourceNonWatchInventory
        installCopyNonWatchInventory
        nonWatchDiff
      ],
      label: "provenance simulatorInstallTransformation",
    )
    require_equal!(
      transformation.fetch("embeddedWatchRemovalOnly"),
      true,
      "provenance embedded Watch removal-only claim",
    )
    require_equal!(
      transformation.fetch("nonWatchDiffEmpty"),
      true,
      "provenance non-Watch install transformation diff",
    )
    require_equal!(
      transformation.fetch("mainExecutableUnchanged"),
      true,
      "provenance transformed main executable claim",
    )
    main_executable_sha256 = build_evidence.fetch("mainExecutableSha256")
    %w[sourceExecutableSha256 installedExecutableSha256].each do |field|
      digest = transformation.fetch(field)
      validate_sha256!(digest, "provenance #{field}")
      require_equal!(digest, main_executable_sha256, "provenance #{field}/main executable SHA-256")
    end

    transformation_contents = TRANSFORMATION_EVIDENCE_FILES.to_h do |field|
      [field, validate_build_evidence_file_record!(transformation.fetch(field), field)]
    end
    source_inventory = transformation_contents.fetch("sourceNonWatchInventory")
    installed_inventory = transformation_contents.fetch("installCopyNonWatchInventory")
    require_equal!(
      installed_inventory,
      source_inventory,
      "source/install-copy non-Watch inventory contents",
    )
    source_entries = parse_non_watch_inventory!(source_inventory, "source non-Watch inventory")
    installed_entries = parse_non_watch_inventory!(installed_inventory, "install-copy non-Watch inventory")
    require_equal!(
      source_entries.fetch("./QuakeSignal"),
      main_executable_sha256,
      "source inventory main executable SHA-256",
    )
    require_equal!(
      installed_entries.fetch("./QuakeSignal"),
      main_executable_sha256,
      "install-copy inventory main executable SHA-256",
    )
    non_watch_diff = transformation_contents.fetch("nonWatchDiff")
    require_equal!(non_watch_diff, "", "non-Watch transformation diff contents")
    require_equal!(
      transformation.fetch("nonWatchDiff").fetch("sha256"),
      EMPTY_SHA256,
      "non-Watch transformation diff SHA-256",
    )

    validate_transformation_record!(
      transformation_contents.fetch("transformationRecord"),
      main_executable_sha256,
    )
  rescue KeyError => error
    raise IOSBuild8ScreenshotCandidateValidationError,
          "incomplete semantic build evidence: #{error.message}"
  end

  def validate_build_evidence_file_record!(record, field)
    required_keys = field == "normalizedBuildLog" ? %w[file sha256 sourceLogSha256] : %w[file sha256]
    require_exact_keys!(record, required_keys, label: "provenance #{field}")
    expected_relative_path = BUILD_EVIDENCE_FILES.fetch(field)
    require_equal!(record.fetch("file"), expected_relative_path, "provenance #{field} file")
    recorded_digest = record.fetch("sha256")
    validate_sha256!(recorded_digest, "provenance #{field} SHA-256")

    evidence_file = @ios_store.join(expected_relative_path)
    unless regular_file_within_store?(evidence_file)
      raise IOSBuild8ScreenshotCandidateValidationError,
            "missing regular build evidence file: #{evidence_file}"
    end
    content = evidence_file.binread
    require_equal!(
      Digest::SHA256.hexdigest(content),
      recorded_digest,
      "provenance #{field} actual SHA-256",
    )
    content
  end

  def parse_normalized_build_settings!(content)
    lines = content.each_line(chomp: true).to_a
    section_headers = lines.each_index.select do |index|
      lines[index].start_with?("Build settings for action ")
    end
    unless section_headers.empty?
      expected_headers = section_headers.select do |index|
        lines[index] == "Build settings for action build and target QuakeSignal:"
      end
      unless section_headers.length == 1 && expected_headers.length == 1
        raise IOSBuild8ScreenshotCandidateValidationError,
              "normalized build settings must contain only the QuakeSignal build target section"
      end
      settings_invocations = lines.select { |line| line.include?("/usr/bin/xcodebuild ") }
      require_equal!(settings_invocations.length, 1, "normalized build settings invocation count")
      require_equal!(
        settings_invocations.first.strip,
        EXPECTED_BUILD_SETTINGS_INVOCATION,
        "normalized build settings Debug Simulator invocation",
      )
      lines = lines[(expected_headers.first + 1)..] || []
    end

    settings = {}
    lines.each.with_index(1) do |line, line_number|
      next if line.empty?

      match = line.match(/\A\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*\z/)
      unless match
        raise IOSBuild8ScreenshotCandidateValidationError,
              "normalized build settings line #{line_number} is not KEY = VALUE"
      end

      key = match[1]
      value = match[2]
      if settings.key?(key) && settings.fetch(key) != value
        raise IOSBuild8ScreenshotCandidateValidationError,
              "normalized build setting #{key} has conflicting duplicate values"
      end
      settings[key] = value
    end
    if settings.empty?
      raise IOSBuild8ScreenshotCandidateValidationError, "normalized build settings must not be empty"
    end
    settings
  end

  def validate_normalized_build_log!(content)
    lines = content.each_line(chomp: true).to_a
    require_equal!(lines.fetch(0), "Command line invocation:", "normalized build log first line")
    xcodebuild_indices = lines.each_index.select { |index| lines[index].include?("/usr/bin/xcodebuild ") }
    require_equal!(xcodebuild_indices, [1], "normalized build log invocation position")
    require_equal!(
      lines.fetch(1).strip,
      EXPECTED_BUILD_INVOCATION,
      "normalized build log Debug Simulator invocation",
    )
    forbidden_patterns = {
      "Release configuration" => /(?:\bRelease\b|\/Release-)/,
      "device SDK" => /(?:\biphoneos\b|iPhoneOS)/,
      "signing enabled" => /CODE_SIGNING_ALLOWED(?:\s*=\s*|=)YES/,
      "device target triple" => /-apple-ios[0-9.]+(?:\s|\z)/,
    }
    forbidden_patterns.each do |label, pattern|
      if lines.any? { |line| line.match?(pattern) }
        raise IOSBuild8ScreenshotCandidateValidationError,
              "normalized build log contains forbidden #{label} evidence"
      end
    end

    signing_settings = lines.each_with_object([]) do |line, values|
      match = line.match(/\A\s*CODE_SIGNING_ALLOWED\s*=\s*(\S+)\s*\z/)
      values << match[1] if match
    end
    if signing_settings.empty?
      raise IOSBuild8ScreenshotCandidateValidationError,
            "normalized build log must record CODE_SIGNING_ALLOWED = NO"
    end
    require_equal!(signing_settings.uniq, ["NO"], "normalized build log signing settings")

    target_indices = {}
    link_indices = {}
    %w[arm64 x86_64].each do |architecture|
      target_pattern = /\ASwiftDriver QuakeSignal normal #{Regexp.escape(architecture)} .* \(in target 'QuakeSignal' from project 'QuakeSignal'\)\z/
      matches = lines.each_index.select { |index| lines[index].match?(target_pattern) }
      require_equal!(matches.length, 1, "normalized build log QuakeSignal #{architecture} target count")
      target_indices[architecture] = matches.first
      link_pattern = %r{\ALd .*/Debug-iphonesimulator/QuakeSignal\.build/Objects-normal/#{Regexp.escape(architecture)}/Binary/QuakeSignal normal #{Regexp.escape(architecture)} \(in target 'QuakeSignal' from project 'QuakeSignal'\)\z}
      matches = lines.each_index.select { |index| lines[index].match?(link_pattern) }
      require_equal!(matches.length, 1, "normalized build log QuakeSignal #{architecture} link count")
      link_indices[architecture] = matches.first
    end

    main_target_lines = lines.count do |line|
      line.start_with?("SwiftDriver QuakeSignal normal ") &&
        line.end_with?("(in target 'QuakeSignal' from project 'QuakeSignal')")
    end
    main_link_lines = lines.count do |line|
      line.start_with?("Ld ") && line.include?("/Binary/QuakeSignal normal ") &&
        line.end_with?("(in target 'QuakeSignal' from project 'QuakeSignal')")
    end
    require_equal!(main_target_lines, 2, "normalized build log main target architecture inventory")
    require_equal!(main_link_lines, 2, "normalized build log main link architecture inventory")

    success_indices = lines.each_index.select { |index| lines[index].strip == "** BUILD SUCCEEDED **" }
    failure_indices = lines.each_index.select { |index| lines[index].strip == "** BUILD FAILED **" }
    require_equal!(success_indices.length, 1, "normalized build log success count")
    require_equal!(failure_indices.length, 0, "normalized build log failure count")
    last_nonempty_index = lines.rindex { |line| !line.empty? }
    require_equal!(success_indices.first, last_nonempty_index, "normalized build log terminal success")
    first_signing_index = lines.index { |line| line.match?(/\A\s*CODE_SIGNING_ALLOWED\s*=/) }
    unless first_signing_index && 1 < first_signing_index &&
        target_indices.values.all? { |index| first_signing_index < index } &&
        %w[arm64 x86_64].all? { |architecture| target_indices.fetch(architecture) < link_indices.fetch(architecture) } &&
        link_indices.values.all? { |index| index < success_indices.first }
      raise IOSBuild8ScreenshotCandidateValidationError,
            "normalized build log invocation, target, link, and success evidence is out of order"
    end
  end

  def parse_non_watch_inventory!(content, label)
    entries = {}
    content.each_line(chomp: true).with_index(1) do |line, line_number|
      match = line.match(/\A([0-9a-f]{64})  (\.\/[^\r\n]+)\z/)
      unless match
        raise IOSBuild8ScreenshotCandidateValidationError,
              "#{label} line #{line_number} must be a lowercase SHA-256 and ./relative/path"
      end
      digest = match[1]
      relative_path = match[2]
      path_segments = relative_path.delete_prefix("./").split("/")
      if path_segments.empty? ||
          path_segments.any? { |segment| segment.empty? || segment == "." || segment == ".." || segment == "Watch" }
        raise IOSBuild8ScreenshotCandidateValidationError,
              "#{label} contains an invalid or Watch path: #{relative_path}"
      end
      if entries.key?(relative_path)
        raise IOSBuild8ScreenshotCandidateValidationError,
              "#{label} contains duplicate path: #{relative_path}"
      end
      entries[relative_path] = digest
    end
    if entries.empty?
      raise IOSBuild8ScreenshotCandidateValidationError, "#{label} must not be empty"
    end
    require_equal!(
      entries.keys.to_set,
      EXPECTED_NON_WATCH_INVENTORY_PATHS.to_set,
      "#{label} path inventory",
    )
    entries
  end

  def validate_transformation_record!(content, main_executable_sha256)
    record = parse_exact_key_value_record!(content, "simulator install transformation record")
    require_exact_keys!(
      record,
      %w[
        purpose
        sourceProduct
        installCopy
        operation
        omittedRelativePath
        reason
        builtProductModified
        nonWatchByteDiff
        nonWatchDiffEvidence
        mainExecutableIdentical
        mainExecutableSha256
        distributionSigningUsed
        credentialsUsed
      ],
      label: "simulator install transformation record",
    )
    expected_values = {
      "purpose" => "Simulator installation compatibility only",
      "sourceProduct" => "<ARTIFACT_ROOT>/build/Products/Debug-iphonesimulator/QuakeSignal.app",
      "installCopy" => "<ARTIFACT_ROOT>/capture-app-no-watch/QuakeSignal.app",
      "operation" => "rsync -a --exclude=Watch/ <sourceProduct>/ <installCopy>/",
      "omittedRelativePath" => "Watch/",
      "builtProductModified" => "false",
      "nonWatchByteDiff" => "false",
      "nonWatchDiffEvidence" => BUILD_EVIDENCE_FILES.fetch("nonWatchDiff"),
      "mainExecutableIdentical" => "true",
      "mainExecutableSha256" => main_executable_sha256,
      "distributionSigningUsed" => "false",
      "credentialsUsed" => "false",
    }
    expected_values.each do |key, expected_value|
      require_equal!(record.fetch(key), expected_value, "transformation record #{key}")
    end
    reason = record.fetch("reason")
    unless reason.is_a?(String) && reason.include?("Watch") && reason.include?("CoreSimulator")
      raise IOSBuild8ScreenshotCandidateValidationError,
            "transformation record reason must explain the embedded Watch CoreSimulator incompatibility"
    end
  end

  def parse_exact_key_value_record!(content, label)
    record = {}
    content.each_line(chomp: true).with_index(1) do |line, line_number|
      match = line.match(/\A([A-Za-z][A-Za-z0-9]*)=(.*)\z/)
      unless match
        raise IOSBuild8ScreenshotCandidateValidationError,
              "#{label} line #{line_number} must be key=value"
      end
      key = match[1]
      if record.key?(key)
        raise IOSBuild8ScreenshotCandidateValidationError, "#{label} contains duplicate key #{key}"
      end
      record[key] = match[2]
    end
    record
  end

  def validate_inventory_and_files!(manifest, provenance)
    screenshot_root = @ios_store.join(manifest.fetch("rootDirectory"))
    unless screenshot_root.directory?
      raise IOSBuild8ScreenshotCandidateValidationError, "missing build-8 screenshot directory: #{screenshot_root}"
    end

    validate_directory_names!(screenshot_root, ["en-US"])
    locale_root = screenshot_root.join("en-US")
    validate_directory_names!(locale_root, DISPLAY_CLASSES.keys)
    DISPLAY_CLASSES.each_key do |display_class|
      validate_file_names!(locale_root.join(display_class), FRAMES)
    end

    files = provenance.fetch("files")
    files.each_with_index do |entry, index|
      require_exact_keys!(
        entry,
        %w[file captureStatus sha256 pixels format hasAlpha],
        label: "provenance file #{index}",
      )
    end
    relative_paths = files.map { |entry| entry.fetch("file") }
    duplicates = relative_paths.group_by(&:itself).select { |_path, entries| entries.length > 1 }.keys
    unless duplicates.empty?
      raise IOSBuild8ScreenshotCandidateValidationError,
            "duplicate build-8 screenshot provenance entries: #{duplicates.sort.join(', ')}"
    end
    require_equal!(relative_paths.to_set, EXPECTED_RELATIVE_PATHS.to_set, "provenance screenshot inventory")

    files.each do |entry|
      validate_file_entry!(screenshot_root, entry)
    end
  rescue KeyError, TypeError, ArgumentError, NoMethodError => error
    raise IOSBuild8ScreenshotCandidateValidationError, "invalid build-8 screenshot file evidence: #{error.message}"
  end

  def validate_directory_names!(directory, expected_names)
    unless directory.directory? && !directory.symlink?
      raise IOSBuild8ScreenshotCandidateValidationError, "missing build-8 screenshot directory: #{directory}"
    end
    ensure_path_within_store!(directory)

    actual_names = directory.children.map { |child| child.basename.to_s }
    require_equal!(actual_names.to_set, expected_names.to_set, "directory inventory for #{directory}")
    directory.children.each do |child|
      next if child.directory? && !child.symlink?

      raise IOSBuild8ScreenshotCandidateValidationError, "unexpected non-directory in #{directory}: #{child}"
    end
  end

  def validate_file_names!(directory, expected_names)
    unless directory.directory? && !directory.symlink?
      raise IOSBuild8ScreenshotCandidateValidationError, "missing build-8 screenshot class directory: #{directory}"
    end
    ensure_path_within_store!(directory)

    actual_names = directory.children.map { |child| child.basename.to_s }
    require_equal!(actual_names.to_set, expected_names.to_set, "screenshot inventory for #{directory}")
    directory.children.each do |child|
      next if child.file? && !child.symlink?

      raise IOSBuild8ScreenshotCandidateValidationError, "unexpected non-file screenshot entry: #{child}"
    end
  end

  def validate_file_entry!(screenshot_root, entry)
    relative_path = entry.fetch("file")
    display_class = relative_path.split(File::SEPARATOR).fetch(1)
    expected_pixels = DISPLAY_CLASSES.fetch(display_class)
    screenshot = screenshot_root.join(relative_path)
    unless screenshot.file? && !screenshot.symlink?
      raise IOSBuild8ScreenshotCandidateValidationError, "missing regular screenshot file: #{screenshot}"
    end
    ensure_path_within_store!(screenshot)

    require_equal!(entry.fetch("captureStatus"), CANDIDATE_STATUS, "#{relative_path} captureStatus")
    require_equal!(entry.fetch("hasAlpha"), false, "#{relative_path} recorded alpha")
    require_equal!(entry.fetch("format"), "jpeg", "#{relative_path} recorded format")
    recorded_pixels = entry.fetch("pixels")
    require_equal!(recorded_pixels, expected_pixels, "#{relative_path} recorded pixels")

    recorded_digest = entry.fetch("sha256")
    unless recorded_digest.is_a?(String) && recorded_digest.match?(/\A[0-9a-f]{64}\z/)
      raise IOSBuild8ScreenshotCandidateValidationError, "#{relative_path} needs a lowercase SHA-256"
    end
    require_equal!(Digest::SHA256.file(screenshot).hexdigest, recorded_digest, "#{relative_path} SHA-256")

    properties = @image_inspector.inspect(screenshot)
    actual_pixels = [properties.fetch(:width), properties.fetch(:height)]
    require_equal!(actual_pixels, expected_pixels, "#{relative_path} actual pixels")
    require_equal!(properties.fetch(:format), "jpeg", "#{relative_path} actual format")
    require_equal!(properties.fetch(:has_alpha), false, "#{relative_path} actual alpha")
  end

  def require_candidate_state!(record, label)
    require_equal!(record.fetch("status"), CANDIDATE_STATUS, "#{label} status")
    require_equal!(record.fetch("uploadApproved"), false, "#{label} uploadApproved")
  end

  def reject_release_approval!(record, label)
    %w[releaseApproval approvedAtUtc signedArtifactSha256 releaseBinaryEvidence].each do |field|
      next unless record.key?(field)

      require_nil!(record.fetch(field), "#{label} #{field}")
    end
    require_nil!(record.fetch("reviewer"), "#{label} reviewer") if record.key?("reviewer")
  end

  def validate_source_commit!(value, label)
    return if value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)

    raise IOSBuild8ScreenshotCandidateValidationError, "#{label} must be a full lowercase Git commit"
  end

  def validate_sha256!(value, label)
    return if value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)

    raise IOSBuild8ScreenshotCandidateValidationError, "#{label} must be a lowercase SHA-256"
  end

  def require_exact_keys!(object, required, optional: [], label:)
    unless object.is_a?(Hash)
      raise IOSBuild8ScreenshotCandidateValidationError, "#{label} must be a JSON object"
    end

    required_keys = required.to_set
    allowed_keys = required_keys | optional.to_set
    actual_keys = object.keys.to_set
    missing = required_keys - actual_keys
    unknown = actual_keys - allowed_keys
    return if missing.empty? && unknown.empty?

    details = []
    details << "missing #{missing.to_a.sort.join(', ')}" unless missing.empty?
    details << "unknown #{unknown.to_a.sort.join(', ')}" unless unknown.empty?
    raise IOSBuild8ScreenshotCandidateValidationError,
          "#{label} keys are not exact: #{details.join('; ')}"
  end

  def ensure_plain_directory!(path, label)
    return if path.directory? && !path.symlink?

    raise IOSBuild8ScreenshotCandidateValidationError,
          "#{label} must be a real directory, not a symlink: #{path}"
  end

  def regular_file_within_store?(path)
    return false unless path.file? && !path.symlink?

    ensure_path_within_store!(path)
    true
  rescue IOSBuild8ScreenshotCandidateValidationError, SystemCallError
    false
  end

  def ensure_path_within_store!(path)
    real_path = path.realpath.to_s
    store_path = @ios_store.to_s
    return if real_path == store_path || real_path.start_with?("#{store_path}#{File::SEPARATOR}")

    raise IOSBuild8ScreenshotCandidateValidationError,
          "screenshot evidence resolves outside the iOS App Store root: #{path}"
  end

  def require_equal!(actual, expected, label)
    return if exact_json_value?(actual, expected)

    raise IOSBuild8ScreenshotCandidateValidationError,
          "#{label} mismatch: expected #{expected.inspect}, found #{actual.inspect}"
  end

  def exact_json_value?(actual, expected)
    case expected
    when Array
      actual.is_a?(Array) && actual.length == expected.length &&
        actual.zip(expected).all? { |left, right| exact_json_value?(left, right) }
    when Hash
      actual.is_a?(Hash) && actual.keys.to_set == expected.keys.to_set &&
        expected.all? { |key, value| exact_json_value?(actual.fetch(key), value) }
    else
      actual.class == expected.class && actual == expected
    end
  end

  def require_nil!(value, label)
    return if value.nil?

    raise IOSBuild8ScreenshotCandidateValidationError, "#{label} must remain null for an unapproved candidate"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    root = Pathname.new(__dir__).join("..", "..").realpath
    workflow_path = root.join(".github", "workflows", "listing-assets.yml")
    ListingAssetsWorkflowContract.validate!(workflow_path.read)
    result = IOSBuild8ScreenshotCandidateValidator.new(root: root).validate_optional!
    if result == :absent
      puts "Historical build-8 iOS screenshot evidence is absent; integrity validation skipped."
    else
      puts "Historical unapproved build-8 iOS screenshot bytes validated: 10 English Debug Simulator JPEGs."
    end
  rescue IOSBuild8ScreenshotCandidateValidationError, SystemCallError => error
    warn "Historical build-8 iOS screenshot integrity validation failed: #{error.message}"
    exit 1
  end
end
