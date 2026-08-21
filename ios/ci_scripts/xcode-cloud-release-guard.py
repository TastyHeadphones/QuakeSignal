#!/usr/bin/env python3
"""Fail-closed, stdlib-only Xcode Cloud release gates for QuakeSignal."""

from __future__ import annotations

import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time
from typing import Any, Callable, Dict, List, Mapping, Optional, Tuple
from urllib.error import HTTPError
from urllib.parse import urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


BUILD_NUMBER = "8"
MARKETING_VERSION = "1.1"
TEAM_ID = "5TT564H883"
RELEASE_REF = "refs/heads/main"
RELEASE_WORKFLOW = "QuakeSignal 1.1 (8) Native Release"
PRODUCT_NAME = "QuakeSignal"
WORKER_ORIGIN = "https://quakesignal-api.hopeso.workers.dev"
VISION_LOCATION_USAGE_DESCRIPTION = "QuakeSignal uses your location to show distance and nearby earthquake context while the app is open."
MAIN_REMOTE_URL = "https://github.com/TastyHeadphones/QuakeSignal.git"
APP_ATTEST_FINGERPRINT = "sha256:wQ7bfMyEJST5ySIwLM1Q6HwT4DtbRPR3vanIG-kXCkQ"
XCODE_SOURCE_GRAPH_FINGERPRINT = "sha256:FPPp_gIATLoIgEwcBZj9tufNpZtlB8qw9dm3ZhacE0k"
XCODE_SCHEMES_FINGERPRINT = "sha256:d1cqEp5M_rdKeYqcsAGXC45NKBHJLieE7oLLChhMCqo"
PLATFORM_CAPABILITIES_FINGERPRINT = "sha256:toLX1XB92g900YQMVNdY6b_qs9oHUEVANOZMzpJrM3Q"
POLICY_FORMAT = "quakesignal-app-attest-policy/v2"
MAX_RESPONSE_BYTES = 1024 * 1024
READINESS_TIMEOUT_SECONDS = 180.0
REQUEST_TIMEOUT_SECONDS = 15.0
READINESS_INTERVAL_SECONDS = 5.0
REPOSITORY_URLS = frozenset(
    {
        "https://github.com/TastyHeadphones/QuakeSignal",
        "https://github.com/TastyHeadphones/QuakeSignal.git",
        "git@github.com:TastyHeadphones/QuakeSignal.git",
        "ssh://git@github.com/TastyHeadphones/QuakeSignal.git",
    }
)
TARGETS = {
    "QuakeSignal": {"platform": "iOS", "verifier": "ios", "bundle": "com.quakesignal.app"},
    "QuakeSignalTV": {"platform": "tvOS", "verifier": "tvos", "bundle": "com.quakesignal.app"},
    "QuakeSignalVision": {"platform": "visionOS", "verifier": "visionos", "bundle": "com.quakesignal.app"},
}
MAC_CATALYST_TARGET = {
    "platform": "macOS",
    "verifier": "maccatalyst",
    "bundle": "com.quakesignal.app",
}
DOCUMENTED_PRODUCT_PLATFORMS = frozenset({"iOS", "macOS", "tvOS", "watchOS"})
REVIEWED_ROUTES = [
    {
        "appIdentity": "5TT564H883.com.quakesignal.app",
        "apnsTopic": "com.quakesignal.app",
        "platform": "ios",
    }
]
XCODE_SOURCE_GRAPH_PATHS = (
    "ios/project.yml",
    "ios/QuakeSignal.xcodeproj/project.pbxproj",
)
XCODE_SCHEME_PATHS = (
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignal.xcscheme",
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalTV.xcscheme",
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalVision.xcscheme",
    "ios/QuakeSignal.xcodeproj/xcshareddata/xcschemes/QuakeSignalWatch.xcscheme",
)
PLATFORM_CAPABILITY_POLICY_PATHS = (
    "ios/QuakeSignal/App/AppDelegate.swift",
    "ios/QuakeSignal/App/PlatformCapabilities.swift",
    "ios/QuakeSignal/App/QuakeSignalApp.swift",
    "ios/QuakeSignal/Features/Detail/QuakeDetailView.swift",
    "ios/QuakeSignal/Features/Guide/DisasterGuideView.swift",
    "ios/QuakeSignal/Features/Map/EpicenterMapView.swift",
    "ios/QuakeSignal/Features/Onboarding/OnboardingView.swift",
    "ios/QuakeSignal/Features/Root/RootView.swift",
    "ios/QuakeSignal/Features/List/QuakeListView.swift",
    "ios/QuakeSignal/Features/Home/QuakeRowView.swift",
    "ios/QuakeSignal/Features/Settings/SourceDisclaimerView.swift",
    "ios/QuakeSignal/Features/Settings/SettingsView.swift",
    "ios/QuakeSignal/Models/EEWEvent.swift",
    "ios/QuakeSignal/Networking/ForegroundHTTPFallbackPolicy.swift",
    "ios/QuakeSignal/Networking/LiveSocketClient.swift",
    "ios/QuakeSignal/Networking/WolfxClient.swift",
    "ios/QuakeSignal/Notifications/EmergencyAlertAudio.swift",
    "ios/QuakeSignal/Notifications/NotificationManager.swift",
    "ios/QuakeSignal/Notifications/PushPayload.swift",
    "ios/QuakeSignal/State/AlertPolicy.swift",
    "ios/QuakeSignal/State/AppSettings.swift",
    "ios/QuakeSignal/State/LocationManager.swift",
    "ios/QuakeSignal/State/QuakeStore.swift",
    "ios/QuakeSignalShared/AlertSoundPreference.swift",
    "ios/QuakeSignalShared/ForegroundQuakeStore.swift",
    "ios/QuakeSignalShared/ScreenshotAutomation.swift",
    "ios/QuakeSignalShared/WatchAlertPreferenceBridge.swift",
    "ios/QuakeSignalShared/WatchForegroundEmergencyPolicy.swift",
    "ios/QuakeSignalTV/TVAlertPreferences.swift",
    "ios/QuakeSignalTV/TVAlertSoundSettingsView.swift",
    "ios/QuakeSignalTV/TVDashboardView.swift",
    "ios/QuakeSignalTV/TVEmergencyAlertView.swift",
    "ios/QuakeSignalTV/TVEmergencyMonitor.swift",
    "ios/QuakeSignalTV/TVEmergencyPresentationPolicy.swift",
    "ios/QuakeSignalTV/TVUserInitiatedAlertAudio.swift",
    "ios/QuakeSignalTV/Supporting/PrivacyInfo.xcprivacy",
    "ios/QuakeSignalWatch/QuakeSignalWatchApp.swift",
    "ios/QuakeSignalWatch/WatchDashboardView.swift",
    "ios/QuakeSignalWatch/WatchEmergencyAlertAudio.swift",
    "ios/QuakeSignalWatch/WatchForegroundEmergencyMonitor.swift",
    "ios/QuakeSignalWatch/Supporting/PrivacyInfo.xcprivacy",
    "ios/QuakeSignal/Resources/PrivacyInfo.xcprivacy",
    "ios/QuakeSignal/Resources/en.lproj/Localizable.strings",
    "ios/QuakeSignal/Resources/ja.lproj/Localizable.strings",
    "ios/QuakeSignal/Resources/zh-Hans.lproj/Localizable.strings",
    "ios/QuakeSignalVision/Resources/PrivacyInfo.xcprivacy",
)
FOREGROUND_PRIVACY_MANIFEST_PATHS = (
    "ios/QuakeSignalTV/Supporting/PrivacyInfo.xcprivacy",
    "ios/QuakeSignalVision/Resources/PrivacyInfo.xcprivacy",
    "ios/QuakeSignalWatch/Supporting/PrivacyInfo.xcprivacy",
)
RELEASE_ENTITLEMENT_PATHS = (
    "ios/QuakeSignal/Supporting/QuakeSignal-Release.entitlements",
    "ios/QuakeSignal/Supporting/QuakeSignal-Catalyst.entitlements",
    "ios/QuakeSignalVision/Supporting/QuakeSignalVision-Release.entitlements",
)
RELEASE_ALERT_ENTITLEMENTS = {
    "aps-environment": "production",
    "com.apple.developer.devicecheck.appattest-environment": "production",
    "com.apple.developer.usernotifications.time-sensitive": True,
}
RELEASE_CATALYST_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.network.client": True,
    "com.apple.security.personal-information.location": True,
}
RELEASE_TARGET_NAMES = (
    "QuakeSignal",
    "QuakeSignalTV",
    "QuakeSignalTests",
    "QuakeSignalVision",
    "QuakeSignalWatch",
)
ARCHIVE_SCHEME_NAMES = (
    "QuakeSignal",
    "QuakeSignalTV",
    "QuakeSignalVision",
    "QuakeSignalWatch",
)
REQUIRED_WOLFX_SOURCES = (
    "jma_eew",
    "jma_eqlist",
)
LEGAL_PAGE_CONTRACTS = (
    {
        "path": "/privacy",
        "title": "Privacy Policy",
        "effectiveDate": "20 August 2026",
        "requiredText": (
            "Only the app when running on an iPhone or iPad can register",
            "embedded Apple Watch companion and Apple TV app",
            "encrypted WebSocket and HTTPS connections while open",
            "selected alert presentation mode locally",
            "Apple Vision Pro and Mac Catalyst",
            "separate Windows desktop app, legacy Tauri macOS builds (dormant for Apple release 1.1 build 8), and Chrome extension",
            "optional family contact name and telephone number stay in local app storage",
            "erase both Family Check-In fields and uncheck each selected preparedness-kit item",
            "Apple Maps and system Location Services",
            "opening this public page sends ordinary web-request metadata to Cloudflare",
            "do not provide background emergency alerts",
            "a public support issue cannot privately identify or delete that unreachable registration",
            "An old registration becomes eligible for deletion after it has not been refreshed for 90 days",
            "event rows and their revision history become eligible for deletion after 89 days",
            "training-test claim becomes eligible for deletion after 14 days",
            "App Attest challenge becomes invalid in no more than five minutes",
            "delivery-failure token hashes become eligible for deletion after 14 days",
            "next successful daily cleanup",
            "operational cleanup failure can delay deletion",
            "watches only the jma_eew and jma_eqlist Wolfx feeds",
            "does not create an earthquake forecast or predict local intensity or arrival time",
        ),
    },
    {
        "path": "/support",
        "title": "Support",
        "effectiveDate": "20 August 2026",
        "requiredText": (
            "iPhone and iPad alerts",
            "embedded Apple Watch companion and Apple TV app",
            "native Watch warning haptic",
            "System is visual-only on Apple TV",
            "custom Apple TV audio requires an explicit Siri Remote action",
            "Apple Vision Pro and Mac Catalyst",
            "separate Windows desktop app, legacy Tauri macOS builds (dormant for Apple release 1.1 build 8), and Chrome extension",
            "do not independently use the QuakeSignal notification relay",
            "Registration removal after a reset",
            "support cannot identify the old registration from a public issue",
            "becomes eligible for deletion after it has not been refreshed for 90 days",
            "next successful daily cleanup",
            "operational cleanup failure can delay deletion",
            "Never include an APNs device token",
            "selected JMA feed type",
            "do not predict local intensity or arrival time",
        ),
    },
    {
        "path": "/terms",
        "title": "Terms of Use",
        "effectiveDate": "12 August 2026",
        "requiredText": (),
    },
)


