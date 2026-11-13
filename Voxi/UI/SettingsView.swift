import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var appState: AppState
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem { Label("通用", systemImage: "gearshape") }
            TextModeEditorView(settings: settings)
                .tabItem { Label("文本", systemImage: "textformat") }
            EndpointListView(settings: settings)
                .tabItem { Label("识别服务", systemImage: "antenna.radiowaves.left.and.right") }
            AboutSettingsView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 520)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var shortcutMessage: String?

    var body: some View {
        Form {
            Section("录音方式") {
                Picker("快捷键行为", selection: $settings.settings.recordingMode) {
                    ForEach(RecordingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.settings.recordingMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("全局快捷键") {
                LabeledContent("当前快捷键") {
                    ShortcutRecorderView(
                        configuration: settings.settings.shortcut,
                        onRecord: { configuration in
                            shortcutMessage = nil
                            settings.settings.shortcut = configuration
                        },
                        onInvalid: { message in
                            shortcutMessage = message
                        }
                    )
                    .frame(width: 180, height: 26)
                }
                if let shortcutMessage {
                    Text(shortcutMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("点击上方快捷键后按下新的组合键。组合键冲突时会在菜单栏提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("输入") {
                Toggle("识别完成后自动输入到前台应用", isOn: $settings.settings.autoInsertEnabled)
                Toggle("菜单栏显示流式临时文本", isOn: $settings.settings.showInterimTextInMenuBar)
                Text("未授权辅助功能时，识别结果会保留在菜单栏供复制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Voxi")
                .font(.title2.weight(.semibold))
            Text("版本 \(Bundle.main.shortVersion) (\(Bundle.main.buildVersion))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("本地录音，发送到你自己配置的语音识别服务。不保存历史，不上传第三方。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    var buildVersion: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}
