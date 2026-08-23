#!/usr/bin/env ruby
# frozen_string_literal: true

# Validates the immutable historical screenshot catalog and, when present, one
# complete source-addressed QuakeSignal 1.1 (8) release set. Historical evidence
# is never made current by this validator. An active set must independently pass
# the full native-product source guard and a release-ready invocation additionally
# requires named review plus signed-Release parity for all five Apple platforms.

require "digest"
require "json"
require "open3"
require "pathname"
require "set"
require "time"
require_relative "verify-native-apple-screenshot-candidates"

class AppleScreenshotReleaseSetValidationError < StandardError; end

class AppleScreenshotDuplicateRejectingHash < Hash
  def []=(key, value)
    if key?(key)
      raise AppleScreenshotReleaseSetValidationError,
            "duplicate JSON object key is forbidden: #{key.inspect}"
    end

    super
  end
end

class AppleScreenshotImageInspector
  def inspect(path)
    output, status = Open3.capture2e(
      "sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", "-g", "hasAlpha",
      path.to_s,
    )
    unless status.success?
      raise AppleScreenshotReleaseSetValidationError,
            "could not inspect release screenshot #{path}: #{output.strip}"
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
    raise AppleScreenshotReleaseSetValidationError,
          "could not read release screenshot properties for #{path}: #{error.message}"
  end
end

class AppleScreenshotHistoricalCommitGuard
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
    raise AppleScreenshotReleaseSetValidationError, "#{failure}#{suffix}"
  end
end

class AppleScreenshotReleaseSourceGuard
  PRODUCT_SOURCE_PATHS = NativeAppleScreenshotSourceGuard::PRODUCT_SOURCE_PATHS

  def initialize(root)
    @root = Pathname.new(root).realpath
  end

  def validate!(source_commit, capture_inputs:)
    NativeAppleScreenshotSourceGuard.new(@root).validate!(source_commit)
    capture_inputs.each do |record|
      validate_capture_input!(source_commit, record.fetch("file"), record.fetch("sha256"))
    end
    true
  rescue NativeAppleScreenshotCandidateValidationError => error
    raise AppleScreenshotReleaseSetValidationError, error.message
  end

  def validate_product_equivalent!(source_commit, signed_build_commit)
    validate_commit!(signed_build_commit, "signed-build source commit")
    _output, error_output, status = Open3.capture3(
      "git", "-C", @root.to_s, "diff", "--no-ext-diff", "--quiet",
      source_commit, signed_build_commit, "--", *PRODUCT_SOURCE_PATHS,
    )
    case status.exitstatus
    when 0
      true
    when 1
      raise AppleScreenshotReleaseSetValidationError,
            "signed Release product source differs from the screenshot source commit"
    else
      detail = error_output.strip
      suffix = detail.empty? ? "" : ": #{detail}"
      raise AppleScreenshotReleaseSetValidationError,
            "could not compare signed Release source to screenshot source#{suffix}"
    end
  end

  private

  def validate_capture_input!(source_commit, relative_path, expected_sha256)
    current = @root.join(relative_path)
    unless current.file? && !current.symlink?
      raise AppleScreenshotReleaseSetValidationError,
            "capture plan must remain a plain tracked file: #{relative_path}"
    end
    unless Digest::SHA256.file(current).hexdigest == expected_sha256
      raise AppleScreenshotReleaseSetValidationError,
            "current capture plan differs from the active package plan hash: #{relative_path}"
    end

    source, error_output, status = Open3.capture3(
      "git", "-C", @root.to_s, "show", "#{source_commit}:#{relative_path}",
    )
    unless status.success?
      detail = error_output.strip
      suffix = detail.empty? ? "" : ": #{detail}"
      raise AppleScreenshotReleaseSetValidationError,
            "capture plan is unavailable at the screenshot source commit: #{relative_path}#{suffix}"
    end
    unless Digest::SHA256.hexdigest(source) == expected_sha256
      raise AppleScreenshotReleaseSetValidationError,
            "capture plan hash does not match the screenshot source commit: #{relative_path}"
    end
  end

  def validate_commit!(commit, label)
    unless commit.is_a?(String) && commit.match?(/\A[0-9a-f]{40}\z/)
      raise AppleScreenshotReleaseSetValidationError, "#{label} must be a full lowercase Git commit"
    end
    _output, error_output, status = Open3.capture3(
      "git", "-C", @root.to_s, "cat-file", "-e", "#{commit}^{commit}",
    )
    unless status.success?
      detail = error_output.strip
      suffix = detail.empty? ? "" : ": #{detail}"
      raise AppleScreenshotReleaseSetValidationError, "#{label} is unavailable#{suffix}"
    end
    _output, error_output, status = Open3.capture3(
      "git", "-C", @root.to_s, "merge-base", "--is-ancestor", commit, "HEAD",
    )
    return if status.success?

    detail = error_output.strip
    suffix = detail.empty? ? "" : ": #{detail}"
    raise AppleScreenshotReleaseSetValidationError, "#{label} is not an ancestor of HEAD#{suffix}"
  end
end

# The outer release package deliberately retains both the sealed raw capture
# tree and its conventional `ditto --keepParent` ZIP.  Load the assembler only
# when an active package exists, then reuse its exact validators so verification
# cannot silently devolve into checking only self-authored outer hashes.
class AppleScreenshotEmbeddedCapturePackageValidator
  attr_reader :validated_platforms

  def initialize(
    root:,
    release_evidence_root: nil,
    image_inspector: AppleScreenshotImageInspector.new,
    provenance_repository_root: nil,
    ios_provenance_image_inspector: nil,
    ios_provenance_result_inspector: nil
  )
    @root = Pathname.new(root).realpath
    @release_evidence_root = release_evidence_root
    @image_inspector = image_inspector
    @provenance_repository_root =
      Pathname.new(provenance_repository_root || @root).realpath
    @ios_provenance_image_inspector = ios_provenance_image_inspector
    @ios_provenance_result_inspector = ios_provenance_result_inspector
    @validated_platforms = []
  end

  def validate!(platform:, source_commit:, capture_root:, artifact:)
    require_relative "assemble-apple-screenshot-release-set" unless defined?(AppleScreenshotReleaseSetAssembler)
    assembler = AppleScreenshotReleaseSetAssembler.new(
      root: @root,
      release_evidence_root: @release_evidence_root,
      image_inspector: @image_inspector,
      source_guard: Object.new,
      index_validator: -> {},
      historical_frame_sha256s: Set.new,
      ios_provenance_repository_root: @provenance_repository_root,
      ios_provenance_image_inspector: @ios_provenance_image_inspector,
      ios_provenance_result_inspector: @ios_provenance_result_inspector,
    )
    evidence = assembler.validate_embedded_capture_package!(
      platform: platform,
      source_commit: source_commit,
      capture_root: capture_root,
      artifact: artifact,
    )
    @validated_platforms << platform
    evidence
  rescue AppleScreenshotReleaseSetAssemblyError => error
    raise AppleScreenshotReleaseSetValidationError,
          "#{platform} embedded capture package failed deep validation: #{error.message}"
  end
end

