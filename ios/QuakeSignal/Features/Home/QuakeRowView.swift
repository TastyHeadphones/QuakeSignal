import SwiftUI
import CoreLocation

struct QuakeRowView: View {
    let event: EEWEvent
    var coordinate: CLLocationCoordinate2D?

    var body: some View {
        HStack(spacing: 12) {
            MagnitudeBadge(event: event)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.hypocenter)
                    .font(.headline)
                    .visionFont(.title3.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(event.reportDate?.formatted(date: .numeric, time: .shortened) ?? "--")
                    Text("·")
                    Text(event.sourceLabelKey)
                    if let maxIntensity = event.maxIntensity {
                        Text("·")
                        Text(L("quake.intensity.label", maxIntensity))
                    }
                }
                .font(.caption)
                .visionFont(.subheadline)
                .visionSupportingText()
                .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(event.reportStatus.labelKey)
                    .font(.caption2.bold())
                    .visionFont(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(event.reportStatus.color))
                if let coordinate, let distance = event.distanceKm(from: coordinate) {
                    Text(L("home.distance", Int(distance.rounded())))
                        .font(.caption2)
                        .visionFont(.caption)
                        .visionSupportingText()
                }
            }
        }
        .padding(.vertical, rowVerticalPadding)
    }

    private var rowVerticalPadding: CGFloat {
#if os(visionOS)
        12
#else
        4
#endif
    }
}

private struct MagnitudeBadge: View {
    let event: EEWEvent

    var body: some View {
        Text(event.magnitudeText)
            .font(.headline.monospacedDigit())
            .visionFont(.title3.bold().monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: badgeDiameter, height: badgeDiameter)
            .background(Circle().fill(event.severity.color.opacity(event.isCancel ? 0.35 : 0.9)))
    }

    private var badgeDiameter: CGFloat {
#if os(visionOS)
        68
#else
        52
#endif
    }
}
