import SwiftUI
import CoreLocation

struct HomeView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var store = QuakeStore.shared
    @State private var settings = AppSettings.shared
    @State private var locationManager = LocationManager.shared
    @State private var showingCityPicker = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 16) {
                        if let loadError = store.loadError {
                            InlineBanner(symbol: "wifi.slash", titleKey: "home.banner.offline", detail: loadError, actionKey: "home.banner.retry") {
                                Task { await store.refresh() }
                            }
                        }

                        if settings.useCurrentLocation && locationManager.selectionStatus == .denied {
                            InlineBanner(symbol: "location.slash", titleKey: "home.banner.locationOff", detail: locationManager.selectionStatus.localizedDetail(fallbackCityName: settings.selectedCity?.localizedName), actionKey: "settings.openSystemSettings") {
                                showingCityPicker = true
                            }
                        }

                        if let statusEvent = store.activeWarning ?? store.recentNearbyReport {
                            NavigationLink(value: statusEvent) {
                                statusCard
                            }
                            .buttonStyle(.plain)
                        } else {
                            statusCard
                        }

                        if let highlighted = store.activeWarning ?? store.recentNearbyReport ?? store.latestNearbyReport {
                            LatestQuakeCardView(
                                event: highlighted,
                                coordinate: store.effectiveCoordinate,
                                isNearby: store.effectiveCoordinate != nil
                            )
                        } else if !store.isLoading {
                            ContentUnavailableView("home.empty.title", systemImage: "checkmark.seal", description: Text("home.empty.body"))
                                .padding(.top, 40)
                        }

                        if horizontalSizeClass == .regular {
                            Spacer(minLength: 16)
                        }

                        QuickActionsRow(showingCityPicker: $showingCityPicker)

                        Text("shared.disclaimer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.top, 4)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: horizontalSizeClass == .regular ? geometry.size.height : nil,
                        alignment: .top
                    )
                    .padding(.vertical, 12)
                }
            }
            .background(Color("GroupedBGColor"))
            .navigationTitle(cityTitle)
            .navigationDestination(for: EEWEvent.self) { event in
                QuakeDetailView(event: event)
            }
            .refreshable { await store.refresh() }
            .overlay {
                if store.isLoading && store.events.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("home.loading")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(isPresented: $showingCityPicker) {
                CityPickerView()
            }
        }
    }

    private var cityTitle: String {
        if settings.useCurrentLocation,
           locationManager.selectionStatus == .current {
            return String(localized: "city.currentLocation")
        }
        if let city = settings.selectedCity {
            return city.localizedName
        }
        if settings.useCurrentLocation {
            return String(localized: "city.currentLocation")
        }
        return String(localized: "app.name")
    }

    private var statusCard: some View {
        StatusCardView(
            bannerState: store.bannerState,
            activeWarning: store.activeWarning,
            recentReport: store.recentNearbyReport,
            radiusKm: settings.radiusKm,
            coordinate: store.effectiveCoordinate
        )
    }
}

private struct StatusCardView: View {
    let bannerState: HomeBannerState
    let activeWarning: EEWEvent?
    let recentReport: EEWEvent?
    let radiusKm: Double
    let coordinate: CLLocationCoordinate2D?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .foregroundStyle(coordinate == nil ? .orange : bannerState.color)
                Text(titleKey)
                    .font(.headline)
                Spacer()
            }
            Text(detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color("CardColor")))
        .padding(.horizontal)
    }

    private var symbolName: String {
        if coordinate == nil { return "location.slash.fill" }
        switch bannerState {
        case .normal: return "checkmark.circle.fill"
        case .caution: return "exclamationmark.circle.fill"
        case .alert: return "exclamationmark.triangle.fill"
        }
    }

    private var titleKey: LocalizedStringKey {
        if coordinate == nil { return "home.status.locationRequired" }
        switch bannerState {
        case .normal: return "home.status.normal"
        case .caution: return "home.status.caution"
        case .alert: return "home.status.alert"
        }
    }

    private var detailText: String {
        guard coordinate != nil else {
            return String(localized: "home.status.locationRequired.detail")
        }
        switch bannerState {
        case .normal:
            return L("home.status.normal.detail", Int(radiusKm))
        case .caution:
            guard let recentReport else {
                return ""
            }
            guard let coordinate, let distance = recentReport.distanceKm(from: coordinate) else {
                return L("home.status.caution.detail.noDistance", recentReport.magnitudeText)
            }
            return L("home.status.caution.detail", Int(distance.rounded()), recentReport.magnitudeText)
        case .alert:
            guard let activeWarning else { return "" }
            return L("home.status.alert.detail", activeWarning.magnitudeText)
        }
    }
}

