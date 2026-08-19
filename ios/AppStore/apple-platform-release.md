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

The native TV and Vision uploads use the existing iOS App Store Connect record
(Apple ID `6800642443`) and matching bundle ID. Watch metadata and screenshots
belong to that iOS record; there is no separate Watch IPA. The Tauri Mac app
uses its existing separate record and `.github/workflows/desktop-release.yml`.
Use [`platforms/`](./platforms/) for reviewed copy and screenshot plans. The
portal state, completed draft preparation, and non-destructive action order are
recorded in
[`app-store-connect-portal-audit-2026-08-19.md`](./app-store-connect-portal-audit-2026-08-19.md).

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

Configure exactly one Xcode Cloud workflow named
`QuakeSignal 1.1 (8) Native Release`. A single workflow is required because
Xcode Cloud assigns one `CI_BUILD_NUMBER` to the build; three separate
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

At the latest App Store Connect verification on 2026-08-19, Xcode Cloud is not
yet onboarded for Apple ID `6800642443`: the portal shows **Create a workflow
in Xcode to get started** and no workflow or build history. That is consistent
with the bootstrap sequence above; it is not evidence that build 8 can be
started yet.

The workflow must have no push, pull-request, tag, or schedule start condition.
Start it manually from the protected `main` source commit and add these three
Archive actions:

| Archive action | Scheme | Destination/product | Signed artifact requirement |
| --- | --- | --- | --- |
| iPhone/iPad + Watch | `QuakeSignal` | iOS | App Store-signed iOS app containing exactly one `QuakeSignalWatch.app` |
| Apple TV | `QuakeSignalTV` | tvOS | App Store-signed tvOS app |
| Apple Vision Pro | `QuakeSignalVision` | visionOS | App Store-signed visionOS app |

Do not add a `QuakeSignalWatch` Archive action. The Watch product is delivered
only inside the iOS artifact, and the post-build verifier rejects a missing,
additional, or independently substituted Watch bundle.

For the final build-8 workflow, set **Deployment Preparation** to
**TestFlight and App Store** on all three Archive actions. Eligibility alone
does not upload a build. Add a **TestFlight Internal Testing** post-action for
each archived product and target only the existing internal group
`InternalQA`. Do not select external testers, external groups, or any App
Review/App Store submission action. The build-1 onboarding workflow must have
no distribution post-action (and should use no distribution preparation), so
its intentionally rejected bootstrap cannot reach testers.

The repository hooks cannot inspect Xcode Cloud's server-side workflow graph.
Before starting build 8, retain a portal screenshot or App Store Connect API
export proving the exact workflow name, restricted editing, clean environment,
three Archive actions and scheme/platform mappings, **TestFlight and App
Store** preparation on each, and the three `InternalQA`-only post-actions.
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
origin to become fully ready and run its build-8 remote smoke contract. tvOS
and visionOS are foreground-only and make no notification-relay request.

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
The GitHub manual-signing lane remains stricter and requires the raw archive
and export both to be Apple Distribution-signed.

Apple’s published Xcode Cloud environment reference currently omits visionOS
from `CI_PRODUCT_PLATFORM`. The first Vision action therefore records an
explicit warning for a nonempty, undocumented value other than `visionOS` or
`xrOS`; a missing value or one of Apple's documented non-Vision values fails.
Scheme, workflow, bundle ID, and the exported signed visionOS/xrOS profile
remain hard requirements. Retain that first-run log as release evidence and
update the reviewed diagnostic only after observing Apple’s value. iOS and
tvOS platform values are documented and must match exactly.

These hooks neither deploy the Worker nor call App Store submission APIs.
Xcode Cloud performs its configured archive/sign/distribution behavior only
after all pre-build gates pass. Do not start the workflow until the hook commit
itself is merged into protected `main`, the native identifiers are registered,
and Xcode Cloud automatic signing resolves both the host and Watch products.
Freeze merges to protected `main` from immediately before the workflow starts
until all three actions finish: every action proves that its pinned commit is
still the live remote `main` tip, so a later merge intentionally stops the run.
Xcode Cloud cannot join the GitHub Actions concurrency lock used by the Worker
release lane, so the release owner must freeze approvals for
`cloudflare-production` deployments from immediately before this workflow
starts until the iOS action's pre/post Worker proofs and all three actions'
artifact checks finish. The iOS before/after smokes detect most accidental
races; they are not a substitute for that protected deployment freeze.

