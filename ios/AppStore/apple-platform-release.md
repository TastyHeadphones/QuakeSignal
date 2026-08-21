# Coordinated Apple platform release 1.1 (8)

This runbook covers the protected archive automation for the native Apple
targets. It prepares uploads; it does not authorize an App Store submission or
public release.

| Store surface | Scheme | Bundle ID | Upload lane |
| --- | --- | --- | --- |
| iPhone and iPad | `QuakeSignal` | `com.quakesignal.app` | `.github/workflows/ios.yml` |
| Apple Watch companion | `QuakeSignalWatch` | `com.quakesignal.app.watchkitapp` | Embedded in the `QuakeSignal` iOS IPA |
| Apple TV | `QuakeSignalTV` | `com.quakesignal.app` | `.github/workflows/apple-platforms.yml`, select `tvos` |
| Apple Vision Pro | `QuakeSignalVision` | `com.quakesignal.app` | `.github/workflows/apple-platforms.yml`, select `visionos` |
| Mac Catalyst | `QuakeSignal` | `com.quakesignal.app` | `.github/workflows/apple-platforms.yml`, select `maccatalyst` |

The native TV, Vision, and Mac Catalyst uploads use the existing shared App
Store Connect record (Apple ID `6800642443`) and matching bundle ID. Watch
metadata and screenshots belong to that record; there is no separate Watch
IPA. The selected public Mac route is the Swift-native Catalyst build, not the
separate Tauri product (`com.quakesignal.desktop`, Apple ID `6800642853`) and
not the iPhone/iPad binary offered as Designed for iPad on Mac. Leave the
separate Tauri record and its historical evidence unchanged.
Use [`platforms/`](./platforms/) for reviewed copy and screenshot plans. The
current saved portal state, remaining contradictions, and non-destructive action order are recorded in
[`app-store-connect-portal-audit-2026-08-22.md`](./app-store-connect-portal-audit-2026-08-22.md).

## Version contract

All four Xcode targets use marketing version `1.1` and coordinated integer
build `8`. The checked-in XcodeGen project, generated project, four Info.plists,
workflow defaults, and Worker App Attest allow-list must agree before any
signing secret is materialized. Never reuse build `7` after adding the embedded
Watch product.

Run the offline contract before requesting a protected archive:

```sh
node --test .github/scripts/verify-ios-release-contract.test.mjs
node .github/scripts/verify-ios-release-contract.mjs --build-number 8
```

## Xcode Cloud protected native release workflow

Action-time portal inspection on 2026-08-22 shows no configured QuakeSignal
workflow or build history; App Store Connect remains on the initial screen that
requires creating the first workflow in Xcode. Under this release's no-local-
Xcode/build constraint, the workflow described below is a future configuration
specification, not an available lane. Use the protected GitHub workflows in
this runbook for build 8 unless an initial Xcode Cloud workflow is created by an
authorized release owner outside this run.

Configure exactly one Xcode Cloud workflow named
`QuakeSignal 1.1 (8) Native Release`. A single workflow is required because
Xcode Cloud assigns one `CI_BUILD_NUMBER` to the build; separate
workflows could silently assign different bundle versions to the native
products.

Xcode Cloud starts build numbering at `1`, and Apple may not expose the
Build Number setting until **Start using Xcode Cloud** has completed once.
Treat that first run as onboarding only: do not enable distribution or grant a
release approval. If it reaches these hooks as an Archive action, the
checked-in gate intentionally rejects build `1` before Xcode builds or signs
the app. After onboarding, open App Store Connect → Xcode Cloud → Settings →
Build Number, set the next build to exactly `8`, finish the exact workflow
configuration below, and start a fresh manual build. Do not use **Rebuild**:
the guard rejects `manual_rebuild` and accepts only a new manual build `8`.
Retain the bootstrap log's `CI_PRODUCT_ID` and `CI_WORKFLOW_ID` as release
evidence; these opaque IDs are created by Apple during onboarding and therefore
cannot be pinned in the pre-onboarding source. Set both observed values as the
protected workflow variables described below. Every gated run requires both
system IDs to equal their pins and requires the exact Xcode Cloud product name
`QuakeSignal` and workflow name.

