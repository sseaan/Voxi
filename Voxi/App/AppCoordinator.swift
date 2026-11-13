import AppKit
import Combine
import Foundation

/// 所有开始、停止、取消和异步结果都经由此对象。
///
/// 不变量：
/// - 同一时刻最多一个 session；每次开始录音生成新的 `UUID`；
/// - 任何异步结果在写入 UI 或前台应用前必须校验 session ID 未变；
/// - 重复开始/停止/取消是安全的 no-op。
@MainActor
final class AppCoordinator: ObservableObject {
    let settings: SettingsStore
    let appState: AppState

    private(set) var currentSessionID: UUID?
    let permissions: PermissionService

    private let microphoneGate: MicrophoneAccessGating
    private let audioCapture: AudioCapturing
    private let shortcutService = ShortcutService()
    private var permissionTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var capturedByteCount = 0
    private var cancellables = Set<AnyCancellable>()
    private var isActivated = false
    /// 快捷键当前是否按下；用于识别“权限弹窗期间松开”的情况。
    private var isShortcutDown = false
    /// 本次 session 是否由“按住快捷键”触发（菜单/API 触发不受松键保护影响）。
    private var startedWithShortcutHeld = false

    init(
        settings: SettingsStore,
        appState: AppState,
        microphoneGate: MicrophoneAccessGating = SystemAudioPermissionProvider(),
        audioCapture: AudioCapturing = AudioCaptureService()
    ) {
        self.settings = settings
        self.appState = appState
        self.microphoneGate = microphoneGate
        self.audioCapture = audioCapture
        self.permissions = PermissionService()
    }

    /// 应用启动时调用一次：注册全局快捷键并跟随设置变化。
    func activate() {
        guard !isActivated else { return }
        isActivated = true

        shortcutService.onPress = { [weak self] in
            self?.handleShortcutPress()
        }
        shortcutService.onRelease = { [weak self] in
            self?.handleShortcutRelease()
        }

        settings.$settings
            .map(\.shortcut)
            .removeDuplicates()
            .sink { [weak self] shortcut in
                self?.applyShortcut(shortcut)
            }
            .store(in: &cancellables)

        permissions.refresh()
        Logger.app.info("协调器已启动，快捷键 \(self.settings.settings.shortcut.displayString, privacy: .public)")
    }

    /// 应用失焦或按键松开事件丢失时的兜底。
    func handleApplicationResignActive() {
        shortcutService.resetKeyState()
        isShortcutDown = false
        let action = ShortcutEventMapper.action(
            for: .lostFocus,
            mode: settings.settings.recordingMode,
            isRecording: appState.state.isRecording
        )
        if action == .stop {
            stopRecording()
        }
        permissions.refresh()
    }

    func handleShortcutEvent(_ event: ShortcutEvent) {
        switch event {
        case .keyDown: isShortcutDown = true
        case .keyUp: isShortcutDown = false
        case .lostFocus: isShortcutDown = false
        }

        let mode = settings.settings.recordingMode
        let action = ShortcutEventMapper.action(
            for: event,
            mode: mode,
            isRecording: appState.state.isRecording
        )
        switch action {
        case .start: startRecording(shortcutHeld: true)
        case .stop: stopRecording()
        case .ignore: break
        }

        // 按住模式下，权限弹窗还没结束就松开快捷键：取消本次录音，避免永久录音。
        if event == .keyUp, mode == .holdToTalk, appState.state == .requestingPermission {
            cancelCurrentSession()
        }
    }

    private func applyShortcut(_ shortcut: ShortcutConfiguration) {
        do {
            try shortcutService.register(shortcut)
        } catch {
            Logger.shortcut.error("快捷键注册失败: \(String(describing: error), privacy: .public)")
            appState.present(error: AppError(
                message: error.localizedDescription + " 请到设置中更换快捷键。"
            ))
        }
    }

    // MARK: - 快捷键入口

    /// 快捷键按下。按住模式开始录音；切换模式在开始/停止之间切换。
    func handleShortcutPress() {
        handleShortcutEvent(.keyDown)
    }

    /// 快捷键松开。只有按住模式会结束录音；切换模式忽略。
    func handleShortcutRelease() {
        handleShortcutEvent(.keyUp)
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
        startRecording(shortcutHeld: false)
    }

