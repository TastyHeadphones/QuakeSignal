# App Store Connect portal audit — 2026-08-20 addendum

This is a read-only record of App Store Connect state observed on 20 August
2026. It supplements, and does not rewrite, the historical
[`2026-08-19 portal audit`](./app-store-connect-portal-audit-2026-08-19.md).
Neither observation is live state. Re-verify the portal immediately before an
authorized action. No App Store Connect field, build, workflow, screenshot, or
submission was changed during this audit.

## Latest observed records

| Apple ID | Record | Read-only observation | Release interpretation |
| --- | --- | --- | --- |
| `6800642443` | QuakeSignal | iOS, tvOS, and visionOS each have an editable `1.1` draft with zero screenshots and no selected build. TestFlight contains historical `1.1 (7)` only; build 8 is absent. An unused macOS `1.0` draft also remains in the record. | This remains the shared native record for iOS/iPadOS, the embedded Watch companion, tvOS, and visionOS. None of its `1.1` platform drafts is release-ready. Do not create a duplicate platform or attach the separate Tauri package to its macOS draft. |
| `6800642853` | QuakeSignal for macOS | macOS `1.0.0` remains an editable draft with four older screenshots and no current signed build. | This remains the canonical record for the separate Tauri app with bundle ID `com.quakesignal.desktop`. The older images are not 1.1.0 signed-build evidence; do not submit them or create another Mac record. |

The 19 August record observed different earlier details, including tvOS and
visionOS draft version numbers and an older Mac build. Preserve that history.
For current release planning, use the later facts above: the shared native
platform drafts already show `1.1`, build 8 is not present, and neither record
has a current signed release candidate selected.

## Incomplete and contradictory portal fields

- **Content Rights:** the shared record currently displays **Yes**, but no
  affirmative written Wolfx permission or separately required underlying-source
  permission is retained. This is a portal/evidence contradiction, not a
  completed gate. Do not preserve, copy, or rely on the affirmative selection;
  keep certification and every submission blocked until
  [`content-rights-evidence.md`](./content-rights-evidence.md) is complete and
  reviewed.
- **App Review contact:** the accountable contact name, email, and phone remain
  missing. Enter them only from a release-owner-approved contact record.
- **Apple TV Privacy Policy:** the required tvOS text field is blank. The local
  draft is not legal approval and must not be copied until it is reviewed and
  consistent with the current published policy.
- **Vision App Motion:** the field displays **Set Up**. Treat the App Motion
  answer as incomplete until final-platform QA and release-owner review support
  the exact selection.
- **Xcode Cloud:** the record still displays **Create a workflow in Xcode to get
  started** and has no workflow or build history. Xcode Cloud is not onboarded;
  there is no product/workflow ID evidence and no Xcode Cloud build-8 archive.
- **Screenshots and builds:** all three shared `1.1` platform drafts have zero
  screenshots and no selected build. Local Debug Simulator candidates remain
  unapproved source evidence only, not portal-ready assets or signed-release
  proof.

## Unresolved Mac distribution choice

The release owner must explicitly choose whether the shared iPhone/iPad code
path is offered on Mac as **Mac Catalyst** or as **Designed for iPad on Mac**.
Do not silently choose one, describe both as simultaneous public variants, or
infer the answer from `SUPPORTS_MACCATALYST`, a successful Catalyst logic test,
or the unused macOS draft. The separate native Tauri app remains a different
product in Apple ID `6800642853` regardless of this choice.

Record the selected shared-record route, customer-visible scope, profile and
signing consequences, Mac QA, availability, screenshots, metadata, and review
ownership before changing either record. Recommendation: make no App Store
Connect mutation in either record until this choice is recorded and its portal
mapping has been reviewed. In particular, leave the shared record's macOS
`1.0` draft untouched and do not attach a Catalyst or Tauri artifact to it.

## Gates that remain open

| Gate | 2026-08-20 status | Required evidence before portal use |
| --- | --- | --- |
| Content rights and underlying sources | **PENDING / SUBMISSION BLOCKER** | Affirmative written permission, complete scope review, and a reviewed evidence reference |
| Coordinated native build 8 | **PENDING** | Frozen source plus protected, signed iOS+Watch, tvOS, and visionOS build-8 artifacts; TestFlight build 7 is historical only |
| Xcode Cloud | **NOT ONBOARDED** | Manual Xcode onboarding, retained product/workflow IDs, reviewed workflow graph, exact protected-main commit, and successful gated build 8 |
| Signing and profiles | **PENDING** | Target-specific distribution profiles, signed-artifact hashes, entitlement/profile verification, and embedded Watch validation |
| Screenshots | **PENDING** | Source-current recapture where required, signed-Release parity, immutable hashes/provenance, and named visual approval; portal currently contains none for the shared 1.1 drafts |
| Physical and platform QA | **PENDING** | iPhone/iPad App Attest/APNs/Focus/Silent Mode/location evidence plus actual Watch, TV, Vision, and selected Mac-route QA |
| Production service parity | **PENDING** | The current protected-main Worker, migration/policy fingerprint, legal pages, public TLS, health/readiness proof, and approved production deployment |
| Review metadata | **PENDING** | Accountable review contact, reviewed tvOS Privacy Policy text, final Vision App Motion answer, privacy/age/export answers, and platform-specific notes |
| Native Tauri macOS 1.1.0 | **PENDING** | Current signed sandboxed package, source/hash evidence, physical Mac behavior proof, signed-build screenshot comparison, and named approval |
| Shared-record Mac route | **PENDING RELEASE-OWNER CHOICE** | A recorded Mac Catalyst-versus-Designed-for-iPad-on-Mac decision and reviewed portal mapping |

None of these gates is satisfied by an editable draft, a successful unsigned
build, a Debug Simulator screenshot, an historical TestFlight build, a prior
portal answer, or an old signed artifact.

## Safe handoff

1. Preserve both dated audits and take a new read-only portal snapshot at
   action time. Do not delete, duplicate, or repurpose a draft.
2. Record the Mac Catalyst-versus-Designed-for-iPad-on-Mac decision before any
   portal mutation.
3. Complete rights, current production, Xcode Cloud onboarding, profiles,
   signed archives, screenshots, named review, and physical/platform QA.
4. Reconcile every portal field with the exact signed candidate. Correct the
   Content Rights contradiction only from reviewed written evidence, not from
   the current **Yes** value.
5. Only a named release owner may authorize build attachment, metadata entry,
   Add for Review, submission, availability, or release.
