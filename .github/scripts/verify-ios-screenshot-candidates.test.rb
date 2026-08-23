# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "verify-ios-screenshot-candidates"

class FakeScreenshotInspector
  attr_accessor :mutations
  attr_reader :inspected

  def initialize
    @mutations = {}
    @inspected = []
  end

  def inspect(path)
    @inspected << path.to_s
    display_class = path.each_filename.to_a[-2]
    width, height = IOSBuild8ScreenshotCandidateValidator::DISPLAY_CLASSES.fetch(display_class)
    { width: width, height: height, format: "jpeg", has_alpha: false }.merge(mutations.fetch(path.basename.to_s, {}))
  end
end

class FakeScreenshotSourceGuard
  attr_accessor :error
  attr_reader :commits

  def initialize
    @commits = []
  end

  def validate!(commit)
    @commits << commit
    raise error if error
  end
end

class IOSBuild8ScreenshotCandidateValidatorTest < Minitest::Test
  SOURCE_COMMIT = "a" * 40

  def setup
    @temporary_directory = Dir.mktmpdir("ios-build8-screenshot-validator")
    @root = Pathname.new(@temporary_directory)
    @store = @root.join("ios", "AppStore")
    FileUtils.mkdir_p(@store)
    @inspector = FakeScreenshotInspector.new
    @source_guard = FakeScreenshotSourceGuard.new
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory)
  end

  def validator
    IOSBuild8ScreenshotCandidateValidator.new(
      root: @root,
      image_inspector: @inspector,
      historical_commit_guard: @source_guard,
    )
  end

  def candidate_manifest
    {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-simulator-candidate",
      "uploadApproved" => false,
      "signedReleaseEvidence" => false,
      "product" => {
        "appleId" => "6800642443",
        "platform" => "iOS/iPadOS",
        "marketingVersion" => "1.1",
        "build" => 9,
        "bundleIdentifier" => "com.quakesignal.app",
        "configuration" => "Debug",
      },
      "rootDirectory" => "screenshots-v1.1-build9",
      "captureEvidence" => {
        "sourceBaselineCommit" => SOURCE_COMMIT,
        "artifactSha256" => "c" * 64,
        "capturedAtUtcRange" => ["2026-08-19T00:00:00Z", "2026-08-19T00:05:00Z"],
        "reviewer" => nil,
      },
      "locales" => [{ "directory" => "en-US" }],
      "displayClasses" => {
        "iphone-6.5" => {
          "portraitPixels" => [1242, 2688],
          "requiredFramesPerApprovedLocale" => 5,
        },
        "ipad-13" => {
          "portraitPixels" => [2064, 2752],
          "requiredFramesPerApprovedLocale" => 5,
        },
      },
      "frames" => IOSBuild8ScreenshotCandidateValidator::FRAMES.map do |file|
        { "file" => file, "captureStatus" => "unapproved-debug-simulator-candidate" }
      end,
    }
  end

  def candidate_provenance
    files = IOSBuild8ScreenshotCandidateValidator::EXPECTED_RELATIVE_PATHS.map do |relative_path|
      screenshot = @store.join("screenshots-v1.1-build9", relative_path)
      display_class = relative_path.split(File::SEPARATOR).fetch(1)
      {
        "file" => relative_path,
        "captureStatus" => "unapproved-debug-simulator-candidate",
        "sha256" => Digest::SHA256.file(screenshot).hexdigest,
        "pixels" => IOSBuild8ScreenshotCandidateValidator::DISPLAY_CLASSES.fetch(display_class),
        "format" => "jpeg",
        "hasAlpha" => false,
      }
    end
    {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-simulator-candidate",
      "uploadApproved" => false,
      "signedReleaseEvidence" => false,
      "product" => {
        "appleId" => "6800642443",
        "platform" => "iOS/iPadOS",
        "marketingVersion" => "1.1",
        "build" => 9,
        "bundleIdentifier" => "com.quakesignal.app",
        "configuration" => "Debug",
        "sdk" => "iphonesimulator26.5",
        "signing" => "disabled",
      },
      "capture" => {
        "sourceBaselineCommit" => SOURCE_COMMIT,
        "sourceTreeState" => "clean",
        "capturedAtUtcRange" => ["2026-08-19T00:00:00Z", "2026-08-19T00:05:00Z"],
        "xcode" => "26.6 (17F113)",
        "hostMacOS" => "26.6.2 (25G83)",
        "runtime" => {
          "name" => "iOS 26.5",
          "version" => "26.5",
          "build" => "23F77",
          "identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        },
        "devices" => [
          {
            "displayClass" => "iphone-6.5",
            "name" => "QuakeSignal App Store 6.5",
            "model" => "iPhone 11 Pro Max",
            "modelIdentifier" => "iPhone12,5",
            "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max",
            "udid" => "8360F1B3-8D49-440E-A488-7A395B0358D2",
            "width" => 1242,
            "height" => 2688,
          },
          {
            "displayClass" => "ipad-13",
            "name" => "QuakeSignal iPad 13",
            "model" => "iPad Pro 13-inch (M4)",
            "modelIdentifier" => "iPad16,6",
            "deviceTypeIdentifier" => "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB",
            "udid" => "6780874D-C761-4774-8EC2-3709E7390FED",
            "width" => 2064,
            "height" => 2752,
          },
        ],
        "reviewer" => nil,
      },
      "automationGates" => {
        "requiredLaunchArgument" => "--quakesignal-screenshot-automation",
        "requiredEnvironment" => { "QUAKESIGNAL_SCREENSHOT_AUTOMATION" => "1" },
        "bothSupplied" => true,
        "sourceConstraint" => "DEBUG && targetEnvironment(simulator)",
      },
      "fixture" => {
        "identifier" => "finalized-historical-reports",
        "warning" => false,
        "training" => false,
      },
      "buildEvidence" => {
        "mainExecutableSha256" => "c" * 64,
        "debugLocalOverridePresent" => false,
        "buildInvocation" => build_evidence_record("buildInvocation"),
        "normalizedBuildSettings" => build_evidence_record("normalizedBuildSettings"),
        "normalizedBuildLog" => build_evidence_record("normalizedBuildLog").merge(
          "sourceLogSha256" => "d" * 64,
        ),
        "targetBuildLogSha256" => "d" * 64,
        "simulatorInstallTransformation" => {
          "embeddedWatchRemovalOnly" => true,
          "nonWatchDiffEmpty" => true,
          "mainExecutableUnchanged" => true,
          "sourceExecutableSha256" => "c" * 64,
          "installedExecutableSha256" => "c" * 64,
          "transformationRecord" => build_evidence_record("transformationRecord"),
          "sourceNonWatchInventory" => build_evidence_record("sourceNonWatchInventory"),
          "installCopyNonWatchInventory" => build_evidence_record("installCopyNonWatchInventory"),
          "nonWatchDiff" => build_evidence_record("nonWatchDiff"),
        },
      },
      "files" => files,
    }
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def build_screenshot_tree
    IOSBuild8ScreenshotCandidateValidator::EXPECTED_RELATIVE_PATHS.each do |relative_path|
      screenshot = @store.join("screenshots-v1.1-build9", relative_path)
      FileUtils.mkdir_p(screenshot.dirname)
      screenshot.write("fixture:#{relative_path}\n")
    end
    evidence_root = @store.join(IOSBuild8ScreenshotCandidateValidator::BUILD_EVIDENCE_ROOT)
    FileUtils.mkdir_p(evidence_root)
    evidence_root.join("build-invocation.txt").binwrite(
      "#{IOSBuild8ScreenshotCandidateValidator::EXPECTED_BUILD_INVOCATION}\n"
    )
    evidence_root.join("normalized-build-settings.txt").binwrite(normalized_build_settings_content)
    evidence_root.join("normalized-build.log").binwrite(normalized_build_log_content)
    inventory = IOSBuild8ScreenshotCandidateValidator::EXPECTED_NON_WATCH_INVENTORY_PATHS.map do |path|
      digest = path == "./QuakeSignal" ? "c" * 64 : "1" * 64
      "#{digest}  #{path}"
    end.join("\n") << "\n"
    evidence_root.join("source-non-watch-inventory.txt").binwrite(inventory)
    evidence_root.join("install-copy-non-watch-inventory.txt").binwrite(inventory)
    evidence_root.join("non-watch.diff").binwrite("")
    evidence_root.join("simulator-install-transformation.txt").binwrite(
      transformation_record_content(inventory)
    )
  end

  def write_candidate(manifest: candidate_manifest, provenance: candidate_provenance)
    @store.join(IOSBuild8ScreenshotCandidateValidator::MANIFEST_NAME).write(JSON.pretty_generate(manifest)) if manifest
    if provenance
      @store.join(IOSBuild8ScreenshotCandidateValidator::PROVENANCE_NAME).write(JSON.pretty_generate(provenance))
    end
  end

  def assert_rejected(manifest: candidate_manifest, provenance: candidate_provenance)
    write_candidate(manifest: manifest, provenance: provenance)
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }
  end

  def test_absent_candidate_is_allowed
    assert_equal :absent, validator.validate_optional!
  end

  def test_partial_candidate_metadata_is_rejected_in_both_directions
    build_screenshot_tree
    write_candidate(manifest: candidate_manifest, provenance: nil)
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }

    @store.join(IOSBuild8ScreenshotCandidateValidator::MANIFEST_NAME).delete
    write_candidate(manifest: nil, provenance: candidate_provenance)
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }
  end

  def test_screenshot_directory_alone_or_with_one_metadata_file_is_rejected
    build_screenshot_tree
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }

    write_candidate(manifest: candidate_manifest, provenance: nil)
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }
  end

  def test_build_evidence_directory_alone_is_rejected
    build_screenshot_tree
    FileUtils.rm_rf(@store.join(IOSBuild8ScreenshotCandidateValidator::SCREENSHOT_ROOT))

    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }
  end

  def test_metadata_symlinks_are_rejected
    build_screenshot_tree
    write_candidate

    manifest_path = @store.join(IOSBuild8ScreenshotCandidateValidator::MANIFEST_NAME)
    manifest_target = @root.join("manifest-target.json")
    manifest_target.write(manifest_path.read)
    manifest_path.delete
    File.symlink(manifest_target, manifest_path)
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }

    remove_candidate_metadata
    write_candidate
    provenance_path = @store.join(IOSBuild8ScreenshotCandidateValidator::PROVENANCE_NAME)
    provenance_target = @root.join("provenance-target.json")
    provenance_target.write(provenance_path.read)
    provenance_path.delete
    File.symlink(provenance_target, provenance_path)
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }
  end

  def test_symlinked_validation_root_and_app_store_ancestor_are_rejected
    root_link = @root.dirname.join("#{@root.basename}-link")
    File.symlink(@root, root_link)
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) do
      IOSBuild8ScreenshotCandidateValidator.new(
        root: root_link,
        image_inspector: @inspector,
        historical_commit_guard: @source_guard,
      )
    end
    root_link.delete

    real_store = @root.join("real-app-store")
    FileUtils.mv(@store, real_store)
    File.symlink(real_store, @store)
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator }
  end

  def test_symlinked_screenshot_root_locale_class_and_file_are_rejected
    cases = {
      "root" => lambda do |target|
        source = @store.join("screenshots-v1.1-build9")
        FileUtils.mv(source, target)
        File.symlink(target, source)
      end,
      "locale" => lambda do |target|
        source = @store.join("screenshots-v1.1-build9", "en-US")
        FileUtils.mv(source, target)
        File.symlink(target, source)
      end,
      "class" => lambda do |target|
        source = @store.join("screenshots-v1.1-build9", "en-US", "iphone-6.5")
        FileUtils.mv(source, target)
        File.symlink(target, source)
      end,
      "file" => lambda do |target|
        source = @store.join(
          "screenshots-v1.1-build9", "en-US", "iphone-6.5", "01-home.jpg"
        )
        FileUtils.mv(source, target)
        File.symlink(target, source)
      end,
    }

    cases.each do |name, mutate|
      FileUtils.rm_rf(@store.join("screenshots-v1.1-build9"))
      remove_candidate_metadata
      build_screenshot_tree
      write_candidate
      target = @root.join("symlink-target-#{name}")
      FileUtils.rm_rf(target)
      mutate.call(target)
      assert_raises(IOSBuild8ScreenshotCandidateValidationError, name) do
        validator.validate_optional!
      end
    end
  end

  def test_duplicate_top_level_and_nested_json_keys_are_rejected
    build_screenshot_tree
    manifest_json = JSON.generate(candidate_manifest)
    duplicate_top_level = manifest_json.sub(
      %Q[{"schemaVersion":1,],
      %Q[{"schemaVersion":1,"schemaVersion":1,],
    )
    refute_equal manifest_json, duplicate_top_level
    @store.join(IOSBuild8ScreenshotCandidateValidator::MANIFEST_NAME).write(duplicate_top_level)
    @store.join(IOSBuild8ScreenshotCandidateValidator::PROVENANCE_NAME).write(
      JSON.generate(candidate_provenance),
    )
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }

    remove_candidate_metadata
    provenance_json = JSON.generate(candidate_provenance)
    duplicate_nested = provenance_json.sub(
      %Q["sdk":"iphonesimulator26.5"],
      %Q["sdk":"iphonesimulator26.5","sdk":"iphonesimulator26.5"],
    )
    refute_equal provenance_json, duplicate_nested
    @store.join(IOSBuild8ScreenshotCandidateValidator::MANIFEST_NAME).write(
      JSON.generate(candidate_manifest),
    )
    @store.join(IOSBuild8ScreenshotCandidateValidator::PROVENANCE_NAME).write(duplicate_nested)
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }
  end

  def test_valid_unapproved_debug_simulator_candidate_passes
    build_screenshot_tree
    write_candidate

    assert_equal :validated, validator.validate_optional!
    assert_equal [SOURCE_COMMIT], @source_guard.commits
    assert_equal 10, @inspector.inspected.length
  end

  def test_full_build_settings_section_allows_commit_safe_user_placeholders
    build_screenshot_tree
    provenance = deep_copy(candidate_provenance)
    content = [
      "Command line invocation:",
      "    #{IOSBuild8ScreenshotCandidateValidator::EXPECTED_BUILD_SETTINGS_INVOCATION}",
      "",
      "Build settings from command line:",
      "    SDKROOT = iphonesimulator26.5",
      "",
      "Build settings for action build and target QuakeSignal:",
      "    SDKROOT = <XCODE_APP>/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk",
      "    ALTERNATE_OWNER = <USER>",
      "    INSTALL_OWNER = <USER>",
      "    USER = <USER>",
      "    VERSION_INFO_BUILDER = <USER>",
      normalized_build_settings_content,
    ].join("\n")
    rewrite_evidence_and_rehash!(provenance, "normalizedBuildSettings", content)
    write_candidate(provenance: provenance)

    assert_equal :validated, validator.validate_optional!
  end

  def test_host_macos_evidence_is_optional
    build_screenshot_tree
    provenance = deep_copy(candidate_provenance)
    provenance.fetch("capture").delete("hostMacOS")
    write_candidate(provenance: provenance)

    assert_equal :validated, validator.validate_optional!
  end

  def test_rejects_approval_and_release_semantics
    build_screenshot_tree
    mutations = [
      ->(manifest, _) { manifest["status"] = "approved" },
      ->(manifest, _) { manifest["uploadApproved"] = true },
      ->(manifest, _) { manifest["signedReleaseEvidence"] = true },
      ->(manifest, _) { manifest["releaseApproval"] = { "status" => "approved" } },
      ->(_, provenance) { provenance["status"] = "approved" },
      ->(_, provenance) { provenance["uploadApproved"] = true },
      ->(_, provenance) { provenance["signedReleaseEvidence"] = true },
      ->(_, provenance) { provenance["capture"]["reviewer"] = "Release Owner" },
      ->(manifest, _) { manifest["captureEvidence"]["reviewer"] = "Release Owner" },
      ->(_, provenance) { provenance["releaseApproval"] = { "status" => "approved" } },
      ->(_, provenance) { provenance["releaseBinaryEvidence"] = "signed" },
    ]

    mutations.each do |mutate|
      manifest = deep_copy(candidate_manifest)
      provenance = deep_copy(candidate_provenance)
      mutate.call(manifest, provenance)
      assert_rejected(manifest: manifest, provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_unknown_approval_looking_and_benign_keys_at_every_object_boundary
    build_screenshot_tree
    mutations = [
      ->(manifest, _) { manifest["releaseApproval"] = "approved" },
      ->(manifest, _) { manifest["notes"] = "benign" },
      ->(manifest, _) { manifest["product"]["approval"] = false },
      ->(manifest, _) { manifest["captureEvidence"]["notes"] = "benign" },
      ->(manifest, _) { manifest["locales"].first["notes"] = "benign" },
      ->(manifest, _) { manifest["displayClasses"]["iphone-6.5"]["approval"] = false },
      ->(manifest, _) { manifest["frames"].first["description"] = "Home" },
      ->(_, provenance) { provenance["releaseApproval"] = "approved" },
      ->(_, provenance) { provenance["notes"] = "benign" },
      ->(_, provenance) { provenance["product"]["approval"] = false },
      ->(_, provenance) { provenance["capture"]["notes"] = "benign" },
      ->(_, provenance) { provenance["capture"]["runtime"]["approval"] = false },
      ->(_, provenance) { provenance["capture"]["devices"].first["notes"] = "benign" },
      ->(_, provenance) { provenance["automationGates"]["approval"] = false },
      lambda do |_manifest, provenance|
        provenance["automationGates"]["requiredEnvironment"]["notes"] = "benign"
      end,
      ->(_, provenance) { provenance["fixture"]["approval"] = false },
      ->(_, provenance) { provenance["buildEvidence"]["notes"] = "benign" },
      ->(_, provenance) { provenance["buildEvidence"]["buildInvocation"]["notes"] = "benign" },
      ->(_, provenance) { provenance["buildEvidence"]["normalizedBuildLog"]["notes"] = "benign" },
      lambda do |_manifest, provenance|
        provenance["buildEvidence"]["simulatorInstallTransformation"]["notes"] = "benign"
      end,
      lambda do |_manifest, provenance|
        provenance["buildEvidence"]["simulatorInstallTransformation"]["transformationRecord"]["notes"] =
          "benign"
      end,
      ->(_, provenance) { provenance["files"].first["description"] = "Home" },
    ]

    mutations.each do |mutate|
      manifest = deep_copy(candidate_manifest)
      provenance = deep_copy(candidate_provenance)
      mutate.call(manifest, provenance)
      assert_rejected(manifest: manifest, provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_wrong_product_or_simulator_contract
    build_screenshot_tree
    mutations = [
      ->(manifest, _) { manifest["product"]["marketingVersion"] = "1.0" },
      ->(manifest, _) { manifest["product"]["build"] = 7 },
      ->(manifest, _) { manifest["product"]["configuration"] = "Release" },
      ->(_, provenance) { provenance["product"]["platform"] = "iOS" },
      ->(_, provenance) { provenance["product"]["build"] = 8 },
      ->(_, provenance) { provenance["product"]["configuration"] = "Release" },
      ->(_, provenance) { provenance["product"]["sdk"] = "iphoneos26.5" },
      ->(_, provenance) { provenance["product"]["signing"] = "automatic" },
    ]

    mutations.each do |mutate|
      manifest = deep_copy(candidate_manifest)
      provenance = deep_copy(candidate_provenance)
      mutate.call(manifest, provenance)
      assert_rejected(manifest: manifest, provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_json_scalar_type_coercion
    build_screenshot_tree
    mutations = [
      ->(manifest, _) { manifest["schemaVersion"] = 1.0 },
      ->(manifest, _) { manifest["product"]["build"] = "8" },
      lambda do |manifest, _|
        manifest["displayClasses"]["iphone-6.5"]["portraitPixels"] = [1242.0, 2688]
      end,
      lambda do |manifest, _|
        manifest["displayClasses"]["iphone-6.5"]["requiredFramesPerApprovedLocale"] = "5"
      end,
      ->(_, provenance) { provenance["uploadApproved"] = 0 },
      ->(_, provenance) { provenance["product"]["build"] = 8.0 },
      ->(_, provenance) { provenance["capture"]["devices"].first["width"] = "1242" },
      ->(_, provenance) { provenance["fixture"]["warning"] = 0 },
      ->(_, provenance) { provenance["files"].first["pixels"] = [1242, 2688.0] },
    ]

    mutations.each do |mutate|
      manifest = deep_copy(candidate_manifest)
      provenance = deep_copy(candidate_provenance)
      mutate.call(manifest, provenance)
      assert_rejected(manifest: manifest, provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_invalid_or_mismatched_source_and_source_drift
    build_screenshot_tree

    manifest = deep_copy(candidate_manifest)
    manifest["captureEvidence"]["sourceBaselineCommit"] = "short"
    assert_rejected(manifest: manifest)
    remove_candidate_metadata

    provenance = deep_copy(candidate_provenance)
    provenance["capture"]["sourceBaselineCommit"] = "b" * 40
    assert_rejected(provenance: provenance)
    remove_candidate_metadata

    provenance = deep_copy(candidate_provenance)
    provenance["capture"]["sourceTreeState"] = "dirty"
    assert_rejected(provenance: provenance)
    remove_candidate_metadata

    @source_guard.error = IOSBuild8ScreenshotCandidateValidationError.new("app-source drift")
    write_candidate
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }
  end

  def test_rejects_missing_or_false_automation_gate_evidence
    build_screenshot_tree
    mutations = [
      ->(provenance) { provenance["automationGates"].delete("requiredLaunchArgument") },
      ->(provenance) { provenance["automationGates"]["requiredLaunchArgument"] = "--different" },
      ->(provenance) { provenance["automationGates"]["requiredEnvironment"] = {} },
      ->(provenance) { provenance["automationGates"]["bothSupplied"] = false },
      ->(provenance) { provenance["automationGates"]["sourceConstraint"] = "Release" },
    ]

    mutations.each do |mutate|
      provenance = deep_copy(candidate_provenance)
      mutate.call(provenance)
      assert_rejected(provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_warning_training_or_wrong_fixture_evidence
    build_screenshot_tree
    mutations = [
      ->(provenance) { provenance["fixture"]["identifier"] = "live-warning" },
      ->(provenance) { provenance["fixture"]["warning"] = true },
      ->(provenance) { provenance["fixture"]["training"] = true },
    ]

    mutations.each do |mutate|
      provenance = deep_copy(candidate_provenance)
      mutate.call(provenance)
      assert_rejected(provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_incomplete_runtime_device_or_executable_evidence
    build_screenshot_tree
    mutations = [
      ->(provenance) { provenance["capture"]["runtime"]["identifier"] = "iOS 26.5" },
      ->(provenance) { provenance["capture"]["devices"].pop },
      ->(provenance) { provenance["capture"]["devices"].first["modelIdentifier"] = "iPhone0,0" },
      ->(provenance) { provenance["capture"]["devices"].first["width"] = 1 },
      ->(provenance) { provenance["capture"]["devices"].first["udid"] = "not-a-uuid" },
      ->(provenance) { provenance["buildEvidence"]["mainExecutableSha256"] = "short" },
    ]

    mutations.each do |mutate|
      provenance = deep_copy(candidate_provenance)
      mutate.call(provenance)
      assert_rejected(provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_missing_or_malformed_xcode_and_optional_host_macos_evidence
    build_screenshot_tree
    mutations = [
      ->(provenance) { provenance["capture"].delete("xcode") },
      ->(provenance) { provenance["capture"]["xcode"] = "26.6" },
      ->(provenance) { provenance["capture"]["xcode"] = "  " },
      ->(provenance) { provenance["capture"]["hostMacOS"] = "26.6.2" },
    ]

    mutations.each do |mutate|
      provenance = deep_copy(candidate_provenance)
      mutate.call(provenance)
      assert_rejected(provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_manifest_and_provenance_executable_digest_mismatch
    build_screenshot_tree
    manifest = deep_copy(candidate_manifest)
    manifest["captureEvidence"]["artifactSha256"] = "d" * 64
    assert_rejected(manifest: manifest)
  end

  def test_rejects_claimed_or_actual_debug_local_override
    build_screenshot_tree
    provenance = deep_copy(candidate_provenance)
    provenance["buildEvidence"]["debugLocalOverridePresent"] = true
    assert_rejected(provenance: provenance)
    remove_candidate_metadata

    override = @root.join("ios", "QuakeSignal", "Supporting", "Debug.local.xcconfig")
    FileUtils.mkdir_p(override.dirname)
    override.write("QUAKESIGNAL_BACKEND_URL = https://example.invalid\n")
    write_candidate
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }
  end

  def test_rejects_missing_unknown_invalid_or_false_build_evidence_claims
    build_screenshot_tree
    mutations = [
      ->(evidence) { evidence.delete("buildInvocation") },
      ->(evidence) { evidence.delete("normalizedBuildSettings") },
      ->(evidence) { evidence.delete("normalizedBuildLog") },
      ->(evidence) { evidence.delete("targetBuildLogSha256") },
      ->(evidence) { evidence["targetBuildLogSha256"] = "short" },
      ->(evidence) { evidence["normalizedBuildLog"]["sourceLogSha256"] = "e" * 64 },
      ->(evidence) { evidence["buildInvocation"]["file"] = "elsewhere.txt" },
      ->(evidence) { evidence["buildInvocation"]["sha256"] = 1 },
      ->(evidence) { evidence["buildInvocation"]["extra"] = false },
      ->(evidence) { evidence.delete("simulatorInstallTransformation") },
      ->(evidence) { evidence["simulatorInstallTransformation"].delete("nonWatchDiffEmpty") },
      ->(evidence) { evidence["simulatorInstallTransformation"]["extra"] = true },
      ->(evidence) { evidence["simulatorInstallTransformation"]["embeddedWatchRemovalOnly"] = false },
      ->(evidence) { evidence["simulatorInstallTransformation"]["nonWatchDiffEmpty"] = false },
      ->(evidence) { evidence["simulatorInstallTransformation"]["mainExecutableUnchanged"] = false },
      ->(evidence) { evidence["simulatorInstallTransformation"].delete("sourceNonWatchInventory") },
      ->(evidence) { evidence["simulatorInstallTransformation"]["sourceExecutableSha256"] = "short" },
      ->(evidence) { evidence["simulatorInstallTransformation"]["installedExecutableSha256"] = 1 },
    ]

    mutations.each do |mutate|
      provenance = deep_copy(candidate_provenance)
      mutate.call(provenance.fetch("buildEvidence"))
      assert_rejected(provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_missing_extra_changed_or_symlinked_build_evidence_files
    mutations = {
      "missing" => lambda do |_provenance|
        @store.join(
          IOSBuild8ScreenshotCandidateValidator::BUILD_EVIDENCE_FILES.fetch("buildInvocation")
        ).delete
      end,
      "extra" => lambda do |_provenance|
        @store.join(IOSBuild8ScreenshotCandidateValidator::BUILD_EVIDENCE_ROOT, "extra.txt").write("extra\n")
      end,
      "changed" => lambda do |_provenance|
        @store.join(
          IOSBuild8ScreenshotCandidateValidator::BUILD_EVIDENCE_FILES.fetch("normalizedBuildSettings")
        ).write("changed after provenance\n")
      end,
      "symlinked file" => lambda do |_provenance|
        file = @store.join(
          IOSBuild8ScreenshotCandidateValidator::BUILD_EVIDENCE_FILES.fetch("buildInvocation")
        )
        target = @root.join("build-invocation-target.txt")
        target.write(file.read)
        file.delete
        File.symlink(target, file)
      end,
      "symlinked root" => lambda do |_provenance|
        evidence_root = @store.join(IOSBuild8ScreenshotCandidateValidator::BUILD_EVIDENCE_ROOT)
        target = @root.join("build-evidence-target")
        FileUtils.rm_rf(target)
        FileUtils.mv(evidence_root, target)
        File.symlink(target, evidence_root)
      end,
    }

    mutations.each do |name, mutate|
      remove_candidate_metadata
      FileUtils.rm_rf(@store.join(IOSBuild8ScreenshotCandidateValidator::BUILD_EVIDENCE_ROOT))
      build_screenshot_tree
      provenance = deep_copy(candidate_provenance)
      mutate.call(provenance)
      assert_rejected(provenance: provenance)
    rescue Minitest::Assertion => error
      raise Minitest::Assertion, "#{name}: #{error.message}"
    end
  end

  def test_rejects_semantically_wrong_build_invocation_after_rehashing
    mutations = [
      ["-configuration Debug", "-configuration Release"],
      ["-sdk iphonesimulator26.5", "-sdk iphoneos26.5"],
      ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_ALLOWED=YES"],
    ]

    mutations.each do |from, to|
      build_screenshot_tree
      provenance = deep_copy(candidate_provenance)
      content = "#{IOSBuild8ScreenshotCandidateValidator::EXPECTED_BUILD_INVOCATION}\n".sub(from, to)
      refute_includes content, from
      rewrite_evidence_and_rehash!(provenance, "buildInvocation", content)
      assert_rejected(provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_semantically_wrong_or_conflicting_build_settings_after_rehashing
    mutations = [
      ->(content) { content.sub("CONFIGURATION=Debug", "CONFIGURATION=Release") },
      ->(content) { content.sub("PLATFORM_NAME=iphonesimulator", "PLATFORM_NAME=iphoneos") },
      ->(content) { content.gsub("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_ALLOWED=YES") },
      ->(content) { "#{content}CONFIGURATION=Release\n" },
      ->(content) { "#{content}not a normalized build setting\n" },
    ]

    mutations.each do |mutate|
      build_screenshot_tree
      provenance = deep_copy(candidate_provenance)
      rewrite_evidence_and_rehash!(
        provenance,
        "normalizedBuildSettings",
        mutate.call(normalized_build_settings_content),
      )
      assert_rejected(provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_wrong_build_log_anchors_architectures_or_result_after_rehashing
    valid_log = normalized_build_log_content
    mutations = [
      ->(content) { content.gsub("-configuration Debug", "-configuration Release") },
      ->(content) { content.gsub("iphonesimulator26.5", "iphoneos26.5") },
      ->(content) { content.gsub("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_ALLOWED=YES") },
      ->(content) { content.sub(/^SwiftDriver QuakeSignal normal x86_64 .*\n/, "") },
      ->(content) { content.sub(/^Ld .*\/x86_64\/Binary\/QuakeSignal normal x86_64 .*\n/, "") },
      ->(content) { content.sub("** BUILD SUCCEEDED **", "** BUILD FAILED **") },
      ->(content) { "#{content}** BUILD SUCCEEDED **\n" },
      lambda do |content|
        content.sub(
          "Command line invocation:\n",
          "Command line invocation:\n" \
          "    <XCODE_APP>/Contents/Developer/usr/bin/xcodebuild build -configuration Release -sdk iphoneos26.5 CODE_SIGNING_ALLOWED=YES\n",
        )
      end,
    ]

    mutations.each do |mutate|
      build_screenshot_tree
      provenance = deep_copy(candidate_provenance)
      mutated_log = mutate.call(valid_log)
      refute_equal valid_log, mutated_log
      rewrite_evidence_and_rehash!(provenance, "normalizedBuildLog", mutated_log)
      assert_rejected(provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_internally_rehashed_simulator_transformation_tampering
    mutations = [
      lambda do |provenance|
        rewrite_evidence_and_rehash!(
          provenance,
          "installCopyNonWatchInventory",
          "#{"2" * 64}  ./ATTRIBUTION.md\n#{"c" * 64}  ./QuakeSignal\n",
        )
        refresh_transformation_record!(provenance)
      end,
      lambda do |provenance|
        rewrite_evidence_and_rehash!(provenance, "nonWatchDiff", "unexpected difference\n")
        refresh_transformation_record!(provenance)
      end,
      lambda do |provenance|
        transformation = provenance.fetch("buildEvidence").fetch("simulatorInstallTransformation")
        transformation["sourceExecutableSha256"] = "e" * 64
        refresh_transformation_record!(provenance)
      end,
      lambda do |provenance|
        transformation = provenance.fetch("buildEvidence").fetch("simulatorInstallTransformation")
        transformation["installedExecutableSha256"] = "e" * 64
        refresh_transformation_record!(provenance)
      end,
      lambda do |provenance|
        rewrite_evidence_and_rehash!(provenance, "sourceNonWatchInventory", "")
        rewrite_evidence_and_rehash!(provenance, "installCopyNonWatchInventory", "")
        refresh_transformation_record!(provenance)
      end,
      lambda do |provenance|
        executable_only = "#{"c" * 64}  ./QuakeSignal\n"
        rewrite_evidence_and_rehash!(provenance, "sourceNonWatchInventory", executable_only)
        rewrite_evidence_and_rehash!(provenance, "installCopyNonWatchInventory", executable_only)
        refresh_transformation_record!(provenance)
      end,
      lambda do |provenance|
        inventory = "#{"c" * 64}  ./QuakeSignal\n#{"3" * 64}  ./Watch/Companion.app\n"
        rewrite_evidence_and_rehash!(provenance, "sourceNonWatchInventory", inventory)
        rewrite_evidence_and_rehash!(provenance, "installCopyNonWatchInventory", inventory)
        refresh_transformation_record!(provenance)
      end,
      lambda do |provenance|
        refresh_transformation_record!(provenance, operation: "copy-entire-app")
      end,
    ]

    mutations.each do |mutate|
      build_screenshot_tree
      provenance = deep_copy(candidate_provenance)
      mutate.call(provenance)
      assert_rejected(provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_invalid_mismatched_or_nonchronological_capture_times
    build_screenshot_tree
    mutations = [
      lambda do |manifest, _provenance|
        manifest["captureEvidence"]["capturedAtUtcRange"] = ["2026-08-19T00:00:00Z", "2026-08-19T00:06:00Z"]
      end,
      lambda do |_manifest, provenance|
        provenance["capture"]["capturedAtUtcRange"] = ["2026-08-19T00:00:00+09:00", "2026-08-19T00:05:00Z"]
      end,
      lambda do |_manifest, provenance|
        provenance["capture"]["capturedAtUtcRange"] = ["2026-08-19T00:05:00Z", "2026-08-19T00:00:00Z"]
      end,
    ]

    mutations.each do |mutate|
      manifest = deep_copy(candidate_manifest)
      provenance = deep_copy(candidate_provenance)
      mutate.call(manifest, provenance)
      assert_rejected(manifest: manifest, provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_wrong_manifest_inventory
    build_screenshot_tree
    mutations = [
      ->(manifest) { manifest["locales"] << { "directory" => "ja" } },
      ->(manifest) { manifest["displayClasses"].delete("ipad-13") },
      ->(manifest) { manifest["displayClasses"]["iphone-6.5"]["portraitPixels"] = [1284, 2778] },
      ->(manifest) { manifest["frames"].pop },
      ->(manifest) { manifest["frames"].first["captureStatus"] = "approved" },
    ]

    mutations.each do |mutate|
      manifest = deep_copy(candidate_manifest)
      mutate.call(manifest)
      assert_rejected(manifest: manifest)
      remove_candidate_metadata
    end
  end

  def test_rejects_wrong_provenance_inventory_and_file_records
    build_screenshot_tree
    mutations = [
      ->(provenance) { provenance["files"].pop },
      ->(provenance) { provenance["files"] << deep_copy(provenance["files"].first) },
      ->(provenance) { provenance["files"].first["file"] = "en-US/iphone-6.5/extra.jpg" },
      ->(provenance) { provenance["files"].first["captureStatus"] = "approved" },
      ->(provenance) { provenance["files"].first["sha256"] = "0" * 64 },
      ->(provenance) { provenance["files"].first["pixels"] = [1, 1] },
      ->(provenance) { provenance["files"].first["format"] = "png" },
      ->(provenance) { provenance["files"].first["hasAlpha"] = true },
    ]

    mutations.each do |mutate|
      provenance = deep_copy(candidate_provenance)
      mutate.call(provenance)
      assert_rejected(provenance: provenance)
      remove_candidate_metadata
    end
  end

  def test_rejects_extra_or_missing_actual_files
    build_screenshot_tree
    extra = @store.join("screenshots-v1.1-build9", "en-US", "iphone-6.5", "extra.jpg")
    extra.write("extra")
    assert_rejected
    remove_candidate_metadata

    extra.delete
    relative_path = IOSBuild8ScreenshotCandidateValidator::EXPECTED_RELATIVE_PATHS.first
    missing = @store.join("screenshots-v1.1-build9", relative_path)
    provenance = candidate_provenance
    missing.delete
    assert_rejected(provenance: provenance)
  end

  def test_rejects_bad_actual_image_properties
    build_screenshot_tree
    mutations = [
      { width: 1 },
      { format: "png" },
      { has_alpha: true },
    ]

    mutations.each do |properties|
      @inspector.mutations = { "01-home.jpg" => properties }
      write_candidate
      assert_raises(IOSBuild8ScreenshotCandidateValidationError) { validator.validate_optional! }
      remove_candidate_metadata
    end
  end

  private

  def normalized_build_settings_content
    lines = IOSBuild8ScreenshotCandidateValidator::REQUIRED_BUILD_SETTINGS.map do |key, value|
      "#{key}=#{value}"
    end
    code_signing = lines.index("CODE_SIGNING_ALLOWED=NO")
    lines.insert(code_signing + 1, "CODE_SIGNING_ALLOWED=NO")
    "#{lines.join("\n")}\n"
  end

  def normalized_build_log_content
    invocation = IOSBuild8ScreenshotCandidateValidator::EXPECTED_BUILD_INVOCATION
    [
      "Command line invocation:",
      "    #{invocation}",
      "",
      "Build settings from command line:",
      "    CODE_SIGNING_ALLOWED = NO",
      "",
      "SwiftDriver QuakeSignal normal arm64 com.apple.xcode.tools.swift.compiler (in target 'QuakeSignal' from project 'QuakeSignal')",
      "SwiftDriver QuakeSignal normal x86_64 com.apple.xcode.tools.swift.compiler (in target 'QuakeSignal' from project 'QuakeSignal')",
      "Ld <ARTIFACT_ROOT>/build/Intermediates/QuakeSignal.build/Debug-iphonesimulator/QuakeSignal.build/Objects-normal/arm64/Binary/QuakeSignal normal arm64 (in target 'QuakeSignal' from project 'QuakeSignal')",
      "Ld <ARTIFACT_ROOT>/build/Intermediates/QuakeSignal.build/Debug-iphonesimulator/QuakeSignal.build/Objects-normal/x86_64/Binary/QuakeSignal normal x86_64 (in target 'QuakeSignal' from project 'QuakeSignal')",
      "** BUILD SUCCEEDED **",
    ].join("\n") << "\n"
  end

  def transformation_record_content(_inventory)
    [
      "purpose=Simulator installation compatibility only",
      "sourceProduct=<ARTIFACT_ROOT>/build/Products/Debug-iphonesimulator/QuakeSignal.app",
      "installCopy=<ARTIFACT_ROOT>/capture-app-no-watch/QuakeSignal.app",
      "operation=rsync -a --exclude=Watch/ <sourceProduct>/ <installCopy>/",
      "omittedRelativePath=Watch/",
      "reason=The embedded Watch bundle is incompatible with the available CoreSimulator runtime.",
      "builtProductModified=false",
      "nonWatchByteDiff=false",
      "nonWatchDiffEvidence=#{IOSBuild8ScreenshotCandidateValidator::BUILD_EVIDENCE_FILES.fetch("nonWatchDiff")}",
      "mainExecutableIdentical=true",
      "mainExecutableSha256=#{"c" * 64}",
      "distributionSigningUsed=false",
      "credentialsUsed=false",
    ].join("\n") << "\n"
  end

  def rewrite_evidence_and_rehash!(provenance, field, content)
    build_evidence = provenance.fetch("buildEvidence")
    record = if IOSBuild8ScreenshotCandidateValidator::TOP_LEVEL_BUILD_EVIDENCE_FILES.include?(field)
               build_evidence.fetch(field)
             else
               build_evidence.fetch("simulatorInstallTransformation").fetch(field)
             end
    @store.join(record.fetch("file")).binwrite(content)
    record["sha256"] = Digest::SHA256.hexdigest(content)
  end

  def refresh_transformation_record!(
    provenance,
    operation: "rsync -a --exclude=Watch/ <sourceProduct>/ <installCopy>/"
  )
    build_evidence = provenance.fetch("buildEvidence")
    content = [
      "purpose=Simulator installation compatibility only",
      "sourceProduct=<ARTIFACT_ROOT>/build/Products/Debug-iphonesimulator/QuakeSignal.app",
      "installCopy=<ARTIFACT_ROOT>/capture-app-no-watch/QuakeSignal.app",
      "operation=#{operation}",
      "omittedRelativePath=Watch/",
      "reason=The embedded Watch bundle is incompatible with the available CoreSimulator runtime.",
      "builtProductModified=false",
      "nonWatchByteDiff=false",
      "nonWatchDiffEvidence=#{IOSBuild8ScreenshotCandidateValidator::BUILD_EVIDENCE_FILES.fetch("nonWatchDiff")}",
      "mainExecutableIdentical=true",
      "mainExecutableSha256=#{build_evidence.fetch("mainExecutableSha256")}",
      "distributionSigningUsed=false",
      "credentialsUsed=false",
    ].join("\n") << "\n"
    rewrite_evidence_and_rehash!(provenance, "transformationRecord", content)
  end

  def build_evidence_record(field)
    relative_path = IOSBuild8ScreenshotCandidateValidator::BUILD_EVIDENCE_FILES.fetch(field)
    evidence_file = @store.join(relative_path)
    {
      "file" => relative_path,
      "sha256" => Digest::SHA256.file(evidence_file).hexdigest,
    }
  end

  def remove_candidate_metadata
    [
      IOSBuild8ScreenshotCandidateValidator::MANIFEST_NAME,
      IOSBuild8ScreenshotCandidateValidator::PROVENANCE_NAME,
    ].each do |name|
      path = @store.join(name)
      path.delete if path.exist? || path.symlink?
    end
  end
end

class SipsScreenshotInspectorTest < Minitest::Test
  FIXTURE = Pathname.new(__dir__).join(
    "..", "..", "ios", "AppStore", "screenshots-v1.1", "en-US", "iphone-6.5", "01-home.jpg"
  ).realpath

  def test_reads_real_opaque_repository_jpeg
    assert_equal(
      { width: 1242, height: 2688, format: "jpeg", has_alpha: false },
      SipsScreenshotInspector.new.inspect(FIXTURE),
    )
  end
end

class IOSBuild8ScreenshotSourceGuardTest < Minitest::Test
  def setup
    @temporary_directory = Dir.mktmpdir("ios-build8-source-guard")
    @root = Pathname.new(@temporary_directory)
    git!("init", "--initial-branch=main")
    git!("config", "user.email", "validator@example.invalid")
    git!("config", "user.name", "Screenshot Validator")
    app_source = @root.join("ios", "QuakeSignal", "App.swift")
    FileUtils.mkdir_p(app_source.dirname)
    app_source.write("struct App {}\n")
    git!("add", "ios/QuakeSignal/App.swift")
    git!("commit", "-m", "capture source")
    @baseline = git!("rev-parse", "HEAD").strip

    evidence = @root.join("ios", "AppStore", "evidence.json")
    FileUtils.mkdir_p(evidence.dirname)
    evidence.write("{}\n")
    git!("add", "ios/AppStore/evidence.json")
    git!("commit", "-m", "record screenshot evidence")
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory)
  end

  def test_allows_evidence_only_commits_after_capture
    IOSBuild8ScreenshotSourceGuard.new(@root).validate!(@baseline)
  end

  def test_rejects_committed_uncommitted_and_untracked_app_source_drift
    source = @root.join("ios", "QuakeSignal", "App.swift")
    source.write("struct ChangedApp {}\n")
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) do
      IOSBuild8ScreenshotSourceGuard.new(@root).validate!(@baseline)
    end

    git!("add", "ios/QuakeSignal/App.swift")
    git!("commit", "-m", "change app source")
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) do
      IOSBuild8ScreenshotSourceGuard.new(@root).validate!(@baseline)
    end

    untracked = @root.join("ios", "QuakeSignalShared", "New.swift")
    FileUtils.mkdir_p(untracked.dirname)
    untracked.write("struct New {}\n")
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) do
      IOSBuild8ScreenshotSourceGuard.new(@root).validate!(git!("rev-parse", "HEAD").strip)
    end
  end

  def test_rejects_unknown_and_non_ancestor_source_commits
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) do
      IOSBuild8ScreenshotSourceGuard.new(@root).validate!("f" * 40)
    end

    git!("checkout", "--orphan", "side")
    git!("rm", "-rf", ".")
    side_file = @root.join("side.txt")
    side_file.write("side\n")
    git!("add", "side.txt")
    git!("commit", "-m", "unrelated source")
    unrelated = git!("rev-parse", "HEAD").strip
    git!("checkout", "main")

    assert_raises(IOSBuild8ScreenshotCandidateValidationError) do
      IOSBuild8ScreenshotSourceGuard.new(@root).validate!(unrelated)
    end
  end

  def test_allows_two_parent_merge_when_app_source_matches_capture_baseline
    git!("checkout", "-b", "metadata-side", @baseline)
    side = @root.join("ios", "AppStore", "side.json")
    FileUtils.mkdir_p(side.dirname)
    side.write("{}\n")
    git!("add", "ios/AppStore/side.json")
    git!("commit", "-m", "side metadata")
    git!("checkout", "main")
    git!("merge", "--no-ff", "metadata-side", "-m", "merge metadata")

    assert_equal 3, git!("rev-list", "--parents", "-n", "1", "HEAD").split.length
    IOSBuild8ScreenshotSourceGuard.new(@root).validate!(@baseline)
  end

  def test_rejects_two_parent_merge_with_app_source_drift
    git!("checkout", "-b", "app-source-side", @baseline)
    @root.join("ios", "QuakeSignal", "App.swift").write("struct ChangedApp {}\n")
    git!("add", "ios/QuakeSignal/App.swift")
    git!("commit", "-m", "change app source on side")
    git!("checkout", "main")
    git!("merge", "--no-ff", "app-source-side", "-m", "merge app source")

    assert_equal 3, git!("rev-list", "--parents", "-n", "1", "HEAD").split.length
    assert_raises(IOSBuild8ScreenshotCandidateValidationError) do
      IOSBuild8ScreenshotSourceGuard.new(@root).validate!(@baseline)
    end
  end

  private

  def git!(*arguments)
    output, error_output, status = Open3.capture3("git", "-C", @root.to_s, *arguments)
    return output if status.success?

    raise "git #{arguments.join(' ')} failed: #{error_output}"
  end
end

class ListingAssetsWorkflowContractTest < Minitest::Test
  WORKFLOW_PATH = Pathname.new(__dir__).join("..", "workflows", "listing-assets.yml").realpath

  def test_current_workflow_has_full_history_paths_and_commands
    assert ListingAssetsWorkflowContract.validate!(WORKFLOW_PATH.read)
  end

  def test_rejects_mutated_workflow_execution_contract
    source = WORKFLOW_PATH.read
    mutations = [
      ["fetch-depth: 0", "fetch-depth: 1"],
      [
        "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
        "actions/checkout@main",
      ],
      [
        "        with:\n          fetch-depth: 0\n",
        "        with:\n          fetch-depth: 0\n          ref: main\n",
      ],
      ["      - \"ios/QuakeSignal/**\"\n", ""],
      ["      - \"ios/ScreenshotAutomation/**\"\n", ""],
      ["      - \"ios/QuakeSignalTV/**\"\n", ""],
      ["      - \"ios/QuakeSignalVision/**\"\n", ""],
      ["      - \"ios/QuakeSignalWatch/**\"\n", ""],
      [
        "      - \"ios/QuakeSignal.xcodeproj/project.xcworkspace/contents.xcworkspacedata\"\n",
        "",
      ],
      ["      - \"ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/**\"\n", ""],
      ["      - \".github/scripts/verify-ios-screenshot-candidates.rb\"\n", ""],
      ["      - \".github/scripts/verify-native-apple-screenshot-candidates.rb\"\n", ""],
      ["      - \".github/scripts/verify-apple-screenshot-release-set.rb\"\n", ""],
      ["      - \".github/scripts/verify-apple-screenshot-release-set.test.rb\"\n", ""],
      ["      - \".github/scripts/verify-ios-release-contract.mjs\"\n", ""],
      ["      - \".github/scripts/verify-ios-release-contract.test.mjs\"\n", ""],
      ["      - \".github/workflows/apple-platform-screenshots.yml\"\n", ""],
      ["      - \".github/workflows/workflow-lint.yml\"\n", ""],
      ["ruby .github/scripts/verify-ios-screenshot-candidates.test.rb", "ruby -v"],
      ["ruby .github/scripts/verify-ios-screenshot-candidates.rb", "ruby -v"],
      ["ruby .github/scripts/verify-native-apple-screenshot-candidates.test.rb", "ruby -v"],
      ["ruby .github/scripts/verify-native-apple-screenshot-candidates.rb", "ruby -v"],
      ["ruby .github/scripts/verify-apple-screenshot-release-set.test.rb", "ruby -v"],
      ["ruby .github/scripts/verify-apple-screenshot-release-set.rb", "ruby -v"],
      [
        "        run: ruby .github/scripts/verify-ios-screenshot-candidates.rb\n",
        "        run: |\n" \
        "          set +e\n" \
        "          ruby .github/scripts/verify-ios-screenshot-candidates.rb\n" \
        "          exit 0\n",
      ],
      [
        "      - name: Validate historical iOS screenshot bytes\n        run:",
        "      - name: Validate historical iOS screenshot bytes\n        if: false\n        run:",
      ],
      [
        "      - name: Validate historical iOS screenshot bytes\n        run:",
        "      - name: Validate historical iOS screenshot bytes\n        continue-on-error: true\n        run:",
      ],
      [
        "      - name: Validate historical iOS screenshot bytes\n        run:",
        "      - name: Validate historical iOS screenshot bytes\n" \
        "        shell: \"bash {0} || true\"\n        run:",
      ],
      [
        "      - name: Validate historical iOS screenshot bytes\n        run:",
        "      - name: Validate historical iOS screenshot bytes\n" \
        "        working-directory: .\n        run:",
      ],
      [
        "      - name: Validate historical iOS screenshot bytes\n        run:",
        "      - name: Validate historical iOS screenshot bytes\n" \
        "        env:\n          RUBYOPT: \"-w\"\n        run:",
      ],
      [
        "      - name: Check out repository\n        uses:",
        "      - name: Check out repository\n        if: true\n        uses:",
      ],
      [
        "      - name: Check out repository\n        uses:",
        "      - name: Check out repository\n        continue-on-error: false\n        uses:",
      ],
      [
        "      - name: Check out repository\n        uses:",
        "      - name: Check out repository\n        working-directory: .\n        uses:",
      ],
      [
        "      - name: Check out repository\n        uses:",
        "      - name: Check out repository\n        env:\n          CHECKOUT_OVERRIDE: \"1\"\n        uses:",
      ],
      [
        "  validate:\n    name:",
        "  validate:\n    if: false\n    name:",
      ],
      [
        "  validate:\n    name:",
        "  validate:\n    continue-on-error: false\n    name:",
      ],
      [
        "  validate:\n    name:",
        "  validate:\n    env:\n      RUBYOPT: \"-w\"\n    name:",
      ],
      [
        "  validate:\n    name:",
        "  validate:\n    defaults:\n      run:\n        shell: bash\n    name:",
      ],
      [
        "name: Store listing assets\n",
        "name: Store listing assets\n\nenv:\n  RUBYOPT: \"-w\"\n",
      ],
      [
        "name: Store listing assets\n",
        "name: Store listing assets\n\ndefaults:\n  run:\n    shell: bash\n",
      ],
    ]

    mutations.each do |from, to|
      mutated = source.sub(from, to)
      refute_equal source, mutated, "workflow fixture must contain #{from.inspect}"
      assert_raises(IOSBuild8ScreenshotCandidateValidationError) do
        ListingAssetsWorkflowContract.validate!(mutated)
      end
    end
  end
end
