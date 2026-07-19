import SwiftUI

private enum RegionFilter: CaseIterable {
    case all, cenc, sichuan, fujian, chongqing, japan

    var labelKey: LocalizedStringKey {
        switch self {
        case .all: return "list.region.all"
        case .cenc: return "quake.source.cenc"
        case .sichuan: return "quake.source.sc"
        case .fujian: return "quake.source.fj"
        case .chongqing: return "quake.source.cq"
        case .japan: return "quake.source.jma"
        }
    }

    func matches(_ event: EEWEvent) -> Bool {
        switch self {
        case .all: return true
        case .cenc: return event.sourceId == "cenc_eew" || event.sourceId == "cenc_eqlist"
        case .sichuan: return event.sourceId == "sc_eew"
        case .fujian: return event.sourceId == "fj_eew"
        case .chongqing: return event.sourceId == "cq_eew"
        case .japan: return event.sourceId == "jma_eew" || event.sourceId == "jma_eqlist"
        }
    }
}

struct QuakeListView: View {
    @State private var store = QuakeStore.shared
    @State private var region: RegionFilter = .all
    @State private var minMagnitude: Double = 0

    private let magnitudeTiers: [Double] = [0, 3, 4, 5, 6]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar

                List {
                    ForEach(filteredEvents) { event in
                        NavigationLink(value: event) {
                            QuakeRowView(event: event, coordinate: store.effectiveCoordinate)
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if filteredEvents.isEmpty {
                        ContentUnavailableView {
                            Label("list.empty.title", systemImage: "list.bullet")
                        } description: {
                            Text("list.empty.detail")
                        } actions: {
                            Button("list.empty.adjustFilters") {
                                region = .all
                                minMagnitude = 0
                            }
                        }
                    }
                }
            }
            .navigationTitle("map.title.list")
            .navigationDestination(for: EEWEvent.self) { event in
                QuakeDetailView(event: event)
            }
            .refreshable { await store.refresh() }
        }
    }

    private var filteredEvents: [EEWEvent] {
        store.events.filter { region.matches($0) && ($0.magnitude ?? 0) >= minMagnitude }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RegionFilter.allCases, id: \.self) { option in
                        FilterChip(labelKey: option.labelKey, isSelected: region == option) {
                            region = option
                        }
                    }
                }
                .padding(.horizontal)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(magnitudeTiers, id: \.self) { tier in
                        FilterChip(labelKey: tier == 0 ? "list.region.all" : LocalizedStringKey("M\(Int(tier))+"), isSelected: minMagnitude == tier) {
                            minMagnitude = tier
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 10)
        .background(Color("GroupedBGColor"))
    }
}

private struct FilterChip: View {
    let labelKey: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(labelKey)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(isSelected ? Color("BrandColor") : Color("CardColor")))
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
