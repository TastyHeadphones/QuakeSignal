# App Store Connect portal audit — 2026-08-22

This is the action-time record for shared native Apple ID `6800642443` after
the release owner authorized preparation of version `1.1 (8)`. It records both
saved changes and remaining gates. It is not evidence that build 8 was uploaded,
that screenshots passed final review, or that any platform was submitted.

## Saved release preparation

- The shared English subtitle is `Earthquake Reports & Safety`.
- The iOS `1.1` description, keywords, and review notes match
  [`en-US/description.txt`](./en-US/description.txt),
  [`en-US/keywords.txt`](./en-US/keywords.txt), and
  [`review-notes.txt`](./review-notes.txt). The previous CENC, Sichuan, Fujian,
  and Chongqing storefront claims were removed in favor of the reviewed
  JMA-only build-8 scope.
- The tvOS `1.1` description and review notes match
  [`platforms/tvos/en-US/description.txt`](./platforms/tvos/en-US/description.txt)
  and [`platforms/tvos/review-notes.txt`](./platforms/tvos/review-notes.txt).
- At audit time, the saved visionOS `1.1` description and review notes matched
  the then-current checked-in copy. The linked
  [`platforms/visionos/en-US/description.txt`](./platforms/visionos/en-US/description.txt)
  and [`platforms/visionos/review-notes.txt`](./platforms/visionos/review-notes.txt)
  were subsequently corrected to distinguish Apple support for App Attest from
  the unavailable APNs capability. The corrected copy is not yet portal-saved
  evidence and must be resaved during the final authenticated pass.
- The shared macOS draft was changed from `1.0` to `1.1`, reconciled to the
  Swift-native Mac Catalyst route, and saved with the exact promotional text,
  description, keywords, and review notes under
  [`platforms/maccatalyst`](./platforms/maccatalyst/). Manual release is
  selected. No Tauri metadata or artifact was used.
- The duplicate **Designed for iPad on Mac** availability checkbox was cleared.
  The native Mac Catalyst draft is the sole planned Mac storefront route.
- Public distribution remains configured across 175 countries or regions.
  The compatible-iOS-app checkbox for Apple Vision Pro remains enabled; App
  Store Connect states that the native visionOS version will supersede it when
  approved.
- The shared App Review contact was aligned to the current Apple Developer
  Account Holder. First name, last name, email, and the organization's phone
  were sourced from the authenticated membership record and saved without
  copying those personal values into the repository.
- TestFlight Test Information was aligned to the same authenticated source:
  Feedback Email and Beta App Review first name, last name, phone, and email
  were saved. The post-save page retained the Account Holder name and showed no
  validation error.

No screenshot, build, attachment, privacy answer, App Motion answer,
accessibility declaration, or Add for Review action was changed. Contact
fields were the only additional shared release information changed.

## Live incomplete state

| Gate | Action-time portal state |
| --- | --- |
| iPhone screenshots | `0 of 10` |
| iPad screenshots | `0 of 10` |
| Apple Watch screenshots | `0 of 10` |
| tvOS screenshots | `0 of 10` |
| visionOS screenshots | `0 of 10` |
| Mac screenshots | `0 of 10` |
| Build 8 | Not present or selected on any platform draft |
| iOS What's New and promotional text | No action-time save/reverification evidence; copy the exact checked-in English fields during the final authenticated pass |
| Corrected visionOS capability wording | Not yet resaved after the App Attest/APNs clarification |
| App Review contact | Saved from the authenticated Apple Developer Account Holder membership record; personal values are intentionally not copied into source |
| Apple TV Privacy Policy | Blank; the checked-in text remains an explicitly unapproved draft |
| Vision App Motion | `Set Up`; do not answer until final Vision QA |
| App Accessibility | Not configured; the setup dialog was inspected and cancelled without saving claims |
| Submission | No platform was added for review or submitted |

The TestFlight dashboard lists only the iOS surface. Its newest upload is
version `1.1 (7)`, marked **Complete** and **Ready to Submit**; build `8` is not
present. The existing `QuakeSignal Internal QA` group is visible, but there is
no tvOS, visionOS, or Mac build section and no qualifying multi-platform build
8 to test or attach. TestFlight Feedback Email and Beta App Review contact were
saved from the authenticated Account Holder membership record. A later App
Store Connect session expiry prevented a second reload check of fields whose
values the accessibility tree masks; it does not reverse the accepted save,
but the release owner must visually confirm the complete contact block during
the final pre-submission portal pass.

## Shared questionnaires and privacy

- App Information still displays Content Rights as **Yes**. That portal value
  remains subject to final signed/deployed JMA-only verification, action-time
  terms and territory review, and the stop conditions in
  [`content-rights-evidence.md`](./content-rights-evidence.md).
- The published App Privacy disclosure lists Coarse Location, Device ID, and
  Other Data, all for App Functionality and linked to the user. The Privacy
  Policy URL is `https://quakesignal-api.hopeso.workers.dev/privacy`.
- The existing age rating is 4+ with the displayed regional variants. Export
  compliance and every questionnaire still require reconciliation against the
  final signed artifacts before submission.

## External release blockers at this audit

- The local `gh` credential for `TastyHeadphones` is invalid, and the managed
  shell cannot connect to `github.com` to begin `gh auth login`.
- The hardened branch and hosted screenshot finalization path must be pushed,
  reviewed, and merged before protected-main build and capture workflows can
  run.
- The live `ios-app-store-release` environment must be confirmed to require an
  independent reviewer and prevent self-review. The finalizer now queries its
  canonical run approval history and rejects any supplied reviewer login that
  is not an approved environment reviewer distinct from the dispatch actor; it
  derives artifact hashes from four machine-readable upload-run attestations
  rather than accepting human-supplied hashes.
- App Store Connect's Xcode Cloud page still shows the initial onboarding state
  and says to create a workflow in Xcode; it exposes no QuakeSignal workflow or
  build history. Because this release forbids local Xcode/build execution, no
  initial Xcode Cloud workflow was created. GitHub Actions is the only currently
  repository-defined hosted build, capture, signing, and upload lane; it is not
  operational until the branch is merged and its protected environment is
  confirmed.
- The Apple distribution profiles exist in the Developer portal, but their
  existence does not prove that the protected GitHub environment contains the
  corresponding base64 profile and certificate values.
- Fresh exact-source capture, named visual/privacy approval, signed-Release
  parity, physical/platform QA, build processing, screenshot upload, and final
  submission remain incomplete.
