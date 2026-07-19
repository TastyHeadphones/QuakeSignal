import SwiftUI
import CoreLocation

/// Full-screen, system-presented-over-anything alert. Layout adapts to the
/// event's ReportStatus (preliminary/final/cancelled/training) -- these are
/// visually distinct states in the source design, not just a badge swap.
struct EEWAlertView: View {
    let event: EEWEvent
    let reason: String
    let onDismiss: () -> Void

    @State private var store = QuakeStore.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Rectangle()
                    .fill(backgroundColor.gradient)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        header

                        if event.reportStatus == .preliminary, let coordinate = store.effectiveCoordinate {
                            CountdownView(event: event, coordinate: coordinate)
                        }

                        magnitudeBlock

                        locationBlock

                        if event.reportStatus == .preliminary || event.reportStatus == .training {
                            DropCoverHoldView()
                        }

                        if event.reportStatus == .final {
                            safetyChecklist
                        }

                        if event.reportStatus == .cancelled {
                            cancelledNote
                        }

                        if event.reportStatus == .training {
                            trainingNote
                        }

                        detailGrid

                        actionButtons

                        Text("shared.disclaimer")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.vertical, 24)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .sensoryFeedback(.warning, trigger: event.id)
    }

    private var backgroundColor: Color {
        switch event.reportStatus {
        case .preliminary: return event.severity.color
        case .final: return Color("BrandDeepColor")
        case .cancelled: return Color("GraphiteColor")
        case .training: return Color("TestColor")
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: headerSymbol)
                .font(.title)
            Text(headerTitleKey)
                .font(.title3.bold())
            Text(event.reportStatus.labelKey)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.2)))
        }
        .foregroundStyle(.white)
    }

    private var headerSymbol: String {
        switch event.reportStatus {
        case .preliminary: return "exclamationmark.triangle.fill"
        case .final: return "doc.text.fill"
        case .cancelled: return "xmark.circle.fill"
        case .training: return "flag.fill"
        }
    }

    private var headerTitleKey: LocalizedStringKey {
        switch event.reportStatus {
        case .preliminary: return badgeKeyForReason
        case .final: return "alert.header.final"
        case .cancelled: return "alert.header.cancelled"
        case .training: return "alert.header.training"
        }
    }

    private var badgeKeyForReason: LocalizedStringKey {
        switch reason {
        case "updated": return "alert.badge.updated"
        default: return "alert.badge.new"
        }
    }

    @ViewBuilder
    private var magnitudeBlock: some View {
        if event.reportStatus != .cancelled {
            VStack(spacing: 2) {
                Text(event.magnitudeText)
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("alert.magnitudeLabel")
                    .font(.caption)
            }
            .foregroundStyle(.white)
        }
    }

    private var locationBlock: some View {
        VStack(spacing: 6) {
            Text(event.hypocenter)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if let coordinate = store.effectiveCoordinate, let distance = event.distanceKm(from: coordinate) {
                Text(L("home.distance", Int(distance.rounded())))
                    .font(.subheadline)
            }
            Text(event.sourceLabelKey)
                .font(.subheadline)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 32)
    }

    private var detailGrid: some View {
        VStack(spacing: 8) {
            if let maxIntensity = event.maxIntensity {
                AlertFieldRow(labelKey: "alert.intensityLabel", value: maxIntensity)
            }
            if let depth = event.depth {
                AlertFieldRow(labelKey: "quake.depth.label.plain", value: String(format: "%.0f km", depth))
            }
            AlertFieldRow(labelKey: "detail.field.source", value: event.sourceLabelText)
            if let originDate = event.originDate {
                AlertFieldRow(labelKey: "home.field.originTime", value: originDate.formatted(date: .omitted, time: .standard))
            }
            if let reportDate = event.reportDate {
                AlertFieldRow(labelKey: "home.field.reportTime", value: reportDate.formatted(date: .omitted, time: .standard))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.12)))
        .padding(.horizontal, 24)
    }

    private var safetyChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("alert.checklist.title")
                .font(.headline)
            ForEach(["alert.checklist.item1", "alert.checklist.item2", "alert.checklist.item3"], id: \.self) { key in
                Label {
                    Text(LocalizedStringKey(key))
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .font(.subheadline)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.12)))
        .padding(.horizontal, 24)
    }

    private var cancelledNote: some View {
        Text("alert.cancelled.note")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.9))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }

    private var trainingNote: some View {
        Text("alert.training.note")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.18)))
            .padding(.horizontal, 24)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            NavigationLink {
                QuakeDetailView(event: event)
            } label: {
                Text("alert.viewDetails")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(backgroundColor)

            Button(action: onDismiss) {
                (event.reportStatus == .training ? Text("alert.endTest") : Text("alert.dismiss"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
    }
}

private struct AlertFieldRow: View {
    let labelKey: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(labelKey)
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Text(value)
                .foregroundStyle(.white)
        }
        .font(.subheadline)
    }
}

/// Live-updating "estimated shaking in N seconds" -- ticks every second
/// without a manually-managed Timer.
private struct CountdownView: View {
    let event: EEWEvent
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let seconds = event.secondsUntilShaking(at: coordinate, now: context.date) {
                VStack(spacing: 2) {
                    Text("\(seconds)")
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text("alert.countdown.label")
                        .font(.caption)
                }
                .foregroundStyle(.white)
            }
        }
    }
}

private struct DropCoverHoldView: View {
    private let steps: [(symbol: String, key: LocalizedStringKey)] = [
        ("arrow.down.to.line", "alert.step.drop"),
        ("shield.lefthalf.filled", "alert.step.cover"),
        ("hand.raised.fill", "alert.step.holdOn"),
    ]

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 24) {
                ForEach(steps.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Image(systemName: steps[index].symbol)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.white.opacity(0.18)))
                        Text(steps[index].key)
                            .font(.caption)
                    }
                }
            }
            VStack(spacing: 4) {
                Label("alert.warning.windows", systemImage: "exclamationmark.triangle")
                Label("alert.warning.elevator", systemImage: "xmark.octagon")
            }
            .font(.caption)
        }
        .foregroundStyle(.white)
    }
}
