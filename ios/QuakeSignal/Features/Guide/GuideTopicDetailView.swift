import SwiftUI

struct GuideTopicDetailView: View {
    let topic: GuideTopic

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: topic.symbol)
                        .font(.system(size: 40))
                        .foregroundStyle(Color("BrandColor"))
                    Text(topic.summaryKey)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)

            Section("guide.detail.steps") {
                ForEach(topic.detailKeys, id: \.self) { key in
                    Label {
                        Text(LocalizedStringKey(key))
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(Color("NormalColor"))
                    }
                    .font(.subheadline)
                }
            }
        }
        .navigationTitle(topic.titleKey)
        .navigationBarTitleDisplayMode(.inline)
    }
}