The 2026-08-20 account audit confirmed that the explicit Watch identifier
`com.quakesignal.app.watchkitapp` is registered on team `5TT564H883` and that
the checked-in Release settings select automatic signing with every
`QUAKESIGNAL_*_PROFILE_NAME` variable absent. Automatic-signing resolution for
all four native Archive actions remains unproven until Xcode Cloud is onboarded
and a signed build `8` completes. Keep those profile-name variables absent in
Xcode Cloud; they are manual-signing inputs for the separate GitHub fallback
lanes, not Xcode Cloud requirements.

The workflow must have no push, pull-request, tag, or schedule start condition.
Start it manually from the protected `main` source commit and add these four
Archive actions:

| Archive action | Scheme | Destination/product | Signed artifact requirement |
| --- | --- | --- | --- |
| iPhone/iPad + Watch | `QuakeSignal` | iOS | App Store-signed iOS app containing exactly one `QuakeSignalWatch.app` |
| Mac Catalyst | `QuakeSignal` | macOS → Mac Catalyst | App Store-signed native Mac app with the shared bundle ID, sandbox, outbound networking, and foreground location entitlement; no embedded Watch or alert-registration entitlements |
| Apple TV | `QuakeSignalTV` | tvOS | App Store-signed tvOS app |
| Apple Vision Pro | `QuakeSignalVision` | visionOS | App Store-signed visionOS app |

Do not add a `QuakeSignalWatch` Archive action. The Watch product is delivered
only inside the iOS artifact, and the post-build verifier rejects a missing,
additional, or independently substituted Watch bundle.

For the final build-8 workflow, set **Deployment Preparation** to
**TestFlight and App Store** on all four Archive actions. Eligibility alone
does not upload a build. Add a **TestFlight Internal Testing** post-action for
each archived product and target only the existing internal group
`QuakeSignal Internal QA`. Do not select external testers, external groups, or
any App Review/App Store submission action. The build-1 onboarding workflow must have
no distribution post-action (and should use no distribution preparation), so
its intentionally rejected bootstrap cannot reach testers.

The repository hooks cannot inspect Xcode Cloud's server-side workflow graph.
Before starting build 8, retain a portal screenshot or App Store Connect API
export proving the exact workflow name, restricted editing, clean environment,
four Archive actions and scheme/platform mappings, **TestFlight and App
Store** preparation on each, and the four `QuakeSignal Internal QA`-only
post-actions.
Treat that audit artifact as a required release input; a successful hook log is
not proof that the post-actions were configured.

Set four non-secret custom environment variables on this workflow immediately
before the approved run:

- `QUAKESIGNAL_RELEASE_REF=refs/heads/main`
- `QUAKESIGNAL_RELEASE_COMMIT=<the exact lowercase SHA of approved main>`
- `QUAKESIGNAL_RELEASE_PRODUCT_ID=<the exact CI_PRODUCT_ID retained during onboarding>`
- `QUAKESIGNAL_RELEASE_WORKFLOW_ID=<the exact CI_WORKFLOW_ID retained during onboarding>`

The hooks in `ios/ci_scripts/` fail closed unless Xcode Cloud reports a manual
archive, team `5TT564H883`, build `8`, the exact shared workflow name, and the
reviewed scheme/bundle mapping. In post-clone—while Apple guarantees the source
checkout is available—the gate requires a clean checkout including untracked
files, verifies the exact reviewed GitHub `origin`, and always runs one
non-redirecting `git ls-remote --exit-code` lookup of `refs/heads/main`. HEAD,
remote main, `CI_COMMIT`, and `QUAKESIGNAL_RELEASE_COMMIT` must all be the same
object ID. This remains fail-closed for a shallow checkout and does not trust a
possibly stale local `main` or `origin/main`. Apple-provided HTTP(S) proxy
settings may remain in use, but custom `SSL_CERT_FILE`, `SSL_CERT_DIR`, and
`CURL_CA_BUNDLE` overrides are rejected so a workflow environment edit cannot
substitute an unreviewed trust root for the GitHub or Worker proof.
The hook wrappers run Bash in privileged startup mode, pin system tool paths,
isolate Python imports, and clear inherited `DEVELOPER_DIR`, `SDKROOT`, and
`TOOLCHAINS` before resolving Apple's Python/Git shims. This prevents mutable
workflow environment values from substituting an unreviewed interpreter,
Git client, shell startup file, or SDK toolchain for the release gate.

