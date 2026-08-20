#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "time"
require "tmpdir"

module QuakeSignalIOSScreenshotBuildSource
  class Error < StandardError; end

  COPIED_INPUTS = %w[
    ios/QuakeSignal
    ios/QuakeSignalShared
    ios/QuakeSignal.xcodeproj
  ].freeze
  PROJECT_RELATIVE = "ios/QuakeSignal.xcodeproj/project.pbxproj"
  ALGORITHM = "sha256 of sorted UTF-8 records: <file-sha256><two spaces><repository-relative-path><newline>"
  MATERIALIZED_TREE_ALGORITHM = "sha256 of sorted UTF-8 records: <kind><two spaces><mode><two spaces><sha256-or-dash><two spaces><bytes-or-dash><two spaces><ios-relative-path><newline>"
  MATERIALIZED_TOP_LEVEL_DIRECTORIES = %w[
    ios/QuakeSignal
    ios/QuakeSignal.xcodeproj
    ios/QuakeSignalShared
  ].freeze
  XCODE_SWIFTPM_WORKSPACE_DIRECTORIES = %w[
    ios/QuakeSignal.xcodeproj/project.xcworkspace/xcshareddata
    ios/QuakeSignal.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
    ios/QuakeSignal.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration
  ].freeze
  XCODE_SWIFTPM_WORKSPACE_DIRECTORY_MODE = "0755"
  MATERIALIZED_SNAPSHOT_PHASES = %w[pre-build post-build].freeze
  MATERIALIZED_SNAPSHOT_TIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%6NZ"
  EXPECTED_REMOVED_REFERENCES = [
    {
      "kind" => "main-target-build-phase-reference",
      "identifier" => "6431C9662A0D7FB6B3066140",
      "label" => "Embed Watch Content",
      "removedLine" => "6431C9662A0D7FB6B3066140 /* Embed Watch Content */,",
    },
    {
      "kind" => "main-target-dependency-reference",
      "identifier" => "772A7BAD5E925617A13DB93C",
      "label" => "QuakeSignalWatch",
      "removedLine" => "772A7BAD5E925617A13DB93C /* PBXTargetDependency */,",
    },
  ].freeze

  class DuplicateRejectingHash < Hash
    def []=(key, value)
      raise Error, "duplicate build-source JSON key #{key.inspect}" if key?(key)

      super
    end
  end

  module_function

  def prepare(repository_root:, source_commit:, output_ios_root:, evidence_output:, before_evidence_write: nil)
    root = Pathname.new(repository_root).expand_path
    raise Error, "repository root must not be a symlink" if root.symlink?

    root = root.realpath
    require_commit(source_commit)
    require_clean_commit(root, source_commit)
    requested_output = Pathname.new(output_ios_root)
    requested_evidence = Pathname.new(evidence_output)
    unless requested_output.absolute? && requested_evidence.absolute? &&
           requested_output.cleanpath == requested_output && requested_evidence.cleanpath == requested_evidence
      raise Error, "temporary build-source outputs must be absolute paths"
    end
    output = requested_output.expand_path
    evidence = requested_evidence.expand_path
    require_external_new_path(root, output, "temporary iOS source output")
    require_external_new_path(root, evidence, "build-source evidence output")
    unless output.basename.to_s == "ios"
      raise Error, "temporary iOS source output must end in /ios"
    end

    stage_parent = output.dirname
    stage = Pathname.new(Dir.mktmpdir(".quakesignal-ios-build-source.", stage_parent.to_s))
    staged_ios = stage.join("ios")
    begin
      extract_commit_inputs(root, source_commit, stage)

      original_project = root.join(PROJECT_RELATIVE)
      transformed_project = staged_ios.join("QuakeSignal.xcodeproj/project.pbxproj")
      archived_project_source = transformed_project.binread
      committed_project_source, show_error, show_status = Open3.capture3(
        "git", "-C", root.to_s, "show", "#{source_commit}:#{PROJECT_RELATIVE}", binmode: true,
      )
      unless show_status.success?
        raise Error, "could not read committed Xcode project: #{show_error.strip}"
      end
      require_equal(archived_project_source, committed_project_source, "git-archive project bytes")
      require_equal(original_project.binread, committed_project_source, "working/committed project bytes")
      original_source = committed_project_source
      transformed_source, removed = remove_watch_embedding_references(original_source)
      transformed_project.binwrite(transformed_source)

      source_files = plain_input_files(root)
      copied_files = plain_input_files(stage)
      copied_project = transformed_project
      source_nonproject = source_files.reject { |file| file == original_project }
      copied_nonproject = copied_files.reject { |file| file == copied_project }
      require_equal(
        source_nonproject.map { |file| file.relative_path_from(root).to_s },
        copied_nonproject.map { |file| "ios/#{file.relative_path_from(staged_ios)}" },
        "temporary main-product input inventory",
      )
      source_nonproject.zip(copied_nonproject).each do |source, copy|
        require_equal(Digest::SHA256.file(copy).hexdigest, Digest::SHA256.file(source).hexdigest,
                      "temporary input bytes for #{source.relative_path_from(root)}")
      end

      source_manifest = content_manifest(source_nonproject, root)
      copied_manifest = content_manifest(copied_nonproject, stage)
      require_equal(copied_manifest.fetch("contentManifestSha256"), source_manifest.fetch("contentManifestSha256"),
                    "temporary main-product content manifest")
      prepare_xcode_swiftpm_workspace_directories(staged_ios)
      materialized_manifest = materialized_source_manifest(staged_ios)

      record = {
        "schemaVersion" => 1,
        "status" => "unapproved-debug-temporary-no-watch-build-source-evidence",
        "uploadApproved" => false,
        "reviewer" => nil,
        "sourceCommit" => source_commit,
        "purpose" => "credential-free iOS Simulator screenshot build on a host where the Watch platform component cannot resolve",
        "sourceMaterialization" => {
          "method" => "git-archive",
          "sourceCommit" => source_commit,
          "paths" => COPIED_INPUTS,
          "archiveProjectMatchesGitShow" => true,
          "workingTreeMatchesArchive" => true,
        },
        "mainProductInputs" => source_manifest,
        "copyVerification" => {
          "allNonProjectBytesIdentical" => true,
          "copiedContentManifestSha256" => copied_manifest.fetch("contentManifestSha256"),
        },
        "projectTransformation" => {
          "originalFile" => PROJECT_RELATIVE,
          "temporaryFile" => "ios/QuakeSignal.xcodeproj/project.pbxproj",
          "originalSha256" => Digest::SHA256.hexdigest(original_source),
          "temporarySha256" => Digest::SHA256.hexdigest(transformed_source),
          "removedReferences" => removed,
          "removedDefinitionCount" => 0,
          "watchTargetDefinitionRetained" => transformed_source.include?("/* QuakeSignalWatch */ = {") &&
            transformed_source.include?("name = QuakeSignalWatch;"),
          "mainTargetSourceAndResourcePhasesUnchanged" => true,
        },
        "materializedBuildSource" => materialized_manifest,
      }
      unless record.fetch("projectTransformation").fetch("watchTargetDefinitionRetained")
        raise Error, "temporary project transformation removed the Watch target definition"
      end

      ensure_unchanged_source(root, source_commit)
      require_external_new_path(root, output, "temporary iOS source output")
      File.rename(staged_ios, output)
      before_evidence_write&.call
      verify_materialized_source(
        build_ios_root: output,
        prepared_source_record: record,
        source_commit: source_commit,
      )
      require_external_new_path(root, evidence, "build-source evidence output")
      evidence.write(JSON.pretty_generate(record) + "\n", mode: "wx")
      record
    rescue StandardError
      FileUtils.remove_entry_secure(output.to_s) if output.directory? && !output.symlink?
      evidence.delete if evidence.file? && !evidence.symlink?
      raise
    ensure
      FileUtils.remove_entry_secure(stage.to_s) if stage.exist?
    end
  rescue Errno::ENOENT, Errno::EEXIST, IOError, SystemCallError => error
    raise Error, "could not prepare temporary iOS screenshot build source: #{error.message}"
  end

  def write_materialized_snapshot(
    output:, build_ios_root:, prepared_source_evidence:, source_commit:, phase:,
    captured_at: Time.now.utc.strftime(MATERIALIZED_SNAPSHOT_TIME_FORMAT)
  )
    require_commit(source_commit)
    require_snapshot_phase(phase)
    captured_at = require_snapshot_time(captured_at, "#{phase} materialized source snapshot")

    _evidence_path, evidence_source, prepared_record = read_prepared_evidence(
      prepared_source_evidence,
      source_commit: source_commit,
    )
    manifest = materialized_source_manifest(build_ios_root)
    expected_manifest = prepared_record.fetch("materializedBuildSource")
    expected_project_sha = prepared_record.fetch("projectTransformation").fetch("temporarySha256")
    observed_project = manifest.fetch("entries").find do |entry|
      entry.fetch("kind") == "file" && entry.fetch("path") == PROJECT_RELATIVE
    end
    observed_project_sha = observed_project&.fetch("sha256")
    matches_prepared = manifest == expected_manifest && observed_project_sha == expected_project_sha
    record = {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-materialized-ios-build-source-snapshot",
      "uploadApproved" => false,
      "reviewer" => nil,
      "phase" => phase,
      "capturedAt" => captured_at,
      "sourceCommit" => source_commit,
      "preparedSourceEvidenceSha256" => Digest::SHA256.hexdigest(evidence_source),
      "preparedTransformedProjectSha256" => expected_project_sha,
      "observedTransformedProjectSha256" => observed_project_sha,
      "materializedBuildSource" => manifest,
      "matchesPreparedSourceEvidence" => matches_prepared,
    }
    path = canonical_new_file(output, "materialized source snapshot")
    path.write(JSON.pretty_generate(record) + "\n", mode: "wx")
    unless matches_prepared
      raise Error, "#{phase} materialized source snapshot retained a tree that differs from prepared evidence"
    end
    record
  rescue Errno::EEXIST, IOError, SystemCallError => error
    raise Error, "could not write materialized source snapshot: #{error.message}"
  end

  def verify_materialized_snapshot(
    snapshot:, prepared_source_evidence:, source_commit:, phase:, build_ios_root: nil,
    require_match: true
  )
    require_commit(source_commit)
    require_snapshot_phase(phase)

    _evidence_path, evidence_source, prepared_record = read_prepared_evidence(
      prepared_source_evidence,
      source_commit: source_commit,
    )
    snapshot_path = canonical_plain_file(snapshot, "materialized source snapshot")
    snapshot_source = stable_file_read(snapshot_path, "materialized source snapshot")
    record = parse_json_object(snapshot_source, "materialized source snapshot")
    require_exact_keys(
      record,
      %w[
        schemaVersion status uploadApproved reviewer phase capturedAt sourceCommit preparedSourceEvidenceSha256
        preparedTransformedProjectSha256 observedTransformedProjectSha256 materializedBuildSource
        matchesPreparedSourceEvidence
      ],
      "materialized source snapshot",
    )
    require_snapshot_time(record.fetch("capturedAt"), "#{phase} materialized source snapshot")
    expected_manifest = prepared_record.fetch("materializedBuildSource")
    expected_project_sha = prepared_record.fetch("projectTransformation").fetch("temporarySha256")
    manifest = validate_materialized_manifest(record.fetch("materializedBuildSource"))
    observed_project = manifest.fetch("entries").find do |entry|
      entry.fetch("kind") == "file" && entry.fetch("path") == PROJECT_RELATIVE
    end
    observed_project_sha = observed_project&.fetch("sha256")
    derived_match = manifest == expected_manifest && observed_project_sha == expected_project_sha
    unless record.fetch("schemaVersion") == 1 &&
           record.fetch("status") == "unapproved-debug-materialized-ios-build-source-snapshot" &&
           record.fetch("uploadApproved") == false && record.fetch("reviewer").nil? &&
           record.fetch("phase") == phase && record.fetch("sourceCommit") == source_commit &&
           record.fetch("preparedSourceEvidenceSha256") == Digest::SHA256.hexdigest(evidence_source) &&
           record.fetch("preparedTransformedProjectSha256") == expected_project_sha &&
           record.fetch("observedTransformedProjectSha256") == observed_project_sha &&
           record.fetch("matchesPreparedSourceEvidence") == derived_match
      raise Error, "materialized source snapshot is not bound to the exact prepared source evidence"
    end
    if require_match && !derived_match
      raise Error, "#{phase} materialized source snapshot does not match prepared evidence"
    end
    if build_ios_root
      observed_live = materialized_source_manifest(build_ios_root)
      require_equal(observed_live, manifest, "#{phase} materialized source snapshot/live tree")
    end
    [record, Digest::SHA256.hexdigest(snapshot_source)]
  rescue KeyError, TypeError => error
    raise Error, "invalid materialized source snapshot: #{error.message}"
  end

  def read_prepared_evidence(value, source_commit:)
    path = canonical_plain_file(value, "prepared build-source evidence")
    source = stable_file_read(path, "prepared build-source evidence")
    record = parse_json_object(source, "prepared build-source evidence")
    validate_prepared_record(record, source_commit: source_commit)
    [path, source, record]
  end

  def verify_materialized_source(build_ios_root:, prepared_source_record:, source_commit:)
    validate_prepared_record(prepared_source_record, source_commit: source_commit)
    root = canonical_plain_directory(build_ios_root, "materialized iOS build source")
    project = canonical_plain_file(
      root.join("QuakeSignal.xcodeproj/project.pbxproj"),
      "materialized Xcode project",
    )
    expected_project_sha = prepared_source_record.fetch("projectTransformation").fetch("temporarySha256")
    actual_project_sha = Digest::SHA256.hexdigest(stable_file_read(project, "materialized Xcode project"))
    require_equal(actual_project_sha, expected_project_sha, "materialized transformed Xcode project hash")
    observed = materialized_source_manifest(root)
    require_equal(
      observed,
      prepared_source_record.fetch("materializedBuildSource"),
      "materialized iOS build source inventory",
    )
    observed
  rescue KeyError, TypeError => error
    raise Error, "invalid prepared build-source evidence: #{error.message}"
  end

  def validate_prepared_record(record, source_commit:)
    require_commit(source_commit)
    require_exact_keys(
      record,
      %w[
        schemaVersion status uploadApproved reviewer sourceCommit purpose sourceMaterialization
        mainProductInputs copyVerification projectTransformation materializedBuildSource
      ],
      "prepared build-source evidence",
    )
    unless record.fetch("schemaVersion") == 1 && record.fetch("sourceCommit") == source_commit &&
           record.fetch("status") == "unapproved-debug-temporary-no-watch-build-source-evidence" &&
           record.fetch("uploadApproved") == false && record.fetch("reviewer").nil? &&
           record.fetch("purpose") ==
             "credential-free iOS Simulator screenshot build on a host where the Watch platform component cannot resolve"
      raise Error, "prepared build-source evidence is not the exact unapproved source commit"
    end

    materialization = record.fetch("sourceMaterialization")
    require_exact_keys(
      materialization,
      %w[method sourceCommit paths archiveProjectMatchesGitShow workingTreeMatchesArchive],
      "build-source materialization",
    )
    unless materialization == {
      "method" => "git-archive",
      "sourceCommit" => source_commit,
      "paths" => COPIED_INPUTS,
      "archiveProjectMatchesGitShow" => true,
      "workingTreeMatchesArchive" => true,
    }
      raise Error, "build-source materialization is not the exact clean git-archive contract"
    end

    source_manifest = validate_content_manifest(record.fetch("mainProductInputs"), "main-product inputs")
    copy = record.fetch("copyVerification")
    require_exact_keys(copy, %w[allNonProjectBytesIdentical copiedContentManifestSha256], "copy verification")
    unless copy.fetch("allNonProjectBytesIdentical") == true &&
           copy.fetch("copiedContentManifestSha256") == source_manifest.fetch("contentManifestSha256")
      raise Error, "prepared source copied input bytes are not bound"
    end

    transformation = record.fetch("projectTransformation")
    require_exact_keys(
      transformation,
      %w[
        originalFile temporaryFile originalSha256 temporarySha256 removedReferences
        removedDefinitionCount watchTargetDefinitionRetained mainTargetSourceAndResourcePhasesUnchanged
      ],
      "project transformation",
    )
    original_sha = require_sha256(transformation.fetch("originalSha256"), "original project")
    temporary_sha = require_sha256(transformation.fetch("temporarySha256"), "transformed project")
    unless transformation.fetch("originalFile") == PROJECT_RELATIVE &&
           transformation.fetch("temporaryFile") == PROJECT_RELATIVE && original_sha != temporary_sha &&
           transformation.fetch("removedReferences") == EXPECTED_REMOVED_REFERENCES &&
           transformation.fetch("removedDefinitionCount") == 0 &&
           transformation.fetch("watchTargetDefinitionRetained") == true &&
           transformation.fetch("mainTargetSourceAndResourcePhasesUnchanged") == true
      raise Error, "project transformation is not the exact two-reference Watch detachment"
    end

    materialized = validate_materialized_manifest(record.fetch("materializedBuildSource"))
    validate_xcode_swiftpm_workspace_directories(materialized)
    materialized_files = materialized.fetch("entries").select { |entry| entry.fetch("kind") == "file" }
    project_entry = materialized_files.find { |entry| entry.fetch("path") == PROJECT_RELATIVE }
    unless project_entry && project_entry.fetch("sha256") == temporary_sha
      raise Error, "materialized source manifest does not bind the transformed Xcode project"
    end
    nonproject_files = materialized_files.reject { |entry| entry.fetch("path") == PROJECT_RELATIVE }.map do |entry|
      {
        "file" => entry.fetch("path"),
        "sha256" => entry.fetch("sha256"),
        "bytes" => entry.fetch("bytes"),
      }
    end
    unless nonproject_files == source_manifest.fetch("files")
      raise Error, "materialized source files differ from the exact archived non-project inventory"
    end
    true
  rescue KeyError, TypeError => error
    raise Error, "invalid prepared build-source evidence: #{error.message}"
  end

  def prepare_xcode_swiftpm_workspace_directories(build_ios_root)
    root = canonical_plain_directory(build_ios_root, "materialized iOS build source")
    unless root.basename.to_s == "ios"
      raise Error, "materialized iOS build source must end in /ios"
    end

    XCODE_SWIFTPM_WORKSPACE_DIRECTORIES.each do |relative|
      path = root.dirname.join(relative)
      if path.exist? || path.symlink?
        raise Error, "prepared Xcode SwiftPM workspace path must be absent before creation: #{relative}"
      end
      canonical_plain_directory(path.dirname, "prepared Xcode SwiftPM workspace parent")
      path.mkdir(0o755)
      path.chmod(0o755)
    end
    true
  rescue Errno::EEXIST, IOError, SystemCallError => error
    raise Error, "could not prepare exact Xcode SwiftPM workspace directories: #{error.message}"
  end

  def validate_xcode_swiftpm_workspace_directories(manifest)
    entries = manifest.fetch("entries")
    first_path = XCODE_SWIFTPM_WORKSPACE_DIRECTORIES.first
    subtree = entries.select do |entry|
      path = entry.fetch("path")
      path == first_path || path.start_with?("#{first_path}/")
    end
    expected = XCODE_SWIFTPM_WORKSPACE_DIRECTORIES.map do |path|
      {
        "kind" => "directory",
        "path" => path,
        "mode" => XCODE_SWIFTPM_WORKSPACE_DIRECTORY_MODE,
      }
    end
    require_equal(subtree, expected, "prepared Xcode SwiftPM empty workspace directory chain")
    true
  rescue KeyError, TypeError => error
    raise Error, "invalid prepared Xcode SwiftPM workspace evidence: #{error.message}"
  end

  def remove_watch_embedding_references(source)
    unless source.encoding == Encoding::BINARY || source.valid_encoding?
      raise Error, "Xcode project is not valid text"
    end
    target_pattern = /^\t\t[0-9A-F]{24} \/\* QuakeSignal \*\/ = \{\n\t\t\tisa = PBXNativeTarget;.*?^\t\t\};$/m
    targets = source.scan(target_pattern)
    raise Error, "expected exactly one QuakeSignal native target" unless targets.length == 1

    target = targets.first
    embed_matches = target.scan(/^\t+([0-9A-F]{24}) \/\* Embed Watch Content \*\/,\n/)
    dependency_matches = target.scan(/^\t+([0-9A-F]{24}) \/\* PBXTargetDependency \*\/,\n/)
    unless embed_matches.length == 1 && dependency_matches.length == 1
      raise Error, "QuakeSignal target must have exactly one Watch embed phase and one target dependency"
    end
    embed_id = embed_matches.first.first
    dependency_id = dependency_matches.first.first

    copy_phase_pattern = /^\t\t#{Regexp.escape(embed_id)} \/\* Embed Watch Content \*\/ = \{.*?^\t\t\};$/m
    copy_phases = source.scan(copy_phase_pattern)
    unless copy_phases.length == 1 && copy_phases.first.include?("QuakeSignalWatch.app in Embed Watch Content")
      raise Error, "Watch embed reference does not resolve to the exact Watch copy phase"
    end
    dependency_pattern = /^\t\t#{Regexp.escape(dependency_id)} \/\* PBXTargetDependency \*\/ = \{.*?^\t\t\};$/m
    dependencies = source.scan(dependency_pattern)
    unless dependencies.length == 1 && dependencies.first.include?("/* QuakeSignalWatch */")
      raise Error, "QuakeSignal dependency does not resolve to the Watch target"
    end

    transformed_target = target.sub(
      /^\t+#{Regexp.escape(embed_id)} \/\* Embed Watch Content \*\/,\n/,
      "",
    ).sub(
      /^\t+#{Regexp.escape(dependency_id)} \/\* PBXTargetDependency \*\/,\n/,
      "",
    )
    transformed = source.sub(target, transformed_target)
    expected_size = source.bytesize - target.bytesize + transformed_target.bytesize
    unless transformed.bytesize == expected_size &&
           !transformed_target.include?("#{embed_id} /* Embed Watch Content */,") &&
           !transformed_target.include?("#{dependency_id} /* PBXTargetDependency */,")
      raise Error, "temporary project transformation changed more than the two allowed references"
    end
    [
      transformed,
      [
        {
          "kind" => "main-target-build-phase-reference",
          "identifier" => embed_id,
          "label" => "Embed Watch Content",
          "removedLine" => "#{embed_id} /* Embed Watch Content */,",
        },
        {
          "kind" => "main-target-dependency-reference",
          "identifier" => dependency_id,
          "label" => "QuakeSignalWatch",
          "removedLine" => "#{dependency_id} /* PBXTargetDependency */,",
        },
      ],
    ]
  end

  def content_manifest(files, root)
    records = files.map do |file|
      relative = file.relative_path_from(root).to_s
      "#{Digest::SHA256.file(file).hexdigest}  #{relative}\n"
    end.sort.join
    {
      "algorithm" => ALGORITHM,
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

  def validate_content_manifest(manifest, label)
    require_exact_keys(manifest, %w[algorithm fileCount totalBytes contentManifestSha256 files], label)
    files = manifest.fetch("files")
    unless manifest.fetch("algorithm") == ALGORITHM && files.is_a?(Array) && !files.empty? &&
           manifest.fetch("fileCount") == files.length &&
           manifest.fetch("totalBytes").is_a?(Integer) && manifest.fetch("totalBytes") >= 0
      raise Error, "#{label} inventory is invalid"
    end
    paths = []
    records = files.map do |file|
      require_exact_keys(file, %w[file sha256 bytes], "#{label} file")
      relative = require_materialized_path(file.fetch("file"), "#{label} path")
      unless COPIED_INPUTS.any? { |prefix| relative == prefix || relative.start_with?("#{prefix}/") }
        raise Error, "#{label} path is outside the exact archived inputs"
      end
      require_sha256(file.fetch("sha256"), "#{label} file")
      unless file.fetch("bytes").is_a?(Integer) && file.fetch("bytes") >= 0
        raise Error, "#{label} file byte count is invalid"
      end
      paths << relative
      "#{file.fetch('sha256')}  #{relative}\n"
    end
    unless paths == paths.sort && paths.uniq.length == paths.length &&
           files.sum { |file| file.fetch("bytes") } == manifest.fetch("totalBytes") &&
           Digest::SHA256.hexdigest(records.sort.join) == manifest.fetch("contentManifestSha256")
      raise Error, "#{label} content manifest is invalid"
    end
    require_sha256(manifest.fetch("contentManifestSha256"), "#{label} content manifest")
    manifest
  end

  def materialized_source_manifest(build_ios_root)
    root = canonical_plain_directory(build_ios_root, "materialized iOS build source")
    unless root.basename.to_s == "ios"
      raise Error, "materialized iOS build source must end in /ios"
    end
    first = materialized_entries(root)
    second = materialized_entries(root)
    unless first == second
      raise Error, "materialized iOS build source changed while its full inventory was read"
    end
    manifest = build_materialized_manifest(first)
    validate_materialized_manifest(manifest)
    manifest
  end

  def materialized_entries(root)
    entries = snapshot_materialized_entry(root, root.dirname)
    top_level = entries.select do |entry|
      entry.fetch("path").count("/") == 1
    end.map { |entry| [entry.fetch("path"), entry.fetch("kind")] }
    expected = MATERIALIZED_TOP_LEVEL_DIRECTORIES.map { |path| [path, "directory"] }
    require_equal(top_level, expected, "materialized iOS build source top-level inventory")
    entries
  end

  def snapshot_materialized_entry(path, relative_root)
    before = path.lstat
    relative = require_materialized_path(path.relative_path_from(relative_root).to_s, "materialized source path")
    mode = format("%04o", before.mode & 0o7777)
    if before.directory? && !path.symlink?
      children = path.children.sort_by { |child| child.basename.to_s }
      entries = [{ "kind" => "directory", "path" => relative, "mode" => mode }]
      entries.concat(children.flat_map { |child| snapshot_materialized_entry(child, relative_root) })
      after = path.lstat
      unless stable_stat_signature(before) == stable_stat_signature(after)
        raise Error, "materialized source directory changed while reading: #{relative}"
      end
      entries
    elsif before.file? && !path.symlink?
      source = stable_file_read(path, "materialized source file #{relative}")
      [{
        "kind" => "file",
        "path" => relative,
        "mode" => mode,
        "sha256" => Digest::SHA256.hexdigest(source),
        "bytes" => source.bytesize,
      }]
    else
      raise Error, "materialized source contains a symlink or special entry: #{relative}"
    end
  rescue Errno::ENOENT => error
    raise Error, "materialized source changed while reading #{relative || path}: #{error.message}"
  end

  def build_materialized_manifest(entries)
    records = entries.map { |entry| materialized_record(entry) }.sort.join
    files = entries.select { |entry| entry.fetch("kind") == "file" }
    directories = entries.select { |entry| entry.fetch("kind") == "directory" }
    {
      "algorithm" => MATERIALIZED_TREE_ALGORITHM,
      "entryCount" => entries.length,
      "fileCount" => files.length,
      "directoryCount" => directories.length,
      "totalBytes" => files.sum { |entry| entry.fetch("bytes") },
      "contentManifestSha256" => Digest::SHA256.hexdigest(records),
      "entries" => entries.sort_by { |entry| entry.fetch("path") },
    }
  end

  def validate_materialized_manifest(manifest)
    require_exact_keys(
      manifest,
      %w[algorithm entryCount fileCount directoryCount totalBytes contentManifestSha256 entries],
      "materialized source manifest",
    )
    entries = manifest.fetch("entries")
    unless manifest.fetch("algorithm") == MATERIALIZED_TREE_ALGORITHM && entries.is_a?(Array) && entries.any? &&
           manifest.fetch("entryCount") == entries.length
      raise Error, "materialized source manifest inventory is invalid"
    end
    paths = []
    file_count = 0
    directory_count = 0
    total_bytes = 0
    entry_by_path = {}
    records = entries.map do |entry|
      kind = entry.fetch("kind")
      relative = require_materialized_path(entry.fetch("path"), "materialized source manifest path")
      mode = entry.fetch("mode")
      unless mode.is_a?(String) && mode.match?(/\A[0-7]{4}\z/)
        raise Error, "materialized source entry mode is invalid"
      end
      case kind
      when "directory"
        require_exact_keys(entry, %w[kind path mode], "materialized source directory")
        directory_count += 1
      when "file"
        require_exact_keys(entry, %w[kind path mode sha256 bytes], "materialized source file")
        require_sha256(entry.fetch("sha256"), "materialized source file")
        unless entry.fetch("bytes").is_a?(Integer) && entry.fetch("bytes") >= 0
          raise Error, "materialized source file byte count is invalid"
        end
        file_count += 1
        total_bytes += entry.fetch("bytes")
      else
        raise Error, "materialized source entry kind is invalid"
      end
      paths << relative
      entry_by_path[relative] = entry
      materialized_record(entry)
    rescue KeyError, TypeError => error
      raise Error, "invalid materialized source entry: #{error.message}"
    end
    unless paths == paths.sort && paths.uniq.length == paths.length
      raise Error, "materialized source paths must be unique and sorted"
    end
    root_entry = entry_by_path.fetch("ios", nil)
    unless root_entry && root_entry.fetch("kind") == "directory"
      raise Error, "materialized source manifest is missing the ios root directory"
    end
    top_level = entries.select { |entry| entry.fetch("path").count("/") == 1 }
                       .map { |entry| [entry.fetch("path"), entry.fetch("kind")] }
    expected_top_level = MATERIALIZED_TOP_LEVEL_DIRECTORIES.map { |path| [path, "directory"] }
    require_equal(top_level, expected_top_level, "materialized source manifest top-level inventory")
    entries.each do |entry|
      relative = entry.fetch("path")
      next if relative == "ios"

      parent = Pathname.new(relative).dirname.to_s
      parent_entry = entry_by_path[parent]
      unless parent_entry && parent_entry.fetch("kind") == "directory"
        raise Error, "materialized source manifest omits parent directory for #{relative}"
      end
      unless MATERIALIZED_TOP_LEVEL_DIRECTORIES.any? do |prefix|
        relative == prefix || relative.start_with?("#{prefix}/")
      end
        raise Error, "materialized source manifest path is outside the exact copied inputs"
      end
    end
    unless manifest.fetch("fileCount") == file_count &&
           manifest.fetch("directoryCount") == directory_count &&
           manifest.fetch("totalBytes") == total_bytes &&
           manifest.fetch("contentManifestSha256") == Digest::SHA256.hexdigest(records.sort.join)
      raise Error, "materialized source manifest counters or content hash are invalid"
    end
    require_sha256(manifest.fetch("contentManifestSha256"), "materialized source manifest")
    manifest
  rescue KeyError, TypeError => error
    raise Error, "invalid materialized source manifest: #{error.message}"
  end

  def materialized_record(entry)
    if entry.fetch("kind") == "directory"
      "directory  #{entry.fetch('mode')}  -  -  #{entry.fetch('path')}\n"
    else
      "file  #{entry.fetch('mode')}  #{entry.fetch('sha256')}  #{entry.fetch('bytes')}  #{entry.fetch('path')}\n"
    end
  end

  def plain_input_files(root)
    COPIED_INPUTS.flat_map { |relative| plain_files(root.join(relative), root) }
                 .sort_by { |file| file.relative_path_from(root).to_s }
  end

  def plain_files(path, root)
    stat = path.lstat
    if stat.file? && !path.symlink?
      return [path]
    end
    unless stat.directory? && !path.symlink?
      raise Error, "build input contains a symlink or special entry: #{path.relative_path_from(root)}"
    end
    path.children.sort_by(&:to_s).flat_map { |child| plain_files(child, root) }
  end

  def copy_plain_tree(source, destination, root)
    stat = source.lstat
    if stat.directory? && !source.symlink?
      destination.mkpath
      source.children.sort_by(&:to_s).each do |child|
        copy_plain_tree(child, destination.join(child.basename), root)
      end
    elsif stat.file? && !source.symlink?
      destination.dirname.mkpath
      FileUtils.cp(source, destination, preserve: true)
    else
      raise Error, "build input contains a symlink or special entry: #{source.relative_path_from(root)}"
    end
  end

  def extract_commit_inputs(root, source_commit, destination)
    archive, archive_error, archive_status = Open3.capture3(
      "git", "-C", root.to_s, "archive", source_commit, "--", *COPIED_INPUTS, binmode: true,
    )
    unless archive_status.success?
      raise Error, "could not archive committed iOS inputs: #{archive_error.strip}"
    end
    _output, extraction_error, extraction_status = Open3.capture3(
      "/usr/bin/tar", "-x", "-f", "-", "-C", destination.to_s,
      stdin_data: archive,
      binmode: true,
    )
    unless extraction_status.success?
      raise Error, "could not extract committed iOS inputs: #{extraction_error.strip}"
    end
    plain_input_files(destination)
  end

  def require_clean_commit(root, expected)
    actual, error, status = Open3.capture3("git", "-C", root.to_s, "rev-parse", "--verify", "HEAD^{commit}")
    raise Error, "could not resolve source commit: #{error.strip}" unless status.success?

    require_equal(actual.strip, expected, "source commit")
    status_output, status_error, status_status = Open3.capture3(
      "git", "-C", root.to_s, "status", "--porcelain=v1", "--untracked-files=all",
    )
    raise Error, "could not inspect source tree: #{status_error.strip}" unless status_status.success?
    raise Error, "temporary screenshot build source requires a clean source tree" unless status_output.empty?
  end

  def ensure_unchanged_source(root, commit)
    require_clean_commit(root, commit)
  end

  def require_external_new_path(root, path, label)
    requested_parent = path.dirname
    unless requested_parent.directory? && !requested_parent.symlink? &&
           requested_parent.realpath == requested_parent
      raise Error, "#{label} parent must be an existing canonical plain directory"
    end
    resolved_path = requested_parent.realpath.join(path.basename).cleanpath
    unless resolved_path == path.cleanpath
      raise Error, "#{label} parent must be canonical and contain no symlink components"
    end
    root_string = root.to_s
    path_string = resolved_path.to_s
    if path_string == root_string || path_string.start_with?("#{root_string}#{File::SEPARATOR}")
      raise Error, "#{label} must remain outside the repository"
    end
    raise Error, "#{label} already exists" if path.exist? || path.symlink?
  end

  def canonical_plain_file(value, label)
    requested = Pathname.new(value)
    path = requested.expand_path
    unless requested.absolute? && requested.cleanpath == requested && path.realpath == path &&
           path.lstat.file? && !path.symlink?
      raise Error, "#{label} must be a canonical absolute plain file"
    end
    path
  rescue Errno::ENOENT
    raise Error, "#{label} is missing"
  end

  def canonical_plain_directory(value, label)
    requested = Pathname.new(value)
    path = requested.expand_path
    unless requested.absolute? && requested.cleanpath == requested && path.realpath == path &&
           path.lstat.directory? && !path.symlink?
      raise Error, "#{label} must be a canonical absolute plain directory"
    end
    path
  rescue Errno::ENOENT
    raise Error, "#{label} is missing"
  end

  def canonical_new_file(value, label)
    requested = Pathname.new(value)
    path = requested.expand_path
    unless requested.absolute? && requested.cleanpath == requested &&
           path.dirname.realpath == path.dirname && path.dirname.lstat.directory? &&
           !path.dirname.symlink? && !path.exist? && !path.symlink?
      raise Error, "#{label} output must be a new path under a canonical absolute plain parent"
    end
    path
  rescue Errno::ENOENT
    raise Error, "#{label} output parent is missing"
  end

  def stable_file_read(path, label)
    pathname_before = path.lstat
    source = nil
    descriptor_before = nil
    descriptor_after = nil
    path.open("rb") do |file|
      descriptor_before = file.stat
      unless descriptor_before.file? &&
             [descriptor_before.dev, descriptor_before.ino] == [pathname_before.dev, pathname_before.ino]
        raise Error, "#{label} changed before it could be read"
      end
      source = file.read
      descriptor_after = file.stat
    end
    pathname_after = path.lstat
    signatures = [pathname_before, descriptor_before, descriptor_after, pathname_after].map do |stat|
      stable_stat_signature(stat)
    end
    unless signatures.uniq.length == 1 && source.bytesize == descriptor_after.size
      raise Error, "#{label} changed while it was read"
    end
    source
  rescue Errno::ENOENT => error
    raise Error, "#{label} changed while it was read: #{error.message}"
  end

  def stable_stat_signature(stat)
    [
      stat.dev,
      stat.ino,
      stat.mode,
      stat.nlink,
      stat.size,
      stat.mtime.to_r,
      stat.ctime.to_r,
    ]
  end

  def parse_json_object(source, label)
    value = JSON.parse(source, object_class: DuplicateRejectingHash)
    raise Error, "#{label} must be an object" unless value.is_a?(Hash)

    value
  rescue JSON::ParserError => error
    raise Error, "invalid #{label}: #{error.message}"
  end

  def require_materialized_path(value, label)
    unless value.is_a?(String)
      raise Error, "#{label} is not one safe UTF-8 relative path"
    end
    relative = value.dup.force_encoding(Encoding::UTF_8)
    unless relative.valid_encoding? && !relative.empty? && !relative.include?("\0") &&
           !relative.include?("\n") && !relative.include?("\r")
      raise Error, "#{label} is not one safe UTF-8 relative path"
    end
    path = Pathname.new(relative)
    unless !path.absolute? && path.cleanpath.to_s == relative &&
           (relative == "ios" || relative.start_with?("ios/"))
      raise Error, "#{label} is not one canonical ios-relative path"
    end
    relative
  end

  def require_sha256(value, label)
    unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
      raise Error, "#{label} SHA-256 is invalid"
    end
    value
  end

  def require_snapshot_phase(value)
    return value if MATERIALIZED_SNAPSHOT_PHASES.include?(value)

    raise Error, "materialized source snapshot phase must be exactly pre-build or post-build"
  end

  def require_snapshot_time(value, label)
    unless value.is_a?(String) &&
           value.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z\z/)
      raise Error, "#{label} capturedAt must be one canonical microsecond UTC timestamp"
    end
    parsed = Time.iso8601(value)
    unless parsed.utc.strftime(MATERIALIZED_SNAPSHOT_TIME_FORMAT) == value
      raise Error, "#{label} capturedAt must be one canonical microsecond UTC timestamp"
    end
    value
  rescue ArgumentError
    raise Error, "#{label} capturedAt must be one canonical microsecond UTC timestamp"
  end

  def require_exact_keys(value, expected, label)
    unless value.is_a?(Hash) && value.keys.sort == expected.sort
      raise Error, "#{label} has an unexpected schema"
    end
  end

  def require_commit(value)
    return if value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)

    raise Error, "source commit must be a full lowercase Git commit"
  end

  def require_equal(actual, expected, label)
    return if actual == expected

    raise Error, "#{label} mismatch: expected #{expected.inspect}, found #{actual.inspect}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV.length == 6 && ARGV.fetch(0) == "snapshot"
      _mode, source_commit, build_ios_root, prepared_evidence, phase, output = ARGV
      QuakeSignalIOSScreenshotBuildSource.write_materialized_snapshot(
        output: output,
        build_ios_root: build_ios_root,
        prepared_source_evidence: prepared_evidence,
        source_commit: source_commit,
        phase: phase,
      )
    elsif ARGV.length == 3
      repository_root = Pathname.new(__dir__).join("../..").realpath
      QuakeSignalIOSScreenshotBuildSource.prepare(
        repository_root: repository_root,
        source_commit: ARGV.fetch(0),
        output_ios_root: ARGV.fetch(1),
        evidence_output: ARGV.fetch(2),
      )
    else
      abort "Usage: prepare-ios-screenshot-build-source.rb <source-commit> <absolute-output-ios-directory> <absolute-evidence.json>\n" \
            "   or: prepare-ios-screenshot-build-source.rb snapshot <source-commit> <absolute-build-ios-directory> <absolute-prepared-evidence.json> <pre-build|post-build> <absolute-snapshot.json>"
    end
  rescue QuakeSignalIOSScreenshotBuildSource::Error => error
    warn "error: #{error.message}"
    exit 65
  end
end
