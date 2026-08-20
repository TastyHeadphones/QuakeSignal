# Unapproved native screenshot candidates — 1.1 (8)

These three directories are byte-for-byte copies of the successful artifacts
from GitHub Actions run
[`32347549322`](https://github.com/TastyHeadphones/QuakeSignal/actions/runs/32347549322),
captured from source commit
`b461083bb5bff21eb4f1f4a8b5ef8f0764d89dd2`.

They contain 3 tvOS, 3 watchOS, and 5 visionOS Debug Simulator PNGs plus the
complete per-frame, aggregate, runtime, and candidate metadata emitted by the
credential-free capture workflow. Preserve the exact package names and file
bytes: their SHA-256 chains depend on both.

Every package remains explicitly unapproved. `uploadApproved` is `false`,
`reviewer` and Release-binary evidence are `null`, and no file here may be
uploaded to App Store Connect until a named reviewer completes visual review
and the release runbook's signed-artifact parity gate. The adjacent platform
manifests remain immutable capture plans; their pending/null values are
intentional because these packages hash those exact plan bytes.

Run the fail-closed validator before review or handoff:

```sh
ruby .github/scripts/verify-native-apple-screenshot-candidates.rb
```

`capture-run-receipt.json` records the original artifact IDs, archive digests,
expiration dates, and deterministic extracted-content digests. The original
GitHub ZIPs are not committed to this repository.