class AppleScreenshotReleaseSetValidator
  INDEX_PATH = "ios/AppStore/screenshot-set-index-v1.1-build10.json"
  RELEASE_ROOT = "ios/AppStore/screenshot-release-sets-v1.1-build10"
  CAPTURE_WORKFLOW_FILE = ".github/workflows/apple-platform-screenshots.yml"
  CANONICAL_REPOSITORY = "TastyHeadphones/QuakeSignal"
  HISTORICAL_ALGORITHM =
    "sha256 of sorted UTF-8 records: <file-sha256><two spaces><repository-relative-path><newline>"
  PACKAGE_ALGORITHM =
    "sha256 of sorted UTF-8 records: <file-sha256><two spaces><package-relative-path><newline>"
  PRODUCT = {
    "appleId" => "6800642443",
    "marketingVersion" => "1.1",
    "build" => 10,
  }.freeze
  REQUIRED_PLATFORMS = {
    "ios-ipados" => 10,
    "tvos" => 3,
    "watchos" => 3,
    "visionos" => 5,
    "maccatalyst" => 5,
  }.freeze
  SIGNED_RELEASE_WORKFLOW_FILES = {
    "ios-ipados" => ".github/workflows/ios.yml",
    "tvos" => ".github/workflows/apple-platforms.yml",
    "watchos" => ".github/workflows/ios.yml",
    "visionos" => ".github/workflows/apple-platforms.yml",
    "maccatalyst" => ".github/workflows/apple-platforms.yml",
  }.freeze
  SIGNED_RELEASE_ARTIFACT_KINDS = {
    "ios-ipados" => "ipa",
    "tvos" => "ipa",
    "watchos" => "ipa",
    "visionos" => "ipa",
    "maccatalyst" => "pkg",
  }.freeze
  PLAN_PATHS = {
    "ios-ipados" => "ios/AppStore/screenshot-manifest-v1.1-build10.template.json",
    "tvos" => "ios/AppStore/platforms/tvos/screenshot-manifest-v1.1-build10.json",
    "watchos" => "ios/AppStore/platforms/watchos/screenshot-manifest-v1.1-build10.json",
    "visionos" => "ios/AppStore/platforms/visionos/screenshot-manifest-v1.1-build10.json",
    "maccatalyst" => "ios/AppStore/platforms/maccatalyst/screenshot-manifest-v1.1-build10.json",
  }.freeze
  HISTORICAL_EVIDENCE = [
    {
      "id" => "ios-ipados-legacy-unversioned",
      "sourceCommit" => nil,
      "status" => "historical-pre-source-binding",
      "eligibleForBuild8Upload" => false,
      "paths" => %w[
        ios/AppStore/screenshot-manifest.json
        ios/AppStore/screenshot-provenance.json
        ios/AppStore/screenshots
      ],
      "fileCount" => 32,
      "totalBytes" => 32_627_800,
      "contentManifestSha256" => "81b1bbf1dcd225696c8da53ff120f225c2a6ade6ca7886114fcab22a2a69fc89",
    },
    {
      "id" => "ios-ipados-release-simulator-build7-19b9260801e99a77b2352931dc2d701045d4eb94",
      "sourceCommit" => "19b9260801e99a77b2352931dc2d701045d4eb94",
      "status" => "historical-build7",
      "eligibleForBuild8Upload" => false,
      "paths" => %w[
        ios/AppStore/screenshot-manifest-v1.1.json
        ios/AppStore/screenshot-provenance-v1.1.json
        ios/AppStore/screenshots-v1.1
      ],
      "fileCount" => 32,
      "totalBytes" => 39_384_886,
      "contentManifestSha256" => "a16732fc2051d8cc5d562b19d8971acc44afee4f0b13d52a58c83019e801289c",
    },
    {
      "id" => "ios-ipados-debug-simulator-build8-64854d0c398c0377c464056751457c4943b4d714",
      "sourceCommit" => "64854d0c398c0377c464056751457c4943b4d714",
      "status" => "historical-unapproved",
      "eligibleForBuild8Upload" => false,
      "paths" => %w[
        ios/AppStore/screenshot-manifest-v1.1-build8.json
        ios/AppStore/screenshot-provenance-v1.1-build8.json
        ios/AppStore/screenshots-v1.1-build8
        ios/AppStore/screenshot-evidence-v1.1-build8
      ],
      "fileCount" => 19,
      "totalBytes" => 12_380_118,
      "contentManifestSha256" => "b9f6e6979b56046b8fb3c528f724bcb293c1c42df2f64fbd323130781c73064c",
    },
    {
      "id" => "native-debug-simulator-build8-b461083bb5bff21eb4f1f4a8b5ef8f0764d89dd2",
      "sourceCommit" => "b461083bb5bff21eb4f1f4a8b5ef8f0764d89dd2",
      "status" => "historical-unapproved",
      "eligibleForBuild8Upload" => false,
      "paths" => ["ios/AppStore/platforms/screenshot-candidates-v1.1-build8"],
      "fileCount" => 33,
      "totalBytes" => 31_940_854,
      "contentManifestSha256" => "89f679e7d457bf74b1fb7e4bcef46a24bf5aa300b6882a88ccd8cffab6e001aa",
    },
  ].freeze
  FRAME_NAMES = %w[home reports map guide alert-preferences].freeze
  SCREENSHOT_EXTENSIONS = %w[.jpg .jpeg .png].freeze
  FRAME_SPECS = {
    "ios-ipados" => [
      *FRAME_NAMES.map.with_index(1) do |name, index|
        {
          "captureSelector" => "ios-iphone-6.5-#{name}",
          "file" => format("en-US/iphone-6.5/%02d-%s.jpg", index, name),
          "pixels" => [1242, 2688],
          "format" => "jpeg",
        }
      end,
      *FRAME_NAMES.map.with_index(1) do |name, index|
        {
          "captureSelector" => "ios-ipad-13-#{name}",
          "file" => format("en-US/ipad-13/%02d-%s.jpg", index, name),
          "pixels" => [2064, 2752],
          "format" => "jpeg",
        }
      end,
    ],
    "tvos" => [
      ["tvos-dashboard", "en-US/01-dashboard.png"],
      ["tvos-recent-reports", "en-US/02-recent-reports.png"],
      ["tvos-event-detail", "en-US/03-event-detail.png"],
    ].map { |selector, file| { "captureSelector" => selector, "file" => file, "pixels" => [1920, 1080], "format" => "png" } },
    "watchos" => [
      ["watchos-headline", "en-US/01-headline.png"],
      ["watchos-recent-reports", "en-US/02-recent-reports.png"],
      ["watchos-event-detail", "en-US/03-event-detail.png"],
    ].map { |selector, file| { "captureSelector" => selector, "file" => file, "pixels" => [410, 502], "format" => "png" } },
    "visionos" => [
      ["visionos-home", "en-US/01-home.png"],
      ["visionos-reports", "en-US/02-reports.png"],
      ["visionos-map", "en-US/03-map.png"],
      ["visionos-guide", "en-US/04-guide.png"],
      ["visionos-alert-preferences", "en-US/05-alert-preferences.png"],
    ].map { |selector, file| { "captureSelector" => selector, "file" => file, "pixels" => [3840, 2160], "format" => "png" } },
    "maccatalyst" => [
      ["maccatalyst-home", "en-US/01-home.png"],
      ["maccatalyst-reports", "en-US/02-reports.png"],
      ["maccatalyst-map", "en-US/03-map.png"],
      ["maccatalyst-guide", "en-US/04-guide.png"],
      ["maccatalyst-alert-preferences", "en-US/05-alert-preferences.png"],
    ].map { |selector, file| { "captureSelector" => selector, "file" => file, "pixels" => [2560, 1600], "format" => "png" } },
  }.freeze

  def initialize(
    root:,
    release_evidence_root: nil,
    image_inspector: AppleScreenshotImageInspector.new,
    source_guard: nil,
    historical_commit_guard: nil,
    historical_evidence: HISTORICAL_EVIDENCE,
    capture_package_validator: nil,
    provenance_repository_root: nil,
    ios_provenance_image_inspector: nil,
    ios_provenance_result_inspector: nil
  )
    requested_root = Pathname.new(root).expand_path
    if requested_root.symlink?
      raise AppleScreenshotReleaseSetValidationError,
            "repository root must not be a symlink: #{requested_root}"
    end
    @root = requested_root.realpath
    requested_release_evidence_root = Pathname.new(release_evidence_root || @root).expand_path
    if requested_release_evidence_root.symlink?
      raise AppleScreenshotReleaseSetValidationError,
            "release evidence root must not be a symlink: #{requested_release_evidence_root}"
    end
    unless requested_release_evidence_root.directory?
      raise AppleScreenshotReleaseSetValidationError,
            "release evidence root must be an existing directory: #{requested_release_evidence_root}"
    end
    @release_evidence_root = requested_release_evidence_root.realpath
    if release_evidence_root && within_directory?(@release_evidence_root, @root)
      raise AppleScreenshotReleaseSetValidationError,
            "external release evidence root must remain outside the repository"
    end
    @image_inspector = image_inspector
    @source_guard = source_guard || AppleScreenshotReleaseSourceGuard.new(@root)
    @historical_commit_guard = historical_commit_guard || AppleScreenshotHistoricalCommitGuard.new(@root)
    @historical_evidence = historical_evidence
    @capture_package_validator = capture_package_validator ||
      AppleScreenshotEmbeddedCapturePackageValidator.new(
        root: @root,
        release_evidence_root: @release_evidence_root == @root ? nil : @release_evidence_root,
        image_inspector: @image_inspector,
        provenance_repository_root: provenance_repository_root,
        ios_provenance_image_inspector: ios_provenance_image_inspector,
        ios_provenance_result_inspector: ios_provenance_result_inspector,
      )
  end

  def validate!(require_release_ready: false, expected_source_commit: nil)
    unless [true, false].include?(require_release_ready)
      raise AppleScreenshotReleaseSetValidationError, "require_release_ready must be Boolean"
    end
    if expected_source_commit && !full_commit?(expected_source_commit)
      raise AppleScreenshotReleaseSetValidationError,
            "expected screenshot source commit must be a full lowercase Git commit"
    end
    if require_release_ready && expected_source_commit.nil?
      raise AppleScreenshotReleaseSetValidationError,
            "release-ready screenshot validation requires an expected source commit"
    end

    index_path = @release_evidence_root.join(INDEX_PATH)
    unless index_path.exist? || index_path.symlink?
      if require_release_ready
        raise AppleScreenshotReleaseSetValidationError,
              "a complete active build-10 screenshot release set is required"
      end
      return :pending
    end
    ensure_plain_file!(index_path, "screenshot set index")
    index = parse_json_object!(index_path)
    validate_index_header!(index)
    historical_frame_sha256s =
      validate_historical_evidence!(index.fetch("historicalEvidence"))

    active = index.fetch("activeReleaseSet")
    if active.nil?
      if require_release_ready
        raise AppleScreenshotReleaseSetValidationError,
              "a complete active build-10 screenshot release set is required"
      end
      return :pending
    end

    validate_active_release_set!(
      active,
      require_release_ready: require_release_ready,
      expected_source_commit: expected_source_commit,
      historical_frame_sha256s: historical_frame_sha256s,
    )
    require_release_ready ? :release_ready : :active_unapproved
  rescue KeyError, TypeError, ArgumentError, NoMethodError => error
    raise AppleScreenshotReleaseSetValidationError,
          "invalid Apple screenshot release-set evidence: #{error.message}"
  end

  private

  def validate_index_header!(index)
    require_exact_keys!(
      index,
      %w[
        schemaVersion product historicalContentManifestAlgorithm requiredPlatforms
        historicalEvidence activeReleaseSet
      ],
      "screenshot set index",
    )
    require_equal!(index.fetch("schemaVersion"), 1, "index schemaVersion")
    require_equal!(index.fetch("product"), PRODUCT, "index product")
    require_equal!(
      index.fetch("historicalContentManifestAlgorithm"), HISTORICAL_ALGORITHM,
      "index historical content-manifest algorithm",
    )
    required = index.fetch("requiredPlatforms")
    unless required.is_a?(Array)
      raise AppleScreenshotReleaseSetValidationError, "index requiredPlatforms must be an array"
    end
    normalized = required.map.with_index do |record, index_number|
      require_exact_keys!(record, %w[platform frameCount], "required platform #{index_number}")
      [record.fetch("platform"), record.fetch("frameCount")]
    end.to_h
    require_equal!(normalized, REQUIRED_PLATFORMS, "index required platform inventory")
    require_equal!(required.map { |record| record.fetch("platform") }, REQUIRED_PLATFORMS.keys, "index required platform order")
  end

  def validate_historical_evidence!(records)
    require_equal!(records, @historical_evidence, "historical evidence index")
    historical_frame_sha256s = Set.new
    records.each do |record|
      commit = record.fetch("sourceCommit")
      @historical_commit_guard.validate!(commit) if commit
      files = files_for_repository_paths!(record.fetch("paths"), record.fetch("id"))
      require_equal!(files.length, record.fetch("fileCount"), "#{record.fetch('id')} file count")
      require_equal!(files.sum(&:size), record.fetch("totalBytes"), "#{record.fetch('id')} total bytes")
      manifest = files.map do |file|
        relative = file.relative_path_from(@root).to_s
        "#{Digest::SHA256.file(file).hexdigest}  #{relative}\n"
      end.join
      require_equal!(
        Digest::SHA256.hexdigest(manifest), record.fetch("contentManifestSha256"),
        "#{record.fetch('id')} content-manifest SHA-256",
      )
      files.each do |file|
        next unless SCREENSHOT_EXTENSIONS.include?(file.extname.downcase)

        historical_frame_sha256s << Digest::SHA256.file(file).hexdigest
      end
    end
    historical_frame_sha256s
  end

  def validate_active_release_set!(
    active,
    require_release_ready:,
    expected_source_commit:,
    historical_frame_sha256s:
  )
    require_exact_keys!(
      active,
      %w[sourceCommit rootDirectory manifestFile manifestSha256 approvalFile approvalSha256],
      "active release set",
    )
    source_commit = active.fetch("sourceCommit")
    require_full_commit!(source_commit, "active release sourceCommit")
    if expected_source_commit
      require_equal!(source_commit, expected_source_commit, "active/expected screenshot source commit")
    end

    expected_root_relative = "#{RELEASE_ROOT}/#{source_commit}"
    require_equal!(active.fetch("rootDirectory"), expected_root_relative, "active release rootDirectory")
    release_root = @release_evidence_root.join(expected_root_relative)
    ensure_plain_directory!(release_root, "active release root")
    expected_manifest_relative = "#{expected_root_relative}/release-set.json"
    require_equal!(active.fetch("manifestFile"), expected_manifest_relative, "active release manifestFile")
    manifest_path = @release_evidence_root.join(expected_manifest_relative)
    ensure_plain_file!(manifest_path, "active release manifest")
    manifest_sha256 = active.fetch("manifestSha256")
    require_sha256!(manifest_sha256, "active release manifestSha256")
    require_equal!(Digest::SHA256.file(manifest_path).hexdigest, manifest_sha256, "active release manifest actual SHA-256")

    manifest = parse_json_object!(manifest_path)
    release_evidence = validate_release_manifest!(
      manifest,
      release_root,
      source_commit,
      historical_frame_sha256s,
    )
    @source_guard.validate!(
      source_commit,
      capture_inputs: release_evidence.fetch(:capture_inputs),
    )

    approval_file = active.fetch("approvalFile")
    approval_sha256 = active.fetch("approvalSha256")
    if approval_file.nil? || approval_sha256.nil?
      unless approval_file.nil? && approval_sha256.nil?
        raise AppleScreenshotReleaseSetValidationError,
              "active approval file and SHA-256 must both be null or both be present"
      end
      approval_path = release_root.join("release-approval.json")
      if approval_path.exist? || approval_path.symlink?
        raise AppleScreenshotReleaseSetValidationError,
              "unindexed release-approval.json is forbidden"
      end
      if require_release_ready
        raise AppleScreenshotReleaseSetValidationError,
              "release-ready screenshots require a separate named signed-parity approval"
      end
      validate_release_root_inventory!(release_root, include_approval: false)
      return
    end

    expected_approval_relative = "#{expected_root_relative}/release-approval.json"
    require_equal!(approval_file, expected_approval_relative, "active release approvalFile")
    require_sha256!(approval_sha256, "active release approvalSha256")
    approval_path = @release_evidence_root.join(expected_approval_relative)
    ensure_plain_file!(approval_path, "active release approval")
    require_equal!(Digest::SHA256.file(approval_path).hexdigest, approval_sha256, "active release approval actual SHA-256")
    validate_release_approval!(
      parse_json_object!(approval_path),
      source_commit,
      manifest_sha256,
      release_evidence.fetch(:capture_completed_at),
    )
    validate_release_root_inventory!(release_root, include_approval: true)
  end

  def validate_release_manifest!(
    manifest,
    release_root,
    source_commit,
    historical_frame_sha256s
  )
    require_exact_keys!(
      manifest,
      %w[
        schemaVersion status uploadApproved sourceCommit product
        packageContentManifestAlgorithm totalFrameCount packages
      ],
      "release-set manifest",
    )
    require_equal!(manifest.fetch("schemaVersion"), 1, "release-set schemaVersion")
    require_equal!(manifest.fetch("status"), "source-frozen-unapproved", "release-set status")
    require_equal!(manifest.fetch("uploadApproved"), false, "release-set uploadApproved")
    require_equal!(manifest.fetch("sourceCommit"), source_commit, "release-set sourceCommit")
    require_equal!(manifest.fetch("product"), PRODUCT, "release-set product")
    require_equal!(
      manifest.fetch("packageContentManifestAlgorithm"), PACKAGE_ALGORITHM,
      "release-set package content-manifest algorithm",
    )
    require_equal!(manifest.fetch("totalFrameCount"), REQUIRED_PLATFORMS.values.sum, "release-set totalFrameCount")

    packages = manifest.fetch("packages")
    unless packages.is_a?(Array)
      raise AppleScreenshotReleaseSetValidationError, "release-set packages must be an array"
    end
    require_equal!(packages.length, REQUIRED_PLATFORMS.length, "release-set package count")
    require_equal!(packages.map { |record| record.fetch("platform") }, REQUIRED_PLATFORMS.keys, "release-set package order")

    package_evidence = packages.map do |package|
      validate_package!(package, release_root, source_commit)
    end
    frame_sha256s = package_evidence.flat_map { |record| record.fetch(:frame_sha256s) }
    duplicate_frame_sha256s = frame_sha256s.group_by(&:itself).select do |_sha256, occurrences|
      occurrences.length > 1
    end.keys
    unless duplicate_frame_sha256s.empty?
      raise AppleScreenshotReleaseSetValidationError,
            "active release set must contain 26 byte-distinct frames; duplicate SHA-256: " \
            "#{duplicate_frame_sha256s.sort.join(', ')}"
    end
    historical_reuse = frame_sha256s.to_set & historical_frame_sha256s
    unless historical_reuse.empty?
      raise AppleScreenshotReleaseSetValidationError,
            "active release frames must not reuse locked historical screenshot bytes: " \
            "#{historical_reuse.to_a.sort.join(', ')}"
    end

    {
      capture_inputs: package_evidence.map { |record| record.fetch(:plan) },
      capture_completed_at: package_evidence.to_h do |record|
        [record.fetch(:platform), record.fetch(:capture_completed_at)]
      end,
    }
  end

  def validate_package!(package, release_root, source_commit)
    require_exact_keys!(
      package,
      %w[
        platform rootDirectory plan metadataFile metadataSha256
        contentManifestSha256 frameCount
      ],
      "release package",
    )
    platform = package.fetch("platform")
    expected_count = REQUIRED_PLATFORMS.fetch(platform) do
      raise AppleScreenshotReleaseSetValidationError,
            "release set contains unsupported platform #{platform.inspect}"
    end
    require_equal!(package.fetch("rootDirectory"), platform, "#{platform} package rootDirectory")
    require_equal!(package.fetch("frameCount"), expected_count, "#{platform} package frameCount")
    package_root = release_root.join(platform)
    ensure_plain_directory!(package_root, "#{platform} package root")

    plan = package.fetch("plan")
    require_exact_keys!(plan, %w[file sha256], "#{platform} package plan")
    require_equal!(plan.fetch("file"), PLAN_PATHS.fetch(platform), "#{platform} package plan file")
    require_sha256!(plan.fetch("sha256"), "#{platform} package plan SHA-256")
    plan_path = @root.join(plan.fetch("file"))
    ensure_plain_file!(plan_path, "#{platform} package plan")
    require_equal!(Digest::SHA256.file(plan_path).hexdigest, plan.fetch("sha256"), "#{platform} current plan SHA-256")
    validate_plan_semantics!(platform, plan_path)

    require_equal!(package.fetch("metadataFile"), "package-provenance.json", "#{platform} metadataFile")
    metadata_path = package_root.join("package-provenance.json")
    ensure_plain_file!(metadata_path, "#{platform} package provenance")
    metadata_sha256 = package.fetch("metadataSha256")
    require_sha256!(metadata_sha256, "#{platform} metadataSha256")
    require_equal!(Digest::SHA256.file(metadata_path).hexdigest, metadata_sha256, "#{platform} package provenance actual SHA-256")
    metadata = parse_json_object!(metadata_path)
    provenance_evidence =
      validate_package_provenance!(metadata, package_root, platform, source_commit)

    actual_files = tree_files!(package_root, "#{platform} package").map do |file|
      file.relative_path_from(package_root).to_s
    end
    require_equal!(
      actual_files,
      provenance_evidence.fetch(:expected_files).sort,
      "#{platform} package file inventory",
    )
    manifest_source = actual_files.map do |relative|
      "#{Digest::SHA256.file(package_root.join(relative)).hexdigest}  #{relative}\n"
    end.join
    content_sha256 = package.fetch("contentManifestSha256")
    require_sha256!(content_sha256, "#{platform} contentManifestSha256")
    require_equal!(Digest::SHA256.hexdigest(manifest_source), content_sha256, "#{platform} package content-manifest SHA-256")
    {
      platform: platform,
      plan: plan,
      frame_sha256s: provenance_evidence.fetch(:frame_sha256s),
      capture_completed_at: provenance_evidence.fetch(:capture_completed_at),
    }
  end

  def validate_plan_semantics!(platform, plan_path)
    document = parse_json_object!(plan_path)
    expected_specs = FRAME_SPECS.fetch(platform)
    if platform == "ios-ipados"
      display_classes = document.fetch("displayClasses")
      expected_classes = {
        "iphone-6.5" => [1242, 2688],
        "ipad-13" => [2064, 2752],
      }
      require_equal!(display_classes.keys, expected_classes.keys, "iOS/iPadOS plan display classes")
      expected_classes.each do |display_class, pixels|
        require_equal!(
          display_classes.fetch(display_class).fetch("portraitPixels"),
          pixels,
          "iOS/iPadOS plan #{display_class} pixels",
        )
      end
      planned_frames = document.fetch("frames").map.with_index do |frame, index|
        require_exact_keys!(
          frame,
          %w[captureSelector displayClass file screen purpose captureStatus],
          "iOS/iPadOS plan frame #{index}",
        )
        require_equal!(frame.fetch("captureStatus"), "pending", "iOS/iPadOS plan frame #{index} status")
        %w[screen purpose].each do |field|
          require_nonempty_string!(frame.fetch(field), "iOS/iPadOS plan frame #{index} #{field}")
        end
        display_class = frame.fetch("displayClass")
        {
          "captureSelector" => frame.fetch("captureSelector"),
          "displayClass" => display_class,
          "file" => frame.fetch("file"),
          "pixels" => expected_classes.fetch(display_class),
        }
      end
      expected_frames = expected_specs.map do |frame|
        display_class = frame.fetch("file").split("/").fetch(1)
        {
          "captureSelector" => frame.fetch("captureSelector"),
          "displayClass" => display_class,
          "file" => File.basename(frame.fetch("file")),
          "pixels" => frame.fetch("pixels"),
        }
      end
      require_equal!(
        planned_frames,
        expected_frames,
        "iOS/iPadOS plan exact ten-frame contract",
      )
      return
    end

    planned_frames = document.fetch("frames").map do |frame|
      %w[captureSelector file pixels].to_h { |field| [field, frame.fetch(field)] }
    end
    expected_frames = expected_specs.map do |frame|
      %w[captureSelector file pixels].to_h { |field| [field, frame.fetch(field)] }
    end
    require_equal!(planned_frames, expected_frames, "#{platform} plan frame contract")
  end

  def validate_package_provenance!(metadata, package_root, platform, source_commit)
    require_exact_keys!(
      metadata,
      %w[
        schemaVersion status uploadApproved sourceCommit platform configuration
        sourceTreeState debugLocalOverridePresent artifactFile artifactSha256
        captureWindowUtc captureEnvironment frames evidenceFiles
      ],
      "#{platform} package provenance",
    )
    require_equal!(metadata.fetch("schemaVersion"), 1, "#{platform} provenance schemaVersion")
    require_equal!(metadata.fetch("status"), "unapproved-source-frozen-candidate", "#{platform} provenance status")
    require_equal!(metadata.fetch("uploadApproved"), false, "#{platform} provenance uploadApproved")
    require_equal!(metadata.fetch("sourceCommit"), source_commit, "#{platform} provenance sourceCommit")
    require_equal!(metadata.fetch("platform"), platform, "#{platform} provenance platform")
    require_equal!(metadata.fetch("configuration"), "Debug", "#{platform} provenance configuration")
    require_equal!(metadata.fetch("sourceTreeState"), "clean", "#{platform} provenance sourceTreeState")
    require_equal!(metadata.fetch("debugLocalOverridePresent"), false, "#{platform} provenance debugLocalOverridePresent")
    require_sha256!(metadata.fetch("artifactSha256"), "#{platform} provenance artifactSha256")
    capture_completed_at = validate_capture_window!(metadata.fetch("captureWindowUtc"), platform)
    validate_capture_environment!(metadata.fetch("captureEnvironment"), platform)

    expected_specs = FRAME_SPECS.fetch(platform)
    frames = metadata.fetch("frames")
    unless frames.is_a?(Array)
      raise AppleScreenshotReleaseSetValidationError, "#{platform} provenance frames must be an array"
    end
    require_equal!(frames.length, expected_specs.length, "#{platform} provenance frame count")
    frames.zip(expected_specs).each_with_index do |(frame, expected), index|
      frame_keys = %w[captureSelector file sha256 pixels format hasAlpha]
      frame_keys << "captureEvidence" if platform == "maccatalyst"
      require_exact_keys!(
        frame,
        frame_keys,
        "#{platform} provenance frame #{index}",
      )
      %w[captureSelector file pixels format].each do |field|
        require_equal!(frame.fetch(field), expected.fetch(field), "#{platform} frame #{index} #{field}")
      end
      require_equal!(frame.fetch("hasAlpha"), false, "#{platform} frame #{index} hasAlpha")
      require_sha256!(frame.fetch("sha256"), "#{platform} frame #{index} SHA-256")
      validate_safe_relative_path!(frame.fetch("file"), "#{platform} frame #{index} file")
      screenshot = package_root.join(frame.fetch("file"))
      ensure_plain_file!(screenshot, "#{platform} screenshot #{frame.fetch('file')}")
      require_equal!(Digest::SHA256.file(screenshot).hexdigest, frame.fetch("sha256"), "#{platform} frame #{index} actual SHA-256")
      properties = @image_inspector.inspect(screenshot)
      require_equal!([properties.fetch(:width), properties.fetch(:height)], expected.fetch("pixels"), "#{platform} frame #{index} actual pixels")
      require_equal!(properties.fetch(:format), expected.fetch("format"), "#{platform} frame #{index} actual format")
      require_equal!(properties.fetch(:has_alpha), false, "#{platform} frame #{index} actual alpha")
      if platform == "maccatalyst"
        validate_maccatalyst_capture_evidence!(
          frame.fetch("captureEvidence"),
          package_root,
          frame.fetch("captureSelector"),
          index,
        )
      end
    end
    if platform == "maccatalyst"
      nonces = frames.map { |frame| frame.fetch("captureEvidence").fetch("nonce") }
      require_equal!(nonces.uniq.length, nonces.length, "Mac Catalyst capture nonce uniqueness")
      frame_scales = frames.map do |frame|
        frame.fetch("captureEvidence").fetch("sourceDisplayScale")
      end.uniq
      require_equal!(frame_scales.length, 1, "Mac Catalyst frame source display-scale inventory")
      require_equal!(frame_scales.first, metadata.fetch("captureEnvironment").fetch("sourceDisplayScale"),
                     "Mac Catalyst frame/environment source display scale")
    end

    evidence = metadata.fetch("evidenceFiles")
    unless evidence.is_a?(Array) && evidence.length >= 2
      raise AppleScreenshotReleaseSetValidationError,
            "#{platform} provenance evidenceFiles must include the archived artifact and independent capture evidence"
    end
    evidence_paths = evidence.map.with_index do |record, index|
      require_exact_keys!(record, %w[file sha256], "#{platform} evidence file #{index}")
      relative = record.fetch("file")
      validate_safe_relative_path!(relative, "#{platform} evidence file #{index}")
      unless relative.start_with?("evidence/")
        raise AppleScreenshotReleaseSetValidationError,
              "#{platform} evidence file must be below evidence/: #{relative}"
      end
      require_sha256!(record.fetch("sha256"), "#{platform} evidence file #{index} SHA-256")
      path = package_root.join(relative)
      ensure_plain_file!(path, "#{platform} evidence file #{relative}")
      unless path.size.positive?
        raise AppleScreenshotReleaseSetValidationError,
              "#{platform} evidence file must be nonempty: #{relative}"
      end
      require_equal!(Digest::SHA256.file(path).hexdigest, record.fetch("sha256"), "#{platform} evidence file #{index} actual SHA-256")
      relative
    end
    all_paths = ["package-provenance.json"] + frames.map { |frame| frame.fetch("file") } + evidence_paths
    duplicates = all_paths.group_by(&:itself).select { |_path, values| values.length > 1 }.keys
    unless duplicates.empty?
      raise AppleScreenshotReleaseSetValidationError,
            "#{platform} package contains duplicate file records: #{duplicates.sort.join(', ')}"
    end

    artifact_file = metadata.fetch("artifactFile")
    validate_safe_relative_path!(artifact_file, "#{platform} provenance artifactFile")
    require_equal!(
      artifact_file,
      "evidence/capture-artifact",
      "#{platform} conventional archived artifact path",
    )
    unless artifact_file.start_with?("evidence/") && evidence_paths.include?(artifact_file)
      raise AppleScreenshotReleaseSetValidationError,
            "#{platform} archived artifact must be a recorded evidence/ file"
    end
    unless (evidence_paths - [artifact_file]).any?
      raise AppleScreenshotReleaseSetValidationError,
            "#{platform} package requires capture evidence independent of the archived artifact"
    end
    artifact_path = package_root.join(artifact_file)
    ensure_plain_file!(artifact_path, "#{platform} archived capture artifact")
    require_equal!(
      Digest::SHA256.file(artifact_path).hexdigest,
      metadata.fetch("artifactSha256"),
      "#{platform} archived artifact actual SHA-256",
    )

    raw_capture_root = package_root.join("evidence/raw-capture")
    ensure_plain_directory!(raw_capture_root, "#{platform} embedded raw capture root")
    deep_evidence = @capture_package_validator.validate!(
      platform: platform,
      source_commit: source_commit,
      capture_root: raw_capture_root,
      artifact: artifact_path,
    )
    require_equal!(
      deep_evidence.fetch(:artifact_sha256),
      metadata.fetch("artifactSha256"),
      "#{platform} deep artifact SHA-256",
    )
    require_equal!(
      deep_evidence.fetch(:capture_window),
      metadata.fetch("captureWindowUtc"),
      "#{platform} deep capture window",
    )
    require_equal!(
      deep_evidence.fetch(:capture_environment),
      metadata.fetch("captureEnvironment"),
      "#{platform} deep capture environment",
    )
    require_equal!(
      deep_evidence.fetch(:frames),
      frames,
      "#{platform} deep frame provenance",
    )
    expected_evidence = [
      { "file" => artifact_file, "sha256" => metadata.fetch("artifactSha256") },
      *deep_evidence.fetch(:raw_evidence),
    ]
    require_equal!(evidence, expected_evidence, "#{platform} exact embedded evidence inventory")

    {
      expected_files: all_paths,
      frame_sha256s: frames.map { |frame| frame.fetch("sha256") },
      capture_completed_at: capture_completed_at,
    }
  end

  def validate_capture_environment!(environment, platform)
    if platform == "maccatalyst"
      require_exact_keys!(
        environment,
        %w[
          kind xcodeVersion operatingSystem runtimeIdentifier deviceIdentifier deviceModel
          captureApi captureSurface logicalViewPoints sourceDisplayScale rasterizationScale
          pixels afterScreenUpdates postCaptureResizePerformed
        ],
        "#{platform} capture environment",
      )
      %w[xcodeVersion operatingSystem deviceIdentifier deviceModel].each do |field|
        value = environment.fetch(field)
        unless value.is_a?(String) && !value.strip.empty?
          raise AppleScreenshotReleaseSetValidationError,
                "#{platform} capture environment #{field} must be nonempty"
        end
      end
      require_equal!(environment.fetch("kind"), "maccatalyst-uikit-hierarchy",
                     "Mac Catalyst capture kind")
      require_equal!(environment.fetch("runtimeIdentifier"), nil,
                     "Mac Catalyst runtimeIdentifier")
      require_equal!(environment.fetch("captureApi"), "UIKit.UIView.drawHierarchy",
                     "Mac Catalyst capture API")
      require_equal!(environment.fetch("captureSurface"), "live-catalyst-uiwindow-hierarchy",
                     "Mac Catalyst capture surface")
      require_equal!(environment.fetch("logicalViewPoints"), [1_280, 800],
                     "Mac Catalyst logicalViewPoints")
      source_display_scale = environment.fetch("sourceDisplayScale")
      unless source_display_scale.is_a?(Numeric) && source_display_scale.finite? &&
             source_display_scale.between?(0.5, 4)
        raise AppleScreenshotReleaseSetValidationError,
              "Mac Catalyst sourceDisplayScale must be finite and between 0.5 and 4"
      end
      require_equal!(environment.fetch("rasterizationScale"), 2,
                     "Mac Catalyst rasterizationScale")
      require_equal!(environment.fetch("pixels"), [2_560, 1_600],
                     "Mac Catalyst capture pixels")
      require_equal!(environment.fetch("afterScreenUpdates"), true,
                     "Mac Catalyst after-screen-updates policy")
      require_equal!(environment.fetch("postCaptureResizePerformed"), false,
                     "Mac Catalyst post-capture resize")
      return
    end

    require_exact_keys!(
      environment,
      %w[
        kind xcodeVersion operatingSystem runtimeIdentifier deviceIdentifier
        deviceModel logicalWindowPoints backingScale
      ],
      "#{platform} capture environment",
    )
    %w[xcodeVersion operatingSystem deviceIdentifier deviceModel].each do |field|
      value = environment.fetch(field)
      unless value.is_a?(String) && !value.strip.empty?
        raise AppleScreenshotReleaseSetValidationError,
              "#{platform} capture environment #{field} must be nonempty"
      end
    end
    require_equal!(environment.fetch("kind"), "simulator", "#{platform} capture kind")
    runtime = environment.fetch("runtimeIdentifier")
    unless runtime.is_a?(String) && !runtime.strip.empty?
      raise AppleScreenshotReleaseSetValidationError,
            "#{platform} capture runtimeIdentifier must be nonempty"
    end
    require_equal!(environment.fetch("logicalWindowPoints"), nil, "#{platform} logicalWindowPoints")
    require_equal!(environment.fetch("backingScale"), nil, "#{platform} backingScale")
  end

  def validate_maccatalyst_capture_evidence!(evidence, package_root, selector, index)
    label = "Mac Catalyst frame #{index} capture evidence"
    require_exact_keys!(
      evidence,
      %w[
        requestFile requestSha256 responseFile responseSha256 rawFile rawSha256 nonce captureApi
        captureSurface logicalViewPoints sourceDisplayScale rasterizationScale pixels
        afterScreenUpdates drawHierarchyComplete postCaptureResizePerformed rendererOpaque
        rendererPreferredRange
      ],
      label,
    )
    unless evidence.fetch("nonce").is_a?(String) && evidence.fetch("nonce").match?(/\A[0-9a-f]{64}\z/)
      raise AppleScreenshotReleaseSetValidationError, "#{label} nonce is invalid"
    end
    require_equal!(evidence.fetch("captureApi"), "UIKit.UIView.drawHierarchy",
                   "#{label} capture API")
    require_equal!(evidence.fetch("captureSurface"), "live-catalyst-uiwindow-hierarchy",
                   "#{label} capture surface")
    require_equal!(evidence.fetch("logicalViewPoints"), [1_280, 800],
                   "#{label} logical view points")
    source_display_scale = evidence.fetch("sourceDisplayScale")
    unless source_display_scale.is_a?(Numeric) && source_display_scale.finite? &&
           source_display_scale.between?(0.5, 4)
      raise AppleScreenshotReleaseSetValidationError,
            "#{label} source display scale must be finite and between 0.5 and 4"
    end
    require_equal!(evidence.fetch("rasterizationScale"), 2,
                   "#{label} rasterization scale")
    require_equal!(evidence.fetch("pixels"), [2_560, 1_600], "#{label} pixels")
    require_equal!(evidence.fetch("afterScreenUpdates"), true,
                   "#{label} after-screen-updates policy")
    require_equal!(evidence.fetch("drawHierarchyComplete"), true,
                   "#{label} hierarchy completion")
    require_equal!(evidence.fetch("postCaptureResizePerformed"), false,
                   "#{label} post-capture resize")
    require_equal!(evidence.fetch("rendererOpaque"), false, "#{label} renderer opacity")
    require_equal!(evidence.fetch("rendererPreferredRange"), "standard",
                   "#{label} renderer preferred range")

    references = [
      [evidence.fetch("requestFile"), evidence.fetch("requestSha256"), "request"],
      [evidence.fetch("responseFile"), evidence.fetch("responseSha256"), "response"],
      [evidence.fetch("rawFile"), evidence.fetch("rawSha256"), "raw PNG"],
    ]
    if references.map(&:first).uniq.length != references.length
      raise AppleScreenshotReleaseSetValidationError,
            "#{label} request, response, and raw PNG files must be distinct"
    end
    expected_paths = [
      "evidence/raw-capture/capture-request-evidence/#{selector}.json",
      "evidence/raw-capture/native-capture-evidence/#{selector}.json",
      "evidence/raw-capture/raw-window-captures/#{selector}.png",
    ]
    require_equal!(references.map(&:first), expected_paths, "#{label} source-addressed paths")
    references.each do |relative, sha256, kind|
      validate_safe_relative_path!(relative, "#{label} #{kind} file")
      unless relative.start_with?("evidence/raw-capture/")
        raise AppleScreenshotReleaseSetValidationError,
              "#{label} #{kind} file must retain source-addressed raw capture evidence"
      end
      require_sha256!(sha256, "#{label} #{kind} SHA-256")
      path = package_root.join(relative)
      ensure_plain_file!(path, "#{label} #{kind}")
      require_equal!(Digest::SHA256.file(path).hexdigest, sha256,
                     "#{label} #{kind} actual SHA-256")
    end
  end

  def validate_capture_window!(window, platform)
    require_exact_keys!(window, %w[startedAt completedAt], "#{platform} captureWindowUtc")
    started = strict_utc_time!(window.fetch("startedAt"), "#{platform} capture startedAt")
    completed = strict_utc_time!(window.fetch("completedAt"), "#{platform} capture completedAt")
    unless completed >= started
      raise AppleScreenshotReleaseSetValidationError,
            "#{platform} capture completion must not precede its start"
    end
    completed
  end

  def validate_release_approval!(
    approval,
    source_commit,
    manifest_sha256,
    capture_completed_at
  )
    require_exact_keys!(
      approval,
      %w[
        schemaVersion status uploadApproved sourceCommit releaseSetManifestSha256
        dispatchActorGitHubLogin environmentApproval captureRun approvals reviewedAtUtc platforms
      ],
      "release approval",
    )
    require_equal!(approval.fetch("schemaVersion"), 3, "release approval schemaVersion")
    require_equal!(approval.fetch("status"), "approved-for-build10-upload", "release approval status")
    require_equal!(approval.fetch("uploadApproved"), true, "release approval uploadApproved")
    require_equal!(approval.fetch("sourceCommit"), source_commit, "release approval sourceCommit")
    require_equal!(approval.fetch("releaseSetManifestSha256"), manifest_sha256, "release approval manifest SHA-256")
    actor = approval.fetch("dispatchActorGitHubLogin")
    unless actor.is_a?(String) && actor.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/)
      raise AppleScreenshotReleaseSetValidationError,
            "release approval requires the dispatching GitHub login"
    end
    approved_reviewer_logins = validate_environment_approval!(
      approval.fetch("environmentApproval"),
      source_commit,
      actor,
    )
    capture_run_completed_at =
      validate_capture_run_approval!(approval.fetch("captureRun"), source_commit)
    approvals = approval.fetch("approvals")
    require_exact_keys!(
      approvals,
      %w[visual privacy signedReleaseParity],
      "named release approvals",
    )
    latest_capture = (capture_completed_at.values + [capture_run_completed_at]).max
    approval_reviewed_at = approvals.to_h do |kind, record|
      require_exact_keys!(record, %w[approved reviewer reviewedAtUtc], "#{kind} approval")
      require_equal!(record.fetch("approved"), true, "#{kind} approval")
      reviewer = record.fetch("reviewer")
      unless reviewer.is_a?(String) && !reviewer.strip.empty? && reviewer.length <= 100 &&
             !reviewer.match?(/[\u0000-\u001f\u007f]/)
        raise AppleScreenshotReleaseSetValidationError,
              "#{kind} approval requires a valid named reviewer"
      end
      unless approved_reviewer_logins.include?(reviewer) && !reviewer.casecmp?(actor)
        raise AppleScreenshotReleaseSetValidationError,
              "#{kind} reviewer must be an approved protected-environment login distinct from the actor"
      end
      review_time = strict_utc_time!(record.fetch("reviewedAtUtc"), "#{kind} reviewedAtUtc")
      unless review_time >= latest_capture
        raise AppleScreenshotReleaseSetValidationError,
              "#{kind} review must not predate screenshot capture completion"
      end
      [kind, review_time]
    end
    reviewed_at =
      strict_utc_time!(approval.fetch("reviewedAtUtc"), "release approval reviewedAtUtc")
    platforms = approval.fetch("platforms")
    unless platforms.is_a?(Array)
      raise AppleScreenshotReleaseSetValidationError, "release approval platforms must be an array"
    end
    require_equal!(platforms.map { |record| record.fetch("platform") }, REQUIRED_PLATFORMS.keys, "release approval platform order")
    signed_run_ids = {}
    signed_run_attempts = {}
    signed_hashes = {}
    attestation_names = {}
    attestation_digests = {}
    parity_reviewed_at = platforms.to_h do |record|
      platform = record.fetch("platform")
      require_exact_keys!(
        record,
        %w[
          platform signedReleaseRunId signedReleaseRunAttempt signedReleaseWorkflowFile
          signedReleaseAttestationArtifactName signedReleaseAttestationArtifactDigest
          signedReleaseArtifactKind signedReleaseArtifactSha256 signedMarketingVersion
          signedBuildNumber signedDistributionMode signedReleaseAttestedAtUtc
          signedBuildSourceCommit signedRunCompletedAtUtc signedReleaseParityApproved
          parityReviewedAtUtc
        ],
        "#{platform} release approval",
      )
      run_id = record.fetch("signedReleaseRunId")
      unless run_id.is_a?(Integer) && run_id.positive?
        raise AppleScreenshotReleaseSetValidationError,
              "#{platform} signed release run ID must be a positive integer"
      end
      run_attempt = record.fetch("signedReleaseRunAttempt")
      unless run_attempt.is_a?(Integer) && run_attempt.positive?
        raise AppleScreenshotReleaseSetValidationError,
              "#{platform} signed release run attempt must be a positive integer"
      end
      require_equal!(
        record.fetch("signedReleaseWorkflowFile"),
        SIGNED_RELEASE_WORKFLOW_FILES.fetch(platform),
        "#{platform} signed release workflow file",
      )
      role = %w[ios-ipados watchos].include?(platform) ? "ios-ipados-watchos" : platform
      require_equal!(
        record.fetch("signedReleaseAttestationArtifactName"),
        "signed-release-attestation-#{role}-#{source_commit}-#{run_id}-#{run_attempt}",
        "#{platform} signed release attestation artifact name",
      )
      digest = record.fetch("signedReleaseAttestationArtifactDigest")
      unless digest.is_a?(String) && digest.match?(/\Asha256:[0-9a-f]{64}\z/)
        raise AppleScreenshotReleaseSetValidationError,
              "#{platform} signed release attestation artifact digest is invalid"
      end
      require_equal!(
        record.fetch("signedReleaseArtifactKind"),
        SIGNED_RELEASE_ARTIFACT_KINDS.fetch(platform),
        "#{platform} signed release artifact kind",
      )
      require_sha256!(record.fetch("signedReleaseArtifactSha256"), "#{platform} signed artifact SHA-256")
      require_equal!(record.fetch("signedMarketingVersion"), PRODUCT.fetch("marketingVersion"),
                     "#{platform} signed marketing version")
      require_equal!(record.fetch("signedBuildNumber"), PRODUCT.fetch("build"),
                     "#{platform} signed build number")
      require_equal!(record.fetch("signedDistributionMode"), "testflight-upload",
                     "#{platform} signed distribution mode")
      signed_attested_at = strict_utc_time!(
        record.fetch("signedReleaseAttestedAtUtc"),
        "#{platform} signedReleaseAttestedAtUtc",
      )
      signed_commit = record.fetch("signedBuildSourceCommit")
      require_full_commit!(signed_commit, "#{platform} signed build source commit")
      require_equal!(signed_commit, source_commit, "#{platform} signed build source commit")
      signed_run_completed_at = strict_utc_time!(
        record.fetch("signedRunCompletedAtUtc"),
        "#{platform} signedRunCompletedAtUtc",
      )
      unless signed_attested_at <= signed_run_completed_at
        raise AppleScreenshotReleaseSetValidationError,
              "#{platform} signed attestation must not postdate signed run completion"
      end
      require_equal!(record.fetch("signedReleaseParityApproved"), true, "#{platform} signed Release parity")
      parity_time = strict_utc_time!(
        record.fetch("parityReviewedAtUtc"),
        "#{platform} parityReviewedAtUtc",
      )
      require_equal!(
        parity_time,
        approval_reviewed_at.fetch("signedReleaseParity"),
        "#{platform} parity/named signed Release review time",
      )
      unless parity_time >= capture_completed_at.fetch(platform)
        raise AppleScreenshotReleaseSetValidationError,
              "#{platform} signed parity review must not predate screenshot capture completion"
      end
      unless parity_time >= signed_run_completed_at
        raise AppleScreenshotReleaseSetValidationError,
              "#{platform} signed parity review must not predate signed upload completion"
      end
      @source_guard.validate_product_equivalent!(source_commit, signed_commit)
      signed_run_ids[platform] = run_id
      signed_run_attempts[platform] = run_attempt
      signed_hashes[platform] = record.fetch("signedReleaseArtifactSha256")
      attestation_names[platform] = record.fetch("signedReleaseAttestationArtifactName")
      attestation_digests[platform] = digest
      [platform, parity_time]
    end
    require_equal!(signed_run_ids.fetch("ios-ipados"), signed_run_ids.fetch("watchos"),
                   "iOS/iPadOS and watchOS signed release run ID")
    require_equal!(signed_run_attempts.fetch("ios-ipados"), signed_run_attempts.fetch("watchos"),
                   "iOS/iPadOS and watchOS signed release run attempt")
    require_equal!(signed_hashes.fetch("ios-ipados"), signed_hashes.fetch("watchos"),
                   "iOS/iPadOS and watchOS signed IPA SHA-256")
    require_equal!(attestation_names.fetch("ios-ipados"), attestation_names.fetch("watchos"),
                   "iOS/iPadOS and watchOS signed attestation name")
    require_equal!(attestation_digests.fetch("ios-ipados"), attestation_digests.fetch("watchos"),
                   "iOS/iPadOS and watchOS signed attestation digest")
    require_equal!(signed_run_ids.values.uniq.length, 4, "distinct signed release run count")
    require_equal!(signed_hashes.values.uniq.length, 4, "distinct signed release artifact count")
    require_equal!(attestation_names.values.uniq.length, 4, "distinct signed attestation name count")
    require_equal!(attestation_digests.values.uniq.length, 4, "distinct signed attestation digest count")
    require_equal!(parity_reviewed_at.values.uniq.length, 1,
                   "signed Release parity completion time count")
    require_equal!(reviewed_at, approval_reviewed_at.values.max,
                   "overall release review completion time")
  end

  def validate_environment_approval!(environment_approval, source_commit, actor)
    require_exact_keys!(
      environment_approval,
      %w[
        schemaVersion repository runId runAttempt workflowFile headSha environment
        approvedReviewerGitHubLogins
      ],
      "protected environment approval",
    )
    require_equal!(environment_approval.fetch("schemaVersion"), 1,
                   "protected environment approval schemaVersion")
    require_equal!(environment_approval.fetch("repository"), CANONICAL_REPOSITORY,
                   "protected environment approval repository")
    run_id = environment_approval.fetch("runId")
    run_attempt = environment_approval.fetch("runAttempt")
    unless run_id.is_a?(Integer) && run_id.positive? &&
           run_attempt.is_a?(Integer) && run_attempt.positive?
      raise AppleScreenshotReleaseSetValidationError,
            "protected environment approval requires a positive run ID and attempt"
    end
    require_equal!(environment_approval.fetch("workflowFile"),
                   ".github/workflows/apple-screenshot-release-ready.yml",
                   "protected environment approval workflow")
    require_equal!(environment_approval.fetch("headSha"), source_commit,
                   "protected environment approval head SHA")
    require_equal!(environment_approval.fetch("environment"), "ios-app-store-release",
                   "protected environment approval environment")
    logins = environment_approval.fetch("approvedReviewerGitHubLogins")
    unless logins.is_a?(Array) && !logins.empty? && logins == logins.uniq.sort &&
           logins.all? { |login| login.is_a?(String) && login.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/) }
      raise AppleScreenshotReleaseSetValidationError,
            "protected environment approved reviewer login inventory is invalid"
    end
    unless logins.any? { |login| !login.casecmp?(actor) }
      raise AppleScreenshotReleaseSetValidationError,
            "protected environment approval requires a reviewer distinct from the actor"
    end
    logins
  end

  def validate_capture_run_approval!(capture_run, source_commit)
    require_exact_keys!(
      capture_run,
      %w[
        schemaVersion repository runId runAttempt workflowFile event headBranch headSha status
        conclusion completedAtUtc artifacts
      ],
      "capture run approval",
    )
    require_equal!(capture_run.fetch("schemaVersion"), 1, "capture run schemaVersion")
    require_equal!(capture_run.fetch("repository"), CANONICAL_REPOSITORY,
                   "capture run canonical repository")
    run_id = capture_run.fetch("runId")
    unless run_id.is_a?(Integer) && run_id.positive?
      raise AppleScreenshotReleaseSetValidationError, "capture run ID must be a positive integer"
    end
    run_attempt = capture_run.fetch("runAttempt")
    unless run_attempt.is_a?(Integer) && run_attempt.positive?
      raise AppleScreenshotReleaseSetValidationError, "capture run attempt must be a positive integer"
    end
    require_equal!(capture_run.fetch("workflowFile"), CAPTURE_WORKFLOW_FILE,
                   "capture run workflow file")
    require_equal!(capture_run.fetch("event"), "workflow_dispatch", "capture run event")
    require_equal!(capture_run.fetch("headBranch"), "main", "capture run head branch")
    require_equal!(capture_run.fetch("headSha"), source_commit, "capture run head SHA")
    require_equal!(capture_run.fetch("status"), "completed", "capture run status")
    require_equal!(capture_run.fetch("conclusion"), "success", "capture run conclusion")
    completed_at = strict_utc_time!(capture_run.fetch("completedAtUtc"), "capture run completedAtUtc")
    artifacts = capture_run.fetch("artifacts")
    unless artifacts.is_a?(Array)
      raise AppleScreenshotReleaseSetValidationError, "capture run artifacts must be an array"
    end
    expected_names = [
      "UNAPPROVED-debug-simulator-ios-ipados-#{source_commit}",
      "UNAPPROVED-debug-simulator-tvos-#{source_commit}",
      "UNAPPROVED-debug-simulator-watchos-#{source_commit}",
      "UNAPPROVED-debug-simulator-visionos-#{source_commit}",
      "UNAPPROVED-debug-maccatalyst-direct-uikit-#{source_commit}",
    ]
    require_equal!(artifacts.map { |record| record.fetch("name") }, expected_names,
                   "capture run artifact order")
    artifact_ids = artifacts.map.with_index do |record, index|
      require_exact_keys!(record, %w[name id sizeInBytes digest expired],
                          "capture run artifact #{index}")
      artifact_id = record.fetch("id")
      size = record.fetch("sizeInBytes")
      unless artifact_id.is_a?(Integer) && artifact_id.positive?
        raise AppleScreenshotReleaseSetValidationError,
              "capture run artifact #{index} ID must be a positive integer"
      end
      unless size.is_a?(Integer) && size.positive? && size <= 2_147_483_648
        raise AppleScreenshotReleaseSetValidationError,
              "capture run artifact #{index} size is outside the safe bound"
      end
      digest = record.fetch("digest")
      unless digest.is_a?(String) && digest.match?(/\Asha256:[0-9a-f]{64}\z/)
        raise AppleScreenshotReleaseSetValidationError,
              "capture run artifact #{index} digest must be a GitHub SHA-256"
      end
      require_equal!(record.fetch("expired"), false, "capture run artifact #{index} expiration")
      artifact_id
    end
    require_equal!(artifact_ids.uniq.length, artifact_ids.length,
                   "capture run unique artifact ID count")
    completed_at
  end

  def validate_release_root_inventory!(release_root, include_approval:)
    expected = REQUIRED_PLATFORMS.keys + ["release-set.json"]
    expected << "release-approval.json" if include_approval
    actual = release_root.children.map do |entry|
      name = entry.basename.to_s
      if REQUIRED_PLATFORMS.key?(name)
        ensure_plain_directory!(entry, "active release #{name} package")
      else
        ensure_plain_file!(entry, "active release root file #{name}")
      end
      name
    end
    require_equal!(actual.sort, expected.sort, "active release root inventory")
  end

  def files_for_repository_paths!(paths, label)
    files = paths.flat_map do |relative|
      validate_safe_relative_path!(relative, "#{label} path")
      path = @root.join(relative)
      if path.file? && !path.symlink?
        [path]
      elsif path.directory? && !path.symlink?
        tree_files!(path, label)
      else
        raise AppleScreenshotReleaseSetValidationError,
              "#{label} path must be a plain file or directory: #{relative}"
      end
    end
    duplicates = files.group_by { |file| file.realpath.to_s }.select { |_path, values| values.length > 1 }.keys
    unless duplicates.empty?
      raise AppleScreenshotReleaseSetValidationError,
            "#{label} contains overlapping historical paths"
    end
    files.sort_by { |file| file.relative_path_from(@root).to_s }
  end

  def tree_files!(root, label)
    files = []
    visit = lambda do |directory|
      directory.children.sort_by(&:to_s).each do |entry|
        stat = entry.lstat
        if stat.directory? && !entry.symlink?
          visit.call(entry)
        elsif stat.file? && !entry.symlink?
          files << entry
        else
          raise AppleScreenshotReleaseSetValidationError,
                "#{label} contains a symlink or non-regular entry: #{entry}"
        end
      end
    end
    visit.call(root)
    files.sort_by { |file| file.relative_path_from(root).to_s }
  rescue Errno::ENOENT => error
    raise AppleScreenshotReleaseSetValidationError,
          "#{label} inventory changed during validation: #{error.message}"
  end

  def parse_json_object!(path)
    source = path.read
    value = JSON.parse(
      source,
      object_class: AppleScreenshotDuplicateRejectingHash,
      allow_duplicate_key: false,
    )
    return value if value.is_a?(Hash)

    raise AppleScreenshotReleaseSetValidationError, "#{path} must contain one JSON object"
  rescue JSON::ParserError, SystemCallError => error
    raise AppleScreenshotReleaseSetValidationError, "could not parse #{path}: #{error.message}"
  end

  def validate_safe_relative_path!(value, label)
    unless value.is_a?(String) && !value.empty? && !Pathname.new(value).absolute? &&
        Pathname.new(value).cleanpath.to_s == value &&
        value.split(File::SEPARATOR).none? { |segment| segment.empty? || segment == "." || segment == ".." }
      raise AppleScreenshotReleaseSetValidationError, "#{label} must be a normalized relative path"
    end
  end

  def ensure_plain_file!(path, label)
    stat = path.lstat
    return if stat.file? && !path.symlink? && within_root?(path)

    raise AppleScreenshotReleaseSetValidationError,
          "#{label} must be a plain file inside the repository: #{path}"
  rescue Errno::ENOENT
    raise AppleScreenshotReleaseSetValidationError, "#{label} is missing: #{path}"
  end

  def ensure_plain_directory!(path, label)
    stat = path.lstat
    return if stat.directory? && !path.symlink? && within_root?(path)

    raise AppleScreenshotReleaseSetValidationError,
          "#{label} must be a plain directory inside the repository: #{path}"
  rescue Errno::ENOENT
    raise AppleScreenshotReleaseSetValidationError, "#{label} is missing: #{path}"
  end

  def within_root?(path)
    real = path.realpath.to_s
    [@root, @release_evidence_root].any? do |allowed_root|
      root = allowed_root.to_s
      real == root || real.start_with?("#{root}#{File::SEPARATOR}")
    end
  end

  def within_directory?(path, directory)
    real = path.realpath.to_s
    root = directory.realpath.to_s
    real == root || real.start_with?("#{root}#{File::SEPARATOR}")
  end

  def require_exact_keys!(value, expected, label)
    unless value.is_a?(Hash)
      raise AppleScreenshotReleaseSetValidationError, "#{label} must be an object"
    end
    require_equal!(value.keys.sort, expected.sort, "#{label} keys")
  end

  def require_full_commit!(value, label)
    return if full_commit?(value)

    raise AppleScreenshotReleaseSetValidationError,
          "#{label} must be a full lowercase Git commit"
  end

  def full_commit?(value)
    value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)
  end

  def require_sha256!(value, label)
    return if value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)

    raise AppleScreenshotReleaseSetValidationError, "#{label} must be a lowercase SHA-256"
  end

  def require_nonempty_string!(value, label)
    return if value.is_a?(String) && !value.strip.empty?

    raise AppleScreenshotReleaseSetValidationError, "#{label} must be nonempty"
  end

  def strict_utc_time!(value, label)
    unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      raise AppleScreenshotReleaseSetValidationError,
            "#{label} must be a whole-second UTC timestamp ending in Z"
    end
    parsed = Time.iso8601(value)
    unless parsed.utc? && parsed.iso8601 == value
      raise AppleScreenshotReleaseSetValidationError, "#{label} is not canonical UTC"
    end
    parsed
  rescue ArgumentError => error
    raise AppleScreenshotReleaseSetValidationError, "#{label} is invalid: #{error.message}"
  end

  def require_equal!(actual, expected, label)
    return if strictly_equal?(actual, expected)

    raise AppleScreenshotReleaseSetValidationError,
          "#{label} mismatch: expected #{expected.inspect}, found #{actual.inspect}"
  end

  def strictly_equal?(actual, expected)
    if actual.is_a?(Hash) || expected.is_a?(Hash)
      return false unless actual.is_a?(Hash) && expected.is_a?(Hash)
      return false unless actual.keys.length == expected.keys.length

      return expected.all? do |key, expected_value|
        actual.key?(key) && strictly_equal?(actual.fetch(key), expected_value)
      end
    end
    if actual.is_a?(Array) || expected.is_a?(Array)
      return false unless actual.is_a?(Array) && expected.is_a?(Array)
      return false unless actual.length == expected.length

      return actual.zip(expected).all? { |left, right| strictly_equal?(left, right) }
    end
    actual.class == expected.class && actual == expected
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    require_release_ready = false
    expected_source_commit = nil
    release_evidence_root = nil
    ARGV.each do |argument|
      case argument
      when "--require-release-ready"
        require_release_ready = true
      when /\A--expected-source-commit=([0-9a-f]{40})\z/
        expected_source_commit = Regexp.last_match(1)
      when /\A--release-evidence-root=(.+)\z/
        release_evidence_root = Regexp.last_match(1)
      else
        warn "Usage: #{$PROGRAM_NAME} [--require-release-ready --expected-source-commit=<40-character-sha>] " \
             "[--release-evidence-root=<absolute-existing-directory>]"
        exit 64
      end
    end
    root = Pathname.new(__dir__).join("../..").realpath
    result = AppleScreenshotReleaseSetValidator.new(
      root: root,
      release_evidence_root: release_evidence_root,
    ).validate!(
      require_release_ready: require_release_ready,
      expected_source_commit: expected_source_commit,
    )
    if result == :pending
      puts "Historical Apple screenshot evidence is locked; final 26-frame build-10 release set is pending."
    elsif result == :active_unapproved
      puts "Complete source-addressed 26-frame Apple screenshot set validated; named signed approval is pending."
    else
      puts "Release-ready source-addressed 26-frame Apple screenshot set and signed approval validated."
    end
  rescue AppleScreenshotReleaseSetValidationError, SystemCallError => error
    warn "Apple screenshot release-set validation failed: #{error.message}"
    exit 65
  end
end
