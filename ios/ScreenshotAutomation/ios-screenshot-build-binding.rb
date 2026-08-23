#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require_relative "parse-ios-screenshot-build-settings"
require_relative "prepare-ios-screenshot-build-source"
require_relative "safe-zip-tree"
require_relative "ios-screenshot-swift-inputs"

module QuakeSignalIOSScreenshotBuildBinding
  class Error < StandardError; end

  class DuplicateRejectingHash < Hash
    def []=(key, value)
      raise Error, "duplicate build-binding JSON key #{key.inspect}" if key?(key)

      super
    end
  end

  TREE_ALGORITHM = "sha256 of sorted UTF-8 records: <file-sha256><two spaces><app-relative-path><newline>"
  EXPECTED_REMOVED_REFERENCES = QuakeSignalIOSScreenshotBuildSource::EXPECTED_REMOVED_REFERENCES

  module_function

  def record(
    source_commit:, build_source_evidence:, build_settings:, build_log:,
    build_list:, result_bundle_archive:, swift_inputs:, app:, prebuild_source_snapshot:,
    postbuild_source_snapshot:, build_ios_root: nil, result_inspector: method(:inspect_xcresult),
    allow_retained_materialized_source: false
  )
    require_commit(source_commit)
    source_path, source_source, source_record = QuakeSignalIOSScreenshotBuildSource.read_prepared_evidence(
      build_source_evidence,
      source_commit: source_commit,
    )
    prebuild_record, prebuild_snapshot_sha = QuakeSignalIOSScreenshotBuildSource.verify_materialized_snapshot(
      snapshot: prebuild_source_snapshot,
      prepared_source_evidence: source_path,
      source_commit: source_commit,
      phase: "pre-build",
    )
    postbuild_record, postbuild_snapshot_sha = QuakeSignalIOSScreenshotBuildSource.verify_materialized_snapshot(
      snapshot: postbuild_source_snapshot,
      prepared_source_evidence: source_path,
      source_commit: source_commit,
      phase: "post-build",
    )
    prebuild_captured_at = prebuild_record.fetch("capturedAt")
    postbuild_captured_at = postbuild_record.fetch("capturedAt")
    prebuild_captured_time = Time.iso8601(prebuild_captured_at)
    postbuild_captured_time = Time.iso8601(postbuild_captured_at)
    unless postbuild_captured_time >= prebuild_captured_time
      raise Error, "post-build materialized source snapshot predates the pre-build snapshot"
    end
    _rechecked_source_path, rechecked_source, rechecked_record =
      QuakeSignalIOSScreenshotBuildSource.read_prepared_evidence(
        source_path,
        source_commit: source_commit,
      )
    unless rechecked_source == source_source && rechecked_record == source_record
      raise Error, "prepared build-source evidence changed during binding validation"
    end
    materialized_manifest = source_record.fetch("materializedBuildSource")
    postbuild_manifest = if build_ios_root
                           QuakeSignalIOSScreenshotBuildSource.verify_materialized_source(
                             build_ios_root: build_ios_root,
                             prepared_source_record: source_record,
                             source_commit: source_commit,
                           )
                         elsif allow_retained_materialized_source
                           postbuild_record.fetch("materializedBuildSource")
                         else
                           raise Error, "binding write requires the live materialized iOS build source"
                         end
    settings_path = canonical_plain_file(build_settings, "build settings")
    log_path = canonical_plain_file(build_log, "build log")
    list_path = canonical_plain_file(build_list, "Xcode project list")
    result_path = canonical_plain_file(result_bundle_archive, "xcresult archive")
    swift_inputs_path = canonical_plain_file(swift_inputs, "Swift compiler input evidence")
    app_path = canonical_plain_directory(app, "built app")
    unless [log_path, list_path, result_path].all? { |path| path.size.positive? }
      raise Error, "build log, Xcode project list, and xcresult archive must be nonempty"
    end
    build_log_source = log_path.read
    unless build_log_source.include?("Build description signature:") &&
           build_log_source.include?("Target dependency graph (1 target)") &&
           build_log_source.match?(/Target ['\"]?QuakeSignal['\"]? in project ['\"]?QuakeSignal['\"]? \(no dependencies\)/) &&
           build_log_source.include?("** BUILD SUCCEEDED **") &&
           !build_log_source.include?("QuakeSignalWatch") &&
           !build_log_source.include?("Embed Watch Content") &&
           !build_log_source.include?("watchsimulator")
      raise Error, "build log does not prove one successful QuakeSignal-only target graph"
    end
    validate_project_list(parse_json(list_path, "Xcode project list"))
    unless result_path.binread(4).start_with?("PK")
      raise Error, "xcresult archive is not a ZIP"
    end

    transformation = source_record.fetch("projectTransformation")
    original_project = require_sha256(transformation.fetch("originalSha256"), "original project")
    transformed_project = require_sha256(transformation.fetch("temporarySha256"), "transformed project")

    parsed_settings = QuakeSignalIOSBuildSettings.parse(settings_path.read)
    host_architecture, architecture_error, architecture_status = Open3.capture3("uname", "-m")
    unless architecture_status.success? && %w[arm64 x86_64].include?(host_architecture.strip)
      raise Error, "could not resolve one supported screenshot-build host architecture: #{architecture_error.strip}"
    end
    host_architecture = host_architecture.strip
    unless parsed_settings.fetch("architectures") == host_architecture
      raise Error, "build settings architecture does not match the observed capture host"
    end
    swift_inputs_record = parse_json(swift_inputs_path, "Swift compiler input evidence")
    QuakeSignalIOSScreenshotSwiftInputs.validate(
      swift_inputs_record,
      source_record: source_record,
      source_commit: source_commit,
      architecture: host_architecture,
    )
    result_summary = nil
    result_bundle_tree = nil
    QuakeSignalSafeZipTree.with_safe_extraction(archive: result_path) do |extracted_result|
      result_summary = result_inspector.call(extracted_result, host_architecture)
      result_bundle_tree = tree_manifest(extracted_result, "xcresult bundle")
    end
    unless prebuild_captured_time.to_f <= result_summary.fetch("startTime") &&
           postbuild_captured_time.to_f >= result_summary.fetch("endTime")
      raise Error, "pre-build and post-build materialized source snapshots do not bracket the xcresult build interval"
    end
    expected_app = Pathname.new(parsed_settings.fetch("targetBuildDirectory"))
                           .join(parsed_settings.fetch("wrapperName")).expand_path
    unless expected_app == app_path
      raise Error, "build settings do not select the supplied QuakeSignal app"
    end

    info = app_path.join("Info.plist")
    canonical_plain_file(info, "built app Info.plist")
    bundle_identifier = plist_value(info, ":CFBundleIdentifier")
    marketing_version = plist_value(info, ":CFBundleShortVersionString")
    build_number = plist_value(info, ":CFBundleVersion")
    executable_name = plist_value(info, ":CFBundleExecutable")
    unless app_path.basename.to_s == "QuakeSignal.app" && executable_name == "QuakeSignal" &&
           parsed_settings.fetch("wrapperName") == "QuakeSignal.app" &&
           parsed_settings.fetch("executableName") == "QuakeSignal"
      raise Error, "built app/product/executable names are not exactly QuakeSignal.app/QuakeSignal"
    end
    if app_path.join("Watch").exist? || app_path.join("Watch").symlink?
      raise Error, "detached screenshot app must not contain a Watch payload"
    end
    executable = canonical_plain_file(app_path.join(executable_name), "built app executable")
    unless bundle_identifier == "com.quakesignal.app" && marketing_version == "1.1" && build_number == "12"
      raise Error, "built app identity differs from com.quakesignal.app 1.1 (12)"
    end

    {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-source-bound-ios-simulator-build",
      "uploadApproved" => false,
      "reviewer" => nil,
      "sourceCommit" => source_commit,
      "hostArchitecture" => host_architecture,
      "configuration" => "Debug",
      "destination" => "generic/platform=iOS Simulator",
      "buildSourceEvidence" => {
        "sha256" => Digest::SHA256.hexdigest(source_source),
        "originalProjectSha256" => original_project,
        "transformedProjectSha256" => transformed_project,
        "materializedBuildSource" => {
          "preparedManifest" => materialized_manifest,
          "preBuildSnapshotSha256" => prebuild_snapshot_sha,
          "postBuildSnapshotSha256" => postbuild_snapshot_sha,
          "preBuildCapturedAt" => prebuild_captured_at,
          "postBuildCapturedAt" => postbuild_captured_at,
          "preBuildManifest" => prebuild_record.fetch("materializedBuildSource"),
          "postBuildManifest" => postbuild_record.fetch("materializedBuildSource"),
          "liveAtBindingManifest" => postbuild_manifest,
          "preBuildContentManifestSha256" => prebuild_record.fetch("materializedBuildSource")
                                                            .fetch("contentManifestSha256"),
          "postBuildContentManifestSha256" => postbuild_record.fetch("materializedBuildSource")
                                                              .fetch("contentManifestSha256"),
          "liveAtBindingContentManifestSha256" => postbuild_manifest.fetch("contentManifestSha256"),
          "prePostAndLiveExactlyMatchPrepared" => true,
        },
      },
      "buildSettings" => parsed_settings.merge(
        "sha256" => Digest::SHA256.file(settings_path).hexdigest,
      ),
      "swiftCompilerInputs" => {
        "evidenceSha256" => Digest::SHA256.file(swift_inputs_path).hexdigest,
        "normalizedContentSha256" => swift_inputs_record.fetch("fileList").fetch("normalizedContentSha256"),
        "authoredInputCount" => swift_inputs_record.fetch("authoredInputCount"),
        "generatedInputCount" => swift_inputs_record.fetch("generatedInputCount"),
      },
      "buildInvocationEvidence" => {
        "projectFile" => "ios/QuakeSignal.xcodeproj",
        "scheme" => "QuakeSignal",
        "action" => "build",
        "sdk" => "iphonesimulator",
        "destination" => "generic/platform=iOS Simulator",
        "projectListSha256" => Digest::SHA256.file(list_path).hexdigest,
        "buildLogSha256" => Digest::SHA256.file(log_path).hexdigest,
        "resultBundleTree" => result_bundle_tree,
        "resultBundleArchiveSha256" => Digest::SHA256.file(result_path).hexdigest,
        "resultSummary" => result_summary,
        "targetCount" => 1,
        "dependencyCount" => 0,
        "buildSucceeded" => true,
      },
      "app" => {
        "bundleName" => parsed_settings.fetch("wrapperName"),
        "bundleIdentifier" => bundle_identifier,
        "marketingVersion" => marketing_version,
        "build" => Integer(build_number, 10),
        "bundleTree" => tree_manifest(app_path, "built app"),
        "watchPayloadPresent" => false,
        "infoPlistSha256" => Digest::SHA256.file(info).hexdigest,
        "mainExecutableFile" => executable_name,
        "mainExecutableSha256" => Digest::SHA256.file(executable).hexdigest,
        "productInspection" => product_inspection(app_path, executable, host_architecture),
      },
    }
  rescue KeyError, ArgumentError, QuakeSignalIOSBuildSettings::Error, QuakeSignalSafeZipTree::Error,
         QuakeSignalIOSScreenshotSwiftInputs::Error, QuakeSignalIOSScreenshotBuildSource::Error => error
    raise Error, "invalid iOS screenshot build binding input: #{error.message}"
  end

  def write(output:, **arguments)
    unless arguments.fetch(:build_ios_root, nil)
      raise Error, "binding write requires the live materialized iOS build source"
    end
    path = new_canonical_output(output)
    value = record(**arguments)
    path.write(JSON.pretty_generate(value) + "\n", mode: "wx")
    value
  rescue Errno::EEXIST => error
    raise Error, "could not write build binding: #{error.message}"
  end

  def verify(binding:, **arguments)
    path = canonical_plain_file(binding, "build binding")
    expected = record(
      **arguments,
      allow_retained_materialized_source: arguments.fetch(:build_ios_root, nil).nil?,
    )
    actual = parse_json(path, "build binding")
    raise Error, "build binding does not match the supplied app and build evidence" unless actual == expected

    actual
  end

  def tree_hash(root)
    tree_manifest(root, "tree").fetch("contentManifestSha256")
  end

  def tree_manifest(root, label)
    files = plain_tree_files(root, root, label)
    records = files.map do |file|
      relative = file.relative_path_from(root).to_s
      "#{Digest::SHA256.file(file).hexdigest}  #{relative}\n"
    end.sort.join
    {
      "algorithm" => TREE_ALGORITHM,
      "fileCount" => files.length,
      "totalBytes" => files.sum(&:size),
      "contentManifestSha256" => Digest::SHA256.hexdigest(records),
      "files" => files.sort_by { |file| file.relative_path_from(root).to_s }.map do |file|
        {
          "file" => file.relative_path_from(root).to_s,
          "sha256" => Digest::SHA256.file(file).hexdigest,
          "bytes" => file.size,
        }
      end,
    }
  end

  def validate_project_list(record)
    require_exact_keys(record, ["project"], "Xcode project list")
    project = record.fetch("project")
    require_exact_keys(project, %w[name configurations schemes targets], "Xcode project inventory")
    expected = {
      "name" => "QuakeSignal",
      "configurations" => %w[Debug InternalQA Release],
      "schemes" => %w[QuakeSignal QuakeSignalTV QuakeSignalVision QuakeSignalWatch],
      "targets" => %w[QuakeSignal QuakeSignalTV QuakeSignalTests QuakeSignalVision QuakeSignalWatch],
    }
    actual = project.transform_values { |value| value.is_a?(Array) ? value.sort : value }
    unless actual == expected
      raise Error, "Xcode project list differs from the exact reviewed project inventory"
    end
  rescue KeyError, TypeError => error
    raise Error, "invalid Xcode project list: #{error.message}"
  end

  def product_inspection(app, executable, architecture)
    file_record = command_record("/usr/bin/file", "-b", executable.to_s)
    vtool_record = command_record("xcrun", "vtool", "-show-build", executable.to_s)
    codesign_record = command_record("/usr/bin/codesign", "-dvvv", app.to_s)
    unless file_record.fetch("exitStatus").zero? &&
           file_record.fetch("output").match?(/\AMach-O 64-bit executable #{Regexp.escape(architecture)}(?:\s|\z)/) &&
           !file_record.fetch("output").include?("universal")
      raise Error, "built executable file inspection is not one #{architecture} Mach-O"
    end
    unless vtool_record.fetch("exitStatus").zero? && vtool_record.fetch("output").include?("platform IOSSIMULATOR")
      raise Error, "built executable vtool inspection is not an iOS Simulator product"
    end
    signature_output = codesign_record.fetch("output")
    unless signature_output.include?("TeamIdentifier=not set") || signature_output.include?("not signed at all")
      raise Error, "built simulator app unexpectedly contains a team-bound code signature"
    end
    {
      "file" => file_record,
      "vtool" => vtool_record,
      "codesign" => codesign_record,
    }
  end

  def command_record(*command)
    output, status = Open3.capture2e(*command)
    {
      "command" => command.first(command.length - 1),
      "exitStatus" => status.exitstatus,
      "output" => output,
    }
  end

  def validate_build_source_record(record, source_commit)
    QuakeSignalIOSScreenshotBuildSource.validate_prepared_record(
      record,
      source_commit: source_commit,
    )
  rescue QuakeSignalIOSScreenshotBuildSource::Error => error
    raise Error, "invalid build-source evidence: #{error.message}"
  end

  def plain_tree_files(directory, root, label)
    directory.children.sort_by(&:to_s).flat_map do |entry|
      stat = entry.lstat
      if stat.directory? && !entry.symlink?
        plain_tree_files(entry, root, label)
      elsif stat.file? && !entry.symlink?
        [entry]
      else
        raise Error, "#{label} contains a symlink or special entry: #{entry.relative_path_from(root)}"
      end
    end
  end


  def inspect_xcresult(path, _architecture)
    output, error, status = Open3.capture3(
      "xcrun", "xcresulttool", "get", "build-results", "--path", path.to_s, "--compact",
    )
    unless status.success?
      raise Error, "xcresult build-results inspection failed: #{error.strip}"
    end
    record = JSON.parse(output, object_class: DuplicateRejectingHash)
    validate_xcresult_record(record)
    record
  rescue JSON::ParserError, KeyError, TypeError => error
    raise Error, "invalid xcresult build-results evidence: #{error.message}"
  end

  def validate_xcresult_record(record)
    require_exact_keys(
      record,
      %w[
        actionTitle destination startTime endTime status errorCount errors warningCount warnings
        analyzerWarningCount analyzerWarnings
      ],
      "xcresult build-results summary",
    )
    destination = record.fetch("destination")
    require_exact_keys(
      destination,
      %w[deviceId deviceName architecture modelName platform osVersion],
      "xcresult destination",
    )
    unless record.fetch("actionTitle") == 'Build "QuakeSignal"' &&
           record.fetch("status") == "succeeded" &&
           record.fetch("errorCount") == 0 && record.fetch("errors") == [] &&
           record.fetch("warningCount") == 0 && record.fetch("warnings") == [] &&
           record.fetch("analyzerWarningCount") == 0 && record.fetch("analyzerWarnings") == [] &&
           record.fetch("startTime").is_a?(Numeric) &&
           record.fetch("endTime").is_a?(Numeric) && record.fetch("endTime") >= record.fetch("startTime") &&
           destination.fetch("platform") == "iOS Simulator" &&
           destination.fetch("deviceId") == "dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder" &&
           destination.fetch("deviceName") == "Any iOS Simulator Device" &&
           destination.fetch("modelName") == "Apple device" &&
           destination.fetch("osVersion") == "" &&
           destination.fetch("architecture") == "undefined_arch"
      raise Error, "xcresult does not prove a successful error-free build for the capture host simulator"
    end
    true
  rescue KeyError, TypeError => error
    raise Error, "invalid xcresult build-results evidence: #{error.message}"
  end

  def plist_value(path, key)
    value, error, status = Open3.capture3("/usr/libexec/PlistBuddy", "-c", "Print #{key}", path.to_s)
    raise Error, "could not read built app #{key}: #{error.strip}" unless status.success?

    value.strip
  end

  def parse_json(path, label)
    value = JSON.parse(path.read, object_class: DuplicateRejectingHash)
    raise Error, "#{label} must be an object" unless value.is_a?(Hash)

    value
  rescue JSON::ParserError => error
    raise Error, "invalid #{label}: #{error.message}"
  end

  def canonical_plain_file(value, label)
    path = Pathname.new(value).expand_path
    unless Pathname.new(value).absolute? && path.realpath == path && path.lstat.file? && !path.symlink?
      raise Error, "#{label} must be a canonical absolute plain file"
    end
    path
  rescue Errno::ENOENT
    raise Error, "#{label} is missing"
  end

  def canonical_plain_directory(value, label)
    path = Pathname.new(value).expand_path
    unless Pathname.new(value).absolute? && path.realpath == path && path.lstat.directory? && !path.symlink?
      raise Error, "#{label} must be a canonical absolute plain directory"
    end
    path
  rescue Errno::ENOENT
    raise Error, "#{label} is missing"
  end

  def new_canonical_output(value)
    path = Pathname.new(value).expand_path
    unless Pathname.new(value).absolute? && path.dirname.realpath == path.dirname && !path.exist? && !path.symlink?
      raise Error, "build binding output must be a new path under a canonical absolute parent"
    end
    path
  rescue Errno::ENOENT
    raise Error, "build binding output parent is missing"
  end

  def require_commit(value)
    raise Error, "source commit must be a full lowercase Git commit" unless value.match?(/\A[0-9a-f]{40}\z/)
  end

  def require_sha256(value, label)
    raise Error, "#{label} SHA-256 is invalid" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)

    value
  end

  def require_exact_keys(value, expected, label)
    unless value.is_a?(Hash) && value.keys.sort == expected.sort
      raise Error, "#{label} has an unexpected schema"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    unless ARGV.length == 13 && %w[write verify].include?(ARGV.fetch(0))
      abort "Usage: ios-screenshot-build-binding.rb <write|verify> <source-commit> <build-source.json> <build-settings.json> <build.log> <xcode-list.json> <xcresult.zip> <swift-inputs.json> <QuakeSignal.app> <binding.json> <pre-build-source-snapshot.json> <post-build-source-snapshot.json> <absolute-build-ios-directory|->"
    end
    mode, source_commit, source, settings, log, list, result_archive, swift_inputs, app, binding,
      prebuild_snapshot, postbuild_snapshot, build_ios_root = ARGV
    build_ios_root = nil if build_ios_root == "-"
    if mode == "write" && build_ios_root.nil?
      raise QuakeSignalIOSScreenshotBuildBinding::Error,
            "binding write requires the live materialized iOS build source"
    end
    arguments = {
      source_commit: source_commit,
      build_source_evidence: source,
      prebuild_source_snapshot: prebuild_snapshot,
      postbuild_source_snapshot: postbuild_snapshot,
      build_ios_root: build_ios_root,
      build_settings: settings,
      build_log: log,
      build_list: list,
      result_bundle_archive: result_archive,
      swift_inputs: swift_inputs,
      app: app,
    }
    if mode == "write"
      QuakeSignalIOSScreenshotBuildBinding.write(output: binding, **arguments)
    else
      QuakeSignalIOSScreenshotBuildBinding.verify(binding: binding, **arguments)
    end
  rescue QuakeSignalIOSScreenshotBuildBinding::Error => error
    warn "error: #{error.message}"
    exit 65
  end
end
