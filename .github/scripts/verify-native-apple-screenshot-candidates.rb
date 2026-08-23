#!/usr/bin/env ruby
# frozen_string_literal: true

# Fail-closed integrity validation for the preserved, explicitly unapproved
# tvOS, watchOS, and visionOS Debug Simulator candidates captured by GitHub
# Actions run 32347549322. These historical files are permanently ineligible
# for upload. Current-source eligibility is separately enforced by
# verify-apple-screenshot-release-set.rb.

require "digest"
require "json"
require "open3"
require "pathname"
require "set"
require "time"
require_relative "../../ios/ScreenshotAutomation/platform-screenshot-plan"

class NativeAppleScreenshotCandidateValidationError < StandardError; end

class NativeAppleDuplicateRejectingHash < Hash
  def []=(key, value)
    if key?(key)
      raise NativeAppleScreenshotCandidateValidationError,
            "duplicate JSON object key is forbidden: #{key.inspect}"
    end

    super
  end
end

class NativeAppleScreenshotInspector
  def inspect(path)
    output, status = Open3.capture2e(
      "sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", "-g", "hasAlpha",
      path.to_s,
    )
    unless status.success?
      raise NativeAppleScreenshotCandidateValidationError,
            "could not inspect native screenshot #{path}: #{output.strip}"
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
    raise NativeAppleScreenshotCandidateValidationError,
          "could not read native screenshot properties for #{path}: #{error.message}"
  end
end

class NativeAppleScreenshotSourceGuard
  # These paths contain the UI, shared runtime behavior, resources, product
  # settings, and delivery graph that produced the three native app targets.
  # Evidence and validator documentation may be added after capture; product
  # source may not drift without a new source-frozen capture.
  PRODUCT_SOURCE_PATHS = %w[
    ios/QuakeSignal
    ios/QuakeSignalShared
    ios/QuakeSignalTV
    ios/QuakeSignalVision
    ios/QuakeSignalWatch
    ios/project.yml
    ios/QuakeSignal.xcodeproj/project.pbxproj
    ios/QuakeSignal.xcodeproj/project.xcworkspace/contents.xcworkspacedata
    ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignal.xcscheme
    ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalTV.xcscheme
    ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalVision.xcscheme
    ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalWatch.xcscheme
  ].freeze

  def initialize(root)
    @root = Pathname.new(root).realpath
  end

  def validate!(source_commit)
    top_level, = run_git!("rev-parse", "--show-toplevel", failure: "repository root is unavailable")
    unless Pathname.new(top_level.strip).realpath == @root
      raise NativeAppleScreenshotCandidateValidationError,
            "native screenshot validator must run against the repository top level"
    end

    run_git!(
      "cat-file", "-e", "#{source_commit}^{commit}",
      failure: "native screenshot source commit is unavailable",
    )
    run_git!(
      "merge-base", "--is-ancestor", source_commit, "HEAD",
      failure: "native screenshot source commit is not an ancestor of HEAD",
    )

    debug_local_override = @root.join("ios/QuakeSignal/Supporting/Debug.local.xcconfig")
    if debug_local_override.exist? || debug_local_override.symlink?
      raise NativeAppleScreenshotCandidateValidationError,
            "ignored Debug.local.xcconfig is forbidden by the source-frozen screenshot contract"
    end

    _output, error_output, status = Open3.capture3(
      "git", "-C", @root.to_s, "diff", "--no-ext-diff", "--quiet", source_commit, "--",
      *PRODUCT_SOURCE_PATHS,
    )
    case status.exitstatus
    when 0
      # The tracked product source and working copy still equal the capture.
    when 1
      raise NativeAppleScreenshotCandidateValidationError,
            "native Apple app UI or product source changed after screenshot capture"
    else
      detail = error_output.strip
      suffix = detail.empty? ? "" : ": #{detail}"
      raise NativeAppleScreenshotCandidateValidationError,
            "could not compare native Apple app source to the capture commit#{suffix}"
    end

    untracked, = run_git!(
      "ls-files", "--others", "--exclude-standard", "--", *PRODUCT_SOURCE_PATHS,
      failure: "could not inspect untracked native Apple app source",
    )
    ignored, = run_git!(
      "ls-files", "--others", "--ignored", "--exclude-standard", "--",
      *PRODUCT_SOURCE_PATHS,
      failure: "could not inspect ignored native Apple app source",
    )
    paths = (untracked.lines + ignored.lines).map(&:strip).reject(&:empty?).uniq.sort
    return if paths.empty?

    raise NativeAppleScreenshotCandidateValidationError,
          "untracked native Apple app source exists after screenshot capture " \
          "(including ignored paths): #{paths.join(', ')}"
  rescue Errno::ENOENT => error
    raise NativeAppleScreenshotCandidateValidationError,
          "git source validation is unavailable: #{error.message}"
  end

  private

  def run_git!(*arguments, failure:)
    output, error_output, status = Open3.capture3("git", "-C", @root.to_s, *arguments)
    return [output, error_output] if status.success?

    detail = error_output.strip
    detail = output.strip if detail.empty?
    suffix = detail.empty? ? "" : ": #{detail}"
    raise NativeAppleScreenshotCandidateValidationError, "#{failure}#{suffix}"
  end
end

