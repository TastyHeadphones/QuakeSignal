# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require_relative "verify-store-assets"
require_relative "../../ios/ScreenshotAutomation/screenshot-test-temp-root"

class StoreAssetListingCopyTest < Minitest::Test
  def with_valid_ios_listing
    Dir.mktmpdir(
      "quakesignal-ios-listing-",
      QuakeSignalScreenshotTestTempRoot.path.to_s,
    ) do |directory|
      listing = Pathname.new(directory)
      {
        "description.txt" => "Reviewed earthquake information.\n",
        "promotional_text.txt" => "Review recent earthquake reports.\n",
        "keywords.txt" => "earthquake,reports,safety\n",
        "subtitle.txt" => "Earthquake Safety\n",
        "whats_new_v1.1.txt" => "Version 1.1 adds reviewed Apple platform support.\n",
      }.each do |name, contents|
        listing.join(name).write(contents, mode: "wx")
      end
      yield listing
    end
  end

  def validation_failure(listing)
    validator = StoreAssetValidator.new
    validator.validate_ios_listing_copy(listing)
    _output, error_output = capture_io do
      assert_raises(SystemExit) { validator.finish! }
    end
    error_output
  end

  def test_accepts_nonempty_whats_new_within_the_character_limit
    with_valid_ios_listing do |listing|
      validator = StoreAssetValidator.new
      validator.validate_ios_listing_copy(listing)
      assert_nil validator.finish!
    end
  end

  def test_rejects_missing_oversized_or_blank_whats_new_mutations
    mutations = [
      [
        ->(path) { path.delete },
        /missing or empty file: .*whats_new_v1\.1\.txt/,
      ],
      [
        ->(path) { path.write("x" * (StoreAssetValidator::MAX_WHATS_NEW_CHARACTERS + 1)) },
        /What's New must be at most 4000 characters \(found 4001\)/,
      ],
      [
        ->(path) { path.write(" \n") },
        /What's New must not be blank/,
      ],
    ]

    mutations.each do |mutate, expected_error|
      with_valid_ios_listing do |listing|
        mutate.call(listing.join("whats_new_v1.1.txt"))
        assert_match expected_error, validation_failure(listing)
      end
    end
  end
end

class WatchAppIconContractTest < Minitest::Test
  def repository_root
    Pathname.new(__dir__).join("..", "..").realpath
  end

  def test_accepts_reviewed_watch_icon_catalog_and_geometry
    assert validate_watch_app_icon_contract!(repository_root)
  end

  def test_rejects_catalog_digest_or_icon_composer_supersession
    Dir.mktmpdir(
      "quakesignal-watch-icon-",
      QuakeSignalScreenshotTestTempRoot.path.to_s,
    ) do |directory|
      root = Pathname.new(directory)
      %w[
        assets/app-icon.svg
        ios/project.yml
        ios/QuakeSignal/Assets.xcassets/AppIcon.appiconset/icon-1024.png
        ios/QuakeSignalWatch/Assets.xcassets/WatchAppIcon.appiconset/Contents.json
        ios/QuakeSignalWatch/Assets.xcassets/WatchAppIcon.appiconset/watch-icon-1024.png
      ].each do |relative_path|
        source = repository_root.join(relative_path)
        destination = root.join(relative_path)
        FileUtils.mkdir_p(destination.dirname)
        FileUtils.cp(source, destination)
      end

      root.join("ios/QuakeSignalWatch/Assets.xcassets/WatchAppIcon.appiconset/watch-icon-1024.png")
        .open("ab") { |file| file.write("drift") }
      assert_raises(RuntimeError) { validate_watch_app_icon_contract!(root) }

      FileUtils.cp(
        repository_root.join("ios/QuakeSignalWatch/Assets.xcassets/WatchAppIcon.appiconset/watch-icon-1024.png"),
        root.join("ios/QuakeSignalWatch/Assets.xcassets/WatchAppIcon.appiconset/watch-icon-1024.png"),
      )
      FileUtils.mkdir_p(root.join("ios/QuakeSignal.icon"))
      assert_raises(RuntimeError) { validate_watch_app_icon_contract!(root) }
    end
  end
