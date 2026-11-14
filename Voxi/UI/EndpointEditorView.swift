import SwiftUI

/// 模型页：单一列表 + 弹窗编辑，参考 OpenVoice 的模型来源/模型配置结构。
struct EndpointListView: View {
    @ObservedObject var settings: SettingsStore
    @State private var addingSource = false
    @State private var editing: EditingProfile?
    @State private var pendingDelete: EndpointProfile?
    @State private var testingProfile: EndpointProfile?

    private struct EditingProfile: Identifiable {
        var profile: EndpointProfile
        var isNew: Bool
        var id: UUID { profile.id }
    }

    private var profiles: [EndpointProfile] { settings.settings.profiles }
    private var activeProfile: EndpointProfile? { settings.activeProfile }

    var body: some View {
        SettingsPage(title: "模型") {
            SettingsCard(
                "模型来源",
                footer: "API Key 只保存在 macOS 钥匙串中；云端请求直接发往你填写的端点。"
            ) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 {
                        Divider().padding(.leading, 12).opacity(0.6)
                    }
                    sourceRow(profile)
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

            SettingsCard(
                "语音识别模型",
                footer: "切换后下一次录音立即生效；当前只使用一个模型。"
            ) {
                activeModelRow
                if profiles.count > 1 {
                    Divider().padding(.leading, 12).opacity(0.6)
                    HStack(spacing: 12) {
                        Text("切换模型")
                            .font(.system(size: 13))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { activeProfile?.id ?? profiles[0].id },
                            set: { activate($0) }
                        )) {
                            ForEach(profiles) { profile in
                                Text(profile.name.isEmpty ? "未命名" : profile.name)
                                    .tag(profile.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
        }
        .sheet(isPresented: $addingSource) {
            ProviderPickerSheet { kind in
                var profile = kind == .openAICompatible
                    ? EndpointProfile.defaultOpenAIProfile()
                    : EndpointProfile.defaultVolcengineProfile()
                profile.name = kind == .openAICompatible ? "OpenAI-compatible" : "火山引擎豆包"
                // 等来源选择弹窗完全收起后再打开编辑弹窗，避免两个 sheet 竞争。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    editing = EditingProfile(profile: profile, isNew: true)
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

    private func sourceRow(_ profile: EndpointProfile) -> some View {
        HStack(spacing: 10) {
            ProviderBadge(kind: profile.kind, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name.isEmpty ? "未命名来源" : profile.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if profile.id == settings.settings.activeProfileID {
                        Text("使用中")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
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

    @ViewBuilder
    private var activeModelRow: some View {
        if let active = activeProfile {
            HStack(spacing: 10) {
                Text("1")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.secondary.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(modelName(active).isEmpty ? "未填写模型" : modelName(active))
                        .font(.system(size: 13))
                    Text(active.name.isEmpty ? "未命名来源" : active.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("测试") {
                    testingProfile = active
                }
                .controlSize(.small)
                Label("使用中", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        } else {
            Text("尚未选择模型")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        }
    }

    private func activate(_ id: UUID) {
        settings.settings.activeProfileID = id
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
        if isNew || settings.settings.activeProfileID == profile.id {
            settings.settings.activeProfileID = profile.id
        }
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
        let model = modelName(profile)
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

private struct ProviderPickerSheet: View {
    let onPick: (EndpointProfile.ProviderKind) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: EndpointProfile.ProviderKind = .openAICompatible

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加模型来源")
                .font(.system(size: 18, weight: .semibold))

            HStack(spacing: 10) {
                providerCard(.openAICompatible)
                providerCard(.volcengineStreaming)
            }

            Text(selected.summary)
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
        .frame(width: 520)
    }

    private func providerCard(_ kind: EndpointProfile.ProviderKind) -> some View {
        let isSelected = selected == kind
        return Button {
            selected = kind
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
}

private struct EndpointEditorSheet: View {
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
                    .font(.system(size: 16, weight: .semibold))
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

struct EndpointEditorView: View {
    @Binding var draft: EndpointProfile
    let isActive: Bool
    @Binding var saveMessage: String?
    let onSave: (EndpointProfile) -> Void
    let onTest: () -> Void

    @State private var apiKeyInput = ""
    @State private var appKeyInput = ""
    @State private var accessKeyInput = ""
    @State private var secretFieldInputs: [UUID: String] = [:]
    @State private var localMessage: String?

    private let keychain = KeychainService.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
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
        SettingsCard("基本信息") {
            SettingsRow("名称") {
                TextField("例如：公司内网 / 火山豆包", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }

            SettingsRow("服务类型") {
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
                .frame(width: 320)
            }

            SettingsRow(
                "Endpoint",
                caption: draft.kind == .openAICompatible
                    ? "HTTPS；仅本机 loopback 可在下方明确允许 HTTP。Voxi 不会替换你填写的路径。"
                    : "WebSocket（wss://）。可填写控制台实际开通的兼容地址。"
            ) {
                TextField("完整 URL", text: $draft.endpointURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    // MARK: - OpenAI-compatible

    private var openAICard: some View {
        SettingsCard("OpenAI-compatible") {
            SettingsRow("model", caption: "必填；不同服务的模型名不同。") {
                TextField("例如 whisper-1 / sensevoice", text: $draft.openAI.model)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }

            SettingsRow("鉴权方式") {
                Picker("", selection: $draft.openAI.authMode) {
                    ForEach(EndpointProfile.OpenAIOptions.AuthMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            if draft.openAI.authMode == .customHeader {
                SettingsRow("Header 名") {
                    TextField("例如 api-key", text: $draft.openAI.customAuthHeaderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
            }

            SettingsRow("API Key", caption: "保存到 Keychain；界面不回显已保存的密钥。更新后首次读取可能需要在系统对话框中选择“始终允许”。") {
                secretInput(
                    text: $apiKeyInput,
                    hasExisting: draft.apiKeyItemID != nil
                )
            }

            SettingsRow("响应格式") {
                Picker("", selection: $draft.openAI.responseFormat) {
                    ForEach(EndpointProfile.OpenAIOptions.ResponseFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            SettingsRow("超时") {
                HStack(spacing: 6) {
                    TextField("60", value: $draft.openAI.timeoutSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("秒").foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle("发送 language 字段", isOn: $draft.openAI.sendsLanguageField)
            Toggle("发送 prompt 字段", isOn: $draft.openAI.sendsPromptField)

            if draft.isLoopbackEndpoint {
                Toggle("允许对本机地址使用明文 HTTP", isOn: $draft.openAI.allowsInsecureLocalHTTP)
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
        SettingsCard("火山引擎豆包流式识别") {
            SettingsRow(
                "鉴权模式",
                caption: "新版与旧版凭据不能混用。"
            ) {
                Picker("", selection: $draft.volcengine.authMode) {
                    ForEach(EndpointProfile.VolcengineOptions.AuthMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 300)
            }

            switch draft.volcengine.authMode {
            case .apiKey:
                SettingsRow("API Key", caption: "保存到 Keychain；界面不回显已保存的密钥。更新后首次读取可能需要在系统对话框中选择“始终允许”。") {
                    secretInput(text: $apiKeyInput, hasExisting: draft.apiKeyItemID != nil)
                }
            case .legacy:
                SettingsRow("App Key") {
                    secretInput(text: $appKeyInput, hasExisting: draft.appKeyItemID != nil)
                }
                SettingsRow("Access Key") {
                    secretInput(text: $accessKeyInput, hasExisting: draft.accessKeyItemID != nil)
                }
            }

            SettingsRow("Resource ID", caption: "与账号已开通的资源一致，例如 volc.seedasr.sauc.duration。") {
                TextField("volc.seedasr.sauc.duration", text: $draft.volcengine.resourceID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            SettingsRow("model_name") {
                TextField("bigmodel", text: $draft.volcengine.modelName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            SettingsRow("结果类型") {
                Picker("", selection: $draft.volcengine.resultType) {
                    ForEach(EndpointProfile.VolcengineOptions.ResultType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            Toggle("发送 X-Api-Sequence header（按所选 v3 接口要求）", isOn: $draft.volcengine.sendsApiSequenceHeader)
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
