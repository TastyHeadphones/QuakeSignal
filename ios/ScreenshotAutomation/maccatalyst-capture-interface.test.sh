#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"
test_temp_root="${QUAKESIGNAL_TEST_TEMP_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
if [ ! -d "$test_temp_root" ] || [ -L "$test_temp_root" ]; then
  echo "error: screenshot test temp root must be an existing plain directory" >&2
  exit 64
fi
test_temp_root="$(cd "$test_temp_root" && pwd -P)"
test_root="$(mktemp -d "$test_temp_root/quakesignal-maccatalyst-interface-test.XXXXXX")"

cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT

expect_status() {
  local expected="$1"
  shift
  set +e
  "$@" >"$test_root/stdout" 2>"$test_root/stderr"
  local actual="$?"
  set -e
  if [ "$actual" -ne "$expected" ]; then
    echo "error: expected status $expected, received $actual: $*" >&2
    cat "$test_root/stdout" "$test_root/stderr" >&2
    exit 1
  fi
}

expect_status 64 "$script_dir/capture-maccatalyst-screenshot.sh"
expect_status 64 "$script_dir/capture-maccatalyst-screenshot-set.sh"
expect_status 64 "$script_dir/capture-maccatalyst-screenshot.sh" maccatalyst-home relative-output
expect_status 64 "$script_dir/capture-maccatalyst-screenshot-set.sh" relative-output
expect_status 64 "$script_dir/capture-maccatalyst-screenshot.sh" maccatalyst-unreviewed "$test_root/unreviewed"
expect_status 64 "$script_dir/capture-maccatalyst-screenshot.sh" maccatalyst-home "$repo_root/forbidden-capture"
expect_status 64 "$script_dir/capture-maccatalyst-screenshot-set.sh" "$repo_root/forbidden-set"

mkdir "$test_root/existing-frame" "$test_root/existing-set"
expect_status 73 "$script_dir/capture-maccatalyst-screenshot.sh" maccatalyst-home "$test_root/existing-frame"
expect_status 73 "$script_dir/capture-maccatalyst-screenshot-set.sh" "$test_root/existing-set"

stub_bin="$test_root/bin"
mkdir "$stub_bin"
printf '%s\n' \
  '#!/bin/bash' \
  'case " $* " in' \
  '  *" rev-parse "*) printf "%040d\n" 0 ;;' \
  '  *" status "*) printf " M ios/QuakeSignal/Features/Root/RootView.swift\n" ;;' \
  '  *) exit 1 ;;' \
  'esac' >"$stub_bin/git"
chmod +x "$stub_bin/git"
expect_status 65 env PATH="$stub_bin:$PATH" "$script_dir/capture-maccatalyst-screenshot.sh" maccatalyst-home "$test_root/dirty-frame"
expect_status 65 env PATH="$stub_bin:$PATH" "$script_dir/capture-maccatalyst-screenshot-set.sh" "$test_root/dirty-set"
if [ -e "$test_root/dirty-frame" ] || [ -e "$test_root/dirty-set" ]; then
  echo "error: dirty-source rejection published a capture directory" >&2
  exit 1
fi

if grep -q 'AXIsProcessTrusted\|AXUIElement' "$script_dir/maccatalyst-window-evidence.swift"; then
  echo "error: Mac Catalyst window evidence must not depend on Accessibility permission" >&2
  exit 1
fi
if grep -q '/usr/sbin/screencapture\|maccatalyst-capture-window\|SCScreenshotManager' "$script_dir/capture-maccatalyst-screenshot.sh"; then
  echo "error: direct hierarchy capture must not fall back to a host screen-capture backend" >&2
  exit 1
fi
if [ "$(grep -c 'matchedForbiddenSystemPromptGroups' "$script_dir/capture-maccatalyst-screenshot.sh")" -ne 2 ]; then
  echo "error: accepted and rejected Catalyst semantic schemas must bind forbidden system prompts" >&2
  exit 1
fi

