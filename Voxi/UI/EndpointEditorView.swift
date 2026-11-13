import SwiftUI

/// 识别服务列表。Phase 2 会加入完整的端点编辑器。
struct EndpointListView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: activeProfileBinding) {
                ForEach(settings.settings.profiles) { profile in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(profile.name)
                                .font(.body.weight(.semibold))
                            if let validation = validationText(for: profile) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help(validation)
                            }
                        }
                        Text("\(profile.kind.displayName) · \(profile.endpointURL)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .tag(profile.id)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 8) {
                Menu {
                    Button("OpenAI-compatible 端点") {
                        settings.addProfile(.defaultOpenAIProfile())
                    }
                    Button("火山引擎流式端点") {
                        settings.addProfile(.defaultVolcengineProfile())
                    }
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    if let id = settings.settings.activeProfileID {
                        settings.removeProfile(id: id)
                    }
                } label: {
                    Label("删除", systemImage: "minus")
                }
                .disabled(settings.settings.profiles.count <= 1)

                Spacer()

                if let profile = settings.activeProfile {
                    Text(profile.kind.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 320, alignment: .trailing)
                }
            }
            .padding(10)
        }
    }

    private var activeProfileBinding: Binding<UUID?> {
        Binding(
            get: { settings.settings.activeProfileID ?? settings.settings.profiles.first?.id },
            set: { settings.settings.activeProfileID = $0 }
        )
    }

    private func validationText(for profile: EndpointProfile) -> String? {
        profile.validation().message
    }
}
