import SwiftUI

/// 菜单栏下拉面板：状态、录音控制、临时预览、错误与常用命令。
struct MenuBarView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var appState: AppState
    @ObservedObject var coordinator: AppCoordinator
    /// 在打开设置/退出前关闭自定义面板。
    var onRequestClose: (() -> Void)?
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onTranscribeAudio: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let notice = appState.noticeMessage {
                messageRow(notice, icon: "info.circle", color: .secondary)
            }
            if let error = appState.error {
                VStack(alignment: .leading, spacing: 6) {
                    messageRow(error.message, icon: "exclamationmark.triangle.fill", color: .orange)
                    if let recovery = error.recovery {
                        Button(Self.recoveryTitle(recovery)) {
                            Self.perform(recovery)
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }
            }
            if !appState.interimText.isEmpty {
                interimPreview
            }
            if let result = appState.lastResult {
                resultPreview(result)
            }

            Divider()
            controls
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        )
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
        } else if let first = settings.settings.asrCandidates.first {
            let count = settings.settings.asrCandidates.count
            Text(count > 1
                 ? "\(first.model) · 自动回退 \(count) 个模型"
                 : "\(first.sourceName) · \(first.model)")
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

    static func recoveryTitle(_ recovery: AppError.Recovery) -> String {
        switch recovery {
        case .openMicrophoneSettings: return "打开麦克风设置…"
        case .openAccessibilitySettings: return "打开辅助功能设置…"
        case .copyTranscript(let text): return text.isEmpty ? "复制" : "复制识别结果"
        }
    }

    static func perform(_ recovery: AppError.Recovery) {
        switch recovery {
        case .openMicrophoneSettings:
            PermissionService.openSettingsPane(.microphone)
        case .openAccessibilitySettings:
            PermissionService.openSettingsPane(.accessibility)
        case .copyTranscript(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    private func resultPreview(_ result: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("识别结果")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(result.text, forType: .string)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Text(result.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)
            if let logID = result.logID {
                Text("LogID: \(logID)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
                    if let onStartRecording {
                        onStartRecording()
                    } else {
                        coordinator.startRecording()
                    }
                } label: {
                    Label("开始录音", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if appState.state.isRecording {
                Button(role: .destructive) {
                    if let onStopRecording {
                        onStopRecording()
                    } else {
                        coordinator.stopRecording()
                    }
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
                onRequestClose?()
                SettingsWindowController.shared.show(
                    settings: settings,
                    appState: appState,
                    coordinator: coordinator
                )
            } label: {
                Label("设置…", systemImage: "gearshape")
            }
            .buttonStyle(.link)

            Button {
                onRequestClose?()
                onTranscribeAudio?()
            } label: {
                Label("转写音频…", systemImage: "waveform.badge.plus")
            }
            .buttonStyle(.link)

            Spacer()

            Button {
                onRequestClose?()
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

/// 自定义 NSPanel 的面板背景材质（系统 popover 背景不可用）。
struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
