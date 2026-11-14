import SwiftUI

/// 识别服务列表 + 端点编辑器（左右分栏）。
struct EndpointListView: View {
    @ObservedObject var settings: SettingsStore
    @State private var selectedID: UUID?
    @State private var draft: EndpointProfile?
    @State private var showingTest = false
    @State private var saveMessage: String?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 210, maxWidth: 250)
            editor
                .frame(minWidth: 460)
        }
        .onAppear(perform: loadSelection)
        .onChange(of: selectedID) { _ in
            loadDraft()
        }
        .onChange(of: settings.settings.profiles) { _ in
            if selectedID == nil { loadSelection() }
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("端点")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("OpenAI-compatible 端点") { addProfile(.defaultOpenAIProfile()) }
                    Button("火山引擎流式端点") { addProfile(.defaultVolcengineProfile()) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("添加端点")

                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(settings.settings.profiles.count <= 1)
                .help("删除当前端点")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            List(selection: $selectedID) {
                ForEach(settings.settings.profiles) { profile in
                    row(for: profile)
                        .tag(profile.id)
                }
            }
            .listStyle(.sidebar)

            Divider()
            Text("勾选标记表示当前使用的端点。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(for profile: EndpointProfile) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: profile.kind == .openAICompatible
                  ? "cloud" : "waveform.path.ecg")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(profile.name.isEmpty ? "未命名" : profile.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if !profile.validation().isValid {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if profile.id == settings.settings.activeProfileID {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text(profile.kind == .openAICompatible ? "OpenAI-compatible" : "火山引擎流式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 编辑器

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
            VStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("选择一个端点，或点击左上角 + 新建")
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
        saveMessage = "已保存并设为当前端点 · \(Self.timeString())"
    }

    static func timeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
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
