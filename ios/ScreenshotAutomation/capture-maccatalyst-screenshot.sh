#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: capture-maccatalyst-screenshot.sh <frame-selector> <absolute-output-directory>

Builds the exact clean Git commit as Debug Mac Catalyst, launches one reviewed
fixture selector, waits for app-written stable 1280x800 geometry evidence, then
requests a PID/window/selector/nonce-bound direct @2x render of that exact live
UIWindow hierarchy. The raw 2560x1600 PNG is losslessly alpha-composited over
fixed black without resizing. The output is an atomic, explicitly unapproved
evidence directory outside the repository.

Optional environment:
  QUAKESIGNAL_CATALYST_SCREENSHOT_DERIVED_DATA=/absolute/cache/directory
      Reuse an unsigned Debug Catalyst build cache. It must be outside the repo.
USAGE
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 64
fi

frame_selector="$1"
requested_output="$2"
requested_derived_data="${QUAKESIGNAL_CATALYST_SCREENSHOT_DERIVED_DATA:-}"

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
ios_root="$(cd "$script_dir/.." && pwd -P)"
repo_root="$(cd "$ios_root/.." && pwd -P)"
# shellcheck source=maccatalyst-capture-retry-policy.sh
. "$script_dir/maccatalyst-capture-retry-policy.sh"
# shellcheck source=maccatalyst-process-guard.sh
. "$script_dir/maccatalyst-process-guard.sh"
manifest_file="ios/AppStore/platforms/maccatalyst/screenshot-manifest-v1.1-build10.json"
manifest_path="$repo_root/$manifest_file"
debug_local_override="$repo_root/ios/QuakeSignal/Supporting/Debug.local.xcconfig"

