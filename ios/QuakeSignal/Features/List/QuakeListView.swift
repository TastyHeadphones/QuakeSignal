import SwiftUI

struct QuakeListView: View {
    @State private var store = QuakeStore.shared
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
                        .visionReadableRow()
                    }
                }
                .listStyle(.plain)
                .visionReadableListSurface(
                    minimumRowHeight: VisionReadabilityMetrics.reportMinimumRowHeight
                )
                .overlay {
                    if filteredEvents.isEmpty {
                        ContentUnavailableView {
                            Label("list.empty.title", systemImage: "list.bullet")
                        } description: {
                            Text("list.empty.detail")
                        } actions: {
                            Button("list.empty.adjustFilters") {
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
        store.events.filter { ($0.magnitude ?? 0) >= minMagnitude }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        .padding(.vertical, filterBarVerticalPadding)
        .background(Color("GroupedBGColor"))
    }

    private var filterBarVerticalPadding: CGFloat {
#if os(visionOS)
        14
#else
        10
#endif
    }
}

private struct FilterChip: View {
    let labelKey: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
                Text(labelKey)
            }
            .font(.subheadline.weight(.medium))
            .visionFont(.body.weight(.semibold))
            .padding(.horizontal, chipHorizontalPadding)
            .padding(.vertical, chipVerticalPadding)
            .frame(minWidth: minimumHitTarget, minHeight: minimumHitTarget)
            .background(Capsule().fill(isSelected ? Color("BrandColor") : Color("CardColor")))
            .foregroundStyle(isSelected ? .white : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var minimumHitTarget: CGFloat? {
#if os(visionOS)
        VisionReadabilityMetrics.minimumControlTargetSize
#else
        nil
#endif
    }

    private var chipHorizontalPadding: CGFloat {
#if os(visionOS)
        18
#else
        14
#endif
    }

    private var chipVerticalPadding: CGFloat {
#if os(visionOS)
        9
#else
        7
#endif
    }
}