private struct LatestQuakeCardView: View {
    let event: EEWEvent
    let coordinate: CLLocationCoordinate2D?
    let isNearby: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNearby ? "home.section.latestNearby" : "home.section.latest")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(alignment: .top, spacing: 4) {
                Text(event.sourceLabelKey)
                Text("·")
                Text(event.reportStatus.labelKey)
                    .foregroundStyle(event.reportStatus.color)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 2) {
                    Text(event.magnitudeText)
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(event.severity.color)
                        .monospacedDigit()
                    Text("alert.magnitudeLabel")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(event.hypocenter)
                        .font(.headline)
                    if let coordinate, let distance = event.distanceKm(from: coordinate) {
                        HStack(spacing: 4) {
                            Text(L("home.distance", Int(distance.rounded())))
                            if let direction = event.compassDirection(from: coordinate) {
                                Text(direction.labelKey)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Divider()

            VStack(spacing: 8) {
                DetailFieldRow(labelKey: "home.field.originTime", value: event.originDate?.formatted(date: .abbreviated, time: .shortened) ?? "--")
                DetailFieldRow(labelKey: "home.field.reportTime", value: event.reportDate?.formatted(date: .abbreviated, time: .shortened) ?? "--")
                if let maxIntensity = event.maxIntensity {
                    DetailFieldRow(labelKey: "alert.intensityLabel", value: maxIntensity)
                }
                if let depth = event.depth {
                    DetailFieldRow(labelKey: "quake.depth.label.plain", value: String(format: "%.0f km", depth))
                }
            }

            NavigationLink(value: event) {
                Text("alert.viewDetails")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("BrandColor"))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color("CardColor")))
        .padding(.horizontal)
    }
}

private struct DetailFieldRow: View {
    let labelKey: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(labelKey)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}

private struct QuickActionsRow: View {
    @Binding var showingCityPicker: Bool

    var body: some View {
        HStack(spacing: 12) {
            QuickActionButton(labelKey: "home.action.nearby", systemImage: "location.circle") {
                showingCityPicker = true
            }
            NavigationLink {
                EpicenterMapView()
            } label: {
                QuickActionButtonLabel(labelKey: "tab.map", systemImage: "map")
            }
            .buttonStyle(.plain)
            NavigationLink {
                DisasterGuideView()
            } label: {
                QuickActionButtonLabel(labelKey: "tab.guide", systemImage: "cross.case")
            }
            .buttonStyle(.plain)
            NavigationLink {
                SettingsView()
            } label: {
                QuickActionButtonLabel(labelKey: "home.action.notify", systemImage: "bell")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }
}

private struct QuickActionButton: View {
    let labelKey: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            QuickActionButtonLabel(labelKey: labelKey, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

private struct QuickActionButtonLabel: View {
    let labelKey: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
            Text(labelKey)
                .font(.caption2)
        }
        .foregroundStyle(Color("BrandColor"))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color("CardColor")))
    }
}

private struct InlineBanner: View {
    let symbol: String
    let titleKey: LocalizedStringKey
    let detail: String
    let actionKey: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color("CautionColor"))
            VStack(alignment: .leading, spacing: 4) {
                Text(titleKey).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Button(action: action) {
                    Text(actionKey).font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color("BrandColor"))
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color("CardColor")))
        .padding(.horizontal)
    }
}