end

class StoreAssetReleaseApprovalTest < Minitest::Test
  def approved_provenance
    commit = "a" * 40
    {
      "status" => "approved",
      "capture" => { "sourceBaselineCommit" => commit },
      "releaseApproval" => {
        "signedBuildComparison" => "approved",
        "sourceBaselineCommit" => commit,
        "signedArtifactSha256" => "b" * 64,
        "signedBuildComparedAtUtc" => "2026-08-19T01:02:03Z",
        "reviewedAtUtc" => "2026-08-19T02:03:04Z",
        "reviewer" => "Release Owner",
      },
      "currentSet" => { "status" => "signed-build-approved" },
    }
  end

  def copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def test_accepts_complete_signed_build_approval
    assert validate_macos_release_approval!(approved_provenance, expected_source_commit: "a" * 40)
  end

  def test_rejects_pending_or_unfrozen_provenance
    pending = copy(approved_provenance)
    pending["status"] = "pending-signed-mac-app-store-build"
    assert_raises(RuntimeError) { validate_macos_release_approval!(pending) }

    unfrozen = copy(approved_provenance)
    unfrozen["capture"]["sourceBaselineCommit"] = nil
    assert_raises(RuntimeError) { validate_macos_release_approval!(unfrozen) }

    assert_raises(RuntimeError) do
      validate_macos_release_approval!(approved_provenance, expected_source_commit: "c" * 40)
    end
  end

  def test_rejects_incomplete_or_mismatched_signed_build_evidence
    mutations = [
      ->(value) { value["releaseApproval"]["signedBuildComparison"] = "pending" },
      ->(value) { value["releaseApproval"]["sourceBaselineCommit"] = "c" * 40 },
      ->(value) { value["releaseApproval"]["signedArtifactSha256"] = "not-a-digest" },
      ->(value) { value["releaseApproval"]["reviewer"] = "  " },
      ->(value) { value["releaseApproval"]["reviewedAtUtc"] = "2026-08-19T02:03:04+09:00" },
      ->(value) { value["currentSet"]["status"] = "controlled-render-validated" },
    ]

    mutations.each do |mutate|
      provenance = copy(approved_provenance)
      mutate.call(provenance)
      assert_raises(RuntimeError, KeyError, ArgumentError) do
        validate_macos_release_approval!(provenance)
      end
    end
  end
end

class StoreAssetScreenshotReleaseModeTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("..", "..").realpath
  SCRIPT = ROOT.join(".github/scripts/verify-store-assets.rb")

  def test_release_ready_mode_rejects_an_absent_or_different_active_commit
    output, error_output, status = Open3.capture3(
      RbConfig.ruby,
      SCRIPT.to_s,
      "--require-build11-screenshot-release-ready",
      "--expected-source-commit=#{'0' * 40}",
      chdir: ROOT.to_s,
    )

    refute status.success?
    assert_equal "", output
    assert_match(
      /complete active build-11 screenshot release set|active\/expected screenshot source commit/,
      error_output,
    )
  end

  def test_release_ready_mode_accepts_an_external_evidence_root_option
    Dir.mktmpdir("store-asset-release-evidence") do |directory|
      output, error_output, status = Open3.capture3(
        RbConfig.ruby,
        SCRIPT.to_s,
        "--require-build11-screenshot-release-ready",
        "--expected-source-commit=#{'0' * 40}",
        "--screenshot-release-evidence-root=#{directory}",
        chdir: ROOT.to_s,
      )

      refute status.success?
      assert_equal "", output
      refute_match(/Unknown argument/, error_output)
      assert_match(/complete active build-11 screenshot release set/, error_output)
    end
  end
end
