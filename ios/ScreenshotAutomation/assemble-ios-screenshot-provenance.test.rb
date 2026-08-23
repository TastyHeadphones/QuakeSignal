#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "assemble-ios-screenshot-provenance"
require_relative "screenshot-test-temp-root"

class IOSScreenshotProvenanceTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../..").realpath
  IPHONE_UUID = "11111111-2222-3333-4444-555555555555"
  IPAD_UUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
  LEASE_TOKEN = "f" * 32
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

  class FakeImageInspector
    def inspect(path)
      pixels = path.to_s.include?("iphone-6.5") || path.basename.to_s.include?("iphone-6.5") ?
        [1_242, 2_688] : [2_064, 2_752]
      if path.extname == ".jpg"
        { "pixels" => pixels, "format" => "jpeg", "hasAlpha" => false }
      else
        { "pixels" => pixels, "format" => "png", "hasAlpha" => false }
      end
    end
  end

  class FakeResultInspector
    def call(path, architecture)
      raise "fixture xcresult was not safely extracted" unless path.directory? && path.join("Data/build-record.json").file?
      raise "unsupported fixture architecture" unless %w[arm64 x86_64].include?(architecture)

      Marshal.load(Marshal.dump(RESULT_SUMMARY))
    end
  end

  def test_assembles_exact_ten_frame_two_device_unapproved_evidence
    with_capture_fixture do |capture_root, output|
      aggregate = assemble(capture_root, output)
      assert output.file?
      assert_equal 10, aggregate.fetch("frames").length
      assert_equal false, aggregate.fetch("uploadApproved")
      assert_nil aggregate.fetch("reviewer")
      assert_nil aggregate.fetch("approval")
      assert_nil aggregate.fetch("releaseBinaryEvidence")
      assert_equal 2, aggregate.fetch("captureEnvironment").fetch("devices").length
      assert_equal "unapproved-debug-source-bound-ios-simulator-build",
                   aggregate.fetch("buildBinding").fetch("status")
      assert_equal "simulator-cleanup-evidence.json",
                   aggregate.fetch("simulatorCleanupEvidence").fetch("file")
      assert_equal %w[iphone-6.5 ipad-13],
                   aggregate.fetch("captureEnvironment").fetch("devices").map { |device| device.fetch("displayClass") }
    end
  end

  def test_rejects_tampered_final_screenshot
    with_capture_fixture do |capture_root, output|
      capture_root.join("en-US/iphone-6.5/01-home.jpg").binwrite("tampered")
      assert_rejected(capture_root, output, /actual SHA-256/)
    end
  end

  def test_rejects_preapproval_or_named_reviewer
    with_capture_fixture do |capture_root, output|
      mutate_frame(capture_root, "ios-iphone-6.5-home") do |record|
        record["uploadApproved"] = true
        record["reviewer"] = "Premature Reviewer"
      end
      assert_rejected(capture_root, output, /uploadApproved/)
    end
  end

  def test_rejects_mixed_source_commits_or_third_device
    with_capture_fixture do |capture_root, output|
      mutate_frame(capture_root, "ios-ipad-13-home") do |record|
        record.fetch("source")["commit"] = "b" * 40
      end
      assert_rejected(capture_root, output, /(?:build-source commit|aggregate source evidence)/)
    end

    with_capture_fixture do |capture_root, output|
      mutate_frame(capture_root, "ios-ipad-13-home") do |record|
        record.fetch("captureEnvironment")["deviceIdentifier"] =
          "99999999-8888-7777-6666-555555555555"
      end
      assert_rejected(capture_root, output, /install simulator|ipad-13 device evidence/)
    end
  end

  def test_rejects_app_or_temporary_build_source_drift_across_frames
    with_capture_fixture do |capture_root, output|
      mutate_frame(capture_root, "ios-ipad-13-home") do |record|
        record.fetch("app")["mainExecutableSha256"] = "d" * 64
      end
      assert_rejected(capture_root, output, /(?:build-binding app|aggregate app evidence)/)
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-map"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      relative = frame.fetch("build").fetch("sourceEvidenceFile")
      source_path = capture_root.join(relative)
      record = JSON.parse(source_path.read)
      record.fetch("projectTransformation")["temporarySha256"] = "e" * 64
      write_json(source_path, record)
      frame.fetch("build")["sourceEvidenceSha256"] = Digest::SHA256.file(source_path).hexdigest
      write_json(frame_path(capture_root, selector), frame)
      assert_rejected(capture_root, output, /transformed project hash/)
    end
  end

  def test_rejects_missing_or_forged_prebuild_materialized_source_snapshot
    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      snapshot_path = capture_root.join(frame.fetch("build").fetch("preBuildSourceSnapshotFile"))
      snapshot_path.delete
      assert_rejected(capture_root, output, /pre-build materialized-source snapshot|capture inventory/)
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      snapshot_path = capture_root.join(frame.fetch("build").fetch("preBuildSourceSnapshotFile"))
      snapshot = JSON.parse(snapshot_path.read)
      snapshot.fetch("materializedBuildSource").fetch("entries").find do |entry|
        entry.fetch("kind") == "file"
      end["sha256"] = "d" * 64
      write_json(snapshot_path, snapshot)
      frame.fetch("build")["preBuildSourceSnapshotSha256"] = Digest::SHA256.file(snapshot_path).hexdigest
      write_json(frame_path(capture_root, selector), frame)
      assert_rejected(capture_root, output, /materialized source manifest|pre-build materialized source/)
    end
  end

  def test_rejects_missing_or_forged_postbuild_materialized_source_snapshot
    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      snapshot_path = capture_root.join(frame.fetch("build").fetch("postBuildSourceSnapshotFile"))
      snapshot_path.delete
      assert_rejected(capture_root, output, /post-build materialized-source snapshot|capture inventory/)
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      snapshot_path = capture_root.join(frame.fetch("build").fetch("postBuildSourceSnapshotFile"))
      snapshot = JSON.parse(snapshot_path.read)
      snapshot.fetch("materializedBuildSource").fetch("entries").find do |entry|
        entry.fetch("kind") == "file"
      end["sha256"] = "d" * 64
      write_json(snapshot_path, snapshot)
      frame.fetch("build")["postBuildSourceSnapshotSha256"] = Digest::SHA256.file(snapshot_path).hexdigest
      write_json(frame_path(capture_root, selector), frame)
      assert_rejected(capture_root, output, /materialized source manifest|post-build materialized source/)
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      snapshot_path = capture_root.join(frame.fetch("build").fetch("postBuildSourceSnapshotFile"))
      snapshot = JSON.parse(snapshot_path.read)
      snapshot["capturedAt"] = "2026-08-21T00:59:57.000000Z"
      write_json(snapshot_path, snapshot)
      frame.fetch("build")["postBuildSourceSnapshotSha256"] = Digest::SHA256.file(snapshot_path).hexdigest
      write_json(frame_path(capture_root, selector), frame)
      assert_rejected(capture_root, output, /post-build materialized-source snapshot predates/)
    end
  end

  def test_rejects_build_binding_postbuild_materialized_source_drift
    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      binding_path = capture_root.join(frame.fetch("build").fetch("bindingFile"))
      binding = JSON.parse(binding_path.read)
      binding.fetch("buildSourceEvidence").fetch("materializedBuildSource")
             .fetch("postBuildManifest")["contentManifestSha256"] = "d" * 64
      write_json(binding_path, binding)
      frame.fetch("build")["bindingSha256"] = Digest::SHA256.file(binding_path).hexdigest
      write_json(frame_path(capture_root, selector), frame)
      assert_rejected(capture_root, output, /build-binding source evidence/)
    end
  end

  def test_requires_retained_source_snapshots_to_bracket_the_xcresult_build
    {
      "preBuild" => ["preBuildSourceSnapshotFile", "preBuildSourceSnapshotSha256", "2026-08-21T01:40:01.000000Z"],
      "postBuild" => ["postBuildSourceSnapshotFile", "postBuildSourceSnapshotSha256", "2026-08-21T01:40:09.000000Z"],
    }.each do |binding_prefix, (file_key, sha_key, captured_at)|
      with_capture_fixture do |capture_root, output|
        selector = "ios-iphone-6.5-home"
        frame_pathname = frame_path(capture_root, selector)
        frame = JSON.parse(frame_pathname.read)
        snapshot_path = capture_root.join(frame.fetch("build").fetch(file_key))
        snapshot = JSON.parse(snapshot_path.read)
        snapshot["capturedAt"] = captured_at
        write_json(snapshot_path, snapshot)
        snapshot_sha = Digest::SHA256.file(snapshot_path).hexdigest
        frame.fetch("build")[sha_key] = snapshot_sha

        binding_path = capture_root.join(frame.fetch("build").fetch("bindingFile"))
        binding = JSON.parse(binding_path.read)
        materialized = binding.fetch("buildSourceEvidence").fetch("materializedBuildSource")
        materialized["#{binding_prefix}CapturedAt"] = captured_at
        materialized["#{binding_prefix}SnapshotSha256"] = snapshot_sha
        write_json(binding_path, binding)
        frame.fetch("build")["bindingSha256"] = Digest::SHA256.file(binding_path).hexdigest
        write_json(frame_pathname, frame)

        assert_rejected(capture_root, output, /snapshots do not bracket the xcresult build/)
      end
    end
  end

  def test_rejects_build_binding_app_source_log_or_settings_substitution
    {
      "app" => ->(record) { record.fetch("app")["bundleTreeSha256"] = "d" * 64 },
      "source" => ->(record) { record.fetch("buildSourceEvidence")["sha256"] = "d" * 64 },
      "log" => ->(record) { record.fetch("buildInvocationEvidence")["buildLogSha256"] = "d" * 64 },
      "settings" => ->(record) { record.fetch("buildSettings")["wrapperName"] = "Other.app" },
    }.each do |label, mutation|
      with_capture_fixture do |capture_root, output|
        selector = "ios-iphone-6.5-home"
        mutate_json_artifact(capture_root, selector, "build", file_key: "bindingFile", sha_key: "bindingSha256") do |record|
          mutation.call(record)
        end
        assert_rejected(capture_root, output, /build-binding (?:app|source evidence|settings)|build invocation buildLogSha256/, label)
      end
    end
  end

  def test_revalidates_retained_project_list_and_xcresult_archive
    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      list_path = capture_root.join(frame.fetch("build").fetch("projectListFile"))
      list = JSON.parse(list_path.read)
      list.fetch("project").fetch("targets") << "UnreviewedTarget"
      write_json(list_path, list)
      bind_build_hash(capture_root, frame, "projectListSha256", Digest::SHA256.file(list_path).hexdigest)
      write_json(frame_path(capture_root, selector), frame)
      assert_rejected(capture_root, output, /project list differs/)
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      result_path = capture_root.join(frame.fetch("build").fetch("resultBundleArchiveFile"))
      result_path.binwrite("PK invalid retained xcresult archive")
      bind_build_hash(capture_root, frame, "resultBundleArchiveSha256", Digest::SHA256.file(result_path).hexdigest)
      write_json(frame_path(capture_root, selector), frame)
      assert_rejected(capture_root, output, /(?:archive is not a ZIP|ZIP end record)/)
    end
  end

  def test_revalidates_retained_swift_compiler_inputs
    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      swift_path = capture_root.join(frame.fetch("build").fetch("swiftInputsFile"))
      swift_inputs = JSON.parse(swift_path.read)
      swift_inputs.fetch("fileList").fetch("entries").find do |entry|
        entry.fetch("kind") == "authored"
      end["sha256"] = "d" * 64
      write_json(swift_path, swift_inputs)
      swift_sha = Digest::SHA256.file(swift_path).hexdigest
      frame.fetch("build")["swiftInputsSha256"] = swift_sha
      binding_path = capture_root.join(frame.fetch("build").fetch("bindingFile"))
      binding = JSON.parse(binding_path.read)
      binding.fetch("swiftCompilerInputs")["evidenceSha256"] = swift_sha
      write_json(binding_path, binding)
      frame.fetch("build")["bindingSha256"] = Digest::SHA256.file(binding_path).hexdigest
      write_json(frame_path(capture_root, selector), frame)
      assert_rejected(capture_root, output, /Swift input differs from source manifest/)
    end
  end

  def test_rejects_retained_xcresult_summary_substitution
    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      binding_path = capture_root.join(frame.fetch("build").fetch("bindingFile"))
      binding = JSON.parse(binding_path.read)
      binding.fetch("buildInvocationEvidence").fetch("resultSummary")["endTime"] += 1
      write_json(binding_path, binding)
      frame.fetch("build")["bindingSha256"] = Digest::SHA256.file(binding_path).hexdigest
      write_json(frame_path(capture_root, selector), frame)
      assert_rejected(capture_root, output, /retained xcresult summary/)
    end
  end

  def test_rejects_installed_container_or_product_hash_substitution
    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      mutate_json_artifact(capture_root, selector, "installEvidence") do |record|
        record["installedAppContainer"] = record.fetch("installedAppContainer").sub(
          IPHONE_UUID,
          "99999999-8888-7777-6666-555555555555",
        )
      end
      assert_rejected(capture_root, output, /installed app container/)
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      mutate_json_artifact(capture_root, selector, "installEvidence") do |record|
        record["mainExecutableSha256"] = "d" * 64
      end
      assert_rejected(capture_root, output, /installed executable/)
    end
  end

  def test_rejects_noncanonical_status_bar_time
    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      mutate_json_artifact(capture_root, selector, "launchEvidence") do |record|
        record["statusBarTime"] = "2026-01-01T09:41:00Z"
      end
      assert_rejected(capture_root, output, /status-bar time/)
    end
  end

  def test_requires_verified_disposable_simulator_cleanup
    with_capture_fixture do |capture_root, output|
      cleanup_path = capture_root.join("simulator-cleanup-evidence.json")
      cleanup = JSON.parse(cleanup_path.read)
      cleanup.fetch("simulators").last["absentAfterDelete"] = false
      write_json(cleanup_path, cleanup)
      assert_rejected(capture_root, output, /absentAfterDelete/)
    end

    with_capture_fixture do |capture_root, output|
      cleanup_path = capture_root.join("simulator-cleanup-evidence.json")
      cleanup = JSON.parse(cleanup_path.read)
      cleanup.fetch("simulators").reverse!
      write_json(cleanup_path, cleanup)
      assert_rejected(capture_root, output, /iphone-6\.5 simulator cleanup displayClass/)
    end

    with_capture_fixture do |capture_root, output|
      cleanup_path = capture_root.join("simulator-cleanup-evidence.json")
      cleanup = JSON.parse(cleanup_path.read)
      cleanup.fetch("simulators").first.delete("absenceQueries")
      write_json(cleanup_path, cleanup)
      assert_rejected(capture_root, output, /simulator cleanup keys/)
    end


    with_capture_fixture do |capture_root, output|
      lease_path = capture_root.join("simulator-lease-evidence.json")
      lease = JSON.parse(lease_path.read)
      lease["token"] = "fixture-lease"
      write_json(lease_path, lease)
      assert_rejected(capture_root, output, /simulator lease token is invalid/)
    end
  end

  def test_rejects_nonempty_or_unbound_simulator_absence_queries
    with_capture_fixture do |capture_root, output|
      cleanup_path = capture_root.join("simulator-cleanup-evidence.json")
      cleanup = JSON.parse(cleanup_path.read)
      query = cleanup.fetch("simulators").first.fetch("absenceQueries").first
      snapshot_path = capture_root.join(query.fetch("file"))
      write_json(
        snapshot_path,
        {
          "devices" => {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5" => [
              { "udid" => IPHONE_UUID, "name" => "private leased simulator" },
            ],
          },
        },
      )
      query["sha256"] = Digest::SHA256.file(snapshot_path).hexdigest
      write_json(cleanup_path, cleanup)
      assert_rejected(capture_root, output, /only empty runtime device arrays/)
    end

    with_capture_fixture do |capture_root, output|
      cleanup_path = capture_root.join("simulator-cleanup-evidence.json")
      cleanup = JSON.parse(cleanup_path.read)
      cleanup.fetch("simulators").first.fetch("absenceQueries").first["query"] = "different-device"
      write_json(cleanup_path, cleanup)
      assert_rejected(capture_root, output, /absence query query/)
    end
  end

  def test_rejects_unbound_predelete_simulator_lease
    with_capture_fixture do |capture_root, output|
      lease_path = capture_root.join("simulator-lease-evidence.json")
      lease = JSON.parse(lease_path.read)
      lease["ownerProcessId"] = 0
      write_json(lease_path, lease)
      cleanup_path = capture_root.join("simulator-cleanup-evidence.json")
      cleanup = JSON.parse(cleanup_path.read)
      cleanup.fetch("leaseEvidence")["sha256"] = Digest::SHA256.file(lease_path).hexdigest
      write_json(cleanup_path, cleanup)
      assert_rejected(capture_root, output, /ownerProcessId/)
    end
  end

  def test_rejects_frame_specific_rebuild_evidence
    with_capture_fixture do |capture_root, output|
      selector = "ios-ipad-13-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      log_path = capture_root.join(frame.fetch("build").fetch("logFile"))
      log_path.write("a second build invocation\n")
      frame.fetch("build")["logSha256"] = Digest::SHA256.file(log_path).hexdigest
      binding_path = capture_root.join(frame.fetch("build").fetch("bindingFile"))
      binding = JSON.parse(binding_path.read)
      binding.fetch("buildInvocationEvidence")["buildLogSha256"] = frame.fetch("build").fetch("logSha256")
      write_json(binding_path, binding)
      frame.fetch("build")["bindingSha256"] = Digest::SHA256.file(binding_path).hexdigest
      write_json(frame_path(capture_root, selector), frame)
      assert_rejected(capture_root, output, /build log does not prove|aggregate buildBinding evidence/)
    end
  end

  def test_rejects_selector_plan_or_simulator_model_drift
    with_capture_fixture do |capture_root, output|
      mutate_frame(capture_root, "ios-iphone-6.5-home") do |record|
        record["captureSelector"] = "ios-iphone-6.5-unreviewed"
      end
      assert_rejected(capture_root, output, /captureSelector/)
    end

    with_capture_fixture do |capture_root, output|
      mutate_frame(capture_root, "ios-ipad-13-map") do |record|
        record.fetch("captureEnvironment")["deviceModel"] = "Generic iPad"
      end
      assert_rejected(capture_root, output, /deviceModel/)
    end

    with_capture_fixture do |capture_root, output|
      mutate_frame(capture_root, "ios-iphone-6.5-home") do |record|
        record.fetch("captureEnvironment")["deviceIdentifier"] = "not-a-simulator-uuid"
      end
      assert_rejected(capture_root, output, /canonical CoreSimulator UUID/)
    end
  end

  def test_rejects_resize_or_wrong_route_semantics
    with_capture_fixture do |capture_root, output|
      mutate_json_artifact(capture_root, "ios-iphone-6.5-map", "transformation") do |record|
        record["resizePerformed"] = true
      end
      assert_rejected(capture_root, output, /resizePerformed/)
    end

    with_capture_fixture do |capture_root, output|
      mutate_json_artifact(
        capture_root, "ios-iphone-6.5-map", "semanticValidation", reference_key: "finalEvidence"
      ) do |record|
        record.fetch("checks")["matchedRequiredTermGroups"] = []
      end
      assert_rejected(capture_root, output, /required semantic terms/)
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      raw_sha = frame.fetch("artifacts").fetch("rawSimulator").fetch("sha256")
      mutate_json_artifact(
        capture_root, selector, "semanticValidation", reference_key: "finalEvidence"
      ) do |record|
        record["imageSha256"] = raw_sha
      end
      assert_rejected(capture_root, output, /semantic image binding/)
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      mutate_json_artifact(
        capture_root, selector, "semanticValidation", reference_key: "finalEvidence"
      ) do |record|
        metrics = record.fetch("checks").fetch("committedView")
        %w[
          luminanceStandardDeviation nonBlackFraction brightFraction
          chromaticFraction horizontalEdgeFraction
        ].each { |key| metrics[key] = 0.0 }
        record.fetch("checks")["recognizedText"] = %w[unrelated words with no route]
        record.fetch("checks")["matchedRequiredTermGroups"] =
          QuakeSignalIOSScreenshotProvenance::SEMANTIC_ROUTE_TERM_GROUPS.fetch("home")
      end
      assert_rejected(capture_root, output, /derived required semantic terms/)
    end

    with_capture_fixture do |capture_root, output|
      mutate_json_artifact(
        capture_root, "ios-iphone-6.5-home", "semanticValidation", reference_key: "finalEvidence"
      ) do |record|
        record["imageFormat"] = "png"
      end
      assert_rejected(capture_root, output, /semantic image format/)
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-ipad-13-home"
      frame = JSON.parse(frame_path(capture_root, selector).read)
      final_sha = frame.fetch("artifacts").fetch("finalScreenshot").fetch("sha256")
      mutate_json_artifact(
        capture_root, selector, "semanticValidation", reference_key: "rawEvidence"
      ) do |record|
        record["imageSha256"] = final_sha
      end
      assert_rejected(capture_root, output, /semantic image binding/)
    end
  end

  def test_applies_the_sparse_non_black_floor_only_to_ipad_reports
    assert_equal 0.12, QuakeSignalIOSScreenshotProvenance::DEFAULT_MINIMUM_NON_BLACK_FRACTION
    assert_equal(
      { "ios-ipad-13-reports" => 0.004 },
      QuakeSignalIOSScreenshotProvenance::MINIMUM_NON_BLACK_FRACTION_BY_SELECTOR,
    )

    with_capture_fixture do |capture_root, output|
      selector = "ios-ipad-13-reports"
      mutate_json_artifact(
        capture_root, selector, "semanticValidation", reference_key: "finalEvidence"
      ) do |record|
        metrics = record.fetch("checks").fetch("committedView")
        metrics["nonBlackFraction"] = 0.004
        metrics["brightFraction"] = 0.004
      end
      aggregate = assemble(capture_root, output)
      assert_equal 10, aggregate.fetch("frames").length
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-ipad-13-reports"
      mutate_json_artifact(
        capture_root, selector, "semanticValidation", reference_key: "finalEvidence"
      ) do |record|
        metrics = record.fetch("checks").fetch("committedView")
        metrics["nonBlackFraction"] = 0.003_999
        metrics["brightFraction"] = 0.003_999
      end
      assert_rejected(capture_root, output, /derived semantic reasons/)
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-reports"
      mutate_json_artifact(
        capture_root, selector, "semanticValidation", reference_key: "finalEvidence"
      ) do |record|
        metrics = record.fetch("checks").fetch("committedView")
        metrics["nonBlackFraction"] = 0.004
        metrics["brightFraction"] = 0.004
      end
      assert_rejected(capture_root, output, /derived semantic reasons/)
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-ipad-13-reports"
      mutate_json_artifact(
        capture_root, selector, "semanticValidation", reference_key: "finalEvidence"
      ) do |record|
        metrics = record.fetch("checks").fetch("committedView")
        metrics["nonBlackFraction"] = 0.004
        metrics["brightFraction"] = 0.004_001
      end
      assert_rejected(capture_root, output, /brightFraction cannot exceed nonBlackFraction/)
    end
  end

  def test_rejects_permission_dialog_semantic_evidence
    with_capture_fixture do |capture_root, output|
      mutate_json_artifact(
        capture_root, "ios-iphone-6.5-home", "semanticValidation", reference_key: "finalEvidence"
      ) do |record|
        record.fetch("checks")["matchedForbiddenSystemPromptGroups"] = [["allow while using app"]]
      end
      assert_rejected(capture_root, output, /system-prompt terms/)
    end
  end

  def test_binds_raw_final_and_retry_rejection_semantic_evidence
    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      enable_semantic_retry(capture_root, selector)
      aggregate = assemble(capture_root, output)
      semantic = aggregate.fetch("frames").first.fetch("semanticValidation")
      assert_equal "semantic-evidence/#{selector}-raw.json", semantic.fetch("rawEvidence").fetch("file")
      assert_equal "semantic-evidence/#{selector}-final.json", semantic.fetch("finalEvidence").fetch("file")
      assert_equal "semantic-rejections/#{selector}-attempt-1.png",
                   semantic.fetch("firstRejection").fetch("imageFile")
      assert_equal 2, semantic.fetch("captureAttemptCount")
      assert_equal true, semantic.fetch("retryPerformed")
    end

    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      rejection_image = enable_semantic_retry(capture_root, selector)
      rejection_image.binwrite("mutated rejection image")
      assert_rejected(capture_root, output, /actual SHA-256/)
    end


    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      enable_semantic_retry(capture_root, selector)
      mutate_json_artifact(
        capture_root, selector, "semanticValidation", reference_key: "firstRejection"
      ) do |record|
        record["reasons"] = ["forged rejection reason"]
      end
      assert_rejected(capture_root, output, /derived semantic reasons/)
    end
  end

  def test_rejects_obsolete_install_fallback_fields
    with_capture_fixture do |capture_root, output|
      selector = "ios-iphone-6.5-home"
      mutate_json_artifact(capture_root, selector, "installEvidence") do |record|
        record["initialInstallExitStatus"] = 1
        record["embeddedWatchPayloadRemoved"] = true
        record["removedPath"] = "Watch"
      end
      assert_rejected(capture_root, output, /install record keys/)
    end
  end

  def test_rejects_extra_files_symlinks_and_duplicate_json_keys
    with_capture_fixture do |capture_root, output|
      capture_root.join("unexpected.txt").write("extra\n")
      assert_rejected(capture_root, output, /inventory differs/)
    end

    with_capture_fixture do |capture_root, output|
      capture_root.join("unexpected-link").make_symlink(capture_root.join("en-US"))
      assert_rejected(capture_root, output, /symlink or non-regular/)
    end

    with_capture_fixture do |capture_root, output|
      path = frame_path(capture_root, "ios-iphone-6.5-home")
      source = path.read.sub(
        %Q[  "status": "unapproved-debug-ios-ipados-capture-evidence",\n],
        %Q[  "status": "unapproved-debug-ios-ipados-capture-evidence",\n  "status": "unapproved-debug-ios-ipados-capture-evidence",\n],
      )
      path.write(source)
      assert_rejected(capture_root, output, /duplicate(?: JSON object)? key/)
    end
  end

  private

  def assemble(capture_root, output)
    QuakeSignalIOSScreenshotProvenance.assemble(
      capture_root: capture_root,
      output: output,
      repository_root: @source_repository_root || ROOT,
      image_inspector: FakeImageInspector.new,
      result_inspector: FakeResultInspector.new,
    )
  end

  def assert_rejected(capture_root, output, pattern, message = nil)
    error = assert_raises(QuakeSignalIOSScreenshotProvenance::Error) do
      assemble(capture_root, output)
    end
    assert_match pattern, error.message, message
    refute output.exist?
  end

  def with_capture_fixture
    Dir.mktmpdir(
      "quakesignal-ios-provenance-test",
      QuakeSignalScreenshotTestTempRoot.path.to_s,
    ) do |directory|
      temporary_root = Pathname.new(directory)
      @source_repository_root = temporary_root.join("repository")
      @source_repository_root.mkpath
      source_archive = temporary_root.join("tracked-source.tar")
      _archive_output, archive_error, archive_status = Open3.capture3(
        "git", "-C", ROOT.to_s, "archive", "--format=tar", "-o", source_archive.to_s,
        "HEAD", *QuakeSignalIOSScreenshotBuildSource::COPIED_INPUTS,
        "ios/AppStore/screenshot-manifest-v1.1-build10.template.json",
      )
      raise "could not archive tracked provenance source fixture: #{archive_error}" unless archive_status.success?
      _tar_output, tar_error, tar_status = Open3.capture3(
        "tar", "-xf", source_archive.to_s, "-C", @source_repository_root.to_s,
      )
      raise "could not extract tracked provenance source fixture: #{tar_error}" unless tar_status.success?
      source_archive.delete
      @fixture_build_source_record = nil

      capture_root = temporary_root.join("capture")
      QuakeSignalIOSScreenshotProvenance::DIRECTORY_NAMES.each do |name|
        capture_root.join(name).mkpath
      end
      result_bundle = temporary_root.join("QuakeSignal-build.xcresult")
      result_bundle.join("Data").mkpath
      result_bundle.join("Data/build-record.json").write(JSON.generate(RESULT_SUMMARY) + "\n")
      result_archive = temporary_root.join("QuakeSignal-build.xcresult.zip")
      _output, error, status = Open3.capture3(
        "/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent",
        result_bundle.to_s, result_archive.to_s,
      )
      raise "could not create retained xcresult fixture: #{error}" unless status.success?
      shared_build = {
        "resultArchive" => result_archive,
        "resultTree" => QuakeSignalIOSScreenshotBuildBinding.tree_manifest(result_bundle, "fixture xcresult"),
        "appTree" => fixture_app_tree,
      }
      plan = QuakeSignalIOSScreenshotPlan.load(repository_root: ROOT)
      plan.fetch("frames").each_with_index do |frame, index|
        write_frame_fixture(capture_root, plan, frame, index, shared_build)
      end
      lease_path = capture_root.join("simulator-lease-evidence.json")
      lease = simulator_lease_record
      write_json(lease_path, lease)
      absence_paths = write_simulator_absence_fixtures(capture_root)
      write_json(
        capture_root.join("simulator-cleanup-evidence.json"),
        simulator_cleanup_record(lease_path: lease_path, absence_paths: absence_paths),
      )
      yield capture_root, capture_root.join("capture-provenance.json")
    ensure
      @source_repository_root = nil
      @fixture_build_source_record = nil
    end
  end

  def write_frame_fixture(capture_root, plan, frame, index, shared_build)
    selector = frame.fetch("captureSelector")
    pixels = frame.fetch("pixels")
    timestamp = format("2026-08-21T01:41:%02dZ", index)
    device_identifier = frame.fetch("displayClass") == "iphone-6.5" ? IPHONE_UUID : IPAD_UUID

    final_path = capture_root.join(frame.fetch("file"))
    raw_path = capture_root.join("raw-simulator-captures/#{selector}.png")
    stdout_path = capture_root.join("app-logs/#{selector}.stdout.log")
    stderr_path = capture_root.join("app-logs/#{selector}.stderr.log")
    build_path = capture_root.join("build-logs/#{selector}.log")
    build_binding_path = capture_root.join("build-bindings/#{selector}.json")
    build_list_path = capture_root.join("build-lists/#{selector}.json")
    build_result_path = capture_root.join("build-results/#{selector}.xcresult.zip")
    build_settings_path = capture_root.join("build-settings/#{selector}.json")
    prebuild_source_snapshot_path = capture_root.join("build-source-snapshots/#{selector}.json")
    postbuild_source_snapshot_path = capture_root.join("post-build-source-snapshots/#{selector}.json")
    swift_inputs_path = capture_root.join("build-swift-inputs/#{selector}.json")
    install_log_path = capture_root.join("install-logs/#{selector}.log")
    build_source_path = capture_root.join("build-project-evidence/#{selector}.json")
    [final_path, raw_path, stdout_path, stderr_path, build_path, install_log_path].each { |path| path.dirname.mkpath }
    final_path.binwrite("jpeg-#{selector}")
    raw_path.binwrite("png-#{selector}")
    stdout_path.write("stdout #{selector}\n")
    stderr_path.write("stderr #{selector}\n")
    build_path.write(<<~LOG)
      Build description signature: fixture-signature
      Target dependency graph (1 target)
          Target 'QuakeSignal' in project 'QuakeSignal' (no dependencies)
      ** BUILD SUCCEEDED **
    LOG
    install_log_path.write("install #{selector}\n")
    source_record = build_source_record
    write_json(build_source_path, source_record)
    write_json(
      prebuild_source_snapshot_path,
      materialized_source_snapshot_record(source_record, build_source_path, phase: "pre-build"),
    )
    write_json(
      postbuild_source_snapshot_path,
      materialized_source_snapshot_record(source_record, build_source_path, phase: "post-build"),
    )
    write_json(build_settings_path, build_settings_record)
    write_json(build_list_path, build_list_record)
    build_result_path.binwrite(shared_build.fetch("resultArchive").binread)
    write_json(swift_inputs_path, swift_inputs_record(source_record))
    build_binding = build_binding_record(
      build_source_path: build_source_path,
      prebuild_source_snapshot_path: prebuild_source_snapshot_path,
      postbuild_source_snapshot_path: postbuild_source_snapshot_path,
      build_settings_path: build_settings_path,
      build_log_path: build_path,
      build_list_path: build_list_path,
      build_result_path: build_result_path,
      result_tree: shared_build.fetch("resultTree"),
      app_tree: shared_build.fetch("appTree"),
      swift_inputs_path: swift_inputs_path,
    )
    write_json(build_binding_path, build_binding)

    install_record = {
      "schemaVersion" => 1,
      "captureSelector" => selector,
      "simulatorDeviceIdentifier" => device_identifier,
      "installExitStatus" => 0,
      "installLogFile" => "install-logs/#{selector}.log",
      "installLogSha256" => Digest::SHA256.file(install_log_path).hexdigest,
      "installedAppContainer" => "/Users/fixture/Library/Developer/CoreSimulator/Devices/#{device_identifier}/data/Containers/Bundle/Application/fixture/QuakeSignal.app",
      "bundleName" => "QuakeSignal.app",
      "bundleTree" => shared_build.fetch("appTree"),
      "watchPayloadPresent" => false,
      "infoPlistSha256" => tree_file_sha(shared_build.fetch("appTree"), "Info.plist"),
      "mainExecutableFile" => "QuakeSignal",
      "mainExecutableSha256" => tree_file_sha(shared_build.fetch("appTree"), "QuakeSignal"),
    }
    install_path = capture_root.join("install-evidence/#{selector}.json")
    write_json(install_path, install_record)

    launch_record = {
      "schemaVersion" => 1,
      "captureSelector" => selector,
      "processId" => 10_000 + index,
      "launchArgumentGatePresent" => true,
      "launchEnvironmentGatePresent" => true,
      "frameArgumentEnvironmentMatch" => true,
      "appleLanguages" => ["en"],
      "appleLocale" => "en_US",
      "timeZone" => "UTC",
      "appearance" => "dark",
      "statusBarTime" => "9:41",
      "captureAttemptCount" => 1,
      "retryPerformed" => false,
      "stdoutSha256" => Digest::SHA256.file(stdout_path).hexdigest,
      "stderrSha256" => Digest::SHA256.file(stderr_path).hexdigest,
    }
    launch_path = capture_root.join("launch-evidence/#{selector}.json")
    write_json(launch_path, launch_record)

    route = selector.sub(/\Aios-(?:iphone-6\.5|ipad-13)-/, "")
    semantic_record = {
      "schemaVersion" => 1,
      "status" => "accepted",
      "captureSelector" => selector,
      "pixels" => pixels,
      "reasons" => [],
      "checks" => {
        "committedView" => {
          "luminanceStandardDeviation" => 40.0,
          "nonBlackFraction" => 0.7,
          "brightFraction" => 0.2,
          "chromaticFraction" => route == "map" ? 0.3 : 0.1,
          "horizontalEdgeFraction" => 0.08,
          "sampledPixels" => ((pixels.fetch(0) + 7) / 8) * ((pixels.fetch(1) + 7) / 8),
        },
        "recognizedText" => (
          QuakeSignalIOSScreenshotProvenance::SEMANTIC_ROUTE_TERM_GROUPS.fetch(route).map(&:first) +
          ["QuakeSignal", "Today", "Details", "Safety", "Ready"]
        ),
        "matchedRequiredTermGroups" => QuakeSignalIOSScreenshotProvenance::SEMANTIC_ROUTE_TERM_GROUPS.fetch(route),
        "matchedForbiddenSystemPromptGroups" => [],
      },
    }
    raw_semantic_path = capture_root.join("semantic-evidence/#{selector}-raw.json")
    raw_semantic_record = Marshal.load(Marshal.dump(semantic_record)).merge(
      "imageSha256" => Digest::SHA256.file(raw_path).hexdigest,
      "imageFormat" => "png",
    )
    write_json(raw_semantic_path, raw_semantic_record)
    final_semantic_path = capture_root.join("semantic-evidence/#{selector}-final.json")
    final_semantic_record = Marshal.load(Marshal.dump(semantic_record)).merge(
      "imageSha256" => Digest::SHA256.file(final_path).hexdigest,
      "imageFormat" => "jpeg",
    )
    write_json(final_semantic_path, final_semantic_record)

    transformation_record = {
      "schemaVersion" => 1,
      "captureSelector" => selector,
      "operation" => "format-conversion",
      "rawFormat" => "png",
      "finalFormat" => "jpeg",
      "encoder" => "sips",
      "quality" => 100,
      "resizePerformed" => false,
      "rawHasAlpha" => false,
      "finalHasAlpha" => false,
      "pixels" => pixels,
    }
    transformation_path = capture_root.join("transformation-evidence/#{selector}.json")
    write_json(transformation_path, transformation_record)

    evidence = {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-ios-ipados-capture-evidence",
      "uploadApproved" => false,
      "reviewer" => nil,
      "approval" => nil,
      "platform" => "ios-ipados",
      "locale" => "en-US",
      "captureSelector" => selector,
      "displayClass" => frame.fetch("displayClass"),
      "plannedFile" => frame.fetch("file"),
      "captureWindowUtc" => { "startedAt" => timestamp, "completedAt" => timestamp },
      "source" => { "commit" => "a" * 40, "treeState" => "clean", "debugLocalOverridePresent" => false },
      "planManifest" => { "file" => plan.fetch("manifestFile"), "sha256" => plan.fetch("manifestSha256") },
      "product" => {
        "bundleIdentifier" => "com.quakesignal.app",
        "marketingVersion" => "1.1",
        "build" => 10,
        "scheme" => "QuakeSignal",
        "destination" => "generic/platform=iOS Simulator",
        "configuration" => "Debug",
      },
      "captureEnvironment" => {
        "kind" => "simulator",
        "xcodeVersion" => "Xcode 26.6;Build version 17G86",
        "operatingSystem" => "26.6.2 (25G91)",
        "runtimeIdentifier" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "deviceTypeIdentifier" => frame.fetch("deviceTypeIdentifier"),
        "deviceModel" => frame.fetch("device"),
        "deviceIdentifier" => device_identifier,
      },
      "app" => {
        "bundleName" => "QuakeSignal.app",
        "bundleTreeSha256" => shared_build.fetch("appTree").fetch("contentManifestSha256"),
        "mainExecutableFile" => "QuakeSignal",
        "mainExecutableSha256" => tree_file_sha(shared_build.fetch("appTree"), "QuakeSignal"),
      },
      "build" => artifact(build_path, "build-logs/#{selector}.log").transform_keys do |key|
        key == "file" ? "logFile" : "logSha256"
      end.merge(
        "sourceEvidenceFile" => "build-project-evidence/#{selector}.json",
        "sourceEvidenceSha256" => Digest::SHA256.file(build_source_path).hexdigest,
        "preBuildSourceSnapshotFile" => "build-source-snapshots/#{selector}.json",
        "preBuildSourceSnapshotSha256" => Digest::SHA256.file(prebuild_source_snapshot_path).hexdigest,
        "postBuildSourceSnapshotFile" => "post-build-source-snapshots/#{selector}.json",
        "postBuildSourceSnapshotSha256" => Digest::SHA256.file(postbuild_source_snapshot_path).hexdigest,
        "settingsFile" => "build-settings/#{selector}.json",
        "settingsSha256" => Digest::SHA256.file(build_settings_path).hexdigest,
        "projectListFile" => "build-lists/#{selector}.json",
        "projectListSha256" => Digest::SHA256.file(build_list_path).hexdigest,
        "resultBundleArchiveFile" => "build-results/#{selector}.xcresult.zip",
        "resultBundleArchiveSha256" => Digest::SHA256.file(build_result_path).hexdigest,
        "swiftInputsFile" => "build-swift-inputs/#{selector}.json",
        "swiftInputsSha256" => Digest::SHA256.file(swift_inputs_path).hexdigest,
        "bindingFile" => "build-bindings/#{selector}.json",
        "bindingSha256" => Digest::SHA256.file(build_binding_path).hexdigest,
        "debugLocalOverridePresent" => false,
      ),
      "installEvidence" => artifact(install_path, "install-evidence/#{selector}.json"),
      "launchEvidence" => artifact(launch_path, "launch-evidence/#{selector}.json"),
      "semanticValidation" => {
        "status" => "accepted",
        "settleSeconds" => 8,
        "captureAttemptCount" => 1,
        "retryPerformed" => false,
        "rawEvidence" => artifact(
          raw_semantic_path,
          "semantic-evidence/#{selector}-raw.json",
        ).merge("status" => "accepted"),
        "finalEvidence" => artifact(
          final_semantic_path,
          "semantic-evidence/#{selector}-final.json",
        ).merge("status" => "accepted"),
        "firstRejection" => nil,
      },
      "transformation" => artifact(transformation_path, "transformation-evidence/#{selector}.json").merge(
        "operation" => "format-conversion",
        "resizePerformed" => false,
        "encoder" => "sips",
        "quality" => 100,
      ),
      "artifacts" => {
        "rawSimulator" => artifact(raw_path, "raw-simulator-captures/#{selector}.png").merge(
          "pixels" => pixels, "format" => "png", "hasAlpha" => false,
        ),
        "finalScreenshot" => artifact(final_path, frame.fetch("file")).merge(
          "pixels" => pixels, "format" => "jpeg", "hasAlpha" => false,
        ),
        "stdoutLog" => artifact(stdout_path, "app-logs/#{selector}.stdout.log"),
        "stderrLog" => artifact(stderr_path, "app-logs/#{selector}.stderr.log"),
      },
    }
    write_json(frame_path(capture_root, selector), evidence)
  end

  def mutate_frame(capture_root, selector)
    path = frame_path(capture_root, selector)
    record = JSON.parse(path.read)
    yield record
    write_json(path, record)
  end

  def mutate_json_artifact(
    capture_root,
    selector,
    evidence_key,
    reference_key: nil,
    file_key: "file",
    sha_key: "sha256"
  )
    frame = JSON.parse(frame_path(capture_root, selector).read)
    reference = frame.fetch(evidence_key)
    reference = reference.fetch(reference_key) if reference_key
    relative = reference.fetch(file_key)
    artifact_path = capture_root.join(relative)
    record = JSON.parse(artifact_path.read)
    yield record
    write_json(artifact_path, record)
    reference[sha_key] = Digest::SHA256.file(artifact_path).hexdigest
    write_json(frame_path(capture_root, selector), frame)
  end

  def bind_build_hash(capture_root, frame, key, value)
    frame.fetch("build")[key] = value
    binding_path = capture_root.join(frame.fetch("build").fetch("bindingFile"))
    binding = JSON.parse(binding_path.read)
    binding.fetch("buildInvocationEvidence")[key] = value
    write_json(binding_path, binding)
    frame.fetch("build")["bindingSha256"] = Digest::SHA256.file(binding_path).hexdigest
  end

  def enable_semantic_retry(capture_root, selector)
    frame_file = frame_path(capture_root, selector)
    frame = JSON.parse(frame_file.read)
    semantic = frame.fetch("semanticValidation")
    semantic["captureAttemptCount"] = 2
    semantic["retryPerformed"] = true

    rejection_image = capture_root.join("semantic-rejections/#{selector}-attempt-1.png")
    rejection_image.binwrite("rejected-png-#{selector}")
    raw_record_path = capture_root.join(semantic.fetch("rawEvidence").fetch("file"))
    rejected_record = JSON.parse(raw_record_path.read)
    rejected_record["status"] = "rejected"
    rejected_record["imageSha256"] = Digest::SHA256.file(rejection_image).hexdigest
    rejected_record.fetch("checks").fetch("committedView")["luminanceStandardDeviation"] = 0.0
    rejected_record["reasons"] = ["committed-view luminance variation is too low"]
    rejected_record_path = capture_root.join("semantic-rejections/#{selector}-attempt-1.json")
    write_json(rejected_record_path, rejected_record)
    semantic["firstRejection"] = artifact(
      rejected_record_path,
      "semantic-rejections/#{selector}-attempt-1.json",
    ).merge(
      "status" => "rejected",
      "validatorExitStatus" => 65,
      "imageFile" => "semantic-rejections/#{selector}-attempt-1.png",
      "imageSha256" => Digest::SHA256.file(rejection_image).hexdigest,
    )

    launch_reference = frame.fetch("launchEvidence")
    launch_path = capture_root.join(launch_reference.fetch("file"))
    launch = JSON.parse(launch_path.read)
    launch["captureAttemptCount"] = 2
    launch["retryPerformed"] = true
    write_json(launch_path, launch)
    launch_reference["sha256"] = Digest::SHA256.file(launch_path).hexdigest
    write_json(frame_file, frame)
    rejection_image
  end

  def frame_path(capture_root, selector)
    capture_root.join("frame-capture-evidence/#{selector}.json")
  end

  def artifact(path, relative)
    { "file" => relative, "sha256" => Digest::SHA256.file(path).hexdigest }
  end

  def build_source_record
    return Marshal.load(Marshal.dump(@fixture_build_source_record)) if @fixture_build_source_record

    source_root = @source_repository_root || ROOT
    source_files = QuakeSignalIOSScreenshotBuildSource.plain_input_files(source_root)
    project_path = source_root.join(QuakeSignalIOSScreenshotBuildSource::PROJECT_RELATIVE)
    nonproject = source_files.reject { |file| file == project_path }
    manifest = QuakeSignalIOSScreenshotBuildSource.content_manifest(nonproject, source_root)
    original = project_path.binread
    transformed, removed = QuakeSignalIOSScreenshotBuildSource.remove_watch_embedding_references(original)
    entries = [
      {
        "kind" => "directory",
        "path" => "ios",
        "mode" => format("%04o", source_root.join("ios").lstat.mode & 0o7777),
      },
    ]
    QuakeSignalIOSScreenshotBuildSource::COPIED_INPUTS.each do |relative|
      entries.concat(
        QuakeSignalIOSScreenshotBuildSource.snapshot_materialized_entry(
          source_root.join(relative),
          source_root,
        ),
      )
    end
    project_entry = entries.find do |entry|
      entry.fetch("kind") == "file" &&
        entry.fetch("path") == QuakeSignalIOSScreenshotBuildSource::PROJECT_RELATIVE
    end
    project_entry["sha256"] = Digest::SHA256.hexdigest(transformed)
    project_entry["bytes"] = transformed.bytesize
    entries.concat(
      QuakeSignalIOSScreenshotBuildSource::XCODE_SWIFTPM_WORKSPACE_DIRECTORIES.map do |path|
        {
          "kind" => "directory",
          "path" => path,
          "mode" => QuakeSignalIOSScreenshotBuildSource::XCODE_SWIFTPM_WORKSPACE_DIRECTORY_MODE,
        }
      end,
    )
    materialized_manifest =
      QuakeSignalIOSScreenshotBuildSource.build_materialized_manifest(entries)
    record = {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-temporary-no-watch-build-source-evidence",
      "uploadApproved" => false,
      "reviewer" => nil,
      "sourceCommit" => "a" * 40,
      "purpose" => "credential-free iOS Simulator screenshot build on a host where the Watch platform component cannot resolve",
      "sourceMaterialization" => {
        "method" => "git-archive",
        "sourceCommit" => "a" * 40,
        "paths" => QuakeSignalIOSScreenshotBuildSource::COPIED_INPUTS,
        "archiveProjectMatchesGitShow" => true,
        "workingTreeMatchesArchive" => true,
      },
      "mainProductInputs" => manifest,
      "copyVerification" => {
        "allNonProjectBytesIdentical" => true,
        "copiedContentManifestSha256" => manifest.fetch("contentManifestSha256"),
      },
      "projectTransformation" => {
        "originalFile" => QuakeSignalIOSScreenshotBuildSource::PROJECT_RELATIVE,
        "temporaryFile" => "ios/QuakeSignal.xcodeproj/project.pbxproj",
        "originalSha256" => Digest::SHA256.hexdigest(original),
        "temporarySha256" => Digest::SHA256.hexdigest(transformed),
        "removedReferences" => removed,
        "removedDefinitionCount" => 0,
        "watchTargetDefinitionRetained" => true,
        "mainTargetSourceAndResourcePhasesUnchanged" => true,
      },
      "materializedBuildSource" => materialized_manifest,
    }
    QuakeSignalIOSScreenshotBuildSource.validate_prepared_record(
      record,
      source_commit: "a" * 40,
    )
    @fixture_build_source_record = record
    Marshal.load(Marshal.dump(record))
  end

  def materialized_source_snapshot_record(source_record, source_path, phase:)
    manifest = source_record.fetch("materializedBuildSource")
    transformed_project_sha =
      source_record.fetch("projectTransformation").fetch("temporarySha256")
    {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-materialized-ios-build-source-snapshot",
      "uploadApproved" => false,
      "reviewer" => nil,
      "phase" => phase,
      "capturedAt" => phase == "pre-build" ?
        "2026-08-21T01:39:59.000000Z" : "2026-08-21T01:40:11.000000Z",
      "sourceCommit" => "a" * 40,
      "preparedSourceEvidenceSha256" => Digest::SHA256.file(source_path).hexdigest,
      "preparedTransformedProjectSha256" => transformed_project_sha,
      "observedTransformedProjectSha256" => transformed_project_sha,
      "materializedBuildSource" => manifest,
      "matchesPreparedSourceEvidence" => true,
    }
  end

  def build_settings_record
    root = QuakeSignalScreenshotTestTempRoot.path.join("quakesignal-ios-provenance-fixture")
    host_architecture = Open3.capture2("uname", "-m").first.strip
    [
      {
        "action" => "build",
        "target" => "QuakeSignal",
        "buildSettings" => {
          "TARGET_BUILD_DIR" => "#{root}/Build/Products/Debug-iphonesimulator",
          "WRAPPER_NAME" => "QuakeSignal.app",
          "EXECUTABLE_NAME" => "QuakeSignal",
          "FULL_PRODUCT_NAME" => "QuakeSignal.app",
          "CONFIGURATION" => "Debug",
          "PLATFORM_NAME" => "iphonesimulator",
          "SDK_NAME" => "iphonesimulator26.5",
          "PRODUCT_BUNDLE_IDENTIFIER" => "com.quakesignal.app",
          "SDKROOT" => "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk",
          "ARCHS" => host_architecture,
          "ONLY_ACTIVE_ARCH" => "NO",
          "CODE_SIGNING_ALLOWED" => "NO",
          "CODE_SIGNING_REQUIRED" => "NO",
          "CODE_SIGN_IDENTITY" => "",
          "COMPILER_INDEX_STORE_ENABLE" => "NO",
          "BUILD_DIR" => "#{root}/Build/Products",
          "BUILD_ROOT" => "#{root}/Build",
          "CONFIGURATION_BUILD_DIR" => "#{root}/Build/Products/Debug-iphonesimulator",
          "OBJROOT" => "#{root}/Build/Intermediates.noindex",
          "SYMROOT" => "#{root}/Build/Products",
          "SHARED_PRECOMPS_DIR" => "#{root}/SharedPrecompiledHeaders",
          "CLANG_MODULE_CACHE_PATH" => "#{root}/ModuleCache.noindex",
          "DSTROOT" => "#{root}/Dst",
        },
      },
    ]
  end

  def swift_inputs_record(source_record)
    architecture = Open3.capture2("uname", "-m").first.strip
    authored_source = source_record.fetch("mainProductInputs").fetch("files").find do |file|
      relative = file.fetch("file")
      relative.end_with?(".swift") &&
        (relative.start_with?("ios/QuakeSignal/") || relative.start_with?("ios/QuakeSignalShared/"))
    end
    raise "fixture source manifest contains no main-product Swift input" unless authored_source

    generated_file = "DerivedData/Build/Intermediates.noindex/QuakeSignal.build/" \
                     "Debug-iphonesimulator/QuakeSignal.build/DerivedSources/GeneratedAssetSymbols.swift"
    entries = [
      {
        "kind" => "authored",
        "file" => authored_source.fetch("file"),
        "sha256" => authored_source.fetch("sha256"),
        "bytes" => authored_source.fetch("bytes"),
      },
      {
        "kind" => "generated",
        "file" => generated_file,
        "sha256" => Digest::SHA256.hexdigest("fixture generated asset symbols\n"),
        "bytes" => "fixture generated asset symbols\n".bytesize,
      },
    ]
    normalized = entries.map { |entry| "#{entry.fetch('kind')}  #{entry.fetch('file')}\n" }.join
    {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-source-bound-swift-compiler-inputs",
      "uploadApproved" => false,
      "reviewer" => nil,
      "sourceCommit" => "a" * 40,
      "hostArchitecture" => architecture,
      "target" => "QuakeSignal",
      "configuration" => "Debug",
      "platform" => "iphonesimulator",
      "fileList" => {
        "derivedDataRelativeFile" => "Build/Intermediates.noindex/QuakeSignal.build/" \
                                     "Debug-iphonesimulator/QuakeSignal.build/Objects-normal/#{architecture}/" \
                                     "QuakeSignal.SwiftFileList",
        "rawSha256" => Digest::SHA256.hexdigest(entries.map { |entry| entry.fetch("file") }.join("\n") + "\n"),
        "entryCount" => entries.length,
        "normalizedContentSha256" => Digest::SHA256.hexdigest(normalized),
        "entries" => entries,
      },
      "authoredInputCount" => 1,
      "generatedInputCount" => 1,
      "mainTargetSourcesBuildPhaseIdentifier" => "AAAAAAAAAAAAAAAAAAAAAAAA",
      "mainTargetAuthoredSourceFiles" => [authored_source.fetch("file")],
      "authoredInputsExactlyMatchMainTargetSources" => true,
    }
  end

  def build_binding_record(
    build_source_path:, prebuild_source_snapshot_path:, postbuild_source_snapshot_path:, build_settings_path:,
    build_log_path:, build_list_path:,
    build_result_path:, result_tree:, app_tree:, swift_inputs_path:
  )
    source = JSON.parse(build_source_path.read)
    parsed_settings = QuakeSignalIOSBuildSettings.parse(build_settings_path.read)
    swift_inputs = JSON.parse(swift_inputs_path.read)
    transformation = source.fetch("projectTransformation")
    materialized_manifest = source.fetch("materializedBuildSource")
    {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-source-bound-ios-simulator-build",
      "uploadApproved" => false,
      "reviewer" => nil,
      "sourceCommit" => "a" * 40,
      "hostArchitecture" => parsed_settings.fetch("architectures"),
      "configuration" => "Debug",
      "destination" => "generic/platform=iOS Simulator",
      "buildSourceEvidence" => {
        "sha256" => Digest::SHA256.file(build_source_path).hexdigest,
        "originalProjectSha256" => transformation.fetch("originalSha256"),
        "transformedProjectSha256" => transformation.fetch("temporarySha256"),
        "materializedBuildSource" => {
          "preparedManifest" => materialized_manifest,
          "preBuildSnapshotSha256" => Digest::SHA256.file(prebuild_source_snapshot_path).hexdigest,
          "postBuildSnapshotSha256" => Digest::SHA256.file(postbuild_source_snapshot_path).hexdigest,
          "preBuildCapturedAt" => "2026-08-21T01:39:59.000000Z",
          "postBuildCapturedAt" => "2026-08-21T01:40:11.000000Z",
          "preBuildManifest" => materialized_manifest,
          "postBuildManifest" => materialized_manifest,
          "liveAtBindingManifest" => materialized_manifest,
          "preBuildContentManifestSha256" => materialized_manifest.fetch("contentManifestSha256"),
          "postBuildContentManifestSha256" => materialized_manifest.fetch("contentManifestSha256"),
          "liveAtBindingContentManifestSha256" => materialized_manifest.fetch("contentManifestSha256"),
          "prePostAndLiveExactlyMatchPrepared" => true,
        },
      },
      "buildSettings" => parsed_settings.merge(
        "sha256" => Digest::SHA256.file(build_settings_path).hexdigest,
      ),
      "swiftCompilerInputs" => {
        "evidenceSha256" => Digest::SHA256.file(swift_inputs_path).hexdigest,
        "normalizedContentSha256" => swift_inputs.fetch("fileList").fetch("normalizedContentSha256"),
        "authoredInputCount" => swift_inputs.fetch("authoredInputCount"),
        "generatedInputCount" => swift_inputs.fetch("generatedInputCount"),
      },
      "buildInvocationEvidence" => {
        "projectFile" => "ios/QuakeSignal.xcodeproj",
        "scheme" => "QuakeSignal",
        "action" => "build",
        "sdk" => "iphonesimulator",
        "destination" => "generic/platform=iOS Simulator",
        "projectListSha256" => Digest::SHA256.file(build_list_path).hexdigest,
        "buildLogSha256" => Digest::SHA256.file(build_log_path).hexdigest,
        "resultBundleTree" => result_tree,
        "resultBundleArchiveSha256" => Digest::SHA256.file(build_result_path).hexdigest,
        "resultSummary" => Marshal.load(Marshal.dump(RESULT_SUMMARY)),
        "targetCount" => 1,
        "dependencyCount" => 0,
        "buildSucceeded" => true,
      },
      "app" => {
        "bundleName" => "QuakeSignal.app",
        "bundleIdentifier" => "com.quakesignal.app",
        "marketingVersion" => "1.1",
        "build" => 10,
        "bundleTree" => app_tree,
        "watchPayloadPresent" => false,
        "infoPlistSha256" => tree_file_sha(app_tree, "Info.plist"),
        "mainExecutableFile" => "QuakeSignal",
        "mainExecutableSha256" => tree_file_sha(app_tree, "QuakeSignal"),
        "productInspection" => {
          "file" => {
            "command" => ["/usr/bin/file", "-b"],
            "exitStatus" => 0,
            "output" => "Mach-O 64-bit executable #{parsed_settings.fetch('architectures')}\n",
          },
          "vtool" => {
            "command" => ["xcrun", "vtool", "-show-build"],
            "exitStatus" => 0,
            "output" => "platform IOSSIMULATOR\n",
          },
          "codesign" => {
            "command" => ["/usr/bin/codesign", "-dvvv"],
            "exitStatus" => 0,
            "output" => "TeamIdentifier=not set\n",
          },
        },
      },
    }
  end

  def build_list_record
    {
      "project" => {
        "name" => "QuakeSignal",
        "configurations" => %w[Debug InternalQA Release],
        "schemes" => %w[QuakeSignal QuakeSignalTV QuakeSignalVision QuakeSignalWatch],
        "targets" => %w[QuakeSignal QuakeSignalTV QuakeSignalTests QuakeSignalVision QuakeSignalWatch],
      },
    }
  end

  def simulator_lease_record
    lease_token = LEASE_TOKEN
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    {
      "schemaVersion" => 1,
      "status" => "active-disposable-ios-screenshot-simulator-lease",
      "sourceCommit" => "a" * 40,
      "token" => lease_token,
      "ownerProcessId" => 12_345,
      "simulators" => [
        {
          "displayClass" => "iphone-6.5",
          "name" => "QuakeSignal iPhone screenshot set #{lease_token}",
          "runtimeIdentifier" => runtime,
          "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max",
          "deviceIdentifier" => IPHONE_UUID,
        },
        {
          "displayClass" => "ipad-13",
          "name" => "QuakeSignal iPad screenshot set #{lease_token}",
          "runtimeIdentifier" => runtime,
          "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB",
          "deviceIdentifier" => IPAD_UUID,
        },
      ],
    }
  end

  def write_simulator_absence_fixtures(capture_root)
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    %w[iphone-6.5 ipad-13].each_with_object({}) do |display_class, paths|
      %w[uuid name].each do |kind|
        path = capture_root.join("simulator-absence-evidence/#{display_class}-#{kind}.json")
        write_json(path, { "devices" => { runtime => [] } })
        (paths[display_class] ||= {})[kind] = path
      end
    end
  end

  def simulator_cleanup_record(lease_path:, absence_paths:)
    lease = JSON.parse(lease_path.read)
    {
      "schemaVersion" => 1,
      "status" => "verified-disposable-ios-simulators-removed-before-publication",
      "sourceCommit" => "a" * 40,
      "leaseToken" => lease.fetch("token"),
      "leaseEvidence" => artifact(lease_path, "simulator-lease-evidence.json"),
      "simulators" => lease.fetch("simulators").map do |simulator|
        display_class = simulator.fetch("displayClass")
        simulator.merge(
          "shutdownRequested" => true,
          "deleteRequested" => true,
          "absentAfterDelete" => true,
          "absenceQueries" => [
            {
              "kind" => "deviceIdentifier",
              "query" => simulator.fetch("deviceIdentifier"),
              "file" => "simulator-absence-evidence/#{display_class}-uuid.json",
              "sha256" => Digest::SHA256.file(absence_paths.fetch(display_class).fetch("uuid")).hexdigest,
              "exitStatus" => 0,
            },
            {
              "kind" => "leaseName",
              "query" => simulator.fetch("name"),
              "file" => "simulator-absence-evidence/#{display_class}-name.json",
              "sha256" => Digest::SHA256.file(absence_paths.fetch(display_class).fetch("name")).hexdigest,
              "exitStatus" => 0,
            },
          ],
        )
      end,
      "verifiedAtUtc" => "2026-08-21T02:00:00Z",
    }
  end

  def fixture_app_tree
    fixture_tree_manifest(
      "Info.plist" => "fixture QuakeSignal Info.plist\n",
      "QuakeSignal" => "fixture thin simulator executable\n",
      "Assets.car" => "fixture assets\n",
    )
  end

  def fixture_tree_manifest(files)
    entries = files.sort.map do |relative, bytes|
      { "file" => relative, "sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize }
    end
    records = entries.map { |entry| "#{entry.fetch('sha256')}  #{entry.fetch('file')}\n" }.join
    {
      "algorithm" => QuakeSignalIOSScreenshotBuildBinding::TREE_ALGORITHM,
      "fileCount" => entries.length,
      "totalBytes" => entries.sum { |entry| entry.fetch("bytes") },
      "contentManifestSha256" => Digest::SHA256.hexdigest(records),
      "files" => entries,
    }
  end

  def tree_file_sha(tree, relative)
    tree.fetch("files").find { |file| file.fetch("file") == relative }.fetch("sha256")
  end

  def write_json(path, record)
    path.dirname.mkpath
    path.write(JSON.pretty_generate(record) + "\n")
  end
end