class ReleaseGuardError(RuntimeError):
    pass


class RequestDeadlineExceeded(TimeoutError):
    pass


class RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


def fail(message: str) -> None:
    raise ReleaseGuardError(f"Xcode Cloud release guard: {message}")


@contextmanager
def overall_request_deadline(seconds: float):
    if seconds <= 0 or not hasattr(signal, "setitimer"):
        fail("a positive macOS wall-clock request deadline is required.")
    if signal.getitimer(signal.ITIMER_REAL) != (0.0, 0.0):
        fail("an inherited process alarm prevents an isolated Worker request deadline.")
    previous_handler = signal.getsignal(signal.SIGALRM)

    def deadline_exceeded(_signum, _frame):  # type: ignore[no-untyped-def]
        raise RequestDeadlineExceeded(f"Worker request exceeded its {seconds:.3f}s deadline")

    try:
        signal.signal(signal.SIGALRM, deadline_exceeded)
    except ValueError:
        fail("Worker request deadline must run on the Python main thread.")
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0.0)
        signal.signal(signal.SIGALRM, previous_handler)


def exact(environment: Mapping[str, str], key: str, expected: str) -> None:
    actual = environment.get(key, "")
    if actual != expected:
        fail(f"{key} must be exactly {expected!r} (received {actual!r}).")


def absent(environment: Mapping[str, str], key: str) -> None:
    if environment.get(key, ""):
        fail(f"{key} must be absent for a protected manual main release.")