class NativeAppleScreenshotHistoricalCommitGuard
  def initialize(root)
    @root = Pathname.new(root).realpath
  end

  def validate!(source_commit)
    top_level, = run_git!("rev-parse", "--show-toplevel", failure: "repository root is unavailable")
    unless Pathname.new(top_level.strip).realpath == @root
      raise NativeAppleScreenshotCandidateValidationError,
            "historical screenshot validator must run against the repository top level"
    end
    run_git!(
      "cat-file", "-e", "#{source_commit}^{commit}",
      failure: "historical screenshot source commit is unavailable",
    )
    run_git!(
      "merge-base", "--is-ancestor", source_commit, "HEAD",
      failure: "historical screenshot source commit is not an ancestor of HEAD",
    )
    true
  end

  private

  def run_git!(*arguments, failure:)
    output, error_output, status = Open3.capture3("git", "-C", @root.to_s, *arguments)
    return [output, error_output] if status.success?

    detail = error_output.strip
    detail = output.strip if detail.empty?
    suffix = detail.empty? ? "" : ": #{detail}"
    raise NativeAppleScreenshotCandidateValidationError, "#{failure}#{suffix}"
  end
end

class NativeAppleScreenshotCandidateValidator
  CANDIDATE_ROOT = "ios/AppStore/platforms/screenshot-candidates-v1.1-build8"
  README_NAME = "README.md"
  README_SHA256 = "8b80ede571fe71ac30845eb9724231b36103dcde031afbd6c75b2d956d1be6cc"
  RECEIPT_NAME = "capture-run-receipt.json"
  SOURCE_COMMIT = "b461083bb5bff21eb4f1f4a8b5ef8f0764d89dd2"
  WORKFLOW_RUN_ID = 32_347_549_322
  WORKFLOW_RUN_URL = "https://github.com/TastyHeadphones/QuakeSignal/actions/runs/#{WORKFLOW_RUN_ID}"
  APPROVAL_REQUIRED =
    "Named visual review and runbook-required signed Release parity comparison"
  CONTENT_MANIFEST_ALGORITHM =
    "sha256 of sorted UTF-8 records: <file-sha256><two spaces><relative-path><newline>"
  XCODE_VERSION = "Xcode 26.6 Build version 17F113 "
  PLATFORMS = %w[tvos watchos visionos].freeze
  HISTORICAL_PLAN_EXPECTED = QuakeSignalPlatformScreenshotPlan::HISTORICAL_BUILD8_EXPECTED

  PLAN_SHA256 = {
    "tvos" => "996df610ad57ba0b83fe4aa9a16a15b9e8ed94267ae2bb9f63837b4d4ecf9647",
    "watchos" => "ec918e620780442f4085beb8891a4c2ad09f0289109238101d30e815ba28501d",
    "visionos" => "e521ab9ed5fb82265e8913489d9dcaf4a251fe080e75ce2ed75c5ffaaa69c32b",
  }.freeze

  EXPECTED_SIMULATORS = {
    "tvos" => {
      "runtimeIdentifier" => "com.apple.CoreSimulator.SimRuntime.tvOS-26-5",
      "deviceTypeIdentifier" =>
        "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p",
      "deviceModel" => "Apple TV 4K (3rd generation) (at 1080p)",
    },
    "watchos" => {
      "runtimeIdentifier" => "com.apple.CoreSimulator.SimRuntime.watchOS-26-5",
      "deviceTypeIdentifier" =>
        "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-2-49mm",
      "deviceModel" => "Apple Watch Ultra 2 (49mm)",
    },
    "visionos" => {
      "runtimeIdentifier" => "com.apple.CoreSimulator.SimRuntime.xrOS-26-5",
      "deviceTypeIdentifier" =>
        "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K",
      "deviceModel" => "Apple Vision Pro",
    },
  }.freeze

  ARTIFACTS = {
    "tvos" => {
      "platform" => "tvos",
      "directory" => "UNAPPROVED-debug-simulator-tvos-#{SOURCE_COMMIT}",
      "artifactId" => 9_398_937_649,
      "archiveDigest" =>
        "sha256:a5604a94bf359334a5d825a05b6408d496e7263f22c1471c0f256b53760966a9",
      "archiveSizeInBytes" => 4_585_918,
      "extractedSizeInBytes" => 4_605_389,
      "fileCount" => 9,
      "contentManifestSha256" =>
        "a8b866dcf92b298d5fe20f9c5d8beaedd3644f9fc45a18a02e22f0159476b1b2",
      "createdAtUtc" => "2026-08-20T08:22:52Z",
      "remoteExpiresAtUtc" => "2026-08-27T08:22:50Z",
    },
    "watchos" => {
      "platform" => "watchos",
      "directory" => "UNAPPROVED-debug-simulator-watchos-#{SOURCE_COMMIT}",
      "artifactId" => 9_399_327_711,
      "archiveDigest" =>
        "sha256:1386f53354886351968bea4f3241d7990139451805ba8e58b1f6cbb17891b94c",
      "archiveSizeInBytes" => 109_069,
      "extractedSizeInBytes" => 118_202,
      "fileCount" => 9,
      "contentManifestSha256" =>
        "f54c54be54c060571f6bba2056b699a1f258f570b4551ceb9a4d5e5dbf47c971",
      "createdAtUtc" => "2026-08-20T08:35:52Z",
      "remoteExpiresAtUtc" => "2026-08-27T08:35:50Z",
    },
    "visionos" => {
      "platform" => "visionos",
      "directory" => "UNAPPROVED-debug-simulator-visionos-#{SOURCE_COMMIT}",
      "artifactId" => 9_399_957_564,
      "archiveDigest" =>
        "sha256:f465d28edb0bb5a7f297c2f5d053869b2de31f2ac012826c6607c9b0bbe4b9a8",
      "archiveSizeInBytes" => 27_182_959,
      "extractedSizeInBytes" => 27_213_097,
      "fileCount" => 13,
      "contentManifestSha256" =>
        "fa8a048581756a6aeeb4a5dd1f228c73b7887fcb8beb2079fbb04629555ca340",
      "createdAtUtc" => "2026-08-20T08:56:53Z",
      "remoteExpiresAtUtc" => "2026-08-27T08:56:49Z",
    },
  }.freeze

  RECEIPT_KEYS = %w[
    archivePreservation artifacts contentManifestAlgorithm releaseBinaryEvidence reviewer schemaVersion
    repository sourceCommit status uploadApproved workflowFile workflowRun
  ].freeze
  RECEIPT_WORKFLOW_KEYS = %w[
    attempt completedAtUtc conclusion createdAtUtc event id url
  ].freeze
  ARCHIVE_PRESERVATION_KEYS = %w[
    archivesCheckedIntoRepository verification verifiedAtUtc
  ].freeze
  ARTIFACT_KEYS = %w[
    archiveDigest archiveSizeInBytes artifactId contentManifestSha256 createdAtUtc directory
    extractedSizeInBytes fileCount platform remoteExpiresAtUtc
  ].freeze
  METADATA_KEYS = %w[
    approvalRequired captureEvidenceFile captureEvidenceSha256 captureWindowUtc
    debugLocalOverridePresent fixture frames locale planManifest platform releaseBinaryEvidence
    reviewer schemaVersion sourceCommit status uploadApproved workflowRun xcodeVersion
  ].freeze
  METADATA_FRAME_KEYS = %w[
    captureEvidenceFile captureEvidenceSha256 captureSelector capturedAtUtc file pixels screen
    screenshotSha256 selectedSimulator
  ].freeze
  AGGREGATE_KEYS = %w[
    approvalRequired captureWindowUtc fixture frames locale planManifest platform releaseBinaryEvidence
    reviewer schemaVersion status uploadApproved
  ].freeze
  AGGREGATE_FRAME_KEYS = %w[
    captureEvidenceFile captureEvidenceSha256 captureSelector capturedAtUtc file pixels purpose
    screen selectedSimulator setup sha256
  ].freeze
  SIDECAR_KEYS = %w[
    captureSelector capturedAtUtc locale pixels plannedFile platform schemaVersion screenshotFile
    screenshotSha256 selectedSimulator status uploadApproved
  ].freeze
  SIMULATOR_KEYS = %w[deviceModel deviceTypeIdentifier runtimeIdentifier udid].freeze
  PLAN_RECORD_KEYS = %w[file sha256].freeze
  WINDOW_KEYS = %w[completedAt startedAt].freeze

  def initialize(root:, image_inspector: NativeAppleScreenshotInspector.new, verify_git: true)
    unless verify_git == true || verify_git == false
      raise NativeAppleScreenshotCandidateValidationError, "verify_git must be true or false"
    end

    requested_root = Pathname.new(root).expand_path
    if requested_root.symlink?
      raise NativeAppleScreenshotCandidateValidationError,
            "repository root must not be a symlink: #{requested_root}"
    end
    @root = requested_root.realpath
    @image_inspector = image_inspector
    @verify_git = verify_git
    @candidate_root = @root.join(CANDIDATE_ROOT)
  rescue Errno::ENOENT => error
    raise NativeAppleScreenshotCandidateValidationError,
          "repository root is unavailable: #{error.message}"
  end

  def validate!
    # Historical integrity and current-source eligibility are deliberately
    # distinct. The full NativeAppleScreenshotSourceGuard remains unchanged and
    # mandatory for an active release set; this old package only proves that its
    # recorded commit exists and that every preserved byte still matches.
    NativeAppleScreenshotHistoricalCommitGuard.new(@root).validate!(SOURCE_COMMIT) if @verify_git
    ensure_candidate_ancestors!
    validate_root_inventory!

    receipt = parse_json_object!(@candidate_root.join(RECEIPT_NAME))
    artifacts = validate_receipt!(receipt)
    plans = load_plans!
    PLATFORMS.each do |platform|
      validate_package!(platform, artifacts.fetch(platform), plans.fetch(platform))
    end
    :validated
  rescue QuakeSignalPlatformScreenshotPlan::Error => error
    raise NativeAppleScreenshotCandidateValidationError,
          "invalid immutable native screenshot plan: #{error.message}"
  rescue Errno::ENOENT, Errno::ENOTDIR => error
    raise NativeAppleScreenshotCandidateValidationError,
          "native screenshot candidate evidence is missing or changed: #{error.message}"
  end

  private

  def ensure_candidate_ancestors!
    paths = [
      @root.join("ios"),
      @root.join("ios/AppStore"),
      @root.join("ios/AppStore/platforms"),
      @candidate_root,
    ]
    paths.each { |path| ensure_plain_directory!(path, path.relative_path_from(@root).to_s) }
  end

  def ensure_plain_directory!(path, label)
    stat = path.lstat
    unless stat.directory? && !path.symlink?
      raise NativeAppleScreenshotCandidateValidationError,
            "#{label} must be a plain directory, not a symlink or special entry"
    end
  rescue Errno::ENOENT
    raise NativeAppleScreenshotCandidateValidationError, "#{label} directory is missing"
  end

  def validate_root_inventory!
    expected = [README_NAME, RECEIPT_NAME] +
      PLATFORMS.map { |platform| ARTIFACTS.fetch(platform).fetch("directory") }
    actual = @candidate_root.children.map do |entry|
      stat = entry.lstat
      name = entry.basename.to_s
      expected_type = [README_NAME, RECEIPT_NAME].include?(name) ? :file : :directory
      valid = (expected_type == :file && stat.file?) || (expected_type == :directory && stat.directory?)
      unless valid && !entry.symlink?
        raise NativeAppleScreenshotCandidateValidationError,
              "candidate root entry #{name.inspect} has an invalid type or is a symlink"
      end
      name
    end.sort
    require_equal(actual, expected.sort, "candidate root inventory")
    require_equal(
      Digest::SHA256.file(@candidate_root.join(README_NAME)).hexdigest,
      README_SHA256,
      "candidate root README SHA-256",
    )
  end

  def validate_receipt!(receipt)
    require_keys(receipt, RECEIPT_KEYS, "capture-run receipt")
    require_equal(receipt.fetch("schemaVersion"), 1, "receipt schemaVersion")
    require_equal(
      receipt.fetch("status"),
      "unapproved-debug-simulator-candidate-run-receipt",
      "receipt status",
    )
    require_equal(receipt.fetch("uploadApproved"), false, "receipt uploadApproved")
    require_equal(receipt.fetch("releaseBinaryEvidence"), nil, "receipt releaseBinaryEvidence")
    require_equal(receipt.fetch("reviewer"), nil, "receipt reviewer")
    require_equal(receipt.fetch("repository"), "TastyHeadphones/QuakeSignal", "receipt repository")
    require_equal(
      receipt.fetch("workflowFile"), ".github/workflows/apple-platform-screenshots.yml",
      "receipt workflowFile",
    )
    require_equal(receipt.fetch("sourceCommit"), SOURCE_COMMIT, "receipt sourceCommit")
    require_equal(
      receipt.fetch("contentManifestAlgorithm"), CONTENT_MANIFEST_ALGORITHM,
      "receipt contentManifestAlgorithm",
    )

    workflow = receipt.fetch("workflowRun")
    require_keys(workflow, RECEIPT_WORKFLOW_KEYS, "receipt workflowRun")
    require_equal(workflow.fetch("id"), WORKFLOW_RUN_ID, "receipt workflowRun.id")
    require_equal(workflow.fetch("attempt"), 1, "receipt workflowRun.attempt")
    require_equal(workflow.fetch("url"), WORKFLOW_RUN_URL, "receipt workflowRun.url")
    require_equal(workflow.fetch("event"), "workflow_dispatch", "receipt workflowRun.event")
    require_equal(workflow.fetch("conclusion"), "success", "receipt workflowRun.conclusion")
    run_created = strict_utc_time(
      workflow.fetch("createdAtUtc"), "receipt workflowRun.createdAtUtc"
    )
    require_equal(
      workflow.fetch("createdAtUtc"), "2026-08-20T08:11:05Z",
      "receipt workflowRun.createdAtUtc",
    )
    run_completed = strict_utc_time(
      workflow.fetch("completedAtUtc"), "receipt workflowRun.completedAtUtc"
    )
    require_equal(
      workflow.fetch("completedAtUtc"), "2026-08-20T08:57:00Z",
      "receipt workflowRun.completedAtUtc",
    )
    unless run_completed > run_created
      raise NativeAppleScreenshotCandidateValidationError,
            "receipt workflow completion must be after workflow creation"
    end

    preservation = receipt.fetch("archivePreservation")
    require_keys(preservation, ARCHIVE_PRESERVATION_KEYS, "receipt archivePreservation")
    strict_utc_time(
      preservation.fetch("verifiedAtUtc"), "receipt archivePreservation.verifiedAtUtc"
    )
    require_equal(
      preservation.fetch("verifiedAtUtc"), "2026-08-20T09:11:25Z",
      "receipt archivePreservation.verifiedAtUtc",
    )
    require_equal(
      preservation.fetch("verification"),
      "Each downloaded ZIP SHA-256 matched the GitHub artifact digest and unzip integrity testing passed",
      "receipt archivePreservation.verification",
    )
    require_equal(
      preservation.fetch("archivesCheckedIntoRepository"), false,
      "receipt archivePreservation.archivesCheckedIntoRepository",
    )

    artifacts = receipt.fetch("artifacts")
    unless artifacts.is_a?(Array)
      raise NativeAppleScreenshotCandidateValidationError, "receipt artifacts must be an array"
    end
    require_equal(artifacts.length, 3, "receipt artifacts.length")
    unless artifacts.all? { |artifact| artifact.is_a?(Hash) }
      raise NativeAppleScreenshotCandidateValidationError,
            "every receipt artifact must be an object"
    end
    require_equal(artifacts.map { |artifact| artifact.fetch("platform") }, PLATFORMS, "receipt artifact order")

    artifacts.each_with_object({}) do |artifact, by_platform|
      require_keys(artifact, ARTIFACT_KEYS, "receipt artifact")
      platform = artifact.fetch("platform")
      expected = ARTIFACTS.fetch(platform) do
        raise NativeAppleScreenshotCandidateValidationError,
              "receipt contains unsupported artifact platform #{platform.inspect}"
      end
      expected.each do |key, expected_value|
        require_equal(artifact.fetch(key), expected_value, "receipt #{platform} #{key}")
      end
      require_prefixed_sha256(artifact.fetch("archiveDigest"), "receipt #{platform} archiveDigest")
      require_sha256(
        artifact.fetch("contentManifestSha256"),
        "receipt #{platform} contentManifestSha256",
      )
      created = strict_utc_time(artifact.fetch("createdAtUtc"), "receipt #{platform} createdAtUtc")
      expires = strict_utc_time(
        artifact.fetch("remoteExpiresAtUtc"),
        "receipt #{platform} remoteExpiresAtUtc",
      )
      unless expires > created
        raise NativeAppleScreenshotCandidateValidationError,
              "receipt #{platform} remote expiration must be after artifact creation"
      end
      unless created >= run_created && created <= run_completed
        raise NativeAppleScreenshotCandidateValidationError,
              "receipt #{platform} artifact creation must fall within the workflow run"
      end
      by_platform[platform] = artifact
    end
  rescue KeyError, TypeError => error
    raise NativeAppleScreenshotCandidateValidationError,
          "invalid capture-run receipt: #{error.message}"
  end

  def load_plans!
    PLATFORMS.each_with_object({}) do |platform, plans|
      manifest_path = @root.join(
        HISTORICAL_PLAN_EXPECTED.fetch(platform).fetch(:manifest),
      )
      ensure_plain_directory!(
        manifest_path.dirname,
        "#{platform} screenshot plan directory",
      )
      manifest_stat = manifest_path.lstat
      unless manifest_stat.file? && !manifest_path.symlink?
        raise NativeAppleScreenshotCandidateValidationError,
              "#{platform} screenshot plan manifest must be a plain file, not a symlink"
      end
      plan = QuakeSignalPlatformScreenshotPlan.load(
        platform,
        repository_root: @root,
        expected_plans: HISTORICAL_PLAN_EXPECTED,
      )
      require_equal(plan.fetch("schemaVersion"), 1, "#{platform} normalized plan schemaVersion")
      require_equal(plan.fetch("platform"), platform, "#{platform} normalized plan platform")
      require_equal(plan.fetch("locale"), "en-US", "#{platform} normalized plan locale")
      require_equal(
        plan.fetch("manifestSha256"),
        PLAN_SHA256.fetch(platform),
        "#{platform} immutable plan SHA-256",
      )
      plans[platform] = plan
    end
  end

  def validate_package!(platform, artifact, plan)
    package_root = @candidate_root.join(artifact.fetch("directory"))
    ensure_plain_directory!(package_root, "#{platform} candidate package")
    directories, files = tree_inventory!(package_root)
    plan_frames = plan.fetch("frames")
    expected_files = ["candidate-metadata.json", "capture-provenance.json", "simulator-runtimes.txt"]
    expected_files.concat(plan_frames.map { |frame| frame.fetch("file") })
    expected_files.concat(
      plan_frames.map do |frame|
        "frame-capture-evidence/#{frame.fetch('captureSelector')}.json"
      end,
    )
    require_equal(directories, %w[en-US frame-capture-evidence], "#{platform} package directories")
    require_equal(files, expected_files.sort, "#{platform} package files")
    require_equal(files.length, artifact.fetch("fileCount"), "#{platform} package fileCount")

    metadata_path = package_root.join("candidate-metadata.json")
    aggregate_path = package_root.join("capture-provenance.json")
    metadata = parse_json_object!(metadata_path)
    aggregate = parse_json_object!(aggregate_path)
    validate_metadata_header!(platform, metadata, plan)
    validate_aggregate_header!(platform, aggregate, plan)
    require_equal(
      metadata.fetch("captureEvidenceSha256"),
      Digest::SHA256.file(aggregate_path).hexdigest,
      "#{platform} metadata-to-aggregate SHA-256",
    )

    normalized_metadata_frames = validate_frames!(platform, package_root, plan_frames, aggregate)
    validate_capture_windows!(platform, metadata, aggregate, normalized_metadata_frames)
    require_equal(metadata.fetch("frames"), normalized_metadata_frames, "#{platform} metadata frames")
    validate_runtime_inventory!(platform, package_root.join("simulator-runtimes.txt"), normalized_metadata_frames)

    extracted_size = files.sum { |relative| package_root.join(relative).size }
    require_equal(
      extracted_size, artifact.fetch("extractedSizeInBytes"),
      "#{platform} package extracted size",
    )
    manifest = files.map do |relative|
      "#{Digest::SHA256.file(package_root.join(relative)).hexdigest}  #{relative}\n"
    end.join
    require_equal(
      Digest::SHA256.hexdigest(manifest),
      artifact.fetch("contentManifestSha256"),
      "#{platform} package content-manifest SHA-256",
    )
  rescue KeyError, TypeError => error
    raise NativeAppleScreenshotCandidateValidationError,
          "invalid #{platform} candidate package: #{error.message}"
  end

  def validate_metadata_header!(platform, metadata, plan)
    require_keys(metadata, METADATA_KEYS, "#{platform} candidate metadata")
    require_equal(metadata.fetch("schemaVersion"), 3, "#{platform} metadata schemaVersion")
    require_equal(
      metadata.fetch("status"),
      "unapproved-debug-simulator-candidate",
      "#{platform} metadata status",
    )
    require_equal(metadata.fetch("uploadApproved"), false, "#{platform} metadata uploadApproved")
    require_equal(
      metadata.fetch("releaseBinaryEvidence"), nil, "#{platform} metadata releaseBinaryEvidence"
    )
    require_equal(metadata.fetch("reviewer"), nil, "#{platform} metadata reviewer")
    require_equal(
      metadata.fetch("debugLocalOverridePresent"), false,
      "#{platform} metadata debugLocalOverridePresent",
    )
    require_equal(metadata.fetch("sourceCommit"), SOURCE_COMMIT, "#{platform} metadata sourceCommit")
    require_equal(metadata.fetch("platform"), platform, "#{platform} metadata platform")
    require_equal(metadata.fetch("locale"), "en-US", "#{platform} metadata locale")
    require_equal(
      metadata.fetch("fixture"), "finalized-historical-reports", "#{platform} metadata fixture"
    )
    validate_plan_record!(platform, metadata.fetch("planManifest"), plan, "metadata")
    require_equal(
      metadata.fetch("captureEvidenceFile"), "capture-provenance.json",
      "#{platform} metadata captureEvidenceFile",
    )
    require_sha256(metadata.fetch("captureEvidenceSha256"), "#{platform} metadata captureEvidenceSha256")
    require_equal(metadata.fetch("xcodeVersion"), XCODE_VERSION, "#{platform} metadata xcodeVersion")
    require_equal(metadata.fetch("workflowRun"), WORKFLOW_RUN_URL, "#{platform} metadata workflowRun")
    require_equal(
      metadata.fetch("approvalRequired"), APPROVAL_REQUIRED, "#{platform} metadata approvalRequired"
    )
    unless metadata.fetch("frames").is_a?(Array)
      raise NativeAppleScreenshotCandidateValidationError, "#{platform} metadata frames must be an array"
    end
    metadata.fetch("frames").each_with_index do |frame, index|
      require_keys(frame, METADATA_FRAME_KEYS, "#{platform} metadata frames[#{index}]")
    end
  end

  def validate_aggregate_header!(platform, aggregate, plan)
    require_keys(aggregate, AGGREGATE_KEYS, "#{platform} aggregate provenance")
    require_equal(aggregate.fetch("schemaVersion"), 2, "#{platform} aggregate schemaVersion")
    require_equal(
      aggregate.fetch("status"),
      "unapproved-debug-simulator-capture-set-evidence",
      "#{platform} aggregate status",
    )
    require_equal(aggregate.fetch("uploadApproved"), false, "#{platform} aggregate uploadApproved")
    require_equal(
      aggregate.fetch("releaseBinaryEvidence"), nil,
      "#{platform} aggregate releaseBinaryEvidence",
    )
    require_equal(aggregate.fetch("reviewer"), nil, "#{platform} aggregate reviewer")
    require_equal(aggregate.fetch("platform"), platform, "#{platform} aggregate platform")
    require_equal(aggregate.fetch("locale"), "en-US", "#{platform} aggregate locale")
    require_equal(
      aggregate.fetch("fixture"), "finalized-historical-reports", "#{platform} aggregate fixture"
    )
    validate_plan_record!(platform, aggregate.fetch("planManifest"), plan, "aggregate")
    require_equal(
      aggregate.fetch("approvalRequired"), APPROVAL_REQUIRED,
      "#{platform} aggregate approvalRequired",
    )
  end

  def validate_plan_record!(platform, record, plan, layer)
    require_keys(record, PLAN_RECORD_KEYS, "#{platform} #{layer} planManifest")
    require_equal(record.fetch("file"), plan.fetch("manifestFile"), "#{platform} #{layer} plan file")
    require_equal(record.fetch("sha256"), plan.fetch("manifestSha256"), "#{platform} #{layer} plan SHA-256")
  end

  def validate_frames!(platform, package_root, plan_frames, aggregate)
    frames = aggregate.fetch("frames")
    unless frames.is_a?(Array)
      raise NativeAppleScreenshotCandidateValidationError, "#{platform} aggregate frames must be an array"
    end
    require_equal(frames.length, plan_frames.length, "#{platform} aggregate frame count")

    udids = Set.new
    plan_frames.each_with_index.map do |planned, index|
      frame = frames.fetch(index)
      label = "#{platform} aggregate frames[#{index}]"
      require_keys(frame, AGGREGATE_FRAME_KEYS, label)
      require_equal(frame.fetch("captureSelector"), planned.fetch("captureSelector"), "#{label} selector")
      require_equal(frame.fetch("file"), planned.fetch("file"), "#{label} file")
      require_equal(frame.fetch("screen"), planned.fetch("screen"), "#{label} screen")
      require_equal(frame.fetch("purpose"), planned.fetch("purpose"), "#{label} purpose")
      require_equal(frame.fetch("setup"), planned.fetch("setup"), "#{label} setup")
      require_equal(frame.fetch("pixels"), planned.fetch("pixels"), "#{label} pixels")
      captured_at = strict_utc_time(frame.fetch("capturedAtUtc"), "#{label} capturedAtUtc").iso8601
      simulator = validate_simulator!(platform, frame.fetch("selectedSimulator"), label)
      unless udids.add?(simulator.fetch("udid"))
        raise NativeAppleScreenshotCandidateValidationError,
              "#{platform} disposable simulator UDIDs must be unique per frame"
      end

      evidence_relative = "frame-capture-evidence/#{planned.fetch('captureSelector')}.json"
      require_equal(frame.fetch("captureEvidenceFile"), evidence_relative, "#{label} evidence file")
      require_sha256(frame.fetch("captureEvidenceSha256"), "#{label} evidence SHA-256")
      evidence_path = package_root.join(evidence_relative)
      evidence_source = evidence_path.read
      sidecar = parse_json_source!(evidence_source, evidence_relative)
      require_equal(
        frame.fetch("captureEvidenceSha256"), Digest::SHA256.hexdigest(evidence_source),
        "#{label} aggregate-to-sidecar SHA-256",
      )
      validate_sidecar!(platform, sidecar, planned, frame, simulator, captured_at)

      screenshot_path = package_root.join(planned.fetch("file"))
      screenshot_sha256 = Digest::SHA256.file(screenshot_path).hexdigest
      require_sha256(frame.fetch("sha256"), "#{label} screenshot SHA-256")
      require_equal(frame.fetch("sha256"), screenshot_sha256, "#{label} aggregate-to-PNG SHA-256")
      inspect_png!(platform, screenshot_path, planned.fetch("pixels"))

      {
        "captureSelector" => planned.fetch("captureSelector"),
        "file" => planned.fetch("file"),
        "screen" => planned.fetch("screen"),
        "screenshotSha256" => screenshot_sha256,
        "pixels" => planned.fetch("pixels"),
        "capturedAtUtc" => captured_at,
        "selectedSimulator" => simulator,
        "captureEvidenceFile" => evidence_relative,
        "captureEvidenceSha256" => frame.fetch("captureEvidenceSha256"),
      }
    end
  end

  def validate_sidecar!(platform, sidecar, planned, aggregate_frame, simulator, captured_at)
    label = "#{platform} #{planned.fetch('captureSelector')} sidecar"
    require_keys(sidecar, SIDECAR_KEYS, label)
    require_equal(sidecar.fetch("schemaVersion"), 1, "#{label} schemaVersion")
    require_equal(
      sidecar.fetch("status"),
      "unapproved-debug-simulator-capture-evidence",
      "#{label} status",
    )
    require_equal(sidecar.fetch("uploadApproved"), false, "#{label} uploadApproved")
    require_equal(sidecar.fetch("platform"), platform, "#{label} platform")
    require_equal(sidecar.fetch("locale"), "en", "#{label} locale")
    require_equal(
      sidecar.fetch("captureSelector"), planned.fetch("captureSelector"), "#{label} selector"
    )
    require_equal(sidecar.fetch("plannedFile"), planned.fetch("file"), "#{label} plannedFile")
    require_equal(
      sidecar.fetch("screenshotFile"), File.basename(planned.fetch("file")),
      "#{label} screenshotFile",
    )
    require_sha256(sidecar.fetch("screenshotSha256"), "#{label} screenshotSha256")
    require_equal(
      sidecar.fetch("screenshotSha256"), aggregate_frame.fetch("sha256"),
      "#{label} sidecar-to-aggregate PNG SHA-256",
    )
    require_equal(sidecar.fetch("pixels"), planned.fetch("pixels"), "#{label} pixels")
    sidecar_time = strict_utc_time(sidecar.fetch("capturedAtUtc"), "#{label} capturedAtUtc").iso8601
    require_equal(sidecar_time, captured_at, "#{label} capturedAtUtc")
    sidecar_simulator = validate_simulator!(platform, sidecar.fetch("selectedSimulator"), label)
    require_equal(sidecar_simulator, simulator, "#{label} selectedSimulator")
  end

  def validate_simulator!(platform, simulator, label)
    require_keys(simulator, SIMULATOR_KEYS, "#{label} selectedSimulator")
    expected = EXPECTED_SIMULATORS.fetch(platform)
    expected.each do |key, value|
      require_equal(simulator.fetch(key), value, "#{label} selectedSimulator.#{key}")
    end
    udid = simulator.fetch("udid")
    unless udid.is_a?(String) && udid.match?(/\A[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\z/)
      raise NativeAppleScreenshotCandidateValidationError,
            "#{label} selectedSimulator.udid must be an uppercase UUID"
    end
    simulator
  end

  def validate_capture_windows!(platform, metadata, aggregate, normalized_frames)
    metadata_window = metadata.fetch("captureWindowUtc")
    aggregate_window = aggregate.fetch("captureWindowUtc")
    require_keys(metadata_window, WINDOW_KEYS, "#{platform} metadata captureWindowUtc")
    require_keys(aggregate_window, WINDOW_KEYS, "#{platform} aggregate captureWindowUtc")
    require_equal(metadata_window, aggregate_window, "#{platform} metadata-to-aggregate capture window")

    times = normalized_frames.map do |frame|
      strict_utc_time(frame.fetch("capturedAtUtc"), "#{platform} frame capturedAtUtc")
    end
    unless times.each_cons(2).all? { |left, right| left < right }
      raise NativeAppleScreenshotCandidateValidationError,
            "#{platform} frame capture timestamps must be strictly increasing"
    end
    started = strict_utc_time(aggregate_window.fetch("startedAt"), "#{platform} capture startedAt")
    completed = strict_utc_time(
      aggregate_window.fetch("completedAt"), "#{platform} capture completedAt"
    )
    require_equal(started, times.min, "#{platform} capture window start")
    require_equal(completed, times.max, "#{platform} capture window completion")
  end

  def validate_runtime_inventory!(platform, path, frames)
    source = path.read
    unless source.start_with?("== Runtimes ==\n") && source.end_with?("\n")
      raise NativeAppleScreenshotCandidateValidationError,
            "#{platform} simulator runtime inventory has an invalid format"
    end
    runtime_identifiers = frames.map do |frame|
      frame.fetch("selectedSimulator").fetch("runtimeIdentifier")
    end.uniq
    runtime_identifiers.each do |identifier|
      unless source.lines.any? { |line| line.end_with?(" - #{identifier}\n") }
        raise NativeAppleScreenshotCandidateValidationError,
              "#{platform} selected simulator runtime is absent from runtime inventory: #{identifier}"
      end
    end
  end

  def inspect_png!(platform, path, pixels)
    properties = @image_inspector.inspect(path)
    require_equal(properties.fetch(:format), "png", "#{platform} screenshot #{path.basename} format")
    require_equal(
      [properties.fetch(:width), properties.fetch(:height)], pixels,
      "#{platform} screenshot #{path.basename} dimensions",
    )
    require_equal(
      properties.fetch(:has_alpha), false, "#{platform} screenshot #{path.basename} opacity"
    )
  rescue KeyError => error
    raise NativeAppleScreenshotCandidateValidationError,
          "invalid image-inspection result for #{path}: #{error.message}"
  end

  def tree_inventory!(root)
    directories = []
    files = []
    visit = lambda do |directory|
      directory.children.sort_by(&:to_s).each do |entry|
        relative = entry.relative_path_from(root).to_s
        stat = entry.lstat
        if stat.directory? && !entry.symlink?
          directories << relative
          visit.call(entry)
        elsif stat.file? && !entry.symlink?
          files << relative
        else
          raise NativeAppleScreenshotCandidateValidationError,
                "#{root.basename} contains a symlink or non-regular entry: #{relative}"
        end
      end
    end
    visit.call(root)
    [directories.sort, files.sort]
  rescue Errno::ENOENT => error
    raise NativeAppleScreenshotCandidateValidationError,
          "candidate inventory changed while it was inspected: #{error.message}"
  end

  def parse_json_object!(path)
    parse_json_source!(path.read, path.to_s)
  end

  def parse_json_source!(source, label)
    value = JSON.parse(
      source,
      object_class: NativeAppleDuplicateRejectingHash,
      allow_duplicate_key: false,
    )
    unless value.is_a?(Hash)
      raise NativeAppleScreenshotCandidateValidationError,
            "JSON document must contain one object: #{label}"
    end
    value
  rescue JSON::ParserError => error
    raise NativeAppleScreenshotCandidateValidationError,
          "invalid JSON in #{label}: #{error.message}"
  end

  def require_keys(value, expected, label)
    unless value.is_a?(Hash)
      raise NativeAppleScreenshotCandidateValidationError, "#{label} must be an object"
    end
    require_equal(value.keys.sort, expected.sort, "#{label} keys")
  end

  def strict_utc_time(value, label)
    unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      raise NativeAppleScreenshotCandidateValidationError,
            "#{label} must be a whole-second UTC timestamp ending in Z"
    end
    parsed = Time.iso8601(value)
    unless parsed.utc? && parsed.iso8601 == value
      raise NativeAppleScreenshotCandidateValidationError, "#{label} is not canonical UTC"
    end
    parsed
  rescue ArgumentError => error
    raise NativeAppleScreenshotCandidateValidationError, "#{label} is invalid: #{error.message}"
  end

  def require_sha256(value, label)
    return if value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)

    raise NativeAppleScreenshotCandidateValidationError,
          "#{label} must be a lowercase SHA-256 digest"
  end

  def require_prefixed_sha256(value, label)
    return if value.is_a?(String) && value.match?(/\Asha256:[0-9a-f]{64}\z/)

    raise NativeAppleScreenshotCandidateValidationError,
          "#{label} must be a sha256:-prefixed lowercase digest"
  end

  def require_equal(actual, expected, label)
    return if strictly_equal?(actual, expected)

    raise NativeAppleScreenshotCandidateValidationError,
          "#{label} must be #{expected.inspect}; received #{actual.inspect}"
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
    unless ARGV.empty?
      warn "Usage: verify-native-apple-screenshot-candidates.rb"
      exit 64
    end
    repository_root = Pathname.new(__dir__).join("../..").realpath
    NativeAppleScreenshotCandidateValidator.new(
      root: repository_root,
      verify_git: true,
    ).validate!
    puts "Validated 3 historical unapproved native Apple screenshot packages " \
         "(11 opaque PNGs) from #{NativeAppleScreenshotCandidateValidator::SOURCE_COMMIT}."
  rescue NativeAppleScreenshotCandidateValidationError => error
    warn "error: #{error.message}"
    exit 65
  end
end
