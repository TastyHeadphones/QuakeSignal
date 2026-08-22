#!/usr/bin/env ruby

root = File.expand_path("../..", __dir__)

read = lambda do |relative|
  path = File.join(root, relative)
  abort "error: missing #{relative}" unless File.file?(path)
  File.read(path)
end

dashboard = read.call("ios/QuakeSignalTV/TVDashboardView.swift")
monitor = read.call("ios/QuakeSignalTV/TVEmergencyMonitor.swift")
policy = read.call("ios/QuakeSignalTV/TVEmergencyPresentationPolicy.swift")
audio = read.call("ios/QuakeSignalTV/TVUserInitiatedAlertAudio.swift")
preferences = read.call("ios/QuakeSignalTV/TVAlertPreferences.swift")
settings = read.call("ios/QuakeSignalTV/TVAlertSoundSettingsView.swift")
alert = read.call("ios/QuakeSignalTV/TVEmergencyAlertView.swift")

unless dashboard.include?("let shouldMonitor = scenePhase == .active && !ScreenshotAutomation.isEnabled") &&
       dashboard.include?("emergencyMonitor.setSceneActive(false)") &&
       dashboard.include?("alertAudio.stop()") &&
       dashboard.match?(/\.onChange\(of: emergencyMonitor\.presentedWarning\?\.id\).*?alertAudio\.stop\(\)/m) &&
       dashboard.include?(".disabled(emergencyMonitor.presentedWarning != nil)") &&
       dashboard.include?(".accessibilityHidden(emergencyMonitor.presentedWarning != nil)") &&
       dashboard.match?(/if let warning = emergencyMonitor\.presentedWarning \{\s*TVEmergencyAlertView\(/m)
  abort "error: TV dashboard must keep monitoring, audio, screenshot, focus, and accessibility lifecycle scene-bound"
end

dashboard_layout = dashboard[/private enum TVDashboardLayout \{.*?^\}/m]
dashboard_surface = dashboard[/private var dashboard: some View \{.*?(?=\n    private var dashboardContent:)/m]
dashboard_content = dashboard[/private var dashboardContent: some View \{.*?(?=\n    private var recentReportsDestination:)/m]
recent_events = dashboard[/private var recentEvents: some View \{.*?(?=\n    \}\n\}\n\nprivate struct TVRecentReportsView)/m]

required_layout_budgets = {
  "dashboardOuterVerticalPadding" => 54,
  "dashboardSectionSpacing" => 34,
  "dashboardRowVerticalPadding" => 22,
}
required_layout_budgets.each do |name, value|
  declaration = /^    static let #{Regexp.escape(name)}: CGFloat = #{value}$/
  abort "error: TV dashboard layout budget #{name} must remain exactly #{value} points" unless dashboard_layout&.match?(declaration)
end

event_row = dashboard[/private struct TVEventRow: View \{.*?(?=\nprivate struct TVEventDetailView)/m]
unless dashboard_surface&.include?(".padding(.vertical, TVDashboardLayout.dashboardOuterVerticalPadding)") &&
       dashboard_content&.include?("VStack(alignment: .leading, spacing: TVDashboardLayout.dashboardSectionSpacing)") &&
       event_row&.include?(".padding(.vertical, TVDashboardLayout.dashboardRowVerticalPadding)")
  abort "error: TV dashboard must apply its reviewed outer, section, and complete-row layout budgets"
end

unless dashboard_layout&.include?("static let previewEventCount = 2") &&
       recent_events&.include?("ForEach(store.events.prefix(TVDashboardLayout.previewEventCount))") &&
       recent_events.include?("TVEventDetailView(event: event)") &&
       recent_events.include?("recentReportsDestination") &&
       !recent_events.include?("ScreenshotAutomation")
  abort "error: TV dashboard must show exactly two complete production preview rows and retain the full reports destination"
end

report_card = dashboard[/private struct TVReportCard: View \{.*?(?=\nprivate struct TVEventRow)/m]
unless report_card&.include?("let isFocused: Bool") &&
       report_card.include?('isFocused ? Color("CautionColor") : .clear') &&
       report_card.include?("lineWidth: 6")
  abort "error: TV report cards must retain their explicit orange Remote-focus ring"
end

event_detail = dashboard[/private struct TVEventDetailView: View \{.*?(?=\nprivate func localizedDepthLabel)/m]
unless event_detail&.scan(/\bScrollView \{/)&.length == 1 &&
       event_detail.match?(/var body: some View \{\s*ZStack \{.*?ScrollView \{\s*VStack\(alignment: \.leading, spacing: 26\)/m) &&
       event_detail.match?(/Label\("detail\.title", systemImage: "info\.circle\.fill"\).*?\.font\(\.largeTitle\.bold\(\)\).*?\.foregroundStyle\(\.primary\).*?\.accessibilityAddTraits\(\.isHeader\)/m) &&
       event_detail.match?(/Label \{\s*Text\("shared\.disclaimer"\).*?\.fixedSize\(horizontal: false, vertical: true\).*?\} icon: \{\s*Image\(systemName: "exclamationmark\.shield\.fill"\).*?Color\("CautionColor"\).*?\.font\(\.headline\).*?\.foregroundStyle\(\.primary\).*?Color\("CardSecondaryColor"\)/m) &&
       event_detail.include?('Label(localizedDepthLabel(depth), systemImage: "arrow.down")') &&
       event_detail.include?('Label(event.sourceLabelKey, systemImage: "antenna.radiowaves.left.and.right")') &&
       event_detail.include?("event.reportDate ?? event.originDate") &&
       event_detail.include?('.navigationTitle("")') &&
       !event_detail.include?("ScreenshotAutomation")
  abort "error: TV detail must expose a semantic high-contrast title and readable contrast-backed disclosure"
end

unless monitor.include?("@MainActor") &&
       monitor.include?("guard isSceneActive else { return }") &&
       monitor.include?("socket.stop()") &&
       monitor.include?("fallbackTask?.cancel()") &&
       monitor.include?("expirationTask?.cancel()") &&
       monitor.include?("isBackfill: true") &&
       monitor.include?("hadLocalHistoryBeforeBatch: locallyKnownEventIDs.contains(event.id)") &&
       monitor.include?("TVEmergencyPresentationPolicy.shouldExpire")
  abort "error: TV emergency monitor lost foreground-only, fallback, baseline, or expiry protection"
end

for forbidden in ["TVUserInitiatedAlertAudio", "AVAudioPlayer", "playUserInitiated", "AudioServicesPlay"]
  abort "error: warning ingestion must remain visual-only (found #{forbidden})" if monitor.include?(forbidden)
end

unless policy.include?("guard !(isBackfill && !hadLocalHistoryBeforeBatch)") &&
       policy.include?("if previous.isTerminal && !incoming.isTerminal { return false }") &&
       policy.include?("return isCurrentlyPresented ? .clearPresented : .baseline") &&
       policy.include?("age >= -allowedFutureSkew && age <= maximumWarningAge")
  abort "error: TV emergency policy lost baseline, terminal, lifecycle, or freshness protection"
end

unless preferences.include?("static func permitsAutomaticWarningPlayback") &&
       preferences.match?(/permitsAutomaticWarningPlayback.*?\{\s*false\s*\}/m) &&
       preferences.include?("preference.bundledFilename != nil")
  abort "error: TV audio policy must reject automatic and System playback"
end

unless audio.scan(/func playUserInitiated\(/).length == 1 &&
       audio.include?("AVAudioSession.sharedInstance()") &&
       audio.include?(".ambient") &&
       audio.include?(".mixWithOthers") &&
       audio.include?("private var playbackCompletionTask: Task<Void, Never>?") &&
       audio.include?("TVAlertAudioPolicy.playbackCompletionDelay") &&
       audio.include?("playbackCompletionTask?.cancel()") &&
       audio.include?("private func finishCompletedPlayback()") &&
       audio.scan(/setActive\(\s*false,\s*options: \.notifyOthersOnDeactivation\s*\)/m).length >= 2 &&
       audio.include?("func stop()")
  abort "error: TV audio player must expose one explicit, ambient, completion-bound, stoppable playback entry point"
end

unless settings.match?(/Button \{\s*playbackResult = playUserInitiated\(preferences\.alertSound\)/m) &&
       !settings.match?(/\.onChange.*?playUserInitiated/m) &&
       settings.include?("@FocusState private var focusedSoundValue") &&
       settings.include?("platform.tv.alertSound.system.visualOnly")
  abort "error: TV sound settings must keep preview explicit, focusable, and honest about System audio"
end

alert_task = alert[/\.task\(id: warning\.id\) \{.*?(?=\n        \.onExitCommand)/m]
unless alert.match?(/Button \{\s*playbackResult = playUserInitiated\(selectedSound\)/m) &&
       alert_task && !alert_task.include?("playUserInitiated") &&
       alert.include?(".accessibilityAddTraits(.isModal)") &&
       alert.include?(".focused($focusedAction, equals: .playSound)") &&
       alert.include?(".focused($focusedAction, equals: .dismiss)") &&
       alert.include?(".onExitCommand") &&
       alert.include?("alert.step.drop") &&
       alert.include?("alert.step.cover") &&
       alert.include?("alert.step.holdOn")
  abort "error: TV warning view must be visual-first, Remote-driven, focus-contained, and accessible"
end

puts "tvOS emergency and visual interface tests passed"