The post-clone hook also verifies the bounded checked-in version, target, and
Worker App Attest source contract, including fingerprint
`sha256:wQ7bfMyEJST5ySIwLM1Q6HwT4DtbRPR3vanIG-kXCkQ`. The pre- and post-build
hooks are self-contained under `ios/ci_scripts/`: they use only Apple's
documented Python 3 runtime, shell/Xcode tools, environment variables, and
Apple-provided artifact paths. They never assume Node.js or repository source
is present in those later phases. For the iOS action only, both later hooks
wait for the exact `https://quakesignal-api.hopeso.workers.dev` production
origin to become fully ready and run its build-8 remote smoke contract. Mac
Catalyst, tvOS, and visionOS are foreground-only and make no
notification-relay request.

After Xcode finishes, the hook requires a successful `xcodebuild`, marketing
version `1.1`, build `8`, the reviewed host/Watch structure, and no unexpected
nested app or app-extension bundles in the raw `CI_ARCHIVE_PATH`. Apple's raw
archive can still carry development signing before export, so that path is not
required to have a distribution identity. The
`CI_APP_STORE_SIGNED_APP_PATH` export—whether Apple supplies an app, IPA,
export directory, or exported xcarchive layout—must be unambiguous and signed
for TestFlight/App Store distribution with Apple team `5TT564H883`, matching
provisioning platform and application IDs, and the reviewed
production/foreground-only capability split.
For Mac Catalyst, that proof additionally requires a macOS bundle layout,
`CFBundleSupportedPlatforms=MacOSX`, device family `2`, macOS 14.0 minimum,
Weather category, no `LSRequiresIPhoneOS`, an `OSX` App Store profile, and the
exact App Sandbox, outbound-network, and foreground-location entitlements. It
rejects APNs, App Attest, Time Sensitive, Critical Alert, and embedded-Watch
claims for the Mac artifact.
The GitHub manual-signing lane remains stricter and requires the raw archive
and export both to be Apple Distribution-signed.

Apple’s published Xcode Cloud environment reference currently omits visionOS
from `CI_PRODUCT_PLATFORM`. The first Vision action therefore records an
explicit warning for a nonempty, undocumented value other than `visionOS` or
`xrOS`; a missing value or one of Apple's documented non-Vision values fails.
Scheme, workflow, bundle ID, and the exported signed visionOS/xrOS profile
remain hard requirements. Retain that first-run log as release evidence and
update the reviewed diagnostic only after observing Apple’s value. iOS, tvOS,
and Mac Catalyst platform values are documented and must match exactly;
Catalyst uses `CI_PRODUCT_PLATFORM=macOS` and the `QuakeSignal` scheme.

These hooks neither deploy the Worker nor call App Store submission APIs.
Xcode Cloud performs its configured archive/sign/distribution behavior only
after all pre-build gates pass. Do not start the workflow until the hook commit
itself is merged into protected `main`, the native identifiers are registered,
and Xcode Cloud automatic signing resolves both the host and Watch products.
Freeze merges to protected `main` from immediately before the workflow starts
until all four actions finish: every action proves that its pinned commit is
still the live remote `main` tip, so a later merge intentionally stops the run.
Xcode Cloud cannot join the GitHub Actions concurrency lock used by the Worker
release lane, so the release owner must freeze approvals for
`cloudflare-production` deployments from immediately before this workflow
starts until the iOS action's pre/post Worker proofs and all four actions'
artifact checks finish. The iOS before/after smokes detect most accidental
races; they are not a substitute for that protected deployment freeze.

## Protected environment configuration

Xcode Cloud uses Apple-managed automatic signing for all four Archive actions.
Do not add `QUAKESIGNAL_IOS_PROFILE_NAME`,
`QUAKESIGNAL_WATCH_PROFILE_NAME`, `QUAKESIGNAL_TV_PROFILE_NAME`,
`QUAKESIGNAL_VISION_PROFILE_NAME`, or `QUAKESIGNAL_CATALYST_PROFILE_NAME` to
the Cloud workflow; absent values intentionally leave each conditional
`PROVISIONING_PROFILE_SPECIFIER` empty so Xcode Cloud can resolve the registered
identifiers.

