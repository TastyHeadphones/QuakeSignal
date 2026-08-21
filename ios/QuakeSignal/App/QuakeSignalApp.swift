import SwiftUI

/// Shared, testable guardrails for the visionOS reading surface. The colors
/// remain semantic and adaptive; these values only reduce the room bleed that
/// can otherwise wash out text on a bright passthrough background.
enum VisionReadabilityMetrics {
    static let defaultWindowWidth: CGFloat = 1_600
    static let defaultWindowHeight: CGFloat = 800
    static let surfaceOpacity = 0.97
    static let rowSurfaceOpacity = 0.98
    static let supportingTextOpacity = 0.82
    static let reportMinimumRowHeight: CGFloat = 128
    static let guideMinimumRowHeight: CGFloat = 84
    static let alertSoundMinimumRowHeight: CGFloat = 112
}

extension View {
    @ViewBuilder
    func visionReadableListSurface(minimumRowHeight: CGFloat) -> some View {
#if os(visionOS)
        scrollContentBackground(.hidden)
            .background(
                Color("GroupedBGColor")
                    .opacity(VisionReadabilityMetrics.surfaceOpacity)
            )
            .environment(\.defaultMinListRowHeight, minimumRowHeight)
#else
        self
#endif
    }

    @ViewBuilder
    func visionReadableRow(minimumHeight: CGFloat? = nil) -> some View {
#if os(visionOS)
        frame(minHeight: minimumHeight)
            .listRowBackground(
                Color("CardColor")
                    .opacity(VisionReadabilityMetrics.rowSurfaceOpacity)
            )
#else
        self
#endif
    }

    @ViewBuilder
    func visionSupportingText() -> some View {
#if os(visionOS)
        foregroundStyle(
            Color.primary.opacity(VisionReadabilityMetrics.supportingTextOpacity)
        )
#else
        foregroundStyle(.secondary)
#endif
    }

    @ViewBuilder
    func visionFont(_ font: Font) -> some View {
#if os(visionOS)
        self.font(font)
#else
        self
#endif
    }
}

@main
struct QuakeSignalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
#if os(visionOS)
        .defaultSize(
            width: VisionReadabilityMetrics.defaultWindowWidth,
            height: VisionReadabilityMetrics.defaultWindowHeight
        )
#endif
    }
}
