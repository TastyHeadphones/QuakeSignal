# frozen_string_literal: true

require "minitest/autorun"
require_relative "verify-store-assets"

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
