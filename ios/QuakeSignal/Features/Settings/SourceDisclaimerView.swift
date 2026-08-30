import Foundation
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
                Label("disclaimer.source.jma", systemImage: "antenna.radiowaves.left.and.right")
                Text("disclaimer.source.jmaAttribution")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("disclaimer.source.jmaTerms", destination: Self.jmaTermsURL)
                Link("disclaimer.source.publicDataLicense", destination: Self.publicDataLicenseURL)
                Label("disclaimer.source.usgs", systemImage: "globe.americas")
                Label("disclaimer.source.emsc", systemImage: "globe.europe.africa")
                Label("disclaimer.source.geonet", systemImage: "globe.asia.australia")
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

    private static let jmaTermsURL = URL(string: "https://www.jma.go.jp/jma/en/copyright.html")!
    private static let publicDataLicenseURL = URL(
        string: "https://www.digital.go.jp/en/resources/open_data/public_data_license_v1.0"
    )!
}