def run_git(repository_root: Optional[Path], arguments: List[str]) -> str:
    forbidden_tool_environment = {
        "CURL_CA_BUNDLE",
        "DEVELOPER_DIR",
        "SDKROOT",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "TOOLCHAINS",
    }
    git_environment = {
        key: value
        for key, value in os.environ.items()
        if not key.upper().startswith("GIT_") and key.upper() not in forbidden_tool_environment
    }
    git_environment.update({
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    })
    try:
        completed = subprocess.run(
            ["/usr/bin/git", *arguments],
            cwd=repository_root if repository_root is not None else Path("/tmp"),
            check=True,
            env=git_environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = ""
        if isinstance(error, subprocess.CalledProcessError):
            detail = (error.stderr or "").strip()
        fail(f"git {' '.join(arguments)} failed{': ' + detail if detail else '.'}")
    return completed.stdout.strip()


def capture_source_state(repository_root: Path) -> Dict[str, str]:
    origin_url = run_git(repository_root, ["remote", "get-url", "origin"])
    if origin_url not in REPOSITORY_URLS:
        fail("origin must be the reviewed TastyHeadphones/QuakeSignal GitHub repository.")
    remote = run_git(
        None,
        [
            "-c",
            "http.followRedirects=false",
            "ls-remote",
            "--exit-code",
            "--refs",
            MAIN_REMOTE_URL,
            RELEASE_REF,
        ],
    )
    lines = [line.split() for line in remote.splitlines() if line.strip()]
    if len(lines) != 1 or len(lines[0]) != 2 or lines[0][1] != RELEASE_REF:
        fail("git ls-remote must return exactly refs/heads/main.")
    return {
        "origin_url": origin_url,
        "head": run_git(repository_root, ["rev-parse", "HEAD"]),
        "main": lines[0][0],
        "status": run_git(repository_root, ["status", "--porcelain=v1", "--untracked-files=all"]),
    }


def verify_context(
    environment: Mapping[str, str],
    *,
    phase: str,
    repository_root: Optional[Path] = None,
    source_state: Optional[Mapping[str, str]] = None,
) -> Optional[Dict[str, Any]]:
    if environment.get("CI_XCODEBUILD_ACTION") != "archive":
        if (
            environment.get("CI_WORKFLOW") == RELEASE_WORKFLOW
            or environment.get("QUAKESIGNAL_RELEASE_REF")
            or environment.get("QUAKESIGNAL_RELEASE_COMMIT")
            or environment.get("QUAKESIGNAL_RELEASE_PRODUCT_ID")
            or environment.get("QUAKESIGNAL_RELEASE_WORKFLOW_ID")
        ):
            exact(environment, "CI_XCODEBUILD_ACTION", "archive")
        return None
    exact(environment, "CI", "TRUE")
    exact(environment, "CI_XCODE_CLOUD", "TRUE")
    exact(environment, "CI_XCODEBUILD_ACTION", "archive")
    exact(environment, "CI_START_CONDITION", "manual")
    exact(environment, "QUAKESIGNAL_RELEASE_REF", RELEASE_REF)
    if environment.get("CI_BRANCH"):
        exact(environment, "CI_BRANCH", "main")
    if environment.get("CI_GIT_REF"):
        exact(environment, "CI_GIT_REF", RELEASE_REF)
    exact(environment, "CI_BUILD_NUMBER", BUILD_NUMBER)
    exact(environment, "CI_TEAM_ID", TEAM_ID)
    exact(environment, "CI_PRODUCT", PRODUCT_NAME)
    exact(environment, "CI_WORKFLOW", RELEASE_WORKFLOW)
    product_id = environment.get("CI_PRODUCT_ID", "")
    if not product_id or len(product_id) > 256 or any(ord(char) < 32 or ord(char) == 127 for char in product_id):
        fail("CI_PRODUCT_ID must be Apple's nonempty, control-free Xcode Cloud product identifier.")
    exact(environment, "QUAKESIGNAL_RELEASE_PRODUCT_ID", product_id)
    workflow_id = environment.get("CI_WORKFLOW_ID", "")
    if not workflow_id or len(workflow_id) > 256 or any(
        ord(char) < 32 or ord(char) == 127 for char in workflow_id
    ):
        fail("CI_WORKFLOW_ID must be Apple's nonempty, control-free Xcode Cloud workflow identifier.")
    exact(environment, "QUAKESIGNAL_RELEASE_WORKFLOW_ID", workflow_id)
    for key in (
        "CI_TAG",
        "CI_PULL_REQUEST_NUMBER",
        "CI_PULL_REQUEST_SOURCE_COMMIT",
        "CI_PULL_REQUEST_TARGET_COMMIT",
    ):
        absent(environment, key)
    for key in ("CURL_CA_BUNDLE", "SSL_CERT_DIR", "SSL_CERT_FILE"):
        absent(environment, key)

    commit = environment.get("CI_COMMIT", "")
    if re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", commit) is None:
        fail("CI_COMMIT must be a lowercase 40- or 64-character Git object ID.")
    exact(environment, "QUAKESIGNAL_RELEASE_COMMIT", commit)

    project_path = Path(environment.get("CI_PROJECT_FILE_PATH", ""))
    if not project_path.is_absolute() or project_path.as_posix().endswith("/ios/QuakeSignal.xcodeproj") is False:
        fail("CI_PROJECT_FILE_PATH must be the absolute ios/QuakeSignal.xcodeproj path.")
    if repository_root is not None and project_path != repository_root / "ios/QuakeSignal.xcodeproj":
        fail("CI_PROJECT_FILE_PATH does not belong to the verified primary repository checkout.")

    scheme = environment.get("CI_XCODE_SCHEME", "")
    reported_platform = environment.get("CI_PRODUCT_PLATFORM", "")
    target = (
        MAC_CATALYST_TARGET
        if scheme == "QuakeSignal" and reported_platform == "macOS"
        else TARGETS.get(scheme)
    )
    if target is None:
        fail(
            "CI_XCODE_SCHEME must be QuakeSignal for iOS or Mac Catalyst, "
            "QuakeSignalTV, or QuakeSignalVision; Watch is embedded only."
        )
    exact(environment, "CI_BUNDLE_ID", str(target["bundle"]))
    if target["verifier"] == "visionos":
        if not reported_platform:
            fail("CI_PRODUCT_PLATFORM must be present for the Vision archive action.")
        if reported_platform in DOCUMENTED_PRODUCT_PLATFORMS:
            fail(f"CI_PRODUCT_PLATFORM {reported_platform!r} is a documented non-Vision platform.")
        if reported_platform not in {"visionOS", "xrOS"}:
            print(
                "::warning::Apple does not document the Vision CI_PRODUCT_PLATFORM value; "
                f"received {reported_platform!r}. The exported profile must still prove visionOS/xrOS.",
                file=sys.stderr,
            )
    elif reported_platform != target["platform"]:
        fail(f"CI_PRODUCT_PLATFORM must be exactly {target['platform']!r} for {scheme}.")

    if phase == "post-clone":
        if repository_root is None:
            fail("post-clone requires the primary repository path.")
        state = dict(source_state or capture_source_state(repository_root))
        if state.get("origin_url") not in REPOSITORY_URLS:
            fail("main proof must come from the reviewed GitHub origin.")
        if state.get("head") != commit:
            fail("checked-out HEAD does not match CI_COMMIT.")
        if state.get("main") != commit:
            fail("remote refs/heads/main does not match CI_COMMIT.")
        if state.get("status") != "":
            fail("the primary repository must be clean, including untracked files.")
    return {
        "scheme": scheme,
        **target,
        "commit": commit,
        "product_id": product_id,
        "workflow_id": workflow_id,
    }


def strip_json_comments(source: str) -> str:
    output: List[str] = []
    index = 0
    in_string = False
    escaped = False
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if in_string:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            output.append(char)
            index += 1
            continue
        if char == "/" and next_char == "/":
            output.append(" ")
            index += 2
            while index < len(source) and source[index] not in "\r\n":
                index += 1
            continue
        if char == "/" and next_char == "*":
            end = source.find("*/", index + 2)
            if end < 0:
                fail("wrangler.jsonc contains an unterminated comment.")
            output.append(" ")
            output.extend(character for character in source[index + 2:end] if character in "\r\n")
            output.append(" ")
            index = end + 2
            continue
        output.append(char)
        index += 1
    without_comments = "".join(output)
    normalized: List[str] = []
    index = 0
    in_string = False
    escaped = False
    while index < len(without_comments):
        char = without_comments[index]
        if in_string:
            normalized.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            normalized.append(char)
            index += 1
            continue
        if char == ",":
            lookahead = index + 1
            while lookahead < len(without_comments) and without_comments[lookahead].isspace():
                lookahead += 1
            if lookahead < len(without_comments) and without_comments[lookahead] in "}]":
                index += 1
                continue
        normalized.append(char)
        index += 1
    return "".join(normalized)


def strict_json_loads(source: Any) -> Any:
    def unique_object(pairs):  # type: ignore[no-untyped-def]
        value: Dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"duplicate JSON key {key!r}")
            value[key] = item
        return value

    def reject_constant(value: str) -> None:
        raise ValueError(f"non-standard JSON constant {value!r}")

    return json.loads(
        source,
        object_pairs_hook=unique_object,
        parse_constant=reject_constant,
    )


def verify_app_attest_variables(variables: Mapping[str, Any]) -> None:
    if "APP_ATTEST_DEVELOPMENT_BYPASS" in variables or "APP_ATTEST_DEVELOPMENT_ENVIRONMENT" in variables:
        fail("checked-in Worker App Attest policy must not define a development bypass or environment.")


def calculate_app_attest_fingerprint(repository_root: Path) -> str:
    try:
        config = strict_json_loads(
            strip_json_comments(
                (repository_root / "backend/cloudflare/wrangler.jsonc").read_text(encoding="utf-8")
            )
        )
    except (OSError, TypeError, ValueError) as error:
        fail(f"could not parse the checked-in Worker App Attest policy: {error}")
    if not isinstance(config, dict) or not isinstance(config.get("vars"), dict):
        fail("checked-in Worker config must contain a vars JSON object.")
    variables = config["vars"]
    verify_app_attest_variables(variables)
    if variables.get("APP_ATTEST_ENFORCEMENT") != "required":
        fail("APP_ATTEST_ENFORCEMENT must be required.")
    if variables.get("APP_ATTEST_APP_ID") != "5TT564H883.com.quakesignal.app":
        fail("APP_ATTEST_APP_ID is not the reviewed app identity.")
    if variables.get("APP_ATTEST_REQUIRE_RELEASE_METADATA") != "false":
        fail("APP_ATTEST_REQUIRE_RELEASE_METADATA must match the reviewed policy.")
    allowed_source = variables.get("APP_ATTEST_ALLOWED_BUNDLE_VERSIONS")
    routes_source = variables.get("APP_ATTEST_APNS_ROUTES")
    if not isinstance(allowed_source, str) or not isinstance(routes_source, str):
        fail("checked-in Worker App Attest allow-list and routes must be JSON strings.")
    allowed = sorted(part.strip() for part in allowed_source.split(","))
    if allowed != [str(value) for value in range(1, 9)]:
        fail("APP_ATTEST_ALLOWED_BUNDLE_VERSIONS must be exactly 1 through 8.")
    try:
        routes = strict_json_loads(routes_source)
    except (TypeError, ValueError) as error:
        fail(f"could not parse APP_ATTEST_APNS_ROUTES: {error}")
    if routes != REVIEWED_ROUTES:
        fail("APP_ATTEST_APNS_ROUTES does not match the reviewed iOS route.")
    policy = "\n".join(
        (
            f"app_id={variables['APP_ATTEST_APP_ID']}",
            "protocol_version=1",
            "required=true",
            "development_bypass_allowed=false",
            "verification_environment=production",
            "require_release_metadata=false",
            f"allowed_bundle_versions={','.join(allowed)}",
            f"app_attest_apns_routes={json.dumps(routes, separators=(',', ':'))}",
            "",
        )
    )
    digest = base64.urlsafe_b64encode(hashlib.sha256(policy.encode()).digest()).decode().rstrip("=")
    return f"sha256:{digest}"


