#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module QuakeSignalScreenshotCapturePackageSeal
  class Error < StandardError; end

  # Ruby's JSON parser accepts the last value for a repeated object key.  A
  # capture seal is a security boundary, so accepting an ambiguous manifest is
  # never safe even when the surviving value happens to be valid.
  class DuplicateRejectingHash < Hash
    def []=(key, value)
      raise Error, "duplicate JSON object key #{key.inspect}" if key?(key)

      super
    end
  end

  ALGORITHM =
    "sha256 of sorted UTF-8 records: <file-sha256><two spaces><capture-relative-path><newline>"
  PLATFORMS = %w[ios-ipados tvos watchos visionos maccatalyst].freeze

  module_function

  def seal(platform:, source_commit:, capture_root:, output:)
    unless PLATFORMS.include?(platform)
      raise Error, "unsupported capture platform #{platform.inspect}"
    end
    unless source_commit.is_a?(String) && source_commit.match?(/\A[0-9a-f]{40}\z/)
      raise Error, "source commit must be a full lowercase Git commit"
    end
    root = Pathname.new(capture_root).realpath
    output_path = Pathname.new(output).expand_path
    unless output_path.dirname == root && output_path.basename.to_s == "capture-package-manifest.json"
      raise Error, "capture package manifest must be a direct capture-root file named capture-package-manifest.json"
    end
    if output_path.exist? || output_path.symlink?
      raise Error, "capture package manifest already exists"
    end

    files = tree_files(root)
    raise Error, "capture package is empty" if files.empty?
    records = files.map do |file|
      relative = file.relative_path_from(root).to_s
      "#{Digest::SHA256.file(file).hexdigest}  #{relative}\n"
    end.sort.join
    record = {
      "schemaVersion" => 1,
      "status" => "unapproved-source-addressed-capture-package-manifest",
      "uploadApproved" => false,
      "reviewer" => nil,
      "platform" => platform,
      "sourceCommit" => source_commit,
      "contentManifestAlgorithm" => ALGORITHM,
      "fileCount" => files.length,
      "totalBytes" => files.sum(&:size),
      "contentManifestSha256" => Digest::SHA256.hexdigest(records),
    }
    output_path.write(JSON.pretty_generate(record) + "\n", mode: "wx")
    record
  end

  def validate(platform:, source_commit:, capture_root:)
    root = Pathname.new(capture_root).realpath
    manifest_path = root.join("capture-package-manifest.json")
    stat = manifest_path.lstat
    unless stat.file? && !manifest_path.symlink?
      raise Error, "capture package manifest is not a plain file"
    end
    source = manifest_path.read
    manifest = JSON.parse(source, object_class: DuplicateRejectingHash)
    expected_keys = %w[
      schemaVersion status uploadApproved reviewer platform sourceCommit
      contentManifestAlgorithm fileCount totalBytes contentManifestSha256
    ]
    unless manifest.is_a?(Hash) && manifest.keys.sort == expected_keys.sort
      raise Error, "capture package manifest keys differ from the sealed schema"
    end
    expected_header = {
      "schemaVersion" => 1,
      "status" => "unapproved-source-addressed-capture-package-manifest",
      "uploadApproved" => false,
      "reviewer" => nil,
      "platform" => platform,
      "sourceCommit" => source_commit,
      "contentManifestAlgorithm" => ALGORITHM,
    }
    expected_header.each do |key, value|
      unless manifest.fetch(key) == value
        raise Error, "capture package manifest #{key} mismatch"
      end
    end
    files = tree_files(root).reject { |file| file == manifest_path }
    records = files.map do |file|
      relative = file.relative_path_from(root).to_s
      "#{Digest::SHA256.file(file).hexdigest}  #{relative}\n"
    end.sort.join
    unless manifest.fetch("fileCount") == files.length &&
           manifest.fetch("totalBytes") == files.sum(&:size) &&
           manifest.fetch("contentManifestSha256") == Digest::SHA256.hexdigest(records)
      raise Error, "capture package bytes differ from the sealed content manifest"
    end
    manifest
  rescue Errno::ENOENT, JSON::ParserError, KeyError, TypeError => error
    raise Error, "invalid capture package manifest: #{error.message}"
  end

  def tree_files(root)
    files = []
    visit = lambda do |directory|
      directory.children.sort_by(&:to_s).each do |entry|
        stat = entry.lstat
        if stat.directory? && !entry.symlink?
          visit.call(entry)
        elsif stat.file? && !entry.symlink?
          files << entry
        else
          raise Error, "capture package contains a symlink or special entry: #{entry.relative_path_from(root)}"
        end
      end
    end
    visit.call(root)
    files.sort_by { |file| file.relative_path_from(root).to_s }
  rescue Errno::ENOENT => error
    raise Error, "capture package changed while inspected: #{error.message}"
  end
  private_class_method :tree_files
end

if $PROGRAM_NAME == __FILE__
  begin
    unless ARGV.length == 4
      abort "Usage: seal-screenshot-capture-package.rb <platform> <source-commit> <capture-root> <output.json>"
    end
    QuakeSignalScreenshotCapturePackageSeal.seal(
      platform: ARGV.fetch(0),
      source_commit: ARGV.fetch(1),
      capture_root: ARGV.fetch(2),
      output: ARGV.fetch(3),
    )
  rescue QuakeSignalScreenshotCapturePackageSeal::Error => error
    warn "error: #{error.message}"
    exit 65
  end
end
