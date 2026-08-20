#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "ios-screenshot-swift-inputs"
require_relative "screenshot-test-temp-root"

class IOSScreenshotSwiftInputsTest < Minitest::Test
  COMMIT = "a" * 40

  def setup
    @temporary_directory = Dir.mktmpdir(
      "quakesignal-ios-swift-inputs-test",
      QuakeSignalScreenshotTestTempRoot.path.to_s,
    )
    @root = Pathname.new(@temporary_directory)
    @arch = `uname -m`.strip
    @build_root = @root.join("BuildSource/ios")
    @authored = @build_root.join("QuakeSignal/App/Main.swift")
    @authored.dirname.mkpath
    @authored.write("struct Main {}\n")
    project = @build_root.join("QuakeSignal.xcodeproj/project.pbxproj")
    project.dirname.mkpath
    project.write(<<~PBX)
      \t\tAAAAAAAAAAAAAAAAAAAAAAAA /* QuakeSignal */ = {
      \t\t\tisa = PBXNativeTarget;
      \t\t\tbuildPhases = (
      \t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Sources */,
      \t\t\t);
      \t\t};
      \t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Sources */ = {
      \t\t\tisa = PBXSourcesBuildPhase;
      \t\t\tfiles = (
      \t\t\t\tCCCCCCCCCCCCCCCCCCCCCCCC /* Main.swift in Sources */,
      \t\t\t);
      \t\t};
    PBX
    @derived = @root.join("DerivedData")
    @generated = @derived.join(
      "Build/Intermediates.noindex/QuakeSignal.build/Debug-iphonesimulator/" \
      "QuakeSignal.build/DerivedSources/GeneratedAssetSymbols.swift",
    )
    @generated.dirname.mkpath
    @generated.write("enum AssetSymbol {}\n")
    @raw_list = @derived.join(
      "Build/Intermediates.noindex/QuakeSignal.build/Debug-iphonesimulator/" \
      "QuakeSignal.build/Objects-normal/#{@arch}/QuakeSignal.SwiftFileList",
    )
    @raw_list.dirname.mkpath
    @raw_list.write("#{@authored}\n#{@generated}\n")
    authored_record = {
      "file" => "ios/QuakeSignal/App/Main.swift",
      "sha256" => Digest::SHA256.file(@authored).hexdigest,
      "bytes" => @authored.size,
    }
    @source_record = {
      "sourceCommit" => COMMIT,
      "mainProductInputs" => { "files" => [authored_record] },
    }
    @source = @root.join("source.json")
    @source.write(JSON.pretty_generate(@source_record) + "\n")
    @log = @root.join("build.log")
    @log.write("SwiftDriver ... #{@raw_list}\n")
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory) if @temporary_directory && File.exist?(@temporary_directory)
  end

  def test_normalizes_and_binds_authored_and_generated_inputs
    record = build_record
    assert_equal false, record.fetch("uploadApproved")
    assert_nil record.fetch("reviewer")
    assert_equal 1, record.fetch("authoredInputCount")
    assert_equal 1, record.fetch("generatedInputCount")
    assert record.fetch("authoredInputsExactlyMatchMainTargetSources")
    entries = record.fetch("fileList").fetch("entries")
    assert_equal %w[authored generated], entries.map { |entry| entry.fetch("kind") }
    assert QuakeSignalIOSScreenshotSwiftInputs.validate(
      record,
      source_record: @source_record,
      source_commit: COMMIT,
      architecture: @arch,
    )
  end

  def test_rejects_unbound_or_external_swift_inputs
    @authored.write("mutated\n")
    assert_error(/bytes differ/) { build_record }

    @authored.write("struct Main {}\n")
    external = @root.join("external.swift")
    external.write("external\n")
    @raw_list.write("#{external}\n#{@generated}\n")
    assert_error(/escaped archived source/) { build_record }
  end

  def test_rejects_missing_log_binding_and_normalized_mutation
    @log.write("no file-list proof\n")
    assert_error(/does not bind/) { build_record }

    @log.write("SwiftDriver ... #{@raw_list}\n")
    record = build_record
    record.fetch("fileList").fetch("entries").first["file"] = "ios/QuakeSignal/App/Other.swift"
    assert_error(/absent from source manifest/) do
      QuakeSignalIOSScreenshotSwiftInputs.validate(
        record,
        source_record: @source_record,
        source_commit: COMMIT,
        architecture: @arch,
      )
    end
  end

  def test_rejects_missing_authored_input_from_main_target_sources
    @raw_list.write("#{@generated}\n")
    assert_error(/authored inputs|PBXSources/) { build_record }
  end

  def test_rejects_duplicate_json_keys
    duplicate = @root.join("duplicate.json")
    duplicate.write('{"sourceCommit":"a","sourceCommit":"b"}')
    assert_error(/duplicate Swift input evidence JSON key/) do
      QuakeSignalIOSScreenshotSwiftInputs.parse_object(duplicate, "duplicate")
    end
  end

  private

  def build_record
    QuakeSignalIOSScreenshotSwiftInputs.record(
      source_commit: COMMIT,
      build_source_evidence: @source,
      build_log: @log,
      derived_data: @derived,
      build_ios_root: @build_root,
      architecture: @arch,
    )
  end

  def assert_error(pattern)
    error = assert_raises(QuakeSignalIOSScreenshotSwiftInputs::Error) { yield }
    assert_match pattern, error.message
  end
end
