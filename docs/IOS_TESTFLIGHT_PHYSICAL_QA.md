# iOS TestFlight physical-device verification

Use this runbook after a release build has been uploaded to the internal
TestFlight group and the protected production Worker has completed its
TestFlight-bootstrap deployment. It records the physical-device evidence
needed before a reviewer may set
`APP_ATTEST_PRODUCTION_ENFORCED=true` and run the production launch
deployment.

This is a **production** check. It must use the TestFlight release build and
the approved notification origin
`https://quakesignal-api.hopeso.workers.dev`. A Simulator, a Debug build, or
the isolated staging Worker is useful development evidence, but cannot satisfy
this gate. Do not submit the app for public App Review while any required row
below is incomplete.

## Before starting

- Use an iPhone that supports App Attest, has normal network access, and is
  enrolled in the QuakeSignal internal TestFlight group. Record the exact
  marketing version and build number shown by TestFlight.
- Install the assigned TestFlight build rather than a development/Xcode build.
  Complete onboarding, then open the **Settings** tab and its
  **Notifications** section.
- Turn off Focus or otherwise make banners visible for the notification test.
  QuakeSignal has no Critical Alerts entitlement; a normal or time-sensitive
  notification may still be delayed or summarized by iOS settings.
- Use a city instead of precise current location if that is preferable for the
  test. Never put an APNs token, App Attest key ID/proof, precise location,
  screenshots of system account information, or secret values in the test
  record.
- Record a UTC timestamp, build number, device model/iOS version, and the
  visible success/failure text for each step. A Settings screenshot is enough;
  no server request body is needed.

The release operator, not the tester, has already verified that the signed
archive pins the approved production host. The tester should not try to call
Worker endpoints directly or use an API client.

## Required tester checklist

Perform the first four checks in the listed order. In particular, the
key-owned empty-body deletion must happen **before** the reinstall check,
while the original App Attest key still owns an active registration.

### 1. Initial production registration

1. In QuakeSignal, select **Enable Notifications** when it is offered and
   grant the iOS notification prompt.
2. Stay in the Settings screen until the status reads **Alert registration is
   active.** If it first says that it is waiting for an APNs token, wait for
   the token and use **Retry Alert Registration** once. Do not repeatedly tap
   retry.
3. Save the timestamp and a screenshot of the active status.

That status is only written after the TestFlight app receives a successful,
App-Attest-protected production registration response. It is the visible
evidence for the initial attestation and APNs-token registration.

### 2. Launch/token refresh

1. With the registration active, close QuakeSignal, force-quit it from the
   app switcher, and launch it again from TestFlight/Home Screen.
2. Return to **Settings → Notifications** and wait for **Alert registration is
   active.** The release client asks APNs for the current token on every
   authorized launch and sends a protected refresh after it arrives.
3. Optionally change one harmless alert preference (for example the magnitude
   tier), wait for the active status again, then restore the original choice.

iOS does not offer a supported tester control to force a new APNs token. This
step proves the launch refresh path; if Apple rotates the token later, record
the same active-status result and time as additional evidence.

### 3. Token-bound unsubscribe and re-enrollment

1. Keep iOS notifications allowed and confirm **Alert registration is active.**
2. Tap **Remove Alert Registration** and confirm **Remove Registration**.
3. Expect **Alert registration removed. Your iPhone notification permission
   was not changed.** The screen should offer **Resume Earthquake Alerts**.
4. Tap **Resume Earthquake Alerts** and wait for both the resume success text
   and **Alert registration is active.**

At this point the app has a current in-memory APNs token, so the deletion is
the token-bound form. Do not record or attempt to inspect that token.

### 4. Key-owned empty-body unsubscribe and re-enrollment

This deliberately verifies the exact empty JSON deletion path (`{}`). It is
safe only for a key that already owns the active registration.

1. Confirm **Alert registration is active** after step 3.
2. Force-quit QuakeSignal. In **iOS Settings → Notifications → QuakeSignal**,
   turn off **Allow Notifications**. Do not delete or reinstall the app.
3. Launch QuakeSignal again. On its Settings screen, the app has no APNs token
   for this launch but it still retains the original App Attest key. Tap
   **Remove Alert Registration** and confirm it.
4. Expect the same **Alert registration removed** success text. This is the
   visible result of the protected key-owned empty-body deletion.
5. Re-enable **Allow Notifications** in iOS Settings, return to QuakeSignal,
   tap **Resume Earthquake Alerts**, and wait for **Alert registration is
   active.**

If this flow is attempted after a reinstall or another key reset, a new key
cannot delete a subscription owned by a different key without the exact APNs
token. Do not treat that expected refusal as a product failure; use the
support link if a real user needs help removing an orphaned registration.

### 5. Controlled production training notification

