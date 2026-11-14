import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var appState: AppState
    @ObservedObject var coordinator: AppCoordinator

    @StateObject private var draft: SettingsDraft
    @State private var tab: SettingsTab = .general

    init(settings: SettingsStore, appState: AppState, coordinator: AppCoordinator) {
        self.settings = settings
        self.appState = appState
        self.coordinator = coordinator
        _draft = StateObject(wrappedValue: SettingsDraft(settings: settings.settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if tab == .general || tab == .text {
                Divider()
                footer
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 420)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general:
            GeneralSettingsView(draft: draft, permissions: coordinator.permissions)
        case .text:
            TextModeEditorView(draft: draft)
        case .endpoints:
            EndpointListView(settings: settings)
        case .about:
            AboutSettingsView()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch tab {
            case .general, .text:
                Text(draft.statusText)
                    .font(.callout)
                    .foregroundStyle(draft.hasChanges ? Color.orange : Color.secondary)
                Spacer()
                Button("还原") {
                    draft.revert(to: settings.settings)
                }
                .disabled(!draft.hasChanges)

                Button("保存") {
                    draft.save(into: settings)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!draft.hasChanges)
                .opacity(draft.hasChanges ? 1 : 0.55)
                .help("保存通用与文本设置（⌘S）")

            case .endpoints, .about:
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var draft: SettingsDraft
    @ObservedObject var permissions: PermissionService
    @State private var shortcutMessage: String?

    private var isAccessibilityTrusted: Bool {
        permissions.isAccessibilityTrusted()
    }

    var body: some View {
        SettingsPage {
            SettingsCard("录音方式", footer: "按住说话适合短句；切换模式适合较长段落。") {
                ForEach(RecordingMode.allCases) { mode in
                    Button {
                        draft.general.recordingMode = mode
                        shortcutMessage = nil
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: draft.general.recordingMode == mode
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(draft.general.recordingMode == mode
                                                 ? Color.accentColor : Color.secondary)
                                .font(.system(size: 14))
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.displayName)
                                Text(mode.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if mode != RecordingMode.allCases.last {
                        Divider()
                    }
                }
            }

            SettingsCard(
                "全局快捷键",
                footer: shortcutMessage ?? "点击快捷键框后按下组合键；也支持单键 Fn / 右 Option（需要辅助功能权限）。"
            ) {
                SettingsRow("组合键") {
                    ShortcutRecorderView(
                        configuration: draft.general.shortcut,
                        onRecord: { configuration in
                            shortcutMessage = nil
                            draft.general.shortcut = configuration
                        },
                        onInvalid: { message in
                            shortcutMessage = message
                        }
                    )
                    .frame(width: 180, height: 26)
                }
            }

            SettingsCard("输入", footer: "未授权辅助功能时，识别结果会保留在菜单栏供复制。") {
                Toggle("识别完成后自动输入到前台应用", isOn: $draft.general.autoInsertEnabled)
                Toggle("菜单栏显示流式临时文本", isOn: $draft.general.showInterimTextInMenuBar)
            }

            SettingsCard(
                "权限",
                footer: "Voxi 只在录音结束后向当前焦点控件输入文字，不会读取屏幕内容。"
            ) {
                HStack(spacing: 12) {
                    Text("麦克风")
                        .frame(width: 104, alignment: .leading)
                        .foregroundStyle(.secondary)
                    StatusBadge(
                        text: permissions.microphoneAuthorization.displayName,
                        color: permissions.microphoneAuthorization.isUsable ? .green : .orange
                    )
                    Spacer()
                    if !permissions.microphoneAuthorization.isUsable {
                        Button("打开设置…") {
                            PermissionService.openSettingsPane(.microphone)
                        }
                        .controlSize(.small)
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Text("辅助功能")
                        .frame(width: 104, alignment: .leading)
                        .foregroundStyle(.secondary)
                    StatusBadge(
                        text: isAccessibilityTrusted ? "已授权" : "未授权",
                        color: isAccessibilityTrusted ? .green : .orange
                    )
                    Spacer()
                    if !isAccessibilityTrusted {
                        Button("请求权限") {
                            permissions.promptAccessibilityAccess()
                        }
                        .controlSize(.small)
                        Button("打开设置…") {
                            PermissionService.openSettingsPane(.accessibility)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .onAppear {
            permissions.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Voxi")
                .font(.title2.weight(.semibold))
            Text("版本 \(Bundle.main.shortVersion) (\(Bundle.main.buildVersion))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("本地录音，发送到你自己配置的语音识别服务。\n不保存历史，不上传第三方。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Divider()
                .frame(width: 240)
                .padding(.vertical, 4)
            Text("自签名构建，不经过 Apple notarization。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
