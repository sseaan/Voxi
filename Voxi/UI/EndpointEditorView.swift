import SwiftUI

/// 模型页：单一列表 + 弹窗编辑，参考 OpenVoice 的模型来源/模型配置结构。
struct EndpointListView: View {
    @ObservedObject var settings: SettingsStore
    @State private var addingSource = false
    @State private var editing: EditingProfile?
    @State private var pendingDelete: EndpointProfile?
    @State private var testingProfile: EndpointProfile?
    @State private var editingLanguageModel: LanguageModelProfile?
    @State private var pendingDeleteLanguageModel = false

    private struct EditingProfile: Identifiable {
        var profile: EndpointProfile
        var isNew: Bool
        var id: UUID { profile.id }
    }

    private var profiles: [EndpointProfile] { settings.settings.profiles }

    var body: some View {
        SettingsPage(title: "模型") {
            SettingsListCard(
                "模型来源",
                footer: "标签区分语音识别与语言模型；API Key 只保存在 macOS 钥匙串中。"
            ) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 {
                        Divider().padding(.leading, 12).opacity(0.6)
                    }
                    sourceRow(profile, index: index)
                }
                if let model = settings.settings.languageModel {
                    Divider().padding(.leading, 12).opacity(0.6)
                    languageModelRow(model)
                }
                Divider().padding(.leading, 12).opacity(0.6)
                Button {
                    addingSource = true
                } label: {
                    Label("添加模型来源", systemImage: "plus")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }

            SettingsListCard(
                "语音识别模型",
                footer: "按来源分组；同一来源内从上到下尝试，来源顺序由上方列表决定。"
            ) {
                let candidates = settings.settings.asrCandidates
                if candidates.isEmpty {
                    Text("尚未启用模型。请编辑来源，填写模型或从服务获取模型列表。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                } else {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        if index == 0 || candidates[index - 1].profile.id != candidate.profile.id {
                            if index > 0 {
                                Divider().padding(.leading, 12).opacity(0.6)
                            }
                            sourceHeader(candidate.profile)
                        }
                        modelRow(candidate, index: index)
                    }
                }
            }

