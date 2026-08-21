import SwiftUI

struct DisasterGuideView: View {
    @State private var guide = GuideStore.shared
    @State private var showingFamilyCheckIn = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("guide.offlineBadge", systemImage: "checkmark.icloud")
                        .font(.caption)
                        .visionFont(.body.weight(.semibold))
                        .foregroundStyle(Color("NormalColor"))
                        .visionReadableRow(minimumHeight: 64)
                }
#if os(visionOS)
                .listRowBackground(
                    Color("CardColor")
                        .opacity(VisionReadabilityMetrics.rowSurfaceOpacity)
                )
#else
                .listRowBackground(Color.clear)
#endif
                .listRowSeparator(.hidden)

                Section("guide.section.duringQuake") {
                    ForEach(GuideContent.duringQuakeTopics) { topic in
                        NavigationLink(value: topic.id) {
                            HStack(spacing: 12) {
                                Image(systemName: topic.symbol)
                                    .foregroundStyle(Color("BrandColor"))
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(topic.titleKey)
                                        .font(.subheadline.weight(.medium))
                                        .visionFont(.body.weight(.semibold))
                                    Text(topic.summaryKey)
                                        .font(.caption)
                                        .visionFont(.subheadline)
                                        .visionSupportingText()
                                }
                            }
                        }
                        .visionReadableRow()
                    }
                }

                Section("guide.section.afterQuake") {
                    ForEach(GuideContent.afterQuakeKeys, id: \.self) { key in
                        Label {
                            Text(LocalizedStringKey(key))
                        } icon: {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(Color("NormalColor"))
                        }
                        .font(.subheadline)
                        .visionFont(.body)
                        .visionReadableRow()
                    }
                }

                Section("guide.section.kit") {
                    ForEach(GuideContent.emergencyKit) { item in
                        Button {
                            guide.toggle(item.id)
                        } label: {
                            HStack {
                                Image(systemName: item.symbol)
                                    .foregroundStyle(Color("BrandColor"))
                                    .frame(width: 28)
                                Text(item.labelKey)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: guide.checkedKitItems.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(guide.checkedKitItems.contains(item.id) ? Color("NormalColor") : Color("GrayColor"))
                            }
                        }
                        .buttonStyle(.plain)
                        .visionReadableRow()
                    }

                    Button {
                        showingFamilyCheckIn = true
                    } label: {
                        Label(guide.hasFamilyContact ? "guide.kit.familyContact.edit" : "guide.kit.familyContact.add", systemImage: "person.crop.circle.badge.plus")
                    }
                    .visionReadableRow()
                }
            }
            .visionReadableListSurface(
                minimumRowHeight: VisionReadabilityMetrics.guideMinimumRowHeight
            )
            .navigationTitle("tab.guide")
            .navigationDestination(for: String.self) { topicId in
                if let topic = GuideContent.duringQuakeTopics.first(where: { $0.id == topicId }) {
                    GuideTopicDetailView(topic: topic)
                }
            }
            .sheet(isPresented: $showingFamilyCheckIn) {
                FamilyCheckInView()
            }
        }
    }
}