if [[ "$requested_output" != /* ]]; then
  echo "error: output directory must be absolute" >&2
  exit 64
fi
output_parent="$(dirname "$requested_output")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
output="$output_parent/$(basename "$requested_output")"
case "$output" in
  "$repo_root"|"$repo_root"/*)
    echo "error: capture output must be outside the repository: $repo_root" >&2
    exit 64
    ;;
esac
if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: refusing to overwrite existing capture directory: $output" >&2
  exit 73
fi

plan_entry="$(/usr/bin/ruby "$script_dir/maccatalyst-screenshot-plan.rb" --tsv | \
  awk -F '\t' -v selector="$frame_selector" '$1 == selector { print; matches += 1 } END { exit(matches == 1 ? 0 : 1) }')" || {
  echo "error: frame selector '$frame_selector' is not in the exact reviewed Mac Catalyst plan" >&2
  exit 64
}
IFS=$'\t' read -r planned_selector planned_file expected_width expected_height <<<"$plan_entry"
if [ "$planned_selector" != "$frame_selector" ] || \
   [ "$expected_width" != "2560" ] || \
   [ "$expected_height" != "1600" ]; then
  echo "error: selector disagrees with the direct @2x hierarchy-render contract" >&2
  exit 65
fi

for required_command in git xcodebuild xcrun ruby sips shasum sw_vers sysctl; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "error: required command not found: $required_command" >&2
    exit 69
  fi
done
if [ ! -x /usr/libexec/PlistBuddy ]; then
  echo "error: required command not found: /usr/libexec/PlistBuddy" >&2
  exit 69
fi
if [ ! -x /usr/bin/pgrep ]; then
  echo "error: required command not found: /usr/bin/pgrep" >&2
  exit 69
fi

source_commit="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')"
if [[ ! "$source_commit" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
  echo "error: source baseline is not a full Git commit object ID" >&2
  exit 65
fi
if [ -n "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]; then
  echo "error: Mac Catalyst screenshots require an exact clean source commit" >&2
  exit 65
fi
if [ -e "$debug_local_override" ] || [ -L "$debug_local_override" ]; then
  echo "error: ignored Debug.local.xcconfig is forbidden for exact screenshot builds" >&2
  exit 65
fi
manifest_sha256="$(shasum -a 256 "$manifest_path" | awk '{ print $1 }')"
plan_manifest_sha256="$(/usr/bin/ruby "$script_dir/maccatalyst-screenshot-plan.rb" --json | \
  /usr/bin/ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("manifestSha256")')"
if [ "$manifest_sha256" != "$plan_manifest_sha256" ]; then
  echo "error: manifest hash changed while loading the reviewed plan" >&2
  exit 65
fi

derived_data=""
if [ -n "$requested_derived_data" ]; then
  if [[ "$requested_derived_data" != /* ]]; then
    echo "error: derived-data cache must be absolute" >&2
    exit 64
  fi
  mkdir -p "$requested_derived_data"
  derived_data="$(cd "$requested_derived_data" && pwd -P)"
  case "$derived_data" in
    "$repo_root"|"$repo_root"/*)
      echo "error: derived-data cache must be outside the repository" >&2
      exit 64
      ;;
  esac
fi

temporary_root="$(mktemp -d "$output_parent/.quakesignal-maccatalyst-frame.XXXXXX")"
payload="$temporary_root/payload"
app_pid=""
maccatalyst_active_child_pid=""
mkdir -p \
  "$payload/app-logs" \
  "$payload/build-logs" \
  "$payload/capture-request-evidence" \
  "$payload/$(dirname "$planned_file")" \
  "$payload/frame-capture-evidence" \
  "$payload/geometry-evidence" \
  "$payload/native-capture-evidence" \
  "$payload/raw-window-captures" \
  "$payload/semantic-evidence" \
  "$payload/semantic-rejections" \
  "$payload/transformation-evidence" \
  "$payload/window-observations" \
  "$temporary_root/isolation-home"
if [ -z "$derived_data" ]; then
  derived_data="$temporary_root/DerivedData"
fi

stop_app() {
  quakesignal_maccatalyst_stop_processes "$app_pid"
  app_pid=""
}

cleanup() {
  quakesignal_maccatalyst_stop_processes "$maccatalyst_active_child_pid"
  maccatalyst_active_child_pid=""
  stop_app
  rm -rf "$temporary_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

window_helper="$temporary_root/maccatalyst-window-evidence"
flatten_helper="$temporary_root/maccatalyst-flatten-png"
validator_helper="$temporary_root/maccatalyst-validate-content"
quakesignal_maccatalyst_run_tracked \
  xcrun swiftc -O "$script_dir/maccatalyst-window-evidence.swift" -o "$window_helper"
quakesignal_maccatalyst_run_tracked \
  xcrun swiftc -O "$script_dir/maccatalyst-flatten-png.swift" -o "$flatten_helper"
quakesignal_maccatalyst_run_tracked \
  xcrun swiftc -O "$script_dir/maccatalyst-validate-content.swift" -o "$validator_helper"

build_log="$payload/build-logs/$frame_selector.log"
build_destination="platform=macOS,variant=Mac Catalyst"
if ! quakesignal_maccatalyst_run_tracked xcodebuild build \
  -project "$ios_root/QuakeSignal.xcodeproj" \
  -scheme QuakeSignal \
  -configuration Debug \
  -destination "$build_destination" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO >"$build_log" 2>&1; then
  tail -n 120 "$build_log" >&2
  echo "error: Debug Mac Catalyst build failed" >&2
  exit 70
fi

build_settings="$temporary_root/build-settings.txt"
quakesignal_maccatalyst_run_tracked xcodebuild -showBuildSettings \
  -project "$ios_root/QuakeSignal.xcodeproj" \
  -scheme QuakeSignal \
  -configuration Debug \
  -destination "$build_destination" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO >"$build_settings"
target_build_dir="$(awk -F ' = ' '$1 ~ /TARGET_BUILD_DIR$/ { print $2; exit }' "$build_settings")"
wrapper_name="$(awk -F ' = ' '$1 ~ /WRAPPER_NAME$/ { print $2; exit }' "$build_settings")"
app_path="$target_build_dir/$wrapper_name"
info_plist="$app_path/Contents/Info.plist"
if [ -z "$target_build_dir" ] || [ "$wrapper_name" != "QuakeSignal.app" ] || [ ! -d "$app_path" ] || [ ! -f "$info_plist" ]; then
  echo "error: could not locate the exact built Mac Catalyst app" >&2
  exit 70
fi

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
if [ "$bundle_identifier" != "com.quakesignal.app" ] || \
   [ "$marketing_version" != "1.1" ] || \
   [ "$build_number" != "10" ] || \
   [ "$executable_name" != "QuakeSignal" ]; then
  echo "error: built app identity/version differs from the build-10 Catalyst contract" >&2
  exit 65
fi
main_executable="$app_path/Contents/MacOS/$executable_name"
if [ ! -f "$main_executable" ] || [ -L "$main_executable" ]; then
  echo "error: built app main executable is missing or indirect" >&2
  exit 70
fi

app_tree_sha256() {
  /usr/bin/ruby -rdigest -rfind -e '
    root = File.realpath(ARGV.fetch(0))
    entries = []
    Find.find(root) { |path| entries << path unless path == root }
    digest = Digest::SHA256.new
    entries.sort.each do |path|
      relative = path.delete_prefix(root + "/")
      stat = File.lstat(path)
      case stat.ftype
      when "directory"
        digest.update("directory\0#{relative}\0#{stat.mode & 0o7777}\0")
      when "file"
        digest.update("file\0#{relative}\0#{stat.mode & 0o7777}\0#{Digest::SHA256.file(path).hexdigest}\0")
      when "link"
        digest.update("link\0#{relative}\0#{stat.mode & 0o7777}\0#{File.readlink(path)}\0")
      else
        abort "unsupported app bundle entry: #{relative} (#{stat.ftype})"
      end
    end
    puts digest.hexdigest
  ' "$app_path"
}

app_bundle_tree_sha256="$(app_tree_sha256)"
main_executable_sha256="$(shasum -a 256 "$main_executable" | awk '{ print $1 }')"
case "$frame_selector" in
  maccatalyst-map) settle_seconds=25 ;;
  *) settle_seconds=10 ;;
esac

capture_attempt_count=0
semantic_retry_performed=false
capture_accepted=false
first_semantic_rejection=""
first_semantic_rejection_image=""
while [ "$capture_attempt_count" -lt 2 ]; do
  capture_attempt_count=$((capture_attempt_count + 1))
  attempt_root="$temporary_root/attempt-$capture_attempt_count"
  geometry_root="$attempt_root/app-geometry-evidence"
  mkdir -p "$attempt_root" "$geometry_root"
  attempt_app_log="$attempt_root/app.log"
  attempt_geometry="$attempt_root/geometry.json"
  attempt_window_before="$attempt_root/window-before.json"
  attempt_window_after="$attempt_root/window-after.json"
  attempt_capture_request="$attempt_root/capture-request.json"
  attempt_raw="$attempt_root/raw.png"
  attempt_native_capture="$attempt_root/native-capture.json"
  attempt_final="$attempt_root/final.png"
  attempt_transformation="$attempt_root/transformation.json"
  attempt_semantic="$attempt_root/semantic.json"
  attempt_semantic_stderr="$attempt_root/semantic.stderr"

  quakesignal_maccatalyst_defer_spawn_signals
  env \
    CFFIXED_USER_HOME="$temporary_root/isolation-home" \
    QUAKESIGNAL_SCREENSHOT_AUTOMATION=1 \
    QUAKESIGNAL_SCREENSHOT_FRAME="$frame_selector" \
    QUAKESIGNAL_CATALYST_SCREENSHOT_EVIDENCE_ROOT="$geometry_root" \
    QUAKESIGNAL_CATALYST_HIERARCHY_CAPTURE=1 \
    TZ=UTC \
      "$main_executable" \
      --quakesignal-screenshot-automation \
      --quakesignal-catalyst-hierarchy-capture \
      "--quakesignal-screenshot-frame=$frame_selector" \
      -AppleLanguages '(en)' \
      -AppleLocale en_US >"$attempt_app_log" 2>&1 &
  app_pid="$!"
  quakesignal_maccatalyst_restore_spawn_signals

  geometry_source="$geometry_root/geometry-$app_pid.json"
  for _ in $(seq 1 120); do
    if [ -f "$geometry_source" ] && [ ! -L "$geometry_source" ]; then
      break
    fi
    if ! kill -0 "$app_pid" >/dev/null 2>&1; then
      tail -n 120 "$attempt_app_log" >&2 || true
      echo "error: Catalyst app exited before publishing geometry evidence" >&2
      exit 70
    fi
    sleep 0.1
  done
  if [ ! -f "$geometry_source" ] || [ -L "$geometry_source" ]; then
    tail -n 120 "$attempt_app_log" >&2 || true
    echo "error: timed out waiting for atomic Catalyst geometry evidence" >&2
    exit 70
  fi

  if ! /usr/bin/ruby -rjson -rtime -e '
    record = JSON.parse(File.read(ARGV.fetch(0)))
    expected_keys = %w[captureSelector logicalFrame processId reason recordedAtUtc schemaVersion sourceDisplayScale status]
    abort "geometry evidence keys differ" unless record.keys.sort == expected_keys.sort
    unless record["schemaVersion"] == 1 && record["status"] == "ready" && record["reason"].nil?
      diagnostic = {
        "status" => record["status"],
        "reason" => record["reason"],
        "logicalFrame" => record["logicalFrame"],
        "sourceDisplayScale" => record["sourceDisplayScale"],
      }
      warn "Catalyst geometry evidence rejected: #{JSON.generate(diagnostic)}"
      abort "geometry evidence is not ready"
    end
    abort "geometry evidence PID differs" unless record["processId"] == Integer(ARGV.fetch(1), 10)
    abort "geometry evidence selector differs" unless record["captureSelector"] == ARGV.fetch(2)
    frame = record.fetch("logicalFrame")
    abort "geometry frame keys differ" unless frame.keys.sort == %w[height width x y]
    abort "geometry size differs" unless frame["width"] == 1280 && frame["height"] == 800
    source_scale = record.fetch("sourceDisplayScale")
    abort "source-display scale differs" unless source_scale.is_a?(Numeric) && source_scale.finite? && source_scale.between?(0.5, 4)
    timestamp = record.fetch("recordedAtUtc")
    abort "geometry timestamp is not UTC" unless timestamp.end_with?("Z") && Time.iso8601(timestamp).utc_offset.zero?
  ' "$geometry_source" "$app_pid" "$frame_selector"; then
    tail -n 120 "$attempt_app_log" >&2 || true
    echo "error: app-written Catalyst geometry evidence is invalid" >&2
    exit 70
  fi
  mv "$geometry_source" "$attempt_geometry"

  echo "Settling $frame_selector for ${settle_seconds}s after stable geometry (attempt $capture_attempt_count/2)"
  quakesignal_maccatalyst_run_tracked sleep "$settle_seconds"
  quakesignal_maccatalyst_run_tracked "$window_helper" \
    "$app_pid" "$bundle_identifier" "$frame_selector" "$attempt_geometry" 5 \
    >"$attempt_window_before"
  window_id="$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("windowId")' "$attempt_window_before")"
  if [[ ! "$window_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: Core Graphics returned an invalid window ID" >&2
    exit 70
  fi

  capture_request_source="$geometry_root/capture-request.json"
  capture_response_source="$geometry_root/capture-response.json"
  capture_raw_source="$geometry_root/capture-raw.png"
  if [ -e "$capture_request_source" ] || [ -L "$capture_request_source" ] || \
     [ -e "$capture_response_source" ] || [ -L "$capture_response_source" ] || \
     [ -e "$capture_raw_source" ] || [ -L "$capture_raw_source" ]; then
    echo "error: Catalyst hierarchy handshake path already exists" >&2
    exit 70
  fi
  capture_nonce="$(/usr/bin/ruby -rsecurerandom -e 'print SecureRandom.hex(32)')"
  if [[ ! "$capture_nonce" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: could not generate an exact hierarchy-capture nonce" >&2
    exit 70
  fi
  request_temporary="$geometry_root/.capture-request.$capture_nonce.tmp"
  export REQUEST_PROCESS_ID="$app_pid"
  export REQUEST_WINDOW_ID="$window_id"
  export REQUEST_SELECTOR="$frame_selector"
  export REQUEST_NONCE="$capture_nonce"
  /usr/bin/ruby -rjson -e '
    request = {
      "schemaVersion" => 1,
      "processId" => Integer(ENV.fetch("REQUEST_PROCESS_ID"), 10),
      "windowId" => Integer(ENV.fetch("REQUEST_WINDOW_ID"), 10),
      "captureSelector" => ENV.fetch("REQUEST_SELECTOR"),
      "nonce" => ENV.fetch("REQUEST_NONCE"),
      "logicalViewPoints" => [1280, 800],
      "rasterizationScale" => 2,
    }
    File.write(ARGV.fetch(0), JSON.pretty_generate(request) + "\n", mode: "wx")
  ' "$request_temporary"
  mv "$request_temporary" "$capture_request_source"

  for _ in $(seq 1 600); do
    if [ -f "$capture_response_source" ] && [ ! -L "$capture_response_source" ]; then
      break
    fi
    if ! kill -0 "$app_pid" >/dev/null 2>&1; then
      tail -n 120 "$attempt_app_log" >&2 || true
      echo "error: Catalyst app exited before publishing hierarchy-capture response" >&2
      exit 70
    fi
    sleep 0.1
  done
  if [ ! -f "$capture_response_source" ] || [ -L "$capture_response_source" ]; then
    tail -n 120 "$attempt_app_log" >&2 || true
    echo "error: timed out waiting for atomic Catalyst hierarchy-capture response" >&2
    exit 70
  fi
  capture_response_status="$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("status")' "$capture_response_source")" || {
    echo "error: Catalyst hierarchy-capture response is invalid JSON" >&2
    exit 70
  }
  if [ "$capture_response_status" != "captured" ]; then
    /usr/bin/ruby -rjson -e 'warn JSON.parse(File.read(ARGV.fetch(0))).fetch("reason", "unknown hierarchy-render failure")' "$capture_response_source" >&2 || true
    tail -n 120 "$attempt_app_log" >&2 || true
    echo "error: in-app Catalyst hierarchy render failed closed" >&2
    exit 70
  fi
  if [ ! -f "$capture_raw_source" ] || [ -L "$capture_raw_source" ]; then
    echo "error: captured response exists without a direct raw hierarchy PNG" >&2
    exit 70
  fi
  mv "$capture_request_source" "$attempt_capture_request"
  mv "$capture_response_source" "$attempt_native_capture"
  mv "$capture_raw_source" "$attempt_raw"

  quakesignal_maccatalyst_run_tracked sleep 0.3
  quakesignal_maccatalyst_run_tracked "$window_helper" \
    "$app_pid" "$bundle_identifier" "$frame_selector" "$attempt_geometry" 2 \
    >"$attempt_window_after"
  if ! /usr/bin/ruby -rjson -e '
    before = JSON.parse(File.read(ARGV.fetch(0)))
    after = JSON.parse(File.read(ARGV.fetch(1)))
    exit(before == after ? 0 : 1)
  ' "$attempt_window_before" "$attempt_window_after"; then
    echo "error: Catalyst PID/window/frame changed across hierarchy render" >&2
    exit 70
  fi
  if ! /usr/bin/ruby -rdigest -rjson -rtime -e '
    request = JSON.parse(File.read(ARGV.fetch(0)))
    capture = JSON.parse(File.read(ARGV.fetch(1)))
    window = JSON.parse(File.read(ARGV.fetch(2)))
    geometry = JSON.parse(File.read(ARGV.fetch(3)))
    raw_path = ARGV.fetch(4)
    request_keys = %w[captureSelector logicalViewPoints nonce processId rasterizationScale schemaVersion windowId]
    abort "capture-request evidence keys differ" unless request.keys.sort == request_keys.sort
    abort "capture-request schema differs" unless request["schemaVersion"] == 1
    abort "capture-request logical geometry differs" unless request["logicalViewPoints"] == [1280, 800] && request["rasterizationScale"] == 2
    abort "capture-request nonce differs" unless request.fetch("nonce").match?(/\A[0-9a-f]{64}\z/)
    expected_keys = %w[afterScreenUpdates captureApi captureSelector captureSurface capturedAtUtc drawHierarchyComplete logicalViewPoints nonce pixels postCaptureResizePerformed processId rasterizationScale rawOutputFile rawSha256 reason rendererOpaque rendererPreferredRange sceneActivationState schemaVersion sourceDisplayScale status systemFrameAfter systemFrameBefore windowAlpha windowBounds windowId windowIsHidden windowIsKey]
    abort "native-capture evidence keys differ" unless capture.keys.sort == expected_keys.sort
    abort "native-capture method differs" unless capture["schemaVersion"] == 1 && capture["status"] == "captured" && capture["reason"].nil? && capture["captureApi"] == "UIKit.UIView.drawHierarchy" && capture["captureSurface"] == "live-catalyst-uiwindow-hierarchy"
    %w[processId windowId captureSelector nonce logicalViewPoints rasterizationScale].each do |key|
      abort "capture request/response #{key} differs" unless capture[key] == request[key]
    end
    abort "native-capture PID/window differs" unless capture["processId"] == window["processId"] && capture["windowId"] == window["windowId"]
    abort "native-capture selector differs" unless capture["captureSelector"] == window["captureSelector"]
    abort "native-capture pixels differ" unless capture["pixels"] == [2560, 1600]
    abort "native-capture configuration differs" unless capture["afterScreenUpdates"] == true && capture["drawHierarchyComplete"] == true && capture["postCaptureResizePerformed"] == false && capture["rendererOpaque"] == false && capture["rendererPreferredRange"] == "standard"
    abort "native-capture visibility differs" unless capture["windowIsKey"] == true && capture["windowIsHidden"] == false && capture["sceneActivationState"] == "foregroundActive" && capture["windowAlpha"].is_a?(Numeric) && capture["windowAlpha"].finite? && capture["windowAlpha"] >= 0.999
    expected_bounds = { "x" => 0, "y" => 0, "width" => 1280, "height" => 800 }
    abort "native-capture UIWindow bounds differ" unless capture["windowBounds"] == expected_bounds
    abort "native-capture UIWindowScene geometry drifted" unless capture["systemFrameBefore"] == capture["systemFrameAfter"] && capture["systemFrameBefore"] == geometry["logicalFrame"]
    source_scale = capture["sourceDisplayScale"]
    abort "native-capture source-display scale differs" unless source_scale.is_a?(Numeric) && source_scale.finite? && source_scale.between?(0.5, 4) && source_scale == geometry["sourceDisplayScale"]
    abort "native-capture raw filename differs" unless capture["rawOutputFile"] == "capture-raw.png"
    abort "native-capture raw SHA-256 is invalid" unless capture["rawSha256"].match?(/\A[0-9a-f]{64}\z/)
    abort "native-capture raw bytes differ" unless capture["rawSha256"] == Digest::SHA256.file(raw_path).hexdigest
    timestamp = capture.fetch("capturedAtUtc")
    abort "capture timestamp is not UTC" unless timestamp.end_with?("Z") && Time.iso8601(timestamp).utc_offset.zero?
  ' "$attempt_capture_request" "$attempt_native_capture" "$attempt_window_before" "$attempt_geometry" "$attempt_raw"; then
    echo "error: direct UIKit hierarchy-capture evidence is invalid" >&2
    exit 70
  fi

  raw_width="$(sips -g pixelWidth "$attempt_raw" | awk '/pixelWidth:/ { print $2 }')"
  raw_height="$(sips -g pixelHeight "$attempt_raw" | awk '/pixelHeight:/ { print $2 }')"
  raw_alpha_value="$(sips -g hasAlpha "$attempt_raw" | awk '/hasAlpha:/ { print $2 }')"
  if [ "$raw_width" != "$expected_width" ] || [ "$raw_height" != "$expected_height" ]; then
    echo "error: direct hierarchy render is ${raw_width}x${raw_height}; expected 2560x1600" >&2
    echo "No resize was performed." >&2
    exit 65
  fi
  case "$raw_alpha_value" in
    yes) raw_has_alpha=true ;;
    no) raw_has_alpha=false ;;
    *) echo "error: could not determine raw PNG alpha state" >&2; exit 70 ;;
  esac

  if ! quakesignal_maccatalyst_run_tracked \
    "$flatten_helper" "$attempt_raw" "$attempt_final" \
    "$expected_width" "$expected_height" >"$attempt_transformation"; then
    echo "error: lossless fixed-black alpha composite failed" >&2
    exit 70
  fi
  final_width="$(sips -g pixelWidth "$attempt_final" | awk '/pixelWidth:/ { print $2 }')"
  final_height="$(sips -g pixelHeight "$attempt_final" | awk '/pixelHeight:/ { print $2 }')"
  final_alpha_value="$(sips -g hasAlpha "$attempt_final" | awk '/hasAlpha:/ { print $2 }')"
  if [ "$final_width" != "$expected_width" ] || [ "$final_height" != "$expected_height" ] || [ "$final_alpha_value" != "no" ]; then
    echo "error: final PNG must remain opaque direct-render 2560x1600" >&2
    exit 65
  fi
  if ! /usr/bin/ruby -rjson -e '
    record = JSON.parse(File.read(ARGV.fetch(0)))
    expected = {
      "operation" => "alpha-composite",
      "backgroundRGBA" => [0, 0, 0, 255],
      "resizePerformed" => false,
      "rawHasAlpha" => ARGV.fetch(1) == "true",
      "finalHasAlpha" => false,
      "pixels" => [2560, 1600],
      "encoder" => "CoreGraphics-ImageIO-PNG",
    }
    abort "transformation evidence differs" unless record == expected
  ' "$attempt_transformation" "$raw_has_alpha"; then
    echo "error: transformation evidence is invalid" >&2
    exit 70
  fi

  set +e
  quakesignal_maccatalyst_run_tracked \
    "$validator_helper" "$frame_selector" "$attempt_final" "$attempt_semantic" \
    2>"$attempt_semantic_stderr"
  semantic_status="$?"
  set -e
  retry_decision="$(
    quakesignal_maccatalyst_capture_retry_decision \
      "$capture_attempt_count" "$semantic_status"
  )" || {
    echo "error: invalid Mac Catalyst retry-policy input" >&2
    exit 70
  }
  if [ "$retry_decision" = "accept" ]; then
    capture_accepted=true
    app_pid_for_evidence="$app_pid"
    stop_app
    app_pid=""
    app_log="$payload/app-logs/$frame_selector.log"
    geometry_path="$payload/geometry-evidence/$frame_selector.json"
    window_before="$payload/window-observations/$frame_selector-before.json"
    window_after="$payload/window-observations/$frame_selector-after.json"
    capture_request_path="$payload/capture-request-evidence/$frame_selector.json"
    raw_path="$payload/raw-window-captures/$frame_selector.png"
    native_capture_path="$payload/native-capture-evidence/$frame_selector.json"
    final_path="$payload/$planned_file"
    transformation_path="$payload/transformation-evidence/$frame_selector.json"
    semantic_path="$payload/semantic-evidence/$frame_selector.json"
    mv "$attempt_app_log" "$app_log"
    mv "$attempt_geometry" "$geometry_path"
    mv "$attempt_window_before" "$window_before"
    mv "$attempt_window_after" "$window_after"
    mv "$attempt_capture_request" "$capture_request_path"
    mv "$attempt_raw" "$raw_path"
    mv "$attempt_native_capture" "$native_capture_path"
    mv "$attempt_final" "$final_path"
    mv "$attempt_transformation" "$transformation_path"
    mv "$attempt_semantic" "$semantic_path"
    break
  fi

  cat "$attempt_semantic_stderr" >&2
  stop_app
  app_pid=""
  if [ "$retry_decision" = "operational-failure" ]; then
    echo "error: Mac Catalyst semantic validator failed operationally with status $semantic_status" >&2
    exit 70
  fi
  if [ "$retry_decision" = "semantic-failure" ]; then
    echo "error: exact Mac Catalyst route failed semantic validation twice" >&2
    exit 65
  fi
  if [ "$retry_decision" != "retry" ]; then
    echo "error: unknown Mac Catalyst retry-policy decision: $retry_decision" >&2
    exit 70
  fi
  first_semantic_rejection="$payload/semantic-rejections/$frame_selector-attempt-1.json"
  first_semantic_rejection_image="$payload/semantic-rejections/$frame_selector-attempt-1.png"
  if [ -e "$first_semantic_rejection" ] || [ -L "$first_semantic_rejection" ] || \
     [ -e "$first_semantic_rejection_image" ] || [ -L "$first_semantic_rejection_image" ]; then
    echo "error: first semantic-rejection evidence path already exists" >&2
    exit 70
  fi
  mv "$attempt_semantic" "$first_semantic_rejection"
  mv "$attempt_final" "$first_semantic_rejection_image"
  semantic_retry_performed=true
  echo "Retrying the exact selector once after semantic rejection" >&2
done

if [ "$capture_accepted" != "true" ]; then
  echo "error: no semantically accepted Mac Catalyst capture was produced" >&2
  exit 65
fi

if [ "$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')" != "$source_commit" ] || \
   [ -n "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]; then
  echo "error: source commit/tree changed during Catalyst capture" >&2
  exit 65
fi
if [ -e "$debug_local_override" ] || [ -L "$debug_local_override" ]; then
  echo "error: ignored Debug.local.xcconfig appeared during Catalyst capture" >&2
  exit 65
fi
if [ "$(shasum -a 256 "$manifest_path" | awk '{ print $1 }')" != "$manifest_sha256" ]; then
  echo "error: screenshot plan manifest changed during capture" >&2
  exit 65
fi
if [ "$(app_tree_sha256)" != "$app_bundle_tree_sha256" ] || \
   [ "$(shasum -a 256 "$main_executable" | awk '{ print $1 }')" != "$main_executable_sha256" ]; then
  echo "error: built app bytes changed during capture" >&2
  exit 65
fi

raw_sha256="$(shasum -a 256 "$raw_path" | awk '{ print $1 }')"
final_sha256="$(shasum -a 256 "$final_path" | awk '{ print $1 }')"
app_log_sha256="$(shasum -a 256 "$app_log" | awk '{ print $1 }')"
build_log_sha256="$(shasum -a 256 "$build_log" | awk '{ print $1 }')"
geometry_sha256="$(shasum -a 256 "$geometry_path" | awk '{ print $1 }')"
capture_request_sha256="$(shasum -a 256 "$capture_request_path" | awk '{ print $1 }')"
window_before_sha256="$(shasum -a 256 "$window_before" | awk '{ print $1 }')"
window_after_sha256="$(shasum -a 256 "$window_after" | awk '{ print $1 }')"
transformation_sha256="$(shasum -a 256 "$transformation_path" | awk '{ print $1 }')"
native_capture_sha256="$(shasum -a 256 "$native_capture_path" | awk '{ print $1 }')"
semantic_sha256="$(shasum -a 256 "$semantic_path" | awk '{ print $1 }')"
first_rejection_sha256=""
first_rejection_image_sha256=""
first_rejection_argument="-"
if [ "$semantic_retry_performed" = "true" ]; then
  first_rejection_sha256="$(shasum -a 256 "$first_semantic_rejection" | awk '{ print $1 }')"
  first_rejection_image_sha256="$(shasum -a 256 "$first_semantic_rejection_image" | awk '{ print $1 }')"
  first_rejection_argument="$first_semantic_rejection"
fi
captured_at_utc="$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("capturedAtUtc")' "$native_capture_path")"
macos_version="$(sw_vers -productVersion)"
macos_build="$(sw_vers -buildVersion)"
xcode_version="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
xcode_build="$(xcodebuild -version | sed -n '2s/^Build version //p')"
hardware_model="$(sysctl -n hw.model)"

export CAPTURE_SELECTOR="$frame_selector"
export CAPTURE_PLANNED_FILE="$planned_file"
export CAPTURED_AT_UTC="$captured_at_utc"
export SOURCE_COMMIT="$source_commit"
export MANIFEST_FILE="$manifest_file"
export MANIFEST_SHA256="$manifest_sha256"
export APP_TREE_SHA256="$app_bundle_tree_sha256"
export MAIN_EXECUTABLE_SHA256="$main_executable_sha256"
export MACOS_VERSION="$macos_version"
export MACOS_BUILD="$macos_build"
export XCODE_VERSION="$xcode_version"
export XCODE_BUILD="$xcode_build"
export HARDWARE_MODEL="$hardware_model"
export PROCESS_ID="$app_pid_for_evidence"
export RAW_HAS_ALPHA="$raw_has_alpha"
export RAW_SHA256="$raw_sha256"
export FINAL_SHA256="$final_sha256"
export APP_LOG_SHA256="$app_log_sha256"
export BUILD_LOG_SHA256="$build_log_sha256"
export GEOMETRY_SHA256="$geometry_sha256"
export CAPTURE_REQUEST_SHA256="$capture_request_sha256"
export WINDOW_BEFORE_SHA256="$window_before_sha256"
export WINDOW_AFTER_SHA256="$window_after_sha256"
export TRANSFORMATION_SHA256="$transformation_sha256"
export NATIVE_CAPTURE_SHA256="$native_capture_sha256"
export SEMANTIC_SHA256="$semantic_sha256"
export SETTLE_SECONDS="$settle_seconds"
export CAPTURE_ATTEMPT_COUNT="$capture_attempt_count"
export SEMANTIC_RETRY_PERFORMED="$semantic_retry_performed"
export FIRST_REJECTION_SHA256="$first_rejection_sha256"
export FIRST_REJECTION_IMAGE_SHA256="$first_rejection_image_sha256"

frame_evidence="$payload/frame-capture-evidence/$frame_selector.json"
/usr/bin/ruby -rjson -rtime -e '
  selector = ENV.fetch("CAPTURE_SELECTOR")
  window = JSON.parse(File.read(ARGV.fetch(0)))
  geometry = JSON.parse(File.read(ARGV.fetch(1)))
  transform = JSON.parse(File.read(ARGV.fetch(2)))
  semantic = JSON.parse(File.read(ARGV.fetch(3)))
  native_capture = JSON.parse(File.read(ARGV.fetch(4)))
  capture_request = JSON.parse(File.read(ARGV.fetch(5)))
  process_id = Integer(ENV.fetch("PROCESS_ID"), 10)
  settle_seconds = Integer(ENV.fetch("SETTLE_SECONDS"), 10)
  capture_attempt_count = Integer(ENV.fetch("CAPTURE_ATTEMPT_COUNT"), 10)
  semantic_retry_performed = ENV.fetch("SEMANTIC_RETRY_PERFORMED") == "true"
  abort "window PID changed" unless window.fetch("processId") == process_id
  abort "geometry PID changed" unless geometry.fetch("processId") == process_id
  abort "window selector changed" unless window.fetch("captureSelector") == selector
  abort "semantic evidence keys differ" unless semantic.keys.sort == %w[captureSelector checks imageFormat imageSha256 pixels reasons schemaVersion status].sort
  abort "semantic evidence was not accepted" unless semantic.fetch("schemaVersion") == 1 && semantic.fetch("status") == "accepted" && semantic.fetch("reasons") == []
  abort "semantic evidence selector changed" unless semantic.fetch("captureSelector") == selector
  abort "semantic evidence pixels changed" unless semantic.fetch("pixels") == [2560, 1600]
  abort "semantic evidence is not bound to the final PNG bytes" unless
    semantic.fetch("imageFormat") == "png" && semantic.fetch("imageSha256") == ENV.fetch("FINAL_SHA256")
  abort "semantic evidence checks differ" unless semantic.fetch("checks").keys.sort == %w[committedView matchedForbiddenSystemPromptGroups matchedRequiredTermGroups recognizedText].sort
  expected_settle = selector == "maccatalyst-map" ? 25 : 10
  abort "semantic settle differs" unless settle_seconds == expected_settle
  abort "capture attempt count differs" unless [1, 2].include?(capture_attempt_count)
  abort "semantic retry binding differs" unless semantic_retry_performed == (capture_attempt_count == 2)
  first_rejection = nil
  if semantic_retry_performed
    rejection = JSON.parse(File.read(ARGV.fetch(6)))
    abort "semantic rejection evidence keys differ" unless rejection.keys.sort == %w[captureSelector checks imageFormat imageSha256 pixels reasons schemaVersion status].sort
    abort "semantic rejection evidence status differs" unless rejection.fetch("schemaVersion") == 1 && rejection.fetch("status") == "rejected"
    abort "semantic rejection evidence lacks reasons" unless rejection.fetch("reasons").is_a?(Array) && !rejection.fetch("reasons").empty?
    abort "semantic rejection selector changed" unless rejection.fetch("captureSelector") == selector
    abort "semantic rejection pixels changed" unless rejection.fetch("pixels") == [2560, 1600]
    abort "semantic rejection is not bound to its retained PNG bytes" unless
      rejection.fetch("imageFormat") == "png" &&
      rejection.fetch("imageSha256") == ENV.fetch("FIRST_REJECTION_IMAGE_SHA256")
    abort "semantic rejection checks differ" unless rejection.fetch("checks").keys.sort == %w[committedView matchedForbiddenSystemPromptGroups matchedRequiredTermGroups recognizedText].sort
    first_rejection = {
      "file" => "semantic-rejections/#{selector}-attempt-1.json",
      "sha256" => ENV.fetch("FIRST_REJECTION_SHA256"),
      "status" => "rejected",
      "validatorExitStatus" => 65,
      "imageFile" => "semantic-rejections/#{selector}-attempt-1.png",
      "imageSha256" => ENV.fetch("FIRST_REJECTION_IMAGE_SHA256"),
    }
  else
    abort "unexpected semantic rejection argument" unless ARGV.fetch(6) == "-"
    abort "unexpected semantic rejection hash" unless ENV.fetch("FIRST_REJECTION_SHA256").empty?
    abort "unexpected semantic rejection image hash" unless ENV.fetch("FIRST_REJECTION_IMAGE_SHA256").empty?
  end
  record = {
    "schemaVersion" => 1,
    "status" => "unapproved-debug-maccatalyst-capture-evidence",
    "uploadApproved" => false,
    "reviewer" => nil,
    "approval" => nil,
    "platform" => "maccatalyst",
    "locale" => "en-US",
    "captureSelector" => selector,
    "plannedFile" => ENV.fetch("CAPTURE_PLANNED_FILE"),
    "capturedAtUtc" => ENV.fetch("CAPTURED_AT_UTC"),
    "source" => { "commit" => ENV.fetch("SOURCE_COMMIT"), "treeState" => "clean" },
    "planManifest" => { "file" => ENV.fetch("MANIFEST_FILE"), "sha256" => ENV.fetch("MANIFEST_SHA256") },
    "product" => {
      "bundleIdentifier" => "com.quakesignal.app",
      "marketingVersion" => "1.1",
      "build" => 10,
      "scheme" => "QuakeSignal",
      "destination" => "platform=macOS,variant=Mac Catalyst",
      "configuration" => "Debug",
    },
    "host" => {
      "macOSVersion" => ENV.fetch("MACOS_VERSION"),
      "macOSBuild" => ENV.fetch("MACOS_BUILD"),
      "xcodeVersion" => ENV.fetch("XCODE_VERSION"),
      "xcodeBuild" => ENV.fetch("XCODE_BUILD"),
      "hardwareModel" => ENV.fetch("HARDWARE_MODEL"),
    },
    "app" => {
      "bundleName" => "QuakeSignal.app",
      "bundleTreeSha256" => ENV.fetch("APP_TREE_SHA256"),
      "mainExecutableFile" => "Contents/MacOS/QuakeSignal",
      "mainExecutableSha256" => ENV.fetch("MAIN_EXECUTABLE_SHA256"),
    },
    "build" => {
      "logFile" => "build-logs/#{selector}.log",
      "logSha256" => ENV.fetch("BUILD_LOG_SHA256"),
      "debugLocalOverridePresent" => false,
    },
    "geometryEvidence" => {
      "file" => "geometry-evidence/#{selector}.json",
      "sha256" => ENV.fetch("GEOMETRY_SHA256"),
      "recordedAtUtc" => geometry.fetch("recordedAtUtc"),
    },
    "captureRequest" => capture_request.merge(
      "file" => "capture-request-evidence/#{selector}.json",
      "sha256" => ENV.fetch("CAPTURE_REQUEST_SHA256"),
    ),
    "semanticValidation" => {
      "file" => "semantic-evidence/#{selector}.json",
      "sha256" => ENV.fetch("SEMANTIC_SHA256"),
      "status" => "accepted",
      "settleSeconds" => settle_seconds,
      "captureAttemptCount" => capture_attempt_count,
      "retryPerformed" => semantic_retry_performed,
      "firstRejection" => first_rejection,
    },
    "nativeCapture" => native_capture.merge(
      "file" => "native-capture-evidence/#{selector}.json",
      "sha256" => ENV.fetch("NATIVE_CAPTURE_SHA256"),
    ),
    "window" => window.merge(
      "sourceDisplayScale" => geometry.fetch("sourceDisplayScale"),
      "beforeObservationFile" => "window-observations/#{selector}-before.json",
      "beforeObservationSha256" => ENV.fetch("WINDOW_BEFORE_SHA256"),
      "afterObservationFile" => "window-observations/#{selector}-after.json",
      "afterObservationSha256" => ENV.fetch("WINDOW_AFTER_SHA256"),
    ),
    "transformation" => transform.merge(
      "file" => "transformation-evidence/#{selector}.json",
      "sha256" => ENV.fetch("TRANSFORMATION_SHA256"),
    ),
    "artifacts" => {
      "rawWindow" => {
        "file" => "raw-window-captures/#{selector}.png",
        "sha256" => ENV.fetch("RAW_SHA256"),
        "pixels" => [2560, 1600],
        "hasAlpha" => ENV.fetch("RAW_HAS_ALPHA") == "true",
      },
      "finalScreenshot" => {
        "file" => ENV.fetch("CAPTURE_PLANNED_FILE"),
        "sha256" => ENV.fetch("FINAL_SHA256"),
        "pixels" => [2560, 1600],
        "hasAlpha" => false,
      },
      "appLog" => {
        "file" => "app-logs/#{selector}.log",
        "sha256" => ENV.fetch("APP_LOG_SHA256"),
      },
    },
  }
  File.write(ARGV.fetch(7), JSON.pretty_generate(record) + "\n", mode: "wx")
' "$window_before" "$geometry_path" "$transformation_path" "$semantic_path" "$native_capture_path" "$capture_request_path" "$first_rejection_argument" "$frame_evidence"

if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: capture output appeared during publication; refusing to overwrite" >&2
  exit 73
fi
mv "$payload" "$output"
echo "Captured exact unapproved Mac Catalyst frame package: $output"
echo "Selector: $frame_selector"
echo "Final:    $planned_file ($final_sha256)"
echo "No artifact in this directory is approved for upload."
