import SwiftUI

struct SourceDisclaimerView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("disclaimer.badge", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color("CautionColor"))
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
        .navigationTitle("settings.section.disclaimer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
    }
}
