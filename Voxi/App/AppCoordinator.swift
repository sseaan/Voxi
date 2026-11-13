import AppKit
import Foundation

/// 所有开始、停止、取消和异步结果都经由此对象。
///
/// 不变量：
/// - 同一时刻最多一个 session；每次开始录音生成新的 `UUID`；
/// - 任何异步结果在写入 UI 或前台应用前必须校验 session ID 未变；
/// - 重复开始/停止/取消是安全的 no-op。
///
/// Phase 0.4 只建立状态机与 session 记账；Phase 1–4 逐步接入权限、音频采集、
/// 识别 provider 与自动输入。
@MainActor
final class AppCoordinator: ObservableObject {
    let settings: SettingsStore
    let appState: AppState

    private(set) var currentSessionID: UUID?

    init(settings: SettingsStore, appState: AppState) {
        self.settings = settings
        self.appState = appState
    }

    // MARK: - 快捷键入口

    /// 快捷键按下。按住模式开始录音；切换模式在开始/停止之间切换。
    func handleShortcutPress() {
        switch settings.settings.recordingMode {
        case .holdToTalk:
            startRecording()
        case .toggle:
            if appState.state.isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        }
    }

    /// 快捷键松开。只有按住模式会结束录音；切换模式忽略。
    func handleShortcutRelease() {
        guard settings.settings.recordingMode == .holdToTalk else { return }
        stopRecording()
    }

    /// 菜单栏「开始 / 停止」按钮。
    func toggleFromMenu() {
        if appState.state.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    // MARK: - 状态机入口

    func startRecording() {
        guard !appState.state.isBusy else {
            Logger.app.debug("忽略重复的开始录音请求，当前状态 \(self.appState.state.rawValue, privacy: .public)")
            return
        }
        guard let profile = settings.activeProfile else {
            appState.present(error: "尚未配置识别端点，请先在设置中添加。")
            transition(to: .failed)
            return
        }

        if appState.state == .failed {
            // 失败状态必须先回到 idle 才能开始新的 session。
            transition(to: .idle)
        }

        let sessionID = UUID()
        currentSessionID = sessionID
        appState.beginSession(id: sessionID, provider: profile.kind)
        Logger.app.info("开始录音 session=\(sessionID.uuidString, privacy: .public) provider=\(profile.kind.rawValue, privacy: .public)")

        // Phase 1 起：先申请麦克风权限，再进入 .recording。
        transition(to: .recording, startedAt: Date())
    }

    func stopRecording() {
        guard appState.state.isRecording else {
            Logger.app.debug("忽略停止请求：当前状态 \(self.appState.state.rawValue, privacy: .public)")
            return
        }
        transition(to: .finalizingAudio)

        // Phase 2/3 起：这里等待音频收尾、上传或等待最终包。
        appState.present(notice: "识别服务尚未接入，录音流程到此为止。")
        transition(to: .idle)
    }

    func cancelCurrentSession() {
        guard appState.state.isBusy else { return }
        Logger.app.info("取消 session=\(self.currentSessionID?.uuidString ?? "nil", privacy: .public)")
        transition(to: .cancelling)
        finishSession()
        transition(to: .idle)
    }

    // MARK: - 内部

    /// 结束一次 session：清理 session 记账。调用前状态必须已到 `.idle`。
    private func finishSession() {
        currentSessionID = nil
        appState.endSession()
    }

    private func transition(to newState: RecordingState, startedAt: Date? = nil) {
        guard appState.state.canTransition(to: newState) else {
            Logger.app.error("非法状态流转 \(self.appState.state.rawValue, privacy: .public) -> \(newState.rawValue, privacy: .public)")
            return
        }
        Logger.app.debug("状态 \(self.appState.state.rawValue, privacy: .public) -> \(newState.rawValue, privacy: .public)")
        appState.updateState(newState, startedAt: startedAt)
        if newState == .idle {
            finishSession()
        }
    }
}
