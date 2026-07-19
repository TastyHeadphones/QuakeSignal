import Foundation

@Observable
@MainActor
final class GuideStore {
    static let shared = GuideStore()

    var checkedKitItems: Set<String> {
        didSet { UserDefaults.standard.set(Array(checkedKitItems), forKey: Keys.checkedKit) }
    }
    var familyContactName: String {
        didSet { UserDefaults.standard.set(familyContactName, forKey: Keys.contactName) }
    }
    var familyContactPhone: String {
        didSet { UserDefaults.standard.set(familyContactPhone, forKey: Keys.contactPhone) }
    }

    var hasFamilyContact: Bool { !familyContactName.isEmpty }

    private enum Keys {
        static let checkedKit = "guide.checkedKitItems"
        static let contactName = "guide.familyContactName"
        static let contactPhone = "guide.familyContactPhone"
    }

    private init() {
        let defaults = UserDefaults.standard
        checkedKitItems = Set(defaults.array(forKey: Keys.checkedKit) as? [String] ?? [])
        familyContactName = defaults.string(forKey: Keys.contactName) ?? ""
        familyContactPhone = defaults.string(forKey: Keys.contactPhone) ?? ""
    }

    func toggle(_ itemId: String) {
        if checkedKitItems.contains(itemId) {
            checkedKitItems.remove(itemId)
        } else {
            checkedKitItems.insert(itemId)
        }
    }
}
