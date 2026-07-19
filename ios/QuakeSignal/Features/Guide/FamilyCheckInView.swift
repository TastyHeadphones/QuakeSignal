import SwiftUI

/// A simple local-only contact card -- no backend involved, matching its
/// scope in the source design (a single "+ set up family check-in" entry
/// point, not a full messaging feature).
struct FamilyCheckInView: View {
    @State private var guide = GuideStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var guide = guide

        NavigationStack {
            Form {
                Section {
                    Text("guide.familyCheckIn.explanation")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("guide.familyCheckIn.contact") {
                    TextField(String(localized: "guide.familyCheckIn.name"), text: $guide.familyContactName)
                    TextField(String(localized: "guide.familyCheckIn.phone"), text: $guide.familyContactPhone)
                        .keyboardType(.phonePad)
                }
            }
            .navigationTitle("guide.familyCheckIn.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "alert.dismiss")) { dismiss() }
                }
            }
        }
    }
}
