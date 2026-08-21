# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "rbconfig"
require "set"
require "tmpdir"
require_relative "assemble-apple-screenshot-release-set"

class FakeAppleScreenshotAssemblyInspector
  def inspect(path)
    platform = AppleScreenshotReleaseSetAssembler::PLATFORMS.find do |candidate|
      path.to_s.include?("/captures/#{candidate}/") ||
        path.to_s.include?("/#{candidate}/en-US/") ||
        path.to_s.include?("/#{candidate}/evidence/raw-capture/")
    end
    raise "unknown fixture platform: #{path}" unless platform

    specification = AppleScreenshotReleaseSetAssembler::FRAME_SPECS.fetch(platform).find do |frame|
      path.to_s.end_with?("/#{frame.fetch('file')}")
    end
    raise "unknown fixture frame: #{path}" unless specification

    {
      width: specification.fetch("pixels").fetch(0),
      height: specification.fetch("pixels").fetch(1),
      format: specification.fetch("format"),
      has_alpha: false,
    }
  end
end

class FakeAppleScreenshotAssemblySourceGuard
  attr_reader :validations

  def initialize
    @validations = []
  end

  def validate!(commit, capture_inputs:)
    @validations << [commit, capture_inputs]
    true
  end
end

class FakeIOSAssemblyProvenanceImageInspector
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

class FakeIOSAssemblyProvenanceResultInspector
  RESULT_SUMMARY = {
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
  }.freeze

  def call(path, architecture)
    unless path.directory? && path.join("Data/build-record.json").file?
      raise "fixture xcresult was not safely extracted"
    end
    raise "unsupported fixture architecture" unless %w[arm64 x86_64].include?(architecture)

    Marshal.load(Marshal.dump(RESULT_SUMMARY))
  end
end

