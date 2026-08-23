#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"
test_temp_parent="${QUAKESIGNAL_TEST_TEMP_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
if [ ! -d "$test_temp_parent" ]; then
  echo "error: screenshot test temporary parent is not an existing directory: $test_temp_parent" >&2
  exit 64
fi
test_temp_parent="$(cd "$test_temp_parent" && pwd -P)"
test_root="$(mktemp -d "$test_temp_parent/quakesignal-ios-capture-interface.XXXXXX")"

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
    /bin/cat "$test_root/stdout" "$test_root/stderr" >&2
    exit 1
  fi
}

expect_status 64 bash "$script_dir/capture-ios-screenshot.sh"
expect_status 64 bash "$script_dir/capture-ios-screenshot-set.sh"
expect_status 64 bash "$script_dir/capture-ios-screenshot.sh" ios-iphone-6.5-home relative-output
expect_status 64 bash "$script_dir/capture-ios-screenshot-set.sh" relative-output
expect_status 64 bash "$script_dir/capture-ios-screenshot.sh" ios-iphone-unreviewed "$test_root/unreviewed"
expect_status 64 bash "$script_dir/capture-ios-screenshot.sh" ios-iphone-6.5-home "$repo_root/forbidden-frame"
expect_status 64 bash "$script_dir/capture-ios-screenshot-set.sh" "$repo_root/forbidden-set"
forbidden_parent="$repo_root/.quakesignal-interface-forbidden-$$"
if [ -e "$forbidden_parent" ] || [ -L "$forbidden_parent" ]; then
  echo "error: interface test forbidden path unexpectedly exists" >&2
  exit 1
fi
expect_status 64 bash "$script_dir/capture-ios-screenshot.sh" \
  ios-iphone-6.5-home "$forbidden_parent/nested/frame"
expect_status 64 bash "$script_dir/capture-ios-screenshot-set.sh" "$forbidden_parent/nested/set"
if [ -e "$forbidden_parent" ] || [ -L "$forbidden_parent" ]; then
  echo "error: rejected repository-contained output mutated the repository" >&2
  exit 1
fi

mkdir "$test_root/existing-frame" "$test_root/existing-set"
expect_status 73 bash "$script_dir/capture-ios-screenshot.sh" ios-iphone-6.5-home "$test_root/existing-frame"
expect_status 73 bash "$script_dir/capture-ios-screenshot-set.sh" "$test_root/existing-set"

stub_bin="$test_root/bin"
mkdir "$stub_bin"
printf '%s\n' \
  '#!/bin/bash' \
  'case " $* " in' \
  '  *" rev-parse "*) printf "%040d\n" 0 ;;' \
  '  *" status "*) printf " M ios/QuakeSignalShared/ScreenshotAutomation.swift\n" ;;' \
  '  *) exit 1 ;;' \
  'esac' >"$stub_bin/git"
chmod +x "$stub_bin/git"
expect_status 65 env PATH="$stub_bin:$PATH" bash "$script_dir/capture-ios-screenshot.sh" \
  ios-iphone-6.5-home "$test_root/dirty-frame"
expect_status 65 env PATH="$stub_bin:$PATH" bash "$script_dir/capture-ios-screenshot-set.sh" \
  "$test_root/dirty-set"
if [ -e "$test_root/dirty-frame" ] || [ -e "$test_root/dirty-set" ]; then
  echo "error: dirty-source refusal published output" >&2
  exit 1
fi