    private func startRecording(shortcutHeld: Bool) {
        guard !appState.state.isBusy else {
            Logger.app.debug("忽略重复的开始录音请求，当前状态 \(self.appState.state.rawValue, privacy: .public)")
            return
        }
        guard let profile = settings.activeProfile else {
            appState.present(error: AppError(message: "尚未配置识别端点，请先在设置中添加。"))
            transition(to: .failed)
            return
        }

        if appState.state == .failed {
            // 失败状态必须先回到 idle 才能开始新的 session。
            transition(to: .idle)
        }

        let sessionID = UUID()
        currentSessionID = sessionID
        startedWithShortcutHeld = shortcutHeld
        appState.beginSession(id: sessionID, provider: profile.kind)
        Logger.app.info("开始录音 session=\(sessionID.uuidString, privacy: .public) provider=\(profile.kind.rawValue, privacy: .public)")

        switch microphoneGate.authorization {
        case .granted:
            transition(to: .requestingPermission)
            beginRecording(sessionID: sessionID)
        case .denied, .restricted:
            failMicrophoneDenied(sessionID: sessionID)
        case .notDetermined:
            transition(to: .requestingPermission)
            requestMicrophonePermission(sessionID: sessionID)
        }
    }

    func stopRecording() {
        guard appState.state.isRecording else {
            Logger.app.debug("忽略停止请求：当前状态 \(self.appState.state.rawValue, privacy: .public)")
            return
        }
        transition(to: .finalizingAudio)
        audioTask?.cancel()
        audioTask = nil

        do {
            let metadata = try audioCapture.finish()
            AudioCaptureService.removeRecording(at: metadata.fileURL)
            let seconds = String(format: "%.1f", metadata.duration)
            appState.present(notice: "已录制 \(seconds) 秒音频，识别服务尚未接入。")
            transition(to: .idle)
        } catch AudioCaptureError.emptyRecording {
            appState.present(error: AppError(message: "没有采集到音频，请检查麦克风后重试。"))
            transition(to: .idle)
        } catch {
            Logger.app.error("结束录音失败: \(String(describing: error), privacy: .public)")
            appState.present(error: AppError(message: error.localizedDescription))
            transition(to: .failed)
        }
    }

    func cancelCurrentSession() {
        guard appState.state.isBusy else { return }
        Logger.app.info("取消 session=\(self.currentSessionID?.uuidString ?? "nil", privacy: .public)")
        permissionTask?.cancel()
        permissionTask = nil
        audioTask?.cancel()
        audioTask = nil
        audioCapture.cancel()
        transition(to: .cancelling)
        finishSession()
        transition(to: .idle)
    }

    // MARK: - 权限

    private func requestMicrophonePermission(sessionID: UUID) {
        permissionTask?.cancel()
        let gate = microphoneGate
        permissionTask = Task { [weak self] in
            let granted = await gate.ensureAccess()
            guard !Task.isCancelled, let self else { return }
            guard self.currentSessionID == sessionID else {
                Logger.app.debug("丢弃过期权限结果 session=\(sessionID.uuidString, privacy: .public)")
                return
            }
            self.permissionTask = nil
            if granted {
                self.beginRecording(sessionID: sessionID)
            } else {
                self.failMicrophoneDenied(sessionID: sessionID)
            }
        }
    }

    private func beginRecording(sessionID: UUID) {
        guard currentSessionID == sessionID, appState.state == .requestingPermission else { return }
        if startedWithShortcutHeld, settings.settings.recordingMode == .holdToTalk, !isShortcutDown {
            // 权限请求期间已经松开快捷键（松开事件可能丢失）：不开始录音。
            Logger.app.info("快捷键已松开，跳过本次录音 session=\(sessionID.uuidString, privacy: .public)")
            cancelCurrentSession()
            return
        }
        do {
            let stream = try audioCapture.start()
            capturedByteCount = 0
            audioTask = Task { [weak self] in
                for await chunk in stream {
                    guard let self, self.currentSessionID == sessionID else { return }
                    self.capturedByteCount += chunk.count
                }
            }
            transition(to: .recording, startedAt: Date())
        } catch {
            Logger.app.error("启动录音失败: \(String(describing: error), privacy: .public)")
            appState.present(error: AppError(message: error.localizedDescription))
            transition(to: .failed)
        }
    }

    private func failMicrophoneDenied(sessionID: UUID) {
        guard currentSessionID == sessionID else { return }
        appState.present(error: AppError(
            message: "麦克风权限未开启。请在系统设置 → 隐私与安全性 → 麦克风中允许 Voxi。",
            recovery: .openMicrophoneSettings
        ))
        transition(to: .failed)
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
        if newState == .idle || newState == .failed {
            // 终态：清理 session，避免迟到结果再写入目标应用。
            finishSession()
        }
    }
}
