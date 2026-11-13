import SwiftUI

/// 菜单栏下拉面板：状态、录音控制、临时预览、错误与常用命令。
struct MenuBarView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var appState: AppState
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let notice = appState.noticeMessage {
                messageRow(notice, icon: "info.circle", color: .secondary)
            }
            if let error = appState.errorMessage {
                messageRow(error, icon: "exclamationmark.triangle.fill", color: .orange)
            }
            if !appState.interimText.isEmpty {
                interimPreview
            }

            Divider()
            controls
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - 组件

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: appState.state.menuBarSystemImage)
                .font(.system(size: 20))
                .foregroundStyle(appState.state.isRecording ? Color.red : Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.state.menuTitle)
                    .font(.headline)
                subtitle
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if appState.state.isRecording, let startedAt = appState.recordingStartedAt {
            TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                Text("已录制 \(Self.formatted(elapsed: context.date.timeIntervalSince(startedAt)))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else if let profile = settings.activeProfile {
            Text("\(profile.name) · \(profile.kind == .openAICompatible ? "停止后上传" : "实时流式")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("尚未配置识别端点")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func messageRow(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var interimPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("临时识别（不会自动输入）")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(appState.interimText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if appState.state == .idle || appState.state == .failed {
                Button {
                    coordinator.startRecording()
                } label: {
                    Label("开始录音", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if appState.state.isRecording {
                Button(role: .destructive) {
                    coordinator.stopRecording()
                } label: {
                    Label("停止并识别", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {} label: {
                    Label(appState.state.menuTitle, systemImage: appState.state.menuBarSystemImage)
                        .frame(maxWidth: .infinity)
                }
                .disabled(true)
            }

            if appState.state.isBusy {
                Button("取消") {
                    coordinator.cancelCurrentSession()
                }
                .disabled(appState.state == .cancelling)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                SettingsWindowController.shared.show(
                    settings: settings,
                    appState: appState,
                    coordinator: coordinator
                )
            } label: {
                Label("设置…", systemImage: "gearshape")
            }
            .buttonStyle(.link)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出 Voxi", systemImage: "power")
            }
            .buttonStyle(.link)
        }
        .font(.callout)
    }

    static func formatted(elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
