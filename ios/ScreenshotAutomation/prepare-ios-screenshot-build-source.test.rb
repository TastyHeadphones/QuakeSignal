#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"
require_relative "prepare-ios-screenshot-build-source"
require_relative "screenshot-test-temp-root"

class PrepareIOSScreenshotBuildSourceTest < Minitest::Test
  SOURCE_ROOT = Pathname.new(__dir__).join("../..").realpath

  def setup
    @temporary_directory = Dir.mktmpdir(
      "quakesignal-ios-build-source-test",
      QuakeSignalScreenshotTestTempRoot.path.to_s,
    )
    @temporary_root = Pathname.new(@temporary_directory)
    @repository = @temporary_root.join("repository")
    @repository.mkpath
    fixture_archive = @temporary_root.join("tracked-ios-inputs.tar")
    run!(
      "git", "-C", SOURCE_ROOT.to_s, "archive", "--format=tar", "-o", fixture_archive.to_s,
      "HEAD", *QuakeSignalIOSScreenshotBuildSource::COPIED_INPUTS,
    )
    run!("tar", "-xf", fixture_archive.to_s, "-C", @repository.to_s)
    fixture_archive.delete
    refute @repository.join(
      "ios/QuakeSignal.xcodeproj/project.xcworkspace/xcuserdata",
    ).exist?, "the fixture must contain only source-addressed tracked inputs"
    run!("git", "init", "-q", @repository.to_s)
    run!("git", "-C", @repository.to_s, "add", "ios")
    run!(
      "git", "-C", @repository.to_s,
      "-c", "user.name=QuakeSignal Test", "-c", "user.email=test@invalid.example",
      "commit", "-qm", "fixture",
    )
    @commit = run!("git", "-C", @repository.to_s, "rev-parse", "HEAD").strip
    @output = @temporary_root.join("output/ios")
    @evidence = @temporary_root.join("evidence/build-source.json")
    @output.dirname.mkpath
    @evidence.dirname.mkpath
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory) if @temporary_directory && File.exist?(@temporary_directory)
  end

  def test_copies_identical_main_inputs_and_removes_only_two_watch_references
    record = prepare
    assert @output.join("QuakeSignal.xcodeproj/project.pbxproj").file?
    assert @evidence.file?
    assert_equal false, record.fetch("uploadApproved")
    assert_nil record.fetch("reviewer")
    assert record.fetch("copyVerification").fetch("allNonProjectBytesIdentical")
    transformation = record.fetch("projectTransformation")
    assert_equal 2, transformation.fetch("removedReferences").length
    assert_equal 0, transformation.fetch("removedDefinitionCount")
    assert transformation.fetch("watchTargetDefinitionRetained")
    refute_equal transformation.fetch("originalSha256"), transformation.fetch("temporarySha256")
    assert_equal Digest::SHA256.file(
      @repository.join("ios/QuakeSignal/App/QuakeSignalApp.swift"),
    ).hexdigest, Digest::SHA256.file(@output.join("QuakeSignal/App/QuakeSignalApp.swift")).hexdigest

    project = @output.join("QuakeSignal.xcodeproj/project.pbxproj").read
    main_target = project.scan(
      /^\t\t[0-9A-F]{24} \/\* QuakeSignal \*\/ = \{\n\t\t\tisa = PBXNativeTarget;.*?^\t\t\};$/m,
    ).fetch(0)
    refute_includes main_target, "Embed Watch Content"
    refute_includes main_target, "PBXTargetDependency"
    assert_includes project, "name = QuakeSignalWatch;"
    assert_includes project, "name = \"Embed Watch Content\";"

    manifest = record.fetch("materializedBuildSource")
    assert_equal manifest, QuakeSignalIOSScreenshotBuildSource.materialized_source_manifest(@output)
    project_entries = manifest.fetch("entries").count do |entry|
      entry.fetch("kind") == "file" &&
        entry.fetch("path") == QuakeSignalIOSScreenshotBuildSource::PROJECT_RELATIVE
    end
    assert_equal 1, project_entries
    assert_equal manifest.fetch("fileCount") + manifest.fetch("directoryCount"), manifest.fetch("entryCount")
    expected_workspace_entries = QuakeSignalIOSScreenshotBuildSource::XCODE_SWIFTPM_WORKSPACE_DIRECTORIES.map do |path|
      {
        "kind" => "directory",
        "path" => path,
        "mode" => QuakeSignalIOSScreenshotBuildSource::XCODE_SWIFTPM_WORKSPACE_DIRECTORY_MODE,
      }
    end
    assert_equal expected_workspace_entries, manifest.fetch("entries").select { |entry|
      entry.fetch("path").start_with?(
        QuakeSignalIOSScreenshotBuildSource::XCODE_SWIFTPM_WORKSPACE_DIRECTORIES.first,
      )
    }
  end

  def test_exact_swiftpm_workspace_directory_chain_remains_fail_closed
    prepare
    workspace = @output.join("QuakeSignal.xcodeproj/project.xcworkspace/xcshareddata")
    swiftpm = workspace.join("swiftpm")
    configuration = swiftpm.join("configuration")

    configuration.join("injected.json").write("{}\n")
    assert_materialized_error(/inventory/)
    configuration.join("injected.json").delete

    workspace.join("unexpected").mkdir
    assert_materialized_error(/inventory/)
    workspace.join("unexpected").rmdir

    configuration.chmod(0o777)
    assert_materialized_error(/inventory/)
    configuration.chmod(0o755)

    configuration.rmdir
    assert_materialized_error(/inventory/)
    configuration.mkdir(0o755)

    configuration.rmdir
    configuration.make_symlink(@output.join("QuakeSignal"))
    assert_materialized_error(/symlink or special/)
    configuration.delete
    configuration.mkdir(0o755)

    assert_equal JSON.parse(@evidence.read).fetch("materializedBuildSource"),
                 QuakeSignalIOSScreenshotBuildSource.materialized_source_manifest(@output)
  end

  def test_rejects_preexisting_swiftpm_workspace_content_in_archived_inputs
    injected = @repository.join(
      "ios/QuakeSignal.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/injected.json",
    )
    injected.dirname.mkpath
    injected.write("{}\n")
    run!("git", "-C", @repository.to_s, "add", injected.relative_path_from(@repository).to_s)
    run!(
      "git", "-C", @repository.to_s,
      "-c", "user.name=QuakeSignal Test", "-c", "user.email=test@invalid.example",
      "commit", "-qm", "inject workspace content",
    )
    @commit = run!("git", "-C", @repository.to_s, "rev-parse", "HEAD").strip

    assert_error(/SwiftPM workspace path must be absent/) { prepare }
    refute @output.exist?
    refute @evidence.exist?
  end

  def test_rejects_ignored_xcuserdata_as_an_unarchived_working_input
    relative = "ios/QuakeSignal.xcodeproj/project.xcworkspace/xcuserdata/operator.xcuserdatad/UserInterfaceState.xcuserstate"
    @repository.join(".git/info/exclude").write("#{relative}\n")
    ignored_state = @repository.join(relative)
    ignored_state.dirname.mkpath
    ignored_state.binwrite("ignored host UI state")
    assert_empty run!(
      "git", "-C", @repository.to_s, "status", "--porcelain=v1", "--untracked-files=all",
    )

    assert_error(/temporary main-product input inventory/) { prepare }
    refute @output.exist?
    refute @evidence.exist?
  end

  def test_writes_a_prebuild_snapshot_and_revalidates_the_live_materialized_tree
    record = prepare
    snapshot = @temporary_root.join("evidence/pre-build-source.json")
    snapshot_record = QuakeSignalIOSScreenshotBuildSource.write_materialized_snapshot(
      output: snapshot,
      build_ios_root: @output,
      prepared_source_evidence: @evidence,
      source_commit: @commit,
      phase: "pre-build",
      captured_at: "2026-08-21T00:00:00.000001Z",
    )
    assert_equal "pre-build", snapshot_record.fetch("phase")
    assert_equal "2026-08-21T00:00:00.000001Z", snapshot_record.fetch("capturedAt")
    assert snapshot_record.fetch("matchesPreparedSourceEvidence")
    assert_equal record.fetch("materializedBuildSource"), snapshot_record.fetch("materializedBuildSource")
    verified, sha256 = QuakeSignalIOSScreenshotBuildSource.verify_materialized_snapshot(
      snapshot: snapshot,
      build_ios_root: @output,
      prepared_source_evidence: @evidence,
      source_commit: @commit,
      phase: "pre-build",
    )
    assert_equal snapshot_record, verified
    assert_equal Digest::SHA256.file(snapshot).hexdigest, sha256
  end

  def test_rejects_project_resource_script_mode_and_symlink_mutations
    prepare
    project = @output.join("QuakeSignal.xcodeproj/project.pbxproj")
    project_source = project.binread
    project.binwrite(project_source + "\n")
    assert_materialized_error(/transformed Xcode project hash/)
    project.binwrite(project_source)

    resource = @output.join("QuakeSignal/Assets.xcassets/Contents.json")
    resource_source = resource.binread
    resource.binwrite(resource_source + "\n")
    assert_materialized_error(/inventory/)
    resource.binwrite(resource_source)

    injected_script = @output.join("QuakeSignal/injected-build-script.sh")
    injected_script.write("#!/bin/sh\nexit 0\n")
    assert_materialized_error(/inventory/)
    injected_script.delete

    injected_directory = @output.join("QuakeSignal/EmptyInjectedResources")
    injected_directory.mkpath
    assert_materialized_error(/inventory/)
    injected_directory.rmdir

    authored_source = @output.join("QuakeSignal/App/QuakeSignalApp.swift")
    original_mode = authored_source.stat.mode & 0o7777
    authored_source.chmod(0o755)
    assert_materialized_error(/inventory/)
    authored_source.chmod(original_mode)

    injected_link = @output.join("QuakeSignal/injected-link")
    injected_link.make_symlink(authored_source)
    assert_materialized_error(/symlink or special/)
    injected_link.delete

    assert_equal JSON.parse(@evidence.read).fetch("materializedBuildSource"),
                 QuakeSignalIOSScreenshotBuildSource.materialized_source_manifest(@output)
  end

  def test_rejects_duplicate_keys_in_retained_source_and_snapshot_evidence
    prepare
    original_source = @evidence.read
    duplicated_source = original_source.sub(
      %Q[  "schemaVersion": 1,\n],
      %Q[  "schemaVersion": 1,\n  "schemaVersion": 1,\n],
    )
    @evidence.binwrite(duplicated_source)
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.read_prepared_evidence(
        @evidence,
        source_commit: @commit,
      )
    end
    assert_match(/duplicate build-source JSON key/, error.message)

    @evidence.binwrite(original_source)
    snapshot = @temporary_root.join("evidence/pre-build-source.json")
    QuakeSignalIOSScreenshotBuildSource.write_materialized_snapshot(
      output: snapshot,
      build_ios_root: @output,
      prepared_source_evidence: @evidence,
      source_commit: @commit,
      phase: "pre-build",
    )
    duplicated_snapshot = snapshot.read.sub(
      %Q[  "phase": "pre-build",\n],
      %Q[  "phase": "pre-build",\n  "phase": "pre-build",\n],
    )
    snapshot.binwrite(duplicated_snapshot)
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.verify_materialized_snapshot(
        snapshot: snapshot,
        prepared_source_evidence: @evidence,
        source_commit: @commit,
        phase: "pre-build",
      )
    end
    assert_match(/duplicate build-source JSON key/, error.message)
  end

  def test_snapshot_rejects_mutation_after_prebuild_checkpoint
    prepare
    snapshot = @temporary_root.join("evidence/pre-build-source.json")
    QuakeSignalIOSScreenshotBuildSource.write_materialized_snapshot(
      output: snapshot,
      build_ios_root: @output,
      prepared_source_evidence: @evidence,
      source_commit: @commit,
      phase: "pre-build",
    )
    @output.join("QuakeSignalShared/Injected.swift").write("fatalError()\n")
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.verify_materialized_snapshot(
        snapshot: snapshot,
        build_ios_root: @output,
        prepared_source_evidence: @evidence,
        source_commit: @commit,
        phase: "pre-build",
      )
    end
    assert_match(/pre-build materialized source snapshot\/live tree/, error.message)
  end

  def test_retains_a_differing_postbuild_snapshot_after_mutation_and_source_restore
    prepare
    postbuild = @temporary_root.join("evidence/post-build-source.json")
    source = @output.join("QuakeSignalShared/ScreenshotAutomation.swift")
    original = source.binread
    source.binwrite(original + "\n// injected during build\n")
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.write_materialized_snapshot(
        output: postbuild,
        build_ios_root: @output,
        prepared_source_evidence: @evidence,
        source_commit: @commit,
        phase: "post-build",
        captured_at: "2026-08-21T00:01:00.000001Z",
      )
    end
    assert_match(/post-build materialized source snapshot retained a tree that differs/, error.message)
    assert postbuild.file?, "the mismatching post-build evidence must survive the failed checkpoint"
    retained = JSON.parse(postbuild.read)
    assert_equal "post-build", retained.fetch("phase")
    assert_equal "2026-08-21T00:01:00.000001Z", retained.fetch("capturedAt")
    assert_equal false, retained.fetch("matchesPreparedSourceEvidence")
    refute_equal JSON.parse(@evidence.read).fetch("materializedBuildSource"),
                 retained.fetch("materializedBuildSource")

    source.binwrite(original)
    QuakeSignalIOSScreenshotBuildSource.verify_materialized_source(
      build_ios_root: @output,
      prepared_source_record: JSON.parse(@evidence.read),
      source_commit: @commit,
    )
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.verify_materialized_snapshot(
        snapshot: postbuild,
        prepared_source_evidence: @evidence,
        source_commit: @commit,
        phase: "post-build",
      )
    end
    assert_match(/post-build materialized source snapshot does not match prepared evidence/, error.message)
    verified, = QuakeSignalIOSScreenshotBuildSource.verify_materialized_snapshot(
      snapshot: postbuild,
      prepared_source_evidence: @evidence,
      source_commit: @commit,
      phase: "post-build",
      require_match: false,
    )
    assert_equal retained, verified
  end

  def test_rejects_noncanonical_snapshot_phase_and_timestamp
    prepare
    snapshot = @temporary_root.join("evidence/pre-build-source.json")
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.write_materialized_snapshot(
        output: snapshot,
        build_ios_root: @output,
        prepared_source_evidence: @evidence,
        source_commit: @commit,
        phase: "before",
      )
    end
    assert_match(/phase must be exactly pre-build or post-build/, error.message)

    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.write_materialized_snapshot(
        output: snapshot,
        build_ios_root: @output,
        prepared_source_evidence: @evidence,
        source_commit: @commit,
        phase: "pre-build",
        captured_at: "2026-08-21T00:00:00Z",
      )
    end
    assert_match(/canonical microsecond UTC timestamp/, error.message)
    refute snapshot.exist?
  end

  def test_rejects_dirty_source_existing_output_or_ambiguous_transform
    @repository.join("ios/QuakeSignalShared/dirty.txt").write("dirty\n")
    assert_error(/clean source tree/) { prepare }

    @repository.join("ios/QuakeSignalShared/dirty.txt").delete
    @output.mkpath
    assert_error(/already exists/) { prepare }

    FileUtils.remove_entry(@output)
    project = @repository.join(QuakeSignalIOSScreenshotBuildSource::PROJECT_RELATIVE)
    source = project.read.sub(
      "\t\t\t\t6431C9662A0D7FB6B3066140 /* Embed Watch Content */,\n",
      "\t\t\t\t6431C9662A0D7FB6B3066140 /* Embed Watch Content */,\n" * 2,
    )
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.remove_watch_embedding_references(source)
    end
    assert_match(/exactly one Watch embed phase/, error.message)
  end

  def test_rejects_symlinked_or_noncanonical_output_parents_before_writing
    linked_parent = @temporary_root.join("linked-parent")
    linked_parent.make_symlink(@repository.join("ios"))
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.prepare(
        repository_root: @repository,
        source_commit: @commit,
        output_ios_root: linked_parent.join("temporary/ios"),
        evidence_output: @evidence,
      )
    end
    assert_match(/plain directories|canonical|outside the repository/, error.message)
    refute @repository.join("ios/temporary").exist?

    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.prepare(
        repository_root: @repository,
        source_commit: @commit,
        output_ios_root: "#{@temporary_root}/output/../other/ios",
        evidence_output: @evidence,
      )
    end
    assert_match(/absolute paths/, error.message)
  end

  def test_rechecks_evidence_parent_immediately_before_exclusive_write
    repository_destination = @repository.join("unexpected-build-source.json")
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.prepare(
        repository_root: @repository,
        source_commit: @commit,
        output_ios_root: @output,
        evidence_output: @evidence,
        before_evidence_write: lambda do
          @evidence.dirname.rmdir
          @evidence.dirname.make_symlink(@repository)
        end,
      )
    end
    assert_match(/parent must be an existing canonical plain directory|outside the repository/, error.message)
    refute repository_destination.exist?
    refute @output.exist?, "failed evidence publication must roll back the temporary source"
  end

  private

  def prepare
    QuakeSignalIOSScreenshotBuildSource.prepare(
      repository_root: @repository,
      source_commit: @commit,
      output_ios_root: @output,
      evidence_output: @evidence,
    )
  end

  def assert_error(pattern)
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) { yield }
    assert_match pattern, error.message
  end

  def assert_materialized_error(pattern)
    record = JSON.parse(@evidence.read)
    error = assert_raises(QuakeSignalIOSScreenshotBuildSource::Error) do
      QuakeSignalIOSScreenshotBuildSource.verify_materialized_source(
        build_ios_root: @output,
        prepared_source_record: record,
        source_commit: @commit,
      )
    end
    assert_match pattern, error.message
  end

  def run!(*command)
    output, error, status = Open3.capture3(*command)
    raise "command failed: #{command.inspect}: #{error}" unless status.success?

    output
  end
end
