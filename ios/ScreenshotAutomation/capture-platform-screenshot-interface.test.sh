#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
test_temp_root="${QUAKESIGNAL_TEST_TEMP_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
if [ ! -d "$test_temp_root" ] || [ -L "$test_temp_root" ]; then
  echo "error: screenshot test temp root must be an existing plain directory" >&2
  exit 64
fi
test_temp_root="$(cd "$test_temp_root" && pwd -P)"
test_root="$(mktemp -d "$test_temp_root/quakesignal-platform-interface-test.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

expect_status() {
  local expected_status="$1"
  shift
  local actual_status=0
  if "$@" >/dev/null 2>&1; then
    actual_status=0
  else
    actual_status=$?
  fi
  if [ "$actual_status" -ne "$expected_status" ]; then
    echo "error: expected status $expected_status, got $actual_status from $*" >&2
    exit 1
  fi
}

expect_status 64 "$script_dir/capture-platform-screenshot.sh"
expect_status 64 "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-unreviewed "$test_root/unreviewed.png"
expect_status 64 "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-dashboard relative.png
expect_status 64 env QUAKESIGNAL_SCREENSHOT_DERIVED_DATA=relative-cache \
  "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-dashboard "$test_root/relative-cache.png"

expect_status 64 "$script_dir/capture-platform-screenshot-set.sh"
expect_status 64 "$script_dir/capture-platform-screenshot-set.sh" \
  unreviewed "$test_root/unreviewed-set"
expect_status 64 env QUAKESIGNAL_SCREENSHOT_LOCALE=ja \
  "$script_dir/capture-platform-screenshot-set.sh" \
  tvos "$test_root/non-english-set"

mkdir "$test_root/existing-set"
expect_status 73 "$script_dir/capture-platform-screenshot-set.sh" \
  tvos "$test_root/existing-set"

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
expect_status 65 env PATH="$stub_bin:$PATH" \
  "$script_dir/capture-platform-screenshot-set.sh" tvos "$test_root/dirty-set"
if [ -e "$test_root/dirty-set" ]; then
  echo "error: dirty-source refusal published a native capture set" >&2
  exit 1
fi

ln -s "$test_root/missing-single-target.png" "$test_root/dangling-single.png"
expect_status 73 "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-dashboard "$test_root/dangling-single.png"

ln -s "$test_root/missing-provenance-target.json" "$test_root/dangling-provenance.json"
expect_status 73 env \
  QUAKESIGNAL_SCREENSHOT_PROVENANCE_OUTPUT="$test_root/dangling-provenance.json" \
  "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-dashboard "$test_root/provenance-guard.png"

ln -s "$test_root/missing-set-target" "$test_root/dangling-set"
expect_status 73 "$script_dir/capture-platform-screenshot-set.sh" \
  tvos "$test_root/dangling-set"

for forbidden_path in \
  "$script_dir/forbidden-single.png" \
  "$script_dir/forbidden-set"; do
  if [ -e "$forbidden_path" ]; then
    echo "error: interface test fixture unexpectedly exists: $forbidden_path" >&2
    exit 1
  fi
done
expect_status 64 "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-dashboard "$script_dir/forbidden-single.png"
expect_status 64 "$script_dir/capture-platform-screenshot-set.sh" \
  tvos "$script_dir/forbidden-set"

if find "$test_root" -type f -name '*.png' -print -quit | grep -q .; then
  echo "error: rejected interface input emitted a screenshot" >&2
  exit 1
fi

/usr/bin/ruby -e '
  source = File.read(ARGV.fetch(0))
  abort "native set lost clean-source pre/post checks" unless
    source.scan(%r{git -C "\$repo_root" status --porcelain=v1 --untracked-files=all}).length == 2
  abort "native set lost Debug.local pre/post checks" unless
    source.scan(%r{\[ -e "\$debug_local_override" \] \|\| \[ -L "\$debug_local_override" \]}).length == 2
  abort "native set lost source-commit plan binding" unless
    source.include?(%q[git -C "$repo_root" show "$source_commit:$plan_manifest_file"])
' "$script_dir/capture-platform-screenshot-set.sh"

