#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "time"
require_relative "maccatalyst-screenshot-plan"

module QuakeSignalMacCatalystScreenshotProvenance
  class Error < StandardError; end

  DIRECTORY_NAMES = %w[
    app-logs
    build-logs
    capture-request-evidence
    en-US
    frame-capture-evidence
    geometry-evidence
    native-capture-evidence
    raw-window-captures
    semantic-evidence
    semantic-rejections
    transformation-evidence
    window-observations
  ].freeze

  SEMANTIC_ROUTE_TERM_GROUPS = {
    "maccatalyst-home" => [["latest earthquake"], ["no nearby activity"]],
    "maccatalyst-reports" => [["earthquake list"], ["noto peninsula"], ["off fukushima"]],
    "maccatalyst-map" => [
      ["24 hours"], ["7 days"], ["30 days"], ["maps"], ["legal"],
      ["noto peninsula"], ["ishikawa"],
    ],
    "maccatalyst-guide" => [
      ["available offline"], ["when an earthquake strikes"],
      ["after the shaking stops"], ["emergency kit"],
    ],
    "maccatalyst-alert-preferences" => [["alert sound"], ["japanese safety voice"], ["cc by 3.0"]],
  }.freeze
  FORBIDDEN_SYSTEM_PROMPT_TERM_GROUPS = [
    ["would like to send you notifications"],
    ["allow while using app", "allow while using the app"],
    ["allow once"],
    ["don t allow"],
  ].freeze

  module_function

  def assemble(capture_root:, output:, repository_root: QuakeSignalMacCatalystScreenshotPlan.repository_root)
    plan = QuakeSignalMacCatalystScreenshotPlan.load(repository_root: repository_root)
    root = Pathname.new(capture_root).realpath
    output_path = Pathname.new(output)
    raise Error, "capture-set provenance output already exists" if output_path.exist? || output_path.symlink?

    expected_files = plan.fetch("frames").flat_map do |frame|
      selector = frame.fetch("captureSelector")
      [
        frame.fetch("file"),
        "app-logs/#{selector}.log",
        "build-logs/#{selector}.log",
        "capture-request-evidence/#{selector}.json",
        "frame-capture-evidence/#{selector}.json",
        "geometry-evidence/#{selector}.json",
        "native-capture-evidence/#{selector}.json",
        "raw-window-captures/#{selector}.png",
        "semantic-evidence/#{selector}.json",
        "transformation-evidence/#{selector}.json",
        "window-observations/#{selector}-after.json",
        "window-observations/#{selector}-before.json",
      ]
    end.sort
    actual_directories, actual_files = capture_inventory(root)
    frames = plan.fetch("frames").map do |frame|
      validate_frame(root: root, frame: frame, plan: plan)
    end
    expected_files.concat(
      frames.flat_map do |frame|
        rejection = frame.fetch("semanticValidation").fetch("firstRejection")
        rejection ? [rejection.fetch("file"), rejection.fetch("imageFile")] : []
      end
    )
    unless actual_directories == DIRECTORY_NAMES && actual_files == expected_files.sort
      raise Error, "capture inventory differs from the exact Mac Catalyst plan"
    end
    require_equal(frames.map { |frame| frame.fetch("source") }.uniq.length, 1, "source evidence")
    require_equal(frames.map { |frame| frame.fetch("app") }.uniq.length, 1, "app evidence")
    require_equal(frames.map { |frame| frame.fetch("product") }.uniq.length, 1, "product evidence")
    require_equal(frames.map { |frame| frame.fetch("host") }.uniq.length, 1, "host evidence")
    require_equal(frames.map { |frame| frame.fetch("sourceDisplayScale") }.uniq.length, 1, "source-display scale evidence")
    require_equal(
      frames.map { |frame| frame.fetch("captureRequest").fetch("nonce") }.uniq.length,
      frames.length,
      "capture-request nonce uniqueness",
    )

    captured_at_values = frames.map { |frame| frame.fetch("capturedAtUtc") }
    aggregate = {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-maccatalyst-capture-set-evidence",
      "uploadApproved" => false,
      "reviewer" => nil,
      "approval" => nil,
      "releaseBinaryEvidence" => nil,
      "platform" => "maccatalyst",
      "locale" => plan.fetch("locale"),
      "fixture" => "finalized-historical-reports",
      "source" => frames.first.fetch("source"),
      "planManifest" => {
        "file" => plan.fetch("manifestFile"),
        "sha256" => plan.fetch("manifestSha256"),
      },
      "product" => frames.first.fetch("product"),
      "host" => frames.first.fetch("host"),
      "app" => frames.first.fetch("app"),
      "captureEnvironment" => {
        "kind" => "maccatalyst-uikit-hierarchy",
        "captureApi" => "UIKit.UIView.drawHierarchy",
        "captureSurface" => "live-catalyst-uiwindow-hierarchy",
        "sourceDisplayScale" => frames.first.fetch("sourceDisplayScale"),
        "rasterizationScale" => 2,
        "logicalViewPoints" => [1_280, 800],
        "pixels" => [2_560, 1_600],
        "afterScreenUpdates" => true,
        "postCaptureResizePerformed" => false,
      },
      "captureWindowUtc" => {
        "startedAt" => captured_at_values.min,
        "completedAt" => captured_at_values.max,
      },
      "frames" => frames,
        "approvalRequired" => "Named visual review and signed Release build 16 parity comparison",
    }
    output_path.dirname.mkpath
    output_path.write(JSON.pretty_generate(aggregate) + "\n", mode: "wx")
    aggregate
  rescue QuakeSignalMacCatalystScreenshotPlan::Error => error
    raise Error, error.message
  end

  def validate_frame(root:, frame:, plan:)
    selector = frame.fetch("captureSelector")
    evidence_relative = "frame-capture-evidence/#{selector}.json"
    evidence_source = root.join(evidence_relative).read
    evidence = parse_json(evidence_source, evidence_relative)
    require_exact_keys(
      evidence,
      %w[approval app artifacts build captureRequest captureSelector capturedAtUtc geometryEvidence host locale nativeCapture planManifest plannedFile platform product reviewer schemaVersion semanticValidation source status transformation uploadApproved window],
      "#{selector} frame evidence",
    )
    require_equal(evidence.fetch("schemaVersion"), 1, "#{selector} schemaVersion")
    require_equal(evidence.fetch("status"), "unapproved-debug-maccatalyst-capture-evidence", "#{selector} status")
    require_equal(evidence.fetch("uploadApproved"), false, "#{selector} uploadApproved")
    require_equal(evidence.fetch("reviewer"), nil, "#{selector} reviewer")
    require_equal(evidence.fetch("approval"), nil, "#{selector} approval")
    require_equal(evidence.fetch("platform"), "maccatalyst", "#{selector} platform")
    require_equal(evidence.fetch("locale"), "en-US", "#{selector} locale")
    require_equal(evidence.fetch("captureSelector"), selector, "#{selector} captureSelector")
    require_equal(evidence.fetch("plannedFile"), frame.fetch("file"), "#{selector} plannedFile")
    captured_at = require_utc_time(evidence.fetch("capturedAtUtc"), "#{selector} capturedAtUtc")

    source = evidence.fetch("source")
    require_exact_keys(source, %w[commit treeState], "#{selector} source")
    unless source.fetch("commit").match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
      raise Error, "#{selector} source commit is not a full Git object ID"
    end
    require_equal(source.fetch("treeState"), "clean", "#{selector} source treeState")

    manifest = evidence.fetch("planManifest")
    require_exact_keys(manifest, %w[file sha256], "#{selector} planManifest")
    require_equal(manifest.fetch("file"), plan.fetch("manifestFile"), "#{selector} manifest file")
    require_equal(manifest.fetch("sha256"), plan.fetch("manifestSha256"), "#{selector} manifest SHA-256")

    product = evidence.fetch("product")
    require_equal(
      product,
      {
        "bundleIdentifier" => "com.quakesignal.app",
        "marketingVersion" => "1.1",
        "build" => 15,
        "scheme" => "QuakeSignal",
        "destination" => "platform=macOS,variant=Mac Catalyst",
        "configuration" => "Debug",
      },
      "#{selector} product",
    )

    host = evidence.fetch("host")
    require_exact_keys(host, %w[hardwareModel macOSBuild macOSVersion xcodeBuild xcodeVersion], "#{selector} host")
    host.each do |key, value|
      raise Error, "#{selector} host #{key} is empty" unless value.is_a?(String) && !value.empty?
    end

    app = evidence.fetch("app")
    require_exact_keys(app, %w[bundleName bundleTreeSha256 mainExecutableFile mainExecutableSha256], "#{selector} app")
    require_equal(app.fetch("bundleName"), "QuakeSignal.app", "#{selector} app bundleName")
    require_equal(app.fetch("mainExecutableFile"), "Contents/MacOS/QuakeSignal", "#{selector} main executable")
    require_sha256(app.fetch("bundleTreeSha256"), "#{selector} app bundle tree")
    require_sha256(app.fetch("mainExecutableSha256"), "#{selector} main executable")

    build = evidence.fetch("build")
    require_exact_keys(build, %w[debugLocalOverridePresent logFile logSha256], "#{selector} build")
    require_equal(build.fetch("debugLocalOverridePresent"), false, "#{selector} Debug.local override")
    require_artifact(
      root,
      { "file" => build.fetch("logFile"), "sha256" => build.fetch("logSha256") },
      expected_file: "build-logs/#{selector}.log",
      label: "#{selector} build log",
    )

    geometry = evidence.fetch("geometryEvidence")
    require_exact_keys(geometry, %w[file recordedAtUtc sha256], "#{selector} geometryEvidence")
    geometry_record = require_json_artifact(
      root,
      geometry,
      expected_file: "geometry-evidence/#{selector}.json",
      label: "#{selector} geometry evidence",
      extra_keys: %w[recordedAtUtc],
    )
    validate_geometry_record(geometry_record, selector: selector, recorded_at: geometry.fetch("recordedAtUtc"))

    semantic_validation = evidence.fetch("semanticValidation")
    validate_semantic(
      root,
      semantic_validation,
      selector: selector,
      final_screenshot_file: frame.fetch("file"),
    )

    window = evidence.fetch("window")
    validate_window(root, window, selector: selector, geometry_record: geometry_record)

    capture_request = evidence.fetch("captureRequest")
    request_record = validate_capture_request(
      root,
      capture_request,
      selector: selector,
      window: window,
    )

    native_capture = evidence.fetch("nativeCapture")
    validate_native_capture(
      root,
      native_capture,
      selector: selector,
      window: window,
      geometry_record: geometry_record,
      request_record: request_record,
    )
    require_equal(
      native_capture.fetch("capturedAtUtc"),
      evidence.fetch("capturedAtUtc"),
      "#{selector} native/frame capture timestamp",
    )

    transformation = evidence.fetch("transformation")
    transformation_record = require_json_artifact(
      root,
      transformation,
      expected_file: "transformation-evidence/#{selector}.json",
      label: "#{selector} transformation evidence",
      extra_keys: %w[backgroundRGBA encoder finalHasAlpha operation pixels rawHasAlpha resizePerformed],
    )
    expected_transform = {
      "operation" => "alpha-composite",
      "backgroundRGBA" => [0, 0, 0, 255],
      "resizePerformed" => false,
      "finalHasAlpha" => false,
      "pixels" => [2_560, 1_600],
      "encoder" => "CoreGraphics-ImageIO-PNG",
    }
    expected_transform.each do |key, value|
      require_equal(transformation.fetch(key), value, "#{selector} transformation #{key}")
      require_equal(transformation_record.fetch(key), value, "#{selector} transformation record #{key}")
    end
    unless [true, false].include?(transformation.fetch("rawHasAlpha"))
      raise Error, "#{selector} transformation rawHasAlpha must be boolean"
    end
    require_equal(
      transformation.fetch("rawHasAlpha"),
      transformation_record.fetch("rawHasAlpha"),
      "#{selector} transformation raw alpha",
    )

    artifacts = evidence.fetch("artifacts")
    require_exact_keys(artifacts, %w[appLog finalScreenshot rawWindow], "#{selector} artifacts")
    require_artifact(root, artifacts.fetch("appLog"), expected_file: "app-logs/#{selector}.log", label: "#{selector} app log")
    validate_png_artifact(
      root,
      artifacts.fetch("rawWindow"),
      expected_file: "raw-window-captures/#{selector}.png",
      expected_alpha: transformation.fetch("rawHasAlpha"),
      label: "#{selector} raw window",
    )
    validate_png_artifact(
      root,
      artifacts.fetch("finalScreenshot"),
      expected_file: frame.fetch("file"),
      expected_alpha: false,
      label: "#{selector} final screenshot",
    )

    {
      "captureSelector" => selector,
      "file" => frame.fetch("file"),
      "screen" => frame.fetch("screen"),
      "purpose" => frame.fetch("purpose"),
      "setup" => frame.fetch("setup"),
      "pixels" => [2_560, 1_600],
      "sha256" => artifacts.fetch("finalScreenshot").fetch("sha256"),
      "rawSha256" => artifacts.fetch("rawWindow").fetch("sha256"),
      "capturedAtUtc" => captured_at,
      "source" => source,
      "product" => product,
      "host" => host,
      "app" => app,
      "processId" => window.fetch("processId"),
      "windowId" => window.fetch("windowId"),
      "logicalFrame" => window.fetch("logicalFrame"),
      "sourceDisplayScale" => window.fetch("sourceDisplayScale"),
      "rasterizationScale" => native_capture.fetch("rasterizationScale"),
      "captureRequest" => capture_request,
      "nativeCapture" => native_capture,
      "semanticValidation" => semantic_validation,
      "frameCaptureEvidenceFile" => evidence_relative,
      "frameCaptureEvidenceSha256" => Digest::SHA256.hexdigest(evidence_source),
      "reviewer" => nil,
      "approval" => nil,
    }
  rescue Errno::ENOENT, KeyError, TypeError, ArgumentError => error
    raise Error, "invalid Mac Catalyst capture evidence for #{selector}: #{error.message}"
  end
  private_class_method :validate_frame

  def validate_geometry_record(record, selector:, recorded_at:)
    require_exact_keys(record, %w[captureSelector logicalFrame processId reason recordedAtUtc schemaVersion sourceDisplayScale status], "#{selector} geometry record")
    require_equal(record.fetch("schemaVersion"), 1, "#{selector} geometry schemaVersion")
    require_equal(record.fetch("status"), "ready", "#{selector} geometry status")
    require_equal(record.fetch("reason"), nil, "#{selector} geometry reason")
    require_equal(record.fetch("captureSelector"), selector, "#{selector} geometry selector")
    require_positive_integer(record.fetch("processId"), "#{selector} geometry PID")
    require_source_display_scale(record.fetch("sourceDisplayScale"), "#{selector} geometry sourceDisplayScale")
    validate_frame_hash(record.fetch("logicalFrame"), "#{selector} geometry frame")
    require_equal(record.fetch("logicalFrame").fetch("width"), 1_280, "#{selector} geometry width")
    require_equal(record.fetch("logicalFrame").fetch("height"), 800, "#{selector} geometry height")
    require_utc_time(record.fetch("recordedAtUtc"), "#{selector} geometry recordedAtUtc")
    require_equal(record.fetch("recordedAtUtc"), recorded_at, "#{selector} geometry recordedAtUtc binding")
  end
  private_class_method :validate_geometry_record

  def validate_semantic(root, semantic, selector:, final_screenshot_file:)
    record = require_json_artifact(
      root,
      semantic,
      expected_file: "semantic-evidence/#{selector}.json",
      label: "#{selector} semantic validation",
      extra_keys: %w[captureAttemptCount firstRejection retryPerformed settleSeconds status],
    )
    require_equal(semantic.fetch("status"), "accepted", "#{selector} semantic status")
    expected_settle = selector == "maccatalyst-map" ? 25 : 10
    require_equal(semantic.fetch("settleSeconds"), expected_settle, "#{selector} semantic settleSeconds")
    attempts = semantic.fetch("captureAttemptCount")
    unless [1, 2].include?(attempts)
      raise Error, "#{selector} semantic captureAttemptCount must be 1 or 2"
    end
    require_equal(
      semantic.fetch("retryPerformed"),
      attempts == 2,
      "#{selector} semantic retry binding",
    )
    validate_semantic_record(
      record,
      selector: selector,
      expected_status: "accepted",
      expected_image_sha256: Digest::SHA256.file(root.join(final_screenshot_file)).hexdigest,
    )

    first_rejection = semantic.fetch("firstRejection")
    if attempts == 1
      require_equal(first_rejection, nil, "#{selector} first semantic rejection")
    else
      rejection_record = require_json_artifact(
        root,
        first_rejection,
        expected_file: "semantic-rejections/#{selector}-attempt-1.json",
        label: "#{selector} first semantic rejection",
        extra_keys: %w[imageFile imageSha256 status validatorExitStatus],
      )
      require_equal(first_rejection.fetch("status"), "rejected", "#{selector} first rejection status")
      require_equal(first_rejection.fetch("validatorExitStatus"), 65, "#{selector} first rejection exit status")
      require_artifact(
        root,
        {
          "file" => first_rejection.fetch("imageFile"),
          "sha256" => first_rejection.fetch("imageSha256"),
        },
        expected_file: "semantic-rejections/#{selector}-attempt-1.png",
        label: "#{selector} first rejected PNG",
      )
      validate_semantic_record(
        rejection_record,
        selector: selector,
        expected_status: "rejected",
        expected_image_sha256: first_rejection.fetch("imageSha256"),
      )
    end
    record
  end
  private_class_method :validate_semantic

  def validate_semantic_record(record, selector:, expected_status:, expected_image_sha256:)
    require_exact_keys(
      record,
      %w[captureSelector checks imageFormat imageSha256 pixels reasons schemaVersion status],
      "#{selector} semantic #{expected_status} record",
    )
    require_equal(record.fetch("schemaVersion"), 1, "#{selector} semantic schemaVersion")
    require_equal(record.fetch("status"), expected_status, "#{selector} semantic record status")
    require_equal(record.fetch("captureSelector"), selector, "#{selector} semantic selector")
    require_equal(record.fetch("pixels"), [2_560, 1_600], "#{selector} semantic pixels")
    require_equal(record.fetch("imageFormat"), "png", "#{selector} semantic image format")
    require_sha256(record.fetch("imageSha256"), "#{selector} semantic image")
    require_equal(
      record.fetch("imageSha256"),
      expected_image_sha256,
      "#{selector} semantic image binding",
    )

    checks = record.fetch("checks")
    require_exact_keys(
      checks,
      %w[committedView matchedForbiddenSystemPromptGroups matchedRequiredTermGroups recognizedText],
      "#{selector} semantic checks",
    )
    committed_view = checks.fetch("committedView")
    require_exact_keys(
      committed_view,
      %w[brightFraction chromaticFraction horizontalEdgeFraction luminanceStandardDeviation nonBlackFraction sampledPixels],
      "#{selector} committed-view checks",
    )
    %w[brightFraction chromaticFraction horizontalEdgeFraction nonBlackFraction].each do |key|
      value = committed_view.fetch(key)
      unless value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
        raise Error, "#{selector} committed-view #{key} must be finite and between 0 and 1"
      end
    end
    standard_deviation = committed_view.fetch("luminanceStandardDeviation")
    unless standard_deviation.is_a?(Numeric) && standard_deviation.finite? && standard_deviation.between?(0, 127.5)
      raise Error, "#{selector} committed-view luminanceStandardDeviation is invalid"
    end
    require_equal(committed_view.fetch("sampledPixels"), 64_000, "#{selector} semantic sampledPixels")
    text = checks.fetch("recognizedText")
    unless text.is_a?(Array) && text.all? { |value| value.is_a?(String) && !value.strip.empty? }
      raise Error, "#{selector} recognized-text inventory is invalid"
    end
    expected_groups = SEMANTIC_ROUTE_TERM_GROUPS.fetch(selector)
    searchable_text = normalize_semantic_text(text.join(" "))
    matched_groups = expected_groups.select do |alternatives|
      alternatives.any? { |term| searchable_text.include?(normalize_semantic_text(term)) }
    end
    matched_forbidden_groups = FORBIDDEN_SYSTEM_PROMPT_TERM_GROUPS.select do |alternatives|
      alternatives.any? { |term| searchable_text.include?(normalize_semantic_text(term)) }
    end
    require_equal(
      checks.fetch("matchedRequiredTermGroups"),
      matched_groups,
      "#{selector} derived required semantic terms",
    )
    require_equal(
      checks.fetch("matchedForbiddenSystemPromptGroups"),
      matched_forbidden_groups,
      "#{selector} derived forbidden system-prompt terms",
    )

    expected_reasons = []
    expected_reasons << "committed-view luminance variation is too low" if standard_deviation < 12
    expected_reasons << "committed-view non-black coverage is too low" if committed_view.fetch("nonBlackFraction") < 0.12
    expected_reasons << "committed-view bright-detail coverage is too low" if committed_view.fetch("brightFraction") < 0.004
    expected_reasons << "committed-view edge detail is too low" if committed_view.fetch("horizontalEdgeFraction") < 0.004
    expected_reasons << "committed-view recognized text inventory is too small" if text.length < 6
    expected_reasons << "requested route terms are missing" if matched_groups != expected_groups
    expected_reasons << "a system permission dialog is visible" unless matched_forbidden_groups.empty?
    if selector == "maccatalyst-map" && committed_view.fetch("chromaticFraction") < 0.02
      expected_reasons << "map chromatic content is too low"
    end
    require_equal(record.fetch("reasons"), expected_reasons, "#{selector} semantic reasons")
    if expected_status == "accepted"
      require_equal(expected_reasons, [], "#{selector} accepted semantic thresholds")
    elsif expected_status == "rejected"
      raise Error, "#{selector} rejected semantic record has no failing check" if expected_reasons.empty?
    else
      raise Error, "#{selector} semantic expected status is invalid"
    end
    record
  end
  private_class_method :validate_semantic_record

  def normalize_semantic_text(value)
    value.downcase.gsub(/[^a-z0-9+.]+/, " ").strip
  end
  private_class_method :normalize_semantic_text

  def validate_window(root, window, selector:, geometry_record:)
    require_exact_keys(
      window,
      %w[afterObservationFile afterObservationSha256 beforeObservationFile beforeObservationSha256 captureSelector logicalFrame ownerName processId sourceDisplayScale windowId windowTitle],
      "#{selector} window",
    )
    require_positive_integer(window.fetch("processId"), "#{selector} window PID")
    require_positive_integer(window.fetch("windowId"), "#{selector} window ID")
    require_equal(window.fetch("captureSelector"), selector, "#{selector} window selector")
    require_equal(window.fetch("processId"), geometry_record.fetch("processId"), "#{selector} geometry/window PID")
    require_source_display_scale(window.fetch("sourceDisplayScale"), "#{selector} window sourceDisplayScale")
    require_equal(
      window.fetch("sourceDisplayScale"),
      geometry_record.fetch("sourceDisplayScale"),
      "#{selector} geometry/window sourceDisplayScale",
    )
    validate_frame_hash(window.fetch("logicalFrame"), "#{selector} window frame")
    require_equal(window.fetch("logicalFrame").fetch("width"), 1_280, "#{selector} window width")
    require_equal(window.fetch("logicalFrame").fetch("height"), 800, "#{selector} window height")
    raise Error, "#{selector} window ownerName is empty" unless window.fetch("ownerName").is_a?(String) && !window.fetch("ownerName").empty?
    unless window.fetch("windowTitle").nil? || window.fetch("windowTitle").is_a?(String)
      raise Error, "#{selector} windowTitle must be null or string"
    end

    observations = %w[before after].map do |phase|
      artifact = {
        "file" => window.fetch("#{phase}ObservationFile"),
        "sha256" => window.fetch("#{phase}ObservationSha256"),
      }
      record = require_json_artifact(
        root,
        artifact,
        expected_file: "window-observations/#{selector}-#{phase}.json",
        label: "#{selector} #{phase} window observation",
      )
      require_exact_keys(record, %w[captureSelector logicalFrame ownerName processId windowId windowTitle], "#{selector} #{phase} window observation")
      record
    end
    require_equal(observations.first, observations.last, "#{selector} before/after window observations")
    expected_observation = {
      "processId" => window.fetch("processId"),
      "windowId" => window.fetch("windowId"),
      "captureSelector" => selector,
      "ownerName" => window.fetch("ownerName"),
      "windowTitle" => window.fetch("windowTitle"),
      "logicalFrame" => window.fetch("logicalFrame"),
    }
    require_equal(observations.first, expected_observation, "#{selector} window observation binding")
  end
  private_class_method :validate_window

  def validate_capture_request(root, capture_request, selector:, window:)
    record_keys = %w[captureSelector logicalViewPoints nonce processId rasterizationScale schemaVersion windowId]
    record = require_json_artifact(
      root,
      capture_request,
      expected_file: "capture-request-evidence/#{selector}.json",
      label: "#{selector} capture request",
      extra_keys: record_keys,
    )
    require_exact_keys(record, record_keys, "#{selector} capture-request record")
    record_keys.each do |key|
      require_equal(capture_request.fetch(key), record.fetch(key), "#{selector} capture-request #{key} binding")
    end
    require_equal(record.fetch("schemaVersion"), 1, "#{selector} capture-request schemaVersion")
    require_equal(record.fetch("processId"), window.fetch("processId"), "#{selector} capture-request PID")
    require_equal(record.fetch("windowId"), window.fetch("windowId"), "#{selector} capture-request window ID")
    require_equal(record.fetch("captureSelector"), selector, "#{selector} capture-request selector")
    require_equal(record.fetch("logicalViewPoints"), [1_280, 800], "#{selector} capture-request logical points")
    require_equal(record.fetch("rasterizationScale"), 2, "#{selector} capture-request rasterization scale")
    unless record.fetch("nonce").is_a?(String) && record.fetch("nonce").match?(/\A[0-9a-f]{64}\z/)
      raise Error, "#{selector} capture-request nonce is invalid"
    end
    record
  end
  private_class_method :validate_capture_request

  def validate_native_capture(root, native_capture, selector:, window:, geometry_record:, request_record:)
    record_keys = %w[
      afterScreenUpdates captureApi captureSelector captureSurface capturedAtUtc
      drawHierarchyComplete logicalViewPoints nonce pixels postCaptureResizePerformed
      processId rasterizationScale rawOutputFile rawSha256 reason rendererOpaque
      rendererPreferredRange sceneActivationState schemaVersion sourceDisplayScale
      status systemFrameAfter systemFrameBefore windowAlpha windowBounds windowId
      windowIsHidden windowIsKey
    ]
    record = require_json_artifact(
      root,
      native_capture,
      expected_file: "native-capture-evidence/#{selector}.json",
      label: "#{selector} native capture",
      extra_keys: record_keys,
    )
    require_exact_keys(record, record_keys, "#{selector} native-capture record")
    record_keys.each do |key|
      require_equal(native_capture.fetch(key), record.fetch(key), "#{selector} native-capture #{key} binding")
    end
    require_equal(record.fetch("schemaVersion"), 1, "#{selector} native-capture schemaVersion")
    require_equal(record.fetch("status"), "captured", "#{selector} native-capture status")
    require_equal(record.fetch("reason"), nil, "#{selector} native-capture reason")
    require_equal(record.fetch("captureApi"), "UIKit.UIView.drawHierarchy", "#{selector} capture API")
    require_equal(
      record.fetch("captureSurface"),
      "live-catalyst-uiwindow-hierarchy",
      "#{selector} capture surface",
    )
    %w[processId windowId captureSelector nonce logicalViewPoints rasterizationScale].each do |key|
      require_equal(record.fetch(key), request_record.fetch(key), "#{selector} request/response #{key}")
    end
    require_equal(record.fetch("processId"), window.fetch("processId"), "#{selector} native-capture PID")
    require_equal(record.fetch("windowId"), window.fetch("windowId"), "#{selector} native-capture window ID")
    require_equal(record.fetch("captureSelector"), selector, "#{selector} native-capture selector")
    require_equal(record.fetch("logicalViewPoints"), [1_280, 800], "#{selector} native-capture logical points")
    require_equal(record.fetch("pixels"), [2_560, 1_600], "#{selector} native-capture pixels")
    require_equal(record.fetch("rasterizationScale"), 2, "#{selector} native capture rasterization scale")
    require_source_display_scale(record.fetch("sourceDisplayScale"), "#{selector} native sourceDisplayScale")
    require_equal(
      record.fetch("sourceDisplayScale"),
      geometry_record.fetch("sourceDisplayScale"),
      "#{selector} native/geometry sourceDisplayScale",
    )
    require_equal(record.fetch("afterScreenUpdates"), true, "#{selector} native afterScreenUpdates")
    require_equal(record.fetch("drawHierarchyComplete"), true, "#{selector} native drawHierarchy completion")
    require_equal(record.fetch("postCaptureResizePerformed"), false, "#{selector} native capture resize")
    require_equal(record.fetch("rendererOpaque"), false, "#{selector} native renderer opacity")
    require_equal(record.fetch("rendererPreferredRange"), "standard", "#{selector} native renderer range")
    require_equal(record.fetch("windowIsKey"), true, "#{selector} native key-window state")
    require_equal(record.fetch("windowIsHidden"), false, "#{selector} native hidden-window state")
    require_equal(record.fetch("sceneActivationState"), "foregroundActive", "#{selector} native scene state")
    unless record.fetch("windowAlpha").is_a?(Numeric) && record.fetch("windowAlpha").finite? && record.fetch("windowAlpha") >= 0.999
      raise Error, "#{selector} native window alpha is invalid"
    end
    validate_frame_hash(record.fetch("windowBounds"), "#{selector} native UIWindow bounds")
    require_equal(
      record.fetch("windowBounds"),
      { "x" => 0, "y" => 0, "width" => 1_280, "height" => 800 },
      "#{selector} native UIWindow bounds",
    )
    validate_frame_hash(record.fetch("systemFrameBefore"), "#{selector} native system frame before")
    validate_frame_hash(record.fetch("systemFrameAfter"), "#{selector} native system frame after")
    require_equal(
      record.fetch("systemFrameBefore"),
      record.fetch("systemFrameAfter"),
      "#{selector} native system-frame drift",
    )
    require_equal(
      record.fetch("systemFrameBefore"),
      geometry_record.fetch("logicalFrame"),
      "#{selector} native stable system-frame binding",
    )
    require_equal(record.fetch("rawOutputFile"), "capture-raw.png", "#{selector} native raw output filename")
    require_sha256(record.fetch("rawSha256"), "#{selector} native raw image")
    require_equal(
      record.fetch("rawSha256"),
      Digest::SHA256.file(root.join("raw-window-captures/#{selector}.png")).hexdigest,
      "#{selector} native raw image binding",
    )
    require_utc_time(record.fetch("capturedAtUtc"), "#{selector} native capturedAtUtc")
  end
  private_class_method :validate_native_capture

  def validate_png_artifact(root, artifact, expected_file:, expected_alpha:, label:)
    require_exact_keys(artifact, %w[file hasAlpha pixels sha256], label)
    require_artifact(root, artifact, expected_file: expected_file, label: label)
    require_equal(artifact.fetch("pixels"), [2_560, 1_600], "#{label} pixels")
    require_equal(artifact.fetch("hasAlpha"), expected_alpha, "#{label} alpha")
  end
  private_class_method :validate_png_artifact

  def require_json_artifact(root, artifact, expected_file:, label:, extra_keys: [])
    require_exact_keys(artifact, %w[file sha256] + extra_keys, label)
    require_artifact(root, artifact, expected_file: expected_file, label: label)
    parse_json(root.join(expected_file).read, expected_file)
  end
  private_class_method :require_json_artifact

  def require_artifact(root, artifact, expected_file:, label:)
    unless artifact.is_a?(Hash) && artifact.keys.include?("file") && artifact.keys.include?("sha256")
      raise Error, "#{label} must contain file and sha256"
    end
    require_equal(artifact.fetch("file"), expected_file, "#{label} file")
    require_sha256(artifact.fetch("sha256"), "#{label} SHA-256")
    actual = Digest::SHA256.file(root.join(expected_file)).hexdigest
    require_equal(artifact.fetch("sha256"), actual, "#{label} actual SHA-256")
  end
  private_class_method :require_artifact

  def validate_frame_hash(frame, label)
    require_exact_keys(frame, %w[height width x y], label)
    frame.each do |key, value|
      unless value.is_a?(Numeric) && value.finite?
        raise Error, "#{label} #{key} must be finite"
      end
    end
  end
  private_class_method :validate_frame_hash

  def require_positive_integer(value, label)
    raise Error, "#{label} must be a positive integer" unless value.is_a?(Integer) && value.positive?
  end
  private_class_method :require_positive_integer

  def require_source_display_scale(value, label)
    unless value.is_a?(Numeric) && value.finite? && value.between?(0.5, 4)
      raise Error, "#{label} must be a plausible finite positive scale"
    end
  end
  private_class_method :require_source_display_scale

  def require_sha256(value, label)
    raise Error, "#{label} is invalid" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
  end
  private_class_method :require_sha256

  def require_utc_time(value, label)
    parsed = Time.iso8601(value)
    raise Error, "#{label} must use UTC Z" unless value.end_with?("Z") && parsed.utc_offset.zero?

    parsed.utc.iso8601
  rescue ArgumentError, TypeError
    raise Error, "#{label} is not an ISO 8601 UTC timestamp"
  end
  private_class_method :require_utc_time

  def require_exact_keys(value, keys, label)
    raise Error, "#{label} must be an object" unless value.is_a?(Hash)
    require_equal(value.keys.sort, keys.sort, "#{label} keys")
  end
  private_class_method :require_exact_keys

  def capture_inventory(root)
    directories = []
    files = []
    visit = lambda do |directory|
      directory.children.sort_by(&:to_s).each do |entry|
        relative = entry.relative_path_from(root).to_s
        stat = entry.lstat
        if stat.directory?
          directories << relative
          visit.call(entry)
        elsif stat.file?
          files << relative
        else
          raise Error, "capture inventory contains a symlink or non-regular entry: #{relative}"
        end
      end
    end
    visit.call(root)
    [directories.sort, files.sort]
  end
  private_class_method :capture_inventory

  def parse_json(source, label)
    JSON.parse(
      source,
      object_class: QuakeSignalMacCatalystScreenshotPlan::DuplicateRejectingHash,
      allow_duplicate_key: false,
    )
  rescue JSON::ParserError, QuakeSignalMacCatalystScreenshotPlan::Error => error
    raise Error, "invalid JSON in #{label}: #{error.message}"
  end
  private_class_method :parse_json

  def require_equal(actual, expected, label)
    return if actual == expected

    raise Error, "#{label} must be #{expected.inspect}; received #{actual.inspect}"
  end
  private_class_method :require_equal
end

if $PROGRAM_NAME == __FILE__
  begin
    unless ARGV.length == 2
      abort "Usage: assemble-maccatalyst-screenshot-provenance.rb <capture-root> <output.json>"
    end
    QuakeSignalMacCatalystScreenshotProvenance.assemble(
      capture_root: ARGV.fetch(0),
      output: ARGV.fetch(1),
    )
  rescue QuakeSignalMacCatalystScreenshotProvenance::Error => error
    warn "error: #{error.message}"
    exit 65
  end
end
