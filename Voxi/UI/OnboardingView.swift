import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permissions: PermissionService
    let onFinish: () -> Void

    @State private var step: Step = .permissions
    @State private var keychainState: KeychainState = .idle
    @State private var shortcutMessage: String?
    @State private var skipModel = false
    @State private var editingModel: EndpointProfile?
    @State private var editingIsNew = true

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum Step: Int, CaseIterable {
        case permissions
        case shortcut
        case model
        case finish
    }

    enum KeychainState: Equatable {
        case idle
        case checking
        case ok
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "未测试"
            case .checking: return "测试中…"
            case .ok: return "已授权"
            case .failed: return "失败"
            }
        }

        var color: Color {
            switch self {
            case .idle: return .secondary
            case .checking: return .secondary
            case .ok: return .green
            case .failed: return .orange
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                    content
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { permissions.refresh() }
        .onReceive(timer) { _ in permissions.refresh() }
        .sheet(item: $editingModel) { profile in
            EndpointEditorSheet(
                profile: profile,
                isNew: editingIsNew,
                isActive: false,
                onSave: { saved in
                    if let index = settings.settings.profiles.firstIndex(where: { $0.id == saved.id }) {
                        settings.settings.profiles[index] = saved
                    } else {
                        settings.settings.profiles.append(saved)
                    }
                    settings.settings.activeProfileID = settings.settings.profiles.first?.id
                    editingModel = nil
                },
                onCancel: { editingModel = nil }
            )
        }
    }

    private var header: some View {
        VStack(spacing: 5) {
            Group {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "waveform.circle.fill")
                        .resizable()
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 44, height: 44)

            Text("Voxi")
                .font(.system(size: 19, weight: .semibold))
            Text("首次设置 · 第 \(step.rawValue + 1) 步，共 4 步")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Circle()
                        .fill(item == step ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    private var title: String {
        switch step {
        case .permissions: return "权限与钥匙串"
        case .shortcut: return "选择快捷键"
        case .model: return "配置识别模型"
        case .finish: return "启动与输出"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .permissions: permissionsStep
        case .shortcut: shortcutStep
        case .model: modelStep
        case .finish: finishStep
        }
    }

    // MARK: - 第一页

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Voxi 需要麦克风录音；辅助功能用于全局快捷键和把文字写回当前应用。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsListCard("系统权限") {
                SettingsFieldRow("麦克风", subtitle: "只在录音期间使用") {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: permissions.microphoneAuthorization.displayName,
                            color: permissions.microphoneAuthorization.isUsable ? .green : .orange
                        )
                        if permissions.microphoneAuthorization == .notDetermined {
                            Button("允许") {
                                Task {
                                    _ = await permissions.requestMicrophoneAccess()
                                    permissions.refresh()
                                }
                            }
                            .controlSize(.small)
                        } else if !permissions.microphoneAuthorization.isUsable {
                            Button("打开设置…") {
                                PermissionService.openSettingsPane(.microphone)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                SettingsDivider()
                SettingsFieldRow("辅助功能", subtitle: "右 Option 快捷键与自动输入") {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: permissions.isAccessibilityTrusted() ? "已授权" : "未授权",
                            color: permissions.isAccessibilityTrusted() ? .green : .orange
                        )
                        if !permissions.isAccessibilityTrusted() {
                            Button("请求权限") {
                                permissions.promptAccessibilityAccess()
                                PermissionService.openSettingsPane(.accessibility)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            if !permissions.isAccessibilityTrusted() {
                Text("未授权辅助功能时，单键快捷键和自动输入不可用；可稍后在设置中授予。")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsListCard(
                "钥匙串",
                footer: "首次读取已保存的 API Key 时，系统会弹窗，请选择「始终允许」。测试会读取已有密钥或创建一个临时条目。"
            ) {
                SettingsFieldRow("Keychain 访问") {
                    HStack(spacing: 8) {
                        StatusBadge(text: keychainState.text, color: keychainState.color)
                        Button(keychainState == .checking ? "测试中…" : "测试钥匙串") {
                            testKeychain()
                        }
                        .controlSize(.small)
                        .disabled(keychainState == .checking)
                    }
                }
                if case .failed(let message) = keychainState {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - 第二页

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("推荐使用右 Option：按住说话、松开结束；也可以改成任意组合键。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsListCard(
                "全局快捷键",
                footer: shortcutMessage ?? "单键快捷键需要辅助功能权限；点击右侧后按下新的组合键。"
            ) {
                SettingsFieldRow(
                    "当前快捷键",
                    subtitle: settings.settings.shortcut.displayString
                ) {
                    ShortcutRecorderView(
                        configuration: settings.settings.shortcut,
                        onRecord: { configuration in
                            settings.settings.shortcut = configuration
                            shortcutMessage = nil
                        },
                        onInvalid: { message in
                            shortcutMessage = message
                        }
                    )
                    .frame(width: 200, height: 28)
                }
                SettingsDivider()
                HStack(spacing: 8) {
                    Button("右 Option") {
                        setShortcut(ShortcutConfiguration.rightOptionKeyCode, modifiers: 0)
                    }
                    Button("Fn") {
                        setShortcut(ShortcutConfiguration.fnKeyCode, modifiers: 0)
                    }
                    Button("⌃⌥Space") {
                        setShortcut(
                            0x31,
                            modifiers: ShortcutConfiguration.Modifier.control.rawValue
                                | ShortcutConfiguration.Modifier.option.rawValue
                        )
                    }
                    Spacer()
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }

            if !permissions.isAccessibilityTrusted() {
                SettingsListCard("辅助功能") {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12))
                        Text("右 Option / Fn 需要辅助功能权限才能接收。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("去授权") {
                            permissions.promptAccessibilityAccess()
                            PermissionService.openSettingsPane(.accessibility)
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
        }
    }

    // MARK: - 第三页

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Voxi 需要一个语音识别端点。可以现在配置，也可以稍后在设置 → 模型中完成。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsListCard("已配置模型", footer: "API Key 只保存在 macOS 钥匙串。") {
                if settings.settings.profiles.isEmpty {
                    Text("尚未配置模型")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(settings.settings.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 {
                            SettingsDivider()
                        }
                        modelRow(profile)
                    }
                }
                SettingsDivider()
                Button {
                    editingIsNew = true
                    editingModel = .defaultOpenAIProfile()
                } label: {
                    Label("添加模型…", systemImage: "plus")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }

            Toggle("暂时跳过模型配置", isOn: $skipModel)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12.5))

            if skipModel {
                Text("可以稍后在 设置 → 模型中配置；在此之前录音会提示缺少模型。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if !hasConfiguredModel {
                Text("还没有可用的模型：请添加模型，或打开上面的跳过开关。")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func modelRow(_ profile: EndpointProfile) -> some View {
        HStack(spacing: 9) {
            Image(systemName: profile.kind == .openAICompatible ? "cloud" : "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name.isEmpty ? "未命名来源" : profile.name)
                    .font(.system(size: 13))
                Text(profile.effectiveModels.isEmpty
                     ? "未填写模型"
                     : profile.effectiveModels.joined(separator: "、"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if profile.validation().isValid {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Button("编辑") {
                editingIsNew = false
                editingModel = profile
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - 第四页

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最后确认几项常用设置，之后都可以在设置中修改。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            SettingsListCard("启动") {
                SettingsFieldRow(
                    "登录时启动",
                    subtitle: "开机后自动在菜单栏运行"
                ) {
                    LaunchAtLoginToggle()
                }
            }

            SettingsListCard("录音与输出") {
                SettingsFieldRow(
                    "录音方式",
                    subtitle: settings.settings.recordingMode.explanation
                ) {
                    Picker("", selection: $settings.settings.recordingMode) {
                        ForEach(RecordingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsDivider()
                SettingsFieldRow("识别完成后自动输入") {
                    Toggle("", isOn: $settings.settings.autoInsertEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsFieldRow("菜单栏显示流式临时文本") {
                    Toggle("", isOn: $settings.settings.showInterimTextInMenuBar)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsFieldRow("保留标点") {
                    Toggle("", isOn: $settings.settings.textMode.addPunctuation)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }

            Text("完成后会打开设置页，可继续配置语言模型、个人词库和高级选项。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .permissions {
                Button("上一步") {
                    if let previous = Step(rawValue: step.rawValue - 1) {
                        step = previous
                    }
                }
            }
            Spacer()
            if step == .finish {
                Button("完成并打开设置") {
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("继续") {
                    if let next = Step(rawValue: step.rawValue + 1) {
                        step = next
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var canContinue: Bool {
        switch step {
        case .permissions:
            return permissions.microphoneAuthorization.isUsable
        case .shortcut:
            return settings.settings.shortcut.isValid
        case .model:
            return skipModel || hasConfiguredModel
        case .finish:
            return true
        }
    }

    private var hasConfiguredModel: Bool {
        settings.settings.profiles.contains { profile in
            !profile.effectiveModels.isEmpty && profile.validation().isValid
        }
    }

    private func setShortcut(_ keyCode: UInt32, modifiers: UInt32) {
        settings.settings.shortcut = ShortcutConfiguration(
            keyCode: keyCode,
            carbonModifiers: modifiers
        )
        shortcutMessage = nil
    }

    private func testKeychain() {
        keychainState = .checking
        Task {
            var temporaryID: UUID?
            do {
                let existingID = settings.settings.profiles
                    .flatMap { [$0.apiKeyItemID, $0.appKeyItemID, $0.accessKeyItemID] }
                    .compactMap { $0 }
                    .first
                let id: UUID
                if let existingID {
                    id = existingID
                } else {
                    let newID = UUID()
                    _ = try KeychainService.shared.store(
                        "voxi-onboarding-probe-\(UUID().uuidString)",
                        for: newID
                    )
                    temporaryID = newID
                    id = newID
                }
                let value = try await SecretReader.secret(KeychainSecretResolver(), for: id)
                if let temporaryID {
                    try? KeychainService.shared.delete(temporaryID)
                }
                keychainState = value.isEmpty
                    ? .failed("读取为空")
                    : .ok
            } catch {
                if let temporaryID {
                    try? KeychainService.shared.delete(temporaryID)
                }
                keychainState = .failed(error.localizedDescription)
            }
        }
    }
}
