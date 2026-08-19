#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/quakesignal-platform-interface-test.XXXXXX")"

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

dashboard = watch_source[/private var dashboard: some View \{.*?(?=\n    private var reports:)/m]
abort "error: ordinary Watch dashboard is missing" unless dashboard
unless dashboard.include?("WatchContextBadges") &&
       dashboard.include?("headline") &&
       dashboard.match?(/NavigationLink\s*\{\s*reports\s*\}/m)
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
       headline_card.include?('.buttonStyle(.plain)')
  abort "error: shared Watch headline card must retain location/date and open the production detail view"
end

recent = extract_view.call(watch_source, "WatchReportsView")
unless recent.include?("Button(action: onRefresh)") &&
       recent.include?('Label("platform.historical.reports"') &&
       recent.include?("ForEach(events.prefix(8))") &&
       recent.match?(/NavigationLink\s*\{\s*WatchEventDetailView\(event: event\)/m) &&
       recent.include?("ScrollView") &&
       recent.include?('.navigationTitle("app.name")')
  abort "error: shared production Watch reports view must retain refresh, history, navigation, and accessibility scrolling"
end

detail_declarations = watch_source.scan(/private struct WatchEventDetailView: View/).length
abort "error: Watch must have exactly one production event-detail view" unless detail_declarations == 1
detail = extract_view.call(watch_source, "WatchEventDetailView")
unless detail.match?(/foregroundBadge.*?Text\(event\.magnitudeText\).*?Label\(localizedDepthLabel\(depth\).*?Text\(event\.hypocenter\).*?event\.reportStatus\.labelKey.*?date\.formatted\(date: \.numeric, time: \.shortened\)/m) &&
       detail.include?("ScrollView") &&
       detail.include?('L("quake.intensity.label", maxIntensity)') &&
       detail.include?('Text("platform.watch.foregroundOnly.detail")') &&
       detail.match?(/\.navigationTitle\("detail\.title"\)\s*\.navigationBarTitleDisplayMode\(\.inline\)/m)
  abort "error: production Watch detail must retain disclosure and all reviewed event fields"
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

ruby - "$script_dir/capture-platform-screenshot.sh" <<'RUBY'
source = File.read(ARGV.fetch(0))

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
RUBY

echo "Platform screenshot interface tests passed"
