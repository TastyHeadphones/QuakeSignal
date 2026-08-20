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
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(event.reportStatus.labelKey)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(event.reportStatus.color))
                if let coordinate, let distance = event.distanceKm(from: coordinate) {
                    Text(L("home.distance", Int(distance.rounded())))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MagnitudeBadge: View {
    let event: EEWEvent

    var body: some View {
        Text(event.magnitudeText)
            .font(.headline.monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(Circle().fill(event.severity.color.opacity(event.isCancel ? 0.35 : 0.9)))
    }
}