/usr/bin/ruby -e '
  single, set, plan, validator, guard = ARGV.map { |path| File.read(path) }
  abort "single capture lost both fixture gates" unless
    single.include?("SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION=1") &&
    single.include?("SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_FRAME=\"$frame_selector\"") &&
    single.include?("--quakesignal-screenshot-automation") &&
    single.include?("--quakesignal-screenshot-frame=$frame_selector")
  abort "single capture lost no-resize JPEG transform" unless
    single.include?("sips -s format jpeg -s formatOptions 100") &&
    single.include?(%q["resizePerformed" => false])
  status_time_argument = "--time " + 39.chr + "9:41" + 39.chr
  abort "single capture lost Apple-documented simulator status-bar time" unless
    single.scan(%r{--time(?:\s|$)}).length == 1 &&
    single.include?(status_time_argument) &&
    single.scan(%q["statusBarTime" => "9:41"]).length == 1 &&
    !single.match?(%r{--time[^\n]*\d{4}-\d{2}-\d{2}T})
  abort "single capture lost source/Debug.local pre/post checks" unless
    single.scan(%r{git -C "\$repo_root" status --porcelain=v1 --untracked-files=all}).length == 2 &&
    single.scan(%r{\[ -e "\$debug_local_override" \] \|\| \[ -L "\$debug_local_override" \]}).length == 2
  abort "set capture lost source/Debug.local pre/post checks" unless
    set.scan(%r{git -C "\$repo_root" status --porcelain=v1 --untracked-files=all}).length == 2 &&
    set.scan(%r{\[ -e "\$debug_local_override" \] \|\| \[ -L "\$debug_local_override" \]}).length == 2
  abort "set capture must build once" unless set.scan(/xcodebuild build/).length == 1
  abort "set capture must create exactly two disposable devices" unless set.scan(/xcrun simctl create/).length == 2
  abort "iPadOS 26 captures must switch the disposable simulator to Full Screen Apps mode" unless
    [single, set].all? do |source|
      source.include?("SBChamoisWindowingEnabled") &&
        source.include?("SBFlexibleWindowingPreviouslyEnabledAutomaticStageCreation") &&
        source.include?("did not enter Full Screen Apps mode")
    end
  abort "set capture lost exact ten-frame guard" unless set.scan(/!= "10"/).length == 1
  abort "plan lost exact display sizes" unless plan.include?("[1242, 2688]") && plan.include?("[2064, 2752]")
  abort "validator lost permission-dialog rejection" unless validator.include?("forbiddenSystemPromptGroups")
  abort "semantic retry may occur on non-semantic failures" unless
    single.include?(%q[if [ "$validator_status" -ne 65 ] || [ "$attempt" -eq 2 ]])
  abort "final JPEG is not independently semantically validated" unless
    single.include?(%q["$validator" "$frame_selector" "$final_screenshot" "$accepted_semantic"])
  abort "accepted raw and final semantic records are not separately retained" unless
    single.include?(%q[accepted_raw_semantic="$payload/semantic-evidence/$frame_selector-raw.json"]) &&
    single.include?(%q[accepted_semantic="$payload/semantic-evidence/$frame_selector-final.json"]) &&
    set.include?(%q[semantic-evidence/$selector-raw.json]) &&
    set.include?(%q[semantic-evidence/$selector-final.json])
  abort "semantic retry did not retain and merge the rejected raw PNG" unless
    single.include?(%q[first_rejection_image_file="semantic-rejections/$frame_selector-attempt-1.png"]) &&
    set.include?(%q[semantic-rejections/$selector-attempt-1.png])
  abort "install-time Watch mutation fallback returned" if
    single.match?(%r{rm .*[Aa]pp_path/Watch}) || single.include?("embeddedWatchPayloadRemoved")
  abort "single capture lost exact installed-container byte proof" unless
    single.include?("simctl get_app_container") &&
    single.include?("installed_tree == app.fetch(\"bundleTree\")") &&
    single.include?(%q[[ -e "$installed_app_path/Watch" ] || [ -L "$installed_app_path/Watch" ]])
  unsafe_install_log = %q["installLogFile" => "install-logs/#{ENV.fetch(] +
    39.chr + "IOS_INSTALL_SELECTOR" + 39.chr + %q[)}.log"]
  abort "install-log selector interpolation is not shell-quote-safe" unless
    single.include?(%q["installLogFile" => "install-logs/#{ENV.fetch("IOS_INSTALL_SELECTOR")}.log"]) &&
    !single.include?(unsafe_install_log)
  abort "single capture lost parent-owned reused-simulator lease" unless
    single.include?("QUAKESIGNAL_IOS_SCREENSHOT_SIMULATOR_LEASE_TOKEN") &&
    single.include?("ios-screenshot-simulator-lease.rb\" verify")
  abort "set capture lost persistent simulator lease and verified pre-publication cleanup" unless
    set.include?("ios-screenshot-simulator-lease.rb\" create") &&
    set.include?("complete_set_simulator_cleanup") &&
    single.include?("verified owned-simulator lease was not retired") &&
    set.include?("verified set-simulator lease was not retired") &&
    set.index("complete_set_simulator_cleanup") < set.index("assemble-ios-screenshot-provenance.rb") &&
    set.index("complete_set_simulator_cleanup") < set.index("quakesignal_screenshot_publish_directory")
  abort "single/set publication lost bound parent identity and canonical post-rename proof" unless
    [single, set].all? do |source|
      source.include?("quakesignal_screenshot_capture_parent_identity") &&
        source.include?("quakesignal_screenshot_capture_directory_identity") &&
        source.include?("quakesignal_screenshot_publish_directory") &&
        source.include?("temporary_root_identity") && source.include?("payload_identity") &&
        source.include?("quakesignal_screenshot_parent_identity_matches") &&
        source.include?("quakesignal_screenshot_remove_bound_tree") &&
        !source.include?(%q[rm -rf "$temporary_root"])
    end &&
    guard.include?("publication parent identity changed") &&
    guard.include?("published output is not the exact canonical plain directory") &&
    guard.include?("bound cleanup parent identity changed")
  abort "captures lost HUP/INT/TERM traps" unless
    [single, set].all? { |source| source.match?(/trap .exit 129. HUP/) && source.match?(/trap .exit 130. INT/) && source.match?(/trap .exit 143. TERM/) }
  abort "set/direct builds lost exact list/result/Swift-input binding" unless
    [single, set].all? do |source|
      source.include?("xcodebuild -list -json") && source.include?("-resultBundlePath") &&
        source.include?("ios-screenshot-swift-inputs.rb") && source.include?("ios-screenshot-build-binding.rb")
    end
  abort "set/direct builds lost immediate pre/post-build source snapshots and live binding recheck" unless
    [single, set].all? do |source|
      list_index = source.index("xcodebuild -list -json")
      pre_snapshot_index = source.index("prepare-ios-screenshot-build-source.rb\" snapshot")
      build_index = source.index("xcodebuild build")
      post_snapshot_index = source.rindex("prepare-ios-screenshot-build-source.rb\" snapshot")
      settings_index = source.index("xcodebuild -showBuildSettings -json")
      list_index && pre_snapshot_index && build_index && post_snapshot_index && settings_index &&
        list_index < pre_snapshot_index && pre_snapshot_index < build_index &&
        build_index < post_snapshot_index && post_snapshot_index < settings_index &&
        source.include?("pre-build") && source.include?("post-build") &&
        source.include?(%q["$prebuild_source_snapshot" "$postbuild_source_snapshot" "$build_ios_root"])
    end &&
    single.include?("QUAKESIGNAL_IOS_SCREENSHOT_PREBUILD_SOURCE_SNAPSHOT") &&
    single.include?("QUAKESIGNAL_IOS_SCREENSHOT_POSTBUILD_SOURCE_SNAPSHOT") &&
    single.include?(%q["$app_path" "$external_build_binding" "$external_prebuild_source_snapshot"]) &&
    single.include?(%q["$external_postbuild_source_snapshot" -]) &&
    set.include?(%q[QUAKESIGNAL_IOS_SCREENSHOT_PREBUILD_SOURCE_SNAPSHOT="$prebuild_source_snapshot"]) &&
    set.include?(%q[QUAKESIGNAL_IOS_SCREENSHOT_POSTBUILD_SOURCE_SNAPSHOT="$postbuild_source_snapshot"]) &&
    set.include?(%q[build-source-snapshots/$selector.json]) &&
    set.include?(%q[post-build-source-snapshots/$selector.json])
  abort "set/direct builds lost fresh contained build overrides" unless
    [single, set].all? do |source|
      %w[SYMROOT OBJROOT BUILD_DIR BUILD_ROOT CONFIGURATION_BUILD_DIR SHARED_PRECOMPS_DIR CLANG_MODULE_CACHE_PATH DSTROOT].all? do |key|
        source.include?(%Q["#{key}=$derived_data/])
      end &&
        source.scan(/"ARCHS=[^"]*"/).length == 1 &&
        source.include?(%q["ARCHS=$host_architecture"]) &&
        source.scan(/"ONLY_ACTIVE_ARCH=[^"]*"/).length == 1 &&
        source.include?(%q["ONLY_ACTIVE_ARCH=NO"]) &&
        source.scan(%q["${build_overrides[@]}"]).length == 2
    end
  abort "set/direct capture architecture is not fail-closed to one supported runner architecture" unless
    [single, set].all? do |source|
      source.include?(%q[host_architecture="$(uname -m)"]) &&
        source.scan("arm64|x86_64").length == 1
    end
' "$script_dir/capture-ios-screenshot.sh" \
  "$script_dir/capture-ios-screenshot-set.sh" \
  "$script_dir/ios-screenshot-plan.rb" \
  "$script_dir/ios-screenshot-content-validator.swift" \
  "$script_dir/screenshot-process-guard.sh"

echo "iOS/iPadOS screenshot capture interface tests passed"