/usr/bin/ruby -e '
  helper, capture, set, root_view, automation = ARGV.map { |path| File.read(path) }
  abort "window helper must require exactly five user arguments" unless
    helper.include?("CommandLine.arguments.count == 6") &&
    helper.include?("<pid> <bundle-id> <capture-selector> <geometry-evidence.json> <timeout-seconds>")
  abort "window helper arguments are not all consumed" unless
    (1..5).all? { |index| helper.include?("CommandLine.arguments[#{index}]") }
  abort "window helper no longer rejects an ambiguous visible PID window set" unless
    helper.include?("let windows = visibleWindows(processID: processID)") &&
    helper.include?("if windows.count == 1,")
  abort "capture does not bind window evidence to selector and app geometry" unless
    capture.match?(/"\$window_helper"\s+\\?\s*"\$app_pid" "\$bundle_identifier" "\$frame_selector" "\$attempt_geometry" 5/m) &&
    capture.match?(/"\$window_helper"\s+\\?\s*"\$app_pid" "\$bundle_identifier" "\$frame_selector" "\$attempt_geometry" 2/m)
  abort "single capture lost explicit tracked-child execution" unless
    capture.scan("xcrun swiftc -O").length == 3 &&
    capture.include?("quakesignal_maccatalyst_run_tracked xcodebuild build") &&
    capture.include?("quakesignal_maccatalyst_run_tracked xcodebuild -showBuildSettings") &&
    capture.scan(%q[quakesignal_maccatalyst_run_tracked "$window_helper"]).length == 2
  abort "shell lost exact PID/window/selector/nonce request-response handshake" unless
    capture.include?(%q[capture_request_path="$payload/capture-request-evidence/$frame_selector.json"]) &&
    capture.include?(%q["capture-request.json"]) &&
    capture.include?(%q["capture-response.json"]) &&
    capture.include?("SecureRandom.hex(32)") &&
    capture.include?(%q[request.fetch("nonce").match?(/\A[0-9a-f]{64}\z/)]) &&
    capture.include?(%q[capture["rawSha256"] == Digest::SHA256.file(raw_path).hexdigest])
  abort "app lost dual-gated exact live UIWindow hierarchy renderer" unless
    automation.include?(%q[--quakesignal-catalyst-hierarchy-capture]) &&
    automation.include?(%q[QUAKESIGNAL_CATALYST_HIERARCHY_CAPTURE]) &&
    root_view.include?("UIGraphicsImageRenderer(bounds: boundsBefore, format: format)") &&
    root_view.include?("format.scale = ScreenshotAutomation.macCaptureRasterizationScale") &&
    root_view.include?("window.drawHierarchy(") &&
    root_view.include?("afterScreenUpdates: true") &&
    root_view.include?(%q["captureApi": "UIKit.UIView.drawHierarchy"]) &&
    root_view.include?(%q["captureSurface": "live-catalyst-uiwindow-hierarchy"]) &&
    root_view.include?(%q["postCaptureResizePerformed": false]) &&
    root_view.include?("cgImage.width == 2_560") &&
    root_view.include?("cgImage.height == 1_600") &&
    root_view.include?("scene.activationState == .foregroundActive") &&
    root_view.include?("window.isKeyWindow") &&
    root_view.include?("!window.isHidden") &&
    root_view.scan("window.alpha >= 0.999").length == 2 &&
    root_view.scan("probe.window === window").length >= 3 &&
    root_view.include?("exactSystemFrame(systemFrameAfter)") &&
    root_view.include?("sourceDisplayScaleAfter") &&
    root_view.include?("approximatelyEqual(systemFrameBefore, systemFrameAfter)")
  abort "set capture lost tracked single-capture child" unless set.include?("quakesignal_maccatalyst_run_tracked env")
  abort "single capture lost ignored Debug.local.xcconfig pre/post refusal" unless
    capture.scan(%r{\[ -e "\$debug_local_override" \] \|\| \[ -L "\$debug_local_override" \]}).length == 2
  abort "set capture lost ignored Debug.local.xcconfig pre/post refusal" unless
    set.scan(%r{\[ -e "\$debug_local_override" \] \|\| \[ -L "\$debug_local_override" \]}).length == 2
  abort "set capture must retain exactly one five-frame count guard" unless set.scan(/!= "5"/).length == 1
  abort "set capture lost semantic evidence transfer" unless set.include?(%q[semantic-evidence/#{selector}.json])
  abort "semantic retry no longer retains first rejection telemetry" unless
    capture.include?(%q[semantic-rejections/$frame_selector-attempt-1.json]) &&
    capture.include?(%q[semantic-rejections/$frame_selector-attempt-1.png]) &&
    capture.include?("first_rejection_sha256") &&
    capture.include?("first_rejection_image_sha256") &&
    capture.include?(%q["validatorExitStatus" => 65])
' "$script_dir/maccatalyst-window-evidence.swift" \
  "$script_dir/capture-maccatalyst-screenshot.sh" \
  "$script_dir/capture-maccatalyst-screenshot-set.sh" \
  "$repo_root/ios/QuakeSignal/Features/Root/RootView.swift" \
  "$repo_root/ios/QuakeSignalShared/ScreenshotAutomation.swift"

echo "Mac Catalyst capture interface tests passed"
