#!/usr/bin/env python3

import copy
import importlib.util
import json
import os
from pathlib import Path
import time
import unittest
from unittest.mock import patch


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
GUARD_PATH = REPOSITORY_ROOT / "ios/ci_scripts/xcode-cloud-release-guard.py"
SPEC = importlib.util.spec_from_file_location("xcode_cloud_release_guard", GUARD_PATH)
guard = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(guard)
COMMIT = "a" * 40
PRODUCT_ID = "12345678-ABCD-DEFG-1234-012345ABCDEF"
WORKFLOW_ID = "87654321-ABCD-DEFG-1234-012345ABCDEF"


def environment(scheme="QuakeSignal"):
    target = guard.TARGETS[scheme]
    return {
        "CI": "TRUE",
        "CI_XCODE_CLOUD": "TRUE",
        "CI_XCODEBUILD_ACTION": "archive",
        "CI_START_CONDITION": "manual",
        "CI_BUILD_NUMBER": guard.BUILD_NUMBER,
        "CI_TEAM_ID": guard.TEAM_ID,
        "CI_PRODUCT": guard.PRODUCT_NAME,
        "CI_PRODUCT_ID": PRODUCT_ID,
        "CI_WORKFLOW": guard.RELEASE_WORKFLOW,
        "CI_WORKFLOW_ID": WORKFLOW_ID,
        "CI_COMMIT": COMMIT,
        "CI_PROJECT_FILE_PATH": str(REPOSITORY_ROOT / "ios/QuakeSignal.xcodeproj"),
        "CI_XCODE_SCHEME": scheme,
        "CI_PRODUCT_PLATFORM": target["platform"],
        "CI_BUNDLE_ID": target["bundle"],
        "QUAKESIGNAL_RELEASE_COMMIT": COMMIT,
        "QUAKESIGNAL_RELEASE_PRODUCT_ID": PRODUCT_ID,
        "QUAKESIGNAL_RELEASE_WORKFLOW_ID": WORKFLOW_ID,
        "QUAKESIGNAL_RELEASE_REF": guard.RELEASE_REF,
    }


def catalyst_environment():
    value = environment("QuakeSignal")
    value["CI_PRODUCT_PLATFORM"] = guard.MAC_CATALYST_TARGET["platform"]
    return value


def source_state():
    return {
        "origin_url": "https://github.com/TastyHeadphones/QuakeSignal.git",
        "head": COMMIT,
        "main": COMMIT,
        "status": "",
    }


def json_bytes(value):
    return json.dumps(value, separators=(",", ":")).encode()


def ready_metadata(fingerprint=guard.APP_ATTEST_FINGERPRINT):
    return {
        "name": "QuakeSignal Notification Service",
        "runtime": "Cloudflare Workers + Durable Objects + D1",
        "purpose": "APNs alert delivery only",
        "earthquakeData": "Clients fetch directly from Wolfx",
        "appAttestPolicy": {
            "format": guard.POLICY_FORMAT,
            "fingerprint": fingerprint,
            "allowedBundleVersions": [str(value) for value in range(1, 9)],
        },
    }