def yaml_mapping_block(source: str, name: str, indent: int) -> List[str]:
    lines = source.splitlines()
    header = f"{' ' * indent}{name}:"
    starts = [index for index, line in enumerate(lines) if line == header]
    if len(starts) != 1:
        fail(f"ios/project.yml must contain exactly one {name!r} mapping at indentation {indent}.")
    start = starts[0] + 1
    end = len(lines)
    for index in range(start, len(lines)):
        line = lines[index]
        if not line.strip():
            continue
        line_indent = len(line) - len(line.lstrip(" "))
        if line_indent <= indent:
            end = index
            break
    return lines[start:end]


def yaml_child_mapping_keys(lines: List[str], indent: int) -> List[str]:
    pattern = re.compile(r"^" + (" " * indent) + r"([A-Za-z0-9_.-]+):(?:\s.*)?$")
    keys: List[str] = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = pattern.match(line)
        if match:
            keys.append(match.group(1))
    return keys


def reviewed_content_fingerprint(files: List[Dict[str, str]]) -> str:
    canonical = json.dumps(
        files,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    digest = base64.urlsafe_b64encode(hashlib.sha256(canonical).digest()).decode().rstrip("=")
    return f"sha256:{digest}"


def reviewed_file_fingerprint(repository_root: Path, relative_paths: Tuple[str, ...]) -> str:
    files = [
        {
            "path": relative_path,
            "source": (repository_root / relative_path).read_text(encoding="utf-8"),
        }
        for relative_path in relative_paths
    ]
    return reviewed_content_fingerprint(files)


def verify_project_executable_graph(project: str, generated: str) -> None:
    forbidden_keys = (
        "buildRules",
        "buildToolPlugins",
        "include",
        "package",
        "packages",
        "postActions",
        "postBuildScripts",
        "postCompileScripts",
        "preActions",
        "preBuildScripts",
        "projectReferences",
        "schemeTemplates",
        "targetTemplates",
        "templates",
    )
    for key in forbidden_keys:
        if re.search(rf"^\s*{re.escape(key)}:\s*(?:#.*)?$", project, re.MULTILINE):
            fail(f"ios/project.yml contains forbidden executable surface {key}.")

    targets_lines = yaml_mapping_block(project, "targets", 0)
    target_names = sorted(yaml_child_mapping_keys(targets_lines, 2))
    if target_names != sorted(RELEASE_TARGET_NAMES):
        fail("ios/project.yml target inventory is not the exact reviewed five-target graph.")
    targets_source = "\n".join(targets_lines)
    for target_name in RELEASE_TARGET_NAMES:
        target_lines = yaml_mapping_block(targets_source, target_name, 2)
        target_source = "\n".join(target_lines)
        if re.search(r"^\s{4}configFiles:\s*$", target_source, re.MULTILINE):
            config_files = "\n".join(yaml_mapping_block(target_source, "configFiles", 4))
            if re.search(r"^\s{6}(?:Release|InternalQA):\s+[^#\s]", config_files, re.MULTILINE):
                fail(f"{target_name} must not load an unreviewed Release/InternalQA xcconfig.")

        has_dependencies = re.search(r"^\s{4}dependencies:\s*$", target_source, re.MULTILINE) is not None
        if target_name in {"QuakeSignal", "QuakeSignalTests"}:
            if not has_dependencies:
                fail(f"{target_name} is missing its reviewed target dependency.")
            dependency_lines = [
                line.strip()
                for line in yaml_mapping_block(target_source, "dependencies", 4)
                if line.strip() and not line.lstrip().startswith("#")
            ]
            expected = (
                ["- target: QuakeSignalWatch", "embed: true", "platformFilter: iOS"]
                if target_name == "QuakeSignal"
                else ["- target: QuakeSignal"]
            )
            if dependency_lines != expected:
                fail(f"{target_name} target dependencies do not match the reviewed graph.")
        elif has_dependencies:
            dependency_lines = [
                line.strip()
                for line in yaml_mapping_block(target_source, "dependencies", 4)
                if line.strip() and not line.lstrip().startswith("#")
            ]
            if dependency_lines:
                fail(f"{target_name} must not acquire an archive-time dependency.")

    schemes_lines = yaml_mapping_block(project, "schemes", 0)
    scheme_names = sorted(yaml_child_mapping_keys(schemes_lines, 2))
    if scheme_names != sorted(ARCHIVE_SCHEME_NAMES):
        fail("ios/project.yml scheme inventory is not the exact reviewed archive graph.")
    schemes_source = "\n".join(schemes_lines)
    for scheme_name in ARCHIVE_SCHEME_NAMES:
        scheme_lines = yaml_mapping_block(schemes_source, scheme_name, 2)
        scheme_source = "\n".join(scheme_lines)
        expected_actions = (
            ["archive", "build", "test"]
            if scheme_name == "QuakeSignal"
            else ["archive", "build", "run"]
        )
        if sorted(yaml_child_mapping_keys(scheme_lines, 4)) != expected_actions:
            fail(f"{scheme_name} scheme contains an unreviewed action.")
        build_source = "\n".join(yaml_mapping_block(scheme_source, "build", 4))
        target_lines = yaml_mapping_block(build_source, "targets", 6)
        build_targets = [
            line.strip()
            for line in target_lines
            if line.strip() and not line.lstrip().startswith("#")
        ]
        if build_targets != [f"{scheme_name}: all"]:
            fail(f"{scheme_name} scheme must build only its reviewed archive target.")
        archive_lines = [
            line.strip()
            for line in yaml_mapping_block(scheme_source, "archive", 4)
            if line.strip() and not line.lstrip().startswith("#")
        ]
        if archive_lines != ["config: Release"]:
            fail(f"{scheme_name} archive action must be exactly Release.")

    for forbidden in (
        "PBXAggregateTarget",
        "PBXBuildRule",
        "PBXLegacyTarget",
        "PBXShellScriptBuildPhase",
        "XCRemoteSwiftPackageReference",
        "XCSwiftPackageProductDependency",
        "shellScript =",
    ):
        if forbidden in generated:
            fail(f"generated Xcode project contains forbidden executable surface {forbidden}.")
    target_names = sorted(re.findall(
        r"^\s*[A-F0-9]+ /\* ([^*]+) \*/ = \{\s*\n\s*isa = PBXNativeTarget;",
        generated,
        re.MULTILINE,
    ))
    if target_names != sorted(RELEASE_TARGET_NAMES):
        fail("generated Xcode project native-target inventory is not exact.")
    phase_types = re.findall(r"isa = (PBX[A-Za-z0-9]+BuildPhase);", generated)
    if (
        len(phase_types) != 10
        or phase_types.count("PBXSourcesBuildPhase") != 5
        or phase_types.count("PBXResourcesBuildPhase") != 4
        or phase_types.count("PBXCopyFilesBuildPhase") != 1
    ):
        fail("generated Xcode project build-phase inventory is not exact.")
    dependency_targets = sorted(re.findall(
        r"/\* PBXTargetDependency \*/ = \{[\s\S]*?\n\s*target = [A-F0-9]+ /\* ([^*]+) \*/;",
        generated,
    ))
    if dependency_targets != ["QuakeSignal", "QuakeSignalWatch"]:
        fail("generated Xcode project target dependencies are not exact.")


def verify_xcode_source_graph_fingerprint(project: str, generated: str) -> None:
    fingerprint = reviewed_content_fingerprint([
        {"path": XCODE_SOURCE_GRAPH_PATHS[0], "source": project},
        {"path": XCODE_SOURCE_GRAPH_PATHS[1], "source": generated},
    ])
    if fingerprint != XCODE_SOURCE_GRAPH_FINGERPRINT:
        fail(
            f"source Xcode graph fingerprint {fingerprint} does not match "
            f"{XCODE_SOURCE_GRAPH_FINGERPRINT}."
        )


def verify_shared_scheme_sources(sources: Mapping[str, str]) -> None:
    if sorted(sources) != sorted(XCODE_SCHEME_PATHS):
        fail("shared archive scheme inventory is incomplete or expanded.")
    fingerprint = reviewed_content_fingerprint([
        {"path": relative_path, "source": sources[relative_path]}
        for relative_path in XCODE_SCHEME_PATHS
    ])
    if fingerprint != XCODE_SCHEMES_FINGERPRINT:
        fail(
            f"shared archive scheme fingerprint {fingerprint} does not match "
            f"{XCODE_SCHEMES_FINGERPRINT}."
        )


def verify_release_entitlements(entitlements: Any, label: str) -> None:
    if label.endswith("QuakeSignal-Release.entitlements"):
        expected = RELEASE_ALERT_ENTITLEMENTS
    elif label.endswith("QuakeSignal-Catalyst.entitlements"):
        expected = RELEASE_CATALYST_ENTITLEMENTS
    else:
        expected = {}
    if entitlements != expected:
        capability = (
            "production alert"
            if expected == RELEASE_ALERT_ENTITLEMENTS
            else "sandboxed foreground-only Catalyst"
            if expected == RELEASE_CATALYST_ENTITLEMENTS
            else "foreground-only"
        )
        fail(f"{label} must contain exactly the reviewed {capability} entitlements.")


def verify_platform_capabilities_sources(sources: Mapping[str, str]) -> None:
    if sorted(sources) != sorted(PLATFORM_CAPABILITY_POLICY_PATHS):
        fail("foreground-only platform capability source inventory is incomplete or expanded.")
    verify_jma_only_source_contract(sources)
    verify_foreground_push_presentation_contract(sources)
    verify_foreground_emergency_parity_contract(sources)
    for privacy_manifest_path in FOREGROUND_PRIVACY_MANIFEST_PATHS:
        verify_vision_privacy_manifest(
            sources[privacy_manifest_path],
            privacy_manifest_path,
        )
    fingerprint = reviewed_content_fingerprint([
        {"path": relative_path, "source": sources[relative_path]}
        for relative_path in PLATFORM_CAPABILITY_POLICY_PATHS
    ])
    if fingerprint != PLATFORM_CAPABILITIES_FINGERPRINT:
        fail(
            f"platform capability policy fingerprint {fingerprint} does not match "
            f"{PLATFORM_CAPABILITIES_FINGERPRINT}."
        )


def verify_jma_only_source_contract(sources: Mapping[str, str]) -> None:
    required_paths = {
        "ios/QuakeSignal/Features/List/QuakeListView.swift",
        "ios/QuakeSignal/Features/Settings/SourceDisclaimerView.swift",
        "ios/QuakeSignal/Networking/LiveSocketClient.swift",
        "ios/QuakeSignal/Networking/WolfxClient.swift",
        "ios/QuakeSignal/Notifications/PushPayload.swift",
        "ios/QuakeSignal/State/AppSettings.swift",
    }
    if not required_paths.issubset(sources):
        fail("JMA-only Apple source inventory is incomplete.")

    forbidden = (
        "all_eew",
        "cenc_eew",
        "cenc_eqlist",
        "cq_eew",
        "fj_eew",
        "sc_eew",
        "query_cenceew",
        "query_cenceqlist",
        "query_cqeew",
        "query_fjeew",
        "query_sceew",
    )
    combined = "\n".join(sources.values())
    found = [token for token in forbidden if token in combined]
    if found:
        fail(f"Apple release sources contain disabled non-JMA feed surface: {', '.join(found)}.")

    client = sources["ios/QuakeSignal/Networking/WolfxClient.swift"]
    socket = sources["ios/QuakeSignal/Networking/LiveSocketClient.swift"]
    settings = sources["ios/QuakeSignal/State/AppSettings.swift"]
    if client.count('static let sources = ["jma_eew", "jma_eqlist"]') != 1:
        fail("WolfxClient.sources must be exactly jma_eew and jma_eqlist.")
    for marker, count in (
        ('.source("jma_eew")', 2),
        ('.source("jma_eqlist")', 2),
        ('return ["query_jmaeew"]', 1),
        ('return ["query_jmaeqlist"]', 1),
    ):
        if socket.count(marker) != count:
            fail(f"direct JMA WebSocket contract is missing exact marker {marker!r}.")
    socket_readiness_markers = (
        ('WolfxNormalizer.validatedEvents(source: source, data: data)', 1),
        ('object["type"] as? String == source', 1),
        ('case .keepAlive:\n            return wasReady', 1),
        ('case .events:\n            return true', 1),
        ('case .invalid:\n            return false', 1),
        ('readyRoutes.removeAll()', 1),
        ('readyRoutes.remove(route)', 4),
        ('let nextState = readyRoutes.count == Self.routes.count', 1),
    )
    for marker, count in socket_readiness_markers:
        if socket.count(marker) != count:
            fail(
                "direct JMA WebSocket readiness must require both routes to deliver "
                f"fully validated, source-matching data; missing exact marker {marker!r}."
            )
    if "WolfxNormalizer.events(" in socket:
        fail("direct JMA WebSocket ingestion must not use the permissive normalizer.")
    for marker in (
        'let serial = positiveInteger(value["Serial"])',
        "serial: serial,",
    ):
        if client.count(marker) != 1:
            fail(
                "JMA EEW validation must require the raw Serial field and preserve "
                f"its exact value; missing marker {marker!r}."
            )
    if settings.count("static let allSources = WolfxClient.sources") != 1:
        fail("AppSettings must derive its selectable sources from WolfxClient.sources.")


def verify_foreground_push_presentation_contract(sources: Mapping[str, str]) -> None:
    payload = sources["ios/QuakeSignal/Notifications/PushPayload.swift"]
    policy = sources["ios/QuakeSignal/State/AlertPolicy.swift"]
    manager = sources["ios/QuakeSignal/Notifications/NotificationManager.swift"]

    payload_markers = (
        'Self.nonEmptyString(userInfo["sourceId"]).flatMap {',
        "WolfxClient.sources.contains($0) ? $0 : nil",
        "Self.isStructurallyUsable(",
        "event.sourceId == sourceID,",
        "event.eventId == eventID,",
        'event.id == "\\(sourceID):\\(eventID)",',
        "event.serial >= 0,",
        "event.originDate != nil,",
        "event.reportDate != nil,",
        "event.coordinate != nil,",
        "var hasUsableMatchingEventSnapshot: Bool",
    )
    for marker in payload_markers:
        if payload.count(marker) != 1:
            fail(
                "foreground push snapshots must be structurally usable and exactly "
                f"match their reviewed JMA source/event envelope; missing marker {marker!r}."
            )
    if policy.count(
        "guard payload.hasUsableMatchingEventSnapshot, isSceneActive else {"
    ) != 1:
        fail(
            "foreground APNs presentation may be suppressed only for an immediately "
            "usable matching snapshot in an active scene."
        )
    for marker in (
        "ForegroundNotificationPresentationPolicy.decision(\n                for: payload,",
        "return [.banner, .sound, .list]",
        "return [.list]",
    ):
        if manager.count(marker) != 1:
            fail(
                "foreground notification delivery must preserve the system banner and sound "
                f"unless the app owns a validated snapshot; missing marker {marker!r}."
            )


def verify_foreground_emergency_parity_contract(sources: Mapping[str, str]) -> None:
    required_paths = {
        "ios/QuakeSignal/App/AppDelegate.swift",
        "ios/QuakeSignal/State/AppSettings.swift",
        "ios/QuakeSignalShared/AlertSoundPreference.swift",
        "ios/QuakeSignalShared/WatchAlertPreferenceBridge.swift",
        "ios/QuakeSignalShared/WatchForegroundEmergencyPolicy.swift",
        "ios/QuakeSignalTV/TVDashboardView.swift",
        "ios/QuakeSignalTV/TVAlertPreferences.swift",
        "ios/QuakeSignalTV/TVEmergencyMonitor.swift",
        "ios/QuakeSignalTV/TVEmergencyPresentationPolicy.swift",
        "ios/QuakeSignalTV/TVUserInitiatedAlertAudio.swift",
        "ios/QuakeSignalWatch/QuakeSignalWatchApp.swift",
        "ios/QuakeSignalWatch/WatchDashboardView.swift",
        "ios/QuakeSignalWatch/WatchEmergencyAlertAudio.swift",
        "ios/QuakeSignalWatch/WatchForegroundEmergencyMonitor.swift",
    }
    if not required_paths.issubset(sources):
        fail("foreground Watch/TV emergency source inventory is incomplete.")

    app_delegate = sources["ios/QuakeSignal/App/AppDelegate.swift"]
    settings = sources["ios/QuakeSignal/State/AppSettings.swift"]
    bridge = sources["ios/QuakeSignalShared/WatchAlertPreferenceBridge.swift"]
    watch_policy = sources["ios/QuakeSignalShared/WatchForegroundEmergencyPolicy.swift"]
    watch_app = sources["ios/QuakeSignalWatch/QuakeSignalWatchApp.swift"]
    watch_dashboard = sources["ios/QuakeSignalWatch/WatchDashboardView.swift"]
    watch_audio = sources["ios/QuakeSignalWatch/WatchEmergencyAlertAudio.swift"]
    watch_monitor = sources["ios/QuakeSignalWatch/WatchForegroundEmergencyMonitor.swift"]
    tv_dashboard = sources["ios/QuakeSignalTV/TVDashboardView.swift"]
    tv_preferences = sources["ios/QuakeSignalTV/TVAlertPreferences.swift"]
    tv_monitor = sources["ios/QuakeSignalTV/TVEmergencyMonitor.swift"]
    tv_policy = sources["ios/QuakeSignalTV/TVEmergencyPresentationPolicy.swift"]
    tv_audio = sources["ios/QuakeSignalTV/TVUserInitiatedAlertAudio.swift"]

    for source, marker in (
        (app_delegate, "WatchAlertPreferenceBridge.activatePhone(current: AppSettings.shared.alertSound)"),
        (settings, "WatchAlertPreferenceBridge.synchronizeFromPhone(alertSound)"),
        (bridge, "CFGetTypeID(number) == CFNumberGetTypeID()"),
        (bridge, "!CFNumberIsFloatType(number)"),
        (bridge, "Set(applicationContext.keys) == [schemaVersionKey, alertSoundKey]"),
        (watch_app, "guard !ScreenshotAutomation.isEnabled else { return }"),
        (watch_app, "WatchAlertPreferenceBridge.activateWatch()"),
        (watch_dashboard, ".sensoryFeedback(.warning, trigger: emergencyFeedbackTrigger)"),
        (watch_dashboard, "WatchEmergencyAlertAudio.shared.playCustomSound(for: selectedAlertSound)"),
        (watch_monitor, "self?.ingest(events, isBackfill: isBackfill)"),
        (watch_monitor, "self.ingest(snapshot.events, isBackfill: true)"),
        (watch_monitor, "hadLocalHistoryBeforeBatch: locallyKnownEventIDs.contains(event.id)"),
        (watch_policy, "guard !(isBackfill && !hadLocalHistoryBeforeBatch) else"),
        (watch_policy, "if isTerminal(previous) && !isTerminal(incoming)"),
        (watch_audio, "private var playbackCompletionTask: Task<Void, Never>?"),
        (watch_audio, "private func finishCompletedPlayback()"),
        (tv_dashboard, "let shouldMonitor = scenePhase == .active && !ScreenshotAutomation.isEnabled"),
        (tv_dashboard, ".accessibilityHidden(emergencyMonitor.presentedWarning != nil)"),
        (tv_monitor, "self?.ingest(events, isBackfill: isBackfill)"),
        (tv_monitor, "self.ingest(snapshot.events, isBackfill: true)"),
        (tv_monitor, "hadLocalHistoryBeforeBatch: locallyKnownEventIDs.contains(event.id)"),
        (tv_policy, "guard !(isBackfill && !hadLocalHistoryBeforeBatch) else"),
        (tv_policy, "if previous.isTerminal && !incoming.isTerminal"),
        (tv_preferences, "static func permitsAutomaticWarningPlayback"),
        (tv_audio, "private var playbackCompletionTask: Task<Void, Never>?"),
        (tv_audio, "func playUserInitiated("),
    ):
        if source.count(marker) != 1:
            fail(
                "foreground Watch/TV emergency policy lost a reviewed lifecycle, "
                f"baseline, preference, feedback, or cleanup boundary: {marker!r}."
            )

    if not re.search(
        r"static func permitsAutomaticWarningPlayback\([^)]*\).*?\{\s*false\s*\}",
        tv_preferences,
        re.DOTALL,
    ):
        fail("Apple TV warning ingestion must never start alert audio automatically.")
    for forbidden in (
        "TVUserInitiatedAlertAudio",
        "AVAudioPlayer",
        "playUserInitiated",
        "AudioServicesPlay",
    ):
        if forbidden in tv_monitor:
            fail("Apple TV warning ingestion must remain visual-only and Remote-driven.")


def verify_vision_privacy_manifest(source: str, label: str) -> None:
    expected = {
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyCollectedDataTypes": [],
        "NSPrivacyAccessedAPITypes": [
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
            }
        ],
    }
    manifest = plistlib.loads(source.encode("utf-8"))
    effective = re.sub(r"<!--[\s\S]*?-->", "", source)
    key_sequence = re.findall(r"<key>\s*([^<]+?)\s*</key>", effective)
    expected_key_sequence = [
        "NSPrivacyTracking",
        "NSPrivacyTrackingDomains",
        "NSPrivacyCollectedDataTypes",
        "NSPrivacyAccessedAPITypes",
        "NSPrivacyAccessedAPIType",
        "NSPrivacyAccessedAPITypeReasons",
    ]
    if manifest != expected or key_sequence != expected_key_sequence:
        fail(
            f"{label} must declare tracking false, no tracking domains or collected data, "
            "and only UserDefaults accessed for reason CA92.1."
        )


