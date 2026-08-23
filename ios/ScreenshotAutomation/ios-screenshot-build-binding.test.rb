#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "ios-screenshot-build-binding"
require_relative "screenshot-test-temp-root"

class IOSScreenshotBuildBindingTest < Minitest::Test
  COMMIT = "a" * 40

  def setup
    @temporary_directory = Dir.mktmpdir(
      "quakesignal-ios-build-binding-test",
      QuakeSignalScreenshotTestTempRoot.path.to_s,
    )
    @root = Pathname.new(@temporary_directory)
    @derived = @root.join("DerivedData")
    @host_architecture = Open3.capture2("uname", "-m").first.strip
    @app = @derived.join("Build/Products/Debug-iphonesimulator/QuakeSignal.app")
    @app.mkpath
    target = @host_architecture == "arm64" ? "arm64-apple-ios17.0-simulator" : "x86_64-apple-ios17.0-simulator"
    _output, compiler_error, compiler_status = Open3.capture3(
      "xcrun", "clang", "-target", target, "-x", "c", "-", "-o", @app.join("QuakeSignal").to_s,
      stdin_data: "int main(void) { return 0; }\n",
    )
    raise "could not compile test simulator executable: #{compiler_error}" unless compiler_status.success?
    @app.join("Info.plist").write(<<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>com.quakesignal.app</string>
      <key>CFBundleShortVersionString</key><string>1.1</string>
      <key>CFBundleVersion</key><string>9</string>
      <key>CFBundleExecutable</key><string>QuakeSignal</string>
      </dict></plist>
    PLIST
    @source = @root.join("build-source.json")
    @build_ios_root = @root.join("BuildSource/ios")
    @build_ios_root.join("QuakeSignal/App").mkpath
    @build_ios_root.join("QuakeSignalShared").mkpath
    @build_ios_root.join("QuakeSignal.xcodeproj").mkpath
    @build_ios_root.join("QuakeSignal.xcodeproj/project.xcworkspace").mkpath
    @build_ios_root.join("QuakeSignal/App/QuakeSignalApp.swift").binwrite("fixture source")
    @build_ios_root.join("QuakeSignal.xcodeproj/project.pbxproj").binwrite("transformed project\n")
    QuakeSignalIOSScreenshotBuildSource.prepare_xcode_swiftpm_workspace_directories(@build_ios_root)
    input_sha = Digest::SHA256.hexdigest("fixture source")
    input_record = {
      "file" => "ios/QuakeSignal/App/QuakeSignalApp.swift",
      "sha256" => input_sha,
      "bytes" => 14,
    }
    input_manifest_sha = Digest::SHA256.hexdigest(
      "#{input_sha}  ios/QuakeSignal/App/QuakeSignalApp.swift\n",
    )
    write_json(
      @source,
      {
        "schemaVersion" => 1,
        "status" => "unapproved-debug-temporary-no-watch-build-source-evidence",
        "uploadApproved" => false,
        "reviewer" => nil,
        "sourceCommit" => COMMIT,
        "purpose" => "credential-free iOS Simulator screenshot build on a host where the Watch platform component cannot resolve",
        "sourceMaterialization" => {
          "method" => "git-archive",
          "sourceCommit" => COMMIT,
          "paths" => QuakeSignalIOSScreenshotBuildSource::COPIED_INPUTS,
          "archiveProjectMatchesGitShow" => true,
          "workingTreeMatchesArchive" => true,
        },
        "mainProductInputs" => {
          "algorithm" => QuakeSignalIOSScreenshotBuildSource::ALGORITHM,
          "fileCount" => 1,
          "totalBytes" => 14,
          "contentManifestSha256" => input_manifest_sha,
          "files" => [input_record],
        },
        "copyVerification" => {
          "allNonProjectBytesIdentical" => true,
          "copiedContentManifestSha256" => input_manifest_sha,
        },
        "projectTransformation" => {
          "originalFile" => QuakeSignalIOSScreenshotBuildSource::PROJECT_RELATIVE,
          "temporaryFile" => "ios/QuakeSignal.xcodeproj/project.pbxproj",
          "originalSha256" => Digest::SHA256.hexdigest("original project\n"),
          "temporarySha256" => Digest::SHA256.hexdigest("transformed project\n"),
          "removedReferences" => QuakeSignalIOSScreenshotBuildBinding::EXPECTED_REMOVED_REFERENCES,
          "removedDefinitionCount" => 0,
          "watchTargetDefinitionRetained" => true,
          "mainTargetSourceAndResourcePhasesUnchanged" => true,
        },
        "materializedBuildSource" =>
          QuakeSignalIOSScreenshotBuildSource.materialized_source_manifest(@build_ios_root),
      },
    )
    @prebuild_snapshot = @root.join("pre-build-source.json")
    QuakeSignalIOSScreenshotBuildSource.write_materialized_snapshot(
      output: @prebuild_snapshot,
      build_ios_root: @build_ios_root,
      prepared_source_evidence: @source,
      source_commit: COMMIT,
      phase: "pre-build",
      captured_at: "2026-08-21T00:00:00.000001Z",
    )
    @postbuild_snapshot = @root.join("post-build-source.json")
    QuakeSignalIOSScreenshotBuildSource.write_materialized_snapshot(
      output: @postbuild_snapshot,
      build_ios_root: @build_ios_root,
      prepared_source_evidence: @source,
      source_commit: COMMIT,
      phase: "post-build",
      captured_at: "2026-08-21T00:01:00.000001Z",
    )
    @settings = @root.join("build-settings.json")
    write_json(
      @settings,
      [{
        "target" => "QuakeSignal",
        "action" => "build",
        "buildSettings" => {
          "PRODUCT_BUNDLE_IDENTIFIER" => "com.quakesignal.app",
          "TARGET_BUILD_DIR" => @app.dirname.to_s,
          "WRAPPER_NAME" => @app.basename.to_s,
          "EXECUTABLE_NAME" => "QuakeSignal",
          "FULL_PRODUCT_NAME" => "QuakeSignal.app",
          "CONFIGURATION" => "Debug",
          "PLATFORM_NAME" => "iphonesimulator",
          "SDK_NAME" => "iphonesimulator26.5",
          "SDKROOT" => "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk",
          "ARCHS" => @host_architecture,
          "ONLY_ACTIVE_ARCH" => "NO",
          "CODE_SIGNING_ALLOWED" => "NO",
          "CODE_SIGNING_REQUIRED" => "NO",
          "CODE_SIGN_IDENTITY" => "",
          "COMPILER_INDEX_STORE_ENABLE" => "NO",
          "BUILD_DIR" => @derived.join("Build/Products").to_s,
          "BUILD_ROOT" => @derived.join("Build").to_s,
          "CONFIGURATION_BUILD_DIR" => @derived.join("Build/Products/Debug-iphonesimulator").to_s,
          "OBJROOT" => @derived.join("Build/Intermediates.noindex").to_s,
          "SYMROOT" => @derived.join("Build/Products").to_s,
          "SHARED_PRECOMPS_DIR" => @derived.join("SharedPrecompiledHeaders").to_s,
          "CLANG_MODULE_CACHE_PATH" => @derived.join("ModuleCache.noindex").to_s,
          "DSTROOT" => @derived.join("Dst").to_s,
        },
      }],
    )
    @log = @root.join("build.log")
    @log.write(<<~LOG)
      Target dependency graph (1 target)
          Target 'QuakeSignal' in project 'QuakeSignal' (no dependencies)
      Build description signature: fixture
      ** BUILD SUCCEEDED **
    LOG
    @list = @root.join("xcode-list.json")
    write_json(
      @list,
      {
        "project" => {
          "name" => "QuakeSignal",
          "configurations" => %w[Debug InternalQA Release],
          "schemes" => %w[QuakeSignal QuakeSignalTV QuakeSignalVision QuakeSignalWatch],
          "targets" => %w[QuakeSignal QuakeSignalTV QuakeSignalTests QuakeSignalVision QuakeSignalWatch],
        },
      },
    )
    @result_bundle = @root.join("QuakeSignal-build.xcresult")
    @result_bundle.mkpath
    @result_bundle.join("Info.plist").write("fixture xcresult\n")
    @result = @root.join("QuakeSignal-build.xcresult.zip")
    success = system(
      "/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent",
      @result_bundle.to_s, @result.to_s,
      out: File::NULL, err: File::NULL,
    )
    raise "could not archive fixture xcresult" unless success && @result.file?
    @swift_inputs = @root.join("swift-inputs.json")
    normalized = "authored  ios/QuakeSignal/App/QuakeSignalApp.swift\n" \
                 "generated  DerivedData/Build/Intermediates.noindex/QuakeSignal.build/Debug-iphonesimulator/" \
                 "QuakeSignal.build/DerivedSources/GeneratedAssetSymbols.swift\n"
    write_json(
      @swift_inputs,
      {
        "schemaVersion" => 1,
        "status" => "unapproved-debug-source-bound-swift-compiler-inputs",
        "uploadApproved" => false,
        "reviewer" => nil,
        "sourceCommit" => COMMIT,
        "hostArchitecture" => @host_architecture,
        "target" => "QuakeSignal",
        "configuration" => "Debug",
        "platform" => "iphonesimulator",
        "fileList" => {
          "derivedDataRelativeFile" => "Build/Intermediates.noindex/QuakeSignal.build/Debug-iphonesimulator/" \
                                       "QuakeSignal.build/Objects-normal/#{@host_architecture}/QuakeSignal.SwiftFileList",
          "rawSha256" => "d" * 64,
          "entryCount" => 2,
          "normalizedContentSha256" => Digest::SHA256.hexdigest(normalized),
          "entries" => [
            input_record.merge("kind" => "authored"),
            {
              "kind" => "generated",
              "file" => "DerivedData/Build/Intermediates.noindex/QuakeSignal.build/Debug-iphonesimulator/" \
                        "QuakeSignal.build/DerivedSources/GeneratedAssetSymbols.swift",
              "sha256" => "e" * 64,
              "bytes" => 20,
            },
          ],
        },
        "authoredInputCount" => 1,
        "generatedInputCount" => 1,
        "mainTargetSourcesBuildPhaseIdentifier" => "A" * 24,
        "mainTargetAuthoredSourceFiles" => ["ios/QuakeSignal/App/QuakeSignalApp.swift"],
        "authoredInputsExactlyMatchMainTargetSources" => true,
      },
    )
    @binding = @root.join("binding.json")
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory) if @temporary_directory && File.exist?(@temporary_directory)
  end

  def test_writes_and_verifies_exact_app_source_settings_and_log_binding
    record = write_binding
    assert_equal false, record.fetch("uploadApproved")
    assert_nil record.fetch("reviewer")
    assert_equal Digest::SHA256.file(@app.join("QuakeSignal")).hexdigest,
                 record.fetch("app").fetch("mainExecutableSha256")
    assert_equal 1, record.fetch("buildInvocationEvidence").fetch("targetCount")
    assert_equal 0, record.fetch("buildInvocationEvidence").fetch("dependencyCount")
    refute record.fetch("buildInvocationEvidence").key?("targetDependencyCount")
    source_binding = record.fetch("buildSourceEvidence").fetch("materializedBuildSource")
    prepared_manifest = JSON.parse(@source.read).fetch("materializedBuildSource")
    assert_equal prepared_manifest, source_binding.fetch("preparedManifest")
    assert_equal prepared_manifest, source_binding.fetch("preBuildManifest")
    assert_equal prepared_manifest, source_binding.fetch("postBuildManifest")
    assert_equal prepared_manifest, source_binding.fetch("liveAtBindingManifest")
    assert_equal "2026-08-21T00:00:00.000001Z", source_binding.fetch("preBuildCapturedAt")
    assert_equal "2026-08-21T00:01:00.000001Z", source_binding.fetch("postBuildCapturedAt")
    assert_equal Digest::SHA256.file(@prebuild_snapshot).hexdigest,
                 source_binding.fetch("preBuildSnapshotSha256")
    assert_equal Digest::SHA256.file(@postbuild_snapshot).hexdigest,
                 source_binding.fetch("postBuildSnapshotSha256")
    assert_equal prepared_manifest.fetch("contentManifestSha256"),
                 source_binding.fetch("preBuildContentManifestSha256")
    assert_equal prepared_manifest.fetch("contentManifestSha256"),
                 source_binding.fetch("postBuildContentManifestSha256")
    assert_equal prepared_manifest.fetch("contentManifestSha256"),
                 source_binding.fetch("liveAtBindingContentManifestSha256")
    assert source_binding.fetch("prePostAndLiveExactlyMatchPrepared")
    assert_equal record, verify_binding
  end

  def test_rejects_materialized_project_resource_and_added_script_drift
    project = @build_ios_root.join("QuakeSignal.xcodeproj/project.pbxproj")
    project_source = project.binread
    project.binwrite(project_source + "mutated\n")
    assert_error(/transformed Xcode project hash/) { write_binding }
    project.binwrite(project_source)

    resource = @build_ios_root.join("QuakeSignal/App/QuakeSignalApp.swift")
    resource_source = resource.binread
    resource.binwrite(resource_source + "\n")
    assert_error(/materialized iOS build source inventory/) { write_binding }
    resource.binwrite(resource_source)

    injected = @build_ios_root.join("QuakeSignal/BuildPhase.sh")
    injected.write("#!/bin/sh\n")
    assert_error(/materialized iOS build source inventory/) { write_binding }
    injected.delete

    assert write_binding
  end

  def test_rejects_post_binding_materialized_source_drift_when_live_tree_is_available
    write_binding
    @build_ios_root.join("QuakeSignalShared/Injected.swift").write("fatalError()\n")
    assert_error(/materialized iOS build source inventory/) { verify_binding }
  end

  def test_reverifies_retained_pre_and_post_contract_after_temporary_source_is_gone
    record = write_binding
    FileUtils.remove_entry(@build_ios_root)
    assert_equal record, verify_binding(build_ios_root: nil)
  end

  def test_rejects_mutated_prebuild_snapshot_and_write_without_live_source
    snapshot = JSON.parse(@prebuild_snapshot.read)
    snapshot["preparedTransformedProjectSha256"] = "0" * 64
    write_json(@prebuild_snapshot, snapshot)
    assert_error(/not bound to the exact prepared source evidence/) { write_binding }

    assert_error(/requires the live materialized iOS build source/) do
      QuakeSignalIOSScreenshotBuildBinding.write(
        output: @root.join("missing-live-binding.json"),
        **arguments(build_ios_root: nil),
      )
    end
  end

  def test_rejects_retained_postbuild_mutation_even_after_live_source_is_restored
    @postbuild_snapshot.delete
    source = @build_ios_root.join("QuakeSignal/App/QuakeSignalApp.swift")
    original = source.binread
    source.binwrite(original + "\n// changed during build\n")
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.write_materialized_snapshot(
        output: @postbuild_snapshot,
        build_ios_root: @build_ios_root,
        prepared_source_evidence: @source,
        source_commit: COMMIT,
        phase: "post-build",
        captured_at: "2026-08-21T00:01:00.000001Z",
      )
    end
    assert_match(/retained a tree that differs/, error.message)
    source.binwrite(original)
    assert_equal JSON.parse(@source.read).fetch("materializedBuildSource"),
                 QuakeSignalIOSScreenshotBuildSource.materialized_source_manifest(@build_ios_root)
    assert_error(/post-build materialized source snapshot does not match prepared evidence/) { write_binding }
  end

  def test_rejects_reversed_or_noncanonical_snapshot_timestamps
    postbuild = JSON.parse(@postbuild_snapshot.read)
    postbuild["capturedAt"] = "2026-08-20T23:59:59.999999Z"
    write_json(@postbuild_snapshot, postbuild)
    assert_error(/predates the pre-build snapshot/) { write_binding }

    postbuild["capturedAt"] = "2026-08-21T00:01:00Z"
    write_json(@postbuild_snapshot, postbuild)
    assert_error(/canonical microsecond UTC timestamp/) { write_binding }
  end

  def test_requires_source_snapshot_timestamps_to_bracket_the_xcresult_build_interval
    before_prebuild = xcresult_record.merge(
      "startTime" => Time.iso8601("2026-08-20T23:59:59.000001Z").to_f,
    )
    assert_error(/do not bracket the xcresult build interval/) do
      write_binding(result_inspector: ->(_path, _architecture) { before_prebuild })
    end

    after_postbuild = xcresult_record.merge(
      "endTime" => Time.iso8601("2026-08-21T00:01:01.000001Z").to_f,
    )
    assert_error(/do not bracket the xcresult build interval/) do
      write_binding(result_inspector: ->(_path, _architecture) { after_postbuild })
    end
  end

  def test_rejects_mutated_app
    write_binding
    @app.join("QuakeSignal").binwrite("different\n")
    assert_error(/Mach-O|does not match/) { verify_binding }
  end

  def test_rejects_mutated_log
    write_binding
    @log.write("different log\n")
    assert_error(/one successful QuakeSignal-only target graph/) { verify_binding }
  end

  def test_rejects_mutated_source
    write_binding
    source_record = JSON.parse(@source.read)
    source_record["sourceCommit"] = "d" * 40
    write_json(@source, source_record)
    assert_error(/source commit/) { verify_binding }
  end

  def test_rejects_mutated_settings
    write_binding
    settings = JSON.parse(@settings.read)
    settings.first.fetch("buildSettings")["ARCHS"] = @host_architecture == "arm64" ? "x86_64" : "arm64"
    write_json(@settings, settings)
    assert_error(/capture host/) { verify_binding }
  end

  def test_rejects_noncanonical_or_multi_architecture_build_settings
    settings = JSON.parse(@settings.read)
    settings.first.fetch("buildSettings")["ONLY_ACTIVE_ARCH"] = "YES"
    write_json(@settings, settings)
    assert_error(/onlyActiveArchitecture is not the exact deterministic screenshot value/) { write_binding }

    settings.first.fetch("buildSettings")["ONLY_ACTIVE_ARCH"] = "NO"
    settings.first.fetch("buildSettings")["ARCHS"] = "arm64 x86_64"
    write_json(@settings, settings)
    assert_error(/architectures is not one exact supported host architecture/) { write_binding }
  end

  def test_rejects_watch_payload_or_symlinked_parent
    @app.join("Watch").mkpath
    assert_error(/must not contain a Watch payload/) { write_binding }
    FileUtils.remove_entry(@app.join("Watch"))
    link = @root.join("linked-app")
    link.make_symlink(@app)
    assert_error(/canonical absolute plain directory/) do
      arguments(app: link).then { |args| QuakeSignalIOSScreenshotBuildBinding.record(**args) }
    end
  end

  def test_rejects_unrelated_or_mutated_retained_xcresult_archive
    write_binding
    unrelated = @root.join("Unrelated.xcresult")
    unrelated.mkpath
    unrelated.join("Info.plist").write("unrelated result\n")
    @result.delete
    archive_result(unrelated, @result)
    assert_error(/does not match/) { verify_binding }

    @result.delete
    @result_bundle.join("Info.plist").write("mutated retained result\n")
    archive_result(@result_bundle, @result)
    assert_error(/does not match/) { verify_binding }
  end

  def test_rejects_mutated_generic_xcresult_summary_shape
    valid = xcresult_record
    assert QuakeSignalIOSScreenshotBuildBinding.validate_xcresult_record(valid)
    [
      ["status", "failed"],
      ["errorCount", 1],
      ["warningCount", 1],
    ].each do |key, value|
      mutated = Marshal.load(Marshal.dump(valid))
      mutated[key] = value
      assert_error(/successful error-free build/) do
        QuakeSignalIOSScreenshotBuildBinding.validate_xcresult_record(mutated)
      end
    end
    mutated = Marshal.load(Marshal.dump(valid))
    mutated.fetch("destination")["architecture"] = @host_architecture
    assert_error(/successful error-free build/) do
      QuakeSignalIOSScreenshotBuildBinding.validate_xcresult_record(mutated)
    end
    mutated = Marshal.load(Marshal.dump(valid))
    mutated["unreviewed"] = true
    assert_error(/unexpected schema/) do
      QuakeSignalIOSScreenshotBuildBinding.validate_xcresult_record(mutated)
    end
  end

  def test_rejects_mutated_swift_compiler_input_binding
    write_binding
    record = JSON.parse(@swift_inputs.read)
    record.fetch("fileList").fetch("entries").first["sha256"] = "0" * 64
    write_json(@swift_inputs, record)
    assert_error(/differs from source manifest/) { verify_binding }
  end

  def test_rejects_extra_or_missing_project_inventory
    base = JSON.parse(@list.read)
    {
      "configuration" => ->(project) { project.fetch("configurations") << "Unreviewed" },
      "scheme" => ->(project) { project.fetch("schemes").delete("QuakeSignalTV") },
      "target" => ->(project) { project.fetch("targets") << "UnreviewedTarget" },
    }.each do |label, mutation|
      record = Marshal.load(Marshal.dump(base))
      mutation.call(record.fetch("project"))
      write_json(@list, record)
      assert_error(/exact reviewed project inventory/, label) do
        QuakeSignalIOSScreenshotBuildBinding.record(**arguments)
      end
    end
  end

  private

  def arguments(app: @app, build_ios_root: @build_ios_root, result_inspector: nil)
    {
      source_commit: COMMIT,
      build_source_evidence: @source,
      prebuild_source_snapshot: @prebuild_snapshot,
      postbuild_source_snapshot: @postbuild_snapshot,
      build_ios_root: build_ios_root,
      build_settings: @settings,
      build_log: @log,
      build_list: @list,
      result_bundle_archive: @result,
      swift_inputs: @swift_inputs,
      app: app,
      result_inspector: result_inspector || ->(_path, _architecture) { xcresult_record },
    }
  end

  def write_binding(**overrides)
    QuakeSignalIOSScreenshotBuildBinding.write(output: @binding, **arguments(**overrides))
  end

  def verify_binding(**overrides)
    QuakeSignalIOSScreenshotBuildBinding.verify(binding: @binding, **arguments(**overrides))
  end

  def assert_error(pattern, message = nil)
    error = assert_raises(QuakeSignalIOSScreenshotBuildBinding::Error) { yield }
    assert_match pattern, error.message, message
  end

  def write_json(path, value)
    path.write(JSON.pretty_generate(value) + "\n")
  end

  def xcresult_record
    {
      "actionTitle" => 'Build "QuakeSignal"',
      "destination" => {
        "deviceId" => "dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder",
        "deviceName" => "Any iOS Simulator Device",
        "architecture" => "undefined_arch",
        "modelName" => "Apple device",
        "platform" => "iOS Simulator",
        "osVersion" => "",
      },
      "startTime" => Time.iso8601("2026-08-21T00:00:15.000001Z").to_f,
      "endTime" => Time.iso8601("2026-08-21T00:00:45.000001Z").to_f,
      "status" => "succeeded",
      "errorCount" => 0,
      "errors" => [],
      "warningCount" => 0,
      "warnings" => [],
      "analyzerWarningCount" => 0,
      "analyzerWarnings" => [],
    }
  end

  def archive_result(source, destination)
    success = system(
      "/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent",
      source.to_s, destination.to_s,
      out: File::NULL, err: File::NULL,
    )
    raise "could not archive fixture xcresult" unless success && destination.file?
  end
end