The existing protected GitHub environment `ios-app-store-release` is a
separate manual-signing fallback for iOS/Watch, tvOS, visionOS, and Mac
Catalyst. It must contain all selected inputs before those workflows are
dispatched. Ordinary `.github/workflows/ios.yml` CI still gives Catalyst a
credential-free Release compilation gate; only an explicitly approved
`apple-platforms.yml` dispatch may materialize its signing credentials.

Shared certificate and upload configuration:

- Secret `IOS_APP_STORE_CERTIFICATE`
- Secret `IOS_APP_STORE_CERTIFICATE_PASSWORD`
- Secret `APP_STORE_CONNECT_API_KEY` (required only for upload)
- Variable `APP_STORE_CONNECT_API_KEY_ID` (required only for upload)
- Variable `APP_STORE_CONNECT_API_ISSUER` (required only for upload)
- Variable `CLOUDFLARE_WORKER_URL`, exactly
  `https://quakesignal-api.hopeso.workers.dev` (used by the iOS lane only)

Target profiles:

- Secret `IOS_APP_STORE_PROVISIONING_PROFILE` and variable
  `IOS_APP_STORE_PROFILE_NAME`
- Secret `WATCHOS_APP_STORE_PROVISIONING_PROFILE` and variable
  `WATCHOS_APP_STORE_PROFILE_NAME`
- Secret `TVOS_APP_STORE_PROVISIONING_PROFILE` and variable
  `TVOS_APP_STORE_PROFILE_NAME`
- Secret `VISIONOS_APP_STORE_PROVISIONING_PROFILE` and variable
  `VISIONOS_APP_STORE_PROFILE_NAME`
- Secret `MACCATALYST_APP_STORE_PROVISIONING_PROFILE` and variable
  `MACCATALYST_APP_STORE_PROFILE_NAME`
- Secrets `MACCATALYST_APP_STORE_INSTALLER_CERTIFICATE` and
  `MACCATALYST_APP_STORE_INSTALLER_CERTIFICATE_PASSWORD` for the base64-encoded
  Mac Installer Distribution `.p12`
- Variable `MACCATALYST_APP_STORE_INSTALLER_IDENTITY`, the exact imported
  `Mac Installer Distribution: … (5TT564H883)` or legacy
  `3rd Party Mac Developer Installer: … (5TT564H883)` identity

Apple Developer portal state recorded on 2026-08-22:

- `QuakeSignal App Store Release` — iOS host
- `QuakeSignal Watch App Store Release` — embedded Watch app
- `QuakeSignal tvOS App Store Release` — tvOS app
- `QuakeSignal visionOS App Store Release` — visionOS app
- `QuakeSignal Mac Catalyst App Store Release` — Mac Catalyst app

All five profiles authorize the intended QuakeSignal identifiers, use the
current UniSphereco LLC Distribution certificate, and expire on 2027-08-12.
The four newly generated profiles were downloaded from the portal. This portal
state does not prove that their base64 contents or exact names have been added
to the protected GitHub environment; keep that environment-configuration gate
open until a protected workflow confirms each selected profile.

The Watch profile must authorize `com.quakesignal.app.watchkitapp`; the host,
TV, Vision, and Catalyst profiles authorize `com.quakesignal.app` for their
respective platforms. Xcode Cloud resolves those profiles automatically; the
manual profile names above apply only to the GitHub fallback. The signed
verifier checks team, application ID, platform, build number,
certificate/profile coherence, and the exact signed capability policy. The
Catalyst fallback additionally requires a Mac App Store provisioning profile
whose leaf certificate matches the imported Apple Distribution identity. Its
exported `.pkg` must have a trusted, exact-team installer signature; a safe
single-app payload without installer scripts or symlinks; readable/searchable
BOM permissions; and the same verified inner-app metadata, profile, signature,
resources, and entitlements as the archive. iOS
alone requires the reviewed production APS, App Attest, and Time Sensitive
Notification entitlements. Mac Catalyst, TV, Vision, and Watch are
foreground-only and must not claim them. This Vision split follows Apple's
published
[visionOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-visionos/),
which lists App Attest but not Push Notifications or Time Sensitive
Notifications.

## CI and archive commands

