import SwiftUI

/// 识别服务列表 + 端点编辑器。
struct EndpointListView: View {
    @ObservedObject var settings: SettingsStore
    @State private var selectedID: UUID?
    @State private var draft: EndpointProfile?
    @State private var showingTest = false
    @State private var saveMessage: String?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, maxWidth: 240)
            editor
                .frame(minWidth: 360)
        }
        .onAppear(perform: loadSelection)
        .onChange(of: selectedID) { _ in
            loadDraft()
        }
        .onChange(of: settings.settings.profiles) { _ in
            if selectedID == nil { loadSelection() }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(settings.settings.profiles) { profile in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(profile.name.isEmpty ? "未命名" : profile.name)
                                .font(.body.weight(.semibold))
                            if !profile.validation().isValid {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help(profile.validation().message ?? "")
                            }
                            if profile.id == settings.settings.activeProfileID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .help("当前使用中的端点")
                            }
                        }
                        Text(profile.kind == .openAICompatible ? "OpenAI-compatible" : "火山引擎流式")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(profile.id)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 6) {
                Menu {
                    Button("OpenAI-compatible 端点") { addProfile(.defaultOpenAIProfile()) }
                    Button("火山引擎流式端点") { addProfile(.defaultVolcengineProfile()) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(settings.settings.profiles.count <= 1)

                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let draftBinding = Binding($draft) {
            EndpointEditorView(
                draft: draftBinding,
                isActive: draft?.id == settings.settings.activeProfileID,
                saveMessage: $saveMessage,
                onSave: { profile in
                    save(profile)
                },
                onTest: { showingTest = true }
            )
            .sheet(isPresented: $showingTest) {
                if let profile = settings.activeProfile {
                    EndpointTestView(profile: profile)
                } else {
                    Text("请先保存端点配置。")
                        .padding(24)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("选择一个端点，或点击左下角 + 新建")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 数据

    private func loadSelection() {
        let id = settings.settings.activeProfileID ?? settings.settings.profiles.first?.id
        selectedID = id
        loadDraft()
    }

    private func loadDraft() {
        guard let id = selectedID,
              let profile = settings.settings.profiles.first(where: { $0.id == id })
        else {
            draft = nil
            return
        }
        draft = profile
        saveMessage = nil
    }

    private func addProfile(_ profile: EndpointProfile) {
        settings.addProfile(profile)
        selectedID = profile.id
        loadDraft()
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        settings.removeProfile(id: id)
        selectedID = settings.settings.activeProfileID
        loadDraft()
    }

    private func save(_ profile: EndpointProfile) {
        let validation = profile.validation()
        guard validation.isValid else {
            saveMessage = validation.message
            return
        }
        settings.updateActiveProfile(profile)
        draft = profile
        saveMessage = "已保存并设为当前端点。"
    }
}

/// 单端点编辑表单。secret 只在保存时写入 Keychain，界面不回显已保存的值。
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                generalSection
                if draft.kind == .openAICompatible {
                    openAISection
                    customFieldsSection
                } else {
                    volcengineSection
                }
                footer
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(draft.name.isEmpty ? "未命名端点" : draft.name)
                    .font(.title3.weight(.semibold))
                if isActive {
                    Text("使用中")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                }
            }
            Text(draft.kind.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var generalSection: some View {
        GroupBox("基本信息") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("名称", text: $draft.name)
                Picker("服务类型", selection: Binding(
                    get: { draft.kind },
                    set: { newKind in
                        if draft.kind != newKind {
                            draft.endpointURL = newKind == .openAICompatible
                                ? "https://api.openai.com/v1/audio/transcriptions"
                                : "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
                            draft.kind = newKind
                        }
                    }
                )) {
                    ForEach(EndpointProfile.ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                TextField("完整 Endpoint URL", text: $draft.endpointURL)
                    .font(.system(.body, design: .monospaced))
                Text(endpointKindHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var endpointKindHint: String {
        if draft.kind == .openAICompatible {
            return "HTTPS；本机 loopback 可在下方明确允许 HTTP。Voxi 不会替换你填写的路径。"
        }
        return "WebSocket（wss://）。可在控制台开通的兼容地址上修改。"
    }

    // MARK: - OpenAI-compatible

    private var openAISection: some View {
        GroupBox("OpenAI-compatible") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("model", text: $draft.openAI.model)

                Picker("鉴权方式", selection: $draft.openAI.authMode) {
                    ForEach(EndpointProfile.OpenAIOptions.AuthMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if draft.openAI.authMode == .customHeader {
                    TextField("鉴权 header 名称（例如 api-key）", text: $draft.openAI.customAuthHeaderName)
                }

                secureField(
                    title: "API Key",
                    existingID: draft.apiKeyItemID,
                    text: $apiKeyInput,
                    placeholder: draft.apiKeyItemID == nil ? "填写后保存到 Keychain" : "已保存（留空表示不修改）"
                )

                Picker("响应格式", selection: $draft.openAI.responseFormat) {
                    ForEach(EndpointProfile.OpenAIOptions.ResponseFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.radioGroup)

                HStack {
                    Text("超时（秒）")
                    TextField("60", value: $draft.openAI.timeoutSeconds, format: .number)
                        .frame(width: 80)
                }

                Toggle("发送 language 字段", isOn: $draft.openAI.sendsLanguageField)
                Toggle("发送 prompt 字段", isOn: $draft.openAI.sendsPromptField)
                if draft.isLoopbackEndpoint {
                    Toggle("允许对本机地址使用明文 HTTP", isOn: $draft.openAI.allowsInsecureLocalHTTP)
                }
            }
            .padding(8)
        }
    }

    private var customFieldsSection: some View {
        GroupBox("自定义 headers / 表单字段") {
            VStack(alignment: .leading, spacing: 12) {
                Text("自定义字段按顺序追加。不能覆盖 file / model / language / prompt / response_format / Content-Type / Authorization。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                httpFieldsEditor(title: "Headers", fields: $draft.openAI.customHeaders)
                httpFieldsEditor(title: "Form fields", fields: $draft.openAI.customFormFields)
            }
            .padding(8)
        }
    }

    private func httpFieldsEditor(
        title: String,
        fields: Binding<[EndpointProfile.HTTPField]>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Button {
                    fields.wrappedValue.append(.init(name: "", value: .literal("")))
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
            ForEach(fields) { $field in
                HStack(spacing: 6) {
                    TextField("名称", text: $field.name)
                        .frame(width: 130)
                    if field.isSecret {
                        SecureField(
                            secretFieldInputs[field.id] != nil ? secretFieldInputs[field.id]! : "已保存（可留空）",
                            text: Binding(
                                get: { secretFieldInputs[field.id] ?? "" },
                                set: { secretFieldInputs[field.id] = $0 }
                            )
                        )
                    } else {
                        TextField("值", text: literalBinding(for: field))
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

    // MARK: - 火山

    private var volcengineSection: some View {
        GroupBox("火山引擎豆包流式识别") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("鉴权模式", selection: $draft.volcengine.authMode) {
                    ForEach(EndpointProfile.VolcengineOptions.AuthMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                switch draft.volcengine.authMode {
                case .apiKey:
                    secureField(
                        title: "API Key",
                        existingID: draft.apiKeyItemID,
                        text: $apiKeyInput,
                        placeholder: draft.apiKeyItemID == nil ? "填写后保存到 Keychain" : "已保存（留空表示不修改）"
                    )
                case .legacy:
                    secureField(
                        title: "App Key",
                        existingID: draft.appKeyItemID,
                        text: $appKeyInput,
                        placeholder: draft.appKeyItemID == nil ? "填写后保存到 Keychain" : "已保存（留空表示不修改）"
                    )
                    secureField(
                        title: "Access Key",
                        existingID: draft.accessKeyItemID,
                        text: $accessKeyInput,
                        placeholder: draft.accessKeyItemID == nil ? "填写后保存到 Keychain" : "已保存（留空表示不修改）"
                    )
                }

                TextField("Resource ID", text: $draft.volcengine.resourceID)
                TextField("model_name", text: $draft.volcengine.modelName)

                Picker("结果类型", selection: $draft.volcengine.resultType) {
                    ForEach(EndpointProfile.VolcengineOptions.ResultType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("发送 X-Api-Sequence header", isOn: $draft.volcengine.sendsApiSequenceHeader)
            }
            .padding(8)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = localMessage ?? saveMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(localMessage == nil ? Color.secondary : Color.orange)
            }
            if let validation = draft.validation().message {
                Text(validation)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("保存") { saveDraft() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("测试端点…") {
                    saveDraft()
                    if draft.validation().isValid {
                        onTest()
                    }
                }
                .disabled(!draft.validation().isValid)
                Spacer()
                if let profile = settingsActiveHint {
                    Text(profile)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var settingsActiveHint: String? { nil }

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
        profile.openAI.customHeaders = try profile.openAI.customHeaders.map { field in
            try resolve(field)
        }
        profile.openAI.customFormFields = try profile.openAI.customFormFields.map { field in
            try resolve(field)
        }
    }

    private func resolve(_ field: EndpointProfile.HTTPField) throws -> EndpointProfile.HTTPField {
        guard field.isSecret else {
            if case .keychain = field.value {
                return field
            }
            return field
        }
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

    private func secureField(
        title: String,
        existingID: UUID?,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            if existingID != nil {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("已保存在 Keychain")
            }
        }
    }
}
