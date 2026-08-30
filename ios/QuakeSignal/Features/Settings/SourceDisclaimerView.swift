import SwiftUI

struct SourceDisclaimerView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("disclaimer.badge")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color("SevereColor"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color("SevereColor").opacity(0.14)))
                    Text("disclaimer.summary")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("disclaimer.section.sources") {
                Label("disclaimer.source.wolfx", systemImage: "antenna.radiowaves.left.and.right")
                Label("disclaimer.source.cenc", systemImage: "antenna.radiowaves.left.and.right")
                Label("disclaimer.source.jma", systemImage: "antenna.radiowaves.left.and.right")
            }

            Section {
                Text("disclaimer.notOfficial")
                Text("disclaimer.mayBeDelayed")
                Text("disclaimer.deliveryNotGuaranteed")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Section {
                LabeledContent("settings.about.version", value: appVersion)
            }
        }
        .nativeGroupedChrome()
        .navigationTitle("settings.section.disclaimer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
    }
}