def verify_release_source_settings(project: str, target_name: str) -> None:
    targets = "\n".join(yaml_mapping_block(project, "targets", 0))
    target = "\n".join(yaml_mapping_block(targets, target_name, 2))
    release = yaml_mapping_block(target, "Release", 8)
    for key, expected in (
        ("QUAKESIGNAL_API_BASE_URL", WORKER_ORIGIN),
        ("QUAKESIGNAL_APP_ATTEST_MODE", "production"),
    ):
        exact_line = f"{' ' * 10}{key}: {expected}"
        if release.count(exact_line) != 1:
            fail(f"{target_name} Release must set exactly {key}: {expected}.")


def verify_foreground_only_source_settings(project: str, target_name: str) -> None:
    targets = "\n".join(yaml_mapping_block(project, "targets", 0))
    target = "\n".join(yaml_mapping_block(targets, target_name, 2))
    for key in ("QUAKESIGNAL_API_BASE_URL", "QUAKESIGNAL_APP_ATTEST_MODE"):
        if re.search(rf"^\s+{re.escape(key)}:\s*", target, re.MULTILINE):
            fail(f"{target_name} is foreground-only and must not set {key}.")


def verify_info_plist_contract(
    plist: Mapping[str, Any], relative: str, requires_worker: bool
) -> None:
    if plist.get("CFBundleVersion") != "$(CURRENT_PROJECT_VERSION)":
        fail(f"{relative} must interpolate CURRENT_PROJECT_VERSION.")
    if requires_worker:
        if plist.get("QUAKESIGNAL_API_BASE_URL") != "$(QUAKESIGNAL_API_BASE_URL)":
            fail(f"{relative} must interpolate QUAKESIGNAL_API_BASE_URL.")
        if plist.get("QUAKESIGNAL_APP_ATTEST_MODE") != "$(QUAKESIGNAL_APP_ATTEST_MODE)":
            fail(f"{relative} must interpolate QUAKESIGNAL_APP_ATTEST_MODE.")
    elif "QUAKESIGNAL_API_BASE_URL" in plist or "QUAKESIGNAL_APP_ATTEST_MODE" in plist:
        fail(f"{relative} must not embed Worker or App Attest configuration.")
    if (
        relative == "ios/QuakeSignal/Supporting/Info.plist"
        and plist.get("LSApplicationCategoryType") != "public.app-category.weather"
    ):
        fail(f"{relative} must declare the reviewed native Mac Weather category.")
    if (
        relative == "ios/QuakeSignalVision/Supporting/Info.plist"
        and plist.get("NSLocationWhenInUseUsageDescription") != VISION_LOCATION_USAGE_DESCRIPTION
    ):
        fail(f"{relative} must disclose foreground-only location use exactly.")


