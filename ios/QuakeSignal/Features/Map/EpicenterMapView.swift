import SwiftUI
import MapKit
import CoreLocation

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
    @State private var locationManager = LocationManager.shared
    @State private var selectedEvent: EEWEvent?
    @State private var detailEvent: EEWEvent?
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
                    if canShowUserLocation {
                        UserAnnotation()
                    }

                    ForEach(locatedEvents) { event in
                        if let coordinate = event.coordinate {
                            Annotation(event.hypocenter, coordinate: coordinate) {
                                MapEventMarker(
                                    event: event,
                                    size: markerSize(for: event),
                                    isSelected: selectedEvent?.id == event.id
                                ) {
                                    toggleSelection(of: event)
                                }
                            }
                        }
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                        .accessibilityIdentifier("map.currentLocationButton")
                    MapCompass()
                    MapScaleView()
                }
                .overlay {
                    if locatedEvents.isEmpty {
                        ContentUnavailableView("map.empty", systemImage: "map")
                            .allowsHitTesting(false)
                    }
                }

                VStack {
                    filterBar
                    Spacer()
                    if let selectedEvent {
                        SelectedEventCard(
                            event: selectedEvent,
                            onDismiss: { dismissSelection() },
                            onViewDetails: { detailEvent = selectedEvent }
                        )
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.snappy, value: selectedEvent?.id)
            .navigationTitle("map.title")
            .navigationDestination(item: $detailEvent) { event in
                QuakeDetailView(event: event)
            }
            .onChange(of: visibleEventIDs) { _, visibleEventIDs in
                guard let selectedEvent, !visibleEventIDs.contains(selectedEvent.id) else { return }
                dismissSelection()
            }
        }
    }

    private var canShowUserLocation: Bool {
        locationManager.authorizationStatus.allowsQuakeSignalLocation
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

    private var visibleEventIDs: Set<EEWEvent.ID> {
        Set(locatedEvents.lazy.map(\.id))
    }

    private func toggleSelection(of event: EEWEvent) {
        if selectedEvent?.id == event.id {
            dismissSelection()
        } else {
            selectedEvent = event
        }
    }

    private func dismissSelection() {
        selectedEvent = nil
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            chipFilters
                .fixedSize(horizontal: true, vertical: false)
            compactFilterMenus
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var chipFilters: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(TimeWindow.allCases, id: \.self) { window in
                    MapFilterChip(
                        labelKey: window.labelKey,
                        accessibilityLabelKey: "map.filter.timeWindow",
                        isSelected: timeWindow == window
                    ) {
                        timeWindow = window
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(magnitudeTiers, id: \.self) { tier in
                    MapFilterChip(
                        labelKey: magnitudeLabel(for: tier),
                        accessibilityLabelKey: "map.filter.minimumMagnitude",
                        isSelected: minMagnitude == tier
                    ) {
                        minMagnitude = tier
                    }
                }
            }
        }
    }

    private var compactFilterMenus: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(TimeWindow.allCases, id: \.self) { window in
                    Button {
                        timeWindow = window
                    } label: {
                        Label {
                            Text(window.labelKey)
                        } icon: {
                            if timeWindow == window {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(timeWindow.labelKey, systemImage: "calendar")
                    .lineLimit(1)
            }
            .accessibilityLabel(Text("map.filter.timeWindow"))
            .accessibilityValue(Text(timeWindow.labelKey))

            Menu {
                ForEach(magnitudeTiers, id: \.self) { tier in
                    Button {
                        minMagnitude = tier
                    } label: {
                        Label {
                            Text(magnitudeLabel(for: tier))
                        } icon: {
                            if minMagnitude == tier {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(magnitudeLabel(for: minMagnitude), systemImage: "waveform.path.ecg")
                    .lineLimit(1)
            }
            .accessibilityLabel(Text("map.filter.minimumMagnitude"))
            .accessibilityValue(Text(magnitudeLabel(for: minMagnitude)))
        }
        .buttonStyle(.bordered)
        .tint(Color("BrandColor"))
    }

    private func magnitudeLabel(for tier: Double) -> LocalizedStringKey {
        tier == 0 ? "list.region.all" : LocalizedStringKey("M\(Int(tier))+")
    }
}

private struct MapEventMarker: View {
    let event: EEWEvent
    let size: CGFloat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(event.severity.color)
                    .frame(width: size, height: size)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))

                if isSelected {
                    Circle()
                        .stroke(Color("BrandColor"), lineWidth: 3)
                        .frame(width: min(44, size + 7), height: min(44, size + 7))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .accessibilityLabel(Text(event.hypocenter))
        .accessibilityValue(Text("\(String(localized: "alert.magnitudeLabel")) \(event.magnitudeText)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MapFilterChip: View {
    let labelKey: LocalizedStringKey
    let accessibilityLabelKey: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(labelKey)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(minHeight: 44)
                .background(Capsule().fill(isSelected ? Color("BrandColor") : Color("CardColor")))
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel(Text(accessibilityLabelKey))
        .accessibilityValue(Text(labelKey))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SelectedEventCard: View {
    let event: EEWEvent
    let onDismiss: () -> Void
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

                Button(action: onDismiss) {
                    Label("alert.dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.caption.bold())
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color("CardSecondaryColor")))
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
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