## Protected environment configuration

The existing protected GitHub environment `ios-app-store-release` must contain
all selected signing inputs. An absent or empty value fails the job before
certificate/profile import.

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

The Watch profile must authorize `com.quakesignal.app.watchkitapp`; the host,
TV, and Vision profiles authorize `com.quakesignal.app` for their respective
platforms. The 2026-08-19 portal audit found only the existing iOS App Store
profile and no visionOS profile, so profile creation/resolution remains a
preflight blocker rather than something these scripts can perform. The signed
verifier checks team, profile name, application ID, platform, build number,
certificate/profile coherence, and the exact signed capability policy. iOS
alone requires the reviewed production APS, App Attest, and Time Sensitive
Notification entitlements. TV, Vision, and Watch are foreground-only and must
not claim them. This Vision split follows Apple's published
[visionOS capability table](https://developer.apple.com/help/account/reference/supported-capabilities-visionos/),
which lists App Attest but not Push Notifications or Time Sensitive
Notifications.

## CI and archive commands

Ordinary push and pull-request CI performs credential-free generic Release
builds for all schemes with `CODE_SIGNING_ALLOWED=NO`. Hosted runners install
the selected Xcode platform component first because tvOS, watchOS, and visionOS
components are not guaranteed to be preinstalled.

The GitHub release workflows remain a separately protected fallback and
archive-evidence lane. They are manual-only for signed artifacts. Their signing jobs
also require protected `main`, the protected environment, exactly one of
`archive_only` or `upload_to_testflight`, and the shared non-cancelling Worker
policy lock. Do not dispatch these commands until the Worker build-8 policy and
profiles are approved:

```sh
gh workflow run ios.yml --ref main \
  -f archive_only=true \
  -f upload_to_testflight=false \
  -f build_number=8

gh workflow run apple-platforms.yml --ref main \
  -f platform=tvos \
  -f archive_only=true \
  -f upload_to_testflight=false \
  -f build_number=8

gh workflow run apple-platforms.yml --ref main \
  -f platform=visionos \
  -f archive_only=true \
  -f upload_to_testflight=false \
  -f build_number=8
```

After the signed archives, platform QA, metadata, screenshots, and legal gates
pass, repeat each run with `archive_only=false` and
`upload_to_testflight=true`. Archive-only runs never contact App Store Connect.

## Distribution blockers outside workflow automation

- Create and review store-complete icon assets: layered Vision icon, Apple TV
  brand/top-shelf assets, and Watch icon set. Do not manufacture these by
  blindly reusing the flat iOS icon.
- Capture and hash screenshots from the frozen build-8 binaries at Apple’s
  accepted sizes.
- Exercise iOS/iPadOS notifications and App Attest on physical hardware or
  TestFlight. Simulator/generic builds are not evidence for APNs, App Attest,
  background delivery, Focus, Silent Mode, or alert sounds.
- Exercise Vision foreground/local monitoring and selected alert sounds,
  TV focus/remote behavior, and Watch foreground behavior on their actual
  platforms. Do not claim Vision background notification delivery.
- Complete content-rights, privacy, export, age-rating, review-contact, and
  platform-metadata approvals before submission.

The existing tvOS and visionOS drafts in Apple ID `6800642443` now use version
`1.1`, reviewed English metadata, platform-specific review notes, and manual
release. They still have no selected build or screenshots. Do not delete the
drafts, create duplicate platforms, or add either version for review until its
remaining gates pass. The same record also contains a macOS draft that must not
receive the separate Tauri Mac app (`com.quakesignal.desktop`); leave it
untouched and use Apple ID `6800642853` for Mac 1.1.0.

The existing 30-image iPhone/iPad provenance records build 7 and remains
historical evidence. A separate ten-image English iPhone/iPad build-8 Debug
Simulator candidate has now been captured with exact source/build provenance,
but it is unsigned, reviewer-null, and not approved for upload. tvOS requires a
new `1920 × 1080` set, visionOS requires `3840 × 2160`, and the planned Watch
set uses `410 × 502` consistently. No native-platform screenshot is approved;
signed-build evidence and named release-owner review remain pending.
