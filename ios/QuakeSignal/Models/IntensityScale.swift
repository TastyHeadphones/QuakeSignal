import SwiftUI
import UIKit

/// Magnitude-tier color used for badges and map pins, matching the source
/// design's exact bands: <4 brand blue, 4-4.9 amber, 5-5.9 orange, >=6 red.
/// `cancelled` is a separate, orthogonal gray treatment, not a magnitude tier.
enum Severity: Comparable {
    case minor
    case moderate
    case strong
    case severe
    case cancelled

    static func from(magnitude: Double?, isCancel: Bool) -> Severity {
        if isCancel { return .cancelled }
        guard let magnitude else { return .minor }
        switch magnitude {
        case ..<4.0: return .minor
        case 4.0..<5.0: return .moderate
        case 5.0..<6.0: return .strong
        default: return .severe
        }
    }

    var color: Color {
        switch self {
        case .cancelled: return Color("GrayColor")
        case .minor: return Color("BrandColor")
        case .moderate: return Color("CautionColor")
        case .strong: return Color("StrongColor")
        case .severe: return Color("SevereColor")
        }
    }
}

/// Three-state overall system status shown on the Home banner -- distinct
/// from `Severity`: this is "is there anything to worry about right now
/// near you", not a per-event magnitude tier.
enum HomeBannerState {
    case normal
    case caution
    case alert

    var color: Color {
        switch self {
        case .normal: return Color("NormalColor")
        case .caution: return Color("CautionColor")
        case .alert: return Color("SevereColor")
        }
    }
}

/// The report-status badge shown on event rows/detail/alert screens.
enum ReportStatus {
    case preliminary
    case final
    case cancelled
    case training

    static func from(isFinal: Bool, isCancel: Bool, isTraining: Bool) -> ReportStatus {
        if isTraining { return .training }
        if isCancel { return .cancelled }
        if isFinal { return .final }
        return .preliminary
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .preliminary: return "status.preliminary"
        case .final: return "status.final"
        case .cancelled: return "status.cancelled"
        case .training: return "status.training"
        }
    }

    var color: Color {
        switch self {
        case .preliminary: return Color("BrandColor")
        case .final: return Color("NormalColor")
        case .cancelled: return Color("GrayColor")
        case .training: return Color("TestColor")
        }
    }
}

/// OpenDesign native-UI tab destinations. The HTML prototype is React; the
/// shipping client is SwiftUI. These values are the iPhone/iPad product map.
enum NativeUITab: String, CaseIterable, Identifiable, Hashable {
    case home
    case reports
    case map
    case guide
    case settings

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .home: return "tab.home"
        case .reports: return "tab.list"
        case .map: return "tab.map"
        case .guide: return "tab.guide"
        case .settings: return "tab.settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "waveform.path.ecg"
        case .reports: return "list.bullet"
        case .map: return "map"
        case .guide: return "cross.case"
        case .settings: return "gearshape"
        }
    }

    var destinations: [NativeUIDestination] {
        switch self {
        case .home: return [.home, .statusHero, .latestEventCard, .cityPicker]
        case .reports: return [.reports, .reportsFilters]
        case .map: return [.map]
        case .guide: return [.guide, .guideTopic, .familyCheckIn]
        case .settings: return [.settings, .alertSources, .notifications, .alertSound, .sourcesDisclaimer]
        }
    }
}

enum NativeUIDestination: String, CaseIterable, Equatable {
    case home
    case reports
    case map
    case guide
    case settings
    case onboarding
    case cityPicker
    case reportsFilters
    case guideTopic
    case familyCheckIn
    case alertSources
    case notifications
    case alertSound
    case sourcesDisclaimer
    case eewOverlay
    case statusHero
    case latestEventCard
    case revisionTimeline
}

enum NativeUINavigation {
    static let rootTabs: [NativeUITab] = NativeUITab.allCases
    static let overlayDestinations: [NativeUIDestination] = [.onboarding, .eewOverlay]
    static let eventDetailDestinations: [NativeUIDestination] = [.revisionTimeline]
}

enum NativeUIQuickAction: String, CaseIterable, Equatable {
    case nearby
    case notify
    case map

    var titleKey: String {
        switch self {
        case .nearby: return "home.action.nearby"
        case .notify: return "home.action.notify"
        case .map: return "tab.map"
        }
    }

