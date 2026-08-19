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


def source_state():
    return {
        "origin_url": "https://github.com/TastyHeadphones/QuakeSignal.git",
        "head": COMMIT,
        "main": COMMIT,
        "status": "",
    }


def json_bytes(value):
    return json.dumps(value, separators=(",", ":")).encode()


def ready_health(fingerprint=guard.APP_ATTEST_FINGERPRINT):
    return {
        "ok": True,
        "mode": "notification-only",
        "delivery": {
            "status": "ready",
            "apnsConfigured": True,
            "activeDlqIncidents": 0,
        },
        "upstream": {
            "status": "ready",
            "staleSources": [],
            "transport": "http-polling",
            "sources": {
                source: {"stale": False, "transport": "http-polling"}
                for source in guard.REQUIRED_WOLFX_SOURCES
            },
        },
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
        path = guard.PLATFORM_CAPABILITY_POLICY_PATHS[0]
        mutated[path] = mutated[path].replace("#elseif os(visionOS)\n        false", "#elseif os(visionOS)\n        true")
        self.assertNotEqual(mutated[path], sources[path])
        with self.assertRaisesRegex(guard.ReleaseGuardError, "platform capability policy fingerprint"):
            guard.verify_platform_capabilities_sources(mutated)

        wrong_symbol = dict(sources)
        settings_path = guard.PLATFORM_CAPABILITY_POLICY_PATHS[2]
        wrong_symbol[settings_path] = wrong_symbol[settings_path].replace('systemImage: "eye"', 'systemImage: "macbook"', 1)
        with self.assertRaisesRegex(guard.ReleaseGuardError, "platform capability policy fingerprint"):
            guard.verify_platform_capabilities_sources(wrong_symbol)

        mac_specific_copy = dict(sources)
        english_path = guard.PLATFORM_CAPABILITY_POLICY_PATHS[3]
        mac_specific_copy[english_path] = mac_specific_copy[english_path].replace(
            '"platform.alertRegistration.foregroundOnly" = "Foreground monitoring only";',
            '"platform.alertRegistration.foregroundOnly" = "Foreground monitoring on Mac";',
            1,
        )
        with self.assertRaisesRegex(guard.ReleaseGuardError, "platform capability policy fingerprint"):
            guard.verify_platform_capabilities_sources(mac_specific_copy)

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
                {"aps-environment": "production"},
                guard.RELEASE_ENTITLEMENT_PATHS[1],
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
    def fetcher(self, fingerprint=guard.APP_ATTEST_FINGERPRINT, health_override=None):
        health = copy.deepcopy(health_override or ready_health(fingerprint))
        root = {
            "purpose": "APNs alert delivery only",
            "earthquakeData": "Clients fetch directly from Wolfx",
        }

        def fetch(url, method="GET", headers=None, body=None, timeout=None):
            del headers, timeout
            self.assertTrue(url.startswith(guard.WORKER_ORIGIN))
            path = url[len(guard.WORKER_ORIGIN):]
            response_headers = {
                "cache-control": "no-store",
                "content-type": "application/json; charset=utf-8",
            }
            if path == "/healthz":
                return 200, response_headers, json_bytes(health)
            if path == "/":
                return 200, response_headers, json_bytes(root)
            if path in {"/privacy", "/support", "/terms"}:
                titles = {"/privacy": "Privacy Policy", "/support": "Support", "/terms": "Terms of Use"}
                response_headers["content-type"] = "text/html; charset=utf-8"
                return 200, response_headers, f"<title>{titles[path]} · QuakeSignal</title>QuakeSignal".encode()
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

    def test_live_release_contract_requires_exact_mime_essences(self):
        for target_path, mutated_content_type, message in (
            ("/healthz", "application/jsonp", "fully ready"),
            ("/", "application/jsonp", "metadata contract"),
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
                health = ready_health()
                health["appAttestPolicy"]["allowedBundleVersions"] = versions
                with self.assertRaisesRegex(guard.ReleaseGuardError, "allow-list"):
                    guard.verify_live_worker_release(fetcher=self.fetcher(health_override=health))

    def test_readiness_requires_exact_true_apns_configuration(self):
        for value in (False, None, 1, "true"):
            with self.subTest(value=value):
                health = ready_health()
                if value is None:
                    del health["delivery"]["apnsConfigured"]
                else:
                    health["delivery"]["apnsConfigured"] = value
                self.assertFalse(guard._ready(health, 200))

    def test_readiness_requires_exact_fresh_wolfx_source_inventory(self):
        mutations = []
        missing = ready_health()
        del missing["upstream"]["sources"]["jma_eew"]
        mutations.append(missing)
        empty = ready_health()
        empty["upstream"]["sources"] = {}
        mutations.append(empty)
        stale = ready_health()
        stale["upstream"]["sources"]["jma_eew"]["stale"] = True
        mutations.append(stale)
        unavailable = ready_health()
        unavailable["upstream"]["sources"]["jma_eew"]["transport"] = "unavailable"
        mutations.append(unavailable)
        for health in mutations:
            with self.subTest(sources=health["upstream"]["sources"]):
                self.assertFalse(guard._ready(health, 200))

    def test_live_release_contract_requires_integer_zero_dlq_incidents(self):
        for value in (False, 0.0, "0", None, 1):
            with self.subTest(value=value):
                health = ready_health()
                health["delivery"]["activeDlqIncidents"] = value
                with self.assertRaisesRegex(guard.ReleaseGuardError, "DLQ"):
                    guard.verify_live_worker_release(fetcher=self.fetcher(health_override=health))

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
                time.sleep(0.2)
                return b"{}"

        class SlowOpener:
            def open(self, _request, timeout):
                self.timeout = timeout
                return SlowResponse()

        opener = SlowOpener()
        started = time.monotonic()
        with patch.object(guard, "build_opener", return_value=opener):
            with self.assertRaisesRegex(guard.ReleaseGuardError, "overall deadline"):
                guard._request(f"{guard.WORKER_ORIGIN}/healthz", timeout=0.05)
        self.assertLess(time.monotonic() - started, 0.15)
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
