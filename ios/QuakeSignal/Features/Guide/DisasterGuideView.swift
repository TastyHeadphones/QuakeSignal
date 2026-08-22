import SwiftUI

enum VisionGuideLayoutPolicy {
    static let wideAfterQuakeItemCount = 3
    static let afterQuakeRowBottomInset: CGFloat = 44

    static func usesWideAfterQuakeRow(
        itemCount: Int,
        dynamicTypeSize: DynamicTypeSize
    ) -> Bool {
        itemCount == wideAfterQuakeItemCount &&
            !dynamicTypeSize.isAccessibilitySize
    }
}

struct DisasterGuideView: View {
    @State private var guide = GuideStore.shared
    @State private var showingFamilyCheckIn = false

    private var usesCatalystScreenshotSummary: Bool {
#if DEBUG && targetEnvironment(macCatalyst)
        ScreenshotAutomation.selectedFrame == .macGuide
#else
        false
#endif
    }

    var body: some View {
        NavigationStack {
            if usesCatalystScreenshotSummary {
                CatalystGuideScreenshotSummary()
            } else {
                guideList
            }
        }
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

    private var guideList: some View {
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
#if os(visionOS)
                    VisionAfterQuakeItems(keys: GuideContent.afterQuakeKeys)
                        .visionReadableRow()
#else
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
#endif
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
    }
}

private struct CatalystGuideScreenshotSummary: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("guide.offlineBadge", systemImage: "checkmark.icloud")
                    .font(.headline)
                    .foregroundStyle(Color("NormalColor"))

                guideCard(
                    title: "guide.section.duringQuake",
                    symbol: "figure.wave",
                    detail: "Drop, cover, and hold on. Move away from windows and stay calm."
                )
                guideCard(
                    title: "guide.section.afterQuake",
                    symbol: "checkmark.circle",
                    detail: "Check for injuries, watch for aftershocks, and follow local instructions."
                )
                guideCard(
                    title: "guide.section.kit",
                    symbol: "cross.case",
                    detail: "Water · First aid · Flashlight · Power bank · Documents"
                )
            }
            .padding(24)
        }
        .background(Color("GroupedBGColor"))
    }

    private func guideCard(title: LocalizedStringKey, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color("CardColor"), in: RoundedRectangle(cornerRadius: 16))
    }
}

#if os(visionOS)
private struct VisionAfterQuakeItems: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let keys: [String]

    private var responsiveLayout: AnyLayout {
        if VisionGuideLayoutPolicy.usesWideAfterQuakeRow(
            itemCount: keys.count,
            dynamicTypeSize: dynamicTypeSize
        ) {
            AnyLayout(HStackLayout(alignment: .top, spacing: 24))
        } else {
            AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        }
    }

    var body: some View {
        responsiveLayout {
            ForEach(keys, id: \.self) { key in
                Label {
                    Text(LocalizedStringKey(key))
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Color("NormalColor"))
                }
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.bottom, VisionGuideLayoutPolicy.afterQuakeRowBottomInset)
        .accessibilityElement(children: .contain)
    }
}
#endif
