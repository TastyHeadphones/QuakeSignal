#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "time"
require_relative "ios-screenshot-plan"
require_relative "ios-screenshot-build-binding"
require_relative "ios-screenshot-swift-inputs"
require_relative "parse-ios-screenshot-build-settings"
require_relative "prepare-ios-screenshot-build-source"

module QuakeSignalIOSScreenshotProvenance
  class Error < StandardError; end

  DIRECTORY_NAMES = %w[
    app-logs
    build-bindings
    build-lists
    build-logs
    build-project-evidence
    build-results
    build-settings
    build-source-snapshots
    build-swift-inputs
    en-US
    en-US/ipad-13
    en-US/iphone-6.5
    frame-capture-evidence
    install-evidence
    install-logs
    launch-evidence
    post-build-source-snapshots
    raw-simulator-captures
    semantic-evidence
    semantic-rejections
    simulator-absence-evidence
    transformation-evidence
  ].freeze

  SEMANTIC_ROUTE_TERM_GROUPS = {
    "home" => [["latest earthquake"], ["no nearby activity"], ["noto peninsula", "ishikawa"]],
    "reports" => [["earthquake list"], ["noto peninsula"], ["fukushima"]],
    "map" => [["map"], ["24 hours"], ["all"], ["m3+", "m3"], ["m4+", "m4"]],
    "guide" => [["available offline"], ["when an earthquake strikes"], ["indoors", "outdoors"]],
    "alert-preferences" => [["alert sound"], ["japanese safety voice"], ["cc by 3.0"]],
  }.freeze
  DEFAULT_MINIMUM_NON_BLACK_FRACTION = 0.12
  MINIMUM_NON_BLACK_FRACTION_BY_SELECTOR = {
    "ios-ipad-13-reports" => 0.004,
  }.freeze
  FORBIDDEN_SYSTEM_PROMPT_TERM_GROUPS = [
    ["would like to send you notifications"],
    ["allow while using app", "allow while using the app"],
    ["allow once"],
    ["don t allow"],
  ].freeze

  class ImageInspector
    def inspect(path)
      output, error_output, status = Open3.capture3(
        "sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", "-g", "hasAlpha", path.to_s,
      )
      unless status.success?
        detail = error_output.strip.empty? ? output.strip : error_output.strip
        raise Error, "could not inspect screenshot #{path}: #{detail}"
      end
      values = output.each_line.each_with_object({}) do |line, result|
        match = line.match(/^\s*(pixelWidth|pixelHeight|format|hasAlpha):\s*(.+?)\s*$/)
        result[match[1]] = match[2] if match
      end
      {
        "pixels" => [Integer(values.fetch("pixelWidth"), 10), Integer(values.fetch("pixelHeight"), 10)],
        "format" => values.fetch("format").downcase,
        "hasAlpha" => values.fetch("hasAlpha").downcase == "yes",
      }
    rescue KeyError, ArgumentError => error
      raise Error, "could not read screenshot properties for #{path}: #{error.message}"
    end
  end

  module_function

  def assemble(
    capture_root:,
    output:,
    repository_root: QuakeSignalIOSScreenshotPlan.repository_root,
    image_inspector: ImageInspector.new,
    result_inspector: QuakeSignalIOSScreenshotBuildBinding.method(:inspect_xcresult)
  )
    plan = QuakeSignalIOSScreenshotPlan.load(repository_root: repository_root)
    root = Pathname.new(capture_root).realpath
    output_path = Pathname.new(output)
    raise Error, "capture-set provenance output already exists" if output_path.exist? || output_path.symlink?
    unless output_path.expand_path.dirname == root
      raise Error, "capture-set provenance output must be a new direct child of the capture root"
    end

    expected_files = plan.fetch("frames").flat_map do |frame|
      selector = frame.fetch("captureSelector")
      [
        frame.fetch("file"),
        "app-logs/#{selector}.stderr.log",
        "app-logs/#{selector}.stdout.log",
        "build-bindings/#{selector}.json",
        "build-lists/#{selector}.json",
        "build-logs/#{selector}.log",
        "build-project-evidence/#{selector}.json",
        "build-results/#{selector}.xcresult.zip",
        "build-settings/#{selector}.json",
        "build-source-snapshots/#{selector}.json",
        "post-build-source-snapshots/#{selector}.json",
        "build-swift-inputs/#{selector}.json",
        "frame-capture-evidence/#{selector}.json",
        "install-evidence/#{selector}.json",
        "install-logs/#{selector}.log",
        "launch-evidence/#{selector}.json",
        "raw-simulator-captures/#{selector}.png",
        "semantic-evidence/#{selector}-final.json",
        "semantic-evidence/#{selector}-raw.json",
        "transformation-evidence/#{selector}.json",
      ]
    end
    expected_files << "simulator-cleanup-evidence.json"
    expected_files << "simulator-lease-evidence.json"
    %w[iphone-6.5 ipad-13].each do |display_class|
      expected_files << "simulator-absence-evidence/#{display_class}-uuid.json"
      expected_files << "simulator-absence-evidence/#{display_class}-name.json"
    end
    actual_directories, actual_files = capture_inventory(root)
    frames = plan.fetch("frames").map do |frame|
      validate_frame(
        root: root,
        frame: frame,
        plan: plan,
        image_inspector: image_inspector,
        result_inspector: result_inspector,
        repository_root: Pathname.new(repository_root).realpath,
      )
    end
    expected_files.concat(
      frames.flat_map do |frame|
        rejection = frame.fetch("semanticValidation").fetch("firstRejection")
        rejection ? [rejection.fetch("file"), rejection.fetch("imageFile")] : []
      end,
    )
    unless actual_directories == DIRECTORY_NAMES && actual_files == expected_files.sort
      raise Error, "capture inventory differs from the exact ten-frame iOS/iPadOS plan"
    end

    %w[source product app buildSource buildBinding].each do |field|
      require_equal(frames.map { |frame| frame.fetch(field) }.uniq.length, 1, "aggregate #{field} evidence")
    end
    host_records = frames.map do |frame|
      environment = frame.fetch("captureEnvironment")
      environment.slice("xcodeVersion", "operatingSystem", "runtimeIdentifier")
    end
    require_equal(host_records.uniq.length, 1, "aggregate host/runtime evidence")

    display_devices = %w[iphone-6.5 ipad-13].map do |display_class|
      class_frames = frames.select { |frame| frame.fetch("displayClass") == display_class }
      require_equal(class_frames.length, 5, "#{display_class} frame count")
      devices = class_frames.map do |frame|
        frame.fetch("captureEnvironment").slice(
          "deviceTypeIdentifier", "deviceModel", "deviceIdentifier",
        )
      end.uniq
      require_equal(devices.length, 1, "#{display_class} device evidence")
      devices.first.merge("displayClass" => display_class)
    end
    if display_devices.map { |device| device.fetch("deviceIdentifier") }.uniq.length != 2
      raise Error, "iOS/iPadOS set must be captured from exactly two distinct disposable simulators"
    end

    capture_windows = frames.map { |frame| frame.fetch("captureWindowUtc") }
    lease_path = root.join("simulator-lease-evidence.json")
    lease_reference = standalone_artifact_reference(
      root,
      "simulator-lease-evidence.json",
      "simulator lease evidence",
    )
    lease_record = parse_json(lease_path.read, "simulator-lease-evidence.json")
    validate_simulator_lease(
      lease_record,
      source_commit: frames.first.fetch("source").fetch("commit"),
      devices: display_devices,
      runtime_identifier: host_records.first.fetch("runtimeIdentifier"),
    )
    cleanup_path = root.join("simulator-cleanup-evidence.json")
    cleanup_reference = standalone_artifact_reference(
      root,
      "simulator-cleanup-evidence.json",
      "simulator cleanup evidence",
    )
    cleanup_record = parse_json(cleanup_path.read, "simulator-cleanup-evidence.json")
    validate_simulator_cleanup(
      cleanup_record,
      source_commit: frames.first.fetch("source").fetch("commit"),
      devices: display_devices,
      runtime_identifier: host_records.first.fetch("runtimeIdentifier"),
      completed_at: capture_windows.map { |window| window.fetch("completedAt") }.max,
      lease_record: lease_record,
      lease_reference: lease_reference,
      root: root,
    )
    aggregate = {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-ios-ipados-capture-set-evidence",
      "uploadApproved" => false,
      "reviewer" => nil,
      "approval" => nil,
      "releaseBinaryEvidence" => nil,
      "platform" => "ios-ipados",
      "locale" => "en-US",
      "fixture" => "finalized-historical-reports",
      "source" => frames.first.fetch("source"),
      "planManifest" => {
        "file" => plan.fetch("manifestFile"),
        "sha256" => plan.fetch("manifestSha256"),
      },
      "product" => frames.first.fetch("product"),
      "app" => frames.first.fetch("app"),
      "buildSource" => frames.first.fetch("buildSource"),
      "buildBinding" => frames.first.fetch("buildBinding"),
      "captureEnvironment" => host_records.first.merge("devices" => display_devices),
      "simulatorCleanupEvidence" => cleanup_reference,
      "captureWindowUtc" => {
        "startedAt" => capture_windows.map { |window| window.fetch("startedAt") }.min,
        "completedAt" => capture_windows.map { |window| window.fetch("completedAt") }.max,
      },
      "frames" => frames,
      "approvalRequired" => "Named visual review and signed Release build 8 parity comparison",
    }
    output_path.write(JSON.pretty_generate(aggregate) + "\n", mode: "wx")
    aggregate
  rescue QuakeSignalIOSScreenshotPlan::Error => error
    raise Error, error.message
  end

  def validate_frame(root:, frame:, plan:, image_inspector:, result_inspector:, repository_root:)
    selector = frame.fetch("captureSelector")
    evidence_relative = "frame-capture-evidence/#{selector}.json"
    evidence_source = root.join(evidence_relative).read
    evidence = parse_json(evidence_source, evidence_relative)
    require_exact_keys(
      evidence,
      %w[
        schemaVersion status uploadApproved reviewer approval platform locale
        captureSelector displayClass plannedFile captureWindowUtc source planManifest
        product captureEnvironment app build installEvidence launchEvidence
        semanticValidation transformation artifacts
      ],
      "#{selector} frame evidence",
    )
    require_equal(evidence.fetch("schemaVersion"), 1, "#{selector} schemaVersion")
    require_equal(evidence.fetch("status"), "unapproved-debug-ios-ipados-capture-evidence", "#{selector} status")
    require_equal(evidence.fetch("uploadApproved"), false, "#{selector} uploadApproved")
    require_equal(evidence.fetch("reviewer"), nil, "#{selector} reviewer")
    require_equal(evidence.fetch("approval"), nil, "#{selector} approval")
    require_equal(evidence.fetch("platform"), "ios-ipados", "#{selector} platform")
    require_equal(evidence.fetch("locale"), "en-US", "#{selector} locale")
    require_equal(evidence.fetch("captureSelector"), selector, "#{selector} captureSelector")
    require_equal(evidence.fetch("displayClass"), frame.fetch("displayClass"), "#{selector} displayClass")
    require_equal(evidence.fetch("plannedFile"), frame.fetch("file"), "#{selector} plannedFile")
    capture_window = validate_capture_window(evidence.fetch("captureWindowUtc"), selector)

    source = evidence.fetch("source")
    require_exact_keys(source, %w[commit treeState debugLocalOverridePresent], "#{selector} source")
    unless source.fetch("commit").is_a?(String) && source.fetch("commit").match?(/\A[0-9a-f]{40}\z/)
      raise Error, "#{selector} source commit is not a full lowercase Git commit"
    end
    require_equal(source.fetch("treeState"), "clean", "#{selector} source treeState")
    require_equal(source.fetch("debugLocalOverridePresent"), false, "#{selector} Debug.local override")

    plan_manifest = evidence.fetch("planManifest")
    require_exact_keys(plan_manifest, %w[file sha256], "#{selector} planManifest")
    require_equal(plan_manifest.fetch("file"), plan.fetch("manifestFile"), "#{selector} plan file")
    require_equal(plan_manifest.fetch("sha256"), plan.fetch("manifestSha256"), "#{selector} plan SHA-256")

    product = evidence.fetch("product")
    require_equal(
      product,
      {
        "bundleIdentifier" => "com.quakesignal.app",
        "marketingVersion" => "1.1",
        "build" => 8,
        "scheme" => "QuakeSignal",
        "destination" => "generic/platform=iOS Simulator",
        "configuration" => "Debug",
      },
      "#{selector} product",
    )

    environment = evidence.fetch("captureEnvironment")
    require_exact_keys(
      environment,
      %w[kind xcodeVersion operatingSystem runtimeIdentifier deviceTypeIdentifier deviceModel deviceIdentifier],
      "#{selector} captureEnvironment",
    )
    require_equal(environment.fetch("kind"), "simulator", "#{selector} capture kind")
    {
      "deviceTypeIdentifier" => frame.fetch("deviceTypeIdentifier"),
      "deviceModel" => frame.fetch("device"),
    }.each do |key, expected|
      require_equal(environment.fetch(key), expected, "#{selector} capture #{key}")
    end
    %w[xcodeVersion operatingSystem runtimeIdentifier deviceIdentifier].each do |key|
      require_nonempty_string(environment.fetch(key), "#{selector} capture #{key}")
    end
    require_simulator_udid(environment.fetch("deviceIdentifier"), "#{selector} capture deviceIdentifier")

    app = evidence.fetch("app")
    require_exact_keys(app, %w[bundleName bundleTreeSha256 mainExecutableFile mainExecutableSha256], "#{selector} app")
    require_equal(app.fetch("bundleName"), "QuakeSignal.app", "#{selector} app bundleName")
    require_nonempty_string(app.fetch("mainExecutableFile"), "#{selector} main executable file")
    require_sha256(app.fetch("bundleTreeSha256"), "#{selector} app tree")
    require_sha256(app.fetch("mainExecutableSha256"), "#{selector} executable")

    build = evidence.fetch("build")
    require_exact_keys(
      build,
      %w[
        logFile logSha256 sourceEvidenceFile sourceEvidenceSha256 settingsFile
        preBuildSourceSnapshotFile preBuildSourceSnapshotSha256
        postBuildSourceSnapshotFile postBuildSourceSnapshotSha256 settingsSha256
        projectListFile projectListSha256 resultBundleArchiveFile
        resultBundleArchiveSha256 swiftInputsFile swiftInputsSha256 bindingFile
        bindingSha256 debugLocalOverridePresent
      ],
      "#{selector} build",
    )
    require_equal(build.fetch("debugLocalOverridePresent"), false, "#{selector} build Debug.local override")
    build_log_path = require_artifact(
      root, build,
      file_key: "logFile", sha_key: "logSha256",
      expected_file: "build-logs/#{selector}.log", label: "#{selector} build log",
    )
    build_source = require_json_artifact(
      root,
      {
        "file" => build.fetch("sourceEvidenceFile"),
        "sha256" => build.fetch("sourceEvidenceSha256"),
      },
      expected_file: "build-project-evidence/#{selector}.json",
      label: "#{selector} build-source evidence",
    )
    validate_build_source(
      build_source,
      source_commit: source.fetch("commit"),
      repository_root: repository_root,
      selector: selector,
    )
    prebuild_source_snapshot_path = require_artifact(
      root, build,
      file_key: "preBuildSourceSnapshotFile", sha_key: "preBuildSourceSnapshotSha256",
      expected_file: "build-source-snapshots/#{selector}.json",
      label: "#{selector} pre-build materialized-source snapshot",
    )
    prebuild_source_snapshot, prebuild_source_snapshot_sha =
      QuakeSignalIOSScreenshotBuildSource.verify_materialized_snapshot(
        snapshot: prebuild_source_snapshot_path,
        prepared_source_evidence: root.join(build.fetch("sourceEvidenceFile")),
        source_commit: source.fetch("commit"),
        phase: "pre-build",
      )
    require_equal(
      prebuild_source_snapshot_sha,
      build.fetch("preBuildSourceSnapshotSha256"),
      "#{selector} pre-build snapshot SHA-256",
    )
    postbuild_source_snapshot_path = require_artifact(
      root, build,
      file_key: "postBuildSourceSnapshotFile", sha_key: "postBuildSourceSnapshotSha256",
      expected_file: "post-build-source-snapshots/#{selector}.json",
      label: "#{selector} post-build materialized-source snapshot",
    )
    postbuild_source_snapshot, postbuild_source_snapshot_sha =
      QuakeSignalIOSScreenshotBuildSource.verify_materialized_snapshot(
        snapshot: postbuild_source_snapshot_path,
        prepared_source_evidence: root.join(build.fetch("sourceEvidenceFile")),
        source_commit: source.fetch("commit"),
        phase: "post-build",
      )
    require_equal(
      postbuild_source_snapshot_sha,
      build.fetch("postBuildSourceSnapshotSha256"),
      "#{selector} post-build snapshot SHA-256",
    )
    unless Time.iso8601(postbuild_source_snapshot.fetch("capturedAt")) >=
           Time.iso8601(prebuild_source_snapshot.fetch("capturedAt"))
      raise Error, "#{selector} post-build materialized-source snapshot predates pre-build evidence"
    end
    build_settings_path = require_artifact(
      root, build,
      file_key: "settingsFile", sha_key: "settingsSha256",
      expected_file: "build-settings/#{selector}.json", label: "#{selector} build settings",
    )
    parsed_build_settings = QuakeSignalIOSBuildSettings.parse(build_settings_path.read)
    project_list_path = require_artifact(
      root, build,
      file_key: "projectListFile", sha_key: "projectListSha256",
      expected_file: "build-lists/#{selector}.json", label: "#{selector} Xcode project list",
    )
    result_bundle_archive_path = require_artifact(
      root, build,
      file_key: "resultBundleArchiveFile", sha_key: "resultBundleArchiveSha256",
      expected_file: "build-results/#{selector}.xcresult.zip", label: "#{selector} xcresult archive",
    )
    swift_inputs = require_json_artifact(
      root,
      {
        "file" => build.fetch("swiftInputsFile"),
        "sha256" => build.fetch("swiftInputsSha256"),
      },
      expected_file: "build-swift-inputs/#{selector}.json",
      label: "#{selector} Swift compiler inputs",
    )
    build_binding = require_json_artifact(
      root,
      {
        "file" => build.fetch("bindingFile"),
        "sha256" => build.fetch("bindingSha256"),
      },
      expected_file: "build-bindings/#{selector}.json",
      label: "#{selector} build binding",
    )
    validate_build_binding(
      build_binding,
      selector: selector,
      source: source,
      product: product,
      app: app,
      build: build,
      build_source: build_source,
      parsed_build_settings: parsed_build_settings,
      build_log_path: build_log_path,
      prebuild_source_snapshot: prebuild_source_snapshot,
      postbuild_source_snapshot: postbuild_source_snapshot,
      project_list_path: project_list_path,
      result_bundle_archive_path: result_bundle_archive_path,
      result_inspector: result_inspector,
      swift_inputs: swift_inputs,
    )

    install = require_json_artifact(
      root,
      evidence.fetch("installEvidence"),
      expected_file: "install-evidence/#{selector}.json",
      label: "#{selector} install evidence",
    )
    validate_install(
      root,
      install,
      selector: selector,
      environment: environment,
      app: app,
      binding_app: build_binding.fetch("app"),
    )

    launch = require_json_artifact(
      root,
      evidence.fetch("launchEvidence"),
      expected_file: "launch-evidence/#{selector}.json",
      label: "#{selector} launch evidence",
    )
    validate_launch(launch, selector: selector)

    semantic = evidence.fetch("semanticValidation")
    validate_semantic(
      root,
      semantic,
      selector: selector,
      frame: frame,
      expected_raw_sha256: evidence.fetch("artifacts").fetch("rawSimulator").fetch("sha256"),
      expected_final_sha256: evidence.fetch("artifacts").fetch("finalScreenshot").fetch("sha256"),
      image_inspector: image_inspector,
    )
    transformation = evidence.fetch("transformation")
    validate_transformation(root, transformation, selector: selector, frame: frame)
    validate_artifacts(root, evidence.fetch("artifacts"), selector: selector, frame: frame, image_inspector: image_inspector)

    {
      "captureSelector" => selector,
      "displayClass" => frame.fetch("displayClass"),
      "file" => frame.fetch("file"),
      "screen" => frame.fetch("screen"),
      "purpose" => frame.fetch("purpose"),
      "pixels" => frame.fetch("pixels"),
      "format" => "jpeg",
      "hasAlpha" => false,
      "sha256" => evidence.fetch("artifacts").fetch("finalScreenshot").fetch("sha256"),
      "rawFile" => evidence.fetch("artifacts").fetch("rawSimulator").fetch("file"),
      "rawSha256" => evidence.fetch("artifacts").fetch("rawSimulator").fetch("sha256"),
      "captureWindowUtc" => capture_window,
      "source" => source,
      "product" => product,
      "captureEnvironment" => environment,
      "app" => app,
      "build" => build,
      "buildSource" => build_source,
      "buildBinding" => build_binding,
      "installEvidence" => evidence.fetch("installEvidence"),
      "launchEvidence" => evidence.fetch("launchEvidence"),
      "semanticValidation" => semantic,
      "transformation" => transformation,
      "frameCaptureEvidenceFile" => evidence_relative,
      "frameCaptureEvidenceSha256" => Digest::SHA256.hexdigest(evidence_source),
      "reviewer" => nil,
      "approval" => nil,
    }
  rescue Errno::ENOENT, KeyError, TypeError, ArgumentError,
         QuakeSignalIOSBuildSettings::Error, QuakeSignalIOSScreenshotBuildBinding::Error,
         QuakeSignalIOSScreenshotSwiftInputs::Error, QuakeSignalSafeZipTree::Error,
         QuakeSignalIOSScreenshotBuildSource::Error => error
    raise Error, "invalid iOS/iPadOS capture evidence for #{selector}: #{error.message}"
  end
  private_class_method :validate_frame

  def validate_build_source(record, source_commit:, repository_root:, selector:)
    require_exact_keys(
      record,
      %w[
        schemaVersion status uploadApproved reviewer sourceCommit purpose sourceMaterialization
        mainProductInputs copyVerification projectTransformation materializedBuildSource
      ],
      "#{selector} build-source record",
    )
    require_equal(record.fetch("schemaVersion"), 1, "#{selector} build-source schemaVersion")
    require_equal(
      record.fetch("status"),
      "unapproved-debug-temporary-no-watch-build-source-evidence",
      "#{selector} build-source status",
    )
    require_equal(record.fetch("uploadApproved"), false, "#{selector} build-source uploadApproved")
    require_equal(record.fetch("reviewer"), nil, "#{selector} build-source reviewer")
    require_equal(record.fetch("sourceCommit"), source_commit, "#{selector} build-source commit")
    require_equal(
      record.fetch("purpose"),
      "credential-free iOS Simulator screenshot build on a host where the Watch platform component cannot resolve",
      "#{selector} build-source purpose",
    )
    materialization = record.fetch("sourceMaterialization")
    require_exact_keys(
      materialization,
      %w[method sourceCommit paths archiveProjectMatchesGitShow workingTreeMatchesArchive],
      "#{selector} source materialization",
    )
    require_equal(materialization.fetch("method"), "git-archive", "#{selector} source materialization method")
    require_equal(materialization.fetch("sourceCommit"), source_commit, "#{selector} materialized source commit")
    require_equal(materialization.fetch("paths"), QuakeSignalIOSScreenshotBuildSource::COPIED_INPUTS,
                  "#{selector} materialized input paths")
    require_equal(materialization.fetch("archiveProjectMatchesGitShow"), true,
                  "#{selector} archive/git-show equality")
    require_equal(materialization.fetch("workingTreeMatchesArchive"), true,
                  "#{selector} worktree/archive equality")

    source_files = QuakeSignalIOSScreenshotBuildSource.plain_input_files(repository_root)
    original_project = repository_root.join(QuakeSignalIOSScreenshotBuildSource::PROJECT_RELATIVE)
    nonproject = source_files.reject { |file| file == original_project }
    expected_manifest = QuakeSignalIOSScreenshotBuildSource.content_manifest(nonproject, repository_root)
    require_equal(record.fetch("mainProductInputs"), expected_manifest, "#{selector} main-product input manifest")

    copy = record.fetch("copyVerification")
    require_exact_keys(copy, %w[allNonProjectBytesIdentical copiedContentManifestSha256], "#{selector} copy verification")
    require_equal(copy.fetch("allNonProjectBytesIdentical"), true, "#{selector} copied input equality")
    require_equal(
      copy.fetch("copiedContentManifestSha256"),
      expected_manifest.fetch("contentManifestSha256"),
      "#{selector} copied input manifest",
    )

    original_source = original_project.binread
    transformed_source, removed = QuakeSignalIOSScreenshotBuildSource.remove_watch_embedding_references(original_source)
    transformation = record.fetch("projectTransformation")
    require_exact_keys(
      transformation,
      %w[
        originalFile temporaryFile originalSha256 temporarySha256 removedReferences
        removedDefinitionCount watchTargetDefinitionRetained mainTargetSourceAndResourcePhasesUnchanged
      ],
      "#{selector} project transformation",
    )
    require_equal(transformation.fetch("originalFile"), QuakeSignalIOSScreenshotBuildSource::PROJECT_RELATIVE,
                  "#{selector} original project file")
    require_equal(transformation.fetch("temporaryFile"), "ios/QuakeSignal.xcodeproj/project.pbxproj",
                  "#{selector} temporary project file")
    require_equal(transformation.fetch("originalSha256"), Digest::SHA256.hexdigest(original_source),
                  "#{selector} original project hash")
    require_equal(transformation.fetch("temporarySha256"), Digest::SHA256.hexdigest(transformed_source),
                  "#{selector} transformed project hash")
    require_equal(transformation.fetch("removedReferences"), removed, "#{selector} removed Watch references")
    require_equal(transformation.fetch("removedDefinitionCount"), 0, "#{selector} removed project definitions")
    require_equal(transformation.fetch("watchTargetDefinitionRetained"), true, "#{selector} retained Watch target")
    require_equal(
      transformation.fetch("mainTargetSourceAndResourcePhasesUnchanged"), true,
      "#{selector} unchanged main source/resource phases",
    )
    QuakeSignalIOSScreenshotBuildSource.validate_prepared_record(
      record,
      source_commit: source_commit,
    )
  rescue QuakeSignalIOSScreenshotBuildSource::Error => error
    raise Error, "#{selector} invalid temporary build-source evidence: #{error.message}"
  end
  private_class_method :validate_build_source

  def validate_build_binding(
    record, selector:, source:, product:, app:, build:, build_source:, parsed_build_settings:,
    build_log_path:, prebuild_source_snapshot:, postbuild_source_snapshot:, project_list_path:,
    result_bundle_archive_path:,
    result_inspector:, swift_inputs:
  )
    require_exact_keys(
      record,
      %w[
        schemaVersion status uploadApproved reviewer sourceCommit hostArchitecture configuration destination
        buildSourceEvidence buildSettings swiftCompilerInputs buildInvocationEvidence app
      ],
      "#{selector} build-binding record",
    )
    require_equal(record.fetch("schemaVersion"), 1, "#{selector} build-binding schemaVersion")
    require_equal(
      record.fetch("status"),
      "unapproved-debug-source-bound-ios-simulator-build",
      "#{selector} build-binding status",
    )
    require_equal(record.fetch("uploadApproved"), false, "#{selector} build-binding uploadApproved")
    require_equal(record.fetch("reviewer"), nil, "#{selector} build-binding reviewer")
    require_equal(record.fetch("sourceCommit"), source.fetch("commit"), "#{selector} build-binding source commit")
    require_equal(
      record.fetch("hostArchitecture"),
      parsed_build_settings.fetch("architectures"),
      "#{selector} build-binding host architecture",
    )
    require_equal(record.fetch("configuration"), product.fetch("configuration"), "#{selector} build-binding configuration")
    require_equal(record.fetch("destination"), product.fetch("destination"), "#{selector} build-binding destination")

    project = build_source.fetch("projectTransformation")
    materialized_manifest = build_source.fetch("materializedBuildSource")
    require_equal(
      record.fetch("buildSourceEvidence"),
      {
        "sha256" => build.fetch("sourceEvidenceSha256"),
        "originalProjectSha256" => project.fetch("originalSha256"),
        "transformedProjectSha256" => project.fetch("temporarySha256"),
        "materializedBuildSource" => {
          "preparedManifest" => materialized_manifest,
          "preBuildSnapshotSha256" => build.fetch("preBuildSourceSnapshotSha256"),
          "postBuildSnapshotSha256" => build.fetch("postBuildSourceSnapshotSha256"),
          "preBuildCapturedAt" => prebuild_source_snapshot.fetch("capturedAt"),
          "postBuildCapturedAt" => postbuild_source_snapshot.fetch("capturedAt"),
          "preBuildManifest" => prebuild_source_snapshot.fetch("materializedBuildSource"),
          "postBuildManifest" => postbuild_source_snapshot.fetch("materializedBuildSource"),
          "liveAtBindingManifest" => materialized_manifest,
          "preBuildContentManifestSha256" => materialized_manifest.fetch("contentManifestSha256"),
          "postBuildContentManifestSha256" => materialized_manifest.fetch("contentManifestSha256"),
          "liveAtBindingContentManifestSha256" => materialized_manifest.fetch("contentManifestSha256"),
          "prePostAndLiveExactlyMatchPrepared" => true,
        },
      },
      "#{selector} build-binding source evidence",
    )
    require_equal(
      record.fetch("buildSettings"),
      parsed_build_settings.merge("sha256" => build.fetch("settingsSha256")),
      "#{selector} build-binding settings",
    )
    QuakeSignalIOSScreenshotSwiftInputs.validate(
      swift_inputs,
      source_record: build_source,
      source_commit: source.fetch("commit"),
      architecture: record.fetch("hostArchitecture"),
    )
    require_equal(
      record.fetch("swiftCompilerInputs"),
      {
        "evidenceSha256" => build.fetch("swiftInputsSha256"),
        "normalizedContentSha256" => swift_inputs.fetch("fileList").fetch("normalizedContentSha256"),
        "authoredInputCount" => swift_inputs.fetch("authoredInputCount"),
        "generatedInputCount" => swift_inputs.fetch("generatedInputCount"),
      },
      "#{selector} build-binding Swift compiler inputs",
    )

    validate_build_log(build_log_path, selector: selector)
    project_list = parse_json(project_list_path.read, "#{selector} Xcode project list")
    QuakeSignalIOSScreenshotBuildBinding.validate_project_list(project_list)

    invocation = record.fetch("buildInvocationEvidence")
    require_exact_keys(
      invocation,
      %w[
        projectFile scheme action sdk destination projectListSha256 buildLogSha256
        resultBundleTree resultBundleArchiveSha256 resultSummary targetCount dependencyCount buildSucceeded
      ],
      "#{selector} build invocation evidence",
    )
    {
      "projectFile" => "ios/QuakeSignal.xcodeproj",
      "scheme" => "QuakeSignal",
      "action" => "build",
      "sdk" => "iphonesimulator",
      "destination" => product.fetch("destination"),
      "projectListSha256" => build.fetch("projectListSha256"),
      "buildLogSha256" => build.fetch("logSha256"),
      "resultBundleArchiveSha256" => build.fetch("resultBundleArchiveSha256"),
      "targetCount" => 1,
      "dependencyCount" => 0,
      "buildSucceeded" => true,
    }.each do |key, expected|
      require_equal(invocation.fetch(key), expected, "#{selector} build invocation #{key}")
    end
    validate_tree_manifest(invocation.fetch("resultBundleTree"), "#{selector} xcresult tree")
    actual_result_summary = nil
    actual_result_tree = nil
    QuakeSignalSafeZipTree.with_safe_extraction(archive: result_bundle_archive_path) do |extracted_result|
      actual_result_summary = result_inspector.call(extracted_result, record.fetch("hostArchitecture"))
      QuakeSignalIOSScreenshotBuildBinding.validate_xcresult_record(actual_result_summary)
      actual_result_tree = QuakeSignalIOSScreenshotBuildBinding.tree_manifest(extracted_result, "xcresult bundle")
    end
    require_equal(actual_result_tree, invocation.fetch("resultBundleTree"), "#{selector} retained xcresult tree")
    require_equal(actual_result_summary, invocation.fetch("resultSummary"), "#{selector} retained xcresult summary")
    prebuild_epoch = Time.iso8601(prebuild_source_snapshot.fetch("capturedAt")).to_f
    postbuild_epoch = Time.iso8601(postbuild_source_snapshot.fetch("capturedAt")).to_f
    unless prebuild_epoch <= actual_result_summary.fetch("startTime") &&
           postbuild_epoch >= actual_result_summary.fetch("endTime")
      raise Error, "#{selector} retained materialized-source snapshots do not bracket the xcresult build"
    end

    binding_app = record.fetch("app")
    require_exact_keys(
      binding_app,
      %w[
        bundleName bundleIdentifier marketingVersion build bundleTree watchPayloadPresent
        infoPlistSha256 mainExecutableFile mainExecutableSha256 productInspection
      ],
      "#{selector} build-binding app",
    )
    {
      "bundleName" => app.fetch("bundleName"),
      "bundleIdentifier" => product.fetch("bundleIdentifier"),
      "marketingVersion" => product.fetch("marketingVersion"),
      "build" => product.fetch("build"),
      "watchPayloadPresent" => false,
      "mainExecutableFile" => app.fetch("mainExecutableFile"),
      "mainExecutableSha256" => app.fetch("mainExecutableSha256"),
    }.each do |key, expected|
      require_equal(binding_app.fetch(key), expected, "#{selector} build-binding app #{key}")
    end
    bundle_tree = binding_app.fetch("bundleTree")
    validate_tree_manifest(bundle_tree, "#{selector} built app tree", forbid_watch: true)
    require_equal(
      bundle_tree.fetch("contentManifestSha256"),
      app.fetch("bundleTreeSha256"),
      "#{selector} build-binding app tree",
    )
    require_sha256(binding_app.fetch("infoPlistSha256"), "#{selector} build-binding Info.plist")
    require_equal(
      tree_file(bundle_tree, "Info.plist", "#{selector} built app tree").fetch("sha256"),
      binding_app.fetch("infoPlistSha256"),
      "#{selector} build-binding Info.plist tree entry",
    )
    require_equal(
      tree_file(bundle_tree, binding_app.fetch("mainExecutableFile"), "#{selector} built app tree").fetch("sha256"),
      binding_app.fetch("mainExecutableSha256"),
      "#{selector} build-binding executable tree entry",
    )
    validate_product_inspection(
      binding_app.fetch("productInspection"),
      architecture: record.fetch("hostArchitecture"),
      selector: selector,
    )
  end
  private_class_method :validate_build_binding

  def validate_build_log(path, selector:)
    source = path.read
    unless source.include?("Build description signature:") &&
           source.include?("Target dependency graph (1 target)") &&
           source.match?(/Target ['\"]?QuakeSignal['\"]? in project ['\"]?QuakeSignal['\"]? \(no dependencies\)/) &&
           source.include?("** BUILD SUCCEEDED **") &&
           !source.include?("QuakeSignalWatch") &&
           !source.include?("Embed Watch Content") &&
           !source.include?("watchsimulator")
      raise Error, "#{selector} build log does not prove one successful QuakeSignal-only target graph"
    end
  end
  private_class_method :validate_build_log

  def validate_tree_manifest(record, label, forbid_watch: false)
    require_exact_keys(record, %w[algorithm fileCount totalBytes contentManifestSha256 files], label)
    require_equal(record.fetch("algorithm"), QuakeSignalIOSScreenshotBuildBinding::TREE_ALGORITHM, "#{label} algorithm")
    require_sha256(record.fetch("contentManifestSha256"), "#{label} content manifest")
    files = record.fetch("files")
    unless files.is_a?(Array) && !files.empty? && record.fetch("fileCount") == files.length &&
           record.fetch("totalBytes").is_a?(Integer) && record.fetch("totalBytes") >= 0
      raise Error, "#{label} inventory is invalid"
    end
    records = files.map do |file|
      require_exact_keys(file, %w[file sha256 bytes], "#{label} file")
      relative = file.fetch("file")
      validate_safe_relative_path(relative, "#{label} file")
      if forbid_watch && (relative == "Watch" || relative.start_with?("Watch/"))
        raise Error, "#{label} contains a Watch payload"
      end
      require_sha256(file.fetch("sha256"), "#{label} file")
      unless file.fetch("bytes").is_a?(Integer) && file.fetch("bytes") >= 0
        raise Error, "#{label} file byte count is invalid"
      end
      "#{file.fetch('sha256')}  #{relative}\n"
    end
    paths = files.map { |file| file.fetch("file") }
    unless paths == paths.sort && paths.uniq.length == paths.length &&
           files.sum { |file| file.fetch("bytes") } == record.fetch("totalBytes") &&
           Digest::SHA256.hexdigest(records.sort.join) == record.fetch("contentManifestSha256")
      raise Error, "#{label} content manifest is invalid"
    end
    record
  end
  private_class_method :validate_tree_manifest

  def tree_file(manifest, relative, label)
    validate_safe_relative_path(relative, "#{label} requested file")
    matches = manifest.fetch("files").select { |file| file.fetch("file") == relative }
    raise Error, "#{label} must contain exactly one #{relative}" unless matches.length == 1

    matches.first
  end
  private_class_method :tree_file

  def validate_product_inspection(record, architecture:, selector:)
    require_exact_keys(record, %w[file vtool codesign], "#{selector} product inspection")
    expected_commands = {
      "file" => ["/usr/bin/file", "-b"],
      "vtool" => ["xcrun", "vtool", "-show-build"],
      "codesign" => ["/usr/bin/codesign", "-dvvv"],
    }
    expected_commands.each do |kind, command|
      inspection = record.fetch(kind)
      require_exact_keys(inspection, %w[command exitStatus output], "#{selector} #{kind} inspection")
      require_equal(inspection.fetch("command"), command, "#{selector} #{kind} command")
      unless inspection.fetch("exitStatus").is_a?(Integer) && inspection.fetch("exitStatus") >= 0 &&
             inspection.fetch("output").is_a?(String) && !inspection.fetch("output").empty?
        raise Error, "#{selector} #{kind} inspection result is invalid"
      end
    end
    file_record = record.fetch("file")
    unless file_record.fetch("exitStatus").zero? && file_record.fetch("output").include?("Mach-O") &&
           file_record.fetch("output").include?(architecture) && !file_record.fetch("output").downcase.include?("universal")
      raise Error, "#{selector} executable inspection is not one #{architecture} Mach-O"
    end
    vtool_record = record.fetch("vtool")
    unless vtool_record.fetch("exitStatus").zero? && vtool_record.fetch("output").include?("platform IOSSIMULATOR")
      raise Error, "#{selector} executable inspection is not an iOS Simulator product"
    end
    signature = record.fetch("codesign").fetch("output")
    unless signature.include?("TeamIdentifier=not set") || signature.include?("not signed at all")
      raise Error, "#{selector} product inspection contains a team-bound code signature"
    end
  end
  private_class_method :validate_product_inspection

  def validate_install(root, record, selector:, environment:, app:, binding_app:)
    require_exact_keys(
      record,
      %w[
        schemaVersion captureSelector simulatorDeviceIdentifier installExitStatus
        installLogFile installLogSha256 installedAppContainer bundleName bundleTree
        watchPayloadPresent infoPlistSha256 mainExecutableFile mainExecutableSha256
      ],
      "#{selector} install record",
    )
    require_equal(record.fetch("schemaVersion"), 1, "#{selector} install schemaVersion")
    require_equal(record.fetch("captureSelector"), selector, "#{selector} install selector")
    require_equal(
      record.fetch("simulatorDeviceIdentifier"),
      environment.fetch("deviceIdentifier"),
      "#{selector} install simulator",
    )
    require_equal(record.fetch("installExitStatus"), 0, "#{selector} install status")
    require_artifact(
      root,
      record,
      file_key: "installLogFile",
      sha_key: "installLogSha256",
      expected_file: "install-logs/#{selector}.log",
      label: "#{selector} install log",
    )
    installed_container = record.fetch("installedAppContainer")
    unless installed_container.is_a?(String) && Pathname.new(installed_container).absolute? &&
           Pathname.new(installed_container).cleanpath.to_s == installed_container &&
           Pathname.new(installed_container).basename.to_s == "QuakeSignal.app" &&
           installed_container.include?("/Devices/#{environment.fetch('deviceIdentifier')}/")
      raise Error, "#{selector} installed app container is not the canonical simulator QuakeSignal.app path"
    end
    require_equal(record.fetch("bundleName"), "QuakeSignal.app", "#{selector} installed bundle name")
    require_equal(record.fetch("bundleTree"), binding_app.fetch("bundleTree"), "#{selector} installed bundle tree")
    validate_tree_manifest(record.fetch("bundleTree"), "#{selector} installed app tree", forbid_watch: true)
    require_equal(
      record.fetch("bundleTree").fetch("contentManifestSha256"),
      app.fetch("bundleTreeSha256"),
      "#{selector} installed app/frame tree",
    )
    require_equal(record.fetch("watchPayloadPresent"), false, "#{selector} installed Watch payload")
    require_equal(record.fetch("infoPlistSha256"), binding_app.fetch("infoPlistSha256"),
                  "#{selector} installed Info.plist")
    require_equal(record.fetch("mainExecutableFile"), binding_app.fetch("mainExecutableFile"),
                  "#{selector} installed executable file")
    require_equal(record.fetch("mainExecutableSha256"), binding_app.fetch("mainExecutableSha256"),
                  "#{selector} installed executable")
  end
  private_class_method :validate_install

  def validate_simulator_lease(record, source_commit:, devices:, runtime_identifier:)
    require_exact_keys(
      record,
      %w[schemaVersion status sourceCommit token ownerProcessId simulators],
      "simulator lease record",
    )
    require_equal(record.fetch("schemaVersion"), 1, "simulator lease schemaVersion")
    require_equal(
      record.fetch("status"),
      "active-disposable-ios-screenshot-simulator-lease",
      "simulator lease status",
    )
    require_equal(record.fetch("sourceCommit"), source_commit, "simulator lease source commit")
    token = record.fetch("token")
    unless token.is_a?(String) && token.match?(/\A[0-9a-f]{32}\z/)
      raise Error, "simulator lease token is invalid"
    end
    unless record.fetch("ownerProcessId").is_a?(Integer) && record.fetch("ownerProcessId").positive?
      raise Error, "simulator lease ownerProcessId must be positive"
    end
    simulators = record.fetch("simulators")
    unless simulators.is_a?(Array) && simulators.length == 2
      raise Error, "simulator lease must contain exactly two assigned simulator records"
    end
    expected_names = simulator_lease_names(token)
    %w[iphone-6.5 ipad-13].each_with_index do |display_class, index|
      simulator = simulators.fetch(index)
      require_exact_keys(
        simulator,
        %w[displayClass name runtimeIdentifier deviceTypeIdentifier deviceIdentifier],
        "#{display_class} simulator lease",
      )
      device = devices.find { |candidate| candidate.fetch("displayClass") == display_class }
      {
        "displayClass" => display_class,
        "name" => expected_names.fetch(display_class),
        "runtimeIdentifier" => runtime_identifier,
        "deviceTypeIdentifier" => device.fetch("deviceTypeIdentifier"),
        "deviceIdentifier" => device.fetch("deviceIdentifier"),
      }.each do |key, expected|
        require_equal(simulator.fetch(key), expected, "#{display_class} simulator lease #{key}")
      end
    end
  end
  private_class_method :validate_simulator_lease

  def validate_simulator_cleanup(
    record, source_commit:, devices:, runtime_identifier:, completed_at:,
    lease_record:, lease_reference:, root:
  )
    require_exact_keys(
      record,
      %w[schemaVersion status sourceCommit leaseToken leaseEvidence simulators verifiedAtUtc],
      "simulator cleanup record",
    )
    require_equal(record.fetch("schemaVersion"), 1, "simulator cleanup schemaVersion")
    require_equal(
      record.fetch("status"),
      "verified-disposable-ios-simulators-removed-before-publication",
      "simulator cleanup status",
    )
    require_equal(record.fetch("sourceCommit"), source_commit, "simulator cleanup source commit")
    lease_token = record.fetch("leaseToken")
    unless lease_token.is_a?(String) && lease_token.match?(/\A[0-9a-f]{32}\z/)
      raise Error, "simulator cleanup leaseToken is invalid"
    end
    require_equal(lease_token, lease_record.fetch("token"), "simulator cleanup/lease token")
    require_equal(record.fetch("leaseEvidence"), lease_reference, "simulator cleanup lease evidence")
    simulators = record.fetch("simulators")
    unless simulators.is_a?(Array) && simulators.length == 2
      raise Error, "simulator cleanup must contain exactly two simulator records"
    end
    expected_names = simulator_lease_names(lease_token)
    query_files = []
    %w[iphone-6.5 ipad-13].each_with_index do |display_class, index|
      simulator = simulators.fetch(index)
      require_exact_keys(
        simulator,
        %w[
          displayClass name deviceIdentifier runtimeIdentifier deviceTypeIdentifier
          shutdownRequested deleteRequested absentAfterDelete absenceQueries
        ],
        "#{display_class} simulator cleanup",
      )
      device = devices.find { |candidate| candidate.fetch("displayClass") == display_class }
      {
        "displayClass" => display_class,
        "name" => expected_names.fetch(display_class),
        "deviceIdentifier" => device.fetch("deviceIdentifier"),
        "runtimeIdentifier" => runtime_identifier,
        "deviceTypeIdentifier" => device.fetch("deviceTypeIdentifier"),
        "shutdownRequested" => true,
        "deleteRequested" => true,
        "absentAfterDelete" => true,
      }.each do |key, expected|
        require_equal(simulator.fetch(key), expected, "#{display_class} simulator cleanup #{key}")
      end
      require_equal(
        simulator.slice("displayClass", "name", "runtimeIdentifier", "deviceTypeIdentifier", "deviceIdentifier"),
        lease_record.fetch("simulators").fetch(index),
        "#{display_class} cleanup/lease simulator assignment",
      )
      queries = simulator.fetch("absenceQueries")
      unless queries.is_a?(Array) && queries.length == 2
        raise Error, "#{display_class} cleanup must contain exactly two absence queries"
      end
      expected_queries = [
        {
          "kind" => "deviceIdentifier",
          "query" => device.fetch("deviceIdentifier"),
          "file" => "simulator-absence-evidence/#{display_class}-uuid.json",
        },
        {
          "kind" => "leaseName",
          "query" => expected_names.fetch(display_class),
          "file" => "simulator-absence-evidence/#{display_class}-name.json",
        },
      ]
      queries.each_with_index do |query, query_index|
        require_exact_keys(query, %w[kind query file sha256 exitStatus], "#{display_class} absence query")
        expected_query = expected_queries.fetch(query_index)
        expected_query.each do |key, expected|
          require_equal(query.fetch(key), expected, "#{display_class} absence query #{key}")
        end
        require_equal(query.fetch("exitStatus"), 0, "#{display_class} absence query exitStatus")
        snapshot = require_json_artifact(
          root,
          query,
          expected_file: expected_query.fetch("file"),
          label: "#{display_class} #{query.fetch('kind')} absence snapshot",
          allowed_extra_keys: %w[kind query exitStatus],
        )
        validate_absence_snapshot(snapshot, runtime_identifier: runtime_identifier, label: "#{display_class} #{query.fetch('kind')}")
        query_files << query.fetch("file")
      end
    end
    unless query_files.uniq.length == 4
      raise Error, "simulator cleanup absence-query artifact paths are not unique"
    end
    verified = require_utc_time(record.fetch("verifiedAtUtc"), "simulator cleanup verifiedAtUtc")
    completed = require_utc_time(completed_at, "aggregate capture completedAt")
    raise Error, "simulator cleanup was verified before frame capture completed" if verified < completed
  end
  private_class_method :validate_simulator_cleanup

  def validate_absence_snapshot(record, runtime_identifier:, label:)
    require_exact_keys(record, ["devices"], "#{label} absence snapshot")
    devices = record.fetch("devices")
    unless devices.is_a?(Hash) && !devices.empty? && devices.key?(runtime_identifier) &&
           devices.keys.all? { |key| key.is_a?(String) && !key.empty? } &&
           devices.values.all? { |value| value == [] }
      raise Error, "#{label} absence snapshot must contain only empty runtime device arrays"
    end
  end
  private_class_method :validate_absence_snapshot

  def simulator_lease_names(token)
    {
      "iphone-6.5" => "QuakeSignal iPhone screenshot set #{token}",
      "ipad-13" => "QuakeSignal iPad screenshot set #{token}",
    }
  end
  private_class_method :simulator_lease_names

  def require_simulator_udid(value, label)
    unless value.is_a?(String) &&
           value.match?(/\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z/)
      raise Error, "#{label} is not a canonical CoreSimulator UUID"
    end
    value
  end
  private_class_method :require_simulator_udid

  def validate_launch(record, selector:)
    require_exact_keys(
      record,
      %w[
        schemaVersion captureSelector processId launchArgumentGatePresent
        launchEnvironmentGatePresent frameArgumentEnvironmentMatch appleLanguages
        appleLocale timeZone appearance statusBarTime captureAttemptCount
        retryPerformed stdoutSha256 stderrSha256
      ],
      "#{selector} launch record",
    )
    require_equal(record.fetch("schemaVersion"), 1, "#{selector} launch schemaVersion")
    require_equal(record.fetch("captureSelector"), selector, "#{selector} launch selector")
    unless record.fetch("processId").is_a?(Integer) && record.fetch("processId").positive?
      raise Error, "#{selector} launch processId must be positive"
    end
    %w[launchArgumentGatePresent launchEnvironmentGatePresent frameArgumentEnvironmentMatch].each do |key|
      require_equal(record.fetch(key), true, "#{selector} launch #{key}")
    end
    require_equal(record.fetch("appleLanguages"), ["en"], "#{selector} Apple languages")
    require_equal(record.fetch("appleLocale"), "en_US", "#{selector} Apple locale")
    require_equal(record.fetch("timeZone"), "UTC", "#{selector} time zone")
    require_equal(record.fetch("appearance"), "dark", "#{selector} appearance")
    require_equal(record.fetch("statusBarTime"), "9:41", "#{selector} status-bar time")
    attempts = record.fetch("captureAttemptCount")
    unless [1, 2].include?(attempts)
      raise Error, "#{selector} launch captureAttemptCount must be 1 or 2"
    end
    require_equal(record.fetch("retryPerformed"), attempts == 2, "#{selector} launch retry binding")
    require_sha256(record.fetch("stdoutSha256"), "#{selector} stdout log")
    require_sha256(record.fetch("stderrSha256"), "#{selector} stderr log")
  end
  private_class_method :validate_launch

  def validate_semantic(
    root,
    semantic,
    selector:,
    frame:,
    expected_raw_sha256:,
    expected_final_sha256:,
    image_inspector:
  )
    require_exact_keys(
      semantic,
      %w[status settleSeconds captureAttemptCount retryPerformed rawEvidence finalEvidence firstRejection],
      "#{selector} semanticValidation",
    )
    require_equal(semantic.fetch("status"), "accepted", "#{selector} semantic status")
    require_equal(semantic.fetch("settleSeconds"), 8, "#{selector} semantic settle")
    attempts = semantic.fetch("captureAttemptCount")
    unless [1, 2].include?(attempts)
      raise Error, "#{selector} semantic captureAttemptCount must be 1 or 2"
    end
    require_equal(semantic.fetch("retryPerformed"), attempts == 2, "#{selector} semantic retry binding")
    require_equal(
      semantic.fetch("rawEvidence").fetch("status"),
      "accepted",
      "#{selector} raw semantic evidence status",
    )
    raw_record = require_json_artifact(
      root,
      semantic.fetch("rawEvidence"),
      expected_file: "semantic-evidence/#{selector}-raw.json",
      label: "#{selector} accepted raw semantic evidence",
      allowed_extra_keys: %w[status],
    )
    validate_semantic_record(
      raw_record,
      selector: selector,
      frame: frame,
      expected_status: "accepted",
      expected_image_format: "png",
      expected_image_sha256: expected_raw_sha256,
    )
    require_equal(
      semantic.fetch("finalEvidence").fetch("status"),
      "accepted",
      "#{selector} final semantic evidence status",
    )
    final_record = require_json_artifact(
      root,
      semantic.fetch("finalEvidence"),
      expected_file: "semantic-evidence/#{selector}-final.json",
      label: "#{selector} accepted final semantic evidence",
      allowed_extra_keys: %w[status],
    )
    validate_semantic_record(
      final_record,
      selector: selector,
      frame: frame,
      expected_status: "accepted",
      expected_image_format: "jpeg",
      expected_image_sha256: expected_final_sha256,
    )
    rejection = semantic.fetch("firstRejection")
    if attempts == 1
      require_equal(rejection, nil, "#{selector} first rejection")
    else
      require_exact_keys(
        rejection,
        %w[file sha256 status validatorExitStatus imageFile imageSha256],
        "#{selector} first rejection",
      )
      require_equal(rejection.fetch("status"), "rejected", "#{selector} first rejection status")
      require_equal(rejection.fetch("validatorExitStatus"), 65, "#{selector} first rejection exit status")
      rejected_record = require_json_artifact(
        root,
        rejection,
        expected_file: "semantic-rejections/#{selector}-attempt-1.json",
        label: "#{selector} first rejection evidence",
        allowed_extra_keys: %w[status validatorExitStatus imageFile imageSha256],
      )
      rejected_image = require_artifact(
        root,
        rejection,
        file_key: "imageFile",
        sha_key: "imageSha256",
        expected_file: "semantic-rejections/#{selector}-attempt-1.png",
        label: "#{selector} first rejected raw capture",
      )
      rejected_image_properties = image_inspector.inspect(rejected_image)
      require_equal(
        rejected_image_properties.fetch("pixels"),
        frame.fetch("pixels"),
        "#{selector} first rejected raw capture pixels",
      )
      require_equal(
        rejected_image_properties.fetch("format"),
        "png",
        "#{selector} first rejected raw capture format",
      )
      unless [true, false].include?(rejected_image_properties.fetch("hasAlpha"))
        raise Error, "#{selector} first rejected raw capture alpha state is invalid"
      end
      validate_semantic_record(
        rejected_record,
        selector: selector,
        frame: frame,
        expected_status: "rejected",
        expected_image_format: "png",
        expected_image_sha256: rejection.fetch("imageSha256"),
      )
    end
  end
  private_class_method :validate_semantic

  def validate_semantic_record(
    record,
    selector:,
    frame:,
    expected_status:,
    expected_image_format:,
    expected_image_sha256:
  )
    require_exact_keys(
      record,
      %w[schemaVersion status captureSelector imageSha256 imageFormat pixels reasons checks],
      "#{selector} semantic record",
    )
    require_equal(record.fetch("schemaVersion"), 1, "#{selector} semantic schemaVersion")
    require_equal(record.fetch("status"), expected_status, "#{selector} semantic record status")
    require_equal(record.fetch("captureSelector"), selector, "#{selector} semantic selector")
    require_equal(record.fetch("pixels"), frame.fetch("pixels"), "#{selector} semantic pixels")
    require_sha256(record.fetch("imageSha256"), "#{selector} semantic image")
    checks = record.fetch("checks")
    require_exact_keys(
      checks,
      %w[committedView recognizedText matchedRequiredTermGroups matchedForbiddenSystemPromptGroups],
      "#{selector} semantic checks",
    )
    committed = checks.fetch("committedView")
    require_exact_keys(
      committed,
      %w[luminanceStandardDeviation nonBlackFraction brightFraction chromaticFraction horizontalEdgeFraction sampledPixels],
      "#{selector} committed-view checks",
    )
    %w[nonBlackFraction brightFraction chromaticFraction horizontalEdgeFraction].each do |key|
      value = committed.fetch(key)
      unless value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
        raise Error, "#{selector} #{key} must be finite and between zero and one"
      end
    end
    if committed.fetch("brightFraction") > committed.fetch("nonBlackFraction")
      raise Error, "#{selector} brightFraction cannot exceed nonBlackFraction"
    end
    deviation = committed.fetch("luminanceStandardDeviation")
    unless deviation.is_a?(Numeric) && deviation.finite? && deviation.between?(0, 127.5)
      raise Error, "#{selector} luminanceStandardDeviation is invalid"
    end
    expected_samples = ((frame.fetch("pixels").fetch(0) + 7) / 8) * ((frame.fetch("pixels").fetch(1) + 7) / 8)
    require_equal(committed.fetch("sampledPixels"), expected_samples, "#{selector} semantic sample count")
    recognized = checks.fetch("recognizedText")
    unless recognized.is_a?(Array) && recognized.all? { |value| value.is_a?(String) && !value.strip.empty? }
      raise Error, "#{selector} recognized-text inventory is invalid"
    end
    route = selector.sub(/\Aios-(?:iphone-6\.5|ipad-13)-/, "")
    expected_groups = SEMANTIC_ROUTE_TERM_GROUPS.fetch(route)
    searchable_text = normalize_semantic_text(recognized.join(" "))
    matched_required_groups = expected_groups.select do |alternatives|
      alternatives.any? { |term| searchable_text.include?(normalize_semantic_text(term)) }
    end
    matched_forbidden_groups = FORBIDDEN_SYSTEM_PROMPT_TERM_GROUPS.select do |alternatives|
      alternatives.any? { |term| searchable_text.include?(normalize_semantic_text(term)) }
    end
    require_equal(
      checks.fetch("matchedRequiredTermGroups"),
      matched_required_groups,
      "#{selector} derived required semantic terms",
    )
    require_equal(
      checks.fetch("matchedForbiddenSystemPromptGroups"),
      matched_forbidden_groups,
      "#{selector} derived forbidden system-prompt terms",
    )

    derived_reasons = []
    derived_reasons << "committed-view luminance variation is too low" if deviation < 12
    minimum_non_black_fraction = MINIMUM_NON_BLACK_FRACTION_BY_SELECTOR.fetch(
      selector,
      DEFAULT_MINIMUM_NON_BLACK_FRACTION,
    )
    if committed.fetch("nonBlackFraction") < minimum_non_black_fraction
      derived_reasons << "committed-view non-black coverage is too low"
    end
    derived_reasons << "committed-view bright-detail coverage is too low" if committed.fetch("brightFraction") < 0.004
    derived_reasons << "committed-view edge detail is too low" if committed.fetch("horizontalEdgeFraction") < 0.004
    derived_reasons << "committed-view recognized text inventory is too small" if recognized.length < 5
    derived_reasons << "requested route terms are missing" if matched_required_groups.length != expected_groups.length
    derived_reasons << "a system permission dialog is visible" unless matched_forbidden_groups.empty?
    if route == "map" && committed.fetch("chromaticFraction") < 0.02
      derived_reasons << "map chromatic content is too low"
    end
    require_equal(record.fetch("reasons"), derived_reasons, "#{selector} derived semantic reasons")
    require_equal(
      record.fetch("status"),
      derived_reasons.empty? ? "accepted" : "rejected",
      "#{selector} derived semantic status",
    )
    require_equal(record.fetch("imageFormat"), expected_image_format, "#{selector} semantic image format")
    require_equal(record.fetch("imageSha256"), expected_image_sha256, "#{selector} semantic image binding")
    if expected_status == "accepted"
      require_equal(derived_reasons, [], "#{selector} accepted semantic reasons")
    elsif derived_reasons.empty?
      raise Error, "#{selector} rejected semantic evidence requires one derived reason"
    end
  end
  private_class_method :validate_semantic_record

  def normalize_semantic_text(value)
    value.downcase.gsub(/[^a-z0-9+.]+/, " ").strip
  end
  private_class_method :normalize_semantic_text

  def validate_transformation(root, transformation, selector:, frame:)
    require_exact_keys(
      transformation,
      %w[file sha256 operation resizePerformed encoder quality],
      "#{selector} transformation",
    )
    record = require_json_artifact(
      root,
      transformation,
      expected_file: "transformation-evidence/#{selector}.json",
      label: "#{selector} transformation evidence",
      allowed_extra_keys: %w[operation resizePerformed encoder quality],
    )
    expected = {
      "schemaVersion" => 1,
      "captureSelector" => selector,
      "operation" => "format-conversion",
      "rawFormat" => "png",
      "finalFormat" => "jpeg",
      "encoder" => "sips",
      "quality" => 100,
      "resizePerformed" => false,
      "finalHasAlpha" => false,
      "pixels" => frame.fetch("pixels"),
    }
    expected.each do |key, value|
      require_equal(record.fetch(key), value, "#{selector} transformation #{key}")
    end
    unless [true, false].include?(record.fetch("rawHasAlpha"))
      raise Error, "#{selector} transformation rawHasAlpha must be Boolean"
    end
    %w[operation resizePerformed encoder quality].each do |key|
      require_equal(transformation.fetch(key), record.fetch(key), "#{selector} transformation binding #{key}")
    end
    require_exact_keys(record, expected.keys + ["rawHasAlpha"], "#{selector} transformation record")
  end
  private_class_method :validate_transformation

  def validate_artifacts(root, artifacts, selector:, frame:, image_inspector:)
    require_exact_keys(artifacts, %w[rawSimulator finalScreenshot stdoutLog stderrLog], "#{selector} artifacts")
    raw = artifacts.fetch("rawSimulator")
    final = artifacts.fetch("finalScreenshot")
    validate_image_artifact(
      root, raw,
      expected_file: "raw-simulator-captures/#{selector}.png",
      expected_pixels: frame.fetch("pixels"), expected_format: "png",
      expected_alpha: raw.fetch("hasAlpha"), image_inspector: image_inspector,
      label: "#{selector} raw simulator capture",
    )
    validate_image_artifact(
      root, final,
      expected_file: frame.fetch("file"), expected_pixels: frame.fetch("pixels"),
      expected_format: "jpeg", expected_alpha: false, image_inspector: image_inspector,
      label: "#{selector} final screenshot",
    )
    require_equal(final.fetch("hasAlpha"), false, "#{selector} final alpha")
    require_artifact(root, artifacts.fetch("stdoutLog"), expected_file: "app-logs/#{selector}.stdout.log", label: "#{selector} stdout log")
    require_artifact(root, artifacts.fetch("stderrLog"), expected_file: "app-logs/#{selector}.stderr.log", label: "#{selector} stderr log")
  end
  private_class_method :validate_artifacts

  def validate_image_artifact(root, record, expected_file:, expected_pixels:, expected_format:, expected_alpha:, image_inspector:, label:)
    require_exact_keys(record, %w[file sha256 pixels format hasAlpha], label)
    require_equal(record.fetch("pixels"), expected_pixels, "#{label} recorded pixels")
    require_equal(record.fetch("format"), expected_format, "#{label} recorded format")
    require_equal(record.fetch("hasAlpha"), expected_alpha, "#{label} recorded alpha")
    path = require_artifact(root, record, expected_file: expected_file, label: label)
    actual = image_inspector.inspect(path)
    require_equal(actual.fetch("pixels"), expected_pixels, "#{label} actual pixels")
    require_equal(actual.fetch("format"), expected_format, "#{label} actual format")
    require_equal(actual.fetch("hasAlpha"), expected_alpha, "#{label} actual alpha")
  end
  private_class_method :validate_image_artifact

  def validate_capture_window(window, selector)
    require_exact_keys(window, %w[startedAt completedAt], "#{selector} captureWindowUtc")
    started = require_utc_time(window.fetch("startedAt"), "#{selector} capture startedAt")
    completed = require_utc_time(window.fetch("completedAt"), "#{selector} capture completedAt")
    raise Error, "#{selector} capture completed before it started" if completed < started
    { "startedAt" => started.iso8601, "completedAt" => completed.iso8601 }
  end
  private_class_method :validate_capture_window

  def require_json_artifact(root, record, expected_file:, label:, allowed_extra_keys: [])
    require_exact_keys(record, %w[file sha256] + allowed_extra_keys, label)
    path = require_artifact(root, record, expected_file: expected_file, label: label)
    parse_json(path.read, expected_file)
  end
  private_class_method :require_json_artifact

  def require_artifact(root, record, expected_file:, label:, file_key: "file", sha_key: "sha256")
    require_equal(record.fetch(file_key), expected_file, "#{label} file")
    require_sha256(record.fetch(sha_key), "#{label} SHA-256")
    validate_safe_relative_path(expected_file, "#{label} file")
    path = root.join(expected_file)
    stat = path.lstat
    unless stat.file? && !path.symlink? && path.size >= 0
      raise Error, "#{label} is not a plain file"
    end
    require_equal(Digest::SHA256.file(path).hexdigest, record.fetch(sha_key), "#{label} actual SHA-256")
    path
  rescue Errno::ENOENT
    raise Error, "#{label} is missing"
  end
  private_class_method :require_artifact

  def standalone_artifact_reference(root, relative, label)
    validate_safe_relative_path(relative, "#{label} file")
    path = root.join(relative)
    stat = path.lstat
    unless stat.file? && !path.symlink?
      raise Error, "#{label} is not a plain file"
    end
    {
      "file" => relative,
      "sha256" => Digest::SHA256.file(path).hexdigest,
    }
  rescue Errno::ENOENT
    raise Error, "#{label} is missing"
  end
  private_class_method :standalone_artifact_reference

  def capture_inventory(root)
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
          raise Error, "capture inventory contains a symlink or non-regular entry: #{relative}"
        end
      end
    end
    visit.call(root)
    [directories.sort, files.sort]
  rescue Errno::ENOENT => error
    raise Error, "capture inventory changed while inspected: #{error.message}"
  end
  private_class_method :capture_inventory

  def parse_json(source, label)
    JSON.parse(
      source,
      object_class: QuakeSignalIOSScreenshotPlan::DuplicateRejectingHash,
      allow_duplicate_key: false,
    )
  rescue JSON::ParserError, QuakeSignalIOSScreenshotPlan::Error => error
    raise Error, "invalid JSON in #{label}: #{error.message}"
  end
  private_class_method :parse_json

  def validate_safe_relative_path(value, label)
    unless value.is_a?(String) && !value.empty? && !Pathname.new(value).absolute? &&
        Pathname.new(value).cleanpath.to_s == value &&
        value.split(File::SEPARATOR).none? { |segment| segment.empty? || segment == "." || segment == ".." }
      raise Error, "#{label} must be a normalized relative path"
    end
  end
  private_class_method :validate_safe_relative_path

  def require_exact_keys(value, expected, label)
    unless value.is_a?(Hash)
      raise Error, "#{label} must be an object"
    end
    require_equal(value.keys.sort, expected.sort, "#{label} keys")
  end
  private_class_method :require_exact_keys

  def require_sha256(value, label)
    return if value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)

    raise Error, "#{label} must be a lowercase SHA-256"
  end
  private_class_method :require_sha256

  def require_nonempty_string(value, label)
    return if value.is_a?(String) && !value.strip.empty?

    raise Error, "#{label} must be a non-empty string"
  end
  private_class_method :require_nonempty_string

  def require_utc_time(value, label)
    unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      raise Error, "#{label} must be whole-second UTC"
    end
    parsed = Time.iso8601(value)
    raise Error, "#{label} is not canonical UTC" unless parsed.utc? && parsed.iso8601 == value

    parsed
  rescue ArgumentError => error
    raise Error, "#{label} is invalid: #{error.message}"
  end
  private_class_method :require_utc_time

  def require_equal(actual, expected, label)
    return if actual == expected

    raise Error, "#{label} must be #{expected.inspect}; received #{actual.inspect}"
  end
  private_class_method :require_equal
end

if $PROGRAM_NAME == __FILE__
  begin
    unless ARGV.length == 2
      abort "Usage: assemble-ios-screenshot-provenance.rb <capture-root> <output.json>"
    end
    QuakeSignalIOSScreenshotProvenance.assemble(
      capture_root: ARGV.fetch(0),
      output: ARGV.fetch(1),
    )
  rescue QuakeSignalIOSScreenshotProvenance::Error => error
    warn "error: #{error.message}"
    exit 65
  end
end
