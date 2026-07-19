import SwiftUI

// LocalizedStringKey isn't Sendable (it's SwiftUI's, not ours), but these are
// plain immutable data structs with no shared mutable state, so it's safe to
// assert Sendable ourselves rather than have the compiler infer it.
struct GuideTopic: Identifiable, @unchecked Sendable {
    let id: String
    let titleKey: LocalizedStringKey
    let summaryKey: LocalizedStringKey
    let symbol: String
    // Plain strings, not [LocalizedStringKey]: LocalizedStringKey isn't
    // Hashable, and ForEach(_:id:\.self) needs that. Wrap with
    // LocalizedStringKey(_:) at the call site.
    let detailKeys: [String]
}

struct GuideChecklistItem: Identifiable, @unchecked Sendable {
    let id: String
    let labelKey: LocalizedStringKey
    let symbol: String
}

enum GuideContent {
    static let duringQuakeTopics: [GuideTopic] = [
        GuideTopic(
            id: "indoor",
            titleKey: "guide.topic.indoor.title",
            summaryKey: "guide.topic.indoor.summary",
            symbol: "house.fill",
            detailKeys: ["guide.topic.indoor.detail1", "guide.topic.indoor.detail2", "guide.topic.indoor.detail3", "guide.topic.indoor.detail4"]
        ),
        GuideTopic(
            id: "outdoor",
            titleKey: "guide.topic.outdoor.title",
            summaryKey: "guide.topic.outdoor.summary",
            symbol: "figure.walk",
            detailKeys: ["guide.topic.outdoor.detail1", "guide.topic.outdoor.detail2", "guide.topic.outdoor.detail3"]
        ),
        GuideTopic(
            id: "elevator",
            titleKey: "guide.topic.elevator.title",
            summaryKey: "guide.topic.elevator.summary",
            symbol: "arrow.up.and.down",
            detailKeys: ["guide.topic.elevator.detail1", "guide.topic.elevator.detail2", "guide.topic.elevator.detail3"]
        ),
        GuideTopic(
            id: "car",
            titleKey: "guide.topic.car.title",
            summaryKey: "guide.topic.car.summary",
            symbol: "car.fill",
            detailKeys: ["guide.topic.car.detail1", "guide.topic.car.detail2", "guide.topic.car.detail3"]
        ),
    ]

    // Plain strings (not [LocalizedStringKey]) purely so this static array is
    // Sendable under Swift 6 strict concurrency -- wrap with
    // LocalizedStringKey(_:) at the call site.
    static let afterQuakeKeys: [String] = [
        "guide.after.item1",
        "guide.after.item2",
        "guide.after.item3",
    ]

    static let emergencyKit: [GuideChecklistItem] = [
        GuideChecklistItem(id: "water", labelKey: "guide.kit.water", symbol: "drop.fill"),
        GuideChecklistItem(id: "firstaid", labelKey: "guide.kit.firstAid", symbol: "cross.case.fill"),
        GuideChecklistItem(id: "light", labelKey: "guide.kit.flashlight", symbol: "flashlight.on.fill"),
        GuideChecklistItem(id: "battery", labelKey: "guide.kit.powerBank", symbol: "battery.100.bolt"),
        GuideChecklistItem(id: "documents", labelKey: "guide.kit.documents", symbol: "doc.text.fill"),
    ]
}