class GuardContextTests(unittest.TestCase):
    def test_all_schemes_share_one_exact_workflow(self):
        self.assertEqual({guard.RELEASE_WORKFLOW}, {guard.RELEASE_WORKFLOW for _ in guard.TARGETS.values()})
        for scheme in guard.TARGETS:
            result = guard.verify_context(
                environment(scheme),
                phase="post-clone",
                repository_root=REPOSITORY_ROOT,
                source_state=source_state(),
            )
            self.assertEqual(result["scheme"], scheme)
        catalyst = guard.verify_context(
            catalyst_environment(),
            phase="post-clone",
            repository_root=REPOSITORY_ROOT,
            source_state=source_state(),
        )
        self.assertEqual(catalyst["verifier"], "maccatalyst")
        for scheme, old_name in (
            ("QuakeSignal", "QuakeSignal iOS App Store Release"),
            ("QuakeSignalTV", "QuakeSignal tvOS App Store Release"),
            ("QuakeSignalVision", "QuakeSignal visionOS App Store Release"),
        ):
            mutated = environment(scheme)
            mutated["CI_WORKFLOW"] = old_name
            with self.assertRaisesRegex(guard.ReleaseGuardError, "CI_WORKFLOW"):
                guard.verify_context(mutated, phase="pre-xcodebuild")

    def test_manual_context_rejects_gate_mutations(self):
        mutations = (
            ("CI_START_CONDITION", "push"),
            ("CI_START_CONDITION", "manual_rebuild"),
            ("CI_BUILD_NUMBER", "9"),
            ("CI_TEAM_ID", "ABCDEFGHIJ"),
            ("CI_PRODUCT", "QuakeSignal Staging"),
            ("CI_PRODUCT_ID", ""),
            ("QUAKESIGNAL_RELEASE_PRODUCT_ID", "other-product"),
            ("CI_WORKFLOW_ID", ""),
            ("QUAKESIGNAL_RELEASE_WORKFLOW_ID", "other-workflow"),
            ("QUAKESIGNAL_RELEASE_REF", "refs/heads/release"),
            ("QUAKESIGNAL_RELEASE_COMMIT", "b" * 40),
            ("CI_XCODE_SCHEME", "QuakeSignalWatch"),
            ("CI_BUNDLE_ID", "com.example.mutated"),
            ("CURL_CA_BUNDLE", "/tmp/attacker-ca.pem"),
            ("SSL_CERT_DIR", "/tmp/attacker-certs"),
            ("SSL_CERT_FILE", "/tmp/attacker-ca.pem"),
        )
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                mutated = environment()
                mutated[key] = value
                with self.assertRaises(guard.ReleaseGuardError):
                    guard.verify_context(mutated, phase="pre-xcodebuild")

    def test_release_markers_cannot_skip_the_gate_as_a_non_archive_action(self):
        for value in ("", "build", "test", "analyze"):
            with self.subTest(value=value):
                mutated = environment()
                mutated["CI_XCODEBUILD_ACTION"] = value
                with self.assertRaisesRegex(guard.ReleaseGuardError, "CI_XCODEBUILD_ACTION"):
                    guard.run_phase("pre-xcodebuild", environment=mutated)
        self.assertIsNone(
            guard.verify_context(
                {"CI_XCODEBUILD_ACTION": "test", "CI_WORKFLOW": "Ordinary CI"},
                phase="pre-xcodebuild",
            )
        )

    def test_branch_specific_values_are_optional_but_exact(self):
        guard.verify_context(environment(), phase="pre-xcodebuild")
        explicit = environment()
        explicit.update({"CI_BRANCH": "main", "CI_GIT_REF": guard.RELEASE_REF})
        guard.verify_context(explicit, phase="pre-xcodebuild")
        for key, value in (("CI_BRANCH", "release"), ("CI_GIT_REF", "refs/heads/release")):
            mutated = environment()
            mutated[key] = value
            with self.assertRaisesRegex(guard.ReleaseGuardError, key):
                guard.verify_context(mutated, phase="pre-xcodebuild")

    def test_vision_platform_rejects_missing_or_documented_wrong_values(self):
        for value in ("", "iOS", "macOS", "tvOS", "watchOS"):
            mutated = environment("QuakeSignalVision")
            mutated["CI_PRODUCT_PLATFORM"] = value
            with self.assertRaisesRegex(guard.ReleaseGuardError, "CI_PRODUCT_PLATFORM"):
                guard.verify_context(mutated, phase="pre-xcodebuild")
        future = environment("QuakeSignalVision")
        future["CI_PRODUCT_PLATFORM"] = "AppleVisionPlatformFutureName"
        self.assertEqual(
            guard.verify_context(future, phase="pre-xcodebuild")["verifier"],
            "visionos",
        )

    def test_quakesignal_scheme_selects_exact_ios_or_mac_catalyst_route(self):
        self.assertEqual(
            guard.verify_context(environment(), phase="pre-xcodebuild")["verifier"],
            "ios",
        )
        catalyst = guard.verify_context(catalyst_environment(), phase="pre-xcodebuild")
        self.assertEqual(catalyst["platform"], "macOS")
        self.assertEqual(catalyst["verifier"], "maccatalyst")

        for value in ("", "tvOS", "watchOS"):
            mutated = environment()
            mutated["CI_PRODUCT_PLATFORM"] = value
            with self.assertRaisesRegex(guard.ReleaseGuardError, "CI_PRODUCT_PLATFORM"):
                guard.verify_context(mutated, phase="pre-xcodebuild")

    def test_post_clone_requires_clean_exact_remote_main_proof(self):
        for key, value in (
            ("origin_url", "https://github.com/example/repackaged.git"),
            ("head", "b" * 40),
            ("main", "b" * 40),
            ("status", " M ios/project.yml"),
        ):
            mutated = source_state()
            mutated[key] = value
            with self.assertRaises(guard.ReleaseGuardError):
                guard.verify_context(
                    environment(),
                    phase="post-clone",
                    repository_root=REPOSITORY_ROOT,
                    source_state=mutated,
                )

    def test_source_capture_always_uses_exact_non_redirecting_remote_main_lookup(self):
        calls = []

        def fake_run_git(root, arguments):
            calls.append((root, arguments))
            if arguments == ["remote", "get-url", "origin"]:
                return "https://github.com/TastyHeadphones/QuakeSignal.git"
            if arguments == [
                "-c",
                "http.followRedirects=false",
                "ls-remote",
                "--exit-code",
                "--refs",
                guard.MAIN_REMOTE_URL,
                guard.RELEASE_REF,
            ]:
                return f"{COMMIT}\t{guard.RELEASE_REF}"
            if arguments == ["rev-parse", "HEAD"]:
                return COMMIT
            if arguments == ["status", "--porcelain=v1", "--untracked-files=all"]:
                return ""
            raise AssertionError(f"unexpected git call: {arguments!r}")

        with patch.object(guard, "run_git", side_effect=fake_run_git):
            self.assertEqual(guard.capture_source_state(REPOSITORY_ROOT)["main"], COMMIT)
        self.assertEqual(
            calls,
            [
                (REPOSITORY_ROOT, ["remote", "get-url", "origin"]),
                (None, [
                    "-c", "http.followRedirects=false", "ls-remote", "--exit-code", "--refs",
                    guard.MAIN_REMOTE_URL, guard.RELEASE_REF,
                ]),
                (REPOSITORY_ROOT, ["rev-parse", "HEAD"]),
                (REPOSITORY_ROOT, ["status", "--porcelain=v1", "--untracked-files=all"]),
            ],
        )

    def test_git_process_strips_repository_and_transport_override_environment(self):
        injected = {
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "url.https://attacker.invalid/.insteadOf",
            "GIT_CONFIG_VALUE_0": guard.MAIN_REMOTE_URL,
            "GIT_DIR": "/tmp/attacker-git-dir",
            "GIT_SSH_COMMAND": "/tmp/attacker-ssh",
            "GIT_WORK_TREE": "/tmp/attacker-work-tree",
            "CURL_CA_BUNDLE": "/tmp/attacker-ca.pem",
            "DEVELOPER_DIR": "/tmp/attacker-developer-dir",
            "SDKROOT": "/tmp/attacker-sdk",
            "SSL_CERT_DIR": "/tmp/attacker-certs",
            "SSL_CERT_FILE": "/tmp/attacker-ca.pem",
            "TOOLCHAINS": "attacker-toolchain",
        }
        completed = guard.subprocess.CompletedProcess(
            args=["git"],
            returncode=0,
            stdout=f"{COMMIT}\t{guard.RELEASE_REF}\n",
            stderr="",
        )
        with patch.dict(os.environ, injected), patch.object(guard.subprocess, "run", return_value=completed) as run:
            guard.run_git(None, ["ls-remote", guard.MAIN_REMOTE_URL, guard.RELEASE_REF])
        call = run.call_args
        self.assertEqual(call.kwargs["cwd"], Path("/tmp"))
        for key in injected:
            self.assertNotIn(key, call.kwargs["env"])
        self.assertEqual(call.kwargs["env"]["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(call.kwargs["env"]["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(call.kwargs["env"]["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertEqual(call.args[0][0], "/usr/bin/git")

    def test_pre_and_post_need_no_primary_checkout(self):
        mutated = environment()
        mutated["CI_PRIMARY_REPOSITORY_PATH"] = "/does/not/exist"
        calls = []
        for phase in ("pre-xcodebuild", "post-xcodebuild"):
            guard.run_phase(phase, environment=mutated, root=Path("/does/not/exist"), remote_verifier=lambda: calls.append(phase))
        self.assertEqual(calls, ["pre-xcodebuild", "post-xcodebuild"])

    def test_foreground_only_targets_do_not_probe_the_iOS_notification_relay(self):
        calls = []
        for scheme in ("QuakeSignalTV", "QuakeSignalVision"):
            guard.run_phase(
                "pre-xcodebuild",
                environment=environment(scheme),
                remote_verifier=lambda: calls.append(scheme),
            )
        guard.run_phase(
            "pre-xcodebuild",
            environment=catalyst_environment(),
            remote_verifier=lambda: calls.append("maccatalyst"),
        )
        self.assertEqual(calls, [])

    def test_checked_in_bounded_source_contract_and_fingerprint_pass(self):
        guard.verify_bounded_source_contract(REPOSITORY_ROOT)
        self.assertEqual(
            guard.calculate_app_attest_fingerprint(REPOSITORY_ROOT),
            guard.APP_ATTEST_FINGERPRINT,
        )

    def test_release_source_settings_reject_worker_or_app_attest_drift(self):
        project = (REPOSITORY_ROOT / "ios/project.yml").read_text(encoding="utf-8")
        for expected, replacement, message in (
            (guard.WORKER_ORIGIN, "https://attacker.invalid", "QUAKESIGNAL_API_BASE_URL"),
            ("QUAKESIGNAL_APP_ATTEST_MODE: production", "QUAKESIGNAL_APP_ATTEST_MODE: development", "QUAKESIGNAL_APP_ATTEST_MODE"),
        ):
            with self.subTest(message=message):
                mutated = project.replace(expected, replacement)
                with self.assertRaisesRegex(guard.ReleaseGuardError, message):
                    guard.verify_release_source_settings(mutated, "QuakeSignal")

    def test_vision_source_contract_is_foreground_only(self):
        project = (REPOSITORY_ROOT / "ios/project.yml").read_text(encoding="utf-8")
        guard.verify_foreground_only_source_settings(project, "QuakeSignalVision")
        mutated = project.replace(
            "          PROVISIONING_PROFILE_SPECIFIER: $(QUAKESIGNAL_VISION_PROFILE_NAME)\n",
            "          PROVISIONING_PROFILE_SPECIFIER: $(QUAKESIGNAL_VISION_PROFILE_NAME)\n"
            "          QUAKESIGNAL_APP_ATTEST_MODE: production\n",
            1,
        )
        with self.assertRaisesRegex(guard.ReleaseGuardError, "foreground-only"):
            guard.verify_foreground_only_source_settings(mutated, "QuakeSignalVision")

    def test_vision_location_disclosure_is_foreground_only(self):
        relative = "ios/QuakeSignalVision/Supporting/Info.plist"
        with (REPOSITORY_ROOT / relative).open("rb") as handle:
            plist = guard.plistlib.load(handle)
        guard.verify_info_plist_contract(plist, relative, False)
        mutated = dict(plist)
        mutated["NSLocationWhenInUseUsageDescription"] = (
            "QuakeSignal alerts you about nearby activity."
        )
        with self.assertRaisesRegex(guard.ReleaseGuardError, "foreground-only location use"):
            guard.verify_info_plist_contract(mutated, relative, False)

    def test_platform_capability_policy_rejects_vision_registration_mutation(self):
        sources = {
            relative: (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")
            for relative in guard.PLATFORM_CAPABILITY_POLICY_PATHS
        }
        mutated = dict(sources)
        path = "ios/QuakeSignal/App/PlatformCapabilities.swift"
        self.assertIn(path, guard.PLATFORM_CAPABILITY_POLICY_PATHS)
        mutated[path] = mutated[path].replace("#elseif os(visionOS)\n        false", "#elseif os(visionOS)\n        true")
        self.assertNotEqual(mutated[path], sources[path])
        with self.assertRaisesRegex(guard.ReleaseGuardError, "platform capability policy fingerprint"):
            guard.verify_platform_capabilities_sources(mutated)

        wrong_symbol = dict(sources)
        settings_path = "ios/QuakeSignal/Features/Settings/SettingsView.swift"
        self.assertIn(settings_path, guard.PLATFORM_CAPABILITY_POLICY_PATHS)
        wrong_symbol[settings_path] = wrong_symbol[settings_path].replace('systemImage: "eye"', 'systemImage: "macbook"', 1)
        with self.assertRaisesRegex(guard.ReleaseGuardError, "platform capability policy fingerprint"):
            guard.verify_platform_capabilities_sources(wrong_symbol)

        mac_specific_copy = dict(sources)
        english_path = "ios/QuakeSignal/Resources/en.lproj/Localizable.strings"
        self.assertIn(english_path, guard.PLATFORM_CAPABILITY_POLICY_PATHS)
        mac_specific_copy[english_path] = mac_specific_copy[english_path].replace(
            '"platform.alertRegistration.foregroundOnly" = "Foreground monitoring only";',
            '"platform.alertRegistration.foregroundOnly" = "Foreground monitoring on Mac";',
            1,
        )
        self.assertNotEqual(mac_specific_copy[english_path], sources[english_path])
        with self.assertRaisesRegex(guard.ReleaseGuardError, "platform capability policy fingerprint"):
            guard.verify_platform_capabilities_sources(mac_specific_copy)

    def test_platform_capability_policy_rejects_foreground_privacy_mutations(self):
        sources = {
            relative: (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")
            for relative in guard.PLATFORM_CAPABILITY_POLICY_PATHS
        }
        for path in guard.FOREGROUND_PRIVACY_MANIFEST_PATHS:
            for old, new in (
                ("<key>NSPrivacyTracking</key>\n\t<false/>", "<key>NSPrivacyTracking</key>\n\t<true/>"),
                ("<key>NSPrivacyCollectedDataTypes</key>\n\t<array/>", "<key>NSPrivacyCollectedDataTypes</key>\n\t<array><dict/></array>"),
                ("<string>CA92.1</string>", "<string>UNREVIEWED.1</string>"),
            ):
                with self.subTest(path=path, replacement=new):
                    mutated = dict(sources)
                    mutated[path] = mutated[path].replace(old, new, 1)
                    self.assertNotEqual(mutated[path], sources[path])
                    with self.assertRaisesRegex(
                        guard.ReleaseGuardError,
                        "must declare tracking false, no tracking domains or collected data",
                    ):
                        guard.verify_platform_capabilities_sources(mutated)

    def test_platform_capability_policy_enforces_the_exact_jma_only_boundary(self):
        sources = {
            relative: (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")
            for relative in guard.PLATFORM_CAPABILITY_POLICY_PATHS
        }
        self.assertEqual(guard.REQUIRED_WOLFX_SOURCES, ("jma_eew", "jma_eqlist"))
        guard.verify_jma_only_source_contract(sources)

        mutations = (
            (
                "ios/QuakeSignal/Networking/WolfxClient.swift",
                'static let sources = ["jma_eew", "jma_eqlist"]',
                'static let sources = ["jma_eew", "jma_eqlist", "cenc_eew"]',
                "disabled non-JMA feed surface",
            ),
            (
                "ios/QuakeSignal/Networking/LiveSocketClient.swift",
                'return ["query_jmaeew"]',
                "return []",
                "direct JMA WebSocket contract",
            ),
            (
                "ios/QuakeSignal/Networking/LiveSocketClient.swift",
                "WolfxNormalizer.validatedEvents(source: source, data: data)",
                "WolfxNormalizer.events(source: source, data: data)",
                "WebSocket readiness",
            ),
            (
                "ios/QuakeSignal/Networking/LiveSocketClient.swift",
                'object["type"] as? String == source',
                'object["type"] as? String != nil',
                "WebSocket readiness",
            ),
            (
                "ios/QuakeSignal/Networking/LiveSocketClient.swift",
                "case .keepAlive:\n            return wasReady",
                "case .keepAlive:\n            return true",
                "WebSocket readiness",
            ),
            (
                "ios/QuakeSignal/Networking/LiveSocketClient.swift",
                "case .invalid:\n            return false",
                "case .invalid:\n            return wasReady",
                "WebSocket readiness",
            ),
            (
                "ios/QuakeSignal/Networking/LiveSocketClient.swift",
                "let nextState = readyRoutes.count == Self.routes.count",
                "let nextState = !readyRoutes.isEmpty",
                "WebSocket readiness",
            ),
            (
                "ios/QuakeSignal/Networking/LiveSocketClient.swift",
                "readyRoutes.remove(route)",
                "_ = route // readiness incorrectly preserved",
                "WebSocket readiness",
            ),
            (
                "ios/QuakeSignal/Networking/WolfxClient.swift",
                'let serial = positiveInteger(value["Serial"])',
                "let serial = 1",
                "raw Serial field",
            ),
            (
                "ios/QuakeSignal/State/AppSettings.swift",
                "static let allSources = WolfxClient.sources",
                'static let allSources = ["jma_eew"]',
                "AppSettings",
            ),
        )
        for path, old, new, message in mutations:
            with self.subTest(path=path):
                mutated = dict(sources)
                mutated[path] = mutated[path].replace(old, new, 1)
                self.assertNotEqual(mutated[path], sources[path])
                with self.assertRaisesRegex(guard.ReleaseGuardError, message):
                    guard.verify_jma_only_source_contract(mutated)

    def test_foreground_push_suppression_requires_confirmed_revision_ownership(self):
        sources = {
            relative: (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")
            for relative in guard.PLATFORM_CAPABILITY_POLICY_PATHS
        }
        guard.verify_foreground_push_presentation_contract(sources)

        mutations = (
            (
                "ios/QuakeSignal/Notifications/PushPayload.swift",
                "WolfxClient.sources.contains($0) ? $0 : nil",
                "$0",
                "strictly typed",
            ),
            (
                "ios/QuakeSignal/Notifications/PushPayload.swift",
                'event.id == "\\(sourceID):\\(eventID)",',
                "true,",
                "strictly typed",
            ),
            (
                "ios/QuakeSignal/Notifications/PushPayload.swift",
                'let serial = nonnegativeInteger(userInfo["serial"]),',
                'let serial = userInfo["serial"] as? Int,',
                "strictly typed",
            ),
            (
                "ios/QuakeSignal/Notifications/PushPayload.swift",
                '(sourceID == "jma_eew" && kind == "eew") ||\n'
                '                (sourceID == "jma_eqlist" && kind == "report"),',
                "true,",
                "strictly typed",
            ),
            (
                "ios/QuakeSignal/Notifications/PushPayload.swift",
                '?? parsedTimestamp(userInfo["originTimeUtc"]) else {',
                "?? Date.distantPast else {",
                "strictly typed",
            ),
            (
                "ios/QuakeSignal/Notifications/PushPayload.swift",
                "kind: kind,",
                'kind: "report",',
                "strictly typed",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "payload.hasUsableMatchingEventSnapshot && isSceneActive",
                "isSceneActive",
                "may be attempted only",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "let eventID: String",
                "var eventID: String",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "let serial: Int",
                "var serial: Int",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "let kind: String",
                "var kind: String",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "let isWarning: Bool",
                "var isWarning: Bool",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "let isFinal: Bool",
                "var isFinal: Bool",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "let isCancelled: Bool",
                "var isCancelled: Bool",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "let isTraining: Bool",
                "var isTraining: Bool",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "let effectiveTimestamp: Date?",
                "var effectiveTimestamp: Date?",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "eventID: event.id,",
                "eventID: event.eventId,",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "serial: event.serial,",
                "serial: 0,",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "kind: event.kind,",
                'kind: "report",',
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "isWarning: event.isWarn,",
                "isWarning: false,",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "isFinal: event.isFinal,",
                "isFinal: false,",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "isCancelled: event.isCancel,",
                "isCancelled: false,",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "isTraining: event.isTraining,",
                "isTraining: false,",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "effectiveTimestamp: event.reportDate ?? event.originDate",
                "effectiveTimestamp: nil",
                "complete typed revision identity",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "guard allowsEmergencyPresentation else { return false }",
                "if !allowsEmergencyPresentation { return true }",
                "exact or monotonically dominated",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "if handledRevisionKeys.contains(incoming) { return true }",
                "if handledRevisionKeys.contains(incoming) { return false }",
                "exact or monotonically dominated",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "guard event.isActiveWarning else { return false }",
                "guard event.isEew else { return false }",
                "exact or monotonically dominated",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "handled.monotonicallyDominates(incoming)",
                "incoming.monotonicallyDominates(handled)",
                "exact or monotonically dominated",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                'kind == "eew" && isWarning && !isFinal && !isCancelled && !isTraining',
                "isWarning && !isFinal",
                "exact or monotonically dominated",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                'kind == "eew" && !isTraining && (isFinal || isCancelled)',
                "isFinal || isCancelled",
                "exact or monotonically dominated",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "if isTerminalWarningLifecycle && incoming.isActiveWarning {",
                "if false {",
                "exact or monotonically dominated",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "return serial > incoming.serial",
                "return serial < incoming.serial",
                "exact or monotonically dominated",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "return effectiveTimestamp > incomingTimestamp",
                "return effectiveTimestamp < incomingTimestamp",
                "exact or monotonically dominated",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "static let lifetime: TimeInterval = 15",
                "static let lifetime: TimeInterval = 300",
                "short-lived revision-bound system presentation reservation",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "let expiresAt = receivedAt.addingTimeInterval(lifetime)",
                "let expiresAt = now.addingTimeInterval(lifetime)",
                "short-lived revision-bound system presentation reservation",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "guard expiresAt >= now else { return }",
                "guard expiresAt >= receivedAt else { return }",
                "short-lived revision-bound system presentation reservation",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "reservations.removeValue(forKey: revisionKey)",
                "reservations[revisionKey]",
                "short-lived revision-bound system presentation reservation",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "reserved.monotonicallyDominates(revisionKey)",
                "revisionKey.monotonicallyDominates(reserved)",
                "short-lived revision-bound system presentation reservation",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "event.isActiveWarning ||",
                "event.isActiveWarning &&",
                "owned foreground audio",
            ),
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "guard preferences.includeTraining, !isBackfill || previous != nil else { return nil }",
                "guard !isBackfill || previous != nil else { return nil }",
                "owned foreground audio",
            ),
            (
                "ios/QuakeSignal/Notifications/NotificationManager.swift",
                "var onForegroundNotification: ((ForegroundNotificationDelivery) -> Bool)?",
                "var onForegroundNotification: ((ForegroundNotificationDelivery) -> Void)?",
                "synchronously confirm in-app ownership",
            ),
            (
                "ios/QuakeSignal/Notifications/NotificationManager.swift",
                "let receivedAt: Date",
                "let receivedAt: TimeInterval",
                "keep buffered delivery system-owned",
            ),
            (
                "ios/QuakeSignal/Notifications/NotificationManager.swift",
                "receivedAt: delivery.receivedAt",
                "receivedAt: Date()",
                "keep buffered delivery system-owned",
            ),
            (
                "ios/QuakeSignal/Notifications/NotificationManager.swift",
                "let receivedAt = Date()",
                "let receivedAt = Date.distantFuture",
                "keep buffered delivery system-owned",
            ),
            (
                "ios/QuakeSignal/Notifications/NotificationManager.swift",
                "receivedAt: receivedAt",
                "receivedAt: Date()",
                "keep buffered delivery system-owned",
            ),
            (
                "ios/QuakeSignal/Notifications/NotificationManager.swift",
                "didHandleEmergencyInApp: allowsEmergencyPresentation && didHandleEmergencyInApp",
                "didHandleEmergencyInApp: allowsEmergencyPresentation || didHandleEmergencyInApp",
                "synchronously confirm in-app ownership",
            ),
            (
                "ios/QuakeSignal/Notifications/NotificationManager.swift",
                "pendingForegroundPayloads = Array(pendingForegroundPayloads.suffix(5))\n        return false",
                "pendingForegroundPayloads = Array(pendingForegroundPayloads.suffix(5))\n        return true",
                "keep buffered delivery system-owned",
            ),
            (
                "ios/QuakeSignal/Features/Root/RootView.swift",
                "return store.ingestForegroundNotification(",
                "store.ingestForegroundNotification(",
                "return synchronous snapshot ownership",
            ),
            (
                "ios/QuakeSignal/Features/Root/RootView.swift",
                "store.reserveSystemPresentation(",
                "store.skipSystemPresentationReservation(",
                "fallbacks system-owned",
            ),
            (
                "ios/QuakeSignal/Features/Root/RootView.swift",
                "if let revisionKey = payload.foregroundRevisionKey",
                "if let revisionKey = payload.compositeEventId",
                "fallbacks system-owned",
            ),
            (
                "ios/QuakeSignal/Features/Root/RootView.swift",
                "receivedAt: delivery.receivedAt",
                "receivedAt: Date()",
                "fallbacks system-owned",
            ),
            (
                "ios/QuakeSignal/State/QuakeStore.swift",
                "receivedAt: receivedAt,",
                "receivedAt: Date(),",
                "exact or dominated previously handled revision",
            ),
            (
                "ios/QuakeSignal/State/QuakeStore.swift",
                "let previous = events.first(where: { $0.id == event.id })\n"
                "        let systemOwnsPresentation = consumeSystemPresentationReservation(",
                "let previous = events.first(where: { $0.id == event.id })\n"
                "        guard EventMergePolicy.shouldAccept(event, replacing: previous) else { return false }\n"
                "        let systemOwnsPresentation = consumeSystemPresentationReservation(",
                "foreground-push reservations must be consumed",
            ),
            (
                "ios/QuakeSignal/State/QuakeStore.swift",
                "let systemOwnsPresentation = consumeSystemPresentationReservation(\n"
                "            for: event,\n"
                "            now: Date()\n"
                "        )\n"
                "        let previous = events.first(where: { $0.id == event.id })\n"
                "        guard EventMergePolicy.shouldAccept(event, replacing: previous) else { return }",
                "let previous = events.first(where: { $0.id == event.id })\n"
                "        guard EventMergePolicy.shouldAccept(event, replacing: previous) else { return }\n"
                "        let systemOwnsPresentation = consumeSystemPresentationReservation(\n"
                "            for: event,\n"
                "            now: Date()\n"
                "        )",
                "direct-event reservations must be consumed",
            ),
            (
                "ios/QuakeSignal/State/QuakeStore.swift",
                "for event in fetchedEvents {\n"
                "            _ = consumeSystemPresentationReservation(for: event, now: Date())\n"
                "            if let current = newestByID[event.id],\n"
                "               !EventMergePolicy.shouldAccept(event, replacing: current) {\n"
                "                continue\n"
                "            }",
                "for event in fetchedEvents {\n"
                "            if let current = newestByID[event.id],\n"
                "               !EventMergePolicy.shouldAccept(event, replacing: current) {\n"
                "                continue\n"
                "            }\n"
                "            _ = consumeSystemPresentationReservation(for: event, now: Date())",
                "fallback reservations must be consumed",
            ),
            (
                "ios/QuakeSignal/State/QuakeStore.swift",
                "guard !systemOwnsPresentation else { return true }",
                "guard !systemOwnsPresentation else { return false }",
                "exact or dominated previously handled revision",
            ),
            (
                "ios/QuakeSignal/State/QuakeStore.swift",
                "if let reason, !systemOwnsPresentation {",
                "if let reason {",
                "exact or dominated previously handled revision",
            ),
            (
                "ios/QuakeSignal/State/QuakeStore.swift",
                "_ = consumeSystemPresentationReservation(for: event, now: Date())",
                "_ = event // skipped fallback reservation consumption",
                "exact or dominated previously handled revision",
            ),
            (
                "ios/QuakeSignal/State/QuakeStore.swift",
                "guard alertedRevisionKeys.insert(key).inserted else { return true }",
                "guard alertedRevisionKeys.insert(key).inserted else { return false }",
                "exact or dominated previously handled revision",
            ),
            (
                "ios/QuakeSignal/Notifications/EmergencyAlertAudio.swift",
                "guard ForegroundEmergencyAudioPolicy.shouldPlay(event: event, reason: reason) else {",
                "guard event.isActiveWarning else {",
                "foreground warning and opted-in training audio",
            ),
            (
                "ios/QuakeSignal/Notifications/NotificationManager.swift",
                "return [.banner, .sound, .list]",
                "return [.list]",
                "preserve the system banner and sound",
            ),
        )
        for path, old, new, message in mutations:
            with self.subTest(path=path):
                mutated = dict(sources)
                mutated[path] = mutated[path].replace(old, new, 1)
                self.assertNotEqual(mutated[path], sources[path])
                with self.assertRaisesRegex(guard.ReleaseGuardError, message):
                    guard.verify_foreground_push_presentation_contract(mutated)

    def test_foreground_ownership_contract_rejects_decentralized_registration_location_or_audio(self):
        sources = {
            relative: (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")
            for relative in guard.PLATFORM_CAPABILITY_POLICY_PATHS
        }
        mutations = (
            (
                "ios/QuakeSignal/State/AppSettings.swift",
                "pushRegistrationPreferencesRevision &+= 1",
                "pushRegistrationPreferencesRevision = 0",
                "centralized registration revision",
            ),
            (
                "ios/QuakeSignal/Features/Root/RootView.swift",
                ".onChange(of: settings.pushRegistrationPreferencesRevision)",
                ".onChange(of: settings.alertSound)",
                "centralized registration revision",
            ),
            (
                "ios/QuakeSignal/Features/Root/RootView.swift",
                "locationManager.currentLocation == nil,\n"
                "           locationManager.isRequestingLocation {",
                "store.effectiveCoordinate == nil,\n"
                "           locationManager.isRequestingLocation {",
                "centralized registration revision",
            ),
            (
                "ios/QuakeSignal/Features/Root/RootView.swift",
                ".onChange(of: locationManager.isRequestingLocation)",
                ".onChange(of: locationManager.lastRequestFailed)",
                "location-request completion must resume deferred protected registration",
            ),
            (
                "ios/QuakeSignal/Features/Map/EpicenterMapView.swift",
                "locationManager.requestCurrentLocation(purpose: .mapFocus)",
                "locationManager.requestCurrentLocation()",
                "location-purpose ownership",
            ),
            (
                "ios/QuakeSignal/State/LocationManager.swift",
                "guard purpose == .mapFocus || AppSettings.shared.useCurrentLocation else {",
                "guard purpose == .mapFocus else {",
                "location-purpose ownership",
            ),
            (
                "ios/QuakeSignal/State/LocationManager.swift",
                "self.activeRequestPurpose = nil\n"
                "            guard purpose == .mapFocus || AppSettings.shared.useCurrentLocation else {",
                "self.activeRequestPurpose = nil\n"
                "            guard purpose == .mapFocus else {",
                "location-purpose ownership",
            ),
            (
                "ios/QuakeSignal/Notifications/EmergencyAlertAudio.swift",
                "play(preference, deduplicationKey: nil, owner: .preview)",
                "play(preference, deduplicationKey: nil, owner: .emergency)",
                "alert-audio ownership",
            ),
            (
                "ios/QuakeSignal/Notifications/EmergencyAlertAudio.swift",
                "guard playbackOwner == .preview else { return }",
                "guard playbackOwner != nil else { return }",
                "alert-audio ownership",
            ),
            (
                "ios/QuakeSignal/Notifications/EmergencyAlertAudio.swift",
                "let key = ForegroundEmergencyRevisionOwnershipPolicy.key(for: event)",
                "let key = ForegroundEmergencyRevisionOwnershipPolicy.key(for: event).serial",
                "alert-audio ownership",
            ),
            (
                "ios/QuakeSignal/Features/Settings/SettingsView.swift",
                "EmergencyAlertAudio.shared.stopPreview()",
                "EmergencyAlertAudio.shared.stop()",
                "alert-audio ownership",
            ),
            (
                "ios/QuakeSignal/State/QuakeStore.swift",
                "EmergencyAlertAudio.shared.stop()",
                "_ = presentedAlert // skipped app-owned emergency audio stop",
                "presented-alert replacement or dismissal",
            ),
        )
        for path, old, new, message in mutations:
            with self.subTest(path=path):
                mutated = dict(sources)
                mutated[path] = mutated[path].replace(old, new, 1)
                self.assertNotEqual(mutated[path], sources[path])
                with self.assertRaisesRegex(
                    guard.ReleaseGuardError,
                    message,
                ):
                    guard.verify_foreground_emergency_parity_contract(mutated)

    def test_platform_capability_policy_rejects_lifecycle_and_cache_mutations(self):
        sources = {
            relative: (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")
            for relative in guard.PLATFORM_CAPABILITY_POLICY_PATHS
        }
        mutations = (
            (
                "ios/QuakeSignal/State/AlertPolicy.swift",
                "event.isActiveWarning && WarningFreshnessPolicy.isFresh(event, now: now)",
                "event.isActiveWarning",
            ),
            (
                "ios/QuakeSignal/Notifications/NotificationManager.swift",
                "self.isForegroundSceneActive &&\n                UIApplication.shared.applicationState == .active",
                "self.isForegroundSceneActive",
            ),
            (
                "ios/QuakeSignal/State/QuakeStore.swift",
                "let now = Date()\n        clockNow = now\n        merge(event)",
                "let now = clockNow\n        merge(event)",
            ),
            (
                "ios/QuakeSignal/Features/Root/RootView.swift",
                "store.ingestTapped(event: cached, reason: reason)",
                "store.presentedAlert = PresentedAlert(event: cached, reason: reason)",
            ),
            (
                "ios/QuakeSignal/Features/Map/EpicenterMapView.swift",
                "return .openSettings",
                "return .request",
            ),
            (
                "ios/QuakeSignal/State/LocationManager.swift",
                "let remainingLifetime = LocationFixPolicy.remainingLifetime(forTimestamp: timestamp)",
                "let remainingLifetime = LocationFixPolicy.maximumAge",
            ),
            (
                "ios/QuakeSignal/Models/EEWEvent.swift",
                "return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil",
                "return coordinate",
            ),
            (
                "ios/QuakeSignal/Networking/WolfxClient.swift",
                "guard isSceneActive else { return }",
                "guard pendingRequestID == nil else { return }",
            ),
            (
                "ios/QuakeSignalTV/TVDashboardView.swift",
                ".task(id: manualRefreshLifecycle.taskID(isSceneActive: scenePhase == .active))",
                ".task",
            ),
            (
                "ios/QuakeSignalWatch/WatchDashboardView.swift",
                ".task(id: manualRefreshLifecycle.taskID(isSceneActive: scenePhase == .active))",
                ".task",
            ),
            (
                "ios/QuakeSignal/State/QuakeStore.swift",
                "case .stopSocket:\n            liveSocket.stop()",
                "case .stopSocket:\n            liveSocket.start()",
            ),
            (
                "ios/QuakeSignal/Networking/ForegroundHTTPFallbackPolicy.swift",
                "static func shouldAcceptDirectEvent(isForegroundActive: Bool) -> Bool {\n        isForegroundActive\n    }",
                "static func shouldAcceptDirectEvent(isForegroundActive: Bool) -> Bool {\n        true\n    }",
            ),
            (
                "ios/QuakeSignal/Networking/WolfxClient.swift",
                "configuration.requestCachePolicy = .reloadIgnoringLocalCacheData",
                "configuration.requestCachePolicy = .returnCacheDataElseLoad",
            ),
        )
        for path, old, new in mutations:
            with self.subTest(path=path):
                mutated = dict(sources)
                mutated[path] = mutated[path].replace(old, new, 1)
                self.assertNotEqual(mutated[path], sources[path])
                with self.assertRaisesRegex(
                    guard.ReleaseGuardError,
                    "platform capability policy fingerprint",
                ):
                    guard.verify_platform_capabilities_sources(mutated)

    def test_platform_capability_policy_rejects_screenshot_fixture_gate_mutations(self):
        sources = {
            relative: (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")
            for relative in guard.PLATFORM_CAPABILITY_POLICY_PATHS
        }
        path = "ios/QuakeSignalShared/ScreenshotAutomation.swift"
        self.assertIn(path, guard.PLATFORM_CAPABILITY_POLICY_PATHS)
        mutations = (
            (
                "#if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))\n        selectedFrame != nil",
                "#if DEBUG\n        selectedFrame != nil",
            ),
            (
                "#if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))\n        guard let captureTarget = currentCaptureTarget else { return nil }",
                "#if targetEnvironment(simulator)\n        guard let captureTarget = currentCaptureTarget else { return nil }",
            ),
            (
                "#else\n        []\n#endif",
                "#else\n        fixtureEventsForRelease\n#endif",
            ),
        )
        for old, new in mutations:
            with self.subTest(replacement=new):
                mutated = dict(sources)
                mutated[path] = mutated[path].replace(old, new, 1)
                self.assertNotEqual(mutated[path], sources[path])
                with self.assertRaisesRegex(
                    guard.ReleaseGuardError,
                    "platform capability policy fingerprint",
                ):
                    guard.verify_platform_capabilities_sources(mutated)

    def test_python_source_gate_rejects_executable_xcode_graph_drift(self):
        project = (REPOSITORY_ROOT / guard.XCODE_SOURCE_GRAPH_PATHS[0]).read_text(encoding="utf-8")
        generated = (REPOSITORY_ROOT / guard.XCODE_SOURCE_GRAPH_PATHS[1]).read_text(encoding="utf-8")

        compiler_wrapper = project.replace(
            "        Release:\n          CODE_SIGN_IDENTITY: Apple Distribution\n",
            "        Release:\n          SWIFT_EXEC: /tmp/unreviewed-compiler-wrapper\n"
            "          CODE_SIGN_IDENTITY: Apple Distribution\n",
            1,
        )
        self.assertNotEqual(compiler_wrapper, project)
        with self.assertRaisesRegex(guard.ReleaseGuardError, "source Xcode graph fingerprint"):
            guard.verify_xcode_source_graph_fingerprint(compiler_wrapper, generated)

        build_script = project.replace(
            "targets:\n",
            "preBuildScripts:\n  - script: /tmp/unreviewed-build-script\ntargets:\n",
            1,
        )
        with self.assertRaisesRegex(guard.ReleaseGuardError, "preBuildScripts"):
            guard.verify_project_executable_graph(build_script, generated)

        with self.assertRaisesRegex(guard.ReleaseGuardError, "PBXShellScriptBuildPhase"):
            guard.verify_project_executable_graph(
                project,
                generated + "\n/* PBXShellScriptBuildPhase */\n",
            )

    def test_python_source_gate_rejects_shared_scheme_drift(self):
        sources = {
            relative: (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")
            for relative in guard.XCODE_SCHEME_PATHS
        }
        mutated = dict(sources)
        mutated[guard.XCODE_SCHEME_PATHS[0]] += "\n<!-- unreviewed scheme action -->\n"
        with self.assertRaisesRegex(guard.ReleaseGuardError, "shared archive scheme fingerprint"):
            guard.verify_shared_scheme_sources(mutated)

    def test_python_source_gate_rejects_extra_release_entitlement(self):
        mutated = dict(guard.RELEASE_ALERT_ENTITLEMENTS)
        mutated["com.apple.developer.associated-domains"] = ["applinks:attacker.invalid"]
        with self.assertRaisesRegex(guard.ReleaseGuardError, "exactly the reviewed"):
            guard.verify_release_entitlements(mutated, guard.RELEASE_ENTITLEMENT_PATHS[0])
        with self.assertRaisesRegex(guard.ReleaseGuardError, "exactly the reviewed"):
            guard.verify_release_entitlements(
                {"com.apple.security.app-sandbox": False},
                guard.RELEASE_ENTITLEMENT_PATHS[1],
            )
        with self.assertRaisesRegex(guard.ReleaseGuardError, "exactly the reviewed"):
            guard.verify_release_entitlements(
                {"aps-environment": "production"},
                guard.RELEASE_ENTITLEMENT_PATHS[2],
            )

    def test_source_fingerprint_rejects_development_policy_variables(self):
        config = guard.strict_json_loads(
            guard.strip_json_comments(
                (REPOSITORY_ROOT / "backend/cloudflare/wrangler.jsonc").read_text(encoding="utf-8")
            )
        )
        for key in ("APP_ATTEST_DEVELOPMENT_BYPASS", "APP_ATTEST_DEVELOPMENT_ENVIRONMENT"):
            with self.subTest(key=key):
                mutated = copy.deepcopy(config)
                mutated["vars"][key] = "true"
                with self.assertRaisesRegex(guard.ReleaseGuardError, "development bypass or environment"):
                    guard.verify_app_attest_variables(mutated["vars"])

    def test_jsonc_trailing_comma_normalization_never_rewrites_strings(self):
        nested = '[{"platform":"ios",}]'
        source = json.dumps({"route": nested, "values": [1]})
        source = source[:-1] + ",}"
        parsed = guard.strict_json_loads(guard.strip_json_comments(source))
        self.assertEqual(parsed["route"], nested)
        with self.assertRaises(ValueError):
            guard.strict_json_loads(parsed["route"])

    def test_jsonc_comments_cannot_concatenate_adjacent_tokens(self):
        normalized = guard.strip_json_comments('{"value":1/* reviewed comment */2}')
        self.assertIn("1  2", normalized)
        with self.assertRaises(ValueError):
            guard.strict_json_loads(normalized)


class LiveWorkerContractTests(unittest.TestCase):
    def fetcher(self, fingerprint=guard.APP_ATTEST_FINGERPRINT, metadata_override=None):
        metadata = copy.deepcopy(metadata_override or ready_metadata(fingerprint))

        def fetch(url, method="GET", headers=None, body=None, timeout=None):
            del headers, timeout
            self.assertTrue(url.startswith(guard.WORKER_ORIGIN))
            path = url[len(guard.WORKER_ORIGIN):]
            response_headers = {
                "cache-control": "no-store",
                "content-type": "application/json; charset=utf-8",
            }
            if path == "/":
                return 200, response_headers, json_bytes(metadata)
            if path in {"/privacy", "/support", "/terms"}:
                contract = next(
                    value for value in guard.LEGAL_PAGE_CONTRACTS
                    if value["path"] == path
                )
                response_headers["content-type"] = "text/html; charset=utf-8"
                markers = (
                    f"<title>{contract['title']} · QuakeSignal</title>",
                    f"QuakeSignal · Effective {contract['effectiveDate']}",
                    *contract["requiredText"],
                )
                return 200, response_headers, "\n".join(markers).encode()
            if path in {"/v1/quakes/recent?limit=5", "/v1/quakes/jma_eew%3Atest", "/v1/live"}:
                return 410, response_headers, b"{}"
            if path == "/v1/app-attest/challenge":
                return 400, response_headers, b"{}"
            if path == "/v1/devices" and method == "POST":
                return (413 if body and len(body) > 9000 else 401), response_headers, b"{}"
            if path in {"/v1/devices", "/v1/devices/test"}:
                return 401, response_headers, b"{}"
            raise AssertionError(f"unexpected request {method} {path}")

        return fetch

    def test_live_release_contract_passes(self):
        guard.verify_live_worker_release(fetcher=self.fetcher())

    def test_live_release_contract_rejects_fingerprint_mutation(self):
        with self.assertRaisesRegex(guard.ReleaseGuardError, "fingerprint"):
            guard.verify_live_worker_release(fetcher=self.fetcher("sha256:" + "A" * 43))

    def test_live_release_contract_rejects_stale_or_incomplete_legal_pages(self):
        for target_path, marker in (
            ("/privacy", "QuakeSignal · Effective 22 August 2026"),
            ("/privacy", "Only the app when running on an iPhone or iPad can register"),
            ("/privacy", "last successfully registered bounded alert area remains in use until the next foreground renewal"),
            ("/privacy", "without a fallback it attempts to delete the stale relay row"),
            ("/privacy", "watches only the jma_eew and jma_eqlist Wolfx feeds"),
            ("/privacy", "does not create an earthquake forecast or predict local intensity or arrival time"),
            ("/support", "support cannot identify the old registration from a public issue"),
            ("/support", "do not predict local intensity or arrival time"),
            ("/terms", "QuakeSignal · Effective 12 August 2026"),
        ):
            with self.subTest(target_path=target_path, marker=marker):
                base_fetcher = self.fetcher()

                def mutated_fetcher(url, **kwargs):
                    status, headers, body = base_fetcher(url, **kwargs)
                    if url[len(guard.WORKER_ORIGIN):] == target_path:
                        body = body.replace(marker.encode(), b"removed-reviewed-marker", 1)
                    return status, headers, body

                with self.assertRaisesRegex(guard.ReleaseGuardError, "legal/support page"):
                    guard.verify_live_worker_release(fetcher=mutated_fetcher)

    def test_live_release_contract_requires_exact_mime_essences(self):
        for target_path, mutated_content_type, message in (
            ("/", "application/jsonp", "service metadata"),
            ("/privacy", "text/html-malware", "legal/support page"),
        ):
            with self.subTest(target_path=target_path):
                base_fetcher = self.fetcher()

                def mutated_fetcher(url, **kwargs):
                    status, headers, body = base_fetcher(url, **kwargs)
                    if url[len(guard.WORKER_ORIGIN):] == target_path:
                        headers = dict(headers)
                        headers["content-type"] = mutated_content_type
                    return status, headers, body

                with self.assertRaisesRegex(guard.ReleaseGuardError, message):
                    guard.verify_live_worker_release(fetcher=mutated_fetcher)

    def test_live_release_contract_rejects_non_exact_bundle_version_list(self):
        for versions in (["8"], [str(value) for value in range(1, 10)], [1, 2, 3, 4, 5, 6, 7, 8]):
            with self.subTest(versions=versions):
                metadata = ready_metadata()
                metadata["appAttestPolicy"]["allowedBundleVersions"] = versions
                with self.assertRaisesRegex(guard.ReleaseGuardError, "allow-list"):
                    guard.verify_live_worker_release(fetcher=self.fetcher(metadata_override=metadata))

    def test_redirect_handler_never_follows(self):
        handler = guard.RejectRedirects()
        self.assertIsNone(handler.redirect_request(None, None, 302, "Found", {}, guard.WORKER_ORIGIN))

    def test_http_response_drip_cannot_extend_the_overall_deadline(self):
        class SlowResponse:
            status = 200
            headers = {}

            def __enter__(self):
                return self

            def __exit__(self, *_arguments):
                return False

            def read(self, _maximum):
                time.sleep(1.0)
                return b"{}"

        class SlowOpener:
            def open(self, _request, timeout):
                self.timeout = timeout
                return SlowResponse()

        opener = SlowOpener()
        started = time.monotonic()
        with patch.object(guard, "build_opener", return_value=opener):
            with self.assertRaisesRegex(guard.ReleaseGuardError, "overall deadline"):
                guard._request(f"{guard.WORKER_ORIGIN}/", timeout=0.05)
        elapsed = time.monotonic() - started
        self.assertLess(
            elapsed,
            0.5,
            f"overall deadline did not interrupt the 1-second response drip: {elapsed:.3f}s",
        )
        self.assertEqual(opener.timeout, 0.05)

    def test_json_parser_rejects_duplicate_keys(self):
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            guard.strict_json_loads(b'{"ok":true,"ok":false}')

    def test_json_parser_rejects_nonstandard_numeric_constants(self):
        for value in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "non-standard JSON constant"):
                    guard.strict_json_loads(f'{{"value":{value}}}')


if __name__ == "__main__":
    unittest.main()