            SettingsListCard(
                "语言模型",
                footer: "用于按风格整理识别结果；点击选择实际调用的模型。"
            ) {
                if let languageModel = settings.settings.languageModel {
                    let models = languageModel.effectiveModels
                    if models.isEmpty {
                        Text("尚未启用语言模型。请编辑来源，填写模型或从服务获取模型列表。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                    } else {
                        ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                            if index > 0 {
                                Divider().padding(.leading, 12).opacity(0.6)
                            }
                            languageModelListRow(model, profile: languageModel)
                        }
                    }
                    Divider().padding(.leading, 12).opacity(0.6)
                    Button {
                        editingLanguageModel = languageModel
                    } label: {
                        Label("管理语言模型…", systemImage: "slider.horizontal.3")
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 10) {
                        LanguageModelBadge(size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("尚未配置语言模型")
                                .font(.system(size: 13))
                            Text("选择风格前需要先添加通用 OpenAI 接入")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("添加") {
                            editingLanguageModel = LanguageModelProfile()
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
        }
        .sheet(isPresented: $addingSource) {
            ProviderPickerSheet { choice in
                // 等来源选择弹窗完全收起后再打开编辑弹窗，避免两个 sheet 竞争。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    switch choice {
                    case .asr(let kind):
                        var profile = kind == .openAICompatible
                            ? EndpointProfile.defaultOpenAIProfile()
                            : EndpointProfile.defaultVolcengineProfile()
                        profile.name = kind == .openAICompatible ? "OpenAI-compatible" : "火山引擎豆包"
                        editing = EditingProfile(profile: profile, isNew: true)
                    case .languageModel(let kind):
                        if let existing = settings.settings.languageModel,
                           existing.providerKind == kind {
                            editingLanguageModel = existing
                        } else {
                            editingLanguageModel = LanguageModelProfile.defaultProfile(for: kind)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { item in
            EndpointEditorSheet(
                profile: item.profile,
                isNew: item.isNew,
                isActive: item.profile.id == settings.settings.activeProfileID,
                onSave: { saved in
                    save(saved, isNew: item.isNew)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
        .sheet(item: $testingProfile) { profile in
            EndpointTestView(profile: profile)
        }
        .sheet(item: $editingLanguageModel) { profile in
            LanguageModelEditorSheet(
                profile: profile,
                onSave: { saved in
                    settings.settings.languageModel = saved
                    editingLanguageModel = nil
                },
                onCancel: { editingLanguageModel = nil }
            )
        }
        .confirmationDialog(
            "删除语言模型配置？",
            isPresented: $pendingDeleteLanguageModel
        ) {
            Button("删除", role: .destructive) {
                deleteLanguageModel()
                pendingDeleteLanguageModel = false
            }
            Button("取消", role: .cancel) { pendingDeleteLanguageModel = false }
        } message: {
            Text("风格整理将停止工作，直到重新配置语言模型。")
        }
        .confirmationDialog(
            "删除这个模型来源？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { profile in
            Button("删除", role: .destructive) {
                deleteSecrets(of: profile)
                settings.removeProfile(id: profile.id)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { profile in
            Text("将移除「\(profile.name.isEmpty ? "未命名" : profile.name)」及其模型配置。")
        }
    }

    private func sourceRow(_ profile: EndpointProfile, index: Int) -> some View {
        HStack(spacing: 10) {
            ProviderBadge(kind: profile.kind, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name.isEmpty ? "未命名来源" : profile.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    CapabilityTag(text: "语音识别", color: Color(red: 0.33, green: 0.47, blue: 0.92))
                }
                Text(sourceSummary(profile))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(credentialStatus(profile).text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                moveSource(index, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(index == 0 ? Color.secondary.opacity(0.3) : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .help("上移来源")
            Button {
                moveSource(index, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(index == profiles.count - 1 ? Color.secondary.opacity(0.3) : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(index == profiles.count - 1)
            .help("下移来源")
            Button("修改") {
                editing = EditingProfile(profile: profile, isNew: false)
            }
            .controlSize(.small)
            Button {
                pendingDelete = profile
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(profiles.count <= 1)
            .help("删除模型来源")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func sourceHeader(_ profile: EndpointProfile) -> some View {
        HStack(spacing: 8) {
            ProviderBadge(kind: profile.kind, size: 20)
            Text(profile.name.isEmpty ? "未命名来源" : profile.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            CapabilityTag(
                text: "语音识别",
                color: Color(red: 0.33, green: 0.47, blue: 0.92)
            )
            Spacer()
            Text("\(profile.effectiveModels.count) 个模型")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func modelRow(_ candidate: ASRModelCandidate, index: Int) -> some View {
        let profile = candidate.profile
        let models = profile.effectiveModels
        let modelIndex = models.firstIndex(of: candidate.model) ?? 0
        let canMove = profile.kind == .openAICompatible && models.count > 1
        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.secondary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.model)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text("\(candidate.sourceName) · \(profile.kind == .openAICompatible ? "OpenAI-compatible" : "火山引擎")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                testingProfile = candidate.resolvedProfile
            } label: {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("测试这个模型")
            Button {
                moveModel(candidate, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(canMove && modelIndex > 0 ? Color.secondary : Color.secondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canMove || modelIndex == 0)
            .help("提高优先级")
            Button {
                moveModel(candidate, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(canMove && modelIndex < models.count - 1 ? Color.secondary : Color.secondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canMove || modelIndex == models.count - 1)
            .help("降低优先级")
            Button {
                removeModel(candidate)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(models.count <= 1)
            .help("从来源中移除这个模型")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func languageModelListRow(_ model: String, profile: LanguageModelProfile) -> some View {
        Button {
            guard var updated = settings.settings.languageModel else { return }
            updated.model = model
            settings.settings.languageModel = updated
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model == profile.model
                      ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(model == profile.model
                                     ? Color.accentColor : Color.secondary.opacity(0.45))
                Text(model)
                    .font(.system(size: 13))
                Spacer()
                Text(profile.providerDisplayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if model == profile.model {
                    Text("使用中")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func moveSource(_ index: Int, offset: Int) {
        let target = index + offset
        guard profiles.indices.contains(index), profiles.indices.contains(target) else { return }
        var updated = profiles
        updated.swapAt(index, target)
        settings.settings.profiles = updated
        settings.settings.activeProfileID = updated.first?.id
    }

    private func moveModel(_ candidate: ASRModelCandidate, offset: Int) {
        guard candidate.profile.kind == .openAICompatible,
              let profileIndex = settings.settings.profiles.firstIndex(where: {
                  $0.id == candidate.profile.id
              })
        else { return }
        var profile = settings.settings.profiles[profileIndex]
        var models = profile.openAI.enabledModels ?? [profile.openAI.model]
        guard let index = models.firstIndex(of: candidate.model) else { return }
        let target = index + offset
        guard models.indices.contains(target) else { return }
        models.swapAt(index, target)
        profile.openAI.enabledModels = models
        profile.openAI.model = models.first ?? profile.openAI.model
        settings.settings.profiles[profileIndex] = profile
        settings.settings.activeProfileID = settings.settings.profiles.first?.id
    }

    private func removeModel(_ candidate: ASRModelCandidate) {
        guard candidate.profile.kind == .openAICompatible,
              let profileIndex = settings.settings.profiles.firstIndex(where: {
                  $0.id == candidate.profile.id
              })
        else { return }
        var profile = settings.settings.profiles[profileIndex]
        guard var models = profile.openAI.enabledModels,
              models.count > 1,
              let index = models.firstIndex(of: candidate.model)
        else { return }
        models.remove(at: index)
        profile.openAI.enabledModels = models
        profile.openAI.model = models.first ?? profile.openAI.model
        settings.settings.profiles[profileIndex] = profile
        settings.settings.activeProfileID = settings.settings.profiles.first?.id
    }

    private func deleteSecrets(of profile: EndpointProfile) {
        var ids = [profile.apiKeyItemID, profile.appKeyItemID, profile.accessKeyItemID].compactMap { $0 }
        for field in profile.openAI.customHeaders + profile.openAI.customFormFields {
            if case .keychain(let id) = field.value { ids.append(id) }
        }
        for id in ids {
            try? KeychainService.shared.delete(id)
        }
    }

    private func save(_ profile: EndpointProfile, isNew: Bool) {
        if let index = settings.settings.profiles.firstIndex(where: { $0.id == profile.id }) {
            settings.settings.profiles[index] = profile
        } else {
            settings.settings.profiles.append(profile)
        }
        settings.settings.activeProfileID = settings.settings.profiles.first?.id
    }

    private func languageModelRow(_ model: LanguageModelProfile) -> some View {
        HStack(spacing: 10) {
            LanguageModelBadge(kind: model.providerKind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name.isEmpty ? model.providerDisplayName : model.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    CapabilityTag(text: "语言模型", color: Color(red: 0.20, green: 0.68, blue: 0.48))
                }
                Text("\(model.providerDisplayName) · \(model.model)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(model.authMode == .none
                 ? "无需密钥"
                 : (model.apiKeyItemID == nil ? "未设置" : "••••••••"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button("修改") {
                editingLanguageModel = model
            }
            .controlSize(.small)
            Button {
                pendingDeleteLanguageModel = true
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("删除语言模型")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func deleteLanguageModel() {
        if let id = settings.settings.languageModel?.apiKeyItemID {
            try? KeychainService.shared.delete(id)
        }
        settings.settings.languageModel = nil
    }

    private func modelName(_ profile: EndpointProfile) -> String {
        switch profile.kind {
        case .openAICompatible:
            return profile.openAI.model.trimmingCharacters(in: .whitespacesAndNewlines)
        case .volcengineStreaming:
            return profile.volcengine.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func sourceSummary(_ profile: EndpointProfile) -> String {
        let provider = profile.kind == .openAICompatible ? "OpenAI-compatible" : "火山引擎"
        let models = profile.effectiveModels
        if models.count > 1 {
            return "\(provider) · \(models.count) 个模型"
        }
        let model = models.first ?? ""
        return model.isEmpty ? provider : "\(provider) · \(model)"
    }

    private func credentialStatus(_ profile: EndpointProfile) -> (text: String, isSet: Bool) {
        switch profile.kind {
        case .openAICompatible:
            if profile.openAI.authMode == .none { return ("无需密钥", true) }
            return profile.apiKeyItemID == nil ? ("未设置", false) : ("••••••••", true)
        case .volcengineStreaming:
            if profile.volcengine.authMode == .apiKey {
                return profile.apiKeyItemID == nil ? ("未设置", false) : ("••••••••", true)
            }
            let hasBoth = profile.appKeyItemID != nil && profile.accessKeyItemID != nil
            return hasBoth ? ("••••••••", true) : ("未设置", false)
        }
    }
}

private struct ProviderBadge: View {
    let kind: EndpointProfile.ProviderKind
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: kind == .openAICompatible ? "cloud.fill" : "waveform")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    private var gradient: LinearGradient {
        if kind == .openAICompatible {
            return LinearGradient(
                colors: [Color(red: 0.32, green: 0.55, blue: 0.98), Color(red: 0.20, green: 0.36, blue: 0.90)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color(red: 0.62, green: 0.40, blue: 0.98), Color(red: 0.44, green: 0.24, blue: 0.88)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private enum ProviderChoice: Equatable {
    case asr(EndpointProfile.ProviderKind)
    case languageModel(LanguageModelProfile.Kind)
}

private struct CapabilityTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct LanguageModelBadge: View {
    var kind: LanguageModelProfile.Kind = .openAICompatible
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: kind == .openCodeGo ? "terminal.fill" : "brain")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                gradient,
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
    }

    private var gradient: LinearGradient {
        if kind == .openCodeGo {
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.60, blue: 0.98), Color(red: 0.12, green: 0.36, blue: 0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color(red: 0.22, green: 0.74, blue: 0.54), Color(red: 0.10, green: 0.55, blue: 0.42)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct ProviderPickerSheet: View {
    let onPick: (ProviderChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ProviderChoice = .asr(.openAICompatible)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加模型来源")
                .font(.system(size: 18, weight: .semibold))

            Text("语音识别")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                asrCard(.openAICompatible)
                asrCard(.volcengineStreaming)
            }

            Text("语言模型")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            HStack(spacing: 10) {
                languageModelCard(.openAICompatible)
                languageModelCard(.openCodeGo)
            }

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 34, alignment: .topLeading)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("继续") {
                    onPick(selected)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private var detail: String {
        switch selected {
        case .asr(let kind):
            return kind.summary
        case .languageModel(let kind):
            if kind == .openCodeGo {
                return "OpenCode Go 专用端点（/inference/go/openai/v1），自动附带 OpenCode 会话头并使用 Chat Completions 格式。"
            }
            return "配置 OpenAI-compatible Chat Completions，用于在识别完成后按所选风格整理文本。与语音识别来源分开保存。"
        }
    }

    private func asrCard(_ kind: EndpointProfile.ProviderKind) -> some View {
        let isSelected = selected == .asr(kind)
        return Button {
            selected = .asr(kind)
        } label: {
            HStack(spacing: 10) {
                ProviderBadge(kind: kind, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .openAICompatible ? "OpenAI-compatible" : "火山引擎豆包")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(kind == .openAICompatible ? "HTTP / multipart 转写" : "WebSocket 流式识别")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func languageModelCard(_ kind: LanguageModelProfile.Kind) -> some View {
        let isSelected = selected == .languageModel(kind)
        return Button {
            selected = .languageModel(kind)
        } label: {
            HStack(spacing: 10) {
                LanguageModelBadge(kind: kind, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .openCodeGo ? "OpenCode Go" : "通用 OpenAI 接入")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(kind == .openCodeGo ? "Go 专用网关" : "Chat Completions")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct LanguageModelEditorSheet: View {
    @State private var draft: LanguageModelProfile
    @State private var apiKeyInput = ""
    @State private var message: String?
    @State private var showingModelPicker = false
    @State private var fetchedModels: [String] = []
    @State private var fetchingModels = false
    @State private var modelFetchMessage: String?
    private let onSave: (LanguageModelProfile) -> Void
    private let onCancel: () -> Void
    private let keychain = KeychainService.shared

    init(
        profile: LanguageModelProfile,
        onSave: @escaping (LanguageModelProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: profile)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(draft.apiKeyItemID == nil ? "添加" : "编辑") \(draft.providerDisplayName)")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsListCard(
                        "连接",
                        footer: draft.providerKind == .openCodeGo
                            ? "OpenCode Go 使用专用网关与 x-opencode-session 会话头。"
                            : "Endpoint 可填完整的 /chat/completions，也可只填到 /v1，Voxi 会自动补全。"
                    ) {
                        SettingsFieldRow("服务类型") {
                            Picker("", selection: Binding(
                                get: { draft.providerKind },
                                set: { newKind in
                                    guard newKind != draft.providerKind else { return }
                                    draft.kind = newKind
                                    draft.endpointURL = newKind.defaultEndpoint
                                    draft.enabledModels = nil
                                    if newKind == .openCodeGo {
                                        if draft.name.isEmpty || draft.name == "通用 OpenAI" {
                                            draft.name = "OpenCode Go"
                                        }
                                        if draft.model.isEmpty || draft.model == "gpt-4o-mini" {
                                            draft.model = newKind.defaultModel
                                        }
                                    } else {
                                        if draft.name == "OpenCode Go" {
                                            draft.name = "通用 OpenAI"
                                        }
                                        if draft.model == "deepseek-v4.1-flash" {
                                            draft.model = newKind.defaultModel
                                        }
                                    }
                                }
                            )) {
                                ForEach(LanguageModelProfile.Kind.allCases) { kind in
                                    Text(kind.displayName).tag(kind)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        if draft.providerKind == .openAICompatible,
                           draft.endpointURL.contains("opencode.ai") {
                            SettingsDivider()
                            Text("检测到 OpenCode 地址。如果使用 OpenCode Go，请把上面的服务类型切换为 OpenCode Go。")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        SettingsDivider()
                        SettingsFieldRow("名称") {
                            TextField("通用 OpenAI", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        }
                        SettingsDivider()
                        if draft.providerKind == .openAICompatible {
                            SettingsFieldRow("Endpoint") {
                                TextField(
                                    "https://api.openai.com/v1/chat/completions",
                                    text: $draft.endpointURL
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            }
                        } else {
                            SettingsFieldRow("Endpoint", subtitle: "OpenCode Go 专用，不可修改") {
                                Text("https://opencode.ai/inference/go/openai/v1/chat/completions")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }
                        SettingsDivider()
                        SettingsFieldRow(
                            "model",
                            subtitle: "手动填写会改为单模型；多模型请用「获取模型列表」勾选。"
                        ) {
                            HStack(spacing: 8) {
                                TextField(
                                    "gpt-4o-mini",
                                    text: Binding(
                                        get: { draft.model },
                                        set: { newValue in
                                            draft.model = newValue
                                            draft.enabledModels = nil
                                        }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                                Button(fetchingModels ? "获取中…" : "获取模型列表…") {
                                    fetchModels()
                                }
                                .controlSize(.small)
                                .disabled(fetchingModels)
                            }
                        }
                        if let enabled = draft.enabledModels, !enabled.isEmpty {
                            SettingsDivider()
                            SettingsFieldRow(
                                "已启用",
                                subtitle: "\(enabled.count) 个模型；会出现在模型页的语言模型列表"
                            ) {
                                Text(enabled.joined(separator: "、"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: 240, alignment: .trailing)
                            }
                        }
                        if let modelFetchMessage {
                            SettingsDivider()
                            Text(modelFetchMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }

                    SettingsListCard("鉴权与参数") {
                        SettingsFieldRow("鉴权") {
                            Picker("", selection: $draft.authMode) {
                                ForEach(LanguageModelProfile.AuthMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        if draft.authMode == .bearer {
                            SettingsDivider()
                            SettingsFieldRow(
                                "API Key",
                                subtitle: "保存到 Keychain；更新后首次读取可能需要选择“始终允许”。"
                            ) {
                                HStack(spacing: 6) {
                                    SecureField(
                                        draft.apiKeyItemID == nil
                                            ? "填写 API Key"
                                            : "已保存（留空不修改）",
                                        text: $apiKeyInput
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 260)
                                    if draft.apiKeyItemID != nil {
                                        Image(systemName: "lock.fill")
                                            .foregroundStyle(.secondary)
                                            .help("已保存在 Keychain")
                                    }
                                }
                            }
                        }
                        SettingsDivider()
                        SettingsFieldRow("超时") {
                            HStack(spacing: 6) {
                                TextField("60", value: $draft.timeoutSeconds, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                Text("秒")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        SettingsDivider()
                        SettingsFieldRow("temperature", subtitle: "0–2，越低越稳定") {
                            TextField("0.3", value: $draft.temperature, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                        }
                    }

                    Text("语言模型只接收识别后的文本，不接收录音；提示词由当前风格决定。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                }
                .padding(18)
            }

            Divider()
            HStack {
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 640, height: 560)
        .sheet(isPresented: $showingModelPicker) {
            ModelPickerSheet(
                title: "选择启用的语言模型",
                models: fetchedModels,
                selected: Set(draft.enabledModels ?? [draft.model])
            ) { selected in
                let ordered = fetchedModels.filter { selected.contains($0) }
                draft.enabledModels = ordered
                if let first = ordered.first {
                    draft.model = first
                }
                showingModelPicker = false
            } onCancel: {
                showingModelPicker = false
            }
        }
    }

    private func fetchModels() {
        modelFetchMessage = nil
        fetchingModels = true
        let profile = draft
        let key = apiKeyInput
        Task {
            do {
                let models = try await ProviderModelsService().fetchLanguageModels(
                    profile: profile,
                    apiKeyInput: key
                )
                var list = models
                let current = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !current.isEmpty, !list.contains(current) {
                    list.insert(current, at: 0)
                }
                fetchedModels = list
                showingModelPicker = true
            } catch {
                modelFetchMessage = error.localizedDescription
            }
            fetchingModels = false
        }
    }

    private func save() {
        message = nil
        var profile = draft
        profile.kind = profile.providerKind
        if profile.providerKind == .openCodeGo {
            profile.endpointURL = LanguageModelProfile.Kind.openCodeGo.defaultEndpoint
        }
        do {
            if !apiKeyInput.isEmpty {
                profile.apiKeyItemID = try keychain.store(
                    apiKeyInput,
                    for: profile.apiKeyItemID ?? UUID()
                )
            }
            if let validation = profile.validation() {
                message = validation
                return
            }
            onSave(profile)
        } catch {
            message = error.localizedDescription
        }
    }
}

struct EndpointEditorSheet: View {
    @State private var draft: EndpointProfile
    private let isNew: Bool
    private let isActive: Bool
    private let onSave: (EndpointProfile) -> Void
    private let onCancel: () -> Void
    @State private var showingTest = false

    init(
        profile: EndpointProfile,
        isNew: Bool,
        isActive: Bool,
        onSave: @escaping (EndpointProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: profile)
        self.isNew = isNew
        self.isActive = isActive
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "添加模型来源" : "编辑模型来源")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            EndpointEditorView(
                draft: $draft,
                isActive: isActive,
                showsHeader: false,
                saveMessage: .constant(nil),
                onSave: onSave,
                onTest: { showingTest = true }
            )
        }
        .frame(width: 680, height: 620)
        .sheet(isPresented: $showingTest) {
            EndpointTestView(profile: draft)
        }
    }
}

private struct ModelPickerSheet: View {
    let title: String
    let models: [String]
    let onApply: (Set<String>) -> Void
    let onCancel: () -> Void
    @State private var selected: Set<String>
    @State private var query = ""

    init(
        title: String,
        models: [String],
        selected: Set<String>,
        onApply: @escaping (Set<String>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.models = models
        self.onApply = onApply
        self.onCancel = onCancel
        _selected = State(initialValue: selected)
    }

    private var filteredModels: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("全选") { selected = Set(models) }
                    .controlSize(.small)
                Button("清空") { selected = [] }
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("搜索模型", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredModels.enumerated()), id: \.element) { index, model in
                        if index > 0 {
                            Divider().padding(.leading, 26)
                        }
                        Button {
                            if selected.contains(model) {
                                selected.remove(model)
                            } else {
                                selected.insert(model)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selected.contains(model)
                                      ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(selected.contains(model)
                                                     ? Color.accentColor : Color.secondary.opacity(0.45))
                                Text(model)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 320)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )

            HStack {
                Text("已选择 \(selected.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { onCancel() }
                Button("应用") { onApply(selected) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct EndpointEditorView: View {
    @Binding var draft: EndpointProfile
    let isActive: Bool
    var showsHeader = true
    @Binding var saveMessage: String?
    let onSave: (EndpointProfile) -> Void
    let onTest: () -> Void

    @State private var apiKeyInput = ""
    @State private var appKeyInput = ""
    @State private var accessKeyInput = ""
    @State private var secretFieldInputs: [UUID: String] = [:]
    @State private var localMessage: String?
    @State private var showingModelPicker = false
    @State private var fetchedModels: [String] = []
    @State private var fetchingModels = false
    @State private var modelFetchMessage: String?

    private let keychain = KeychainService.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if showsHeader {
                        header
                    }
                    generalCard
                    if draft.kind == .openAICompatible {
                        openAICard
                        customFieldsCard
                    } else {
                        volcengineCard
                    }
                }
                .frame(maxWidth: 580, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()
            actionBar
        }
        .sheet(isPresented: $showingModelPicker) {
            ModelPickerSheet(
                title: "选择启用的模型",
                models: fetchedModels,
                selected: Set(draft.openAI.enabledModels ?? [draft.openAI.model])
            ) { selected in
                let ordered = fetchedModels.filter { selected.contains($0) }
                draft.openAI.enabledModels = ordered
                if let first = ordered.first {
                    draft.openAI.model = first
                }
                showingModelPicker = false
            } onCancel: {
                showingModelPicker = false
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(draft.name.isEmpty ? "未命名端点" : draft.name)
                    .font(.title3.weight(.semibold))
                if isActive {
                    StatusBadge(text: "使用中", color: .green)
                }
            }
            Text(draft.kind.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 基本信息

    private var generalCard: some View {
        SettingsListCard("基本信息") {
            SettingsFieldRow("名称") {
                TextField("例如：公司内网 / 火山豆包", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }
            SettingsDivider()
            SettingsFieldRow("服务类型") {
                Picker("", selection: Binding(
                    get: { draft.kind },
                    set: { newKind in
                        guard draft.kind != newKind else { return }
                        switch newKind {
                        case .openAICompatible:
                            draft.endpointURL = "https://api.openai.com/v1/audio/transcriptions"
                        case .volcengineStreaming:
                            draft.endpointURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
                        }
                        draft.kind = newKind
                        localMessage = nil
                    }
                )) {
                    Text("OpenAI-compatible").tag(EndpointProfile.ProviderKind.openAICompatible)
                    Text("火山引擎流式").tag(EndpointProfile.ProviderKind.volcengineStreaming)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }
            SettingsDivider()
            SettingsFieldRow(
                "Endpoint",
                subtitle: draft.kind == .openAICompatible
                    ? "HTTPS；仅本机 loopback 可在下方明确允许 HTTP。Voxi 不会替换你填写的路径。"
                    : "WebSocket（wss://）。可填写控制台实际开通的兼容地址。"
            ) {
                TextField("完整 URL", text: $draft.endpointURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    // MARK: - OpenAI-compatible

    private var openAICard: some View {
        SettingsListCard("OpenAI-compatible") {
            SettingsFieldRow(
                "model",
                subtitle: "手动填写会改为单模型；多模型请用「获取模型列表」。"
            ) {
                HStack(spacing: 8) {
                    TextField(
                        "例如 whisper-1 / sensevoice",
                        text: Binding(
                            get: { draft.openAI.model },
                            set: { newValue in
                                draft.openAI.model = newValue
                                draft.openAI.enabledModels = nil
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    Button(fetchingModels ? "获取中…" : "获取模型列表…") {
                        fetchASRModels()
                    }
                    .controlSize(.small)
                    .disabled(fetchingModels)
                }
            }
            if let enabled = draft.openAI.enabledModels, !enabled.isEmpty {
                SettingsDivider()
                SettingsFieldRow(
                    "已启用",
                    subtitle: "\(enabled.count) 个模型；会出现在模型页的语音识别模型列表"
                ) {
                    Text(enabled.joined(separator: "、"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 250, alignment: .trailing)
                }
            }
            if let message = modelFetchMessage {
                SettingsDivider()
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            SettingsDivider()
            SettingsFieldRow("鉴权方式") {
                Picker("", selection: $draft.openAI.authMode) {
                    ForEach(EndpointProfile.OpenAIOptions.AuthMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if draft.openAI.authMode == .customHeader {
                SettingsDivider()
                SettingsFieldRow("Header 名") {
                    TextField("例如 api-key", text: $draft.openAI.customAuthHeaderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
            SettingsDivider()
            SettingsFieldRow(
                "API Key",
                subtitle: "保存到 Keychain；更新后首次读取可能需要选择“始终允许”。"
            ) {
                secretInput(text: $apiKeyInput, hasExisting: draft.apiKeyItemID != nil)
            }
            SettingsDivider()
            SettingsFieldRow("响应格式") {
                Picker("", selection: $draft.openAI.responseFormat) {
                    ForEach(EndpointProfile.OpenAIOptions.ResponseFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsDivider()
            SettingsFieldRow("超时") {
                HStack(spacing: 6) {
                    TextField("60", value: $draft.openAI.timeoutSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("秒")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            SettingsDivider()
            SettingsFieldRow("发送 language 字段") {
                Toggle("", isOn: $draft.openAI.sendsLanguageField)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsDivider()
            SettingsFieldRow("发送 prompt 字段") {
                Toggle("", isOn: $draft.openAI.sendsPromptField)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if draft.isLoopbackEndpoint {
                SettingsDivider()
                SettingsFieldRow("允许本机明文 HTTP", subtitle: "仅对 loopback 地址生效") {
                    Toggle("", isOn: $draft.openAI.allowsInsecureLocalHTTP)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
        }
    }

    private var customFieldsCard: some View {
        SettingsCard(
            "自定义 headers / 表单字段",
            footer: "不能覆盖 file / model / language / prompt / response_format / Content-Type / Authorization。"
        ) {
            httpFieldsEditor(title: "Headers", fields: $draft.openAI.customHeaders)
            Divider()
            httpFieldsEditor(title: "Form fields", fields: $draft.openAI.customFormFields)
        }
    }

    private func httpFieldsEditor(
        title: String,
        fields: Binding<[EndpointProfile.HTTPField]>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer()
                Button {
                    fields.wrappedValue.append(.init(name: "", value: .literal("")))
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("添加\(title == "Headers" ? " header" : "字段")")
            }

            if fields.wrappedValue.isEmpty {
                Text("暂无自定义\(title == "Headers" ? " header" : "字段")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(fields) { $field in
                HStack(spacing: 6) {
                    TextField("名称", text: $field.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 128)
                    if field.isSecret {
                        SecureField(
                            secretFieldInputs[field.id] == nil ? "已保存（可留空）" : "",
                            text: Binding(
                                get: { secretFieldInputs[field.id] ?? "" },
                                set: { secretFieldInputs[field.id] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    } else {
                        TextField("值", text: literalBinding(for: field))
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("secret", isOn: Binding(
                        get: { field.isSecret },
                        set: { field.isSecret = $0 }
                    ))
                    .toggleStyle(.checkbox)

                    Button {
                        fields.wrappedValue.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - 火山

    private var volcengineCard: some View {
        SettingsListCard("火山引擎豆包流式识别") {
            SettingsFieldRow("鉴权模式", subtitle: "新版与旧版凭据不能混用。") {
                Picker("", selection: $draft.volcengine.authMode) {
                    ForEach(EndpointProfile.VolcengineOptions.AuthMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            switch draft.volcengine.authMode {
            case .apiKey:
                SettingsDivider()
                SettingsFieldRow(
                    "API Key",
                    subtitle: "保存到 Keychain；更新后首次读取可能需要选择“始终允许”。"
                ) {
                    secretInput(text: $apiKeyInput, hasExisting: draft.apiKeyItemID != nil)
                }
            case .legacy:
                SettingsDivider()
                SettingsFieldRow("App Key") {
                    secretInput(text: $appKeyInput, hasExisting: draft.appKeyItemID != nil)
                }
                SettingsDivider()
                SettingsFieldRow("Access Key") {
                    secretInput(text: $accessKeyInput, hasExisting: draft.accessKeyItemID != nil)
                }
            }
            SettingsDivider()
            SettingsFieldRow(
                "Resource ID",
                subtitle: "与账号已开通的资源一致，例如 volc.seedasr.sauc.duration。"
            ) {
                TextField("volc.seedasr.sauc.duration", text: $draft.volcengine.resourceID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            SettingsDivider()
            SettingsFieldRow("model_name") {
                TextField("bigmodel", text: $draft.volcengine.modelName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            SettingsDivider()
            SettingsFieldRow("结果类型") {
                Picker("", selection: $draft.volcengine.resultType) {
                    ForEach(EndpointProfile.VolcengineOptions.ResultType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            SettingsDivider()
            SettingsFieldRow(
                "X-Api-Sequence",
                subtitle: "按所选 v3 接口要求发送"
            ) {
                Toggle("", isOn: $draft.volcengine.sendsApiSequenceHeader)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - 底部操作栏

    private var actionBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let message = localMessage {
                    Text(message).foregroundStyle(.orange)
                } else if let saveMessage {
                    Text(saveMessage).foregroundStyle(.secondary)
                } else if let validation = draft.validation().message {
                    Text(validation).foregroundStyle(.orange)
                } else if !draft.isLoopbackEndpoint && draft.kind == .openAICompatible {
                    Text("配置有效").foregroundStyle(.secondary)
                } else {
                    Text("")
                }
            }
            .font(.caption)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("测试端点…") {
                saveDraft()
                if draft.validation().isValid {
                    onTest()
                }
            }
            .disabled(!draft.validation().isValid)

            Button("保存") {
                saveDraft()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 控件

    private func secretInput(text: Binding<String>, hasExisting: Bool) -> some View {
        HStack(spacing: 6) {
            SecureField(
                hasExisting ? "已保存（留空表示不修改）" : "填写后保存到 Keychain",
                text: text
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 340)
            if hasExisting {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("已保存在 Keychain")
            }
        }
    }

    private func literalBinding(for field: EndpointProfile.HTTPField) -> Binding<String> {
        Binding(
            get: {
                if case .literal(let value) = field.value, !field.isSecret { return value }
                return ""
            },
            set: { newValue in
                if let index = draft.openAI.customHeaders.firstIndex(where: { $0.id == field.id }) {
                    draft.openAI.customHeaders[index].value = .literal(newValue)
                } else if let index = draft.openAI.customFormFields.firstIndex(where: { $0.id == field.id }) {
                    draft.openAI.customFormFields[index].value = .literal(newValue)
                }
            }
        )
    }

    // MARK: - 模型列表

    private func fetchASRModels() {
        modelFetchMessage = nil
        fetchingModels = true
        let profile = draft
        let key = apiKeyInput
        Task {
            do {
                let models = try await ProviderModelsService().fetchASRModels(
                    profile: profile,
                    apiKeyInput: key
                )
                var list = models
                let current = profile.openAI.model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !current.isEmpty, !list.contains(current) {
                    list.insert(current, at: 0)
                }
                fetchedModels = list
                showingModelPicker = true
            } catch {
                modelFetchMessage = error.localizedDescription
            }
            fetchingModels = false
        }
    }

    // MARK: - 保存

    private func saveDraft() {
        localMessage = nil
        do {
            var profile = draft
            profile.apiKeyItemID = try saveSecret(apiKeyInput, existing: profile.apiKeyItemID)
            profile.appKeyItemID = try saveSecret(appKeyInput, existing: profile.appKeyItemID)
            profile.accessKeyItemID = try saveSecret(accessKeyInput, existing: profile.accessKeyItemID)

            try saveCustomFieldSecrets(&profile)

            let validation = profile.validation()
            guard validation.isValid else {
                localMessage = validation.message
                return
            }
            draft = profile
            apiKeyInput = ""
            appKeyInput = ""
            accessKeyInput = ""
            secretFieldInputs = [:]
            onSave(profile)
        } catch {
            localMessage = error.localizedDescription
        }
    }

    private func saveSecret(_ input: String, existing: UUID?) throws -> UUID? {
        guard !input.isEmpty else { return existing }
        return try keychain.store(input, for: existing ?? UUID())
    }

    private func saveCustomFieldSecrets(_ profile: inout EndpointProfile) throws {
        profile.openAI.customHeaders = try profile.openAI.customHeaders.map { try resolve($0) }
        profile.openAI.customFormFields = try profile.openAI.customFormFields.map { try resolve($0) }
    }

    private func resolve(_ field: EndpointProfile.HTTPField) throws -> EndpointProfile.HTTPField {
        guard field.isSecret else { return field }
        let input = secretFieldInputs[field.id] ?? ""
        var updated = field
        if !input.isEmpty {
            let id = try keychain.store(input, for: fieldID(for: field) ?? UUID())
            updated.value = .keychain(id)
        } else if fieldID(for: field) == nil {
            throw TranscriptionError.missingCredential
        }
        return updated
    }

    private func fieldID(for field: EndpointProfile.HTTPField) -> UUID? {
        if case .keychain(let id) = field.value { return id }
        return nil
    }
}
