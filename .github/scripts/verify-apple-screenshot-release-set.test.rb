# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "verify-apple-screenshot-release-set"
require_relative "../../ios/ScreenshotAutomation/seal-screenshot-capture-package"

class FakeAppleReleaseScreenshotInspector
  attr_reader :expected, :inspected

  def initialize
    @expected = {}
    @inspected = []
  end

  def inspect(path)
    @inspected << path.to_s
    return expected.fetch(path.to_s) if expected.key?(path.to_s)

    platform = AppleScreenshotReleaseSetValidator::REQUIRED_PLATFORMS.keys.find do |candidate|
      path.to_s.include?("/#{candidate}/evidence/raw-capture/")
    end
    specification = platform && AppleScreenshotReleaseSetValidator::FRAME_SPECS.fetch(platform).find do |frame|
      path.to_s.end_with?("/#{frame.fetch('file')}")
    end
    raise KeyError, "unexpected inspected fixture path #{path}" unless specification

    {
      width: specification.fetch("pixels").fetch(0),
      height: specification.fetch("pixels").fetch(1),
      format: specification.fetch("format"),
      has_alpha: false,
    }
  end
end

class FakeAppleReleaseSourceGuard
  attr_accessor :validation_error, :equivalence_error
  attr_reader :validations, :equivalence_checks

  def initialize
    @validations = []
    @equivalence_checks = []
  end

  def validate!(commit, capture_inputs:)
    raise validation_error if validation_error

    @validations << [commit, capture_inputs]
    true
  end

  def validate_product_equivalent!(source_commit, signed_commit)
    raise equivalence_error if equivalence_error

    @equivalence_checks << [source_commit, signed_commit]
    true
  end
end

class FakeAppleHistoricalCommitGuard
  attr_reader :commits

  def initialize
    @commits = []
  end

  def validate!(commit)
    @commits << commit
    true
  end
end

class FakeAppleEmbeddedCapturePackageValidator
  attr_reader :validated_platforms

  def initialize
    @validated_platforms = []
  end

  def validate!(platform:, source_commit:, capture_root:, artifact:)
    raise "unexpected fixture source" unless source_commit == AppleScreenshotReleaseSetValidatorTest::SOURCE_COMMIT

    raw_root = Pathname.new(capture_root)
    package_root = raw_root.join("../..").cleanpath
    metadata = JSON.parse(package_root.join("package-provenance.json").read)
    @validated_platforms << platform
    {
      plan: nil,
      frames: metadata.fetch("frames"),
      capture_window: metadata.fetch("captureWindowUtc"),
      capture_environment: metadata.fetch("captureEnvironment"),
      artifact_sha256: Digest::SHA256.file(artifact).hexdigest,
      raw_evidence: raw_root.glob("**/*", File::FNM_DOTMATCH).select do |path|
        path.file? && !path.symlink?
      end.sort_by { |path| path.relative_path_from(raw_root).to_s }.map do |path|
        {
          "file" => "evidence/raw-capture/#{path.relative_path_from(raw_root)}",
          "sha256" => Digest::SHA256.file(path).hexdigest,
        }
      end,
    }
  end
end

class FakeVerifierIOSProvenanceImageInspector
  def inspect(path)
    pixels = path.to_s.include?("iphone-6.5") || path.basename.to_s.include?("iphone-6.5") ?
      [1_242, 2_688] : [2_064, 2_752]
    {
      "pixels" => pixels,
      "format" => path.extname == ".jpg" ? "jpeg" : "png",
      "hasAlpha" => false,
    }
  end
end

class FakeVerifierIOSProvenanceResultInspector
  def call(path, architecture)
    unless path.directory? && path.join("Data/build-record.json").file?
      raise "fixture xcresult was not safely extracted"
    end
    raise "unsupported fixture architecture" unless %w[arm64 x86_64].include?(architecture)

    {
      "actionTitle" => 'Build "QuakeSignal"',
      "status" => "succeeded",
      "errorCount" => 0,
      "errors" => [],
      "warningCount" => 0,
      "warnings" => [],
      "analyzerWarningCount" => 0,
      "analyzerWarnings" => [],
      "startTime" => 1_787_276_400.0,
      "endTime" => 1_787_276_410.0,
      "destination" => {
        "platform" => "iOS Simulator",
        "deviceId" => "dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder",
        "deviceName" => "Any iOS Simulator Device",
        "modelName" => "Apple device",
        "osVersion" => "",
        "architecture" => "undefined_arch",
      },
    }
  end
end