# Both foreground-only detail screens share a `%@` localization template.
# Passing a Double directly to that object placeholder crashes Foundation's
# vararg formatter before SwiftUI commits the frame, leaving a Watch clock or
# TV system raster. Require an explicitly formatted String argument in each
# platform-local source so this contract cannot regress unnoticed.
for detail_source in \
  "$script_dir/../QuakeSignalWatch/WatchDashboardView.swift" \
  "$script_dir/../QuakeSignalTV/TVDashboardView.swift"; do
  if grep -Fq 'L("quake.depth.label", depth)' "$detail_source"; then
    echo "error: detail depth must not pass a Double to the %@ localization placeholder: $detail_source" >&2
    exit 1
  fi
  grep -Fq 'Label(localizedDepthLabel(depth), systemImage: "arrow.down")' "$detail_source" || {
    echo "error: detail screen does not use the reviewed localized depth helper: $detail_source" >&2
    exit 1
  }
  grep -Fq 'locale: Locale(identifier: "en_US_POSIX")' "$detail_source" || {
    echo "error: detail depth helper lost its deterministic numeric locale: $detail_source" >&2
    exit 1
  }
  grep -Fq 'return L("quake.depth.label", depthText)' "$detail_source" || {
    echo "error: detail depth helper must pass formatted text to the %@ placeholder: $detail_source" >&2
    exit 1
  }
done