class AppleScreenshotReleaseSetAssemblerTest < Minitest::Test
  SOURCE_ROOT = Pathname.new(__dir__).join("../..").realpath
  SOURCE_COMMIT = "a" * 40

  class << self
    def realistic_ios_capture_fixture
      return @realistic_ios_capture_fixture if @realistic_ios_capture_fixture

      temp_parent = ENV["QUAKESIGNAL_TEST_TEMP_ROOT"] || ENV["RUNNER_TEMP"] || ENV["TMPDIR"] || Dir.tmpdir
      temp_parent = Pathname.new(temp_parent).realpath
      cache = Pathname.new(Dir.mktmpdir("quakesignal-realistic-ios-assembler-fixture", temp_parent.to_s))
      destination = cache.join("capture")
      fixture_test = SOURCE_ROOT.join("ios/ScreenshotAutomation/assemble-ios-screenshot-provenance.test.rb")
      script = <<~'RUBY'
        require "fileutils"
        require "pathname"
        fixture_test, requested_destination = ARGV
        ARGV.replace(["--name", "/__no_autorun_tests__/"])
        require fixture_test
        destination = Pathname.new(requested_destination)
        helper = IOSScreenshotProvenanceTest.new("fixture")
        helper.send(:with_capture_fixture) do |capture_root, output|
          helper.send(:assemble, capture_root, output)
          destination.mkpath
          capture_root.children.each do |entry|
            FileUtils.cp_r(entry, destination, preserve: true)
          end
          FileUtils.cp(output, destination.join("capture-provenance.json"), preserve: true)
        end
        exit! 0
      RUBY
      success = system(
        RbConfig.ruby,
        "-e",
        script,
        fixture_test.to_s,
        destination.to_s,
        out: File::NULL,
        err: File::NULL,
      )
      raise "failed to build current realistic iOS provenance fixture" unless success && destination.directory?

      @realistic_ios_capture_fixture = destination.realpath
      Minitest.after_run do
        FileUtils.remove_entry(cache) if cache.directory? && !cache.symlink?
      end
      @realistic_ios_capture_fixture
    end

    def realistic_platform_capture_fixture(platform)
      @realistic_platform_capture_fixtures ||= {}
      return @realistic_platform_capture_fixtures.fetch(platform) if @realistic_platform_capture_fixtures.key?(platform)

      temp_parent = ENV["QUAKESIGNAL_TEST_TEMP_ROOT"] || ENV["RUNNER_TEMP"] || ENV["TMPDIR"] || Dir.tmpdir
      temp_parent = Pathname.new(temp_parent).realpath
      cache = Pathname.new(Dir.mktmpdir("quakesignal-realistic-#{platform}-assembler-fixture", temp_parent.to_s))
      destination = cache.join("capture")
      fixture_test = SOURCE_ROOT.join("ios/ScreenshotAutomation/assemble-platform-screenshot-provenance.test.rb")
      script = <<~'RUBY'
        require "fileutils"
        require "pathname"
        fixture_test, requested_destination, platform = ARGV
        ARGV.replace(["--name", "/__no_autorun_tests__/"])
        require fixture_test
        destination = Pathname.new(requested_destination)
        helper = PlatformScreenshotProvenanceTest.new("fixture")
        helper.send(:with_capture_fixture, platform) do |capture_root, output|
          plan = QuakeSignalPlatformScreenshotPlan.load(platform, repository_root: PlatformScreenshotProvenanceTest::ROOT)
          plan.fetch("frames").each do |frame|
            path = capture_root.join("frame-capture-evidence/#{frame.fetch('captureSelector')}.json")
            evidence = JSON.parse(path.read)
            evidence["selectedSimulator"].merge!(
              "runtimeIdentifier" => "com.apple.CoreSimulator.SimRuntime.#{platform}-26-5",
              "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.#{platform}-reviewed",
              "deviceModel" => "Reviewed #{platform} Simulator",
            )
            path.write(JSON.pretty_generate(evidence) + "\n")
          end
          helper.send(:assemble, platform, capture_root, output)
          destination.mkpath
          capture_root.children.each do |entry|
            FileUtils.cp_r(entry, destination, preserve: true)
          end
          FileUtils.cp(output, destination.join("capture-provenance.json"), preserve: true)
        end
        exit! 0
      RUBY
      success = system(
        RbConfig.ruby, "-e", script, fixture_test.to_s, destination.to_s, platform,
        out: File::NULL, err: File::NULL,
      )
      raise "failed to build current realistic #{platform} provenance fixture" unless success && destination.directory?

      @realistic_platform_capture_fixtures[platform] = destination.realpath
      Minitest.after_run { FileUtils.remove_entry(cache) if cache.directory? && !cache.symlink? }
      @realistic_platform_capture_fixtures.fetch(platform)
    end

    def realistic_maccatalyst_capture_fixture
      return @realistic_maccatalyst_capture_fixture if @realistic_maccatalyst_capture_fixture

      temp_parent = ENV["QUAKESIGNAL_TEST_TEMP_ROOT"] || ENV["RUNNER_TEMP"] || ENV["TMPDIR"] || Dir.tmpdir
      temp_parent = Pathname.new(temp_parent).realpath
      cache = Pathname.new(Dir.mktmpdir("quakesignal-realistic-maccatalyst-assembler-fixture", temp_parent.to_s))
      destination = cache.join("capture")
      fixture_test = SOURCE_ROOT.join("ios/ScreenshotAutomation/assemble-maccatalyst-screenshot-provenance.test.rb")
      script = <<~'RUBY'
        require "fileutils"
        require "pathname"
        fixture_test, requested_destination = ARGV
        ARGV.replace(["--name", "/__no_autorun_tests__/"])
        require fixture_test
        destination = Pathname.new(requested_destination)
        helper = MacCatalystScreenshotProvenanceTest.new("fixture")
        helper.send(:with_capture_fixture) do |capture_root, output|
          helper.send(:assemble, capture_root, output)
          destination.mkpath
          capture_root.children.each do |entry|
            FileUtils.cp_r(entry, destination, preserve: true)
          end
          FileUtils.cp(output, destination.join("capture-provenance.json"), preserve: true)
        end
        exit! 0
      RUBY
      success = system(
        RbConfig.ruby, "-e", script, fixture_test.to_s, destination.to_s,
        out: File::NULL, err: File::NULL,
      )
      unless success && destination.directory?
        raise "failed to build current realistic Mac Catalyst provenance fixture"
      end

      @realistic_maccatalyst_capture_fixture = destination.realpath
      Minitest.after_run { FileUtils.remove_entry(cache) if cache.directory? && !cache.symlink? }
      @realistic_maccatalyst_capture_fixture
    end
  end

  def setup
    temp_root = ENV["QUAKESIGNAL_TEST_TEMP_ROOT"] || ENV["RUNNER_TEMP"] || ENV["TMPDIR"] || Dir.tmpdir
    temp_root = Pathname.new(temp_root).realpath
    raise "test temp root must be a plain directory" unless temp_root.directory? && !temp_root.symlink?

    @temporary_directory = Dir.mktmpdir("quakesignal-release-assembler-test", temp_root.to_s)
    @temporary_root = Pathname.new(@temporary_directory)
    @root = @temporary_root.join("repository")
    @captures = @temporary_root.join("captures")
    @archives = @temporary_root.join("archives")
    @root.mkpath
    @captures.mkpath
    @archives.mkpath
    copy_contract_files
    @source_guard = FakeAppleScreenshotAssemblySourceGuard.new
    @packages = build_capture_packages
    @output = @root.join(AppleScreenshotReleaseSetAssembler::RELEASE_ROOT, SOURCE_COMMIT)
    @index_parent = @temporary_root.join("index-candidates")
    @index_parent.mkpath
    @index_candidate = @index_parent.join("screenshot-set-index.candidate.json")
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory) if @temporary_directory && File.exist?(@temporary_directory)
  end

  def test_assembles_atomic_unapproved_five_platform_release_set_and_index_candidate
    result = assembler.assemble(
      source_commit: SOURCE_COMMIT,
      output: @output,
      index_candidate: @index_candidate,
      packages: @packages,
    )

    assert @output.directory?
    assert @index_candidate.file?
    refute @output.join("release-approval.json").exist?
    release = result.fetch(:release_set)
    assert_equal "source-frozen-unapproved", release.fetch("status")
    assert_equal false, release.fetch("uploadApproved")
    assert_equal 26, release.fetch("totalFrameCount")
    assert_equal AppleScreenshotReleaseSetAssembler::PLATFORMS,
                 release.fetch("packages").map { |record| record.fetch("platform") }
    assert_equal 1, @source_guard.validations.length
    assert_equal AppleScreenshotReleaseSetAssembler::PLAN_PATHS.values,
                 @source_guard.validations.first.fetch(1).map { |record| record.fetch("file") }

    release.fetch("packages").each do |package|
      platform = package.fetch("platform")
      package_root = @output.join(platform)
      metadata = JSON.parse(package_root.join("package-provenance.json").read)
      assert_equal false, metadata.fetch("uploadApproved")
      assert_equal "unapproved-source-frozen-candidate", metadata.fetch("status")
      assert_equal "Debug", metadata.fetch("configuration")
      assert metadata.fetch("evidenceFiles").length >= 3
      artifact = @packages.fetch(platform).fetch(:artifact)
      assert_equal Digest::SHA256.file(artifact).hexdigest, metadata.fetch("artifactSha256")
      assert_equal artifact.binread, package_root.join(metadata.fetch("artifactFile")).binread
      assert_equal package.fetch("contentManifestSha256"), package_content_sha(package_root)
    end

    catalyst_metadata = JSON.parse(
      @output.join("maccatalyst/package-provenance.json").read,
    )
    catalyst_environment = catalyst_metadata.fetch("captureEnvironment")
    assert_equal "maccatalyst-uikit-hierarchy", catalyst_environment.fetch("kind")
    assert_equal "UIKit.UIView.drawHierarchy", catalyst_environment.fetch("captureApi")
    assert_equal "live-catalyst-uiwindow-hierarchy", catalyst_environment.fetch("captureSurface")
    assert_equal [1_280, 800], catalyst_environment.fetch("logicalViewPoints")
    assert catalyst_environment.fetch("sourceDisplayScale").positive?
    assert_equal 2, catalyst_environment.fetch("rasterizationScale")
    assert_equal [2_560, 1_600], catalyst_environment.fetch("pixels")
    assert_equal true, catalyst_environment.fetch("afterScreenUpdates")
    assert_equal false, catalyst_environment.fetch("postCaptureResizePerformed")
    catalyst_metadata.fetch("frames").each do |frame|
      evidence = frame.fetch("captureEvidence")
      assert_equal "UIKit.UIView.drawHierarchy", evidence.fetch("captureApi")
      assert_equal "live-catalyst-uiwindow-hierarchy", evidence.fetch("captureSurface")
      assert_equal [1_280, 800], evidence.fetch("logicalViewPoints")
      assert_equal [2_560, 1_600], evidence.fetch("pixels")
      assert_equal 2, evidence.fetch("rasterizationScale")
      assert_equal false, evidence.fetch("postCaptureResizePerformed")
      assert_equal "standard", evidence.fetch("rendererPreferredRange")
      %w[requestFile responseFile rawFile].each do |field|
        assert_match(%r{\Aevidence/raw-capture/}, evidence.fetch(field))
        assert @output.join("maccatalyst", evidence.fetch(field)).file?
      end
    end

    candidate = JSON.parse(@index_candidate.read)
    active = candidate.fetch("activeReleaseSet")
    assert_equal SOURCE_COMMIT, active.fetch("sourceCommit")
    assert_nil active.fetch("approvalFile")
    assert_nil active.fetch("approvalSha256")
    refute @index_candidate.read.include?("approved-for-build8-upload")
    refute @index_candidate.read.include?("signedReleaseParityApproved")
  end

  def test_rejects_any_premature_reviewer_approval_or_release_binary_claim
    mutate_aggregate("ios-ipados") { |aggregate| aggregate["reviewer"] = "Premature Reviewer" }
    assert_rejected(/full aggregate provenance mismatch|aggregate reviewer/)

    reset_output_state
    mutate_aggregate("maccatalyst") { |aggregate| aggregate["releaseBinaryEvidence"] = { "approved" => true } }
    assert_rejected(/full aggregate provenance mismatch|releaseBinaryEvidence/)
  end

  def test_rejects_mixed_source_commit_or_plan_hash
    path = @captures.join("watchos/source-address.json")
    record = JSON.parse(path.read)
    record.fetch("source")["commit"] = "b" * 40
    write_json(path, record)
    reseal("watchos")
    assert_rejected(/capture source commit/)

    reset_output_state
    mutate_aggregate("visionos") do |aggregate|
      aggregate.fetch("planManifest")["sha256"] = "f" * 64
    end
    assert_rejected(/full aggregate provenance mismatch|plan (?:binding|hash)/)
  end

  def test_rejects_duplicate_or_locked_historical_frame_bytes
    first = @captures.join("tvos/en-US/01-dashboard.png")
    second = @captures.join("tvos/en-US/02-recent-reports.png")
    second.binwrite(first.binread)
    update_frame_hash("tvos", "tvos-recent-reports", second)
    reseal("ios-ipados")
    assert_rejected(/screenshotSha256|byte-distinct/)

    reset_output_state
    historical_hash = Digest::SHA256.file(
      @captures.join("tvos/en-US/01-dashboard.png"),
    ).hexdigest
    assert_rejected(
      /reuse locked historical/,
      custom_assembler: assembler(historical: Set[historical_hash]),
    )
  end

  def test_rejects_tampered_unsealed_extra_or_symlinked_capture_evidence
    @captures.join("tvos/unsealed-extra.txt").write("extra\n")
    assert_rejected(/capture package bytes differ/)

    reset_output_state
    @captures.join("visionos/symlink-evidence").make_symlink(
      @captures.join("visionos/source-address.json"),
    )
    assert_rejected(/symlink or special/)
  end

  def test_rejects_archive_inside_capture_root_and_existing_output_or_index
    inside = @captures.join("ios-ipados/archive.bin")
    inside.write("archive\n")
    reseal("ios-ipados")
    @packages.fetch("ios-ipados")[:artifact] = inside
    assert_rejected(/independent of the raw capture directory/)

    reset_output_state
    @output.mkpath
    assert_rejected(/release-set output already exists/, expect_output_absent: false)

    FileUtils.remove_entry(@output)
    @index_candidate.write("existing\n")
    assert_rejected(/index candidate already exists/, expect_index_absent: false)
  end

  def test_rejects_index_candidate_inside_output_or_any_repository_path
    @index_candidate = @output.join("candidate.json")
    assert_rejected(/outside the repository and release-set output/)

    @index_candidate = @root.join("candidate.json")
    assert_rejected(/outside the repository and release-set output/)
  end

  def test_rejects_missing_platform_appropriate_non_frame_evidence
    FileUtils.remove_entry(@captures.join("ios-ipados/build-bindings"))
    reseal("ios-ipados")
    assert_rejected(/build binding is missing|lacks required non-frame evidence: build-bindings/)

    reset_output_state
    FileUtils.remove_entry(@captures.join("watchos/frame-capture-evidence"))
    reseal("watchos")
    assert_rejected(/capture inventory differs|lacks required non-frame evidence: frame-capture-evidence/)
  end

  def test_rejects_arbitrary_or_semantically_different_archived_artifact
    @packages.fetch("ios-ipados").fetch(:artifact).binwrite("hello\n")
    assert_rejected(/not a ZIP/)

    reset_output_state
    capture_root = @captures.join("watchos")
    extra = capture_root.join("archive-only-extra.txt")
    extra.write("not in the sealed package\n")
    archive_capture_root("watchos")
    extra.delete
    assert_rejected(/archive file inventory/)
  end

  def test_rejects_unsupported_central_or_local_zip_flags
    artifact = @packages.fetch("ios-ipados").fetch(:artifact)
    mutate_zip_flag(artifact, location: :central)
    assert_rejected(/unsupported flags/)

    reset_output_state
    artifact = @packages.fetch("ios-ipados").fetch(:artifact)
    mutate_zip_flag(artifact, location: :local)
    assert_rejected(/local entry uses unsupported flags/)
  end

  def test_rejects_trailing_data_after_a_complete_deflate_stream
    artifact = @packages.fetch("ios-ipados").fetch(:artifact)
    append_trailing_deflate_data(artifact)
    assert_rejected(/trailing deflate data|not one exact deflate stream/)
  end

  def test_rejects_arbitrary_local_sizes_on_descriptor_backed_entry
    artifact = @packages.fetch("ios-ipados").fetch(:artifact)
    mutate_zip_descriptor_local_sizes(artifact)
    assert_rejected(/local\/central entry sizes mismatch|local sizes mismatch/)
  end

  def test_rejects_nonzero_central_or_local_directory_records
    artifact = @packages.fetch("ios-ipados").fetch(:artifact)
    mutate_zip_directory_size(artifact, location: :central)
    assert_rejected(/directory entries must be zero-byte stored records/)

    reset_output_state
    artifact = @packages.fetch("ios-ipados").fetch(:artifact)
    mutate_zip_directory_size(artifact, location: :local)
    assert_rejected(/local directory entry must be a zero-byte stored record/)
  end

  def test_rejects_archive_unix_mode_mismatch
    artifact = @packages.fetch("ios-ipados").fetch(:artifact)
    mutate_zip_file_mode(artifact)
    assert_rejected(/archive .* mode mismatch/)
  end

  def test_bounds_inflate_before_accepting_a_lying_declared_size
    path = @temporary_root.join("declared-size-expansion-bomb.bin")
    source = "A" * 20_000_000
    compressor = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -Zlib::MAX_WBITS)
    compressed = compressor.deflate(source, Zlib::FINISH)
    compressor.close
    name = "bomb.txt"
    header = [
      0x04034b50, 20, 0, 8, 0, 0, Zlib.crc32(source), compressed.bytesize, 1,
      name.bytesize, 0,
    ].pack("VvvvvvVVVvv")
    path.binwrite(header + name + compressed)
    entry = {
      name: name,
      flags: 0,
      method: 8,
      crc32: Zlib.crc32(source),
      compressed_size: compressed.bytesize,
      uncompressed_size: 1,
      local_offset: 0,
    }

    error = assert_raises(AppleScreenshotReleaseSetAssemblyError) do
      assembler.send(:read_zip_entry_bytes!, path, entry, "test")
    end
    assert_match(/exceeds its declared uncompressed size/, error.message)
  end

  def test_rejects_duplicate_json_keys_and_never_publishes_partial_output
    path = @captures.join("tvos/capture-provenance.json")
    source = path.read.sub(
      %Q[  "status": "unapproved-debug-simulator-capture-set-evidence",\n],
      %Q[  "status": "unapproved-debug-simulator-capture-set-evidence",\n  "status": "unapproved-debug-simulator-capture-set-evidence",\n],
    )
    path.write(source)
    reseal("tvos")
    assert_rejected(/duplicate JSON object key/)
    refute @output.exist?
    refute @index_candidate.exist?
  end

  def test_rejects_source_mutation_after_normalization_before_stage_copy
    frame = @captures.join("ios-ipados/en-US/iphone-6.5/01-home.jpg")
    mutating = assembler(
      before_stage_copy: lambda do |_packages|
        frame.binwrite("mutated after normalization\n")
      end,
    )
    assert_rejected(/staged frame .* (?:size|SHA-256)/, custom_assembler: mutating)

    reset_output_state
    artifact = @packages.fetch("watchos").fetch(:artifact)
    mutating = assembler(
      before_stage_copy: lambda do |_packages|
        artifact.open("ab") { |file| file.write("mutated after normalization\n") }
      end,
    )
    assert_rejected(/staged capture artifact (?:source )?(?:size|SHA-256)/, custom_assembler: mutating)
  end

  def test_rejects_source_mode_mutation_after_normalization_before_stage_copy
    evidence = @captures.join("watchos/frame-capture-evidence/watchos-headline.json")
    original_mode = evidence.lstat.mode & 0o7777
    changed_mode = original_mode == 0o600 ? 0o644 : 0o600
    mutating = assembler(
      before_stage_copy: lambda do |_packages|
        evidence.chmod(changed_mode)
      end,
    )
    assert_rejected(/staged raw evidence .* source mode/, custom_assembler: mutating)
  end

  def test_rejects_resealed_ios_native_and_catalyst_provenance_forgeries
    mutate_aggregate("ios-ipados") do |aggregate|
      aggregate.fetch("frames").first["purpose"] = "Self-resealed aggregate forgery"
    end
    assert_rejected(/ios-ipados full aggregate provenance mismatch/)

    reset_output_state
    native_selector = "watchos-headline"
    native_evidence = @captures.join("watchos/frame-capture-evidence/#{native_selector}.json")
    native_record = JSON.parse(native_evidence.read)
    native_record["forgedEvidence"] = true
    write_json(native_evidence, native_record)
    update_aggregate_frame_evidence_hash("watchos", native_selector, native_evidence)
    reseal("watchos")
    assert_rejected(/watchos full aggregate provenance validation failed/)

    reset_output_state
    catalyst_selector = "maccatalyst-home"
    semantic = @captures.join("maccatalyst/semantic-evidence/#{catalyst_selector}.json")
    semantic_record = JSON.parse(semantic.read)
    semantic_record.fetch("checks")["matchedForbiddenSystemPromptGroups"] = [["Allow", "Don’t Allow"]]
    write_json(semantic, semantic_record)
    cascade_catalyst_evidence_hashes(catalyst_selector, semantic)
    reseal("maccatalyst")
    assert_rejected(/maccatalyst full aggregate provenance validation failed/)
  end

  def test_catalyst_release_projection_rejects_screen_capture_and_non_2x_rasterization
    capture_root = @captures.join("maccatalyst")
    aggregate = JSON.parse(capture_root.join("capture-provenance.json").read)
    frame = aggregate.fetch("frames").first

    screen_capture = Marshal.load(Marshal.dump(frame))
    screen_capture.fetch("nativeCapture")["captureApi"] = "ScreenCaptureKit.SCScreenshotManager"
    error = assert_raises(AppleScreenshotReleaseSetAssemblyError) do
      assembler.send(
        :normalize_maccatalyst_capture_evidence!,
        screen_capture,
        capture_root,
        0,
      )
    end
    assert_match(/capture API mismatch/, error.message)

    resized = Marshal.load(Marshal.dump(frame))
    resized["rasterizationScale"] = 1
    resized.fetch("captureRequest")["rasterizationScale"] = 1
    resized.fetch("nativeCapture")["rasterizationScale"] = 1
    error = assert_raises(AppleScreenshotReleaseSetAssemblyError) do
      assembler.send(
        :normalize_maccatalyst_capture_evidence!,
        resized,
        capture_root,
        0,
      )
    end
    assert_match(/rasterization scale mismatch/, error.message)
  end

  def test_rejects_forbidden_approval_sentinel_in_rehashed_non_json_evidence
    selector = "maccatalyst-home"
    log = @captures.join("maccatalyst/app-logs/#{selector}.log")
    log.open("ab") { |file| file.write("approved-for-build8-upload\n") }
    cascade_catalyst_evidence_hashes(selector, log)
    reseal("maccatalyst")
    assert_rejected(/forbidden approval or signed-parity sentinel/)
  end

  def test_rejects_normalized_approval_sentinel_split_across_chunk_and_long_punctuation
    selector = "maccatalyst-home"
    log = @captures.join("maccatalyst/app-logs/#{selector}.log")
    log.binwrite(("a" * 65_330) + "signed" + ("-" * 200) + "releaseparityapproved")
    cascade_catalyst_evidence_hashes(selector, log)
    reseal("maccatalyst")
    assert_rejected(/forbidden approval or signed-parity sentinel/)
  end

  def test_rejects_normalized_plain_text_upload_approval_claim
    selector = "maccatalyst-home"
    log = @captures.join("maccatalyst/app-logs/#{selector}.log")
    log.open("ab") { |file| file.write("Release reviewer says: APPROVED FOR BUILD8 UPLOAD\n") }
    cascade_catalyst_evidence_hashes(selector, log)
    reseal("maccatalyst")
    assert_rejected(/forbidden approval or signed-parity sentinel/)
  end

  def test_output_and_index_publication_are_no_clobber_after_absence_checks
    output_attacker = "attacker output target\n"
    output_racer = assembler(
      publish_hook: lambda do |phase, _context|
        next unless phase == :after_output_target_absence_check

        @output.mkdir
        @output.join("sentinel.txt").write(output_attacker)
      end,
    )
    assert_rejected(/File exists|publication/, custom_assembler: output_racer, expect_output_absent: false)
    assert_equal output_attacker, @output.join("sentinel.txt").read
    refute @index_candidate.exist?

    reset_output_state
    index_attacker = "attacker index target\n"
    index_racer = assembler(
      publish_hook: lambda do |phase, _context|
        next unless phase == :after_index_target_absence_check

        @index_candidate.write(index_attacker)
      end,
    )
    assert_rejected(/File exists|publication/, custom_assembler: index_racer, expect_index_absent: false)
    assert_equal index_attacker, @index_candidate.read
    refute @output.exist?
  end

  def test_stage_inode_swaps_are_detected_without_deleting_replacements
    displaced_stage = @temporary_root.join("displaced-release-stage")
    replacement = "attacker replacement stage\n"
    output_racer = assembler(
      publish_hook: lambda do |phase, context|
        next unless phase == :after_output_stage_identity_check

        File.rename(context.fetch(:stage), displaced_stage)
        context.fetch(:stage).mkdir
        context.fetch(:stage).join("sentinel.txt").write(replacement)
      end,
    )
    assert_rejected(/published release set identity mismatch/, custom_assembler: output_racer,
                    expect_output_absent: false)
    assert_equal replacement, @output.join("sentinel.txt").read
    assert displaced_stage.join("release-set.json").file?

    reset_output_state
    displaced_candidate = @temporary_root.join("displaced-index-stage.json")
    index_replacement = "attacker replacement candidate\n"
    index_racer = assembler(
      publish_hook: lambda do |phase, context|
        next unless phase == :after_index_stage_identity_check

        File.rename(context.fetch(:candidate_stage), displaced_candidate)
        context.fetch(:candidate_stage).write(index_replacement)
      end,
    )
    assert_rejected(/published index candidate identity mismatch/, custom_assembler: index_racer,
                    expect_index_absent: false)
    assert_equal index_replacement, @index_candidate.read
    assert_match(/activeReleaseSet/, displaced_candidate.read)
    refute @output.exist?
  end

  def test_parent_exchange_and_symlink_races_preserve_recovery_and_attacker_material
    displaced_output_parent = @temporary_root.join("displaced-output-parent")
    output_sentinel = "attacker output parent\n"
    output_racer = assembler(
      publish_hook: lambda do |phase, context|
        next unless phase == :after_output_publish

        File.rename(context.fetch(:output_parent), displaced_output_parent)
        context.fetch(:output_parent).mkdir
        context.fetch(:output_parent).join("sentinel.txt").write(output_sentinel)
      end,
    )
    assert_rejected(/output parent after publish identity changed/, custom_assembler: output_racer)
    assert_equal output_sentinel, @output.dirname.join("sentinel.txt").read
    assert displaced_output_parent.children.any? { |path| path.basename.to_s.start_with?(".quakesignal-recovery.") }

    FileUtils.remove_entry(@output.dirname)
    File.rename(displaced_output_parent, @output.dirname)
    reset_output_state

    displaced_index_parent = @temporary_root.join("displaced-index-parent")
    attacker_index_parent = @temporary_root.join("attacker-index-parent")
    index_sentinel = "attacker symlink destination\n"
    index_racer = assembler(
      publish_hook: lambda do |phase, context|
        next unless phase == :after_index_publish

        File.rename(context.fetch(:index_parent), displaced_index_parent)
        attacker_index_parent.mkdir
        attacker_index_parent.join("sentinel.txt").write(index_sentinel)
        context.fetch(:index_parent).make_symlink(attacker_index_parent)
      end,
    )
    assert_rejected(/index candidate parent after publish/, custom_assembler: index_racer)
    assert_equal index_sentinel, attacker_index_parent.join("sentinel.txt").read
    assert displaced_index_parent.children.any? { |path| path.basename.to_s.start_with?(".quakesignal-recovery.") }
    refute @output.exist?
  end

  def test_rejects_rehashed_aggregate_or_frame_extra_keys_and_hidden_approval_material
    mutate_aggregate("tvos") { |aggregate| aggregate["marketingApproval"] = nil }
    assert_rejected(/full aggregate provenance mismatch|aggregate keys/)

    reset_output_state
    mutate_aggregate("maccatalyst") do |aggregate|
      aggregate.fetch("frames").first["unreviewedExtra"] = "rehashed"
    end
    assert_rejected(/full aggregate provenance mismatch|aggregate frame 0 keys/)

    reset_output_state
    path = @captures.join("visionos/frame-capture-evidence/visionos-home.json")
    record = JSON.parse(path.read)
    record["nestedClaim"] = { "signedReleaseParityApproved" => true }
    write_json(path, record)
    reseal("visionos")
    assert_rejected(/full aggregate provenance validation failed|hidden reviewer, approval, signed, or release-binary material/)
  end

  def test_requires_referenced_ios_simulator_cleanup_evidence
    @captures.join("ios-ipados/simulator-cleanup-evidence.json").delete
    reseal("ios-ipados")
    assert_rejected(/capture inventory|simulator cleanup evidence|lacks required non-frame evidence/)
  end

  private

  def assembler(historical: Set.new, before_stage_copy: nil, publish_hook: nil)
    AppleScreenshotReleaseSetAssembler.new(
      root: @root,
      image_inspector: FakeAppleScreenshotAssemblyInspector.new,
      source_guard: @source_guard,
      index_validator: -> {},
      historical_frame_sha256s: historical,
      before_stage_copy: before_stage_copy,
      publish_hook: publish_hook,
      ios_provenance_repository_root: SOURCE_ROOT,
      ios_provenance_image_inspector: FakeIOSAssemblyProvenanceImageInspector.new,
      ios_provenance_result_inspector: FakeIOSAssemblyProvenanceResultInspector.new,
    )
  end

  def assert_rejected(
    pattern,
    custom_assembler: assembler,
    expect_output_absent: true,
    expect_index_absent: true
  )
    error = assert_raises(AppleScreenshotReleaseSetAssemblyError) do
      custom_assembler.assemble(
        source_commit: SOURCE_COMMIT,
        output: @output,
        index_candidate: @index_candidate,
        packages: @packages,
      )
    end
    assert_match pattern, error.message
    refute @output.exist? if expect_output_absent
    refute @index_candidate.exist? if expect_index_absent
  end

  def reset_output_state
    FileUtils.remove_entry(@output) if @output.exist?
    @index_candidate.delete if @index_candidate.exist?
    @packages = build_capture_packages
    @source_guard = FakeAppleScreenshotAssemblySourceGuard.new
  end

  def copy_contract_files
    files = [
      AppleScreenshotReleaseSetAssembler::INDEX_PATH,
      *AppleScreenshotReleaseSetAssembler::PLAN_PATHS.values,
    ]
    files.each do |relative|
      destination = @root.join(relative)
      destination.dirname.mkpath
      FileUtils.cp(SOURCE_ROOT.join(relative), destination)
    end
  end

  def build_capture_packages
    FileUtils.remove_entry(@captures) if @captures.exist?
    FileUtils.remove_entry(@archives) if @archives.exist?
    @captures.mkpath
    @archives.mkpath
    AppleScreenshotReleaseSetAssembler::PLATFORMS.to_h do |platform|
      capture_root = @captures.join(platform)
      capture_root.mkpath
      fixture = case platform
                when "ios-ipados" then self.class.realistic_ios_capture_fixture
                when "maccatalyst" then self.class.realistic_maccatalyst_capture_fixture
                else self.class.realistic_platform_capture_fixture(platform)
                end
      fixture.children.each do |entry|
        FileUtils.cp_r(entry, capture_root, preserve: true)
      end
      aggregate = JSON.parse(capture_root.join("capture-provenance.json").read)
      if %w[tvos watchos visionos].include?(platform)
        write_source_address(capture_root, platform, aggregate.fetch("planManifest"))
      end
      QuakeSignalScreenshotCapturePackageSeal.seal(
        platform: platform,
        source_commit: SOURCE_COMMIT,
        capture_root: capture_root,
        output: capture_root.join("capture-package-manifest.json"),
      )
      archive = archive_capture_root(platform)
      [platform, { capture_root: capture_root, artifact: archive }]
    end
  end

  def build_aggregate(capture_root, platform)
    plan_file = AppleScreenshotReleaseSetAssembler::PLAN_PATHS.fetch(platform)
    plan = {
      "file" => plan_file,
      "sha256" => Digest::SHA256.file(@root.join(plan_file)).hexdigest,
    }
    frames = AppleScreenshotReleaseSetAssembler::FRAME_SPECS.fetch(platform).map.with_index do |specification, index|
      path = capture_root.join(specification.fetch("file"))
      path.dirname.mkpath
      path.binwrite("unique frame #{platform} #{index}\n")
      frame = {
        "captureSelector" => specification.fetch("captureSelector"),
        "file" => specification.fetch("file"),
        "screen" => "Reviewed screen #{index}",
        "purpose" => "Reviewed purpose #{index}",
        "setup" => "Reviewed setup #{index}",
        "pixels" => specification.fetch("pixels"),
        "sha256" => Digest::SHA256.file(path).hexdigest,
      }
      if %w[tvos watchos visionos].include?(platform)
        frame["selectedSimulator"] = {
          "runtimeIdentifier" => "com.apple.CoreSimulator.SimRuntime.#{platform}-26-5",
          "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.#{platform}-reviewed",
          "deviceModel" => "Reviewed #{platform} Simulator",
          "udid" => "#{platform}-device-#{index}",
        }
        frame["captureEvidenceFile"] = "frame-capture-evidence/#{specification.fetch('captureSelector')}.json"
        frame["captureEvidenceSha256"] = "c" * 64
        frame["capturedAtUtc"] = format("2026-08-21T01:%02d:00Z", index)
      elsif platform == "ios-ipados"
        source = {
          "commit" => SOURCE_COMMIT,
          "treeState" => "clean",
          "debugLocalOverridePresent" => false,
        }
        frame.delete("setup")
        frame.merge!(
          "displayClass" => specification.fetch("file").split("/").fetch(1),
          "format" => "jpeg",
          "hasAlpha" => false,
          "rawFile" => "raw-simulator-captures/#{specification.fetch('captureSelector')}.png",
          "rawSha256" => "d" * 64,
          "captureWindowUtc" => {
            "startedAt" => "2026-08-21T01:00:00Z",
            "completedAt" => "2026-08-21T01:30:00Z",
          },
          "source" => source,
          "product" => { "bundleIdentifier" => "com.quakesignal.app" },
          "captureEnvironment" => { "deviceIdentifier" => "fixture-device-#{index}" },
          "app" => { "bundleName" => "QuakeSignal.app" },
          "build" => { "configuration" => "Debug" },
          "buildSource" => { "sourceCommit" => SOURCE_COMMIT },
          "buildBinding" => { "sourceCommit" => SOURCE_COMMIT },
          "installEvidence" => { "file" => "install-evidence/#{specification.fetch('captureSelector')}.json" },
          "launchEvidence" => { "file" => "launch-evidence/#{specification.fetch('captureSelector')}.json" },
          "semanticValidation" => { "status" => "accepted" },
          "transformation" => { "resizePerformed" => false },
          "frameCaptureEvidenceFile" => "frame-capture-evidence/#{specification.fetch('captureSelector')}.json",
          "frameCaptureEvidenceSha256" => "e" * 64,
          "reviewer" => nil,
          "approval" => nil,
        )
      else
        frame.merge!(
          "rawSha256" => "f" * 64,
          "capturedAtUtc" => format("2026-08-21T01:%02d:00Z", index),
          "source" => { "commit" => SOURCE_COMMIT, "treeState" => "clean" },
          "product" => { "bundleIdentifier" => "com.quakesignal.app" },
          "host" => { "hardwareModel" => "Mac16,1" },
          "app" => { "bundleName" => "QuakeSignal.app" },
          "processId" => index + 100,
          "windowId" => index + 200,
          "logicalFrame" => [0, 0, 1280, 800],
          "backingScale" => 2,
          "nativeCapture" => { "status" => "accepted" },
          "semanticValidation" => { "status" => "accepted" },
          "frameCaptureEvidenceFile" => "frame-capture-evidence/#{specification.fetch('captureSelector')}.json",
          "frameCaptureEvidenceSha256" => "1" * 64,
          "reviewer" => nil,
          "approval" => nil,
        )
      end
      frame
    end
    common = {
      "schemaVersion" => platform == "ios-ipados" ? 1 : 2,
      "status" => AppleScreenshotReleaseSetAssembler::AGGREGATE_STATUS.fetch(platform),
      "uploadApproved" => false,
      "reviewer" => nil,
      "releaseBinaryEvidence" => nil,
      "platform" => platform,
      "locale" => "en-US",
      "fixture" => "finalized-historical-reports",
      "planManifest" => plan,
      "captureWindowUtc" => {
        "startedAt" => "2026-08-21T01:00:00Z",
        "completedAt" => "2026-08-21T01:30:00Z",
      },
      "frames" => frames,
      "approvalRequired" => "Named visual review and signed Release parity comparison",
    }
    case platform
    when "ios-ipados"
      cleanup = capture_root.join("simulator-cleanup-evidence.json")
      write_json(
        cleanup,
        {
          "schemaVersion" => 1,
          "status" => "simulators-verified-absent",
          "uploadApproved" => false,
          "reviewer" => nil,
        },
      )
      common.merge(
        "approval" => nil,
        "source" => {
          "commit" => SOURCE_COMMIT,
          "treeState" => "clean",
          "debugLocalOverridePresent" => false,
        },
        "captureEnvironment" => {
          "xcodeVersion" => "Xcode 26.6 Build 17G86",
          "operatingSystem" => "26.6.2 (25G91)",
          "runtimeIdentifier" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
          "devices" => [
            { "displayClass" => "iphone-6.5", "deviceIdentifier" => "iphone-device", "deviceModel" => "iPhone 11 Pro Max" },
            { "displayClass" => "ipad-13", "deviceIdentifier" => "ipad-device", "deviceModel" => "iPad Pro 13-inch (M4)" },
          ],
        },
        "product" => { "bundleIdentifier" => "com.quakesignal.app" },
        "app" => { "bundleName" => "QuakeSignal.app" },
        "buildSource" => { "sourceCommit" => SOURCE_COMMIT },
        "buildBinding" => { "sourceCommit" => SOURCE_COMMIT },
        "simulatorCleanupEvidence" => {
          "file" => "simulator-cleanup-evidence.json",
          "sha256" => Digest::SHA256.file(cleanup).hexdigest,
        },
      )
    when "maccatalyst"
      common.merge(
        "schemaVersion" => 1,
        "approval" => nil,
        "source" => { "commit" => SOURCE_COMMIT, "treeState" => "clean" },
        "host" => {
          "xcodeVersion" => "26.6",
          "xcodeBuild" => "17G86",
          "macOSVersion" => "26.6.2",
          "macOSBuild" => "25G91",
          "hardwareModel" => "Mac16,1",
        },
        "product" => { "bundleIdentifier" => "com.quakesignal.app" },
        "app" => { "bundleName" => "QuakeSignal.app" },
      )
    else
      common
    end
  end

  def write_source_address(capture_root, platform, plan)
    write_json(
      capture_root.join("source-address.json"),
      {
        "schemaVersion" => 1,
        "status" => "unapproved-source-addressed-native-capture-evidence",
        "uploadApproved" => false,
        "reviewer" => nil,
        "platform" => platform,
        "source" => {
          "commit" => SOURCE_COMMIT,
          "treeState" => "clean",
          "debugLocalOverridePresent" => false,
        },
        "planManifest" => plan,
        "host" => {
          "xcodeVersion" => "Xcode 26.6 Build 17G86",
          "operatingSystem" => "26.6.2 (25G91)",
        },
      },
    )
  end

  def write_independent_capture_evidence(capture_root, platform)
    paths = case platform
            when "ios-ipados"
              %w[
                build-bindings/shared.json
                frame-capture-evidence/shared.json
                raw-simulator-captures/shared.png
                semantic-evidence/shared.json
              ]
            when "maccatalyst"
              %w[
                frame-capture-evidence/shared.json
                raw-window-captures/shared.png
                semantic-evidence/shared.json
                window-observations/shared.json
              ]
            else
              ["frame-capture-evidence/shared.json"]
            end
    paths.each do |relative|
      path = capture_root.join(relative)
      path.dirname.mkpath
      if path.extname == ".json"
        write_json(
          path,
          {
            "schemaVersion" => 1,
            "status" => "unapproved-independent-capture-evidence",
            "uploadApproved" => false,
            "reviewer" => nil,
            "platform" => platform,
            "file" => relative,
          },
        )
      else
        path.write("independent #{platform} capture evidence: #{relative}\n")
      end
    end
  end

  def mutate_aggregate(platform)
    path = @captures.join(platform, "capture-provenance.json")
    aggregate = JSON.parse(path.read)
    yield aggregate
    write_json(path, aggregate)
    reseal(platform)
  end

  def update_frame_hash(platform, selector, frame_path)
    mutate_aggregate(platform) do |aggregate|
      frame = aggregate.fetch("frames").find { |candidate| candidate.fetch("captureSelector") == selector }
      frame["sha256"] = Digest::SHA256.file(frame_path).hexdigest
    end
  end

  def update_aggregate_frame_evidence_hash(platform, selector, evidence_path)
    path = @captures.join(platform, "capture-provenance.json")
    aggregate = JSON.parse(path.read)
    frame = aggregate.fetch("frames").find do |candidate|
      candidate.fetch("captureSelector") == selector
    end
    key = platform == "maccatalyst" ? "frameCaptureEvidenceSha256" : "captureEvidenceSha256"
    frame[key] = Digest::SHA256.file(evidence_path).hexdigest
    write_json(path, aggregate)
  end

  def cascade_catalyst_evidence_hashes(selector, changed_artifact)
    frame_path = @captures.join("maccatalyst/frame-capture-evidence/#{selector}.json")
    frame = JSON.parse(frame_path.read)
    relative = changed_artifact.relative_path_from(@captures.join("maccatalyst")).to_s
    case relative
    when %r{\Asemantic-evidence/}
      frame.fetch("semanticValidation")["sha256"] = Digest::SHA256.file(changed_artifact).hexdigest
    when %r{\Aapp-logs/}
      frame.fetch("artifacts").fetch("appLog")["sha256"] = Digest::SHA256.file(changed_artifact).hexdigest
    else
      raise "unsupported Catalyst cascade artifact: #{relative}"
    end
    write_json(frame_path, frame)
    update_aggregate_frame_evidence_hash("maccatalyst", selector, frame_path)
  end

  def reseal(platform)
    capture_root = @captures.join(platform)
    manifest = capture_root.join("capture-package-manifest.json")
    manifest.delete if manifest.exist?
    QuakeSignalScreenshotCapturePackageSeal.seal(
      platform: platform,
      source_commit: SOURCE_COMMIT,
      capture_root: capture_root,
      output: manifest,
    )
    archive_capture_root(platform)
  end


  def archive_capture_root(platform)
    capture_root = @captures.join(platform)
    archive = @archives.join("#{platform}.zip")
    archive.delete if archive.exist?
    success = system(
      "/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent",
      capture_root.to_s, archive.to_s,
      out: File::NULL, err: File::NULL,
    )
    raise "failed to build archive fixture for #{platform}" unless success && archive.file?

    archive
  end

  def zip_central_records(bytes)
    eocd_offset = bytes.rindex("PK\x05\x06".b)
    raise "ZIP fixture lacks an end record" unless eocd_offset

    eocd = bytes.byteslice(eocd_offset, 22)&.unpack("VvvvvVVv")
    raise "ZIP fixture end record is malformed" unless eocd&.fetch(0) == 0x06054b50

    entry_count = eocd.fetch(4)
    central_offset = eocd.fetch(6)
    position = central_offset
    records = Array.new(entry_count) do
      values = bytes.byteslice(position, 46)&.unpack("VvvvvvvVVVvvvvvVV")
      raise "ZIP fixture central entry is malformed" unless values&.fetch(0) == 0x02014b50

      record = {
        position: position,
        name: bytes.byteslice(position + 46, values.fetch(10)),
        flags: values.fetch(3),
        method: values.fetch(4),
        compressed_size: values.fetch(8),
        external_attributes: values.fetch(15),
        local_offset: values.fetch(16),
      }
      position += 46 + values.fetch(10) + values.fetch(11) + values.fetch(12)
      record
    end
    [records, central_offset, eocd_offset]
  end

  def mutate_zip_file_mode(path)
    bytes = path.binread
    records, = zip_central_records(bytes)
    record = records.find { |candidate| !candidate.fetch(:name).end_with?("/") }
    raise "ZIP fixture lacks a regular file" unless record

    external = record.fetch(:external_attributes)
    unix_mode = (external >> 16) & 0xffff
    changed_mode = (unix_mode & ~0o7777) | 0o777
    bytes[record.fetch(:position) + 38, 4] = [((changed_mode & 0xffff) << 16) | (external & 0xffff)].pack("V")
    path.binwrite(bytes)
  end

  def mutate_zip_flag(path, location:)
    bytes = path.binread
    records, = zip_central_records(bytes)
    record = records.first
    offset = case location
             when :central then record.fetch(:position) + 8
             when :local then record.fetch(:local_offset) + 6
             else raise "unsupported ZIP flag mutation location: #{location}"
             end
    flags = bytes.byteslice(offset, 2).unpack1("v")
    bytes[offset, 2] = [flags | 0x10].pack("v")
    path.binwrite(bytes)
  end

  def mutate_zip_directory_size(path, location:)
    bytes = path.binread
    records, = zip_central_records(bytes)
    directory = records.first
    unless directory.fetch(:method).zero? && directory.fetch(:compressed_size).zero?
      raise "ZIP fixture first entry is not a stored directory"
    end

    offset = case location
             when :central then directory.fetch(:position) + 20
             when :local then directory.fetch(:local_offset) + 22
             else raise "unsupported ZIP directory mutation location: #{location}"
             end
    bytes[offset, 4] = [1].pack("V")
    path.binwrite(bytes)
  end

  def append_trailing_deflate_data(path)
    bytes = path.binread
    records, central_offset, eocd_offset = zip_central_records(bytes)
    ordered = records.sort_by { |record| record.fetch(:local_offset) }
    target = ordered.reverse.find { |record| record.fetch(:method) == 8 && (record.fetch(:flags) & 0x8) != 0 }
    raise "ZIP fixture lacks a descriptor-backed deflate entry" unless target == ordered.last

    local = bytes.byteslice(target.fetch(:local_offset), 30).unpack("VvvvvvVVVvv")
    data_end = target.fetch(:local_offset) + 30 + local.fetch(9) + local.fetch(10) +
               target.fetch(:compressed_size)
    descriptor_size = central_offset - data_end
    raise "ZIP fixture deflate descriptor is not canonical" unless [12, 16].include?(descriptor_size)

    trailing = "trailing-deflate-data".b
    bytes[data_end, 0] = trailing
    added = trailing.bytesize
    new_compressed_size = target.fetch(:compressed_size) + added
    descriptor_offset = data_end + added
    descriptor_signature = bytes.byteslice(descriptor_offset, 4).unpack1("V")
    descriptor_compressed_offset = descriptor_offset + (descriptor_signature == 0x08074b50 ? 8 : 4)
    bytes[descriptor_compressed_offset, 4] = [new_compressed_size].pack("V")

    shifted_central_position = target.fetch(:position) + added
    bytes[shifted_central_position + 20, 4] = [new_compressed_size].pack("V")
    shifted_eocd_offset = eocd_offset + added
    bytes[shifted_eocd_offset + 16, 4] = [central_offset + added].pack("V")
    path.binwrite(bytes)
  end

  def mutate_zip_descriptor_local_sizes(path)
    bytes = path.binread
    records, = zip_central_records(bytes)
    target = records.find { |record| (record.fetch(:flags) & 0x8) != 0 }
    raise "ZIP fixture lacks a descriptor-backed entry" unless target

    local_offset = target.fetch(:local_offset)
    bytes[local_offset + 14, 4] = [0x1111_1111].pack("V")
    bytes[local_offset + 18, 4] = [2_222].pack("V")
    bytes[local_offset + 22, 4] = [3_333].pack("V")
    path.binwrite(bytes)
  end

  def package_content_sha(package_root)
    files = package_root.find.select(&:file?).sort_by do |file|
      file.relative_path_from(package_root).to_s
    end
    source = files.map do |file|
      relative = file.relative_path_from(package_root).to_s
      "#{Digest::SHA256.file(file).hexdigest}  #{relative}\n"
    end.join
    Digest::SHA256.hexdigest(source)
  end

  def write_json(path, value)
    path.dirname.mkpath
    path.write(JSON.pretty_generate(value) + "\n")
  end
end