class AppleScreenshotReleaseSetValidatorTest < Minitest::Test
  SOURCE_ROOT = Pathname.new(__dir__).join("../..").realpath
  SOURCE_COMMIT = "a" * 40
  SIGNED_COMMIT = SOURCE_COMMIT

  class << self
    def realistic_active_release_fixture
      return @realistic_active_release_fixture if @realistic_active_release_fixture

      parent = ENV["QUAKESIGNAL_TEST_TEMP_ROOT"] || ENV["RUNNER_TEMP"] || ENV["TMPDIR"] || Dir.tmpdir
      parent = Pathname.new(parent).realpath
      cache = Pathname.new(Dir.mktmpdir("quakesignal-realistic-verifier-fixture", parent.to_s))
      destination = cache.join("repository")
      assembler_test = SOURCE_ROOT.join(".github/scripts/assemble-apple-screenshot-release-set.test.rb")
      script = <<~'RUBY'
        require "fileutils"
        require "json"
        require "pathname"
        test_file, destination_string = ARGV
        ARGV.replace(["--name", "test_realistic_verifier_fixture_sentinel"])
        require test_file
        class AppleScreenshotReleaseSetAssemblerFixtureSentinelTest < Minitest::Test
          def test_realistic_verifier_fixture_sentinel
            assert true
          end
        end
        destination = Pathname.new(destination_string)
        helper = AppleScreenshotReleaseSetAssemblerTest.new("fixture")
        begin
          helper.setup
          root = helper.instance_variable_get(:@root)
          output = helper.instance_variable_get(:@output)
          index_candidate = helper.instance_variable_get(:@index_candidate)
          packages = helper.instance_variable_get(:@packages)
          helper.send(:assembler).assemble(
            source_commit: AppleScreenshotReleaseSetAssemblerTest::SOURCE_COMMIT,
            output: output,
            index_candidate: index_candidate,
            packages: packages,
          )
          destination.mkpath
          root.children.each { |entry| FileUtils.cp_r(entry, destination, preserve: true) }
          index = JSON.parse(index_candidate.read)
          index["historicalEvidence"] = []
          index_path = destination.join(AppleScreenshotReleaseSetValidator::INDEX_PATH)
          index_path.write(JSON.pretty_generate(index) + "\n")
        ensure
          helper.teardown
        end
      RUBY
      output, error_output, status = Open3.capture3(
        RbConfig.ruby, "-e", script, assembler_test.to_s, destination.to_s,
      )
      unless status.success? && destination.directory?
        detail = [error_output.strip, output.strip].reject(&:empty?).join("\n")
        suffix = detail.empty? ? "" : ":\n#{detail}"
        raise "failed to build realistic active release-set fixture#{suffix}"
      end

      @realistic_active_release_fixture = destination.realpath
      Minitest.after_run { FileUtils.remove_entry(cache) if cache.directory? && !cache.symlink? }
      @realistic_active_release_fixture
    end
  end

  def setup
    @temporary_directory = Dir.mktmpdir("apple-screenshot-release-set")
    @root = Pathname.new(@temporary_directory).realpath
    @release_evidence_root = @root
    @inspector = FakeAppleReleaseScreenshotInspector.new
    @source_guard = FakeAppleReleaseSourceGuard.new
    @historical_guard = FakeAppleHistoricalCommitGuard.new
    @capture_package_validator = FakeAppleEmbeddedCapturePackageValidator.new
    build_history_fixture
    copy_plan_fixtures
    write_index(active: nil)
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory) if @temporary_directory && File.exist?(@temporary_directory)
  end

  def validator
    AppleScreenshotReleaseSetValidator.new(
      root: @root,
      release_evidence_root: @release_evidence_root == @root ? nil : @release_evidence_root,
      image_inspector: @inspector,
      source_guard: @source_guard,
      historical_commit_guard: @historical_guard,
      historical_evidence: [@history_record],
      capture_package_validator: @capture_package_validator,
    )
  end

  def test_pending_index_validates_history_but_release_ready_fails_closed
    assert_equal :pending, validator.validate!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end
    assert_match(/complete active build-16 screenshot release set/, error.message)
    assert_empty @source_guard.validations
  end

  def test_external_ephemeral_release_evidence_validates_without_repository_mutation
    @release_evidence_root = @root.dirname.join("#{@root.basename}-release-evidence")
    @release_evidence_root.mkpath
    build_active_release_set

    assert_equal :active_unapproved,
                 validator.validate!(expected_source_commit: SOURCE_COMMIT)
    assert @release_evidence_root.join(AppleScreenshotReleaseSetValidator::INDEX_PATH).file?
    refute @root.join(AppleScreenshotReleaseSetValidator::RELEASE_ROOT, SOURCE_COMMIT).exist?
  ensure
    FileUtils.remove_entry(@release_evidence_root) if
      @release_evidence_root && @release_evidence_root != @root && @release_evidence_root.exist?
  end

  def test_complete_active_set_is_source_guarded_but_not_release_ready_without_approval
    build_active_release_set

    assert_equal :active_unapproved, validator.validate!(expected_source_commit: SOURCE_COMMIT)
    assert_equal 26, @inspector.inspected.length
    assert_equal 1, @source_guard.validations.length
    assert_equal SOURCE_COMMIT, @source_guard.validations.first.fetch(0)
    assert_equal AppleScreenshotReleaseSetValidator::PLAN_PATHS.values,
                 @source_guard.validations.first.fetch(1).map { |record| record.fetch("file") }

    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end
    assert_match(/separate named signed-parity approval/, error.message)
  end

  def test_named_signed_approval_makes_exact_26_frame_set_release_ready
    build_active_release_set
    add_release_approval

    assert_equal :release_ready,
                 validator.validate!(
                   require_release_ready: true,
                   expected_source_commit: SOURCE_COMMIT,
                 )
    assert_equal 5, @source_guard.equivalence_checks.length
    assert_equal [[SOURCE_COMMIT, SIGNED_COMMIT]] * 5, @source_guard.equivalence_checks
  end

  def test_cross_source_package_is_rejected_even_after_outer_hashes_are_recomputed
    build_active_release_set
    metadata_path = release_root.join("tvos/package-provenance.json")
    metadata = JSON.parse(metadata_path.read)
    metadata["sourceCommit"] = "c" * 40
    write_json(metadata_path, metadata)
    rehash_package!("tvos")
    rehash_release_manifest!

    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/tvos provenance sourceCommit/, error.message)
  end

  def test_active_set_cannot_bypass_the_current_product_source_guard
    build_active_release_set
    @source_guard.validation_error =
      AppleScreenshotReleaseSetValidationError.new("tracked, untracked, or ignored product drift")

    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/tracked, untracked, or ignored product drift/, error.message)
  end

  def test_rehashed_plan_drift_cannot_change_the_required_frame_contract
    build_active_release_set
    plan_path = @root.join(AppleScreenshotReleaseSetValidator::PLAN_PATHS.fetch("tvos"))
    plan = JSON.parse(plan_path.read)
    plan.fetch("frames").first["captureSelector"] = "tvos-unplanned"
    write_json(plan_path, plan)

    manifest_path = release_root.join("release-set.json")
    manifest = JSON.parse(manifest_path.read)
    package = manifest.fetch("packages").find { |record| record.fetch("platform") == "tvos" }
    package.fetch("plan")["sha256"] = Digest::SHA256.file(plan_path).hexdigest
    write_json(manifest_path, manifest)
    rehash_release_manifest!

    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/tvos plan frame contract/, error.message)
  end

  def test_rehashed_ios_plan_cannot_drift_selector_or_display_class
    build_active_release_set
    ios_plan_path = @root.join(AppleScreenshotReleaseSetValidator::PLAN_PATHS.fetch("ios-ipados"))
    plan = JSON.parse(ios_plan_path.read)
    plan.fetch("frames").first["captureSelector"] = "ios-iphone-6.5-unreviewed"
    write_json(ios_plan_path, plan)
    rehash_plan_reference!("ios-ipados")
    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/iOS\/iPadOS plan exact ten-frame contract/, error.message)

    FileUtils.copy_file(
      SOURCE_ROOT.join(AppleScreenshotReleaseSetValidator::PLAN_PATHS.fetch("ios-ipados")),
      ios_plan_path,
    )
    build_active_release_set(reset: true)
    plan = JSON.parse(ios_plan_path.read)
    plan.fetch("frames").first["displayClass"] = "ipad-13"
    write_json(ios_plan_path, plan)
    rehash_plan_reference!("ios-ipados")
    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/iOS\/iPadOS plan exact ten-frame contract/, error.message)
  end

  def test_catalyst_release_metadata_requires_direct_uikit_hierarchy_at_2x
    build_active_release_set
    metadata_path = release_root.join("maccatalyst/package-provenance.json")
    metadata = JSON.parse(metadata_path.read)
    metadata.fetch("captureEnvironment")["kind"] = "maccatalyst-host"
    write_json(metadata_path, metadata)
    rehash_package!("maccatalyst")
    rehash_release_manifest!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/Mac Catalyst capture kind mismatch/, error.message)

    build_active_release_set(reset: true)
    metadata = JSON.parse(metadata_path.read)
    metadata.fetch("frames").first.fetch("captureEvidence")["captureApi"] =
      "ScreenCaptureKit.SCScreenshotManager"
    write_json(metadata_path, metadata)
    rehash_package!("maccatalyst")
    rehash_release_manifest!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/capture API mismatch/, error.message)

    build_active_release_set(reset: true)
    metadata = JSON.parse(metadata_path.read)
    metadata.fetch("frames").first.fetch("captureEvidence")["rasterizationScale"] = 1
    write_json(metadata_path, metadata)
    rehash_package!("maccatalyst")
    rehash_release_manifest!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/rasterization scale mismatch/, error.message)

    build_active_release_set(reset: true)
    metadata = JSON.parse(metadata_path.read)
    first_nonce = metadata.fetch("frames").first.fetch("captureEvidence").fetch("nonce")
    metadata.fetch("frames").fetch(1).fetch("captureEvidence")["nonce"] = first_nonce
    write_json(metadata_path, metadata)
    rehash_package!("maccatalyst")
    rehash_release_manifest!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/capture nonce uniqueness mismatch/, error.message)
  end

  def test_collapsed_or_historical_frame_bytes_are_rejected_after_all_rehashing
    build_active_release_set

    source = release_root.join("tvos/en-US/01-dashboard.png")
    target = release_root.join("watchos/en-US/01-headline.png")
    target.binwrite(source.binread)
    metadata_path = release_root.join("watchos/package-provenance.json")
    metadata = JSON.parse(metadata_path.read)
    metadata.fetch("frames").first["sha256"] = Digest::SHA256.file(target).hexdigest
    write_json(metadata_path, metadata)
    rehash_package!("watchos")
    rehash_release_manifest!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/26 byte-distinct frames/, error.message)

    build_active_release_set(reset: true)
    target = release_root.join("visionos/en-US/01-home.png")
    target.binwrite(@historical_frame.binread)
    metadata_path = release_root.join("visionos/package-provenance.json")
    metadata = JSON.parse(metadata_path.read)
    metadata.fetch("frames").first["sha256"] = Digest::SHA256.file(target).hexdigest
    write_json(metadata_path, metadata)
    rehash_package!("visionos")
    rehash_release_manifest!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/must not reuse locked historical screenshot bytes/, error.message)
  end

  def test_artifact_bytes_are_bound_beyond_the_outer_evidence_hashes
    build_active_release_set
    artifact = release_root.join("tvos/evidence/capture-artifact")
    artifact.binwrite("different debug artifact bytes\n")
    metadata_path = release_root.join("tvos/package-provenance.json")
    metadata = JSON.parse(metadata_path.read)
    evidence = metadata.fetch("evidenceFiles").find do |record|
      record.fetch("file") == metadata.fetch("artifactFile")
    end
    evidence["sha256"] = Digest::SHA256.file(artifact).hexdigest
    write_json(metadata_path, metadata)
    rehash_package!("tvos")
    rehash_release_manifest!

    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/archived artifact actual SHA-256/, error.message)
  end

  def test_missing_extra_traversal_and_symlinked_package_entries_are_rejected
    build_active_release_set

    missing = release_root.join("watchos/en-US/01-headline.png")
    missing.delete
    assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    build_active_release_set(reset: true)

    extra = release_root.join("visionos/unindexed.txt")
    extra.write("extra\n")
    assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    extra.delete

    metadata_path = release_root.join("tvos/package-provenance.json")
    metadata = JSON.parse(metadata_path.read)
    metadata["evidenceFiles"].select! do |record|
      record.fetch("file") == metadata.fetch("artifactFile")
    end
    release_root.join("tvos/evidence/raw-capture/capture.txt").delete
    write_json(metadata_path, metadata)
    rehash_package!("tvos")
    rehash_release_manifest!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/archived artifact and independent capture evidence/, error.message)
    build_active_release_set(reset: true)

    metadata_path = release_root.join("ios-ipados/package-provenance.json")
    metadata = JSON.parse(metadata_path.read)
    metadata.fetch("evidenceFiles") << { "file" => "../escape.txt", "sha256" => "0" * 64 }
    write_json(metadata_path, metadata)
    rehash_package!("ios-ipados")
    rehash_release_manifest!
    assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    build_active_release_set(reset: true)

    screenshot = release_root.join("maccatalyst/en-US/01-home.png")
    target = release_root.join("maccatalyst/en-US/02-reports.png")
    screenshot.delete
    File.symlink(target.basename.to_s, screenshot)
    assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
  end

  def test_historical_byte_and_index_mutations_are_rejected
    @historical_frame.binwrite("changed\n")
    assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }

    build_history_fixture
    index = JSON.parse(index_path.read)
    index.fetch("historicalEvidence").first["eligibleForBuild8Upload"] = true
    write_json(index_path, index)
    assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
  end

  def test_approval_requires_named_reviewer_signed_parity_and_source_equivalence
    build_active_release_set
    add_release_approval
    approval_path = release_root.join("release-approval.json")
    approval = JSON.parse(approval_path.read)
    approval.fetch("approvals").fetch("visual")["reviewer"] = "  "
    write_json(approval_path, approval)
    rehash_approval!
    assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end

    add_release_approval(reset: true)
    @source_guard.equivalence_error = AppleScreenshotReleaseSetValidationError.new("signed source drift")
    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end
    assert_match(/signed source drift/, error.message)
  end

  def test_approval_requires_explicit_privacy_review_and_exact_capture_run_binding
    build_active_release_set
    add_release_approval
    approval_path = release_root.join("release-approval.json")
    approval = JSON.parse(approval_path.read)
    approval.fetch("approvals").fetch("privacy")["approved"] = false
    write_json(approval_path, approval)
    rehash_approval!
    assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end

    add_release_approval(reset: true)
    approval = JSON.parse(approval_path.read)
    approval.fetch("captureRun")["workflowFile"] = ".github/workflows/unreviewed.yml"
    write_json(approval_path, approval)
    rehash_approval!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end
    assert_match(/capture run workflow file/, error.message)

    add_release_approval(reset: true)
    approval = JSON.parse(approval_path.read)
    approval.fetch("captureRun")["repository"] = "UntrustedFork/QuakeSignal"
    write_json(approval_path, approval)
    rehash_approval!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end
    assert_match(/capture run canonical repository/, error.message)
  end

  def test_named_reviewers_are_bound_to_protected_environment_approval
    build_active_release_set
    add_release_approval
    approval_path = release_root.join("release-approval.json")
    approval = JSON.parse(approval_path.read)
    approval.fetch("approvals").fetch("visual")["reviewer"] = "unapproved-reviewer"
    write_json(approval_path, approval)
    rehash_approval!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end
    assert_match(/approved protected-environment login/, error.message)

    add_release_approval(reset: true)
    approval = JSON.parse(approval_path.read)
    approval.fetch("environmentApproval")["approvedReviewerGitHubLogins"] = ["release-owner"]
    approval.fetch("approvals").each_value { |record| record["reviewer"] = "release-owner" }
    write_json(approval_path, approval)
    rehash_approval!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end
    assert_match(/reviewer distinct from the actor/, error.message)
  end

  def test_approval_times_must_follow_capture_and_platform_parity
    build_active_release_set
    add_release_approval
    approval_path = release_root.join("release-approval.json")
    approval = JSON.parse(approval_path.read)
    approval.fetch("platforms").first["parityReviewedAtUtc"] = "2020-01-01T00:00:00Z"
    approval.fetch("approvals").fetch("signedReleaseParity")["reviewedAtUtc"] =
      "2020-01-01T00:00:00Z"
    write_json(approval_path, approval)
    rehash_approval!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end
    assert_match(/signedReleaseParity review must not predate screenshot capture completion/, error.message)

    add_release_approval(reset: true)
    approval = JSON.parse(approval_path.read)
    approval["reviewedAtUtc"] = "2020-01-01T00:00:00Z"
    write_json(approval_path, approval)
    rehash_approval!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end
    assert_match(/overall release review completion time/, error.message)
  end

  def test_signed_release_evidence_requires_embedded_watch_and_four_distinct_artifacts
    build_active_release_set
    add_release_approval
    approval_path = release_root.join("release-approval.json")
    approval = JSON.parse(approval_path.read)
    watch = approval.fetch("platforms").find { |record| record.fetch("platform") == "watchos" }
    watch["signedReleaseRunId"] += 100
    watch["signedReleaseAttestationArtifactName"] =
      "signed-release-attestation-ios-ipados-watchos-#{SOURCE_COMMIT}-#{watch.fetch("signedReleaseRunId")}-#{watch.fetch("signedReleaseRunAttempt")}"
    write_json(approval_path, approval)
    rehash_approval!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end
    assert_match(/iOS\/iPadOS and watchOS signed release run ID/, error.message)

    add_release_approval(reset: true)
    approval = JSON.parse(approval_path.read)
    tvos = approval.fetch("platforms").find { |record| record.fetch("platform") == "tvos" }
    visionos = approval.fetch("platforms").find { |record| record.fetch("platform") == "visionos" }
    visionos["signedReleaseArtifactSha256"] = tvos.fetch("signedReleaseArtifactSha256")
    write_json(approval_path, approval)
    rehash_approval!
    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      validator.validate!(require_release_ready: true, expected_source_commit: SOURCE_COMMIT)
    end
    assert_match(/distinct signed release artifact count/, error.message)
  end

  def test_duplicate_json_keys_and_partial_approval_pointer_are_rejected
    source = index_path.read
    duplicate = source.sub(%Q[  "schemaVersion": 1,\n], %Q[  "schemaVersion": 1,\n  "schemaVersion": 1,\n])
    refute_equal source, duplicate
    index_path.write(duplicate)
    assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }

    write_index(active: nil)
    build_active_release_set
    index = JSON.parse(index_path.read)
    index.fetch("activeReleaseSet")["approvalFile"] = "#{release_root_relative}/release-approval.json"
    write_json(index_path, index)
    error = assert_raises(AppleScreenshotReleaseSetValidationError) { validator.validate! }
    assert_match(/both be null or both be present/, error.message)
  end

  def test_realistic_assembled_release_set_deep_validates_all_five_raw_packages
    install_realistic_active_fixture

    assert_equal :active_unapproved, realistic_validator.validate!
    assert_equal AppleScreenshotReleaseSetValidator::REQUIRED_PLATFORMS.keys,
                 @realistic_capture_validator.validated_platforms
  end

  def test_rejects_resealed_raw_aggregate_forgery_after_archive_and_outer_rehash
    install_realistic_active_fixture
    raw_root = release_root.join("tvos/evidence/raw-capture")
    aggregate_path = raw_root.join("capture-provenance.json")
    aggregate = JSON.parse(aggregate_path.read)
    aggregate.fetch("frames").first["purpose"] = "Self-resealed verifier forgery"
    write_json(aggregate_path, aggregate)
    reseal_realistic_capture!("tvos", rebuild_archive: true)

    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      realistic_validator.validate!
    end
    assert_match(/tvos embedded capture package failed deep validation/, error.message)
    assert_match(/full aggregate provenance/, error.message)
  end

  def test_rejects_resealed_raw_tree_that_no_longer_equals_rehashed_archive_evidence
    install_realistic_active_fixture
    source_address = release_root.join("watchos/evidence/raw-capture/source-address.json")
    source_address.open("ab") { |file| file.write("\n") }
    reseal_realistic_capture!("watchos", rebuild_archive: false)

    error = assert_raises(AppleScreenshotReleaseSetValidationError) do
      realistic_validator.validate!
    end
    assert_match(/watchos embedded capture package failed deep validation/, error.message)
    assert_match(/archive .* bytes/, error.message)
  end

  def test_direct_cli_loads_assembler_lazily_and_validates_an_active_realistic_fixture
    install_realistic_active_fixture
    fixture_entries = @root.children
    fixture_root = @root.join("release-set")
    fixture_root.mkpath
    fixture_entries.each { |entry| FileUtils.mv(entry, fixture_root) }
    harness_root = @root.join("direct-cli-harness")
    harness_root.mkpath
    prelude = harness_root.join("prelude.rb")
    write_direct_cli_prelude(prelude)
    environment = {
      "QUAKESIGNAL_REALISTIC_VERIFIER_ROOT" => fixture_root.to_s,
      "QUAKESIGNAL_REALISTIC_SOURCE_ROOT" => SOURCE_ROOT.to_s,
    }
    begin
      output, error_output, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        "-r#{prelude}",
        SOURCE_ROOT.join(".github/scripts/verify-apple-screenshot-release-set.rb").to_s,
      )
    ensure
      FileUtils.remove_entry(harness_root) if harness_root.directory? && !harness_root.symlink?
    end
    assert status.success?, "direct verifier CLI failed: #{error_output}"
    assert_match(/Complete source-addressed 26-frame Apple screenshot set validated/, output)
    refute_match(/circular|uninitialized constant|stack level too deep/i, output + error_output)
    refute harness_root.exist?, "direct verifier CLI harness residue must be removed"
    assert_equal [fixture_root], @root.children
  end

  private

  def install_realistic_active_fixture
    FileUtils.remove_entry(@root) if @root.exist?
    @root.mkpath
    self.class.realistic_active_release_fixture.children.each do |entry|
      FileUtils.cp_r(entry, @root, preserve: true)
    end
    @inspector = FakeAppleReleaseScreenshotInspector.new
    AppleScreenshotReleaseSetValidator::FRAME_SPECS.each do |platform, frames|
      frames.each do |frame|
        path = release_root.join(platform, frame.fetch("file"))
        @inspector.expected[path.to_s] = {
          width: frame.fetch("pixels").fetch(0),
          height: frame.fetch("pixels").fetch(1),
          format: frame.fetch("format"),
          has_alpha: false,
        }
      end
    end
    @source_guard = FakeAppleReleaseSourceGuard.new
    @historical_guard = FakeAppleHistoricalCommitGuard.new
    @realistic_capture_validator = AppleScreenshotEmbeddedCapturePackageValidator.new(
      root: @root,
      image_inspector: @inspector,
      provenance_repository_root: SOURCE_ROOT,
      ios_provenance_image_inspector: FakeVerifierIOSProvenanceImageInspector.new,
      ios_provenance_result_inspector: FakeVerifierIOSProvenanceResultInspector.new,
    )
  end

  def realistic_validator
    AppleScreenshotReleaseSetValidator.new(
      root: @root,
      image_inspector: @inspector,
      source_guard: @source_guard,
      historical_commit_guard: @historical_guard,
      historical_evidence: [],
      capture_package_validator: @realistic_capture_validator,
    )
  end

  def reseal_realistic_capture!(platform, rebuild_archive:)
    package_root = release_root.join(platform)
    raw_root = package_root.join("evidence/raw-capture")
    manifest_path = raw_root.join("capture-package-manifest.json")
    manifest_path.delete
    QuakeSignalScreenshotCapturePackageSeal.seal(
      platform: platform,
      source_commit: SOURCE_COMMIT,
      capture_root: raw_root,
      output: manifest_path,
    )
    artifact = package_root.join("evidence/capture-artifact")
    if rebuild_archive
      artifact.delete
      success = system(
        "/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent",
        raw_root.to_s, artifact.to_s,
        out: File::NULL, err: File::NULL,
      )
      raise "failed to rebuild realistic capture ZIP" unless success && artifact.file?
    end

    metadata_path = package_root.join("package-provenance.json")
    metadata = JSON.parse(metadata_path.read)
    metadata["artifactSha256"] = Digest::SHA256.file(artifact).hexdigest
    metadata.fetch("evidenceFiles").each do |record|
      path = package_root.join(record.fetch("file"))
      record["sha256"] = Digest::SHA256.file(path).hexdigest
    end
    write_json(metadata_path, metadata)
    rehash_realistic_package!(platform)
  end

  def rehash_realistic_package!(platform)
    release_manifest_path = release_root.join("release-set.json")
    release_manifest = JSON.parse(release_manifest_path.read)
    package = release_manifest.fetch("packages").find do |record|
      record.fetch("platform") == platform
    end
    package_root = release_root.join(platform)
    package["metadataSha256"] =
      Digest::SHA256.file(package_root.join("package-provenance.json")).hexdigest
    package["contentManifestSha256"] = package_content_sha256(package_root)
    write_json(release_manifest_path, release_manifest)
    index = JSON.parse(index_path.read)
    index.fetch("activeReleaseSet")["manifestSha256"] =
      Digest::SHA256.file(release_manifest_path).hexdigest
    write_json(index_path, index)
  end

  def write_direct_cli_prelude(path)
    path.write(<<~'RUBY')
      class DirectVerifierInspector
        def inspect(path)
          value = path.to_s
          pixels = if value.include?("/iphone-6.5/")
                     [1_242, 2_688]
                   elsif value.include?("/ipad-13/")
                     [2_064, 2_752]
                   elsif value.include?("/tvos/")
                     [1_920, 1_080]
                   elsif value.include?("/watchos/")
                     [410, 502]
                   elsif value.include?("/visionos/")
                     [3_840, 2_160]
                   else
                     [2_560, 1_600]
                   end
          {
            width: pixels.fetch(0), height: pixels.fetch(1),
            format: path.extname.downcase == ".jpg" ? "jpeg" : "png",
            has_alpha: false,
          }
        end
      end

      class DirectVerifierIOSInspector
        def inspect(path)
          pixels = path.to_s.include?("iphone-6.5") || path.basename.to_s.include?("iphone-6.5") ?
            [1_242, 2_688] : [2_064, 2_752]
          {
            "pixels" => pixels,
            "format" => path.extname.downcase == ".jpg" ? "jpeg" : "png",
            "hasAlpha" => false,
          }
        end
      end

      class DirectVerifierResultInspector
        def call(path, architecture)
          raise "fixture xcresult missing" unless path.join("Data/build-record.json").file?
          raise "fixture architecture drift" unless %w[arm64 x86_64].include?(architecture)
          {
            "actionTitle" => 'Build "QuakeSignal"',
            "status" => "succeeded",
            "errorCount" => 0,
            "errors" => [],
            "warningCount" => 0,
            "warnings" => [],
            "analyzerWarningCount" => 0,
            "analyzerWarnings" => [],
            "startTime" => 1_787_276_400.0,
            "endTime" => 1_787_276_410.0,
            "destination" => {
              "platform" => "iOS Simulator",
              "deviceId" => "dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder",
              "deviceName" => "Any iOS Simulator Device",
              "modelName" => "Apple device",
              "osVersion" => "",
              "architecture" => "undefined_arch",
            },
          }
        end
      end

      class DirectVerifierSourceGuard
        def validate!(*); true; end
        def validate_product_equivalent!(*); true; end
      end

      class DirectVerifierHistoricalGuard
        def validate!(*); true; end
      end

      $quakesignal_direct_verifier_trace = TracePoint.new(:end) do
        next unless defined?(AppleScreenshotReleaseSetValidator)
        next unless AppleScreenshotReleaseSetValidator.instance_methods(false).include?(:validate!)

        klass = AppleScreenshotReleaseSetValidator
        original_new = klass.method(:new)
        fixture_root = ENV.fetch("QUAKESIGNAL_REALISTIC_VERIFIER_ROOT")
        source_root = ENV.fetch("QUAKESIGNAL_REALISTIC_SOURCE_ROOT")
        klass.define_singleton_method(:new) do |**_arguments|
          inspector = DirectVerifierInspector.new
          capture_validator = AppleScreenshotEmbeddedCapturePackageValidator.new(
            root: fixture_root,
            image_inspector: inspector,
            provenance_repository_root: source_root,
            ios_provenance_image_inspector: DirectVerifierIOSInspector.new,
            ios_provenance_result_inspector: DirectVerifierResultInspector.new,
          )
          original_new.call(
            root: fixture_root,
            image_inspector: inspector,
            source_guard: DirectVerifierSourceGuard.new,
            historical_commit_guard: DirectVerifierHistoricalGuard.new,
            historical_evidence: [],
            capture_package_validator: capture_validator,
          )
        end
        $quakesignal_direct_verifier_trace.disable
      end
      $quakesignal_direct_verifier_trace.enable
    RUBY
  end

  def build_history_fixture
    @historical_frame = @root.join("history/frame.png")
    @historical_frame.dirname.mkpath
    @historical_frame.binwrite("historical screenshot bytes\n")
    relative = @historical_frame.relative_path_from(@root).to_s
    manifest = "#{Digest::SHA256.file(@historical_frame).hexdigest}  #{relative}\n"
    @history_record = {
      "id" => "test-history",
      "sourceCommit" => nil,
      "status" => "historical-pre-source-binding",
      "eligibleForBuild8Upload" => false,
      "paths" => [relative],
      "fileCount" => 1,
      "totalBytes" => @historical_frame.size,
      "contentManifestSha256" => Digest::SHA256.hexdigest(manifest),
    }
  end

  def copy_plan_fixtures
    AppleScreenshotReleaseSetValidator::PLAN_PATHS.each_value do |relative|
      destination = @root.join(relative)
      destination.dirname.mkpath
      FileUtils.copy_file(SOURCE_ROOT.join(relative), destination)
    end
  end

  def index_path
    @release_evidence_root.join(AppleScreenshotReleaseSetValidator::INDEX_PATH)
  end

  def release_root_relative
    "#{AppleScreenshotReleaseSetValidator::RELEASE_ROOT}/#{SOURCE_COMMIT}"
  end

  def release_root
    @release_evidence_root.join(release_root_relative)
  end

  def base_index
    {
      "schemaVersion" => 1,
      "product" => AppleScreenshotReleaseSetValidator::PRODUCT,
      "historicalContentManifestAlgorithm" => AppleScreenshotReleaseSetValidator::HISTORICAL_ALGORITHM,
      "requiredPlatforms" => AppleScreenshotReleaseSetValidator::REQUIRED_PLATFORMS.map do |platform, count|
        { "platform" => platform, "frameCount" => count }
      end,
      "historicalEvidence" => [@history_record],
      "activeReleaseSet" => nil,
    }
  end

  def write_index(active:)
    index = base_index
    index["activeReleaseSet"] = active
    index_path.dirname.mkpath
    write_json(index_path, index)
  end

  def build_active_release_set(reset: false)
    if reset && release_root.exist?
      FileUtils.remove_entry(release_root)
      @inspector.expected.clear
    end
    release_root.mkpath
    packages = AppleScreenshotReleaseSetValidator::REQUIRED_PLATFORMS.map do |platform, count|
      build_package(platform, count)
    end
    manifest = {
      "schemaVersion" => 1,
      "status" => "source-frozen-unapproved",
      "uploadApproved" => false,
      "sourceCommit" => SOURCE_COMMIT,
      "product" => AppleScreenshotReleaseSetValidator::PRODUCT,
      "packageContentManifestAlgorithm" => AppleScreenshotReleaseSetValidator::PACKAGE_ALGORITHM,
      "totalFrameCount" => 26,
      "packages" => packages,
    }
    manifest_path = release_root.join("release-set.json")
    write_json(manifest_path, manifest)
    active = {
      "sourceCommit" => SOURCE_COMMIT,
      "rootDirectory" => release_root_relative,
      "manifestFile" => "#{release_root_relative}/release-set.json",
      "manifestSha256" => Digest::SHA256.file(manifest_path).hexdigest,
      "approvalFile" => nil,
      "approvalSha256" => nil,
    }
    write_index(active: active)
  end

  def build_package(platform, expected_count)
    package_root = release_root.join(platform)
    package_root.mkpath
    raw_capture_root = package_root.join("evidence/raw-capture")
    raw_capture_root.mkpath
    frames = AppleScreenshotReleaseSetValidator::FRAME_SPECS.fetch(platform).map do |spec|
      file = package_root.join(spec.fetch("file"))
      file.dirname.mkpath
      file.binwrite("fixture:#{platform}:#{spec.fetch('file')}\n")
      @inspector.expected[file.to_s] = {
        width: spec.fetch("pixels").fetch(0),
        height: spec.fetch("pixels").fetch(1),
        format: spec.fetch("format"),
        has_alpha: false,
      }
      normalized = spec.merge("sha256" => Digest::SHA256.file(file).hexdigest, "hasAlpha" => false)
      if platform == "maccatalyst"
        selector = spec.fetch("captureSelector")
        nonce = Digest::SHA256.hexdigest("fixture capture nonce:#{selector}")
        request = raw_capture_root.join("capture-request-evidence/#{selector}.json")
        response = raw_capture_root.join("native-capture-evidence/#{selector}.json")
        raw = raw_capture_root.join("raw-window-captures/#{selector}.png")
        write_json(request, { "fixture" => "app request", "nonce" => nonce })
        write_json(response, { "fixture" => "app response", "nonce" => nonce })
        raw.dirname.mkpath
        raw.binwrite("direct hierarchy fixture:#{selector}\n")
        normalized["captureEvidence"] = {
          "requestFile" => "evidence/raw-capture/#{request.relative_path_from(raw_capture_root)}",
          "requestSha256" => Digest::SHA256.file(request).hexdigest,
          "responseFile" => "evidence/raw-capture/#{response.relative_path_from(raw_capture_root)}",
          "responseSha256" => Digest::SHA256.file(response).hexdigest,
          "rawFile" => "evidence/raw-capture/#{raw.relative_path_from(raw_capture_root)}",
          "rawSha256" => Digest::SHA256.file(raw).hexdigest,
          "nonce" => nonce,
          "captureApi" => "UIKit.UIView.drawHierarchy",
          "captureSurface" => "live-catalyst-uiwindow-hierarchy",
          "logicalViewPoints" => [1_280, 800],
          "sourceDisplayScale" => 1.0,
          "rasterizationScale" => 2,
          "pixels" => [2_560, 1_600],
          "afterScreenUpdates" => true,
          "drawHierarchyComplete" => true,
          "postCaptureResizePerformed" => false,
          "rendererOpaque" => false,
          "rendererPreferredRange" => "standard",
        }
      end
      normalized
    end
    assert_equal expected_count, frames.length
    evidence_path = raw_capture_root.join("capture.txt")
    evidence_path.binwrite("capture evidence for #{platform}\n")
    artifact_path = package_root.join("evidence/capture-artifact")
    artifact_path.binwrite("debug capture artifact bytes for #{platform}\n")
    raw_evidence_records = raw_capture_root.glob("**/*", File::FNM_DOTMATCH).select do |path|
      path.file? && !path.symlink?
    end.sort_by { |path| path.relative_path_from(raw_capture_root).to_s }.map do |path|
      {
        "file" => "evidence/raw-capture/#{path.relative_path_from(raw_capture_root)}",
        "sha256" => Digest::SHA256.file(path).hexdigest,
      }
    end
    metadata = {
      "schemaVersion" => 1,
      "status" => "unapproved-source-frozen-candidate",
      "uploadApproved" => false,
      "sourceCommit" => SOURCE_COMMIT,
      "platform" => platform,
      "configuration" => "Debug",
      "sourceTreeState" => "clean",
      "debugLocalOverridePresent" => false,
      "artifactFile" => "evidence/capture-artifact",
      "artifactSha256" => Digest::SHA256.file(artifact_path).hexdigest,
      "captureWindowUtc" => {
        "startedAt" => "2026-08-20T00:00:00Z",
        "completedAt" => "2026-08-20T00:05:00Z",
      },
      "captureEnvironment" => capture_environment(platform),
      "frames" => frames,
      "evidenceFiles" => [
        {
          "file" => "evidence/capture-artifact",
          "sha256" => Digest::SHA256.file(artifact_path).hexdigest,
        },
        *raw_evidence_records,
      ],
    }
    metadata_path = package_root.join("package-provenance.json")
    write_json(metadata_path, metadata)
    {
      "platform" => platform,
      "rootDirectory" => platform,
      "plan" => {
        "file" => AppleScreenshotReleaseSetValidator::PLAN_PATHS.fetch(platform),
        "sha256" => Digest::SHA256.file(@root.join(AppleScreenshotReleaseSetValidator::PLAN_PATHS.fetch(platform))).hexdigest,
      },
      "metadataFile" => "package-provenance.json",
      "metadataSha256" => Digest::SHA256.file(metadata_path).hexdigest,
      "contentManifestSha256" => package_content_sha256(package_root),
      "frameCount" => expected_count,
    }
  end

  def capture_environment(platform)
    catalyst = platform == "maccatalyst"
    if catalyst
      return {
        "kind" => "maccatalyst-uikit-hierarchy",
        "xcodeVersion" => "26.6 (17F113)",
        "operatingSystem" => "macOS 26.6.2 (25G83)",
        "runtimeIdentifier" => nil,
        "deviceIdentifier" => "host-mac",
        "deviceModel" => "Mac",
        "captureApi" => "UIKit.UIView.drawHierarchy",
        "captureSurface" => "live-catalyst-uiwindow-hierarchy",
        "logicalViewPoints" => [1_280, 800],
        "sourceDisplayScale" => 1.0,
        "rasterizationScale" => 2,
        "pixels" => [2_560, 1_600],
        "afterScreenUpdates" => true,
        "postCaptureResizePerformed" => false,
      }
    end

    {
      "kind" => "simulator",
      "xcodeVersion" => "26.6 (17F113)",
      "operatingSystem" => "macOS 26.6.2 (25G83)",
      "runtimeIdentifier" => "com.apple.CoreSimulator.SimRuntime.test",
      "deviceIdentifier" => "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      "deviceModel" => "Simulator",
      "logicalWindowPoints" => nil,
      "backingScale" => nil,
    }
  end

  def add_release_approval(reset: false)
    approval_path = release_root.join("release-approval.json")
    approval_path.delete if reset && approval_path.exist?
    manifest_path = release_root.join("release-set.json")
    approval = {
      "schemaVersion" => 3,
      "status" => "approved-for-build17-upload",
      "uploadApproved" => true,
      "sourceCommit" => SOURCE_COMMIT,
      "releaseSetManifestSha256" => Digest::SHA256.file(manifest_path).hexdigest,
      "dispatchActorGitHubLogin" => "release-owner",
      "environmentApproval" => {
        "schemaVersion" => 1,
        "repository" => AppleScreenshotReleaseSetValidator::CANONICAL_REPOSITORY,
        "runId" => 30_001,
        "runAttempt" => 1,
        "workflowFile" => ".github/workflows/apple-screenshot-release-ready.yml",
        "headSha" => SOURCE_COMMIT,
        "environment" => "ios-app-store-release",
        "approvedReviewerGitHubLogins" => ["release-reviewer"],
      },
      "captureRun" => {
        "schemaVersion" => 1,
        "repository" => AppleScreenshotReleaseSetValidator::CANONICAL_REPOSITORY,
        "runId" => 12_345,
        "runAttempt" => 1,
        "workflowFile" => AppleScreenshotReleaseSetValidator::CAPTURE_WORKFLOW_FILE,
        "event" => "workflow_dispatch",
        "headBranch" => "main",
        "headSha" => SOURCE_COMMIT,
        "status" => "completed",
        "conclusion" => "success",
        "completedAtUtc" => "2026-08-20T00:50:00Z",
        "artifacts" => [
          "UNAPPROVED-debug-simulator-ios-ipados-#{SOURCE_COMMIT}",
          "UNAPPROVED-debug-simulator-tvos-#{SOURCE_COMMIT}",
          "UNAPPROVED-debug-simulator-watchos-#{SOURCE_COMMIT}",
          "UNAPPROVED-debug-simulator-visionos-#{SOURCE_COMMIT}",
          "UNAPPROVED-debug-maccatalyst-direct-uikit-#{SOURCE_COMMIT}",
        ].map.with_index do |name, index|
          {
            "name" => name,
            "id" => index + 1,
            "sizeInBytes" => 1024 + index,
            "digest" => "sha256:#{Digest::SHA256.hexdigest(name)}",
            "expired" => false,
          }
        end,
      },
      "approvals" => {
        "visual" => {
          "approved" => true,
          "reviewer" => "release-reviewer",
          "reviewedAtUtc" => "2026-08-20T00:57:00Z",
        },
        "privacy" => {
          "approved" => true,
          "reviewer" => "release-reviewer",
          "reviewedAtUtc" => "2026-08-20T00:58:00Z",
        },
        "signedReleaseParity" => {
          "approved" => true,
          "reviewer" => "release-reviewer",
          "reviewedAtUtc" => "2026-08-20T00:55:00Z",
        },
      },
      "reviewedAtUtc" => "2026-08-20T00:58:00Z",
      "platforms" => AppleScreenshotReleaseSetValidator::REQUIRED_PLATFORMS.keys.map do |platform|
        run_id = {
          "ios-ipados" => 20_001,
          "watchos" => 20_001,
          "tvos" => 20_002,
          "visionos" => 20_003,
          "maccatalyst" => 20_004,
        }.fetch(platform)
        role = %w[ios-ipados watchos].include?(platform) ? "ios-ipados-watchos" : platform
        signed_hash_platform = platform == "watchos" ? "ios-ipados" : platform
        {
          "platform" => platform,
          "signedReleaseRunId" => run_id,
          "signedReleaseRunAttempt" => 1,
          "signedReleaseWorkflowFile" =>
            AppleScreenshotReleaseSetValidator::SIGNED_RELEASE_WORKFLOW_FILES.fetch(platform),
          "signedReleaseAttestationArtifactName" =>
            "signed-release-attestation-#{role}-#{SOURCE_COMMIT}-#{run_id}-1",
          "signedReleaseAttestationArtifactDigest" =>
            "sha256:#{Digest::SHA256.hexdigest("attestation:#{role}")}",
          "signedReleaseArtifactKind" =>
            AppleScreenshotReleaseSetValidator::SIGNED_RELEASE_ARTIFACT_KINDS.fetch(platform),
          "signedReleaseArtifactSha256" => Digest::SHA256.hexdigest("signed:#{signed_hash_platform}"),
          "signedMarketingVersion" => "1.1",
          "signedBuildNumber" => 15,
          "signedDistributionMode" => "testflight-upload",
          "signedReleaseAttestedAtUtc" => "2026-08-20T00:53:00Z",
          "signedBuildSourceCommit" => SIGNED_COMMIT,
          "signedRunCompletedAtUtc" => "2026-08-20T00:54:00Z",
          "signedReleaseParityApproved" => true,
          "parityReviewedAtUtc" => "2026-08-20T00:55:00Z",
        }
      end,
    }
    write_json(approval_path, approval)
    rehash_approval!
  end

  def rehash_package!(platform)
    manifest_path = release_root.join("release-set.json")
    manifest = JSON.parse(manifest_path.read)
    package = manifest.fetch("packages").find { |record| record.fetch("platform") == platform }
    package_root = release_root.join(platform)
    metadata_path = package_root.join("package-provenance.json")
    package["metadataSha256"] = Digest::SHA256.file(metadata_path).hexdigest
    package["contentManifestSha256"] = package_content_sha256(package_root)
    write_json(manifest_path, manifest)
  end

  def rehash_plan_reference!(platform)
    manifest_path = release_root.join("release-set.json")
    manifest = JSON.parse(manifest_path.read)
    package = manifest.fetch("packages").find { |record| record.fetch("platform") == platform }
    plan_path = @root.join(AppleScreenshotReleaseSetValidator::PLAN_PATHS.fetch(platform))
    package.fetch("plan")["sha256"] = Digest::SHA256.file(plan_path).hexdigest
    write_json(manifest_path, manifest)
    rehash_release_manifest!
  end

  def rehash_release_manifest!
    index = JSON.parse(index_path.read)
    index.fetch("activeReleaseSet")["manifestSha256"] =
      Digest::SHA256.file(release_root.join("release-set.json")).hexdigest
    write_json(index_path, index)
  end

  def rehash_approval!
    index = JSON.parse(index_path.read)
    active = index.fetch("activeReleaseSet")
    active["approvalFile"] = "#{release_root_relative}/release-approval.json"
    active["approvalSha256"] = Digest::SHA256.file(release_root.join("release-approval.json")).hexdigest
    write_json(index_path, index)
  end

  def package_content_sha256(package_root)
    files = package_root.glob("**/*", File::FNM_DOTMATCH).select(&:file?).sort_by do |file|
      file.relative_path_from(package_root).to_s
    end
    source = files.map do |file|
      "#{Digest::SHA256.file(file).hexdigest}  #{file.relative_path_from(package_root)}\n"
    end.join
    Digest::SHA256.hexdigest(source)
  end

  def write_json(path, value)
    path.dirname.mkpath
    path.write(JSON.pretty_generate(value) + "\n")
  end
end
