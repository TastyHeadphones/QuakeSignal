#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "assemble-maccatalyst-screenshot-provenance"

class MacCatalystScreenshotProvenanceTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../..").realpath

  def test_assembles_exact_unapproved_native_capture_set
    with_capture_fixture do |capture_root, output|
      aggregate = assemble(capture_root, output)

      assert_equal 1, aggregate.fetch("schemaVersion")
      assert_equal false, aggregate.fetch("uploadApproved")
      assert_nil aggregate.fetch("reviewer")
      assert_nil aggregate.fetch("approval")
      assert_nil aggregate.fetch("releaseBinaryEvidence")
      assert_equal 5, aggregate.fetch("frames").length
      assert_equal [2_560, 1_600], aggregate.fetch("frames").first.fetch("pixels")
      assert_equal 1, aggregate.fetch("frames").first.fetch("sourceDisplayScale")
      assert_equal 2, aggregate.fetch("frames").first.fetch("rasterizationScale")
      assert_equal "maccatalyst-uikit-hierarchy", aggregate.fetch("captureEnvironment").fetch("kind")
      assert_equal "UIKit.UIView.drawHierarchy", aggregate.fetch("frames").first.fetch("nativeCapture").fetch("captureApi")
      assert_equal "accepted", aggregate.fetch("frames").first.fetch("semanticValidation").fetch("status")
      assert_equal false, aggregate.fetch("frames").first.fetch("semanticValidation").fetch("retryPerformed")
      assert output.file?
    end
  end

  def test_rejects_tampered_hash_window_or_approval
    with_capture_fixture do |capture_root, output|
      capture_root.join("raw-window-captures/maccatalyst-home.png").binwrite("tampered")
      assert_rejected(capture_root, output, /actual SHA-256|native raw image binding/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_frame_evidence(capture_root, "maccatalyst-map") do |evidence|
        evidence.fetch("window")["windowId"] += 1
      end
      assert_rejected(capture_root, output, /window observation binding/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_frame_evidence(capture_root, "maccatalyst-guide") do |evidence|
        evidence["approval"] = { "approvedBy" => "Nobody" }
      end
      assert_rejected(capture_root, output, /approval/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_frame_evidence(capture_root, "maccatalyst-home") do |evidence|
        evidence.fetch("nativeCapture")["postCaptureResizePerformed"] = true
      end
      assert_rejected(capture_root, output, /native-capture postCaptureResizePerformed binding|native capture resize/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_frame_evidence(capture_root, "maccatalyst-home") do |evidence|
        evidence.fetch("nativeCapture")["drawHierarchyComplete"] = false
      end
      assert_rejected(capture_root, output, /drawHierarchyComplete binding|drawHierarchy completion/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_frame_evidence(capture_root, "maccatalyst-home") do |evidence|
        evidence.fetch("captureRequest")["nonce"] = "f" * 64
      end
      assert_rejected(capture_root, output, /capture-request nonce binding|request\/response nonce/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_frame_evidence(capture_root, "maccatalyst-home") do |evidence|
        evidence.fetch("nativeCapture")["rasterizationScale"] = 1
      end
      assert_rejected(capture_root, output, /rasterizationScale binding|rasterization scale/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_frame_evidence(capture_root, "maccatalyst-home") do |evidence|
        evidence.fetch("nativeCapture")["sourceDisplayScale"] = 2
      end
      assert_rejected(capture_root, output, /sourceDisplayScale binding|sourceDisplayScale/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_geometry(capture_root, "maccatalyst-home") do |record|
        record.fetch("logicalFrame")["width"] = 1_279
      end
      assert_rejected(capture_root, output, /geometry width/)
    end
  end

  def test_rejects_dirty_or_abbreviated_source_and_resized_transform
    with_capture_fixture do |capture_root, output|
      mutate_frame_evidence(capture_root, "maccatalyst-home") do |evidence|
        evidence.fetch("source")["treeState"] = "dirty"
      end
      assert_rejected(capture_root, output, /treeState/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_frame_evidence(capture_root, "maccatalyst-home") do |evidence|
        evidence.fetch("source")["commit"] = "abc123"
      end
      assert_rejected(capture_root, output, /full Git object ID/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_transform(capture_root, "maccatalyst-reports") do |record|
        record["resizePerformed"] = true
      end
      assert_rejected(capture_root, output, /transformation record resizePerformed/)
    end
  end

  def test_rejects_unplanned_file_and_symlink
    with_capture_fixture do |capture_root, output|
      capture_root.join("en-US/99-extra.png").binwrite("extra")
      assert_rejected(capture_root, output, /inventory differs/)
    end
    with_capture_fixture do |capture_root, output|
      capture_root.join("unexpected-link").make_symlink(capture_root.join("en-US"))
      assert_rejected(capture_root, output, /symlink or non-regular|inventory differs/)
    end
  end

  def test_rejects_semantic_hash_status_route_or_retry_binding
    with_capture_fixture do |capture_root, output|
      capture_root.join("semantic-evidence/maccatalyst-home.json").write("tampered\n")
      assert_rejected(capture_root, output, /actual SHA-256/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_semantic(capture_root, "maccatalyst-home") do |record|
        record["status"] = "rejected"
        record["reasons"] = ["blank"]
      end
      assert_rejected(capture_root, output, /semantic record status/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_semantic(capture_root, "maccatalyst-map") do |record|
        record.fetch("checks")["matchedRequiredTermGroups"] = [["maps"]]
      end
      assert_rejected(capture_root, output, /semantic reasons|derived required semantic terms/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_frame_evidence(capture_root, "maccatalyst-guide") do |evidence|
        evidence.fetch("semanticValidation")["retryPerformed"] = true
      end
      assert_rejected(capture_root, output, /semantic retry binding/)
    end
    with_capture_fixture do |capture_root, output|
      add_first_rejection(capture_root, "maccatalyst-map")
      capture_root.join("semantic-rejections/maccatalyst-map-attempt-1.json").write("tampered\n")
      assert_rejected(capture_root, output, /actual SHA-256/)
    end
  end

  def test_derives_semantic_matches_thresholds_and_forbidden_prompts_from_ocr
    with_capture_fixture do |capture_root, output|
      mutate_semantic(capture_root, "maccatalyst-home") do |record|
        checks = record.fetch("checks")
        checks["recognizedText"] = ["unrelated", "fixture", "words", "claim", "route", "valid"]
        checks["matchedRequiredTermGroups"] =
          QuakeSignalMacCatalystScreenshotProvenance::SEMANTIC_ROUTE_TERM_GROUPS.fetch("maccatalyst-home")
        checks["committedView"].transform_values! { 0.0 }
        checks["committedView"]["sampledPixels"] = 64_000
      end
      assert_rejected(capture_root, output, /derived required semantic terms|derived semantic reasons/)
    end
    with_capture_fixture do |capture_root, output|
      mutate_semantic(capture_root, "maccatalyst-home") do |record|
        record.fetch("checks").fetch("recognizedText") <<
          "QuakeSignal would like to send you notifications"
      end
      assert_rejected(capture_root, output, /derived forbidden system-prompt terms|derived semantic reasons/)
    end
    with_capture_fixture do |capture_root, output|
      add_first_rejection(capture_root, "maccatalyst-home")
      path = capture_root.join("semantic-rejections/maccatalyst-home-attempt-1.json")
      record = JSON.parse(path.read)
      record["status"] = "rejected"
      record["reasons"] = ["requested route terms are missing"]
      record.fetch("checks")["committedView"] = {
        "luminanceStandardDeviation" => 42.0,
        "nonBlackFraction" => 0.70,
        "brightFraction" => 0.20,
        "chromaticFraction" => 0.10,
        "horizontalEdgeFraction" => 0.08,
        "sampledPixels" => 64_000,
      }
      record.fetch("checks")["recognizedText"] = recognized_text_for("maccatalyst-home")
      record.fetch("checks")["matchedRequiredTermGroups"] =
        QuakeSignalMacCatalystScreenshotProvenance::SEMANTIC_ROUTE_TERM_GROUPS.fetch("maccatalyst-home")
      write_json(path, record)
      mutate_frame_evidence(capture_root, "maccatalyst-home") do |evidence|
        evidence.fetch("semanticValidation").fetch("firstRejection")["sha256"] =
          Digest::SHA256.file(path).hexdigest
      end
      assert_rejected(capture_root, output, /semantic reasons|rejected semantic record has no failing check/)
    end
  end

  def test_binds_accepted_and_rejected_semantic_records_to_exact_png_bytes
    with_capture_fixture do |capture_root, output|
      selector = "maccatalyst-home"
      final_path = capture_root.join(
        QuakeSignalMacCatalystScreenshotPlan.load(repository_root: ROOT).fetch("frames").first.fetch("file")
      )
      final_path.binwrite("replacement-final-#{selector}")
      mutate_frame_evidence(capture_root, selector) do |evidence|
        evidence.fetch("artifacts").fetch("finalScreenshot")["sha256"] =
          Digest::SHA256.file(final_path).hexdigest
      end
      assert_rejected(capture_root, output, /semantic image binding/)
    end
    with_capture_fixture do |capture_root, output|
      selector = "maccatalyst-map"
      add_first_rejection(capture_root, selector)
      image_path = capture_root.join("semantic-rejections/#{selector}-attempt-1.png")
      image_path.binwrite("replacement-rejected-#{selector}")
      mutate_frame_evidence(capture_root, selector) do |evidence|
        evidence.fetch("semanticValidation").fetch("firstRejection")["imageSha256"] =
          Digest::SHA256.file(image_path).hexdigest
      end
      assert_rejected(capture_root, output, /semantic image binding/)
    end
  end

  def test_retains_and_hashes_first_semantic_rejection_on_successful_retry
    with_capture_fixture do |capture_root, output|
      add_first_rejection(capture_root, "maccatalyst-map")
      aggregate = assemble(capture_root, output)
      frame = aggregate.fetch("frames").find { |value| value.fetch("captureSelector") == "maccatalyst-map" }
      semantic = frame.fetch("semanticValidation")

      assert_equal 2, semantic.fetch("captureAttemptCount")
      assert_equal true, semantic.fetch("retryPerformed")
      assert_equal "rejected", semantic.fetch("firstRejection").fetch("status")
      assert_equal 65, semantic.fetch("firstRejection").fetch("validatorExitStatus")
      assert output.file?
    end
  end

  private

  def assemble(capture_root, output)
    QuakeSignalMacCatalystScreenshotProvenance.assemble(
      capture_root: capture_root,
      output: output,
      repository_root: ROOT,
    )
  end

  def assert_rejected(capture_root, output, pattern)
    error = assert_raises(QuakeSignalMacCatalystScreenshotProvenance::Error) do
      assemble(capture_root, output)
    end
    assert_match pattern, error.message
    refute output.exist?
  end

  def write_json(path, value)
    path.write(JSON.pretty_generate(value) + "\n")
  end

  def file_record(path, relative)
    {
      "file" => relative,
      "sha256" => Digest::SHA256.file(path).hexdigest,
    }
  end

  def with_capture_fixture
    Dir.mktmpdir("quakesignal-maccatalyst-provenance-test") do |directory|
      temporary_root = Pathname.new(directory)
      capture_root = temporary_root.join("capture")
      QuakeSignalMacCatalystScreenshotProvenance::DIRECTORY_NAMES.each do |name|
        capture_root.join(name).mkpath
      end
      plan = QuakeSignalMacCatalystScreenshotPlan.load(repository_root: ROOT)

      plan.fetch("frames").each_with_index do |frame, index|
        selector = frame.fetch("captureSelector")
        process_id = 10_000 + index
        window_id = 20_000 + index
        timestamp = "2026-08-20T01:0#{index}:00Z"
        logical_frame = { "x" => 100 + index, "y" => 80, "width" => 1_280, "height" => 800 }

        final_path = capture_root.join(frame.fetch("file"))
        raw_path = capture_root.join("raw-window-captures/#{selector}.png")
        app_log_path = capture_root.join("app-logs/#{selector}.log")
        build_log_path = capture_root.join("build-logs/#{selector}.log")
        [final_path, raw_path, app_log_path, build_log_path].map(&:dirname).each(&:mkpath)
        final_path.binwrite("final-#{selector}")
        raw_path.binwrite("raw-#{selector}")
        app_log_path.write("app log #{selector}\n")
        build_log_path.write("build log #{selector}\n")

        geometry_record = {
          "schemaVersion" => 1,
          "status" => "ready",
          "reason" => nil,
          "processId" => process_id,
          "captureSelector" => selector,
          "logicalFrame" => logical_frame,
          "sourceDisplayScale" => 1,
          "recordedAtUtc" => timestamp,
        }
        geometry_path = capture_root.join("geometry-evidence/#{selector}.json")
        write_json(geometry_path, geometry_record)

        window_record = {
          "captureSelector" => selector,
          "processId" => process_id,
          "windowId" => window_id,
          "ownerName" => "QuakeSignal",
          "windowTitle" => "QuakeSignal",
          "logicalFrame" => logical_frame,
        }
        before_path = capture_root.join("window-observations/#{selector}-before.json")
        after_path = capture_root.join("window-observations/#{selector}-after.json")
        write_json(before_path, window_record)
        write_json(after_path, window_record)

        transform_record = {
          "operation" => "alpha-composite",
          "backgroundRGBA" => [0, 0, 0, 255],
          "resizePerformed" => false,
          "rawHasAlpha" => true,
          "finalHasAlpha" => false,
          "pixels" => [2_560, 1_600],
          "encoder" => "CoreGraphics-ImageIO-PNG",
        }
        transform_path = capture_root.join("transformation-evidence/#{selector}.json")
        write_json(transform_path, transform_record)

        semantic_record = {
          "schemaVersion" => 1,
          "status" => "accepted",
          "captureSelector" => selector,
          "imageSha256" => Digest::SHA256.file(final_path).hexdigest,
          "imageFormat" => "png",
          "pixels" => [2_560, 1_600],
          "reasons" => [],
          "checks" => {
            "committedView" => {
              "luminanceStandardDeviation" => 42.0,
              "nonBlackFraction" => 0.70,
              "brightFraction" => 0.20,
              "chromaticFraction" => selector == "maccatalyst-map" ? 0.30 : 0.10,
              "horizontalEdgeFraction" => 0.08,
              "sampledPixels" => 64_000,
            },
            "recognizedText" => recognized_text_for(selector),
            "matchedRequiredTermGroups" =>
              QuakeSignalMacCatalystScreenshotProvenance::SEMANTIC_ROUTE_TERM_GROUPS.fetch(selector),
            "matchedForbiddenSystemPromptGroups" => [],
          },
        }
        semantic_path = capture_root.join("semantic-evidence/#{selector}.json")
        write_json(semantic_path, semantic_record)

        capture_request_record = {
          "schemaVersion" => 1,
          "processId" => process_id,
          "windowId" => window_id,
          "captureSelector" => selector,
          "nonce" => ("%064x" % (index + 1)),
          "logicalViewPoints" => [1_280, 800],
          "rasterizationScale" => 2,
        }
        capture_request_path = capture_root.join("capture-request-evidence/#{selector}.json")
        write_json(capture_request_path, capture_request_record)

        native_capture_record = {
          "schemaVersion" => 1,
          "status" => "captured",
          "reason" => nil,
          "captureApi" => "UIKit.UIView.drawHierarchy",
          "captureSurface" => "live-catalyst-uiwindow-hierarchy",
          "processId" => process_id,
          "windowId" => window_id,
          "captureSelector" => selector,
          "nonce" => capture_request_record.fetch("nonce"),
          "sourceDisplayScale" => 1,
          "rasterizationScale" => 2,
          "logicalViewPoints" => [1_280, 800],
          "pixels" => [2_560, 1_600],
          "afterScreenUpdates" => true,
          "drawHierarchyComplete" => true,
          "postCaptureResizePerformed" => false,
          "rendererOpaque" => false,
          "rendererPreferredRange" => "standard",
          "windowBounds" => { "x" => 0, "y" => 0, "width" => 1_280, "height" => 800 },
          "systemFrameBefore" => logical_frame,
          "systemFrameAfter" => logical_frame,
          "windowIsKey" => true,
          "windowIsHidden" => false,
          "windowAlpha" => 1,
          "sceneActivationState" => "foregroundActive",
          "rawOutputFile" => "capture-raw.png",
          "rawSha256" => Digest::SHA256.file(raw_path).hexdigest,
          "capturedAtUtc" => timestamp,
        }
        native_capture_path = capture_root.join("native-capture-evidence/#{selector}.json")
        write_json(native_capture_path, native_capture_record)

        before_record = file_record(before_path, "window-observations/#{selector}-before.json")
        after_record = file_record(after_path, "window-observations/#{selector}-after.json")
        transformation = transform_record.merge(
          file_record(transform_path, "transformation-evidence/#{selector}.json")
        )
        evidence = {
          "schemaVersion" => 1,
          "status" => "unapproved-debug-maccatalyst-capture-evidence",
          "uploadApproved" => false,
          "reviewer" => nil,
          "approval" => nil,
          "platform" => "maccatalyst",
          "locale" => "en-US",
          "captureSelector" => selector,
          "plannedFile" => frame.fetch("file"),
          "capturedAtUtc" => timestamp,
          "source" => { "commit" => "a" * 40, "treeState" => "clean" },
          "planManifest" => {
            "file" => plan.fetch("manifestFile"),
            "sha256" => plan.fetch("manifestSha256"),
          },
          "product" => {
            "bundleIdentifier" => "com.quakesignal.app",
            "marketingVersion" => "1.1",
            "build" => 13,
            "scheme" => "QuakeSignal",
            "destination" => "platform=macOS,variant=Mac Catalyst",
            "configuration" => "Debug",
          },
          "host" => {
            "macOSVersion" => "26.1",
            "macOSBuild" => "25A1",
            "xcodeVersion" => "26.1",
            "xcodeBuild" => "17A1",
            "hardwareModel" => "MacBookPro",
          },
          "app" => {
            "bundleName" => "QuakeSignal.app",
            "bundleTreeSha256" => "b" * 64,
            "mainExecutableFile" => "Contents/MacOS/QuakeSignal",
            "mainExecutableSha256" => "c" * 64,
          },
          "build" => file_record(build_log_path, "build-logs/#{selector}.log").transform_keys do |key|
            key == "file" ? "logFile" : "logSha256"
          end.merge("debugLocalOverridePresent" => false),
          "geometryEvidence" => file_record(geometry_path, "geometry-evidence/#{selector}.json").merge(
            "recordedAtUtc" => timestamp
          ),
          "semanticValidation" => file_record(
            semantic_path,
            "semantic-evidence/#{selector}.json"
          ).merge(
            "status" => "accepted",
            "settleSeconds" => selector == "maccatalyst-map" ? 25 : 10,
            "captureAttemptCount" => 1,
            "retryPerformed" => false,
            "firstRejection" => nil
          ),
          "captureRequest" => capture_request_record.merge(
            file_record(capture_request_path, "capture-request-evidence/#{selector}.json")
          ),
          "nativeCapture" => native_capture_record.merge(
            file_record(native_capture_path, "native-capture-evidence/#{selector}.json")
          ),
          "window" => window_record.merge(
            "sourceDisplayScale" => 1,
            "beforeObservationFile" => before_record.fetch("file"),
            "beforeObservationSha256" => before_record.fetch("sha256"),
            "afterObservationFile" => after_record.fetch("file"),
            "afterObservationSha256" => after_record.fetch("sha256"),
          ),
          "transformation" => transformation,
          "artifacts" => {
            "rawWindow" => file_record(raw_path, "raw-window-captures/#{selector}.png").merge(
              "pixels" => [2_560, 1_600], "hasAlpha" => true
            ),
            "finalScreenshot" => file_record(final_path, frame.fetch("file")).merge(
              "pixels" => [2_560, 1_600], "hasAlpha" => false
            ),
            "appLog" => file_record(app_log_path, "app-logs/#{selector}.log"),
          },
        }
        write_json(capture_root.join("frame-capture-evidence/#{selector}.json"), evidence)
      end

      yield capture_root, temporary_root.join("aggregate.json")
    end
  end

  def mutate_frame_evidence(capture_root, selector)
    path = capture_root.join("frame-capture-evidence/#{selector}.json")
    evidence = JSON.parse(path.read)
    yield evidence
    write_json(path, evidence)
  end

  def mutate_transform(capture_root, selector)
    path = capture_root.join("transformation-evidence/#{selector}.json")
    record = JSON.parse(path.read)
    yield record
    write_json(path, record)
    mutate_frame_evidence(capture_root, selector) do |evidence|
      evidence.fetch("transformation")["sha256"] = Digest::SHA256.file(path).hexdigest
    end
  end

  def mutate_geometry(capture_root, selector)
    path = capture_root.join("geometry-evidence/#{selector}.json")
    record = JSON.parse(path.read)
    yield record
    write_json(path, record)
    mutate_frame_evidence(capture_root, selector) do |evidence|
      evidence.fetch("geometryEvidence")["sha256"] = Digest::SHA256.file(path).hexdigest
    end
  end


  def mutate_semantic(capture_root, selector)
    path = capture_root.join("semantic-evidence/#{selector}.json")
    record = JSON.parse(path.read)
    yield record
    write_json(path, record)
    mutate_frame_evidence(capture_root, selector) do |evidence|
      evidence.fetch("semanticValidation")["sha256"] = Digest::SHA256.file(path).hexdigest
    end
  end


  def add_first_rejection(capture_root, selector)
    image_relative = "semantic-rejections/#{selector}-attempt-1.png"
    image_path = capture_root.join(image_relative)
    image_path.binwrite("rejected-#{selector}")
    rejection = {
      "schemaVersion" => 1,
      "status" => "rejected",
      "captureSelector" => selector,
      "imageSha256" => Digest::SHA256.file(image_path).hexdigest,
      "imageFormat" => "png",
      "pixels" => [2_560, 1_600],
      "reasons" => [
        "committed-view luminance variation is too low",
        "committed-view non-black coverage is too low",
        "committed-view bright-detail coverage is too low",
        "committed-view edge detail is too low",
        "committed-view recognized text inventory is too small",
        "requested route terms are missing",
        *(selector == "maccatalyst-map" ? ["map chromatic content is too low"] : []),
      ],
      "checks" => {
        "committedView" => {
          "luminanceStandardDeviation" => 0.0,
          "nonBlackFraction" => 0.0,
          "brightFraction" => 0.0,
          "chromaticFraction" => 0.0,
          "horizontalEdgeFraction" => 0.0,
          "sampledPixels" => 64_000,
        },
        "recognizedText" => [],
        "matchedRequiredTermGroups" => [],
        "matchedForbiddenSystemPromptGroups" => [],
      },
    }
    relative = "semantic-rejections/#{selector}-attempt-1.json"
    path = capture_root.join(relative)
    write_json(path, rejection)
    mutate_frame_evidence(capture_root, selector) do |evidence|
      semantic = evidence.fetch("semanticValidation")
      semantic["captureAttemptCount"] = 2
      semantic["retryPerformed"] = true
      semantic["firstRejection"] = file_record(path, relative).merge(
        "status" => "rejected",
        "validatorExitStatus" => 65,
        "imageFile" => image_relative,
        "imageSha256" => Digest::SHA256.file(image_path).hexdigest
      )
    end
  end

  def recognized_text_for(selector)
    terms = QuakeSignalMacCatalystScreenshotProvenance::SEMANTIC_ROUTE_TERM_GROUPS.fetch(selector).map(&:first)
    terms + Array.new([6 - terms.length, 0].max) { |index| "fixture detail #{index + 1}" }
  end
end