def verify_bounded_source_contract(repository_root: Path) -> None:
    project = (repository_root / "ios/project.yml").read_text(encoding="utf-8")
    if len(re.findall(r'^\s*MARKETING_VERSION:\s*["\']1\.1["\']\s*$', project, re.MULTILINE)) != 1:
        fail("ios/project.yml must contain exactly one MARKETING_VERSION 1.1.")
    if len(re.findall(r'^\s*CURRENT_PROJECT_VERSION:\s*["\']8["\']\s*$', project, re.MULTILINE)) != 1:
        fail("ios/project.yml must contain exactly one CURRENT_PROJECT_VERSION 8.")
    for required in (
        "QuakeSignal:",
        "platform: iOS",
        "QuakeSignalTV:",
        "platform: tvOS",
        "QuakeSignalVision:",
        "platform: visionOS",
        "QuakeSignalWatch:",
        "platform: watchOS",
        "PRODUCT_BUNDLE_IDENTIFIER: com.quakesignal.app",
        "PRODUCT_BUNDLE_IDENTIFIER: com.quakesignal.app.watchkitapp",
        "DEVELOPMENT_TEAM: 5TT564H883",
        "SUPPORTS_MACCATALYST: YES",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO",
        '"ENABLE_APP_SANDBOX[sdk=macosx*]": YES',
        '"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": QuakeSignal/Supporting/QuakeSignal-Catalyst.entitlements',
        '"PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]": $(QUAKESIGNAL_CATALYST_PROFILE_NAME)',
    ):
        if required not in project:
            fail(f"ios/project.yml is missing reviewed value {required!r}.")
    verify_release_source_settings(project, "QuakeSignal")
    verify_foreground_only_source_settings(project, "QuakeSignalVision")
    verify_platform_capabilities_sources({
        relative_path: (repository_root / relative_path).read_text(encoding="utf-8")
        for relative_path in PLATFORM_CAPABILITY_POLICY_PATHS
    })
    generated = (repository_root / "ios/QuakeSignal.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    verify_project_executable_graph(project, generated)
    verify_xcode_source_graph_fingerprint(project, generated)
    verify_shared_scheme_sources({
        relative_path: (repository_root / relative_path).read_text(encoding="utf-8")
        for relative_path in XCODE_SCHEME_PATHS
    })
    if len(re.findall(r"CURRENT_PROJECT_VERSION = 8;", generated)) != 3:
        fail("generated Xcode project must contain exactly three build-8 settings.")
    generated_origins = re.findall(r"^\s*QUAKESIGNAL_API_BASE_URL = ([^;]+);\s*$", generated, re.MULTILINE)
    if generated_origins != [f'"{WORKER_ORIGIN}"'] * 2:
        fail("generated Xcode project must contain exactly two reviewed iOS Worker origin settings.")
    generated_modes = re.findall(r"^\s*QUAKESIGNAL_APP_ATTEST_MODE = ([^;]+);\s*$", generated, re.MULTILINE)
    if len(generated_modes) != 3 or generated_modes.count("production") != 2 or generated_modes.count("development") != 1:
        fail("generated Xcode project must contain exactly two production and one development iOS App Attest mode settings.")
    for relative in RELEASE_ENTITLEMENT_PATHS:
        with (repository_root / relative).open("rb") as handle:
            entitlements = plistlib.load(handle)
        verify_release_entitlements(entitlements, relative)
    info_contracts = {
        "ios/QuakeSignal/Supporting/Info.plist": True,
        "ios/QuakeSignalTV/Supporting/Info.plist": False,
        "ios/QuakeSignalVision/Supporting/Info.plist": False,
        "ios/QuakeSignalWatch/Supporting/Info.plist": False,
    }
    for relative, requires_worker in info_contracts.items():
        with (repository_root / relative).open("rb") as handle:
            plist = plistlib.load(handle)
        verify_info_plist_contract(plist, relative, requires_worker)
    fingerprint = calculate_app_attest_fingerprint(repository_root)
    if fingerprint != APP_ATTEST_FINGERPRINT:
        fail(f"source App Attest fingerprint {fingerprint} does not match {APP_ATTEST_FINGERPRINT}.")


def _request(
    url: str,
    *,
    method: str = "GET",
    headers: Optional[Mapping[str, str]] = None,
    body: Optional[bytes] = None,
    timeout: float = REQUEST_TIMEOUT_SECONDS,
) -> Tuple[int, Dict[str, str], bytes]:
    request = Request(url, data=body, method=method, headers=dict(headers or {}))
    opener = build_opener(RejectRedirects())
    try:
        with overall_request_deadline(timeout):
            try:
                response = opener.open(request, timeout=timeout)
            except HTTPError as error:
                response = error
            with response:
                data = response.read(MAX_RESPONSE_BYTES + 1)
                if len(data) > MAX_RESPONSE_BYTES:
                    fail(f"response from {url} exceeded {MAX_RESPONSE_BYTES} bytes.")
                return response.status, {key.lower(): value for key, value in response.headers.items()}, data
    except RequestDeadlineExceeded:
        fail(f"response from {url} exceeded its {timeout:.3f}s overall deadline.")


def _json_response(
    path: str,
    *,
    fetcher: Callable[..., Tuple[int, Dict[str, str], bytes]] = _request,
    timeout: float = REQUEST_TIMEOUT_SECONDS,
) -> Tuple[int, Dict[str, str], Any]:
    status, headers, data = fetcher(urljoin(WORKER_ORIGIN + "/", path.lstrip("/")), timeout=timeout)
    try:
        value = strict_json_loads(data)
    except (UnicodeDecodeError, TypeError, ValueError):
        value = None
    return status, headers, value


def _sources_ready(upstream: Any) -> bool:
    if not isinstance(upstream, dict):
        return False
    sources = upstream.get("sources")
    if not isinstance(sources, dict) or sorted(sources) != list(REQUIRED_WOLFX_SOURCES):
        return False
    return all(
        isinstance(sources[source], dict)
        and sources[source].get("stale") is False
        and sources[source].get("transport") in {"websocket", "http-polling"}
        for source in REQUIRED_WOLFX_SOURCES
    )


def _ready(body: Any, status: int) -> bool:
    return (
        status == 200
        and isinstance(body, dict)
        and body.get("ok") is True
        and isinstance(body.get("delivery"), dict)
        and body["delivery"].get("status") == "ready"
        and body["delivery"].get("apnsConfigured") is True
        and isinstance(body.get("upstream"), dict)
        and body["upstream"].get("status") == "ready"
        and body["upstream"].get("staleSources") == []
        and body["upstream"].get("transport") in {"websocket", "http-polling", "mixed"}
        and _sources_ready(body["upstream"])
    )


def wait_for_readiness(
    *,
    fetcher: Callable[..., Tuple[int, Dict[str, str], bytes]] = _request,
    now: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> Dict[str, Any]:
    deadline = now() + READINESS_TIMEOUT_SECONDS
    last: Any = None
    while now() < deadline:
        remaining = deadline - now()
        try:
            status, _, body = _json_response("/healthz", fetcher=fetcher, timeout=min(REQUEST_TIMEOUT_SECONDS, remaining))
            last = {"status": status, "body": body}
            if isinstance(body, dict) and isinstance(body.get("delivery"), dict) and body["delivery"].get("apnsConfigured") is False:
                fail("Worker reports APNs signing material is not configured.")
            if _ready(body, status):
                return body
        except ReleaseGuardError:
            raise
        except Exception as error:  # bounded retry for transient DNS/TLS/network failures
            last = {"error": type(error).__name__}
        remaining = deadline - now()
        if remaining > 0:
            sleep(min(READINESS_INTERVAL_SECONDS, remaining))
    fail(f"Worker readiness did not converge within {READINESS_TIMEOUT_SECONDS:.0f}s: {last!r}")


def _fetch(
    path: str,
    *,
    fetcher: Callable[..., Tuple[int, Dict[str, str], bytes]],
    method: str = "GET",
    headers: Optional[Mapping[str, str]] = None,
    body: Optional[bytes] = None,
) -> Tuple[int, Dict[str, str], bytes]:
    return fetcher(
        urljoin(WORKER_ORIGIN + "/", path.lstrip("/")),
        method=method,
        headers=headers,
        body=body,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )


def content_type_essence(headers: Mapping[str, str]) -> str:
    return headers.get("content-type", "").split(";", 1)[0].strip().lower()


def verify_live_worker_release(
    *, fetcher: Callable[..., Tuple[int, Dict[str, str], bytes]] = _request
) -> None:
    parsed = urlsplit(WORKER_ORIGIN)
    if parsed.scheme != "https" or parsed.path or parsed.query or parsed.fragment or parsed.username or parsed.password or parsed.port:
        fail("Worker origin must remain the exact bare reviewed HTTPS origin.")
    health = wait_for_readiness(fetcher=fetcher)
    status, headers, body_bytes = _fetch("/healthz", fetcher=fetcher)
    if status != 200 or headers.get("cache-control") != "no-store":
        fail("health endpoint must return uncached HTTP 200.")
    try:
        health = strict_json_loads(body_bytes)
    except (UnicodeDecodeError, TypeError, ValueError):
        fail("health endpoint must return JSON.")
    if (
        content_type_essence(headers) != "application/json"
        or not _ready(health, status)
        or health.get("mode") != "notification-only"
    ):
        fail("health endpoint is not fully ready notification-only production.")
    delivery = health.get("delivery")
    if (
        not isinstance(delivery, dict)
        or type(delivery.get("activeDlqIncidents")) is not int
        or delivery.get("activeDlqIncidents") != 0
    ):
        fail("health endpoint must report zero active DLQ incidents.")
    policy = health.get("appAttestPolicy")
    if not isinstance(policy, dict):
        fail("health endpoint is missing App Attest policy.")
    versions = policy.get("allowedBundleVersions")
    if (
        policy.get("format") != POLICY_FORMAT
        or policy.get("fingerprint") != APP_ATTEST_FINGERPRINT
        or versions != [str(value) for value in range(1, 9)]
    ):
        fail("live App Attest fingerprint/allow-list does not match release build 8.")

    status, root_headers, root_bytes = _fetch("/", fetcher=fetcher)
    try:
        root = strict_json_loads(root_bytes)
    except (UnicodeDecodeError, TypeError, ValueError):
        root = None
    if status != 200 or content_type_essence(root_headers) != "application/json" or not isinstance(root, dict) or root.get("purpose") != "APNs alert delivery only" or root.get("earthquakeData") != "Clients fetch directly from Wolfx" or "recent" in root or "live" in root:
        fail("Worker metadata contract is not the reviewed notification-only service.")
    for contract in LEGAL_PAGE_CONTRACTS:
        path = contract["path"]
        title = contract["title"]
        status, headers, data = _fetch(path, fetcher=fetcher)
        text = data.decode("utf-8", errors="replace")
        required_text = (
            f"<title>{title} · QuakeSignal</title>",
            f"QuakeSignal · Effective {contract['effectiveDate']}",
            *contract["requiredText"],
        )
        if (
            status != 200
            or content_type_essence(headers) != "text/html"
            or any(marker not in text for marker in required_text)
        ):
            fail(f"{path} is not the reviewed App Store legal/support page.")
    for path in ("/v1/quakes/recent?limit=5", "/v1/quakes/jma_eew%3Atest", "/v1/live"):
        if _fetch(path, fetcher=fetcher)[0] != 410:
            fail(f"disabled earthquake data endpoint {path} must return 410.")

    json_headers = {"content-type": "application/json"}
    token_body = json.dumps({"token": "a" * 64}).encode()
    for path, method, request_body, expected in (
        ("/v1/devices", "POST", token_body, 401),
        ("/v1/devices", "DELETE", token_body, 401),
        ("/v1/devices/test", "POST", token_body, 401),
        ("/v1/app-attest/challenge", "POST", b'{"version":"1"}', 400),
        ("/v1/devices", "POST", json.dumps({"token": "a" * (9 * 1024)}).encode(), 413),
    ):
        status, response_headers, _ = _fetch(path, fetcher=fetcher, method=method, headers=json_headers, body=request_body)
        if status != expected or response_headers.get("cache-control") != "no-store":
            fail(f"{method} {path} must fail closed with uncached HTTP {expected}.")
    bypass_headers = {**json_headers, "x-quakesignal-app-attest-bypass": "development-unsupported"}
    bypass_status, bypass_response_headers, _ = _fetch(
        "/v1/devices", fetcher=fetcher, method="POST", headers=bypass_headers, body=token_body
    )
    if bypass_status != 401 or bypass_response_headers.get("cache-control") != "no-store":
        fail("production Worker must reject the development App Attest bypass.")


def repository_root(environment: Mapping[str, str]) -> Path:
    configured = environment.get("CI_PRIMARY_REPOSITORY_PATH")
    if configured:
        return Path(configured).resolve()
    return Path(__file__).resolve().parents[2]


def run_phase(
    phase: str,
    *,
    environment: Mapping[str, str] = os.environ,
    root: Optional[Path] = None,
    source_state: Optional[Mapping[str, str]] = None,
    remote_verifier: Callable[[], None] = verify_live_worker_release,
) -> None:
    if phase not in {"post-clone", "pre-xcodebuild", "post-xcodebuild"}:
        fail(f"unsupported hook phase {phase!r}.")
    root = (
        (root or repository_root(environment))
        if phase == "post-clone" and environment.get("CI_XCODEBUILD_ACTION") == "archive"
        else None
    )
    target = verify_context(
        environment,
        phase=phase,
        repository_root=root,
        source_state=source_state,
    )
    if target is None:
        print(f"No protected release gate is required for {environment.get('CI_XCODEBUILD_ACTION', 'unknown')} actions.")
        return
    if phase == "post-clone":
        assert root is not None
        verify_bounded_source_contract(root)
    elif target["verifier"] == "ios":
        remote_verifier()
    print(
        f"Verified protected {target['platform']} release gate at {phase} for "
        f"{PRODUCT_NAME} product {target['product_id']} and commit {target['commit']}."
    )


def main(arguments: List[str]) -> int:
    try:
        if len(arguments) != 2 or arguments[0] != "--phase":
            fail("usage is xcode-cloud-release-guard.py --phase <post-clone|pre-xcodebuild|post-xcodebuild>.")
        observed_product_id = os.environ.get("CI_PRODUCT_ID", "")
        if observed_product_id and len(observed_product_id) <= 256 and not any(
            ord(char) < 32 or ord(char) == 127 for char in observed_product_id
        ):
            print(
                f"::notice::Observed Xcode Cloud CI_PRODUCT_ID={observed_product_id}; "
                "retain this non-secret opaque identifier with onboarding/release evidence."
            )
        observed_workflow_id = os.environ.get("CI_WORKFLOW_ID", "")
        if observed_workflow_id and len(observed_workflow_id) <= 256 and not any(
            ord(char) < 32 or ord(char) == 127 for char in observed_workflow_id
        ):
            print(
                f"::notice::Observed Xcode Cloud CI_WORKFLOW_ID={observed_workflow_id}; "
                "pin this non-secret opaque identifier in QUAKESIGNAL_RELEASE_WORKFLOW_ID."
            )
        run_phase(arguments[1])
        return 0
    except (OSError, UnicodeError, ValueError, plistlib.InvalidFileException, ReleaseGuardError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
