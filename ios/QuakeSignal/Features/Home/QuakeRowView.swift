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
                    Text(event.reportDate?.formatted(date: .omitted, time: .shortened) ?? "--")
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
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(event.reportStatus.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(event.reportStatus.color.opacity(0.14)))
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
            .font(.title3.weight(.bold).monospacedDigit())
            .foregroundStyle(event.severity.color.opacity(event.isCancel ? 0.45 : 1))
            .frame(width: 52, height: 52)
    }
}
