#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fiddle/import"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "set"
require "tmpdir"
require "time"
require "zlib"
require_relative "verify-apple-screenshot-release-set" unless defined?(AppleScreenshotReleaseSetValidator)
require_relative "../../ios/ScreenshotAutomation/assemble-ios-screenshot-provenance"
require_relative "../../ios/ScreenshotAutomation/assemble-maccatalyst-screenshot-provenance"
require_relative "../../ios/ScreenshotAutomation/assemble-platform-screenshot-provenance"
require_relative "../../ios/ScreenshotAutomation/seal-screenshot-capture-package"

module QuakeSignalAppleScreenshotReleaseSetNativeFilesystem
  extend Fiddle::Importer

  dlload Fiddle.dlopen(nil)
  extern "int openat(int, const char *, int, unsigned int)"
  extern "int linkat(int, const char *, int, const char *, int)"
  extern "int renameat(int, const char *, int, const char *)"
  extern "int renameatx_np(int, const char *, int, const char *, unsigned int)"
  extern "int unlinkat(int, const char *, int)"
end

class AppleScreenshotReleaseSetAssemblyError < StandardError; end

class AppleScreenshotReleaseSetAssembler
  PRODUCT = AppleScreenshotReleaseSetValidator::PRODUCT
  PLATFORMS = AppleScreenshotReleaseSetValidator::REQUIRED_PLATFORMS.keys.freeze
  FRAME_SPECS = AppleScreenshotReleaseSetValidator::FRAME_SPECS
  PLAN_PATHS = AppleScreenshotReleaseSetValidator::PLAN_PATHS
  RELEASE_ROOT = AppleScreenshotReleaseSetValidator::RELEASE_ROOT
  INDEX_PATH = AppleScreenshotReleaseSetValidator::INDEX_PATH
  PACKAGE_ALGORITHM = AppleScreenshotReleaseSetValidator::PACKAGE_ALGORITHM
  AGGREGATE_STATUS = {
    "ios-ipados" => "unapproved-debug-ios-ipados-capture-set-evidence",
    "tvos" => "unapproved-debug-simulator-capture-set-evidence",
    "watchos" => "unapproved-debug-simulator-capture-set-evidence",
    "visionos" => "unapproved-debug-simulator-capture-set-evidence",
    "maccatalyst" => "unapproved-debug-maccatalyst-capture-set-evidence",
  }.freeze
  INDEPENDENT_EVIDENCE_REQUIREMENTS = {
    "ios-ipados" => [
      ["build-bindings/"],
      ["frame-capture-evidence/"],
      ["raw-simulator-captures/"],
      ["semantic-evidence/"],
      ["simulator-cleanup-evidence.json"],
    ],
    "tvos" => [["source-address.json"], ["frame-capture-evidence/"]],
    "watchos" => [["source-address.json"], ["frame-capture-evidence/"]],
    "visionos" => [["source-address.json"], ["frame-capture-evidence/"]],
    "maccatalyst" => [
      ["capture-request-evidence/"],
      ["frame-capture-evidence/"],
      ["native-capture-evidence/"],
      ["raw-window-captures/"],
      ["semantic-evidence/"],
      ["window-observations/"],
    ],
  }.freeze
  AGGREGATE_KEYS = {
    "ios-ipados" => %w[
      schemaVersion status uploadApproved reviewer approval releaseBinaryEvidence
      platform locale fixture source planManifest product app buildSource buildBinding
      captureEnvironment simulatorCleanupEvidence captureWindowUtc frames approvalRequired
    ],
    "tvos" => %w[
      schemaVersion status uploadApproved releaseBinaryEvidence reviewer platform locale
      fixture planManifest captureWindowUtc frames approvalRequired
    ],
    "watchos" => %w[
      schemaVersion status uploadApproved releaseBinaryEvidence reviewer platform locale
      fixture planManifest captureWindowUtc frames approvalRequired
    ],
    "visionos" => %w[
      schemaVersion status uploadApproved releaseBinaryEvidence reviewer platform locale
      fixture planManifest captureWindowUtc frames approvalRequired
    ],
    "maccatalyst" => %w[
      schemaVersion status uploadApproved reviewer approval releaseBinaryEvidence platform
      locale fixture source planManifest product host app captureEnvironment captureWindowUtc
      frames approvalRequired
    ],
  }.transform_values(&:freeze).freeze
  FRAME_KEYS = {
    "ios-ipados" => %w[
      captureSelector displayClass file screen purpose pixels format hasAlpha sha256 rawFile
      rawSha256 captureWindowUtc source product captureEnvironment app build buildSource
      buildBinding installEvidence launchEvidence semanticValidation transformation
      frameCaptureEvidenceFile frameCaptureEvidenceSha256 reviewer approval
    ],
    "tvos" => %w[
      captureSelector file screen purpose setup sha256 pixels capturedAtUtc selectedSimulator
      captureEvidenceFile captureEvidenceSha256
    ],
    "watchos" => %w[
      captureSelector file screen purpose setup sha256 pixels capturedAtUtc selectedSimulator
      captureEvidenceFile captureEvidenceSha256
    ],
    "visionos" => %w[
      captureSelector file screen purpose setup sha256 pixels capturedAtUtc selectedSimulator
      captureEvidenceFile captureEvidenceSha256
    ],
    "maccatalyst" => %w[
      captureSelector file screen purpose setup pixels sha256 rawSha256 capturedAtUtc source
      product host app processId windowId logicalFrame sourceDisplayScale rasterizationScale
      captureRequest nativeCapture semanticValidation frameCaptureEvidenceFile
      frameCaptureEvidenceSha256 reviewer approval
    ],
  }.transform_values(&:freeze).freeze
  PROVENANCE_ENVELOPE_FILES = %w[
    candidate-metadata.json
    capture-package-manifest.json
    capture-provenance.json
    simulator-runtimes.txt
    source-address.json
  ].freeze
  MAX_ZIP_ARCHIVE_BYTES = 1_073_741_824
  MAX_ZIP_ENTRY_COUNT = 100_000
  MAX_ZIP_ENTRY_COMPRESSED_BYTES = 536_870_912
  MAX_ZIP_ENTRY_UNCOMPRESSED_BYTES = 536_870_912
  MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES = 1_073_741_824
  ZIP_STREAM_CHUNK_BYTES = 1_024
  APPROVAL_SCAN_CHUNK_BYTES = 65_536
  RENAME_EXCL = 0x0000_0004
  FORBIDDEN_APPROVAL_SENTINELS = %w[
    approved-for-build8-upload
    approved-for-build10-upload
    approved-for-build11-upload
    approved-for-build17-upload
    signedreleaseparityapproved
  ].freeze

  def initialize(
    root:,
    release_evidence_root: nil,
    image_inspector: AppleScreenshotImageInspector.new,
    source_guard: nil,
    index_validator: nil,
    historical_frame_sha256s: nil,
    before_stage_copy: nil,
    publish_hook: nil,
    ios_provenance_repository_root: nil,
    ios_provenance_image_inspector: nil,
    ios_provenance_result_inspector: nil
  )
    requested_root = Pathname.new(root).expand_path
    if requested_root.symlink?
      raise AppleScreenshotReleaseSetAssemblyError, "repository root must not be a symlink"
    end
    @root = requested_root.realpath
    requested_release_evidence_root = Pathname.new(release_evidence_root || @root).expand_path
    if requested_release_evidence_root.symlink?
      raise AppleScreenshotReleaseSetAssemblyError,
            "release evidence root must not be a symlink"
    end
    unless requested_release_evidence_root.directory?
      raise AppleScreenshotReleaseSetAssemblyError,
            "release evidence root must be an existing directory"
    end
    @release_evidence_root = requested_release_evidence_root.realpath
    if release_evidence_root && path_within?(@release_evidence_root, @root)
      raise AppleScreenshotReleaseSetAssemblyError,
            "external release evidence root must remain outside the repository"
    end
    @image_inspector = image_inspector
    @source_guard = source_guard || AppleScreenshotReleaseSourceGuard.new(@root)
    @index_validator = index_validator || lambda do
      result = AppleScreenshotReleaseSetValidator.new(root: @root).validate!
      unless result == :pending
        raise AppleScreenshotReleaseSetAssemblyError,
              "a release set is already active; assembly only starts from the pending index"
      end
    end
    @historical_frame_sha256s = historical_frame_sha256s
    unless before_stage_copy.nil? || before_stage_copy.respond_to?(:call)
      raise AppleScreenshotReleaseSetAssemblyError, "before_stage_copy must be callable"
    end
    @before_stage_copy = before_stage_copy
    unless publish_hook.nil? || publish_hook.respond_to?(:call)
      raise AppleScreenshotReleaseSetAssemblyError, "publish_hook must be callable"
    end
    @publish_hook = publish_hook
    @ios_provenance_repository_root = Pathname.new(ios_provenance_repository_root || @root).realpath
    @ios_provenance_image_inspector = ios_provenance_image_inspector
    @ios_provenance_result_inspector = ios_provenance_result_inspector
  end

  # packages is an exact platform-keyed hash whose values contain :capture_root
  # and :artifact. `output` must be the canonical release-evidence path;
  # `index_candidate` is a separate new file and can never replace the checked-in
  # index. The default evidence root is the repository for backwards-compatible
  # offline fixture assembly; hosted release handoff supplies a fresh external
  # root so generated assets never mutate the checkout.
  def assemble(source_commit:, output:, index_candidate:, packages:)
    require_full_commit!(source_commit, "source commit")
    require_equal!(packages.keys, PLATFORMS, "capture package order")
    output_path = Pathname.new(output).expand_path
    expected_output = @release_evidence_root.join(RELEASE_ROOT, source_commit)
    require_equal!(output_path.cleanpath, expected_output, "release-set output path")
    output_parent_binding = ensure_canonical_directory_chain_under!(
      output_path.dirname,
      anchor: @release_evidence_root,
      label: "release-set output parent",
    )
    ensure_new_path!(output_path, "release-set output")

    index_path = @root.join(INDEX_PATH)
    ensure_plain_file!(index_path, "current screenshot set index")
    index = parse_json_file!(index_path, "current screenshot set index")
    unless index.fetch("activeReleaseSet").nil?
      raise AppleScreenshotReleaseSetAssemblyError,
            "current screenshot index must remain pending before assembly"
    end
    requested_index_candidate_path = Pathname.new(index_candidate)
    unless requested_index_candidate_path.absolute?
      raise AppleScreenshotReleaseSetAssemblyError, "index candidate must be an absolute path"
    end
    index_candidate_path = requested_index_candidate_path.expand_path
    if index_candidate_path.cleanpath == index_path
      raise AppleScreenshotReleaseSetAssemblyError,
            "assembler cannot overwrite the current screenshot set index"
    end
    if path_within?(index_candidate_path, @root) || path_within?(index_candidate_path, output_path)
      raise AppleScreenshotReleaseSetAssemblyError,
            "index candidate must remain outside the repository and release-set output"
    end
    index_parent_binding = bind_directory_chain!(
      index_candidate_path.dirname,
      "index candidate parent",
    )
    ensure_new_path!(index_candidate_path, "index candidate")

    @index_validator.call
    normalized_packages = PLATFORMS.map do |platform|
      input = packages.fetch(platform)
      unless input.is_a?(Hash) && input.keys.sort == %i[artifact capture_root]
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} input must contain only capture_root and artifact"
      end
      normalize_capture_package!(
        platform: platform,
        source_commit: source_commit,
        capture_root: input.fetch(:capture_root),
        artifact: input.fetch(:artifact),
      )
    end

    plan_records = normalized_packages.map { |package| package.fetch(:plan) }
    begin
      @source_guard.validate!(source_commit, capture_inputs: plan_records)
    rescue AppleScreenshotReleaseSetValidationError, NativeAppleScreenshotCandidateValidationError => error
      raise AppleScreenshotReleaseSetAssemblyError, error.message
    end

    frame_hashes = normalized_packages.flat_map { |package| package.fetch(:frames).map { |frame| frame.fetch("sha256") } }
    duplicates = frame_hashes.group_by(&:itself).select { |_hash, values| values.length > 1 }.keys
    unless duplicates.empty?
      raise AppleScreenshotReleaseSetAssemblyError,
            "all 26 release frames must be byte-distinct: #{duplicates.sort.join(', ')}"
    end
    historical = @historical_frame_sha256s || historical_frame_sha256s(index)
    reused = frame_hashes.to_set & historical.to_set
    unless reused.empty?
      raise AppleScreenshotReleaseSetAssemblyError,
            "release frames reuse locked historical screenshot bytes: #{reused.to_a.sort.join(', ')}"
    end

    publish!(
      source_commit: source_commit,
      output_path: output_path,
      index_candidate_path: index_candidate_path,
      output_parent_binding: output_parent_binding,
      index_parent_binding: index_parent_binding,
      index: index,
      packages: normalized_packages,
    )
  rescue KeyError, TypeError, ArgumentError, Errno::ENOENT => error
    raise AppleScreenshotReleaseSetAssemblyError,
          "invalid Apple screenshot release-set assembly input: #{error.message}"
  end

  # Revalidates one already-published package using the same seal, exact
  # aggregate, image, semantic/build/install, and ZIP-byte boundary used during
  # assembly.  The release-set verifier calls this entry point lazily so this
  # file can continue to require the verifier for the outer release contract
  # without introducing a circular load.
  def validate_embedded_capture_package!(platform:, source_commit:, capture_root:, artifact:)
    unless PLATFORMS.include?(platform)
      raise AppleScreenshotReleaseSetAssemblyError,
            "unsupported embedded capture platform #{platform.inspect}"
    end
    require_full_commit!(source_commit, "embedded capture source commit")

    capture_path = Pathname.new(capture_root).expand_path
    if capture_path.symlink?
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{platform} embedded raw capture root must not be a symlink"
    end
    capture_path = capture_path.realpath
    unless capture_path.directory? && !capture_path.symlink?
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{platform} embedded raw capture root must be a plain directory"
    end
    artifact_path = Pathname.new(artifact).expand_path
    ensure_plain_file!(artifact_path, "#{platform} embedded capture artifact")

    begin
      QuakeSignalScreenshotCapturePackageSeal.validate(
        platform: platform,
        source_commit: source_commit,
        capture_root: capture_path,
      )
    rescue QuakeSignalScreenshotCapturePackageSeal::Error => error
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{platform} embedded capture seal failed: #{error.message}"
    end
    validate_zip_archive_equivalence!(
      artifact_path: artifact_path,
      capture_path: capture_path,
      platform: platform,
      infer_wrapper: true,
    )

    aggregate_path = capture_path.join("capture-provenance.json")
    ensure_plain_file!(aggregate_path, "#{platform} embedded aggregate capture provenance")
    aggregate = parse_json_file!(aggregate_path, "#{platform} embedded aggregate capture provenance")
    validate_full_capture_provenance!(capture_path, aggregate, platform)
    validate_aggregate_schema!(aggregate, platform)
    validate_unapproved_aggregate_header!(aggregate, platform)
    source = source_record!(aggregate, capture_path, platform)
    require_equal!(source.fetch("commit"), source_commit, "#{platform} embedded capture source commit")
    require_equal!(source.fetch("treeState"), "clean", "#{platform} embedded capture source treeState")
    if source.key?("debugLocalOverridePresent")
      require_equal!(
        source.fetch("debugLocalOverridePresent"), false,
        "#{platform} embedded capture Debug.local override",
      )
    end

    plan = aggregate.fetch("planManifest")
    require_exact_keys!(plan, %w[file sha256], "#{platform} embedded planManifest")
    require_equal!(plan.fetch("file"), PLAN_PATHS.fetch(platform), "#{platform} embedded plan file")
    require_sha256!(plan.fetch("sha256"), "#{platform} embedded plan SHA-256")
    plan_path = @root.join(plan.fetch("file"))
    ensure_plain_file!(plan_path, "#{platform} current embedded-capture plan")
    require_equal!(
      Digest::SHA256.file(plan_path).hexdigest,
      plan.fetch("sha256"),
      "#{platform} current embedded-capture plan hash",
    )

    frames = normalize_frames!(aggregate, capture_path, platform).map do |frame|
      frame.reject { |key, _value| key == "sourcePath" }
    end
    capture_window = validate_capture_window!(aggregate.fetch("captureWindowUtc"), platform)
    capture_environment = normalize_capture_environment!(aggregate, capture_path, platform)
    raw_files = tree_files!(capture_path, "#{platform} embedded raw capture package")
    reject_hidden_approval_material_in_capture!(raw_files, "#{platform} embedded")
    require_independent_capture_evidence!(
      platform: platform,
      capture_path: capture_path,
      raw_files: raw_files,
      aggregate_path: aggregate_path,
    )
    validate_ios_cleanup_evidence!(aggregate, capture_path) if platform == "ios-ipados"

    {
      plan: { "file" => plan.fetch("file"), "sha256" => plan.fetch("sha256") },
      frames: frames,
      capture_window: capture_window,
      capture_environment: capture_environment,
      artifact_sha256: Digest::SHA256.file(artifact_path).hexdigest,
      raw_evidence: raw_files.map do |file|
        {
          "file" => "evidence/raw-capture/#{file.relative_path_from(capture_path)}",
          "sha256" => Digest::SHA256.file(file).hexdigest,
        }
      end,
    }
  rescue KeyError, TypeError, ArgumentError, Errno::ENOENT => error
    raise AppleScreenshotReleaseSetAssemblyError,
          "invalid #{platform} embedded capture package: #{error.message}"
  end

  private

  def normalize_capture_package!(platform:, source_commit:, capture_root:, artifact:)
    capture_path = Pathname.new(capture_root).expand_path
    if capture_path.symlink?
      raise AppleScreenshotReleaseSetAssemblyError, "#{platform} capture root must not be a symlink"
    end
    capture_path = capture_path.realpath
    if within_repository?(capture_path)
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{platform} raw capture package must remain outside the repository"
    end
    begin
      QuakeSignalScreenshotCapturePackageSeal.validate(
        platform: platform,
        source_commit: source_commit,
        capture_root: capture_path,
      )
    rescue QuakeSignalScreenshotCapturePackageSeal::Error => error
      raise AppleScreenshotReleaseSetAssemblyError, "#{platform} capture seal failed: #{error.message}"
    end

    artifact_path = Pathname.new(artifact).expand_path
    ensure_plain_file!(artifact_path, "#{platform} archived capture artifact", inside_repository: false)
    if artifact_path.size.zero?
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{platform} archived capture artifact must be nonempty"
    end
    if within_directory?(artifact_path.realpath, capture_path)
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{platform} archived artifact must be independent of the raw capture directory"
    end
    if within_repository?(artifact_path.realpath)
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{platform} archived artifact must remain outside the repository"
    end
    validate_zip_archive_equivalence!(
      artifact_path: artifact_path,
      capture_path: capture_path,
      platform: platform,
    )

    aggregate_path = capture_path.join("capture-provenance.json")
    ensure_plain_file!(aggregate_path, "#{platform} aggregate capture provenance", inside_repository: false)
    aggregate = parse_json_file!(aggregate_path, "#{platform} aggregate capture provenance")
    validate_full_capture_provenance!(capture_path, aggregate, platform)
    validate_aggregate_schema!(aggregate, platform)
    validate_unapproved_aggregate_header!(aggregate, platform)
    source = source_record!(aggregate, capture_path, platform)
    require_equal!(source.fetch("commit"), source_commit, "#{platform} capture source commit")
    require_equal!(source.fetch("treeState"), "clean", "#{platform} capture source treeState")
    if source.key?("debugLocalOverridePresent")
      require_equal!(source.fetch("debugLocalOverridePresent"), false, "#{platform} Debug.local override")
    end

    plan = aggregate.fetch("planManifest")
    require_exact_keys!(plan, %w[file sha256], "#{platform} aggregate planManifest")
    require_equal!(plan.fetch("file"), PLAN_PATHS.fetch(platform), "#{platform} plan file")
    require_sha256!(plan.fetch("sha256"), "#{platform} plan SHA-256")
    plan_path = @root.join(plan.fetch("file"))
    ensure_plain_file!(plan_path, "#{platform} current plan")
    require_equal!(Digest::SHA256.file(plan_path).hexdigest, plan.fetch("sha256"), "#{platform} current plan hash")

    frames = normalize_frames!(aggregate, capture_path, platform)
    capture_window = validate_capture_window!(aggregate.fetch("captureWindowUtc"), platform)
    environment = normalize_capture_environment!(aggregate, capture_path, platform)
    raw_files = tree_files!(capture_path, "#{platform} raw capture package")
    reject_hidden_approval_material_in_capture!(raw_files, platform)
    independent_evidence = require_independent_capture_evidence!(
      platform: platform,
      capture_path: capture_path,
      raw_files: raw_files,
      aggregate_path: aggregate_path,
    )
    if platform == "ios-ipados"
      validate_ios_cleanup_evidence!(aggregate, capture_path)
    end
    raw_file_snapshots = raw_files.map do |file|
      snapshot_file!(
        file,
        relative: file.relative_path_from(capture_path).to_s,
        label: "#{platform} raw capture file",
      )
    end
    raw_directory_snapshots = tree_directories!(capture_path, "#{platform} raw capture package").map do |directory|
      {
        source_path: directory,
        relative: directory == capture_path ? "." : directory.relative_path_from(capture_path).to_s,
        mode: directory.lstat.mode & 0o7777,
      }
    end
    artifact_snapshot = snapshot_file!(
      artifact_path,
      relative: nil,
      label: "#{platform} archived capture artifact",
    )
    begin
      QuakeSignalScreenshotCapturePackageSeal.validate(
        platform: platform,
        source_commit: source_commit,
        capture_root: capture_path,
      )
    rescue QuakeSignalScreenshotCapturePackageSeal::Error => error
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{platform} capture changed during normalization: #{error.message}"
    end
    validate_zip_archive_equivalence!(
      artifact_path: artifact_path,
      capture_path: capture_path,
      platform: platform,
    )
    {
      platform: platform,
      capture_root: capture_path,
      artifact: artifact_path,
      artifact_snapshot: artifact_snapshot,
      artifact_sha256: artifact_snapshot.fetch(:sha256),
      raw_files: raw_files,
      raw_file_snapshots: raw_file_snapshots,
      raw_directory_snapshots: raw_directory_snapshots,
      independent_evidence: independent_evidence,
      plan: { "file" => plan.fetch("file"), "sha256" => plan.fetch("sha256") },
      frames: frames,
      capture_window: capture_window,
      capture_environment: environment,
    }
  end

  def validate_unapproved_aggregate_header!(aggregate, platform)
    require_equal!(aggregate.fetch("status"), AGGREGATE_STATUS.fetch(platform), "#{platform} aggregate status")
    require_equal!(aggregate.fetch("uploadApproved"), false, "#{platform} aggregate uploadApproved")
    require_equal!(aggregate.fetch("reviewer"), nil, "#{platform} aggregate reviewer")
    if aggregate.key?("approval")
      require_equal!(aggregate.fetch("approval"), nil, "#{platform} aggregate approval")
    end
    if aggregate.key?("releaseBinaryEvidence")
      require_equal!(aggregate.fetch("releaseBinaryEvidence"), nil, "#{platform} aggregate releaseBinaryEvidence")
    end
    require_equal!(aggregate.fetch("platform"), platform, "#{platform} aggregate platform")
    require_equal!(aggregate.fetch("locale"), "en-US", "#{platform} aggregate locale")
  end

  def validate_aggregate_schema!(aggregate, platform)
    require_exact_keys!(aggregate, AGGREGATE_KEYS.fetch(platform), "#{platform} aggregate")
    expected_schema = %w[ios-ipados maccatalyst].include?(platform) ? 1 : 2
    require_equal!(aggregate.fetch("schemaVersion"), expected_schema, "#{platform} aggregate schemaVersion")
    require_equal!(aggregate.fetch("fixture"), "finalized-historical-reports", "#{platform} aggregate fixture")
    require_nonempty_string!(aggregate.fetch("approvalRequired"), "#{platform} aggregate approvalRequired")
  end

  def validate_ios_cleanup_evidence!(aggregate, capture_path)
    reference = aggregate.fetch("simulatorCleanupEvidence")
    require_exact_keys!(reference, %w[file sha256], "iOS/iPadOS simulatorCleanupEvidence")
    require_equal!(reference.fetch("file"), "simulator-cleanup-evidence.json",
                   "iOS/iPadOS simulator cleanup evidence file")
    require_sha256!(reference.fetch("sha256"), "iOS/iPadOS simulator cleanup evidence SHA-256")
    path = capture_path.join(reference.fetch("file"))
    ensure_plain_file!(path, "iOS/iPadOS simulator cleanup evidence", inside_repository: false)
    require_equal!(Digest::SHA256.file(path).hexdigest, reference.fetch("sha256"),
                   "iOS/iPadOS simulator cleanup evidence actual SHA-256")
  end

  def validate_full_capture_provenance!(capture_path, aggregate, platform)
    Dir.mktmpdir("quakesignal-#{platform}-provenance-validation.") do |directory|
      mirror = Pathname.new(directory).join(capture_path.basename)
      mirror.mkdir
      mirror = mirror.realpath
      copy_provenance_validation_tree!(capture_path, mirror, platform)
      output = mirror.join("capture-provenance.json")
      regenerated = case platform
                    when "ios-ipados"
                      options = {
                        capture_root: mirror,
                        output: output,
                        repository_root: @ios_provenance_repository_root,
                      }
                      options[:image_inspector] = @ios_provenance_image_inspector if @ios_provenance_image_inspector
                      options[:result_inspector] = @ios_provenance_result_inspector if @ios_provenance_result_inspector
                      QuakeSignalIOSScreenshotProvenance.assemble(**options)
                    when "maccatalyst"
                      QuakeSignalMacCatalystScreenshotProvenance.assemble(
                        capture_root: mirror,
                        output: output,
                        repository_root: @ios_provenance_repository_root,
                      )
                    else
                      QuakeSignalPlatformScreenshotProvenance.assemble(
                        platform: platform,
                        capture_root: mirror,
                        output: output,
                        repository_root: @ios_provenance_repository_root,
                      )
                    end
      require_equal!(regenerated, aggregate, "#{platform} full aggregate provenance")
    end
  rescue QuakeSignalIOSScreenshotProvenance::Error,
         QuakeSignalMacCatalystScreenshotProvenance::Error,
         QuakeSignalPlatformScreenshotProvenance::Error,
         IOError, SystemCallError => error
    raise AppleScreenshotReleaseSetAssemblyError,
          "#{platform} full aggregate provenance validation failed: #{error.message}"
  end

  def copy_provenance_validation_tree!(source, destination, platform, relative = nil)
    source.children.sort_by(&:to_s).each do |entry|
      name = relative ? "#{relative}/#{entry.basename}" : entry.basename.to_s
      next if relative.nil? && PROVENANCE_ENVELOPE_FILES.include?(name)

      stat = entry.lstat
      target = destination.join(entry.basename)
      if stat.directory? && !entry.symlink?
        target.mkdir
        copy_provenance_validation_tree!(entry, target, platform, name)
      elsif stat.file? && !entry.symlink?
        FileUtils.cp(entry, target, preserve: true)
      else
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} provenance validation input contains a symlink or special entry: #{name}"
      end
    end
  end

  def reject_hidden_approval_material_in_capture!(raw_files, platform)
    raw_files.each do |path|
      scan_forbidden_approval_sentinels!(path, "#{platform} raw evidence #{path.basename}")
      next unless path.extname.downcase == ".json"

      value = parse_json_value!(path, "#{platform} raw JSON #{path.basename}")
      reject_hidden_approval_value!(value, "#{platform} raw JSON #{path.basename}")
    end
  end

  def scan_forbidden_approval_sentinels!(path, label)
    if path.size > MAX_ZIP_ENTRY_UNCOMPRESSED_BYTES
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} exceeds the bounded approval-scan limit"
    end

    normalized_sentinels = FORBIDDEN_APPROVAL_SENTINELS.map do |sentinel|
      sentinel.downcase.gsub(/[^a-z0-9]/n, "")
    end.freeze
    normalized_keep = normalized_sentinels.map(&:bytesize).max - 1
    normalized_suffix = +"".b
    File.open(path, "rb") do |file|
      while (chunk = file.read(APPROVAL_SCAN_CHUNK_BYTES))
        normalized_window = normalized_suffix + chunk.downcase.gsub(/[^a-z0-9]/n, "")
        if normalized_sentinels.any? { |sentinel| normalized_window.include?(sentinel) }
          raise AppleScreenshotReleaseSetAssemblyError,
                "#{label} contains a forbidden approval or signed-parity sentinel"
        end
        normalized_suffix = normalized_window.byteslice(
          -[normalized_window.bytesize, normalized_keep].min,
          normalized_keep,
        ) || normalized_window
      end
    end
    true
  rescue Errno::ENOENT, IOError, SystemCallError => error
    raise AppleScreenshotReleaseSetAssemblyError, "#{label} could not be scanned safely: #{error.message}"
  end

  def reject_hidden_approval_value!(value, label)
    case value
    when Hash
      value.each do |key, nested|
        normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, "")
        case normalized
        when "uploadapproved"
          require_equal!(nested, false, "#{label} #{key}")
        when "reviewer", "approval", "releasebinaryevidence", "approvalfile", "approvalsha256"
          require_equal!(nested, nil, "#{label} #{key}")
        when "approvalrequired"
          require_nonempty_string!(nested, "#{label} #{key}")
        else
          if normalized.include?("reviewer") || normalized.include?("approval") ||
             normalized.include?("releasebinary") || normalized.include?("signedrelease") ||
             normalized.include?("signedartifact")
            raise AppleScreenshotReleaseSetAssemblyError,
                  "#{label} contains hidden reviewer, approval, signed, or release-binary material: #{key}"
          end
        end
        reject_hidden_approval_value!(nested, "#{label}.#{key}")
      end
    when Array
      value.each_with_index do |nested, index|
        reject_hidden_approval_value!(nested, "#{label}[#{index}]")
      end
    when String
      if value.match?(/approved-for-build(?:8|9|10)-upload|signed.?release.?parity.?approved/i)
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{label} contains an approval or signed-parity claim"
      end
    end
  end

  def snapshot_file!(path, relative:, label:)
    ensure_plain_file!(path, label, inside_repository: false)
    stat = path.lstat
    {
      source_path: path,
      relative: relative,
      size: stat.size,
      mode: stat.mode & 0o7777,
      sha256: Digest::SHA256.file(path).hexdigest,
    }
  end

  def source_record!(aggregate, capture_path, platform)
    if %w[ios-ipados maccatalyst].include?(platform)
      source = aggregate.fetch("source")
      expected_keys = platform == "ios-ipados" ?
        %w[commit treeState debugLocalOverridePresent] : %w[commit treeState]
      require_exact_keys!(source, expected_keys, "#{platform} aggregate source")
      return source
    end

    path = capture_path.join("source-address.json")
    ensure_plain_file!(path, "#{platform} source-address evidence", inside_repository: false)
    record = parse_json_file!(path, "#{platform} source-address evidence")
    require_exact_keys!(
      record,
      %w[schemaVersion status uploadApproved reviewer platform source planManifest host],
      "#{platform} source-address evidence",
    )
    require_equal!(record.fetch("schemaVersion"), 1, "#{platform} source-address schemaVersion")
    require_equal!(record.fetch("status"), "unapproved-source-addressed-native-capture-evidence", "#{platform} source-address status")
    require_equal!(record.fetch("uploadApproved"), false, "#{platform} source-address uploadApproved")
    require_equal!(record.fetch("reviewer"), nil, "#{platform} source-address reviewer")
    require_equal!(record.fetch("platform"), platform, "#{platform} source-address platform")
    source = record.fetch("source")
    require_exact_keys!(source, %w[commit treeState debugLocalOverridePresent], "#{platform} source-address source")
    require_equal!(source.fetch("debugLocalOverridePresent"), false, "#{platform} source-address Debug.local override")
    require_equal!(record.fetch("planManifest"), aggregate.fetch("planManifest"), "#{platform} source-address plan binding")
    source
  end

  def normalize_frames!(aggregate, capture_path, platform)
    frames = aggregate.fetch("frames")
    expected = FRAME_SPECS.fetch(platform)
    unless frames.is_a?(Array)
      raise AppleScreenshotReleaseSetAssemblyError, "#{platform} aggregate frames must be an array"
    end
    require_equal!(frames.length, expected.length, "#{platform} aggregate frame count")
    normalized_frames = frames.zip(expected).map.with_index do |(frame, specification), index|
      require_exact_keys!(frame, FRAME_KEYS.fetch(platform), "#{platform} aggregate frame #{index}")
      %w[captureSelector file pixels].each do |field|
        require_equal!(frame.fetch(field), specification.fetch(field), "#{platform} frame #{index} #{field}")
      end
      sha256 = frame.fetch("sha256")
      require_sha256!(sha256, "#{platform} frame #{index} SHA-256")
      relative = specification.fetch("file")
      validate_safe_relative_path!(relative, "#{platform} frame #{index} file")
      path = capture_path.join(relative)
      ensure_plain_file!(path, "#{platform} raw frame #{relative}", inside_repository: false)
      require_equal!(Digest::SHA256.file(path).hexdigest, sha256, "#{platform} frame #{index} actual SHA-256")
      properties = @image_inspector.inspect(path)
      require_equal!([properties.fetch(:width), properties.fetch(:height)], specification.fetch("pixels"), "#{platform} frame #{index} pixels")
      require_equal!(properties.fetch(:format), specification.fetch("format"), "#{platform} frame #{index} format")
      require_equal!(properties.fetch(:has_alpha), false, "#{platform} frame #{index} alpha")
      normalized = specification.merge("sha256" => sha256, "hasAlpha" => false, "sourcePath" => path)
      if platform == "maccatalyst"
        normalized["captureEvidence"] = normalize_maccatalyst_capture_evidence!(
          frame,
          capture_path,
          index,
        )
      end
      normalized
    end
    if platform == "maccatalyst"
      nonces = normalized_frames.map { |frame| frame.fetch("captureEvidence").fetch("nonce") }
      require_equal!(nonces.uniq.length, nonces.length, "Mac Catalyst capture nonce uniqueness")
    end
    normalized_frames
  end

  def normalize_maccatalyst_capture_evidence!(frame, capture_path, index)
    label = "maccatalyst frame #{index}"
    request = frame.fetch("captureRequest")
    response = frame.fetch("nativeCapture")
    unless request.is_a?(Hash) && response.is_a?(Hash)
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{label} direct hierarchy request and response must be objects"
    end

    request_file = capture_evidence_file!(
      request,
      capture_path,
      "#{label} app capture request",
    )
    response_file = capture_evidence_file!(
      response,
      capture_path,
      "#{label} app capture response",
    )
    if request_file == response_file
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{label} app capture request and response evidence must be distinct"
    end

    selector = frame.fetch("captureSelector")
    require_equal!(request_file, "capture-request-evidence/#{selector}.json",
                   "#{label} app capture request file")
    require_equal!(response_file, "native-capture-evidence/#{selector}.json",
                   "#{label} app capture response file")
    nonce = request.fetch("nonce")
    unless nonce.is_a?(String) && nonce.match?(/\A[0-9a-f]{64}\z/)
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} capture nonce is invalid"
    end
    require_equal!(response.fetch("nonce"), nonce, "#{label} capture nonce binding")
    [request, response].each_with_index do |record, record_index|
      record_label = record_index.zero? ? "request" : "response"
      require_equal!(record.fetch("schemaVersion"), 1, "#{label} #{record_label} schemaVersion")
      require_equal!(record.fetch("captureSelector"), selector, "#{label} #{record_label} selector")
      require_equal!(record.fetch("processId"), frame.fetch("processId"), "#{label} #{record_label} PID")
      require_equal!(record.fetch("windowId"), frame.fetch("windowId"), "#{label} #{record_label} window ID")
      require_equal!(record.fetch("logicalViewPoints"), [1_280, 800],
                     "#{label} #{record_label} logical view points")
      require_equal!(record.fetch("rasterizationScale"), 2,
                     "#{label} #{record_label} rasterization scale")
    end

    source_display_scale = response.fetch("sourceDisplayScale")
    unless source_display_scale.is_a?(Numeric) && source_display_scale.finite? &&
           source_display_scale.between?(0.5, 4)
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{label} source display scale must be finite and between 0.5 and 4"
    end
    require_equal!(frame.fetch("sourceDisplayScale"), source_display_scale,
                   "#{label} source display scale binding")
    require_equal!(frame.fetch("rasterizationScale"), 2,
                   "#{label} frame rasterization scale")
    require_equal!(response.fetch("status"), "captured", "#{label} capture response status")
    require_equal!(response.fetch("reason"), nil, "#{label} capture response reason")
    require_equal!(response.fetch("captureApi"), "UIKit.UIView.drawHierarchy", "#{label} capture API")
    require_equal!(response.fetch("captureSurface"), "live-catalyst-uiwindow-hierarchy",
                   "#{label} capture surface")
    require_equal!(response.fetch("pixels"), [2_560, 1_600], "#{label} response pixels")
    require_equal!(response.fetch("afterScreenUpdates"), true,
                   "#{label} after-screen-updates policy")
    require_equal!(response.fetch("drawHierarchyComplete"), true,
                   "#{label} hierarchy completion")
    require_equal!(response.fetch("postCaptureResizePerformed"), false,
                   "#{label} post-capture resize")
    require_equal!(response.fetch("rendererOpaque"), false, "#{label} renderer opacity")
    require_equal!(response.fetch("rendererPreferredRange"), "standard",
                   "#{label} renderer preferred range")
    raw_relative = "raw-window-captures/#{selector}.png"
    raw_path = capture_path.join(raw_relative)
    ensure_plain_file!(raw_path, "#{label} direct raw PNG", inside_repository: false)
    raw_sha256 = response.fetch("rawSha256")
    require_sha256!(raw_sha256, "#{label} direct raw PNG SHA-256")
    require_equal!(frame.fetch("rawSha256"), raw_sha256, "#{label} aggregate/raw response SHA-256")
    require_equal!(Digest::SHA256.file(raw_path).hexdigest, raw_sha256,
                   "#{label} direct raw PNG actual SHA-256")

    {
      "requestFile" => "evidence/raw-capture/#{request.fetch('file')}",
      "requestSha256" => request.fetch("sha256"),
      "responseFile" => "evidence/raw-capture/#{response.fetch('file')}",
      "responseSha256" => response.fetch("sha256"),
      "rawFile" => "evidence/raw-capture/#{raw_relative}",
      "rawSha256" => raw_sha256,
      "nonce" => nonce,
      "captureApi" => response.fetch("captureApi"),
      "captureSurface" => response.fetch("captureSurface"),
      "logicalViewPoints" => response.fetch("logicalViewPoints"),
      "sourceDisplayScale" => source_display_scale,
      "rasterizationScale" => response.fetch("rasterizationScale"),
      "pixels" => response.fetch("pixels"),
      "afterScreenUpdates" => response.fetch("afterScreenUpdates"),
      "drawHierarchyComplete" => response.fetch("drawHierarchyComplete"),
      "postCaptureResizePerformed" => response.fetch("postCaptureResizePerformed"),
      "rendererOpaque" => response.fetch("rendererOpaque"),
      "rendererPreferredRange" => response.fetch("rendererPreferredRange"),
    }
  end

  def capture_evidence_file!(record, capture_path, label)
    relative = record.fetch("file")
    validate_safe_relative_path!(relative, "#{label} file")
    sha256 = record.fetch("sha256")
    require_sha256!(sha256, "#{label} SHA-256")
    path = capture_path.join(relative)
    ensure_plain_file!(path, label, inside_repository: false)
    require_equal!(Digest::SHA256.file(path).hexdigest, sha256, "#{label} actual SHA-256")
    relative
  end

  def normalize_capture_environment!(aggregate, capture_path, platform)
    if platform == "maccatalyst"
      host = aggregate.fetch("host")
      %w[xcodeVersion macOSVersion macOSBuild hardwareModel].each do |field|
        require_nonempty_string!(host.fetch(field), "Mac Catalyst host #{field}")
      end
      frames = aggregate.fetch("frames")
      capture_environment = aggregate.fetch("captureEnvironment")
      require_exact_keys!(
        capture_environment,
        %w[
          kind captureApi captureSurface sourceDisplayScale rasterizationScale
          logicalViewPoints pixels afterScreenUpdates postCaptureResizePerformed
        ],
        "Mac Catalyst aggregate capture environment",
      )
      require_equal!(capture_environment.fetch("kind"), "maccatalyst-uikit-hierarchy",
                     "Mac Catalyst aggregate capture kind")
      require_equal!(capture_environment.fetch("captureApi"), "UIKit.UIView.drawHierarchy",
                     "Mac Catalyst aggregate capture API")
      require_equal!(capture_environment.fetch("captureSurface"),
                     "live-catalyst-uiwindow-hierarchy",
                     "Mac Catalyst aggregate capture surface")
      require_equal!(capture_environment.fetch("logicalViewPoints"), [1_280, 800],
                     "Mac Catalyst aggregate logical view points")
      require_equal!(capture_environment.fetch("pixels"), [2_560, 1_600],
                     "Mac Catalyst aggregate capture pixels")
      require_equal!(capture_environment.fetch("rasterizationScale"), 2,
                     "Mac Catalyst aggregate rasterization scale")
      require_equal!(capture_environment.fetch("afterScreenUpdates"), true,
                     "Mac Catalyst aggregate after-screen-updates policy")
      require_equal!(capture_environment.fetch("postCaptureResizePerformed"), false,
                     "Mac Catalyst aggregate post-capture resize")
      source_display_scales = frames.map { |frame| frame.fetch("sourceDisplayScale") }.uniq
      require_equal!(source_display_scales.length, 1, "Mac Catalyst source display-scale inventory")
      source_display_scale = source_display_scales.first
      unless source_display_scale.is_a?(Numeric) && source_display_scale.finite? &&
             source_display_scale.between?(0.5, 4)
        raise AppleScreenshotReleaseSetAssemblyError,
              "Mac Catalyst source display scale must be finite and between 0.5 and 4"
      end
      require_equal!(capture_environment.fetch("sourceDisplayScale"), source_display_scale,
                     "Mac Catalyst aggregate/frame source display scale")
      require_equal!(frames.map { |frame| frame.fetch("rasterizationScale") }.uniq, [2],
                     "Mac Catalyst rasterization-scale inventory")
      require_equal!(frames.map { |frame| frame.fetch("nativeCapture").fetch("captureApi") }.uniq,
                     ["UIKit.UIView.drawHierarchy"], "Mac Catalyst capture API inventory")
      require_equal!(frames.map { |frame| frame.fetch("nativeCapture").fetch("captureSurface") }.uniq,
                     ["live-catalyst-uiwindow-hierarchy"],
                     "Mac Catalyst capture-surface inventory")
      return {
        "kind" => capture_environment.fetch("kind"),
        "xcodeVersion" => [host.fetch("xcodeVersion"), host["xcodeBuild"]].compact.join(" "),
        "operatingSystem" => "#{host.fetch('macOSVersion')} (#{host.fetch('macOSBuild')})",
        "runtimeIdentifier" => nil,
        "deviceIdentifier" => host.fetch("hardwareModel"),
        "deviceModel" => host.fetch("hardwareModel"),
        "captureApi" => capture_environment.fetch("captureApi"),
        "captureSurface" => capture_environment.fetch("captureSurface"),
        "logicalViewPoints" => capture_environment.fetch("logicalViewPoints"),
        "sourceDisplayScale" => source_display_scale,
        "rasterizationScale" => capture_environment.fetch("rasterizationScale"),
        "pixels" => capture_environment.fetch("pixels"),
        "afterScreenUpdates" => capture_environment.fetch("afterScreenUpdates"),
        "postCaptureResizePerformed" => capture_environment.fetch("postCaptureResizePerformed"),
      }
    end

    if platform == "ios-ipados"
      environment = aggregate.fetch("captureEnvironment")
      %w[xcodeVersion operatingSystem runtimeIdentifier].each do |field|
        require_nonempty_string!(environment.fetch(field), "iOS/iPadOS capture #{field}")
      end
      devices = environment.fetch("devices")
      unless devices.is_a?(Array) && devices.length == 2
        raise AppleScreenshotReleaseSetAssemblyError, "iOS/iPadOS aggregate requires exactly two devices"
      end
      return simulator_environment(
        xcode_version: environment.fetch("xcodeVersion"),
        operating_system: environment.fetch("operatingSystem"),
        runtime_identifier: environment.fetch("runtimeIdentifier"),
        identifiers: devices.map { |device| "#{device.fetch('displayClass')}=#{device.fetch('deviceIdentifier')}" },
        models: devices.map { |device| device.fetch("deviceModel") },
      )
    end

    source_address = parse_json_file!(
      capture_path.join("source-address.json"),
      "#{platform} source-address evidence",
    )
    host = source_address.fetch("host")
    require_exact_keys!(host, %w[xcodeVersion operatingSystem], "#{platform} source-address host")
    selected = aggregate.fetch("frames").map { |frame| frame.fetch("selectedSimulator") }
    runtimes = selected.map { |simulator| simulator.fetch("runtimeIdentifier") }.uniq
    types = selected.map { |simulator| simulator.fetch("deviceTypeIdentifier") }.uniq
    models = selected.map { |simulator| simulator.fetch("deviceModel") }.uniq
    require_equal!(runtimes.length, 1, "#{platform} runtime inventory")
    require_equal!(types.length, 1, "#{platform} device-type inventory")
    require_equal!(models.length, 1, "#{platform} device-model inventory")
    simulator_environment(
      xcode_version: host.fetch("xcodeVersion"),
      operating_system: host.fetch("operatingSystem"),
      runtime_identifier: runtimes.first,
      identifiers: selected.map { |simulator| simulator.fetch("udid") }.uniq.sort,
      models: models,
    )
  end

  def simulator_environment(xcode_version:, operating_system:, runtime_identifier:, identifiers:, models:)
    [xcode_version, operating_system, runtime_identifier, *identifiers, *models].each_with_index do |value, index|
      require_nonempty_string!(value, "simulator environment field #{index}")
    end
    {
      "kind" => "simulator",
      "xcodeVersion" => xcode_version,
      "operatingSystem" => operating_system,
      "runtimeIdentifier" => runtime_identifier,
      "deviceIdentifier" => identifiers.join(","),
      "deviceModel" => models.join(", "),
      "logicalWindowPoints" => nil,
      "backingScale" => nil,
    }
  end

  def publish!(
    source_commit:, output_path:, index_candidate_path:, output_parent_binding:,
    index_parent_binding:, index:, packages:
  )
    output_parent = output_path.dirname
    output_parent_io = nil
    index_parent_io = nil
    stage = nil
    stage_identity = nil
    published = false
    published_identity = nil
    candidate_published = false
    candidate_stage = nil
    candidate_identity = nil
    begin
      output_parent_io = open_bound_directory!(output_parent_binding, "release-set output parent")
      index_parent_io = open_bound_directory!(index_parent_binding, "index candidate parent")
      stage = Pathname.new(Dir.mktmpdir(".quakesignal-release-set.", output_parent.to_s))
      stage_identity = path_identity!(stage, :directory, "release-set stage")
      @before_stage_copy&.call(packages)
      package_records = packages.map do |package|
        publish_package!(stage, source_commit, package)
      end
      release_manifest = {
        "schemaVersion" => 1,
        "status" => "source-frozen-unapproved",
        "uploadApproved" => false,
        "sourceCommit" => source_commit,
        "product" => PRODUCT,
        "packageContentManifestAlgorithm" => PACKAGE_ALGORITHM,
        "totalFrameCount" => FRAME_SPECS.values.sum(&:length),
        "packages" => package_records,
      }
      release_manifest_path = stage.join("release-set.json")
      release_manifest_path.write(JSON.pretty_generate(release_manifest) + "\n", mode: "wx")
      if stage.join("release-approval.json").exist?
        raise AppleScreenshotReleaseSetAssemblyError, "assembler must never create release approval"
      end

      manifest_sha256 = Digest::SHA256.file(release_manifest_path).hexdigest
      candidate = deep_copy(index)
      candidate["activeReleaseSet"] = {
        "sourceCommit" => source_commit,
        "rootDirectory" => "#{RELEASE_ROOT}/#{source_commit}",
        "manifestFile" => "#{RELEASE_ROOT}/#{source_commit}/release-set.json",
        "manifestSha256" => manifest_sha256,
        "approvalFile" => nil,
        "approvalSha256" => nil,
      }
      reject_approval_material!(candidate)
      validate_staged_release!(
        stage: stage,
        release_manifest: release_manifest,
        candidate: candidate,
        source_commit: source_commit,
      )

      invoke_publish_hook!(
        :before_output_parent_revalidation,
        output_parent,
        index_candidate_path.dirname,
        stage: stage,
      )
      revalidate_directory_binding!(output_parent_binding, "release-set output parent")
      ensure_new_path!(output_path, "release-set output")
      invoke_publish_hook!(
        :after_output_target_absence_check,
        output_parent,
        index_candidate_path.dirname,
        stage: stage,
      )
      require_bound_child_identity!(
        output_parent_io,
        output_parent_binding,
        stage,
        stage_identity,
        :directory,
        "release-set stage before publication",
      )
      invoke_publish_hook!(
        :after_output_stage_identity_check,
        output_parent,
        index_candidate_path.dirname,
        stage: stage,
      )
      rename_bound_child!(
        output_parent_io,
        output_parent_binding,
        stage,
        output_path,
        "release-set output publication",
      )
      published = true
      published_identity = stage_identity
      invoke_publish_hook!(
        :after_output_publish,
        output_parent,
        index_candidate_path.dirname,
        stage: stage,
      )
      revalidate_directory_binding!(output_parent_binding, "release-set output parent after publish")
      require_path_identity!(output_path, published_identity, :directory, "published release set")
      validate_staged_release!(
        stage: output_path,
        release_manifest: release_manifest,
        candidate: candidate,
        source_commit: source_commit,
      )
      revalidate_directory_binding!(index_parent_binding, "index candidate parent before staging")
      candidate_stage = Pathname.new(
        Dir::Tmpname.create([".quakesignal-index-candidate.", ".json"], index_candidate_path.dirname.to_s) {},
      )
      candidate_source = JSON.pretty_generate(candidate) + "\n"
      File.open(candidate_stage, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(candidate_source)
        file.flush
        file.fsync
      end
      candidate_identity = path_identity!(candidate_stage, :file, "staged index candidate")
      invoke_publish_hook!(
        :before_index_parent_revalidation,
        output_parent,
        index_candidate_path.dirname,
        stage: stage,
        candidate_stage: candidate_stage,
      )
      revalidate_directory_binding!(index_parent_binding, "index candidate parent")
      ensure_new_path!(index_candidate_path, "index candidate")
      invoke_publish_hook!(
        :after_index_target_absence_check,
        output_parent,
        index_candidate_path.dirname,
        stage: stage,
        candidate_stage: candidate_stage,
      )
      require_bound_child_identity!(
        index_parent_io,
        index_parent_binding,
        candidate_stage,
        candidate_identity,
        :file,
        "staged index candidate before publication",
      )
      invoke_publish_hook!(
        :after_index_stage_identity_check,
        output_parent,
        index_candidate_path.dirname,
        stage: stage,
        candidate_stage: candidate_stage,
      )
      link_bound_child!(
        index_parent_io,
        index_parent_binding,
        candidate_stage,
        index_candidate_path,
        "index candidate publication",
      )
      candidate_published = true
      invoke_publish_hook!(
        :after_index_publish,
        output_parent,
        index_candidate_path.dirname,
        stage: stage,
        candidate_stage: candidate_stage,
      )
      revalidate_directory_binding!(index_parent_binding, "index candidate parent after publish")
      require_path_identity!(index_candidate_path, candidate_identity, :file, "published index candidate")
      require_equal!(index_candidate_path.binread, candidate_source, "published index candidate bytes")
      unlink_bound_child!(
        index_parent_io,
        index_parent_binding,
        candidate_stage,
        "staged index candidate cleanup",
      )
      candidate_stage = nil
      { release_set: release_manifest, index_candidate: candidate }
    rescue StandardError
      if candidate_published
        preserve_bound_child!(
          index_candidate_path, index_parent_io, index_parent_binding, candidate_identity, :file,
        )
      end
      if published
        preserve_bound_child!(
          output_path, output_parent_io, output_parent_binding, published_identity, :directory,
        )
      end
      raise
    ensure
      if candidate_stage
        preserve_bound_child!(
          candidate_stage, index_parent_io, index_parent_binding, candidate_identity, :file,
        )
      end
      if stage
        preserve_bound_child!(stage, output_parent_io, output_parent_binding, stage_identity, :directory)
      end
      index_parent_io&.close
      output_parent_io&.close
    end
  end

  def validate_staged_release!(stage:, release_manifest:, candidate:, source_commit:)
    validator = AppleScreenshotReleaseSetValidator.new(
      root: @root,
      release_evidence_root: @release_evidence_root == @root ? nil : @release_evidence_root,
      image_inspector: @image_inspector,
      source_guard: @source_guard,
      provenance_repository_root: @ios_provenance_repository_root,
      ios_provenance_image_inspector: @ios_provenance_image_inspector,
      ios_provenance_result_inspector: @ios_provenance_result_inspector,
    )
    validator.send(
      :validate_release_manifest!,
      release_manifest,
      stage,
      source_commit,
      Set.new,
    )
    validator.send(:validate_release_root_inventory!, stage, include_approval: false)
    validator.send(:validate_index_header!, candidate)
    active = candidate.fetch("activeReleaseSet")
    require_exact_keys!(
      active,
      %w[sourceCommit rootDirectory manifestFile manifestSha256 approvalFile approvalSha256],
      "staged index candidate activeReleaseSet",
    )
    require_equal!(active.fetch("sourceCommit"), source_commit, "staged index sourceCommit")
    require_equal!(active.fetch("rootDirectory"), "#{RELEASE_ROOT}/#{source_commit}",
                   "staged index rootDirectory")
    require_equal!(active.fetch("manifestFile"), "#{RELEASE_ROOT}/#{source_commit}/release-set.json",
                   "staged index manifestFile")
    require_equal!(active.fetch("manifestSha256"), Digest::SHA256.file(stage.join("release-set.json")).hexdigest,
                   "staged index manifestSha256")
    require_equal!(active.fetch("approvalFile"), nil, "staged index approvalFile")
    require_equal!(active.fetch("approvalSha256"), nil, "staged index approvalSha256")
    reject_hidden_approval_value!(release_manifest, "staged release manifest")
    reject_hidden_approval_value!(candidate, "staged index candidate")
    tree_files!(stage, "staged release set").each do |path|
      next unless path.extname.downcase == ".json"

      reject_hidden_approval_value!(
        parse_json_value!(path, "staged release JSON #{path.relative_path_from(stage)}"),
        "staged release JSON #{path.relative_path_from(stage)}",
      )
    end
  rescue AppleScreenshotReleaseSetValidationError => error
    raise AppleScreenshotReleaseSetAssemblyError, "staged release-set validation failed: #{error.message}"
  end

  def publish_package!(stage, source_commit, package)
    platform = package.fetch(:platform)
    root = stage.join(platform)
    root.mkpath
    raw_snapshots = package.fetch(:raw_file_snapshots).to_h do |snapshot|
      [snapshot.fetch(:relative), snapshot]
    end
    package.fetch(:frames).each do |frame|
      destination = root.join(frame.fetch("file"))
      destination.dirname.mkpath
      snapshot = raw_snapshots.fetch(frame.fetch("file"))
      verified_copy!(snapshot, destination, "#{platform} staged frame #{frame.fetch('file')}")
    end
    evidence_root = root.join("evidence")
    raw_evidence_root = evidence_root.join("raw-capture")
    raw_evidence_root.mkpath
    package.fetch(:raw_directory_snapshots).sort_by do |snapshot|
      snapshot.fetch(:relative).count("/")
    end.each do |snapshot|
      source = snapshot.fetch(:source_path)
      source_stat = source.lstat
      unless source_stat.directory? && !source.symlink? &&
             (source_stat.mode & 0o7777) == snapshot.fetch(:mode)
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} staged raw evidence directory changed: #{snapshot.fetch(:relative)}"
      end
      destination = snapshot.fetch(:relative) == "." ?
        raw_evidence_root : raw_evidence_root.join(snapshot.fetch(:relative))
      destination.mkpath
      File.chmod(snapshot.fetch(:mode), destination)
    end
    artifact_relative = "evidence/capture-artifact"
    artifact_destination = root.join(artifact_relative)
    verified_copy!(package.fetch(:artifact_snapshot), artifact_destination,
                   "#{platform} staged capture artifact")
    evidence_files = [
      { "file" => artifact_relative, "sha256" => Digest::SHA256.file(artifact_destination).hexdigest },
    ]
    package.fetch(:raw_file_snapshots).each do |snapshot|
      relative = snapshot.fetch(:relative)
      destination_relative = "evidence/raw-capture/#{relative}"
      destination = root.join(destination_relative)
      destination.dirname.mkpath
      verified_copy!(snapshot, destination, "#{platform} staged raw evidence #{relative}")
      evidence_files << {
        "file" => destination_relative,
        "sha256" => Digest::SHA256.file(destination).hexdigest,
      }
    end
    reject_hidden_approval_material_in_capture!(
      tree_files!(raw_evidence_root, "#{platform} staged raw capture package"),
      "#{platform} staged",
    )
    staged_aggregate_path = raw_evidence_root.join("capture-provenance.json")
    staged_aggregate = parse_json_file!(
      staged_aggregate_path,
      "#{platform} staged aggregate capture provenance",
    )
    validate_full_capture_provenance!(raw_evidence_root, staged_aggregate, platform)
    required_relatives = package.fetch(:independent_evidence).map do |file|
      file.relative_path_from(package.fetch(:capture_root)).to_s
    end
    unless required_relatives.all? do |relative|
      destination = root.join("evidence/raw-capture", relative)
      destination.file? && !destination.symlink? && destination.size.positive?
    end
      raise AppleScreenshotReleaseSetAssemblyError,
            "#{platform} package needs nonempty evidence independent of its archive"
    end

    metadata = {
      "schemaVersion" => 1,
      "status" => "unapproved-source-frozen-candidate",
      "uploadApproved" => false,
      "sourceCommit" => source_commit,
      "platform" => platform,
      "configuration" => "Debug",
      "sourceTreeState" => "clean",
      "debugLocalOverridePresent" => false,
      "artifactFile" => artifact_relative,
      "artifactSha256" => Digest::SHA256.file(artifact_destination).hexdigest,
      "captureWindowUtc" => package.fetch(:capture_window),
      "captureEnvironment" => package.fetch(:capture_environment),
      "frames" => package.fetch(:frames).map do |frame|
        normalized = frame.reject { |key, _value| key == "sourcePath" }
        normalized.merge("sha256" => Digest::SHA256.file(root.join(frame.fetch("file"))).hexdigest)
      end,
      "evidenceFiles" => evidence_files,
    }
    metadata_path = root.join("package-provenance.json")
    metadata_path.write(JSON.pretty_generate(metadata) + "\n", mode: "wx")
    actual_files = tree_files!(root, "#{platform} release package").map do |file|
      file.relative_path_from(root).to_s
    end
    manifest_source = actual_files.map do |relative|
      "#{Digest::SHA256.file(root.join(relative)).hexdigest}  #{relative}\n"
    end.join
    {
      "platform" => platform,
      "rootDirectory" => platform,
      "plan" => package.fetch(:plan),
      "metadataFile" => "package-provenance.json",
      "metadataSha256" => Digest::SHA256.file(metadata_path).hexdigest,
      "contentManifestSha256" => Digest::SHA256.hexdigest(manifest_source),
      "frameCount" => package.fetch(:frames).length,
    }
  end

  def verified_copy!(snapshot, destination, label)
    source = snapshot.fetch(:source_path)
    ensure_plain_file!(source, "#{label} source", inside_repository: false)
    source_stat = source.lstat
    require_equal!(source_stat.size, snapshot.fetch(:size), "#{label} source size")
    require_equal!(source_stat.mode & 0o7777, snapshot.fetch(:mode), "#{label} source mode")
    FileUtils.cp(source, destination, preserve: true)
    source_stat = source.lstat
    require_equal!(source_stat.size, snapshot.fetch(:size), "#{label} source size after copy")
    require_equal!(source_stat.mode & 0o7777, snapshot.fetch(:mode), "#{label} source mode after copy")
    require_equal!(Digest::SHA256.file(source).hexdigest, snapshot.fetch(:sha256),
                   "#{label} source SHA-256 after copy")
    ensure_plain_file!(destination, label)
    require_equal!(destination.size, snapshot.fetch(:size), "#{label} size")
    require_equal!(destination.lstat.mode & 0o7777, snapshot.fetch(:mode), "#{label} mode")
    require_equal!(Digest::SHA256.file(destination).hexdigest, snapshot.fetch(:sha256),
                   "#{label} SHA-256")
  rescue Errno::ENOENT, IOError, SystemCallError => error
    raise AppleScreenshotReleaseSetAssemblyError, "#{label} could not be copied and verified: #{error.message}"
  end

  def historical_frame_sha256s(index)
    hashes = Set.new
    records = index.fetch("historicalEvidence")
    unless records.is_a?(Array)
      raise AppleScreenshotReleaseSetAssemblyError, "historical evidence index must be an array"
    end
    records.each do |record|
      record.fetch("paths").each do |relative|
        validate_safe_relative_path!(relative, "historical evidence path")
        path = @root.join(relative)
        files = path.directory? && !path.symlink? ? tree_files!(path, "historical evidence") : [path]
        files.each do |file|
          next unless %w[.jpg .jpeg .png].include?(file.extname.downcase)

          ensure_plain_file!(file, "historical screenshot")
          hashes << Digest::SHA256.file(file).hexdigest
        end
      end
    end
    hashes
  end

  def validate_capture_window!(window, platform)
    require_exact_keys!(window, %w[startedAt completedAt], "#{platform} capture window")
    started = strict_utc_time!(window.fetch("startedAt"), "#{platform} capture startedAt")
    completed = strict_utc_time!(window.fetch("completedAt"), "#{platform} capture completedAt")
    if completed < started
      raise AppleScreenshotReleaseSetAssemblyError, "#{platform} capture completed before it started"
    end
    { "startedAt" => started.iso8601, "completedAt" => completed.iso8601 }
  end

  def require_independent_capture_evidence!(platform:, capture_path:, raw_files:, aggregate_path:)
    unless aggregate_path.size.positive?
      raise AppleScreenshotReleaseSetAssemblyError, "#{platform} aggregate capture provenance is empty"
    end
    relatives = raw_files.to_h do |file|
      [file.relative_path_from(capture_path).to_s, file]
    end
    selected = INDEPENDENT_EVIDENCE_REQUIREMENTS.fetch(platform).map do |alternatives|
      match = relatives.find do |relative, file|
        alternatives.any? do |prefix|
          relative == prefix || (prefix.end_with?("/") && relative.start_with?(prefix))
        end && file.size.positive?
      end
      unless match
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} capture package lacks required non-frame evidence: #{alternatives.join(' or ')}"
      end
      match.fetch(1)
    end
    selected.uniq
  end

  # The release artifact must be a conventional `ditto -c -k --norsrc
  # --keepParent` ZIP of the sealed capture directory.  We parse the ZIP
  # central/local records ourselves so no archive path is ever extracted, and
  # compare every regular entry's bytes with the already-validated sealed tree.
  # This makes an arbitrary nonempty artifact (or a ZIP with hidden/excess
  # entries) fail closed before publication.
  def validate_zip_archive_equivalence!(artifact_path:, capture_path:, platform:, infer_wrapper: false)
    entries = read_zip_entries!(artifact_path, platform)
    raw_files = tree_files!(capture_path, "#{platform} sealed capture package")
    prefix = if infer_wrapper
               top_levels = entries.map do |entry|
                 entry.fetch(:name).delete_suffix("/").split("/").fetch(0)
               end.uniq
               unless top_levels.length == 1
                 raise AppleScreenshotReleaseSetAssemblyError,
                       "#{platform} archived ZIP must contain exactly one wrapper directory"
               end
               "#{top_levels.fetch(0)}/"
             else
               "#{capture_path.basename}/"
             end
    expected_files = raw_files.to_h do |file|
      relative = file.relative_path_from(capture_path).to_s
      ["#{prefix}#{relative}", file]
    end
    expected_directories = tree_directories!(capture_path, "#{platform} sealed capture package").to_h do |directory|
      relative = directory == capture_path ? "" : directory.relative_path_from(capture_path).to_s
      name = relative.empty? ? prefix : "#{prefix}#{relative}/"
      [name, directory]
    end

    actual_files = entries.select { |entry| entry.fetch(:type) == :file }.to_h do |entry|
      [entry.fetch(:name), entry]
    end
    actual_directories = entries.select { |entry| entry.fetch(:type) == :directory }.to_h do |entry|
      [entry.fetch(:name), entry]
    end
    require_equal!(actual_files.keys.sort, expected_files.keys.sort, "#{platform} archive file inventory")
    require_equal!(actual_directories.keys.sort, expected_directories.keys.sort,
                   "#{platform} archive directory inventory")

    expected_files.each do |name, source|
      entry = actual_files.fetch(name)
      require_equal!(entry.fetch(:uncompressed_size), source.size, "#{platform} archive #{name} size")
      require_equal!(entry.fetch(:mode), source.lstat.mode & 0o7777, "#{platform} archive #{name} mode")
      bytes = read_zip_entry_bytes!(artifact_path, entry, platform)
      require_equal!(Digest::SHA256.hexdigest(bytes), Digest::SHA256.file(source).hexdigest,
                     "#{platform} archive #{name} bytes")
    end
    expected_directories.each do |name, source|
      require_equal!(actual_directories.fetch(name).fetch(:mode), source.lstat.mode & 0o7777,
                     "#{platform} archive #{name} directory mode")
    end
    true
  end

  def read_zip_entries!(path, platform)
    size = path.size
    raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived artifact is not a ZIP" if size < 22
    if size > MAX_ZIP_ARCHIVE_BYTES
      raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP exceeds the safe byte limit"
    end

    File.open(path, "rb") do |io|
      tail_size = [size, 65_557].min
      io.seek(size - tail_size)
      tail = io.read(tail_size)
      marker = tail.rindex("PK\x05\x06".b)
      unless marker
        raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived artifact is not a ZIP"
      end
      eocd_offset = size - tail_size + marker
      eocd = tail.byteslice(marker, 22)
      if eocd.nil? || eocd.bytesize != 22
        raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP end record is truncated"
      end
      signature, disk, central_disk, disk_entries, entry_count,
        central_size, central_offset, comment_length = eocd.unpack("VvvvvVVv")
      unless signature == 0x06054b50 && disk.zero? && central_disk.zero? &&
             disk_entries == entry_count && entry_count.positive? &&
             entry_count <= MAX_ZIP_ENTRY_COUNT && comment_length.zero? &&
             eocd_offset + 22 == size
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} archived ZIP must be a single-disk, comment-free exact archive"
      end
      if [entry_count, central_size, central_offset].include?(0xffff) ||
         [central_size, central_offset].include?(0xffffffff) ||
         central_offset + central_size != eocd_offset
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} archived ZIP uses unsupported ZIP64 or malformed offsets"
      end

      io.seek(central_offset)
      entries = Array.new(entry_count) do
        header = io.read(46)
        if header.nil? || header.bytesize != 46
          raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP central directory is truncated"
        end
        values = header.unpack("VvvvvvvVVVvvvvvVV")
        unless values.fetch(0) == 0x02014b50
          raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP central entry is malformed"
        end
        made_by, needed, flags, method, _time, _date, crc32,
          compressed_size, uncompressed_size, name_length, extra_length,
          entry_comment_length, entry_disk, _internal_attributes,
          external_attributes, local_offset = values.drop(1)
        if needed >= 45 || entry_disk != 0 || entry_comment_length != 0 ||
           [compressed_size, uncompressed_size, local_offset].include?(0xffffffff) ||
           compressed_size > MAX_ZIP_ENTRY_COMPRESSED_BYTES ||
           uncompressed_size > MAX_ZIP_ENTRY_UNCOMPRESSED_BYTES ||
           (flags & ~0x8) != 0 || ![0, 8].include?(method)
          raise AppleScreenshotReleaseSetAssemblyError,
                "#{platform} archived ZIP entry uses unsupported flags, ZIP64, disk, or compression features"
        end
        name_bytes = io.read(name_length)
        extra = io.read(extra_length)
        if name_bytes.nil? || name_bytes.bytesize != name_length ||
           extra.nil? || extra.bytesize != extra_length
          raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP entry metadata is truncated"
        end
        name = name_bytes.dup.force_encoding(Encoding::UTF_8)
        unless name.valid_encoding? && !name.empty? && !name.include?("\0") && !name.include?("\n") &&
               !name.include?("\r") && !name.start_with?("/") &&
               Pathname.new(name.delete_suffix("/")).cleanpath.to_s == name.delete_suffix("/") &&
               name.split("/").none? { |component| component == "." || component == ".." }
          raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP contains an unsafe path"
        end
        creator = made_by >> 8
        unix_mode = (external_attributes >> 16) & 0xffff
        unix_type = unix_mode & 0o170000
        type = if creator == 3 && unix_type == 0o100000 && !name.end_with?("/")
                 :file
               elsif creator == 3 && unix_type == 0o040000 && name.end_with?("/")
                 :directory
               end
        unless type
          raise AppleScreenshotReleaseSetAssemblyError,
                "#{platform} archived ZIP contains a symlink, special, or malformed entry: #{name}"
        end
        if type == :directory &&
           (!compressed_size.zero? || !uncompressed_size.zero? || !crc32.zero? || method != 0)
          raise AppleScreenshotReleaseSetAssemblyError,
                "#{platform} archived ZIP directory entries must be zero-byte stored records: #{name}"
        end
        {
          name: name,
          type: type,
          mode: unix_mode & 0o7777,
          flags: flags,
          method: method,
          crc32: crc32,
          compressed_size: compressed_size,
          uncompressed_size: uncompressed_size,
          local_offset: local_offset,
        }
      end
      unless io.pos == central_offset + central_size
        raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP central size is inconsistent"
      end
      names = entries.map { |entry| entry.fetch(:name) }
      if names.uniq.length != names.length || entries.map { |entry| entry.fetch(:local_offset) }.uniq.length != entries.length
        raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP contains duplicate entries"
      end
      if entries.sum { |entry| entry.fetch(:uncompressed_size) } > MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} archived ZIP expanded tree exceeds the safe byte limit"
      end
      validate_zip_local_layout!(io, entries, central_offset, platform)
      entries
    end
  rescue Errno::ENOENT, IOError, SystemCallError => error
    raise AppleScreenshotReleaseSetAssemblyError,
          "#{platform} archived ZIP could not be inspected: #{error.message}"
  end


  def validate_zip_local_layout!(io, entries, central_offset, platform)
    ordered = entries.sort_by { |entry| entry.fetch(:local_offset) }
    unless ordered.first&.fetch(:local_offset) == 0
      raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP contains unaccounted prefix bytes"
    end
    ordered.each_with_index do |entry, index|
      io.seek(entry.fetch(:local_offset))
      header = io.read(30)
      values = header&.unpack("VvvvvvVVVvv")
      unless values&.fetch(0) == 0x04034b50
        raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP local entry is malformed"
      end
      local_flags = values.fetch(2)
      if (local_flags & ~0x8) != 0
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} archived ZIP local entry uses unsupported flags"
      end
      unless local_flags == entry.fetch(:flags) && values.fetch(3) == entry.fetch(:method)
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} archived ZIP local/central entry mismatch"
      end
      if entry.fetch(:type) == :directory &&
         (!values.fetch(6).zero? || !values.fetch(7).zero? || !values.fetch(8).zero?)
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} archived ZIP local directory entry must be a zero-byte stored record"
      end
      central_sizes = [
        entry.fetch(:crc32),
        entry.fetch(:compressed_size),
        entry.fetch(:uncompressed_size),
      ]
      local_sizes = [values.fetch(6), values.fetch(7), values.fetch(8)]
      sizes_valid = if (local_flags & 0x8).zero?
                      local_sizes == central_sizes
                    else
                      local_sizes == [0, 0, 0] || local_sizes == central_sizes
                    end
      unless sizes_valid
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} archived ZIP local/central entry sizes mismatch"
      end
      name_length = values.fetch(9)
      extra_length = values.fetch(10)
      local_name = io.read(name_length)
      unless local_name&.bytesize == name_length && local_name == entry.fetch(:name).b
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} archived ZIP local/central entry mismatch"
      end
      data_end = entry.fetch(:local_offset) + 30 + name_length + extra_length + entry.fetch(:compressed_size)
      next_offset = index + 1 < ordered.length ? ordered.fetch(index + 1).fetch(:local_offset) : central_offset
      descriptor_size = next_offset - data_end
      expected_sizes = (entry.fetch(:flags) & 0x8).zero? ? [0] : [12, 16]
      unless expected_sizes.include?(descriptor_size)
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} archived ZIP contains an unaccounted local-entry gap"
      end
      next if descriptor_size.zero?

      io.seek(data_end)
      descriptor = io.read(descriptor_size)
      values = descriptor_size == 16 ? descriptor&.unpack("VVVV") : descriptor&.unpack("VVV")
      values = values.drop(1) if descriptor_size == 16 && values&.first == 0x08074b50
      unless values == [entry.fetch(:crc32), entry.fetch(:compressed_size), entry.fetch(:uncompressed_size)]
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} archived ZIP data descriptor is inconsistent"
      end
    end
  end

  def read_zip_entry_bytes!(path, entry, platform)
    File.open(path, "rb") do |io|
      io.seek(entry.fetch(:local_offset))
      header = io.read(30)
      values = header&.unpack("VvvvvvVVVvv")
      unless values&.fetch(0) == 0x04034b50
        raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP local entry is malformed"
      end
      _signature, _needed, flags, method, _time, _date, local_crc,
        local_compressed, local_uncompressed, name_length, extra_length = values
      if (flags & ~0x8) != 0
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{platform} archived ZIP local entry uses unsupported flags"
      end
      name = io.read(name_length)
      io.seek(extra_length, IO::SEEK_CUR)
      unless name == entry.fetch(:name).b && flags == entry.fetch(:flags) && method == entry.fetch(:method)
        raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP local/central entry mismatch"
      end
      central_sizes = [entry.fetch(:crc32), entry.fetch(:compressed_size), entry.fetch(:uncompressed_size)]
      local_sizes = [local_crc, local_compressed, local_uncompressed]
      sizes_valid = if (flags & 0x8).zero?
                      local_sizes == central_sizes
                    else
                      local_sizes == [0, 0, 0] || local_sizes == central_sizes
                    end
      unless sizes_valid
        raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP local sizes mismatch"
      end
      bytes = case method
              when 0
                unless entry.fetch(:compressed_size) == entry.fetch(:uncompressed_size)
                  raise AppleScreenshotReleaseSetAssemblyError,
                        "#{platform} archived ZIP stored entry sizes are inconsistent"
                end
                remaining = entry.fetch(:compressed_size)
                output = +"".b
                while remaining.positive?
                  chunk = io.read([remaining, ZIP_STREAM_CHUNK_BYTES].min)
                  unless chunk&.bytesize&.positive?
                    raise AppleScreenshotReleaseSetAssemblyError,
                          "#{platform} archived ZIP entry data is truncated"
                  end
                  output << chunk
                  remaining -= chunk.bytesize
                end
                output
              when 8
                inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
                begin
                  remaining = entry.fetch(:compressed_size)
                  output = +"".b
                  while remaining.positive?
                    declared_remaining = entry.fetch(:uncompressed_size) - output.bytesize
                    input_limit = [[declared_remaining, 1].max, ZIP_STREAM_CHUNK_BYTES].min
                    chunk = io.read([remaining, input_limit].min)
                    unless chunk&.bytesize&.positive?
                      raise AppleScreenshotReleaseSetAssemblyError,
                            "#{platform} archived ZIP entry data is truncated"
                    end
                    inflated = inflater.inflate(chunk)
                    if output.bytesize + inflated.bytesize > entry.fetch(:uncompressed_size)
                      raise AppleScreenshotReleaseSetAssemblyError,
                            "#{platform} archived ZIP entry exceeds its declared uncompressed size"
                    end
                    output << inflated
                    remaining -= chunk.bytesize
                    if inflater.finished? && remaining.positive?
                      raise AppleScreenshotReleaseSetAssemblyError,
                            "#{platform} archived ZIP entry contains trailing deflate data"
                    end
                  end
                  unless inflater.finished? && inflater.total_in == entry.fetch(:compressed_size)
                    raise AppleScreenshotReleaseSetAssemblyError,
                          "#{platform} archived ZIP entry is not one exact deflate stream"
                  end
                  output
                ensure
                  inflater.close
                end
              end
      unless bytes.bytesize == entry.fetch(:uncompressed_size) && Zlib.crc32(bytes) == entry.fetch(:crc32)
        raise AppleScreenshotReleaseSetAssemblyError, "#{platform} archived ZIP entry checksum mismatch"
      end
      bytes
    end
  rescue Zlib::Error, IOError, SystemCallError => error
    raise AppleScreenshotReleaseSetAssemblyError,
          "#{platform} archived ZIP entry could not be decoded: #{error.message}"
  end

  def reject_approval_material!(candidate)
    active = candidate.fetch("activeReleaseSet")
    require_equal!(active.fetch("approvalFile"), nil, "index candidate approvalFile")
    require_equal!(active.fetch("approvalSha256"), nil, "index candidate approvalSha256")
    serialized = JSON.generate(candidate)
    if serialized.match?(/approved-for-build(?:8|9|10)-upload/) || serialized.include?("signedReleaseParityApproved")
      raise AppleScreenshotReleaseSetAssemblyError,
            "assembler output must not contain reviewer or signed-parity approval"
    end
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
          raise AppleScreenshotReleaseSetAssemblyError,
                "#{label} contains a symlink or non-regular entry: #{entry}"
        end
      end
    end
    visit.call(root)
    files.sort_by { |file| file.relative_path_from(root).to_s }
  end

  def tree_directories!(root, label)
    directories = [root]
    visit = lambda do |directory|
      directory.children.sort_by(&:to_s).each do |entry|
        stat = entry.lstat
        if stat.directory? && !entry.symlink?
          directories << entry
          visit.call(entry)
        elsif stat.file? && !entry.symlink?
          next
        else
          raise AppleScreenshotReleaseSetAssemblyError,
                "#{label} contains a symlink or non-regular entry: #{entry}"
        end
      end
    end
    visit.call(root)
    directories.sort_by { |directory| directory.relative_path_from(root).to_s }
  end

  def parse_json_file!(path, label)
    value = parse_json_value!(path, label)
    return value if value.is_a?(Hash)

    raise AppleScreenshotReleaseSetAssemblyError, "#{label} must contain one JSON object"
  end

  def parse_json_value!(path, label)
    JSON.parse(
      path.read,
      object_class: AppleScreenshotDuplicateRejectingHash,
      allow_duplicate_key: false,
    )
  rescue JSON::ParserError, AppleScreenshotReleaseSetValidationError => error
    raise AppleScreenshotReleaseSetAssemblyError, "invalid #{label}: #{error.message}"
  end

  def ensure_new_path!(path, label)
    if path.exist? || path.symlink?
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} already exists: #{path}"
    end
  end

  def ensure_canonical_directory_chain_under!(path, anchor:, label:)
    target = Pathname.new(path).expand_path.cleanpath
    trusted = Pathname.new(anchor).realpath
    unless path_within?(target, trusted)
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} must remain inside #{trusted}"
    end

    revalidate_directory_binding!(bind_directory_chain!(trusted, "#{label} anchor"), "#{label} anchor")
    current = trusted
    target.relative_path_from(trusted).each_filename do |component|
      current = current.join(component)
      begin
        stat = current.lstat
      rescue Errno::ENOENT
        Dir.mkdir(current, 0o755)
        stat = current.lstat
      end
      unless stat.directory? && !current.symlink? && current.realpath == current
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{label} contains a symlink, non-directory, or noncanonical component: #{current}"
      end
    end
    bind_directory_chain!(target, label)
  rescue SystemCallError => error
    raise AppleScreenshotReleaseSetAssemblyError, "#{label} could not be created safely: #{error.message}"
  end

  def bind_directory_chain!(path, label)
    target = Pathname.new(path).expand_path.cleanpath
    unless target.absolute? && target.realpath == target
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} must be an existing canonical absolute directory"
    end

    current = Pathname.new(File::SEPARATOR)
    paths = [current]
    target.each_filename do |component|
      current = current.join(component)
      paths << current
    end
    entries = paths.map do |component|
      stat = component.lstat
      unless stat.directory? && !component.symlink? && component.realpath == component
        raise AppleScreenshotReleaseSetAssemblyError,
              "#{label} contains a symlink, non-directory, or noncanonical component: #{component}"
      end
      { path: component.to_s, device: stat.dev, inode: stat.ino }
    end
    { path: target.to_s, entries: entries.freeze }.freeze
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
    raise AppleScreenshotReleaseSetAssemblyError, "#{label} is unavailable: #{error.message}"
  end

  def revalidate_directory_binding!(binding, label)
    current = bind_directory_chain!(binding.fetch(:path), label)
    unless current.fetch(:entries) == binding.fetch(:entries)
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} identity changed during assembly"
    end
    true
  end

  def path_identity!(path, type, label)
    stat = path.lstat
    valid = type == :directory ? stat.directory? : stat.file?
    unless valid && !path.symlink?
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} must be a plain #{type}"
    end
    { device: stat.dev, inode: stat.ino }
  rescue Errno::ENOENT => error
    raise AppleScreenshotReleaseSetAssemblyError, "#{label} is missing: #{error.message}"
  end

  def require_path_identity!(path, identity, type, label)
    require_equal!(path_identity!(path, type, label), identity, "#{label} identity")
  end

  def open_bound_directory!(binding, label)
    revalidate_directory_binding!(binding, label)
    io = File.open(binding.fetch(:path), File::RDONLY | File::NOFOLLOW)
    expected = binding.fetch(:entries).last
    actual = io.stat
    unless actual.directory? && actual.dev == expected.fetch(:device) && actual.ino == expected.fetch(:inode)
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} identity changed while opening it"
    end
    revalidate_directory_binding!(binding, label)
    io
  rescue StandardError
    io&.close
    raise
  end

  def bound_child_name!(path, binding, label)
    child = Pathname.new(path).expand_path.cleanpath
    unless child.dirname.to_s == binding.fetch(:path) && ![".", ".."].include?(child.basename.to_s)
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} is not a direct child of its bound parent"
    end
    child.basename.to_s
  end

  def rename_bound_child!(parent_io, binding, source, destination, label)
    source_name = bound_child_name!(source, binding, "#{label} source")
    destination_name = bound_child_name!(destination, binding, "#{label} destination")
    result = QuakeSignalAppleScreenshotReleaseSetNativeFilesystem.renameatx_np(
      parent_io.fileno,
      source_name,
      parent_io.fileno,
      destination_name,
      RENAME_EXCL,
    )
    raise_native_filesystem_error!(label) unless result.zero?
  end

  def link_bound_child!(parent_io, binding, source, destination, label)
    source_name = bound_child_name!(source, binding, "#{label} source")
    destination_name = bound_child_name!(destination, binding, "#{label} destination")
    result = QuakeSignalAppleScreenshotReleaseSetNativeFilesystem.linkat(
      parent_io.fileno,
      source_name,
      parent_io.fileno,
      destination_name,
      0,
    )
    raise_native_filesystem_error!(label) unless result.zero?
  end

  def unlink_bound_child!(parent_io, binding, path, label)
    name = bound_child_name!(path, binding, label)
    result = QuakeSignalAppleScreenshotReleaseSetNativeFilesystem.unlinkat(parent_io.fileno, name, 0)
    raise_native_filesystem_error!(label) unless result.zero?
  end

  def require_bound_child_identity!(parent_io, binding, path, identity, type, label)
    name = bound_child_name!(path, binding, label)
    descriptor = QuakeSignalAppleScreenshotReleaseSetNativeFilesystem.openat(
      parent_io.fileno,
      name,
      File::RDONLY | File::NOFOLLOW,
      0,
    )
    raise_native_filesystem_error!(label) if descriptor.negative?

    child = IO.for_fd(descriptor)
    stat = child.stat
    valid = type == :directory ? stat.directory? : stat.file?
    unless valid && { device: stat.dev, inode: stat.ino } == identity
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} identity changed during assembly"
    end
    true
  ensure
    child&.close
  end

  # Rollback never recursively deletes through an absolute path. It first
  # rebinds the exact child inode through the already-open parent directory,
  # then atomically moves that child to a no-clobber recovery name. If either
  # identity changed, cleanup refuses to touch the replacement.
  def preserve_bound_child!(path, parent_io, binding, identity, type)
    return unless path && parent_io && !parent_io.closed? && identity

    name = bound_child_name!(path, binding, "rollback child")
    require_bound_child_identity!(
      parent_io,
      binding,
      path,
      identity,
      type,
      "rollback child",
    )
    recovery = ".quakesignal-recovery.#{Process.pid}.#{SecureRandom.hex(13)}.#{name}"
    QuakeSignalAppleScreenshotReleaseSetNativeFilesystem.renameatx_np(
      parent_io.fileno,
      name,
      parent_io.fileno,
      recovery,
      RENAME_EXCL,
    )
    nil
  rescue AppleScreenshotReleaseSetAssemblyError, SystemCallError
    nil
  end

  def raise_native_filesystem_error!(label)
    error = SystemCallError.new(label, Fiddle.last_error)
    raise AppleScreenshotReleaseSetAssemblyError, error.message
  end

  def invoke_publish_hook!(phase, output_parent, index_parent, stage: nil, candidate_stage: nil)
    @publish_hook&.call(
      phase,
      {
        output_parent: output_parent,
        index_parent: index_parent,
        stage: stage,
        candidate_stage: candidate_stage,
      }.freeze,
    )
  end

  def ensure_plain_file!(path, label, inside_repository: true)
    stat = path.lstat
    valid_location = inside_repository ? within_repository?(path.realpath) : true
    return if stat.file? && !path.symlink? && valid_location

    raise AppleScreenshotReleaseSetAssemblyError, "#{label} must be a plain file"
  rescue Errno::ENOENT
    raise AppleScreenshotReleaseSetAssemblyError, "#{label} is missing: #{path}"
  end

  def within_repository?(path)
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

  def path_within?(path, directory)
    candidate = path.cleanpath.to_s
    root = directory.cleanpath.to_s
    candidate == root || candidate.start_with?("#{root}#{File::SEPARATOR}")
  end

  def validate_safe_relative_path!(value, label)
    unless value.is_a?(String) && !value.empty? && !Pathname.new(value).absolute? &&
        Pathname.new(value).cleanpath.to_s == value &&
        value.split(File::SEPARATOR).none? { |segment| segment.empty? || segment == "." || segment == ".." }
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} must be a normalized relative path"
    end
  end

  def require_exact_keys!(value, expected, label)
    unless value.is_a?(Hash)
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} must be an object"
    end
    require_equal!(value.keys.sort, expected.sort, "#{label} keys")
  end

  def require_full_commit!(value, label)
    return if value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)

    raise AppleScreenshotReleaseSetAssemblyError,
          "#{label} must be a full lowercase Git commit"
  end

  def require_sha256!(value, label)
    return if value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)

    raise AppleScreenshotReleaseSetAssemblyError, "#{label} must be a lowercase SHA-256"
  end

  def require_nonempty_string!(value, label)
    return if value.is_a?(String) && !value.strip.empty?

    raise AppleScreenshotReleaseSetAssemblyError, "#{label} must be nonempty"
  end

  def strict_utc_time!(value, label)
    unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} must be whole-second UTC"
    end
    parsed = Time.iso8601(value)
    unless parsed.utc? && parsed.iso8601 == value
      raise AppleScreenshotReleaseSetAssemblyError, "#{label} is not canonical UTC"
    end
    parsed
  rescue ArgumentError => error
    raise AppleScreenshotReleaseSetAssemblyError, "#{label} is invalid: #{error.message}"
  end

  def require_equal!(actual, expected, label)
    return if actual == expected

    raise AppleScreenshotReleaseSetAssemblyError,
          "#{label} mismatch: expected #{expected.inspect}, found #{actual.inspect}"
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    release_evidence_root = nil
    arguments = ARGV.reject do |argument|
      if argument.start_with?("--release-evidence-root=")
        if release_evidence_root
          abort "--release-evidence-root may be supplied only once"
        end
        release_evidence_root = argument.delete_prefix("--release-evidence-root=")
        true
      else
        false
      end
    end
    unless arguments.length == 13
      abort <<~USAGE
        Usage: assemble-apple-screenshot-release-set.rb \
          [--release-evidence-root=<absolute-existing-directory>] \
          <source-commit> <canonical-output-directory> <new-index-candidate.json> \
          <ios-ipados-capture-root> <ios-ipados-artifact> \
          <tvos-capture-root> <tvos-artifact> \
          <watchos-capture-root> <watchos-artifact> \
          <visionos-capture-root> <visionos-artifact> \
          <maccatalyst-capture-root> <maccatalyst-artifact>
      USAGE
    end
    source_commit, output, index_candidate, *package_arguments = arguments
    packages = AppleScreenshotReleaseSetAssembler::PLATFORMS.each_with_index.to_h do |platform, index|
      [
        platform,
        {
          capture_root: package_arguments.fetch(index * 2),
          artifact: package_arguments.fetch(index * 2 + 1),
        },
      ]
    end
    root = Pathname.new(__dir__).join("../..").realpath
    AppleScreenshotReleaseSetAssembler.new(
      root: root,
      release_evidence_root: release_evidence_root,
    ).assemble(
      source_commit: source_commit,
      output: output,
      index_candidate: index_candidate,
      packages: packages,
    )
    puts "Assembled source-frozen unapproved Apple screenshot release set: #{output}"
    puts "Wrote separate unapproved index candidate: #{index_candidate}"
  rescue AppleScreenshotReleaseSetAssemblyError => error
    warn "Apple screenshot release-set assembly failed: #{error.message}"
    exit 65
  end
end
