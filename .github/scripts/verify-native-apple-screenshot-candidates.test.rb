# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "verify-native-apple-screenshot-candidates"

class FakeNativeAppleScreenshotInspector
  attr_reader :inspected, :mutations

  def initialize
    @inspected = []
    @mutations = {}
  end

  def inspect(path)
    @inspected << path.to_s
    match = path.to_s.match(/UNAPPROVED-debug-simulator-(tvos|watchos|visionos)-/)
    raise "could not infer fixture platform from #{path}" unless match

    pixels = QuakeSignalPlatformScreenshotPlan::EXPECTED.fetch(match[1]).fetch(:pixels)
    {
      width: pixels.fetch(0),
      height: pixels.fetch(1),
      format: "png",
      has_alpha: false,
    }.merge(@mutations.fetch(path.to_s, {}))
  end
end

class NativeAppleScreenshotCandidateValidatorTest < Minitest::Test
  SOURCE_ROOT = Pathname.new(__dir__).join("../..").realpath
  SCRIPT = SOURCE_ROOT.join(".github/scripts/verify-native-apple-screenshot-candidates.rb")
  TEST_TEMP_PARENT = Pathname.new(
    ENV["QUAKESIGNAL_TEST_TEMP_ROOT"] || ENV["RUNNER_TEMP"] || Dir.tmpdir,
  ).expand_path

  def setup
    TEST_TEMP_PARENT.mkpath
    @temporary_directory = Dir.mktmpdir(
      "native-apple-screenshot-candidates-test.",
      TEST_TEMP_PARENT.to_s,
    )
    @root = Pathname.new(@temporary_directory).realpath
    copy_candidate_fixture
    @inspector = FakeNativeAppleScreenshotInspector.new
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory) if @temporary_directory && File.exist?(@temporary_directory)
  end

  def test_valid_exact_candidate_set_passes_without_test_git_bypass_in_cli
    assert_equal :validated, validator.validate!
    assert_equal 11, @inspector.inspected.length
    assert_equal 11, @inspector.inspected.uniq.length

    source = SCRIPT.read
    assert_match(/verify_git:\s*true/, source)
    refute_match(/ENV.*verify_git|verify_git.*ENV/, source)
  end

  def test_real_checked_in_baseline_passes_the_cli_with_git_validation
    output, error_output, status = Open3.capture3(
      { "QUAKESIGNAL_TEST_TEMP_ROOT" => TEST_TEMP_PARENT.to_s },
      RbConfig.ruby,
      SCRIPT.to_s,
      chdir: SOURCE_ROOT.to_s,
    )

    assert status.success?, "CLI failed (#{status.exitstatus}):\n#{output}\n#{error_output}"
    assert_match(/Validated 3 historical unapproved native Apple screenshot packages/, output)
    assert_equal "", error_output
  end

  def test_duplicate_keys_are_rejected_in_receipt_and_nested_sidecar_json
    receipt = receipt_path
    original_receipt = receipt.binread
    duplicate_receipt = original_receipt.sub(
      %Q[  "schemaVersion": 1,\n],
      %Q[  "schemaVersion": 1,\n  "schemaVersion": 1,\n],
    )
    refute_equal original_receipt, duplicate_receipt
    replace_file(receipt, duplicate_receipt)
    assert_rejected(/duplicate JSON object key/)

    replace_file(receipt, original_receipt)
    sidecar = sidecar_path("tvos", 0)
    original_sidecar = sidecar.binread
    duplicate_sidecar = original_sidecar.sub(
      %Q[  "status": "unapproved-debug-simulator-capture-evidence",\n],
      %Q[  "status": "unapproved-debug-simulator-capture-evidence",\n] +
      %Q[  "status": "unapproved-debug-simulator-capture-evidence",\n],
    )
    refute_equal original_sidecar, duplicate_sidecar
    replace_file(sidecar, duplicate_sidecar)
    assert_rejected(/duplicate JSON object key/)
  end

  def test_root_and_package_inventory_reject_extra_missing_and_symlinked_entries
    extra = candidate_root.join("unexpected.txt")
    replace_file(extra, "unexpected\n")
    assert_rejected(/candidate root entry|candidate root inventory/)
    extra.delete

    readme = candidate_root.join("README.md")
    replace_file(readme, readme.binread.sub("These three", "Those three"))
    assert_rejected(/README SHA-256/)

    copy_one(SOURCE_ROOT.join(NativeAppleScreenshotCandidateValidator::CANDIDATE_ROOT, "README.md"), readme)
    screenshot = png_path("watchos", 0)
    target = png_path("watchos", 1)
    screenshot.delete
    File.symlink(target.basename.to_s, screenshot)
    assert_rejected(/symlink or non-regular entry/)
  end

  def test_missing_package_and_unexpected_package_file_are_rejected
    package = package_root("tvos")
    moved = @root.join("removed-tvos-package")
    FileUtils.mv(package, moved)
    assert_rejected(/candidate root inventory/)
    FileUtils.mv(moved, package)

    unexpected = package.join("frame-capture-evidence/unplanned.json")
    replace_file(unexpected, "{}\n")
    assert_rejected(/package files/)
  end

  def test_receipt_identity_approval_artifact_and_digest_mutations_are_rejected
    original = receipt_path.binread
    cases = [
      [/receipt schemaVersion/, lambda { |json| json["schemaVersion"] = 1.0 }],
      [/receipt uploadApproved/, lambda { |json| json["uploadApproved"] = true }],
      [/receipt sourceCommit/, lambda { |json| json["sourceCommit"] = "0" * 40 }],
      [/receipt repository/, lambda { |json| json["repository"] = "someone/else" }],
      [/receipt workflowFile/, lambda { |json| json["workflowFile"] = "other.yml" }],
      [/workflowRun\.id/, lambda { |json| json.fetch("workflowRun")["id"] += 1 }],
      [/workflowRun\.id/, lambda { |json| json.fetch("workflowRun")["id"] = 32_347_549_322.0 }],
      [/workflowRun\.attempt/, lambda { |json| json.fetch("workflowRun")["attempt"] = 2 }],
      [/workflowRun\.createdAtUtc/, lambda do |json|
        json.fetch("workflowRun")["createdAtUtc"] = "2026-08-20T08:11:05+00:00"
      end],
      [/archivesCheckedIntoRepository/, lambda do |json|
        json.fetch("archivePreservation")["archivesCheckedIntoRepository"] = true
      end],
      [/contentManifestAlgorithm/, lambda { |json| json["contentManifestAlgorithm"] = "sha256" }],
      [/artifactId/, lambda { |json| json.fetch("artifacts").first["artifactId"] += 1 }],
      [/artifactId/, lambda { |json| json.fetch("artifacts").first["artifactId"] = 9_398_937_649.0 }],
      [/archiveDigest/, lambda do |json|
        json.fetch("artifacts").first["archiveDigest"] = "sha256:#{'0' * 64}"
      end],
      [/archiveSizeInBytes/, lambda do |json|
        json.fetch("artifacts").first["archiveSizeInBytes"] += 1
      end],
      [/archiveSizeInBytes/, lambda do |json|
        json.fetch("artifacts").first["archiveSizeInBytes"] = 4_585_918.0
      end],
      [/extractedSizeInBytes/, lambda do |json|
        json.fetch("artifacts").first["extractedSizeInBytes"] += 1
      end],
      [/contentManifestSha256/, lambda do |json|
        json.fetch("artifacts").first["contentManifestSha256"] = "0" * 64
      end],
    ]

    cases.each do |pattern, mutation|
      json = JSON.parse(original)
      mutation.call(json)
      write_json(receipt_path, json)
      assert_rejected(pattern)
    ensure
      replace_file(receipt_path, original)
    end
  end

  def test_plan_loader_and_exact_plan_sha_reject_any_manifest_byte_drift
    path = plan_path("tvos")
    source = path.binread
    replace_file(path, source + "\n")

    assert_rejected(/immutable plan SHA-256/)

    target = @root.join("immutable-plan-target.json")
    replace_file(target, source)
    path.delete
    File.symlink(target, path)
    assert_rejected(/plan manifest must be a plain file/)
  end

  def test_metadata_schema_approval_source_and_plan_mutations_are_rejected_semantically
    path = metadata_path("tvos")
    original = path.binread
    cases = [
      [/metadata schemaVersion/, lambda { |json| json["schemaVersion"] = 2 }],
      [/metadata schemaVersion/, lambda { |json| json["schemaVersion"] = 3.0 }],
      [/metadata status/, lambda { |json| json["status"] = "approved" }],
      [/metadata uploadApproved/, lambda { |json| json["uploadApproved"] = true }],
      [/metadata releaseBinaryEvidence/, lambda { |json| json["releaseBinaryEvidence"] = "signed" }],
      [/metadata reviewer/, lambda { |json| json["reviewer"] = "Reviewer" }],
      [/debugLocalOverridePresent/, lambda { |json| json["debugLocalOverridePresent"] = true }],
      [/metadata sourceCommit/, lambda { |json| json["sourceCommit"] = "1" * 40 }],
      [/metadata plan SHA-256/, lambda { |json| json.fetch("planManifest")["sha256"] = "2" * 64 }],
      [/metadata workflowRun/, lambda { |json| json["workflowRun"] = "https://example.invalid" }],
      [/metadata keys/, lambda { |json| json["approved"] = true }],
    ]

    cases.each do |pattern, mutation|
      json = JSON.parse(original)
      mutation.call(json)
      write_json(path, json)
      assert_rejected(pattern)
    ensure
      replace_file(path, original)
    end
  end

  def test_aggregate_schema_approval_plan_and_frame_mutations_are_rejected_semantically
    aggregate = aggregate_path("tvos")
    metadata = metadata_path("tvos")
    original_aggregate = aggregate.binread
    original_metadata = metadata.binread
    cases = [
      [/aggregate schemaVersion/, lambda { |json| json["schemaVersion"] = 3 }],
      [/aggregate schemaVersion/, lambda { |json| json["schemaVersion"] = 2.0 }],
      [/aggregate status/, lambda { |json| json["status"] = "approved" }],
      [/aggregate uploadApproved/, lambda { |json| json["uploadApproved"] = true }],
      [/aggregate releaseBinaryEvidence/, lambda { |json| json["releaseBinaryEvidence"] = "signed" }],
      [/aggregate reviewer/, lambda { |json| json["reviewer"] = "Reviewer" }],
      [/aggregate plan SHA-256/, lambda { |json| json.fetch("planManifest")["sha256"] = "3" * 64 }],
      [/purpose/, lambda { |json| json.fetch("frames").first["purpose"] = "Marketing composite" }],
      [/aggregate provenance keys/, lambda { |json| json["approved"] = true }],
    ]

    cases.each do |pattern, mutation|
      json = JSON.parse(original_aggregate)
      mutation.call(json)
      write_json(aggregate, json)
      rehash_aggregate_in_metadata("tvos")
      assert_rejected(pattern)
    ensure
      replace_file(aggregate, original_aggregate)
      replace_file(metadata, original_metadata)
    end
  end

  def test_metadata_to_aggregate_to_sidecar_to_png_hash_chain_rejects_each_broken_link
    aggregate = aggregate_path("tvos")
    metadata = metadata_path("tvos")
    sidecar = sidecar_path("tvos", 0)
    png = png_path("tvos", 0)
    originals = [aggregate, metadata, sidecar, png].to_h { |path| [path, path.binread] }

    replace_file(aggregate, originals.fetch(aggregate) + "\n")
    assert_rejected(/metadata-to-aggregate SHA-256/)
    restore_files(originals)

    replace_file(sidecar, originals.fetch(sidecar) + "\n")
    assert_rejected(/aggregate-to-sidecar SHA-256/)
    restore_files(originals)

    replace_file(png, originals.fetch(png) + "mutated")
    assert_rejected(/aggregate-to-PNG SHA-256/)
    restore_files(originals)

    mutate_json(metadata) do |json|
      json.fetch("frames").first["screenshotSha256"] = "0" * 64
    end
    assert_rejected(/metadata frames/)
  end

  def test_sidecar_schema_approval_and_binding_mutations_survive_outer_rehash_but_are_rejected
    sidecar = sidecar_path("tvos", 0)
    aggregate = aggregate_path("tvos")
    metadata = metadata_path("tvos")
    originals = [sidecar, aggregate, metadata].to_h { |path| [path, path.binread] }
    cases = [
      [/sidecar schemaVersion/, lambda { |json| json["schemaVersion"] = 2 }],
      [/sidecar schemaVersion/, lambda { |json| json["schemaVersion"] = 1.0 }],
      [/sidecar uploadApproved/, lambda { |json| json["uploadApproved"] = true }],
      [/sidecar plannedFile/, lambda { |json| json["plannedFile"] = "en-US/unplanned.png" }],
      [/sidecar-to-aggregate PNG SHA-256/, lambda { |json| json["screenshotSha256"] = "0" * 64 }],
      [/sidecar keys/, lambda { |json| json["reviewer"] = "Reviewer" }],
    ]

    cases.each do |pattern, mutation|
      json = JSON.parse(originals.fetch(sidecar))
      mutation.call(json)
      write_json(sidecar, json)
      rebuild_outer_hashes("tvos")
      assert_rejected(pattern)
    ensure
      restore_files(originals)
    end
  end

  def test_timestamps_and_simulator_identifiers_are_strict_and_cross_layer_bound
    aggregate = aggregate_path("watchos")
    metadata = metadata_path("watchos")
    sidecar = sidecar_path("watchos", 0)
    originals = [aggregate, metadata, sidecar].to_h { |path| [path, path.binread] }

    invalid_time = "2026-08-20T08:24:06+00:00"
    mutate_json(sidecar) { |json| json["capturedAtUtc"] = invalid_time }
    mutate_json(aggregate) { |json| json.fetch("frames").first["capturedAtUtc"] = invalid_time }
    rebuild_outer_hashes("watchos")
    assert_rejected(/whole-second UTC timestamp ending in Z/)
    restore_files(originals)

    mutate_json(sidecar) { |json| json.fetch("selectedSimulator")["udid"] = "not-a-uuid" }
    mutate_json(aggregate) do |json|
      json.fetch("frames").first.fetch("selectedSimulator")["udid"] = "not-a-uuid"
    end
    rebuild_outer_hashes("watchos")
    assert_rejected(/uppercase UUID/)
    restore_files(originals)

    float_pixels = [410.0, 502.0]
    mutate_json(sidecar) { |json| json["pixels"] = float_pixels }
    mutate_json(aggregate) { |json| json.fetch("frames").first["pixels"] = float_pixels }
    rebuild_outer_hashes("watchos")
    assert_rejected(/aggregate frames\[0\] pixels/)
    restore_files(originals)

    wrong_runtime = "com.apple.CoreSimulator.SimRuntime.watchOS-99-9"
    mutate_json(sidecar) do |json|
      json.fetch("selectedSimulator")["runtimeIdentifier"] = wrong_runtime
    end
    mutate_json(aggregate) do |json|
      json.fetch("frames").first.fetch("selectedSimulator")["runtimeIdentifier"] = wrong_runtime
    end
    rebuild_outer_hashes("watchos")
    assert_rejected(/selectedSimulator\.runtimeIdentifier/)
  end

  def test_exact_frame_inventory_and_native_png_format_dimensions_and_opacity_are_enforced
    unexpected = package_root("visionos").join("en-US/06-unplanned.png")
    copy_one(png_path("visionos", 0), unexpected)
    assert_rejected(/package files/)
    unexpected.delete

    screenshot = png_path("visionos", 0)
    cases = [
      [/format/, { format: "jpeg" }],
      [/dimensions/, { width: 3839 }],
      [/opacity/, { has_alpha: true }],
    ]
    cases.each do |pattern, mutation|
      @inspector.mutations[screenshot.to_s] = mutation
      assert_rejected(pattern)
      @inspector.mutations.clear
    end
  end

  def test_extracted_size_and_content_manifest_bind_every_package_byte
    runtime_inventory = package_root("tvos").join("simulator-runtimes.txt")
    original = runtime_inventory.binread
    same_size_mutation = original.sub("iOS 26.2", "iOS 26.3")
    refute_equal original, same_size_mutation
    assert_equal original.bytesize, same_size_mutation.bytesize
    replace_file(runtime_inventory, same_size_mutation)

    assert_rejected(/package content-manifest SHA-256/)
  end

  def test_source_guard_rejects_tracked_workspace_untracked_and_ignored_product_drift
    repository = @root.join("source-guard-repository")
    repository.mkpath
    run_git(repository, "init", "-q")
    product = repository.join("ios/QuakeSignalTV/App.swift")
    product.dirname.mkpath
    product.write("struct CapturedApp {}\n")
    workspace = repository.join(
      "ios/QuakeSignal.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
    )
    workspace.dirname.mkpath
    workspace_source = %Q[<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"/>\n]
    workspace.write(workspace_source)
    repository.join(".gitignore").write("/ios/QuakeSignalTV/IgnoredView.swift\n")
    run_git(repository, "add", ".gitignore", "ios")
    run_git(repository, "-c", "user.name=Validator Test", "-c", "user.email=test@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-q", "-m", "captured source")
    baseline = run_git(repository, "rev-parse", "HEAD").strip

    repository.join("notes.txt").write("unrelated\n")
    run_git(repository, "add", "notes.txt")
    run_git(repository, "-c", "user.name=Validator Test", "-c", "user.email=test@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-q", "-m", "unrelated change")
    guard = NativeAppleScreenshotSourceGuard.new(repository)
    guard.validate!(baseline)

    product.write("struct ChangedApp {}\n")
    error = assert_raises(NativeAppleScreenshotCandidateValidationError) do
      guard.validate!(baseline)
    end
    assert_match(/UI or product source changed/, error.message)

    product.write("struct CapturedApp {}\n")
    workspace.write(workspace_source.sub("1.0", "2.0"))
    error = assert_raises(NativeAppleScreenshotCandidateValidationError) do
      guard.validate!(baseline)
    end
    assert_match(/UI or product source changed/, error.message)

    workspace.write(workspace_source)
    untracked = repository.join("ios/QuakeSignalWatch/NewView.swift")
    untracked.dirname.mkpath
    untracked.write("struct NewView {}\n")
    error = assert_raises(NativeAppleScreenshotCandidateValidationError) do
      guard.validate!(baseline)
    end
    assert_match(/untracked native Apple app source/, error.message)

    untracked.delete
    ignored = repository.join("ios/QuakeSignalTV/IgnoredView.swift")
    ignored.write("struct IgnoredView {}\n")
    assert_equal "!! ios/QuakeSignalTV/IgnoredView.swift\n", run_git(
      repository, "status", "--short", "--ignored", "--", "ios/QuakeSignalTV/IgnoredView.swift"
    )
    error = assert_raises(NativeAppleScreenshotCandidateValidationError) do
      guard.validate!(baseline)
    end
    assert_match(/including ignored paths/, error.message)
    assert_match(/ios\/QuakeSignalTV\/IgnoredView\.swift/, error.message)
  end

  private

  def validator
    NativeAppleScreenshotCandidateValidator.new(
      root: @root,
      image_inspector: @inspector,
      verify_git: false,
    )
  end

  def assert_rejected(pattern)
    error = assert_raises(NativeAppleScreenshotCandidateValidationError) do
      validator.validate!
    end
    assert_match(pattern, error.message)
    error
  end

  def copy_candidate_fixture
    source_candidates = SOURCE_ROOT.join(NativeAppleScreenshotCandidateValidator::CANDIDATE_ROOT)
    destination_candidates = @root.join(NativeAppleScreenshotCandidateValidator::CANDIDATE_ROOT)
    clone_tree(source_candidates, destination_candidates)
    NativeAppleScreenshotCandidateValidator::PLATFORMS.each do |platform|
      relative = QuakeSignalPlatformScreenshotPlan::EXPECTED.fetch(platform).fetch(:manifest)
      copy_one(SOURCE_ROOT.join(relative), @root.join(relative))
    end
  end

  def clone_tree(source, destination)
    stat = source.lstat
    if stat.directory?
      destination.mkpath
      source.children.each { |child| clone_tree(child, destination.join(child.basename)) }
    elsif stat.file?
      copy_one(source, destination)
    else
      raise "fixture contains a non-regular entry: #{source}"
    end
  end

  def copy_one(source, destination)
    destination.dirname.mkpath
    destination.delete if destination.exist? || destination.symlink?
    File.link(source, destination)
  rescue Errno::EXDEV, Errno::EPERM, Errno::EACCES, Errno::EMLINK
    FileUtils.copy_file(source, destination)
  end

  def replace_file(path, content)
    path = Pathname.new(path)
    path.dirname.mkpath
    temporary = path.dirname.join(".#{path.basename}.mutation-#{Process.pid}-#{rand(1_000_000)}")
    File.open(temporary, "wb") { |file| file.write(content) }
    File.rename(temporary, path)
  ensure
    FileUtils.rm_f(temporary) if temporary
  end

  def write_json(path, value)
    replace_file(path, JSON.pretty_generate(value) + "\n")
  end

  def mutate_json(path)
    value = JSON.parse(path.binread)
    yield value
    write_json(path, value)
  end

  def restore_files(files)
    files.each { |path, content| replace_file(path, content) }
  end

  def candidate_root
    @root.join(NativeAppleScreenshotCandidateValidator::CANDIDATE_ROOT)
  end

  def package_root(platform)
    candidate_root.join(
      NativeAppleScreenshotCandidateValidator::ARTIFACTS.fetch(platform).fetch("directory"),
    )
  end

  def receipt_path
    candidate_root.join(NativeAppleScreenshotCandidateValidator::RECEIPT_NAME)
  end

  def metadata_path(platform)
    package_root(platform).join("candidate-metadata.json")
  end

  def aggregate_path(platform)
    package_root(platform).join("capture-provenance.json")
  end

  def aggregate(platform)
    JSON.parse(aggregate_path(platform).binread)
  end

  def sidecar_path(platform, index)
    package_root(platform).join(aggregate(platform).fetch("frames").fetch(index).fetch("captureEvidenceFile"))
  end

  def png_path(platform, index)
    package_root(platform).join(aggregate(platform).fetch("frames").fetch(index).fetch("file"))
  end

  def plan_path(platform)
    @root.join(QuakeSignalPlatformScreenshotPlan::EXPECTED.fetch(platform).fetch(:manifest))
  end

  def rehash_aggregate_in_metadata(platform)
    mutate_json(metadata_path(platform)) do |metadata|
      metadata["captureEvidenceSha256"] = Digest::SHA256.file(aggregate_path(platform)).hexdigest
    end
  end

  def rebuild_outer_hashes(platform)
    aggregate_json = JSON.parse(aggregate_path(platform).binread)
    aggregate_json.fetch("frames").each do |frame|
      frame["captureEvidenceSha256"] =
        Digest::SHA256.file(package_root(platform).join(frame.fetch("captureEvidenceFile"))).hexdigest
      frame["sha256"] = Digest::SHA256.file(package_root(platform).join(frame.fetch("file"))).hexdigest
    end
    write_json(aggregate_path(platform), aggregate_json)

    mutate_json(metadata_path(platform)) do |metadata|
      metadata["captureEvidenceSha256"] = Digest::SHA256.file(aggregate_path(platform)).hexdigest
      metadata["frames"] = aggregate_json.fetch("frames").map do |frame|
        {
          "captureSelector" => frame.fetch("captureSelector"),
          "file" => frame.fetch("file"),
          "screen" => frame.fetch("screen"),
          "screenshotSha256" => frame.fetch("sha256"),
          "pixels" => frame.fetch("pixels"),
          "capturedAtUtc" => frame.fetch("capturedAtUtc"),
          "selectedSimulator" => frame.fetch("selectedSimulator"),
          "captureEvidenceFile" => frame.fetch("captureEvidenceFile"),
          "captureEvidenceSha256" => frame.fetch("captureEvidenceSha256"),
        }
      end
    end
  end

  def run_git(repository, *arguments)
    output, error_output, status = Open3.capture3("git", "-C", repository.to_s, *arguments)
    assert status.success?, "git #{arguments.join(' ')} failed:\n#{output}\n#{error_output}"
    output
  end
end