    var systemImage: String {
        switch self {
        case .nearby: return "location.circle"
        case .notify: return "bell"
        case .map: return "map"
        }
    }

    var destination: NativeUIDestination {
        switch self {
        case .nearby: return .cityPicker
        case .notify: return .notifications
        case .map: return .map
        }
    }
}

/// APNs / App Attest relay registration exists only on iPhone and iPad.
/// Mac Catalyst, Watch, and visionOS stay on foreground or local alerts.
enum NativeUIRelaySurface: String, CaseIterable, Equatable {
    case iPhone
    case iPad
    case macCatalyst
    case watch
    case vision
    case other

    var registersForNotificationRelay: Bool {
        switch self {
        case .iPhone, .iPad: return true
        case .macCatalyst, .watch, .vision, .other: return false
        }
    }

    var notificationsTitleKey: String {
        registersForNotificationRelay ? "settings.section.notifications" : "settings.foregroundAlerts"
    }

    static func resolve(
        userInterfaceIdiom: UIUserInterfaceIdiom,
        isMacCatalyst: Bool
    ) -> NativeUIRelaySurface {
        if isMacCatalyst { return .macCatalyst }
        switch userInterfaceIdiom {
        case .phone: return .iPhone
        case .pad: return .iPad
        case .mac: return .macCatalyst
        case .vision: return .vision
        case .tv, .carPlay, .unspecified: return .other
        @unknown default: return .other
        }
    }

    static func current() -> NativeUIRelaySurface {
        #if os(watchOS)
        return .watch
        #elseif os(visionOS)
        return .vision
        #else
        var isMacCatalyst = false
        #if targetEnvironment(macCatalyst)
        isMacCatalyst = true
        #endif
        return resolve(
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom,
            isMacCatalyst: isMacCatalyst
        )
        #endif
    }
}

enum NativeStatusHeroMapping {
    static func bannerState(
        hasActiveWarning: Bool,
        hasRecentNearbyReport: Bool
    ) -> HomeBannerState {
        if hasActiveWarning { return .alert }
        if hasRecentNearbyReport { return .caution }
        return .normal
    }

    static func titleKey(for state: HomeBannerState) -> String {
        switch state {
        case .normal: return "home.status.normal"
        case .caution: return "home.status.caution"
        case .alert: return "home.status.alert"
        }
    }

    static func detailKey(for state: HomeBannerState) -> String {
        switch state {
        case .normal: return "home.status.normal.detail"
        case .caution: return "home.status.caution.detail"
        case .alert: return "home.status.alert.detail"
        }
    }

    static func systemImage(for state: HomeBannerState) -> String {
        switch state {
        case .normal: return "checkmark.circle.fill"
        case .caution: return "exclamationmark.circle.fill"
        case .alert: return "exclamationmark.triangle.fill"
        }
    }
}

private struct NativeUITabSelectionKey: EnvironmentKey {
    static var defaultValue: Binding<NativeUITab>? { nil }
}

extension EnvironmentValues {
    var nativeUITabSelection: Binding<NativeUITab>? {
        get { self[NativeUITabSelectionKey.self] }
        set { self[NativeUITabSelectionKey.self] = newValue }
    }
}

enum NativeGlass {
    static let cardRadius: CGFloat = 22
    static let groupedRadius: CGFloat = 16
    static let heroRadius: CGFloat = 28
}

struct NativeGlassCard: ViewModifier {
    var cornerRadius: CGFloat = NativeGlass.cardRadius

    func body(content: Content) -> some View {
        content
            .background {
                glassShape
            }
    }

    private var glassShape: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            Color.primary.opacity(0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: Color.black.opacity(0.10), radius: 14, y: 8)
    }
}

extension View {
    func nativeGlassCard(cornerRadius: CGFloat = NativeGlass.cardRadius) -> some View {
        modifier(NativeGlassCard(cornerRadius: cornerRadius))
    }

    func nativeGroupedChrome() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color("GroupedBGColor"))
    }
}

struct NativeFilterChip: View {
    let labelKey: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(labelKey)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(isSelected ? Color.primary : Color.primary.opacity(0.07)))
                .foregroundStyle(isSelected ? Color("GroupedBGColor") : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
