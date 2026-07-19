import SwiftUI

struct CityPickerView: View {
    @State private var settings = AppSettings.shared
    @State private var locationManager = LocationManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            List {
                Section {
                    Button {
                        settings.useCurrentLocation = true
                        settings.selectedCityId = nil
                        locationManager.requestAuthorization()
                        locationManager.requestLocationUpdate()
                        dismiss()
                    } label: {
                        HStack {
                            Label("city.useCurrentLocation", systemImage: "location.fill")
                            Spacer()
                            if settings.useCurrentLocation {
                                Image(systemName: "checkmark").foregroundStyle(Color("BrandColor"))
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section("city.section.radius") {
                    HStack(spacing: 8) {
                        ForEach(AppSettings.radiusTiersKm, id: \.self) { tier in
                            RadiusChip(km: tier, isSelected: settings.radiusKm == tier) {
                                settings.radiusKm = tier
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                }

                Section("city.section.pick") {
                    ForEach(filteredCities) { city in
                        Button {
                            settings.selectedCityId = city.id
                            settings.useCurrentLocation = false
                            dismiss()
                        } label: {
                            HStack {
                                Text(city.localizedName)
                                Spacer()
                                if !settings.useCurrentLocation && settings.selectedCityId == city.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color("BrandColor"))
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .searchable(text: $searchText)
            .navigationTitle("city.pickerTitle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "alert.dismiss")) { dismiss() }
                }
            }
        }
    }

    private var filteredCities: [City] {
        guard !searchText.isEmpty else { return CityDirectory.all }
        return CityDirectory.all.filter {
            $0.localizedName.localizedCaseInsensitiveContains(searchText) || $0.nameEn.localizedCaseInsensitiveContains(searchText)
        }
    }
}

private struct RadiusChip: View {
    let km: Double
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(Int(km)) km")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? Color("BrandColor") : Color("GroupedBGColor")))
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
