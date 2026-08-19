import SwiftUI
import MapKit

struct QuakeDetailView: View {
    let event: EEWEvent

    @State private var store = QuakeStore.shared

    var body: some View {
        List {
            Section("detail.section.overview") {
                LabeledContent("quake.hypocenter.label", value: event.hypocenter)
                LabeledContent("detail.field.source") { Text(event.sourceLabelKey) }
                LabeledContent("alert.magnitudeLabel", value: event.magnitudeText)
                if let maxIntensity = event.maxIntensity {
                    LabeledContent("alert.intensityLabel", value: maxIntensity)
                }
                if let depth = event.depth {
                    LabeledContent("quake.depth.label.plain", value: String(format: "%.0f km", depth))
                }
                LabeledContent("detail.field.status") { Text(event.reportStatus.labelKey).foregroundStyle(event.reportStatus.color) }
                LabeledContent("detail.field.reportNumber", value: String(event.serial))
                LabeledContent("detail.field.eventId", value: event.eventId)
                if let coordinate = event.coordinate {
                    LabeledContent(
                        "detail.field.coordinates",
                        value: String(format: "%.1f, %.1f", coordinate.latitude, coordinate.longitude)
                    )
                }
                if let originDate = event.originDate {
                    LabeledContent("home.field.originTime", value: originDate.formatted(date: .abbreviated, time: .standard))
                }
                if let reportDate = event.reportDate {
                    LabeledContent("home.field.reportTime", value: reportDate.formatted(date: .abbreviated, time: .standard))
                }
                if let tsunami = event.tsunami, !tsunami.isEmpty {
                    LabeledContent("detail.tsunami", value: tsunami)
                }
            }

            if revisions.count > 1 {
                Section("detail.section.timeline") {
                    ForEach(timelineEntries, id: \.revision.id) { entry in
                        TimelineRow(revision: entry.revision, labelKey: entry.labelKey)
                    }
                }
            }

            if let coordinate = event.coordinate {
                Section("detail.section.location") {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)
                    ))) {
                        Marker(event.hypocenter, coordinate: coordinate)
                            .tint(event.severity.color)
                    }
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .navigationTitle("detail.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var revisions: [EventRevision] {
        store.revisions(for: event.id)
    }

    private var timelineEntries: [(revision: EventRevision, labelKey: LocalizedStringKey)] {
        var entries: [(EventRevision, LocalizedStringKey)] = []
        for (index, revision) in revisions.enumerated() {
            let previous = index > 0 ? revisions[index - 1] : nil
            if revision.isCancel {
                entries.append((revision, "detail.timeline.cancelled"))
            } else if revision.isFinal && !(previous?.isFinal ?? false) {
                entries.append((revision, "detail.timeline.final"))
            } else if previous == nil {
                entries.append((revision, "detail.timeline.first"))
            } else {
                entries.append((revision, "detail.timeline.updated"))
            }
        }
        return entries.reversed()
    }
}

private struct TimelineRow: View {
    let revision: EventRevision
    let labelKey: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(labelKey)
                if let magnitude = revision.magnitude {
                    Text(String(format: "· M%.1f", magnitude))
                }
            }
            .font(.subheadline.weight(.medium))

            Text(L("detail.timeline.meta", revision.reportDate?.formatted(date: .omitted, time: .standard) ?? "--", revision.serial))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
