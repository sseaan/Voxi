import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var appState: AppState
    @ObservedObject var coordinator: AppCoordinator

    @State private var tab: SettingsTab = .dashboard
    @State private var onboardingController: OnboardingWindowController?

    init(settings: SettingsStore, appState: AppState, coordinator: AppCoordinator) {
        self.settings = settings
        self.appState = appState
        self.coordinator = coordinator
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: 32)

            VStack(spacing: 4) {
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
                .frame(width: 64, height: 64)

                Text("Voxi")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.82))
                Text("版本 \(Bundle.main.shortVersion)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 18)

            ForEach(SettingsTab.allCases) { item in
                SettingsSidebarItem(
                    tab: item,
                    selected: tab == item
                ) {
                    tab = item
                }
            }

            Spacer()
        }
        .padding(10)
        .frame(width: 178)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .dashboard:
            DashboardView(
                settings: settings,
                onRunOnboarding: runOnboarding,
                onOpenTab: { tab = $0 }
            )
        case .general:
            GeneralSettingsView(settings: settings, permissions: coordinator.permissions)
        case .endpoints:
            EndpointListView(settings: settings)
        case .text:
            TextModeEditorView(settings: settings, onOpenModels: { tab = .endpoints })
        case .lexicon:
            LexiconView(settings: settings)
        case .about:
            AboutSettingsView(onRunOnboarding: runOnboarding)
        }
    }

    private func runOnboarding() {
        settings.settings.hasCompletedOnboarding = false
        let controller = OnboardingWindowController(
            settings: settings,
            coordinator: coordinator
        )
        onboardingController = controller
        controller.show()
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permissions: PermissionService
    @State private var shortcutMessage: String?

    private var isAccessibilityTrusted: Bool {
        permissions.isAccessibilityTrusted()
    }

    var body: some View {
        SettingsPage(title: "通用") {
            SettingsListCard(
                "录音",
                footer: "按住说话适合短句；切换模式适合较长段落。"
            ) {
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
                SettingsFieldRow(
                    "识别完成后自动输入",
                    subtitle: "未授权辅助功能时，结果会保留在菜单栏供复制。"
                ) {
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
                SettingsFieldRow(
                    "登录时启动",
                    subtitle: "开机后自动在菜单栏运行"
                ) {
                    LaunchAtLoginToggle()
                }
            }

            SettingsListCard(
                "快捷键",
                footer: shortcutMessage ?? "支持组合键，也支持单键 Fn / 右 Option（需要辅助功能权限）。"
            ) {
                SettingsFieldRow(
                    "全局快捷键",
                    subtitle: "点击右侧后按下新的组合键"
                ) {
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
                    .frame(width: 170, height: 26)
                }
            }

            SettingsListCard(
                "权限",
                footer: "Voxi 只在录音结束后向当前焦点控件输入文字，不读取屏幕内容。"
            ) {
                SettingsFieldRow(
                    "麦克风",
                    subtitle: "录音与实时波形"
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: permissions.microphoneAuthorization.displayName,
                            color: permissions.microphoneAuthorization.isUsable ? .green : .orange
                        )
                        if !permissions.microphoneAuthorization.isUsable {
                            Button("打开设置…") {
                                PermissionService.openSettingsPane(.microphone)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                SettingsDivider()
                SettingsFieldRow(
                    "辅助功能",
                    subtitle: "把识别结果输入到前台应用"
                ) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: isAccessibilityTrusted ? "已授权" : "未授权",
                            color: isAccessibilityTrusted ? .green : .orange
                        )
                        if !isAccessibilityTrusted {
                            Button("请求权限") {
                                permissions.promptAccessibilityAccess()
                            }
                            .controlSize(.small)
                            Button("设置…") {
                                PermissionService.openSettingsPane(.accessibility)
                            }
                            .controlSize(.small)
                        }
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

private struct SettingsSidebarItem: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        tab.iconColor.gradient,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                Text(tab.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.09)
                          : hovering ? Color.primary.opacity(0.04) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct AboutSettingsView: View {
    var onRunOnboarding: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("关于")
                    .font(.system(size: 20, weight: .bold))
                    .padding(.top, 34)
                aboutContent
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var aboutContent: some View {
        VStack(spacing: 12) {
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
            .frame(width: 64, height: 64)
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
            Button("重新运行首次引导…") {
                onRunOnboarding()
            }
            .controlSize(.small)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
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