Ordinary push and pull-request CI performs credential-free generic Release
builds for iOS/iPadOS, Mac Catalyst, tvOS, visionOS, and watchOS with
`CODE_SIGNING_ALLOWED=NO`. Catalyst uses the `QuakeSignal` scheme and exact
destination `generic/platform=macOS,variant=Mac Catalyst`. Hosted runners
install the selected Xcode platform component first because tvOS, watchOS, and
visionOS components are not guaranteed to be preinstalled.

The GitHub release workflows remain a separately protected fallback and
archive-evidence lane. They are manual-only for signed artifacts. Their signing jobs
also require protected `main`, the protected environment, exactly one of
`archive_only` or `upload_to_testflight`, and the shared non-cancelling Worker
policy lock. Do not dispatch these commands until the Worker build-8 policy and
profiles are approved:

```sh
QUAKESIGNAL_REPOSITORY=TastyHeadphones/QuakeSignal
QUAKESIGNAL_SOURCE_COMMIT="$(
  gh api "repos/$QUAKESIGNAL_REPOSITORY/commits/main" --jq .sha
)"
test "${#QUAKESIGNAL_SOURCE_COMMIT}" -eq 40
case "$QUAKESIGNAL_SOURCE_COMMIT" in
  *[!0-9a-f]*) echo "main is not a full lowercase Git SHA" >&2; exit 1 ;;
esac

gh workflow run ios.yml --ref main \
  --repo "$QUAKESIGNAL_REPOSITORY" \
  -f archive_only=true \
  -f upload_to_testflight=false \
  -f build_number=8 \
  -f source_commit="$QUAKESIGNAL_SOURCE_COMMIT"

gh workflow run apple-platforms.yml --ref main \
  --repo "$QUAKESIGNAL_REPOSITORY" \
  -f platform=tvos \
  -f archive_only=true \
  -f upload_to_testflight=false \
  -f build_number=8 \
  -f source_commit="$QUAKESIGNAL_SOURCE_COMMIT"

gh workflow run apple-platforms.yml --ref main \
  --repo "$QUAKESIGNAL_REPOSITORY" \
  -f platform=visionos \
  -f archive_only=true \
  -f upload_to_testflight=false \
  -f build_number=8 \
  -f source_commit="$QUAKESIGNAL_SOURCE_COMMIT"

gh workflow run apple-platforms.yml --ref main \
  --repo "$QUAKESIGNAL_REPOSITORY" \
  -f platform=maccatalyst \
  -f archive_only=true \
  -f upload_to_testflight=false \
  -f build_number=8 \
  -f source_commit="$QUAKESIGNAL_SOURCE_COMMIT"
```

The four archive-only dispatches are optional signing rehearsals. Once the exact
source, Worker build-8 policy, distribution profiles/certificates/API-key
configuration, and store-complete icon catalogs pass their gates, repeat the
four commands with `archive_only=false` and `upload_to_testflight=true`.
Do this before TestFlight/physical-platform QA and signed screenshot comparison:
the protected upload creates the builds those checks need. It does **not** select
or attach a build to version `1.1`, add anything to App Review, submit a version,
or choose a release mode. Those actions remain blocked on the later QA,
screenshot, metadata, privacy, legal, and approval gates.

Archive-only runs never contact App Store Connect and are not accepted by the
screenshot finalizer as signed release evidence.
Each protected lane exports and verifies exactly one regular, non-symlink
artifact and records its SHA-256 digest. Because this repository is public, the
workflows never upload the signed iOS, tvOS, or visionOS `.ipa` files or the
Catalyst `.pkg` as GitHub Actions artifacts. An archive-only run therefore
retains a 30-day machine-readable attestation and digest, not the binary. With explicit upload
consent, the lane rehashes, validates, and directly uploads the same binary
with shared Apple ID
`6800642443`, `com.quakesignal.app` bundle ID, marketing version `1.1`, and the
selected build number. The iOS/Watch host uses `ios`, Catalyst uses `macos`, and
the tvOS and visionOS lanes use `appletvos` and `visionos`, respectively.
A successful upload starts Apple's asynchronous processing; it is not evidence
that the build is processed, selectable, attached to version `1.1`, or
submitted for review.
Only the four successful upload runs (one combined iOS/iPadOS+embedded-Watch
run, plus tvOS, visionOS, and Mac Catalyst) are eligible for the finalizer. Each
attestation binds its immutable protected-main head SHA, run ID/attempt,
workflow, product version/build, platform set, artifact kind/hash, and upload
mode. Preserve the four canonical run URLs/IDs; iOS/iPadOS and watchOS must use
the same combined run and IPA evidence.

