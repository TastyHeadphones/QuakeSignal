#!/usr/bin/ruby
# frozen_string_literal: true

require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "seal-screenshot-capture-package"
require_relative "screenshot-test-temp-root"

class ScreenshotCapturePackageSealTest < Minitest::Test
  COMMIT = "a" * 40

  def test_seals_and_validates_exact_plain_inventory
    with_fixture do |root|
      manifest = seal(root)
      assert_equal 2, manifest.fetch("fileCount")
      assert_equal false, manifest.fetch("uploadApproved")
      assert_nil manifest.fetch("reviewer")
      assert_equal manifest,
                   QuakeSignalScreenshotCapturePackageSeal.validate(
                     platform: "ios-ipados", source_commit: COMMIT, capture_root: root,
                   )
    end
  end

  def test_validation_rejects_tamper_or_extra_file
    with_fixture do |root|
      seal(root)
      root.join("one.txt").write("tampered\n")
      assert_raises(QuakeSignalScreenshotCapturePackageSeal::Error) do
        QuakeSignalScreenshotCapturePackageSeal.validate(
          platform: "ios-ipados", source_commit: COMMIT, capture_root: root,
        )
      end
    end

    with_fixture do |root|
      seal(root)
      root.join("extra.txt").write("extra\n")
      assert_raises(QuakeSignalScreenshotCapturePackageSeal::Error) do
        QuakeSignalScreenshotCapturePackageSeal.validate(
          platform: "ios-ipados", source_commit: COMMIT, capture_root: root,
        )
      end
    end
  end

  def test_refuses_symlink_or_preexisting_manifest
    with_fixture do |root|
      root.join("link").make_symlink(root.join("one.txt"))
      assert_raises(QuakeSignalScreenshotCapturePackageSeal::Error) { seal(root) }
    end

    with_fixture do |root|
      root.join("capture-package-manifest.json").write("{}\n")
      assert_raises(QuakeSignalScreenshotCapturePackageSeal::Error) { seal(root) }
    end
  end

  def test_validation_rejects_duplicate_manifest_keys
    with_fixture do |root|
      seal(root)
      path = root.join("capture-package-manifest.json")
      path.write(
        path.read.sub(
          %Q[  "status": "unapproved-source-addressed-capture-package-manifest",\n],
          %Q[  "status": "unapproved-source-addressed-capture-package-manifest",\n  "status": "unapproved-source-addressed-capture-package-manifest",\n],
        ),
      )
      error = assert_raises(QuakeSignalScreenshotCapturePackageSeal::Error) do
        QuakeSignalScreenshotCapturePackageSeal.validate(
          platform: "ios-ipados", source_commit: COMMIT, capture_root: root,
        )
      end
      assert_match(/duplicate JSON object key "status"/, error.message)
    end
  end

  private

  def with_fixture
    Dir.mktmpdir(
      "quakesignal-capture-seal-test",
      QuakeSignalScreenshotTestTempRoot.path.to_s,
    ) do |directory|
      root = Pathname.new(directory)
      root.join("nested").mkpath
      root.join("one.txt").write("one\n")
      root.join("nested/two.txt").write("two\n")
      yield root
    end
  end

  def seal(root)
    QuakeSignalScreenshotCapturePackageSeal.seal(
      platform: "ios-ipados",
      source_commit: COMMIT,
      capture_root: root,
      output: root.join("capture-package-manifest.json"),
    )
  end
end
