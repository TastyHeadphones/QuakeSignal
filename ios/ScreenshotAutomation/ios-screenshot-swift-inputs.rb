#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module QuakeSignalIOSScreenshotSwiftInputs
  class Error < StandardError; end

  class DuplicateRejectingHash < Hash
    def []=(key, value)
      raise Error, "duplicate Swift input evidence JSON key #{key.inspect}" if key?(key)
      super
    end
  end

  module_function

  def record(source_commit:, build_source_evidence:, build_log:, derived_data:, build_ios_root:, architecture:)
    require_commit(source_commit)
    raise Error, "unsupported Swift input architecture" unless %w[arm64 x86_64].include?(architecture)

    source_path = canonical_plain_file(build_source_evidence, "build-source evidence")
    log_path = canonical_plain_file(build_log, "build log")
    derived = canonical_plain_directory(derived_data, "DerivedData")
    build_root = canonical_plain_directory(build_ios_root, "temporary iOS source")
    source_record = parse_object(source_path, "build-source evidence")
    unless source_record.fetch("sourceCommit") == source_commit
      raise Error, "Swift inputs and build-source commit differ"
    end
    source_files = source_record.fetch("mainProductInputs").fetch("files").to_h do |file|
      [file.fetch("file"), file]
    end

    expected_relative = "Build/Intermediates.noindex/QuakeSignal.build/Debug-iphonesimulator/" \
                        "QuakeSignal.build/Objects-normal/#{architecture}/QuakeSignal.SwiftFileList"
    raw_list = canonical_plain_file(derived.join(expected_relative), "QuakeSignal Swift file list")
    unless log_path.read.include?(raw_list.to_s)
      raise Error, "build log does not bind the exact QuakeSignal Swift file list"
    end
    raw_lines = raw_list.readlines(chomp: true)
    if raw_lines.empty? || raw_lines.any?(&:empty?) || raw_lines.uniq.length != raw_lines.length
      raise Error, "QuakeSignal Swift file list must contain unique nonempty entries"
    end

    entries = raw_lines.map do |line|
      path = canonical_plain_file(line, "Swift compiler input")
      relative = if inside?(path, build_root)
                   "ios/#{path.relative_path_from(build_root)}"
                 elsif inside?(path, derived)
                   "DerivedData/#{path.relative_path_from(derived)}"
                 else
                   raise Error, "Swift compiler input escaped archived source and fresh DerivedData"
                 end
      kind = relative.start_with?("ios/") ? "authored" : "generated"
      if kind == "authored"
        source = source_files.fetch(relative) do
          raise Error, "authored Swift compiler input is absent from the archived source manifest: #{relative}"
        end
        unless relative.end_with?(".swift") && source.fetch("sha256") == Digest::SHA256.file(path).hexdigest &&
               source.fetch("bytes") == path.size
          raise Error, "authored Swift compiler input bytes differ from the archived source manifest: #{relative}"
        end
      elsif relative != "DerivedData/Build/Intermediates.noindex/QuakeSignal.build/Debug-iphonesimulator/" \
                        "QuakeSignal.build/DerivedSources/GeneratedAssetSymbols.swift"
        raise Error, "unreviewed generated Swift compiler input: #{relative}"
      end
      {
        "kind" => kind,
        "file" => relative,
        "sha256" => Digest::SHA256.file(path).hexdigest,
        "bytes" => path.size,
      }
    end
    authored = entries.select { |entry| entry.fetch("kind") == "authored" }
    generated = entries.select { |entry| entry.fetch("kind") == "generated" }
    unless authored.any? && generated.length == 1
      raise Error, "Swift file list must contain authored inputs and the exact generated asset-symbol source"
    end
    phase_identifier, expected_authored_paths = main_target_swift_sources(
      build_root.join("QuakeSignal.xcodeproj/project.pbxproj").read,
      source_files,
    )
    unless authored.map { |entry| entry.fetch("file") }.sort == expected_authored_paths
      raise Error, "Swift file list does not exactly match the QuakeSignal PBXSources build phase"
    end
    normalized = entries.map { |entry| "#{entry.fetch('kind')}  #{entry.fetch('file')}\n" }.join
    value = {
      "schemaVersion" => 1,
      "status" => "unapproved-debug-source-bound-swift-compiler-inputs",
      "uploadApproved" => false,
      "reviewer" => nil,
      "sourceCommit" => source_commit,
      "hostArchitecture" => architecture,
      "target" => "QuakeSignal",
      "configuration" => "Debug",
      "platform" => "iphonesimulator",
      "fileList" => {
        "derivedDataRelativeFile" => expected_relative,
        "rawSha256" => Digest::SHA256.file(raw_list).hexdigest,
        "entryCount" => entries.length,
        "normalizedContentSha256" => Digest::SHA256.hexdigest(normalized),
        "entries" => entries,
      },
      "authoredInputCount" => authored.length,
      "generatedInputCount" => generated.length,
      "mainTargetSourcesBuildPhaseIdentifier" => phase_identifier,
      "mainTargetAuthoredSourceFiles" => expected_authored_paths,
      "authoredInputsExactlyMatchMainTargetSources" => true,
    }
    validate(value, source_record: source_record, source_commit: source_commit, architecture: architecture)
    value
  rescue KeyError, JSON::ParserError => error
    raise Error, "invalid Swift input evidence: #{error.message}"
  end

  def validate(record, source_record:, source_commit:, architecture:)
    exact_keys(record, %w[
      schemaVersion status uploadApproved reviewer sourceCommit hostArchitecture target configuration
      platform fileList authoredInputCount generatedInputCount mainTargetSourcesBuildPhaseIdentifier
      mainTargetAuthoredSourceFiles authoredInputsExactlyMatchMainTargetSources
    ], "Swift input evidence")
    unless record.fetch("schemaVersion") == 1 &&
           record.fetch("status") == "unapproved-debug-source-bound-swift-compiler-inputs" &&
           record.fetch("uploadApproved") == false && record.fetch("reviewer").nil? &&
           record.fetch("sourceCommit") == source_commit && record.fetch("hostArchitecture") == architecture &&
           record.fetch("target") == "QuakeSignal" && record.fetch("configuration") == "Debug" &&
           record.fetch("platform") == "iphonesimulator" &&
           record.fetch("authoredInputsExactlyMatchMainTargetSources") == true &&
           record.fetch("mainTargetSourcesBuildPhaseIdentifier").match?(/\A[0-9A-F]{24}\z/)
      raise Error, "Swift input evidence header differs from the exact build contract"
    end
    list = record.fetch("fileList")
    exact_keys(list, %w[derivedDataRelativeFile rawSha256 entryCount normalizedContentSha256 entries], "Swift file list")
    expected_relative = "Build/Intermediates.noindex/QuakeSignal.build/Debug-iphonesimulator/" \
                        "QuakeSignal.build/Objects-normal/#{architecture}/QuakeSignal.SwiftFileList"
    require_sha(list.fetch("rawSha256"), "raw Swift file list")
    entries = list.fetch("entries")
    unless list.fetch("derivedDataRelativeFile") == expected_relative && entries.is_a?(Array) && entries.any? &&
           list.fetch("entryCount") == entries.length
      raise Error, "Swift file-list identity or count is invalid"
    end
    source_files = source_record.fetch("mainProductInputs").fetch("files").to_h do |file|
      [file.fetch("file"), file]
    end
    paths = []
    authored_count = 0
    generated_count = 0
    normalized = entries.map do |entry|
      exact_keys(entry, %w[kind file sha256 bytes], "Swift input entry")
      kind = entry.fetch("kind")
      relative = entry.fetch("file")
      require_sha(entry.fetch("sha256"), "Swift input")
      unless entry.fetch("bytes").is_a?(Integer) && entry.fetch("bytes").positive?
        raise Error, "Swift input byte count is invalid"
      end
      case kind
      when "authored"
        authored_count += 1
        source = source_files.fetch(relative) do
          raise Error, "authored Swift input is absent from source manifest"
        end
        unless relative.start_with?("ios/QuakeSignal/") || relative.start_with?("ios/QuakeSignalShared/")
          raise Error, "authored Swift input escaped the main-product source trees"
        end
        unless relative.end_with?(".swift") && source.fetch("sha256") == entry.fetch("sha256") &&
               source.fetch("bytes") == entry.fetch("bytes")
          raise Error, "authored Swift input differs from source manifest"
        end
      when "generated"
        generated_count += 1
        expected_generated = "DerivedData/Build/Intermediates.noindex/QuakeSignal.build/" \
                             "Debug-iphonesimulator/QuakeSignal.build/DerivedSources/GeneratedAssetSymbols.swift"
        raise Error, "generated Swift input is not the exact asset-symbol source" unless relative == expected_generated
      else
        raise Error, "Swift input kind is unreviewed"
      end
      paths << relative
      "#{kind}  #{relative}\n"
    end.join
    expected_authored = record.fetch("mainTargetAuthoredSourceFiles")
    unless expected_authored.is_a?(Array) && expected_authored == expected_authored.sort &&
           expected_authored.uniq.length == expected_authored.length &&
           paths.select { |path| path.start_with?("ios/") }.sort == expected_authored &&
           paths.uniq.length == paths.length && authored_count == record.fetch("authoredInputCount") &&
           generated_count == record.fetch("generatedInputCount") && generated_count == 1 && authored_count.positive? &&
           Digest::SHA256.hexdigest(normalized) == list.fetch("normalizedContentSha256")
      raise Error, "normalized Swift compiler input inventory is invalid"
    end
    true
  rescue KeyError, TypeError => error
    raise Error, "invalid Swift input evidence: #{error.message}"
  end

  def main_target_swift_sources(project_source, source_files)
    target_pattern = /^\t\t[0-9A-F]{24} \/\* QuakeSignal \*\/ = \{\n\t\t\tisa = PBXNativeTarget;.*?^\t\t\};$/m
    targets = project_source.scan(target_pattern)
    raise Error, "expected exactly one QuakeSignal native target" unless targets.length == 1
    phase_ids = targets.first.scan(/^\t+([0-9A-F]{24}) \/\* Sources \*\/,\n/).flatten
    raise Error, "QuakeSignal target must reference exactly one Sources phase" unless phase_ids.length == 1
    phase_id = phase_ids.first
    phase_pattern = /^\t\t#{Regexp.escape(phase_id)} \/\* Sources \*\/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;.*?^\t\t\};$/m
    phases = project_source.scan(phase_pattern)
    raise Error, "QuakeSignal Sources phase is missing or ambiguous" unless phases.length == 1
    names = phases.first.scan(/^\t+\w+ \/\* (.+\.swift) in Sources \*\/,\n/).flatten
    raise Error, "QuakeSignal Sources phase contains no Swift files" if names.empty? || names.uniq.length != names.length
    paths = names.map do |name|
      matches = source_files.keys.select { |path| path.end_with?("/#{name}") }
      raise Error, "QuakeSignal source name is absent or ambiguous in archived inputs: #{name}" unless matches.length == 1
      matches.first
    end.sort
    [phase_id, paths]
  end

  def write(output:, **arguments)
    path = Pathname.new(output).expand_path
    unless Pathname.new(output).absolute? && path.dirname.realpath == path.dirname && !path.exist? && !path.symlink?
      raise Error, "Swift input evidence output must be a new canonical absolute path"
    end
    value = record(**arguments)
    path.write(JSON.pretty_generate(value) + "\n", mode: "wx")
    value
  rescue Errno::ENOENT, Errno::EEXIST => error
    raise Error, "could not write Swift input evidence: #{error.message}"
  end

  def inside?(path, root)
    path.to_s.start_with?("#{root}#{File::SEPARATOR}")
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

  def parse_object(path, label)
    value = JSON.parse(path.read, object_class: DuplicateRejectingHash)
    raise Error, "#{label} must be an object" unless value.is_a?(Hash)
    value
  end

  def exact_keys(value, expected, label)
    raise Error, "#{label} has an unexpected schema" unless value.is_a?(Hash) && value.keys.sort == expected.sort
  end

  def require_sha(value, label)
    raise Error, "#{label} SHA-256 is invalid" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
  end

  def require_commit(value)
    raise Error, "source commit must be full lowercase Git" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    unless ARGV.length == 7
      abort "Usage: ios-screenshot-swift-inputs.rb <commit> <build-source.json> <build.log> <DerivedData> <build-source/ios> <architecture> <output.json>"
    end
    commit, source, log, derived, build_root, architecture, output = ARGV
    QuakeSignalIOSScreenshotSwiftInputs.write(
      output: output,
      source_commit: commit,
      build_source_evidence: source,
      build_log: log,
      derived_data: derived,
      build_ios_root: build_root,
      architecture: architecture,
    )
  rescue QuakeSignalIOSScreenshotSwiftInputs::Error => error
    warn "error: #{error.message}"
    exit 65
  end
end