## Distribution blockers outside workflow automation

- The layered Vision icon, Apple TV brand/top-shelf assets, and flattened
  Watch catalog are structurally complete. The Watch input deliberately uses
  the canonical signal artwork (SHA-256
  `b792fccc4c08645fb6485ab96c1882c069229246162b02ebdbb605157a5bc65f`):
  its foreground remains at least 128 px inside the circular-mask radius and
  the listing validator pins its catalog, vector geometry, color profile, and
  opacity. Obtain named visual approval against that exact digest; do not
  invent divergent Watch artwork merely to make it different.
- Capture and hash screenshots from the frozen build-8 binaries at Apple’s
  accepted sizes. The Mac source-only plan is
  [`platforms/maccatalyst/screenshot-manifest-v1.1-build8.json`](./platforms/maccatalyst/screenshot-manifest-v1.1-build8.json):
  five unapproved `2560 × 1600` frames from a `1280 × 800` point window at 2×,
  using the exact `maccatalyst-*`
  selectors. Existing Tauri screenshots cannot serve as Catalyst evidence.
- Preserve every existing screenshot tree as historical evidence. Dispatch
  `apple-platform-screenshots.yml` once at the exact protected-main source and
  use its successful run ID only if it contains the exact five expected
  candidate artifacts. After named visual, privacy, and signed-parity review,
  dispatch `apple-screenshot-release-ready.yml` with that run ID, the full
  source SHA, four exact successful upload-run IDs, and the three real review
  completion times. It creates one
  indivisible 26-frame package in an external hosted evidence root while the
  checked-in `screenshot-set-index-v1.1-build8.json` remains pending. The
  protected handoff must run:

  ```sh
  set -euo pipefail
  QUAKESIGNAL_REPOSITORY=TastyHeadphones/QuakeSignal
  QUAKESIGNAL_CAPTURE_DISPATCH_OUTPUT="$(
    gh workflow run apple-platform-screenshots.yml \
      --repo "$QUAKESIGNAL_REPOSITORY" \
      --ref main 2>&1
  )"
  printf '%s\n' "$QUAKESIGNAL_CAPTURE_DISPATCH_OUTPUT"
  QUAKESIGNAL_CAPTURE_RUN_URL="$(
    printf '%s\n' "$QUAKESIGNAL_CAPTURE_DISPATCH_OUTPUT" |
      /usr/bin/sed -nE \
        's#^.*(https://github\.com/TastyHeadphones/QuakeSignal/actions/runs/[1-9][0-9]*).*$#\1#p'
  )"
  QUAKESIGNAL_CAPTURE_RUN_ID="$(
    printf '%s\n' "${QUAKESIGNAL_CAPTURE_RUN_URL##*/}"
  )"
  case "$QUAKESIGNAL_CAPTURE_RUN_ID" in
    ""|0|*[!0-9]*) echo "capture dispatch did not return one positive run ID" >&2; exit 1 ;;
  esac
  test "$QUAKESIGNAL_CAPTURE_RUN_URL" = \
    "https://github.com/$QUAKESIGNAL_REPOSITORY/actions/runs/$QUAKESIGNAL_CAPTURE_RUN_ID"

  gh run watch "$QUAKESIGNAL_CAPTURE_RUN_ID" \
    --repo "$QUAKESIGNAL_REPOSITORY" \
    --exit-status

  QUAKESIGNAL_CAPTURE_RUN_FIELDS="$(
    gh run view "$QUAKESIGNAL_CAPTURE_RUN_ID" \
      --repo "$QUAKESIGNAL_REPOSITORY" \
      --json databaseId,url,headSha,event,headBranch,conclusion \
      --jq '[.databaseId,.url,.headSha,.event,.headBranch,.conclusion] | @tsv'
  )"
  IFS=$'\t' read -r QUAKESIGNAL_VIEW_RUN_ID QUAKESIGNAL_VIEW_RUN_URL \
    QUAKESIGNAL_SOURCE_COMMIT QUAKESIGNAL_CAPTURE_EVENT \
    QUAKESIGNAL_CAPTURE_BRANCH QUAKESIGNAL_CAPTURE_CONCLUSION \
    <<< "$QUAKESIGNAL_CAPTURE_RUN_FIELDS"
  test "$QUAKESIGNAL_VIEW_RUN_ID" = "$QUAKESIGNAL_CAPTURE_RUN_ID"
  test "$QUAKESIGNAL_VIEW_RUN_URL" = "$QUAKESIGNAL_CAPTURE_RUN_URL"
  test "$QUAKESIGNAL_CAPTURE_EVENT" = workflow_dispatch
  test "$QUAKESIGNAL_CAPTURE_BRANCH" = main
  test "$QUAKESIGNAL_CAPTURE_CONCLUSION" = success
  test "${#QUAKESIGNAL_SOURCE_COMMIT}" -eq 40
  case "$QUAKESIGNAL_SOURCE_COMMIT" in
    *[!0-9a-f]*) echo "capture run headSha is not a full lowercase Git SHA" >&2; exit 1 ;;
  esac

  # Replace these placeholders with the four exact successful upload-run IDs,
  # canonical UTC review completion times, and the GitHub login that will
  # approve ios-app-store-release. iOS/iPadOS and watchOS intentionally share
  # one combined signed-run ID.
  QUAKESIGNAL_IOS_WATCH_SIGNED_RUN_ID='<positive-run-id>'
  QUAKESIGNAL_TVOS_SIGNED_RUN_ID='<positive-run-id>'
  QUAKESIGNAL_VISIONOS_SIGNED_RUN_ID='<positive-run-id>'
  QUAKESIGNAL_MACCATALYST_SIGNED_RUN_ID='<positive-run-id>'
  QUAKESIGNAL_VISUAL_REVIEWED_AT='<YYYY-MM-DDTHH:MM:SSZ>'
  QUAKESIGNAL_PRIVACY_REVIEWED_AT='<YYYY-MM-DDTHH:MM:SSZ>'
  QUAKESIGNAL_SIGNED_PARITY_REVIEWED_AT='<YYYY-MM-DDTHH:MM:SSZ>'
  QUAKESIGNAL_APPROVED_REVIEWER_LOGIN='<approved-environment-reviewer-login>'
  QUAKESIGNAL_SIGNED_RELEASE_EVIDENCE_JSON="$(
    jq -cn \
      --argjson ios "$QUAKESIGNAL_IOS_WATCH_SIGNED_RUN_ID" \
      --argjson tvos "$QUAKESIGNAL_TVOS_SIGNED_RUN_ID" \
      --argjson visionos "$QUAKESIGNAL_VISIONOS_SIGNED_RUN_ID" \
      --argjson maccatalyst "$QUAKESIGNAL_MACCATALYST_SIGNED_RUN_ID" \
      --arg visual "$QUAKESIGNAL_VISUAL_REVIEWED_AT" \
      --arg privacy "$QUAKESIGNAL_PRIVACY_REVIEWED_AT" \
      --arg parity "$QUAKESIGNAL_SIGNED_PARITY_REVIEWED_AT" \
      '{signedRunIds:{"ios-ipados":$ios,tvos:$tvos,watchos:$ios,visionos:$visionos,maccatalyst:$maccatalyst},reviewedAtUtc:{visual:$visual,privacy:$privacy,signedReleaseParity:$parity}}'
  )"

  gh workflow run apple-screenshot-release-ready.yml \
    --repo "$QUAKESIGNAL_REPOSITORY" \
    --ref main \
    -f capture_run_id="$QUAKESIGNAL_CAPTURE_RUN_ID" \
    -f source_commit="$QUAKESIGNAL_SOURCE_COMMIT" \
    -f visual_reviewer="$QUAKESIGNAL_APPROVED_REVIEWER_LOGIN" \
    -f visual_review_approved=true \
    -f privacy_reviewer="$QUAKESIGNAL_APPROVED_REVIEWER_LOGIN" \
    -f privacy_review_approved=true \
    -f signed_parity_reviewer="$QUAKESIGNAL_APPROVED_REVIEWER_LOGIN" \
    -f signed_release_parity_approved=true \
    -f signed_release_evidence="$QUAKESIGNAL_SIGNED_RELEASE_EVIDENCE_JSON"
  ```

  The capture dispatch must return one canonical run URL; absence or ambiguity
  is a stop condition. Never pre-read moving `main` or select a subsequently
  listed run. Watch the returned positive run ID, then derive and validate
  its exact `headSha`, event, branch, URL, and successful conclusion with
  `gh run view`. The finalizer independently rechecks that run, its canonical
  repository, and all five artifact identities before and after download.

  Inside the protected finalizer, the strict verifier invocation is:

  ```sh
  ruby .github/scripts/verify-store-assets.rb \
    --require-build8-screenshot-release-ready \
    --expected-source-commit=<40-character-source-commit> \
    --screenshot-release-evidence-root="$EVIDENCE_ROOT"
  ```

  That command must not pass without exact-current product source and plan
  bytes, all five platform packages, the exact successful capture-run binding,
  four exact successful signed-upload runs, and separate named
  visual/privacy/signed-parity approvals. Only one
  three-day screenshot artifact is retained; signed `.ipa`/`.pkg` binaries and
  generated screenshots are never committed or uploaded by this handoff.
  The finalizer downloads only the four small attestation artifacts and derives
  all four distinct binary hashes from them; it never downloads an IPA or PKG.
  It requires the iOS/iPadOS and watchOS entries to share one combined run and
  IPA hash. The canonical `ios-app-store-release` environment must require an
  independent reviewer and prevent self-review. The job queries its own
  canonical run approval history and requires every supplied reviewer identifier
  to equal an approved GitHub login distinct from the dispatch actor. Generic
  placeholders, archive-only attestations, fabricated/future review times, or
  fewer/more than four distinct successful upload runs are stop conditions.
