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
- The visionOS `1.1` description and review notes match
  [`platforms/visionos/en-US/description.txt`](./platforms/visionos/en-US/description.txt)
  and [`platforms/visionos/review-notes.txt`](./platforms/visionos/review-notes.txt).
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

No screenshot, build, attachment, privacy answer, App Motion answer,
accessibility declaration, or Add for Review action was changed as part of
these saves.

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
| App Review contact | First name `GENG` and last name `YANG` are present; email and phone are blank and have no approved repository source |
| Apple TV Privacy Policy | Blank; the checked-in text remains an explicitly unapproved draft |
| Vision App Motion | `Set Up`; do not answer until final Vision QA |
| App Accessibility | Not configured; the setup dialog was inspected and cancelled without saving claims |
| Submission | No platform was added for review or submitted |

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
  independent reviewer and prevent self-review before its human-supplied
  reviewer names or signed-artifact hashes are accepted as release evidence.
- The Apple distribution profiles exist in the Developer portal, but their
  existence does not prove that the protected GitHub environment contains the
  corresponding base64 profile and certificate values.
- Fresh exact-source capture, named visual/privacy approval, signed-Release
  parity, physical/platform QA, build processing, screenshot upload, and final
  submission remain incomplete.