The checked-in production configuration deliberately has
`ENABLE_PRODUCTION_TEST_PUSH=false`. Do **not** press **Send Test Alert**
while that setting is disabled: a resulting “production test alerts are
disabled” error is expected and is not a delivery test.

When a release operator has explicitly opened a reviewed, time-bounded test
window, do the following on the already active device:

1. Leave the app's **Include Test Alerts** preference enabled for a clear test
   record. Do not use real earthquake data or a real-looking emergency
   message.
2. Tap **Send Test Alert** once. Do not retry it automatically.
3. Expect **Test alert sent.** and an APNs banner whose localized title marks
   it as a test (for example, **Earthquake Warning (Test)** in English). When
   opened, the app must identify it as a training/drill rather than a real
   earthquake.
4. Record the screen state, delivery time, whether a banner/sound appeared,
   and any failure text. The Worker allows one accepted production training
   attempt per App Attest key per UTC day; a later attempt receives a
   rate-limit response until the next UTC day, even if APNs rejected the first
   attempt.
5. The release operator must return `ENABLE_PRODUCTION_TEST_PUSH` to `false`
   in a separately reviewed configuration deployment immediately after the
   planned attempt. It is never a client secret or a standing launch setting.

The training endpoint requires an existing, attested production registration
owned by the caller's key. It cannot bootstrap a key or send to another
device.

### 6. Delayed background, locked, and terminated training notification

This check requires a **later TestFlight build** containing **Schedule
Background Test Alert** and a reviewed Worker revision containing the private
delayed-training scheduler. The currently uploaded TestFlight build does not
contain this control, so it cannot provide this evidence.

During a separate, explicitly reviewed temporary window with
`ENABLE_PRODUCTION_TEST_PUSH=true`, use an already active production
registration:

1. Do not first use **Send Test Alert** that UTC day: immediate and delayed
   modes share the same one-attempt-per-App-Attest-key daily claim.
2. Tap **Schedule Background Test Alert**, confirm the dialog, and expect the
   visible scheduled-success text. Do not expose or record any token, key, or
   request details.
3. Immediately leave QuakeSignal, then lock or terminate it. The server fixes
   the appointment at 90 seconds; the client cannot choose another time.
4. Record the banner/sound and delivery time without reopening the app before
   the expected alert. An alarm more than 30 seconds late is discarded rather
   than delivered stale. Do not retry a missed or rejected attempt: the daily
   claim is already consumed.
5. The release operator returns `ENABLE_PRODUCTION_TEST_PUSH` to `false` in a
   separately reviewed configuration deployment after the planned attempt.

## Evidence that still needs an additional controlled capability

The fresh-key rebind requirement is not reproducibly testable by a person using
the current TestFlight UI alone. Mark it as pending rather than inferring a
pass. The background/locked/terminated requirement remains pending until the
later-build check above has passed.

| Requirement | Why the current UI is insufficient | Safe completion path |
| --- | --- | --- |
| Background, locked, and terminated APNs delivery | The currently uploaded TestFlight build has only synchronous **Send Test Alert**; swiping Home or locking immediately after tapping is race-prone. | Install a later TestFlight build that contains **Schedule Background Test Alert**, then use section 6 during a reviewed temporary test window. |
| A verified fresh-key rebind after reinstall/restore | Reinstalling is a useful smoke test, but iOS does not guarantee that it will create the exact App Attest key-reset condition on demand. The Settings UI never exposes a key ID or proof type. | Use a controlled QA key-reset/restore scenario or narrowly scoped, sanitized reviewer evidence that shows a fresh production attestation rebound the same APNs token. Do not expose keys, tokens, proofs, or raw D1 rows to the tester. |

For the reinstall smoke test itself, leave an active registration in place,
delete the app without using **Remove Alert Registration**, reinstall the same
TestFlight build, complete onboarding, and verify that registration becomes
active again. Record it as a reinstall smoke result, not as definitive proof
of the fresh-key branch unless the reviewer obtains the additional evidence
described above.

## Release decision record

Copy this into the release ticket; redact all identifiers and personal data.

| Check | Result | UTC time | Evidence / observed text |
| --- | --- | --- | --- |
| TestFlight build and physical device identified |  |  |  |
| Initial production registration |  |  |  |
| Launch/token refresh |  |  |  |
| Token-bound unsubscribe + re-enrollment |  |  |  |
| Key-owned empty-body unsubscribe + re-enrollment |  |  |  |
| Controlled training notification |  |  |  |
| Background/locked/terminated delivery | Pending until section 6 passes on a later TestFlight build |  |  |
| Fresh-key rebind after reinstall/restore | Pending unless separately evidenced |  |  |

Do not promote the App Attest environment gate or submit the iOS app while a
required row is unresolved. See the broader deployment controls in
[`CLOUDFLARE_PRODUCTION.md`](CLOUDFLARE_PRODUCTION.md) and the App Store
release sequence in [`ios/AppStore/README.md`](../ios/AppStore/README.md).