- Exercise iOS/iPadOS notifications and App Attest on physical hardware or
  TestFlight. Simulator/generic builds are not evidence for APNs, App Attest,
  background delivery, Focus, Silent Mode, or alert sounds.
- Exercise Catalyst and Vision foreground/local monitoring, maps, location,
  and selected alert sounds; TV focus/remote behavior; and Watch foreground
  warning UI, native warning haptic, custom audio, iPhone-preference mirroring,
  Crown/scroll behavior, and scene-deactivation audio stop on their actual
  platforms. Do not claim Catalyst, Vision, TV, or Watch background
  notification delivery.
- In App Store Connect, explicitly clear **Make this app available** under the
  iPhone/iPad-on-Apple-silicon-Mac availability controls. The checked-in
  `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD=NO` removes the competing Xcode
  destination but does not prove the portal availability setting was cleared.
- Complete content-rights, privacy, export, age-rating, review-contact, and
  platform-metadata approvals before submission.

The App Store Connect audit found platform drafts in Apple ID `6800642443`.
Reuse the existing native drafts and change an editable version number to
`1.1` only after the corresponding build-8 release evidence is frozen. Do not
delete a draft or create a duplicate platform. The macOS platform on this
shared record is now reserved for the `com.quakesignal.app` Catalyst archive.
Do not attach the separate Tauri package (`com.quakesignal.desktop`) to it;
leave Tauri Apple ID `6800642853` unchanged.

The existing 30-image iPhone/iPad provenance records build 7 and remains
historical evidence. A separate ten-image English iPhone/iPad build-8 Debug
Simulator candidate has now been captured with exact source/build provenance,
but it predates the current JMA-only/Mac Catalyst source changes and is now
historical, unsigned, reviewer-null, and not approved for upload. A separate
source-frozen native capture now preserves three tvOS frames at
`1920 × 1080`, five visionOS frames at `3840 × 2160`, and three Watch frames
at `410 × 502`, together with their full unapproved provenance under
`platforms/screenshot-candidates-v1.1-build8/`. No native-platform screenshot
is approved, and the b461 native capture must not be treated as current-source
evidence. The Catalyst plan adds five source-defined native PNG frames at
`2560 × 1600`, captured from a `1280 × 800` logical window at 2×, but no
Catalyst PNG has been captured or validated yet. Signed
build evidence, a complete final-commit recapture, and named release-owner
review remain pending for every native platform screenshot set.
