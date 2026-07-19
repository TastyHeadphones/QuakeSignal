import SwiftUI
import MapKit

private enum TimeWindow: CaseIterable {
    case day, week, month

    var labelKey: LocalizedStringKey {
        switch self {
        case .day: return "map.window.day"
        case .week: return "map.window.week"
        case .month: return "map.window.month"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }
}

struct EpicenterMapView: View {
    @State private var store = QuakeStore.shared
    @State private var selectedEvent: EEWEvent?
    @State private var showingDetail = false
    @State private var timeWindow: TimeWindow = .week
    @State private var minMagnitude: Double = 0
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 30, longitude: 125),
            span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
        )
    )

    private let magnitudeTiers: [Double] = [0, 3, 4, 5]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $cameraPosition) {
                    ForEach(locatedEvents) { event in
                        Annotation(event.hypocenter, coordinate: event.coordinate!) {
                            Circle()
                                .fill(event.severity.color)
                                .frame(width: markerSize(for: event), height: markerSize(for: event))
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                .onTapGesture { selectedEvent = event }
                        }
                    }
                }
                .overlay {
                    if locatedEvents.isEmpty {
                        ContentUnavailableView("map.empty", systemImage: "map")
                    }
                }

                VStack {
                    filterBar
                    Spacer()
                    if let selectedEvent {
                        SelectedEventCard(event: selectedEvent, onViewDetails: { showingDetail = true })
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    }
                }
            }
            .navigationTitle("map.title")
            .navigationDestination(isPresented: $showingDetail) {
                if let selectedEvent { QuakeDetailView(event: selectedEvent) }
            }
        }
    }

    private var locatedEvents: [EEWEvent] {
        let cutoff = Date().addingTimeInterval(-timeWindow.interval)
        return store.events.filter { event in
            guard event.coordinate != nil else { return false }
            guard (event.magnitude ?? 0) >= minMagnitude else { return false }
            guard let reportDate = event.reportDate else { return true }
            return reportDate >= cutoff
        }
    }

    private func markerSize(for event: EEWEvent) -> CGFloat {
        guard let magnitude = event.magnitude else { return 14 }
        return max(12, min(40, magnitude * 5))
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(TimeWindow.allCases, id: \.self) { window in
                    MapFilterChip(labelKey: window.labelKey, isSelected: timeWindow == window) {
                        timeWindow = window
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(magnitudeTiers, id: \.self) { tier in
                    MapFilterChip(labelKey: tier == 0 ? "list.region.all" : LocalizedStringKey("M\(Int(tier))+"), isSelected: minMagnitude == tier) {
                        minMagnitude = tier
                    }
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

private struct MapFilterChip: View {
    let labelKey: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(labelKey)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(isSelected ? Color("BrandColor") : Color("CardColor")))
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

private struct SelectedEventCard: View {
    let event: EEWEvent
    let onViewDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.hypocenter).font(.headline)
                    Text("\(event.magnitudeText) M · \(event.reportDate?.formatted(date: .omitted, time: .shortened) ?? "--")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(event.reportStatus.labelKey)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(event.reportStatus.color))
            }

            HStack(spacing: 12) {
                Button(action: onViewDetails) {
                    Text("alert.viewDetails").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandColor"))

                ShareLink(item: shareText) {
                    Label("map.share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color("CardColor")))
        .shadow(radius: 8, y: 2)
    }

    private var shareText: String {
        "\(event.hypocenter) M\(event.magnitudeText)"
    }
}