ruby - "$script_dir/../QuakeSignalWatch/WatchDashboardView.swift" <<'RUBY'
source = File.read(ARGV.fetch(0))
detail = source[/private struct WatchEventDetailView: View \{.*?(?=\nprivate func localizedDepthLabel)/m]
abort "error: Watch detail view block is missing" unless detail

checks = {
  "use a ScrollView as its first body container" =>
    /var body: some View \{\s*ScrollView \{/m,
  "place the foreground banner before the first metric row" =>
    /ScrollView \{\s*VStack\(alignment: \.leading, spacing: \d+\) \{\s*foregroundBadge\s*HStack/m,
  "show localized depth beside magnitude in the first-baseline row" =>
    /HStack\(alignment: \.firstTextBaseline, spacing: \d+\) \{\s*Text\(event\.magnitudeText\).*?Label\(localizedDepthLabel\(depth\), systemImage: "arrow\.down"\)/m,
  "reserve inline navigation-title space above its foreground banner" =>
    /\.navigationTitle\("detail\.title"\)\s*\.navigationBarTitleDisplayMode\(\.inline\)/m
}

checks.each do |requirement, pattern|
  abort "error: Watch detail must #{requirement}" unless detail.match?(pattern)
end

body_spacing = detail[/VStack\(alignment: \.leading, spacing: (\d+)\)/, 1]&.to_i
metric_spacing = detail[/HStack\(alignment: \.firstTextBaseline, spacing: (\d+)\)/, 1]&.to_i
unless body_spacing && body_spacing <= 7 && metric_spacing && metric_spacing <= 7
  abort "error: Watch detail top spacing must remain compact enough for the 205x251-point viewport"
end
RUBY

ruby - \
  "$script_dir/../QuakeSignalWatch/WatchDashboardView.swift" \
  "$script_dir/../QuakeSignalTV/TVDashboardView.swift" <<'RUBY'
watch_source = File.read(ARGV.fetch(0))
tv_source = File.read(ARGV.fetch(1))

extract_view = lambda do |source, name|
  block = source[/private struct #{Regexp.escape(name)}: View \{.*?(?=\nprivate struct|\nprivate func)/m]
  abort "error: #{name} block is missing" unless block
  block
end

routes = watch_source[/switch ScreenshotAutomation\.selectedFrame \{.*?\n            default:/m]
abort "error: Watch screenshot routing switch is missing" unless routes

capture_only_views = [watch_source, tv_source].flat_map do |source|
  source.scan(/\b(?:struct|class)\s+([A-Za-z0-9_]*ScreenshotView)\b/).flatten
end
unless capture_only_views.empty?
  abort "error: screenshot selectors must not render capture-only views: #{capture_only_views.join(', ')}"
end

unless routes.match?(/case \.watchHeadline:\s*dashboard/) &&
       routes.match?(/case \.watchRecentReports:\s*reports/) &&
       routes.match?(/case \.watchEventDetail:.*?WatchEventDetailView\(event: event\)/m)
  abort "error: Watch selectors must route to ordinary production dashboard, reports, and detail views"
end

if watch_source.include?('proxy.scrollTo("watch-recent-reports"') ||
   watch_source.include?('.id("watch-recent-reports")')
  abort "error: Watch recent-reports capture must not depend on a ScrollViewReader anchor"
end

badges = extract_view.call(watch_source, "WatchContextBadges")
unless badges.match?(/\.lineLimit\(1\).*?\.minimumScaleFactor\(0\.78\)/m)
  abort "error: Watch context badges must stay single-line with a reviewed scale floor"
end

foreground_badge_icons = watch_source.scan(
  /Label\("platform\.foreground\.badge", systemImage: "([^"]+)"\)/,
).flatten
unless foreground_badge_icons == Array.new(3, "applewatch")
  abort "error: all three Watch foreground-only badges must use the Apple Watch glyph"
end
mutated_badge_source = watch_source.sub(
  'Label("platform.foreground.badge", systemImage: "applewatch")',
  'Label("platform.foreground.badge", systemImage: "eye")',
)
mutated_badge_icons = mutated_badge_source.scan(
  /Label\("platform\.foreground\.badge", systemImage: "([^"]+)"\)/,
).flatten
if mutated_badge_icons == Array.new(3, "applewatch")
  abort "error: Watch foreground-only icon contract did not reject an eye-glyph mutation"
end

dashboard = watch_source[/private var dashboard: some View \{.*?(?=\n    private var reports:)/m]
abort "error: ordinary Watch dashboard is missing" unless dashboard
unless dashboard.include?("WatchContextBadges") &&
       dashboard.include?("headline") &&
       dashboard.match?(/NavigationLink\s*\{\s*reports\s*\}/m) &&
       dashboard.include?(".id(WatchDashboardPage.headline)") &&
       dashboard.include?(".id(WatchDashboardPage.controls)") &&
       dashboard.scan("minHeight: geometry.size.height").length == 2 &&
       dashboard.include?(".scrollTargetBehavior(.paging)") &&
       dashboard.scan(".ignoresSafeArea(.container, edges: .bottom)").length == 1 &&
       dashboard.match?(/\.navigationTitle\("app\.name"\)\s*\.navigationBarTitleDisplayMode\(\.inline\)/m)
  abort "error: ordinary Watch dashboard must show the compact headline and expose the shared reports destination"
end

reports_builder = watch_source[/private var reports: some View \{.*?(?=\n    @ViewBuilder)/m]
unless reports_builder&.include?("WatchReportsView(")
  abort "error: Watch reports selector and NavigationLink must share one production destination builder"
end

headline_card = extract_view.call(watch_source, "WatchHeadlineCard")
unless headline_card.match?(/Text\(event\.hypocenter\).*?\.lineLimit\(2\)/m) &&
       headline_card.include?('date.formatted(date: .numeric, time: .shortened)') &&
       headline_card.match?(/NavigationLink\s*\{\s*WatchEventDetailView\(event: event\)/m) &&
       headline_card.include?('.buttonStyle(.plain)') &&
       headline_card.include?("@FocusState private var isFocused: Bool") &&
       headline_card.include?(".focused($isFocused)") &&
       headline_card.include?("isFocused ? .black : .white") &&
       headline_card.include?("isFocused ? Color.black.opacity(0.72) : Color.white.opacity(0.72)") &&
       headline_card.include?("Color(white: 0.16)") &&
       !headline_card.include?('Color("CardColor")')
  abort "error: shared Watch headline card must retain readable focus-aware location/date and open production detail"
end

recent = extract_view.call(watch_source, "WatchReportsView")
unless recent.include?("Array(events.prefix(2))") &&
       recent.include?("Array(events.dropFirst(2).prefix(6))") &&
       recent.match?(/VStack\(alignment: \.leading, spacing: 3\).*?WatchReportsHeader.*?ForEach\(firstPageEvents\)/m) &&
       recent.include?("ForEach(firstPageEvents)") &&
       recent.include?("ForEach(remainingEvents)") &&
       recent.include?("ScrollView") &&
       recent.scan("minHeight: geometry.size.height").length == 2 &&
       recent.include?(".id(WatchReportsPage.first)") &&
       recent.include?(".id(WatchReportsPage.remaining)") &&
       recent.include?(".scrollTargetBehavior(.paging)") &&
       recent.scan(".ignoresSafeArea(.container, edges: .bottom)").length == 1 &&
       recent.match?(/\.navigationTitle\("app\.name"\)\s*\.navigationBarTitleDisplayMode\(\.inline\)/m)
  abort "error: shared production Watch reports must page an exact complete 2-row first viewport before remaining reports"
end

reports_header = extract_view.call(watch_source, "WatchReportsHeader")
unless reports_header.match?(/var body: some View \{\s*HStack\(alignment: \.center, spacing: 5\) \{\s*VStack\(alignment: \.leading, spacing: 4\).*?Label\("platform\.foreground\.badge".*?Label\("platform\.historical\.reports".*?\.frame\(maxWidth: \.infinity, alignment: \.leading\).*?Button\(action: onRefresh\)/m) &&
       reports_header.include?('Label("platform.historical.reports"') &&
       reports_header.include?("WatchRefreshControlLabel(isLoading: isLoading)") &&
       reports_header.include?(".buttonStyle(.plain)") &&
       reports_header.include?('.accessibilityLabel(Text("platform.refresh"))') &&
       !reports_header.include?('Label("platform.refresh", systemImage: "arrow.clockwise")')
  abort "error: Watch reports header must keep an icon-only localized accessible 44-point refresh control"
end

refresh_control = extract_view.call(watch_source, "WatchRefreshControlLabel")
unless refresh_control.include?('Image(systemName: "arrow.clockwise")') &&
       refresh_control.match?(/\.frame\(width: 44, height: 44\)\s*\.contentShape\(Rectangle\(\)\)/m) &&
       refresh_control.include?("RoundedRectangle(cornerRadius: 12, style: .continuous)")
  abort "error: Watch refresh label must own its complete 44-by-44-point visible hit region"
end

report_link = extract_view.call(watch_source, "WatchReportLink")
unless report_link.include?("@FocusState private var isFocused: Bool") &&
       report_link.match?(/NavigationLink\s*\{\s*WatchEventDetailView\(event: event\)/m) &&
       report_link.include?("WatchCompactEventRow(event: event, isFocused: isFocused)") &&
       report_link.include?(".focused($isFocused)") &&
       report_link.include?(".buttonStyle(.plain)")
  abort "error: every production Watch report link must bind real focus state to the shared detail destination"
end

report_row = extract_view.call(watch_source, "WatchCompactEventRow")
unless report_row.include?("let isFocused: Bool") &&
       report_row.include?("isFocused ? .black : .white") &&
       report_row.include?("isFocused ? Color.black.opacity(0.72) : Color.white.opacity(0.72)") &&
       report_row.include?("Color(white: 0.16)") &&
       report_row.match?(/Text\(event\.hypocenter\).*?\.font\(\.caption2\.weight\(\.semibold\)\).*?\.lineLimit\(2, reservesSpace: true\).*?\.minimumScaleFactor\(0\.82\)/m) &&
       report_row.include?(".padding(.vertical, 2)") &&
       report_row.include?('date.formatted(date: .omitted, time: .shortened)') &&
       !report_row.include?('Color("CardColor")')
  abort "error: production Watch report rows must keep complete two-line locations and metadata readable in both focus states"
end

detail_declarations = watch_source.scan(/private struct WatchEventDetailView: View/).length
abort "error: Watch must have exactly one production event-detail view" unless detail_declarations == 1
detail = extract_view.call(watch_source, "WatchEventDetailView")
unless detail.match?(/foregroundBadge.*?Text\(event\.magnitudeText\).*?event\.maxIntensity.*?Label\(localizedDepthLabel\(depth\).*?event\.reportStatus\.labelKey.*?event\.sourceLabelKey.*?Text\(event\.hypocenter\).*?date\.formatted\(date: \.numeric, time: \.shortened\)/m) &&
       detail.include?("ScrollView") &&
       detail.include?('L("quake.intensity.label", maxIntensity)') &&
       detail.include?('Text("platform.watch.foregroundOnly.detail")') &&
       detail.match?(/\.navigationTitle\("detail\.title"\)\s*\.navigationBarTitleDisplayMode\(\.inline\)/m)
  abort "error: production Watch detail must retain disclosure and all reviewed event fields"
end


watch_detail_layout_errors = lambda do |view|
  errors = []
  errors << "compact body spacing" unless view.match?(/VStack\(alignment: \.leading, spacing: 4\)/)
  unless view.match?(/HStack\(alignment: \.firstTextBaseline, spacing: 5\).*?Text\(event\.magnitudeText\).*?size: 34.*?VStack\(alignment: \.trailing, spacing: 1\).*?event\.maxIntensity.*?localizedDepthLabel\(depth\).*?event\.reportStatus\.labelKey.*?event\.sourceLabelKey/m)
    errors << "stacked summary facts"
  end
  errors << "one max-intensity field" unless view.scan("event.maxIntensity").length == 1
  errors << "one depth field" unless view.scan("event.depth").length == 1
  unless view.match?(/date\.formatted\(date: \.numeric, time: \.shortened\).*?Divider\(\)\s*\.padding\(\.top, 12\)/m)
    errors << "clean initial viewport boundary after date"
  end
  disclosure = view[/Text\("platform\.watch\.foregroundOnly\.detail"\).*?(?=\n\s*\}\n\s*\.padding\(\.horizontal, 8\))/m]
  unless disclosure&.match?(/\.font\(\.footnote\).*?\.fixedSize\(horizontal: false, vertical: true\)/m) &&
         !disclosure.include?(".lineLimit(") &&
         !disclosure.include?(".minimumScaleFactor(")
    errors << "accessible complete disclosure"
  end
  unless view.match?(/\.fixedSize\(horizontal: false, vertical: true\)\s*\}\s*\.padding\(\.horizontal, 8\)\s*\.padding\(\.bottom, 10\)/m)
    errors << "safe content insets"
  end
  errors
end

layout_errors = watch_detail_layout_errors.call(detail)
unless layout_errors.empty?
  abort "error: Watch detail layout contract failed: #{layout_errors.join(', ')}"
end

layout_mutations = {
  "oversized magnitude" => detail.sub("size: 34", "size: 40"),
  "missing horizontal inset" => detail.sub(".padding(.horizontal, 8)", ".padding(.horizontal, 0)"),
  "missing bottom inset" => detail.sub(".padding(.bottom, 10)", ".padding(.bottom, 0)"),
  "insufficient first-viewport disclosure separation" => detail.sub(
    ".padding(.top, 12)",
    ".padding(.top, 0)"
  ),
  "undersized disclosure" => detail.sub(".font(.footnote)", ".font(.system(size: 9.5))"),
  "truncated disclosure" => detail.sub(
    ".fixedSize(horizontal: false, vertical: true)",
    ".lineLimit(3)"
  ),
}
layout_mutations.each do |name, mutated_detail|
  if watch_detail_layout_errors.call(mutated_detail).empty?
    abort "error: Watch detail layout contract did not reject #{name} mutation"
  end
end

if tv_source.include?("isRecentReportsScreenshot") || tv_source.include?("recentEventLimit")
  abort "error: TV reports must not use capture-only layout or row-limit branches"
end

unless tv_source.match?(/ScreenshotAutomation\.selectedFrame == \.tvRecentReports \{\s*recentReportsDestination/m) &&
       tv_source.match?(/NavigationLink\s*\{\s*recentReportsDestination\s*\}/m)
  abort "error: TV selector and ordinary dashboard navigation must share the production reports destination"
end

tv_reports_builder = tv_source[/private var recentReportsDestination: some View \{.*?(?=\n    private var header:)/m]
unless tv_reports_builder&.include?("TVRecentReportsView(") &&
       tv_reports_builder.include?("Array(store.events.prefix(12))")
  abort "error: TV reports destination must use the normal reviewed report inventory"
end

tv_reports = extract_view.call(tv_source, "TVRecentReportsView")
if tv_reports.include?("ScreenshotAutomation") ||
   tv_reports.include?(".clipped(") ||
   tv_reports.include?(".mask(") ||
   tv_reports.include?(".offset(") ||
   tv_reports.include?("ScrollView")
  abort "error: shared TV reports view must remain selector-independent, fixed, and unclipped"
end
unless tv_reports.include?("LazyVGrid") &&
       tv_reports.include?("ForEach(events)") &&
       tv_reports.include?("maxHeight: .infinity, alignment: .topLeading") &&
       tv_reports.include?("focusedEventID = firstEventID")
  abort "error: shared TV reports view must top-anchor the full grid and visibly focus its first report"
end
RUBY

ruby - \
  "$script_dir/capture-platform-screenshot.sh" \
  "$script_dir/watch-capture-guard.sh" <<'RUBY'
source = File.read(ARGV.fetch(0))
watch_guard = File.read(ARGV.fetch(1))

build_destination_assignments = source.lines.grep(/^build_destination=/).map(&:chomp)
unless build_destination_assignments == ['build_destination="generic/platform=$destination_platform"']
  abort "error: native capture builds must use exactly one generic simulator platform assignment"
end
destination_flags = source.lines.grep(/^\s+-destination /).map(&:strip)
unless destination_flags == Array.new(2, '-destination "$build_destination" \\')
  abort "error: build and build-settings discovery must share the generic simulator destination"
end
if source.include?('destination="platform=$destination_platform,id=$simulator_id"') ||
   source.match?(/-destination "\$simulator_id"/)
  abort "error: xcodebuild must not depend on rediscovering the ephemeral simulator UUID"
end

{
  "install" => /xcrun simctl install "\$simulator_id" "\$app_path"/,
  "launch" => /xcrun simctl launch.*?"\$simulator_id"\s*\\\s*"\$bundle_id"/m,
  "screenshot" => /xcrun simctl io "\$simulator_id" screenshot/,
  "provenance" => /CAPTURE_SIMULATOR_UDID="\$simulator_id"/
}.each do |operation, pattern|
  abort "error: native #{operation} must remain bound to the exact selected simulator UUID" unless
    source.match?(pattern)
end

watch_launch_helper = watch_guard[/^quakesignal_launch_exact_watch_frame\(\) \{.*?^\}/m]
unless watch_launch_helper &&
       watch_launch_helper.include?('local launch_max_attempts=2') &&
       watch_launch_helper.include?('local launch_backoff_seconds=5') &&
       watch_launch_helper.include?('SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION=1') &&
       watch_launch_helper.include?('SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_FRAME="$frame_selector"') &&
       watch_launch_helper.include?('--quakesignal-screenshot-automation') &&
       watch_launch_helper.include?('"--quakesignal-screenshot-frame=$frame_selector"') &&
       watch_launch_helper.include?('simctl launch --terminate-running-process') &&
       watch_launch_helper.include?('return 70') &&
       watch_launch_helper.scan('simctl launch').length == 1
  abort "error: shared Watch launch helper must preserve two exact dual-gated attempts, five-second backoff, and operational status 70"
end
unless watch_guard.scan(/\bquakesignal_launch_exact_watch_frame\b/).length == 2
  abort "error: semantic Watch retry must reuse the one shared exact-frame launch helper"
end
unless source.scan(/\bquakesignal_launch_exact_watch_frame\b/).length == 1
  abort "error: initial Watch launch must call the shared exact-frame helper exactly once"
end

launch_fixture_definition = source.index('launch_fixture_app() {')
watch_initial_branch = source.index('if [ "$platform" = "watchos" ]; then', launch_fixture_definition)
watch_initial_call = source.index('quakesignal_launch_exact_watch_frame', watch_initial_branch)
watch_initial_status_check = source.index('if [ "$watch_initial_launch_status" -ne 0 ]; then', watch_initial_call)
watch_initial_failure_exit = source.index('exit "$watch_initial_launch_status"', watch_initial_status_check)
initial_settle = source.index('sleep "$initial_settle_seconds"', watch_initial_failure_exit)
candidate_assignment = source.index('candidate="$temporary_root/$platform-$locale.png"', initial_settle)
watch_capture = source.index('quakesignal_capture_validated_watch_screenshot', candidate_assignment)
pixel_inspection = source.index('pixel_width="$(sips -g pixelWidth "$candidate"', watch_capture)
publication = source.index('mv "$candidate" "$output"', pixel_inspection)
provenance = source.index('if [ -n "$provenance_output" ]; then', publication)
unless [launch_fixture_definition, watch_initial_branch, watch_initial_call,
        watch_initial_status_check, watch_initial_failure_exit, initial_settle,
        candidate_assignment, watch_capture, pixel_inspection, publication,
        provenance].all? &&
       launch_fixture_definition < watch_initial_branch &&
       watch_initial_branch < watch_initial_call &&
       watch_initial_call < watch_initial_status_check &&
       watch_initial_status_check < watch_initial_failure_exit &&
       watch_initial_failure_exit < initial_settle &&
       initial_settle < candidate_assignment && candidate_assignment < watch_capture &&
       watch_capture < pixel_inspection && pixel_inspection < publication &&
       publication < provenance
  abort "error: failed initial Watch launch must exit before settle, capture, inspection, publication, and provenance"
end

unless source.include?('source "$script_dir/vision-map-capture-guard.sh"') &&
       source.include?('vision_settle_seconds=25') &&
       source.match?(/if \[ "\$platform" = "visionos" \]; then\s*initial_settle_seconds="\$vision_settle_seconds"/m) &&
       source.match?(/elif \[ "\$platform" = "visionos" \]; then\s*vision_capture_status=0\s*quakesignal_capture_validated_vision_screenshot/m) &&
       source.match?(/quakesignal_capture_validated_vision_screenshot.*?"\$script_dir\/validate-vision-map-content\.rb".*?"\$vision_settle_seconds" sips \/usr\/bin\/ruby \|\|/m) &&
       source.include?('exit "$vision_capture_status"')
  abort "error: every exact Vision capture must use the 25-second bounded semantic validator/retry before publication"
end
unless source.scan("quakesignal_capture_validated_vision_screenshot").length == 1
  abort "error: Vision semantic retry must have exactly one platform-wide capture branch"
end

vision_branch = source.index('elif [ "$platform" = "visionos" ]; then')
guard_call = source.index("quakesignal_capture_validated_vision_screenshot", vision_branch)
status_check = source.index('if [ "$vision_capture_status" -ne 0 ]; then', guard_call)
failure_exit = source.index('exit "$vision_capture_status"', status_check)
pixel_inspection = source.index('pixel_width="$(sips -g pixelWidth "$candidate"', failure_exit)
publication = source.index('mv "$candidate" "$output"', pixel_inspection)
provenance = source.index('if [ -n "$provenance_output" ]; then', publication)
unless [vision_branch, guard_call, status_check, failure_exit, pixel_inspection, publication, provenance].all? &&
       vision_branch < guard_call && guard_call < status_check && status_check < failure_exit &&
       failure_exit < pixel_inspection && pixel_inspection < publication && publication < provenance
  abort "error: Vision semantic failure must exit before pixel inspection, publication, and provenance"
end
RUBY

# Execute the real set publisher around a deterministic capture stub. Four
# earlier frames enter its private payload, then the final non-map selector
# fails semantically. The set must clean that payload and never run aggregation
# or atomically move any partial output into the caller-visible destination.
atomic_repo="$test_root/atomic-repo"
atomic_script_dir="$atomic_repo/ios/ScreenshotAutomation"
atomic_output="$test_root/atomic-vision-output"
atomic_trace="$test_root/atomic-capture-trace"
atomic_aggregate_marker="$test_root/atomic-aggregate-ran"
mkdir -p "$atomic_script_dir"
cp "$script_dir/capture-platform-screenshot-set.sh" \
  "$atomic_script_dir/capture-platform-screenshot-set.sh"
/usr/bin/ruby - "$atomic_script_dir" <<'RUBY'
script_dir = ARGV.fetch(0)
File.write(File.join(script_dir, "platform-screenshot-plan.rb"), <<~'PLAN')
  require "digest"
  require "json"
  case ARGV
  when ["visionos", "--json"]
    puts JSON.generate(
      "manifestFile" => "ios/AppStore/platforms/visionos/atomic-plan.json",
      "manifestSha256" => Digest::SHA256.hexdigest("atomic plan\n")
    )
  when ["visionos", "--tsv"]
    puts [
      "visionos-home\ten-US/01-home.png\t3840\t2160",
      "visionos-reports\ten-US/02-reports.png\t3840\t2160",
      "visionos-map\ten-US/03-map.png\t3840\t2160",
      "visionos-guide\ten-US/04-guide.png\t3840\t2160",
      "visionos-alert-preferences\ten-US/05-alert-preferences.png\t3840\t2160"
    ]
  else
    abort "unexpected atomic plan request"
  end
PLAN
File.write(File.join(script_dir, "capture-platform-screenshot.sh"), <<~'CAPTURE')
  #!/bin/bash
  set -euo pipefail
  platform="$1"
  selector="$2"
  output="$3"
  [ "$platform" = "visionos" ]
  printf '%s\n' "$selector" >> "$QUAKESIGNAL_TEST_CAPTURE_TRACE"
  if [ "$selector" = "visionos-alert-preferences" ]; then
    exit 65
  fi
  mkdir -p "$(dirname "$output")" "$(dirname "$QUAKESIGNAL_SCREENSHOT_PROVENANCE_OUTPUT")"
  printf 'private-candidate\n' > "$output"
  printf '{}\n' > "$QUAKESIGNAL_SCREENSHOT_PROVENANCE_OUTPUT"
CAPTURE
File.write(File.join(script_dir, "assemble-platform-screenshot-provenance.rb"), <<~'ASSEMBLE')
  File.write(ENV.fetch("QUAKESIGNAL_TEST_AGGREGATE_MARKER"), "ran\n")
ASSEMBLE
File.chmod(0o755, File.join(script_dir, "capture-platform-screenshot.sh"))
RUBY

atomic_bin="$test_root/atomic-bin"
mkdir "$atomic_bin"
printf '%s\n' \
  '#!/bin/bash' \
  'case " $* " in' \
  '  *" rev-parse "*) printf "%040d\n" 0 ;;' \
  '  *" status "*) exit 0 ;;' \
  '  *" show "*) printf "atomic plan\n" ;;' \
  '  *) exit 1 ;;' \
  'esac' >"$atomic_bin/git"
chmod +x "$atomic_bin/git"

expect_status 65 env \
  PATH="$atomic_bin:$PATH" \
  QUAKESIGNAL_TEST_CAPTURE_TRACE="$atomic_trace" \
  QUAKESIGNAL_TEST_AGGREGATE_MARKER="$atomic_aggregate_marker" \
  "$atomic_script_dir/capture-platform-screenshot-set.sh" \
    visionos "$atomic_output"

expected_atomic_trace=$'visionos-home\nvisionos-reports\nvisionos-map\nvisionos-guide\nvisionos-alert-preferences'
if [ ! -f "$atomic_trace" ] || [ "$(<"$atomic_trace")" != "$expected_atomic_trace" ]; then
  echo "error: atomic set fixture did not reach the final exact Vision failure after four private frames" >&2
  exit 1
fi
if [ -e "$atomic_output" ] || [ -L "$atomic_output" ] ||
    [ -e "$atomic_aggregate_marker" ] || [ -L "$atomic_aggregate_marker" ]; then
  echo "error: semantic Vision rejection published a partial set or provenance aggregate" >&2
  exit 1
fi
if find "$test_root" -maxdepth 1 -name '.quakesignal-visionos-set.*' -print -quit | grep -q .; then
  echo "error: semantic Vision rejection left the set's private payload behind" >&2
  exit 1
fi

echo "Platform screenshot interface tests passed"
