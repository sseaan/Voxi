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
    private let providers: [EndpointProfile.ProviderKind: TranscriptionProvider]
    private let textInserter: TextInserting
    private let frontmostProvider: FrontmostAppProviding
    private let styleProcessor: (String, VoxiSettings) async throws -> String
    private let shortcutService = ShortcutService()

    private var permissionTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var transcriptionSession: (any TranscriptionSession)?
    private var updatesTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private var isActivated = false
    /// 快捷键当前是否按下；用于识别“权限弹窗期间松开”的情况。
    private var isShortcutDown = false
    /// 本次 session 是否由“按住快捷键”触发（菜单/API 触发不受松键保护影响）。
    private var startedWithShortcutHeld = false
    private var capturedByteCount = 0
    /// 连接 ASR 期间采集到的 PCM，就绪后按顺序补发。
    private var pendingAudio: [Data] = []
    /// 连接期间用户已松开快捷键：连接成功后立即收尾，而不是丢弃录音。
    private var stopRequestedWhileConnecting = false
    /// 快捷键触发时记录的前台应用 PID；输入前必须仍然一致。
    private var targetApplicationPID: pid_t?

    /// 本次录音开始时锁定的模型链（按优先级）；中途改设置不影响本次。
    private var sessionProfiles: [EndpointProfile] = []
    private var attemptedProfileIDs: Set<UUID> = []
    private var activeSessionProfile: EndpointProfile?
    /// 流式模型中途断开：继续录音，结束后用备用模型转写。
    private var streamingFailed = false

    init(
        settings: SettingsStore,
        appState: AppState,
        microphoneGate: MicrophoneAccessGating = SystemAudioPermissionProvider(),
        audioCapture: AudioCapturing = AudioCaptureService(),
        providers: [TranscriptionProvider]? = nil,
        textInserter: TextInserting? = nil,
        frontmostProvider: FrontmostAppProviding = SystemFrontmostApp(),
        styleProcessor: @escaping (String, VoxiSettings) async throws -> String = { text, settings in
            try await StyleProcessor.process(text: text, settings: settings)
        }
    ) {
        self.settings = settings
        self.appState = appState
        self.microphoneGate = microphoneGate
        self.audioCapture = audioCapture
        self.permissions = PermissionService()

        let resolvedProviders = providers ?? [OpenAICompatibleProvider(), VolcengineStreamingProvider()]
        self.providers = Dictionary(uniqueKeysWithValues: resolvedProviders.map { ($0.kind, $0) })
        self.textInserter = textInserter ?? TextInsertionService(frontmost: frontmostProvider)
        self.frontmostProvider = frontmostProvider
        self.styleProcessor = styleProcessor
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

        // 按住模式下，权限弹窗还没结束就松开快捷键：取消本次录音。
        if event == .keyUp, mode == .holdToTalk, appState.state == .requestingPermission {
            cancelCurrentSession()
        }
        // 连接尚未完成时松键：标记连接完成后立即收尾，保留已采集音频。
        if event == .keyUp, mode == .holdToTalk, appState.state == .connecting {
            stopRecording()
        }
    }

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

    // MARK: - 开始录音

    func startRecording() {
        startRecording(shortcutHeld: false)
    }

    private func startRecording(shortcutHeld: Bool) {
        guard !appState.state.isBusy else {
            Logger.app.debug("忽略重复的开始录音请求，当前状态 \(self.appState.state.rawValue, privacy: .public)")
            return
        }
        let usableProfiles = settings.settings.profiles
        guard let profile = usableProfiles.first else {
            appState.present(error: AppError(message: "尚未配置可用的识别模型，请先在设置 → 模型中完善配置。"))
            transition(to: .failed)
            return
        }
        sessionProfiles = usableProfiles
        attemptedProfileIDs = []
        activeSessionProfile = nil
        streamingFailed = false

        if appState.state == .failed {
            // 失败状态必须先回到 idle 才能开始新的 session。
            transition(to: .idle)
        }

        let sessionID = UUID()
        currentSessionID = sessionID
        startedWithShortcutHeld = shortcutHeld
        stopRequestedWhileConnecting = false
        pendingAudio.removeAll()
        // 锁定录音开始时的前台应用；若前台是 Voxi 自己（例如从菜单栏触发），则不锁定，
        // 由面板在开始录音前恢复上一个应用的前台状态。
        let frontPID = frontmostProvider.currentPID()
        targetApplicationPID = frontPID == ProcessInfo.processInfo.processIdentifier ? nil : frontPID
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

    // MARK: - 停止录音

    func stopRecording() {
        if appState.state == .connecting {
            // 连接期间松键：保留已采集音频，连接完成后立即收尾。
            stopRequestedWhileConnecting = true
            Logger.app.debug("连接进行中收到停止请求，将在连接就绪后收尾")
            return
        }
        guard appState.state.isRecording else {
            Logger.app.debug("忽略停止请求：当前状态 \(self.appState.state.rawValue, privacy: .public)")
            return
        }
        let sessionID = currentSessionID
        transition(to: .finalizingAudio)

        finishTask?.cancel()
        finishTask = Task { [weak self] in
            await self?.finishRecording(sessionID: sessionID)
        }
    }

    func cancelCurrentSession() {
        guard appState.state.isBusy else { return }
        Logger.app.info("取消 session=\(self.currentSessionID?.uuidString ?? "nil", privacy: .public)")

        permissionTask?.cancel()
        permissionTask = nil
        audioTask?.cancel()
        audioTask = nil
        updatesTask?.cancel()
        updatesTask = nil
        finishTask?.cancel()
        finishTask = nil

        audioCapture.cancel()
        let session = transcriptionSession
        transcriptionSession = nil
        capturedByteCount = 0
        pendingAudio.removeAll()
        stopRequestedWhileConnecting = false

        transition(to: .cancelling)
        finishSession()
        transition(to: .idle)

        Task { await session?.cancel() }
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

    private func failMicrophoneDenied(sessionID: UUID) {
        guard currentSessionID == sessionID else { return }
        appState.present(error: AppError(
            message: "麦克风权限未开启。请在系统设置 → 隐私与安全性 → 麦克风中允许 Voxi。",
            recovery: .openMicrophoneSettings
        ))
        transition(to: .failed)
    }

    // MARK: - 录音与识别

    private func beginRecording(sessionID: UUID) {
        guard currentSessionID == sessionID, appState.state == .requestingPermission else { return }
        if startedWithShortcutHeld, settings.settings.recordingMode == .holdToTalk, !isShortcutDown {
            Logger.app.info("快捷键已松开，跳过本次录音 session=\(sessionID.uuidString, privacy: .public)")
            cancelCurrentSession()
            return
        }
        guard let firstProfile = sessionProfiles.first else {
            appState.present(error: AppError(message: "没有可用的识别模型。"))
            transition(to: .failed)
            return
        }

        let options = TranscriptionOptions(
            sessionID: sessionID,
            textMode: settings.settings.textMode,
            audioDuration: nil,
            lexicon: settings.settings.lexicon
        )

        // 第一个模型是流式时先显示“连接”；OpenAI-compatible 会话创建是即时的。
        if firstProfile.kind == .volcengineStreaming {
            transition(to: .connecting)
        }

        Task { [weak self] in
            do {
                guard let self else { return }
                try await self.startAudioCapture(sessionID: sessionID)
                Logger.app.debug("采集已启动（状态=\(self.appState.state.rawValue, privacy: .public)）")

                var attempts: [String] = []
                for profile in self.sessionProfiles {
                    guard let provider = self.providers[profile.kind] else { continue }
                    self.attemptedProfileIDs.insert(profile.id)
                    do {
                        let session = try await provider.makeSession(profile: profile, options: options)
                        guard self.currentSessionID == sessionID,
                              self.appState.state == .requestingPermission || self.appState.state == .connecting
                        else {
                            await session.cancel()
                            return
                        }
                        self.transcriptionSession = session
                        self.activeSessionProfile = profile
                        Logger.app.debug("ASR 会话就绪 provider=\(profile.kind.rawValue, privacy: .public) model=\(profile.name, privacy: .public)")
                        self.observeUpdates(session: session, sessionID: sessionID)
                        // 立即补发连接期间缓冲的音频，不必等下一个分片。
                        await self.flushPendingAudio(into: session)
                        self.transition(to: .recording, startedAt: self.captureStartedAt ?? Date())
                        if self.stopRequestedWhileConnecting {
                            self.stopRequestedWhileConnecting = false
                            self.stopRecording()
                        }
                        return
                    } catch {
                        let name = profile.name.isEmpty ? profile.kind.displayName : profile.name
                        attempts.append("\(name)：\(error.localizedDescription)")
                        Logger.app.error("模型「\(profile.name, privacy: .public)」连接失败，尝试下一个：\(String(describing: error), privacy: .public)")
                    }
                }
                self.failStart(
                    AllModelsFailedError(attempts: attempts),
                    sessionID: sessionID
                )
            } catch {
                self?.failStart(error, sessionID: sessionID)
            }
        }
    }

    private var captureStartedAt: Date?

    /// 订阅流式临时结果：只更新菜单栏预览，绝不写入前台应用。
    private func observeUpdates(session: any TranscriptionSession, sessionID: UUID) {
        updatesTask?.cancel()
        let showInMenuBar = settings.settings.showInterimTextInMenuBar
        updatesTask = Task { [weak self] in
            do {
                for try await update in session.updates {
                    guard let self, self.currentSessionID == sessionID else { return }
                    if case .interim(let text) = update {
                        self.appState.setInterimText(showInMenuBar ? text : "")
                    }
                }
            } catch {
                // 错误由 finish()/cancel() 统一上报，这里只结束预览。
                Logger.app.debug("临时结果流结束: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func startAudioCapture(sessionID: UUID) async throws {
        // AVAudioEngine 的启动/停止不能在主线程执行：设备切换时 CoreAudio 可能阻塞数秒。
        let capture = audioCapture
        let stream = try await Self.runWithTimeout(seconds: 10) {
            try capture.start()
        }
        guard currentSessionID == sessionID,
              appState.state == .requestingPermission || appState.state == .connecting
        else {
            // 启动期间用户已取消或开始新的 session：丢弃这次录音。
            Logger.app.info("录音启动完成时 session 已失效，丢弃采集 session=\(sessionID.uuidString, privacy: .public)")
            Task.detached(priority: .utility) { capture.cancel() }
            return
        }
        capturedByteCount = 0
        captureStartedAt = Date()
        audioTask = Task { [weak self] in
            for await chunk in stream {
                guard let self, self.currentSessionID == sessionID else { return }
                self.capturedByteCount += chunk.count
                for level in Self.audioLevels(fromPCM16: chunk) {
                    self.appState.updateAudioLevel(level)
                }
                await self.sendOrBufferAudio(chunk, sessionID: sessionID)
            }
        }
    }

    /// 音频发送：ASR 会话未就绪时先缓冲，就绪后按顺序补发。
    private func sendOrBufferAudio(_ chunk: Data, sessionID: UUID) async {
        guard let session = transcriptionSession else {
            pendingAudio.append(chunk)
            // 最多保留约 30 秒（150 × 200ms），防止连接异常时无限占用内存。
            if pendingAudio.count > 150 {
                pendingAudio.removeFirst()
            }
            return
        }
        do {
            await flushPendingAudio(into: session)
            try await session.appendAudio(chunk)
        } catch {
            await handleStreamingFailure(error, sessionID: sessionID)
        }
    }

    /// 按约 100ms 的节奏补发缓冲音频，避免一次性突发导致服务端丢弃。
    private func flushPendingAudio(into session: any TranscriptionSession) async {
        guard !pendingAudio.isEmpty else { return }
        Logger.app.debug("补发缓冲音频 \(self.pendingAudio.count, privacy: .public) 块")
        while !pendingAudio.isEmpty {
            let buffered = pendingAudio.removeFirst()
            do {
                try await session.appendAudio(buffered)
            } catch {
                Logger.app.error("补发缓冲音频失败: \(String(describing: error), privacy: .public)")
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func finishRecording(sessionID: UUID?) async {
        let metadata: AudioRecordingMetadata
        let capture = audioCapture
        do {
            metadata = try await Task.detached(priority: .userInitiated) {
                try capture.finish()
            }.value
        } catch AudioCaptureError.emptyRecording {
            cleanupTranscriptionSession()
            appState.present(error: AppError(message: "没有采集到音频，请检查麦克风后重试。"))
            transition(to: .idle)
            return
        } catch {
            Logger.app.error("结束录音失败: \(String(describing: error), privacy: .public)")
            cleanupTranscriptionSession()
            appState.present(error: AppError(message: error.localizedDescription))
            transition(to: .failed)
            return
        }

        // 等待音频消费者把结尾数据送达（stream 在 finish 时结束）。
        await audioTask?.value
        audioTask = nil
        stopRequestedWhileConnecting = false

        guard let sessionID, currentSessionID == sessionID else {
            AudioCaptureService.removeRecording(at: metadata.fileURL)
            return
        }

        if let session = transcriptionSession, !streamingFailed {
            await flushPendingAudio(into: session)
        }
        appState.setInterimText("")
        transition(to: .transcribing)
        let optionsDuration = metadata.duration
        Logger.app.info("录音结束 duration=\(String(format: "%.2f", optionsDuration), privacy: .public)s，开始识别")

        do {
            let result = try await transcribeWithFallback(
                wavURL: metadata.fileURL,
                duration: metadata.duration,
                sessionID: sessionID
            )
            AudioCaptureService.removeRecording(at: metadata.fileURL)

            guard currentSessionID == sessionID else {
                Logger.app.debug("丢弃迟到的识别结果 session=\(sessionID.uuidString, privacy: .public)")
                return
            }
            transcriptionSession = nil
            updatesTask?.cancel()
            updatesTask = nil
            appState.setInterimText("")

            let rawText = settings.settings.lexicon.replacing(in: result.text)
            var finalText = settings.settings.textMode.finalize(rawText)
            var styleNotice: String?
            let style = settings.settings.activeStyle
            if style.requiresLLM {
                do {
                    let styled = try await styleProcessor(rawText, settings.settings)
                    finalText = settings.settings.textMode.finalize(styled)
                    try Task.checkCancellation()
                } catch {
                    if Task.isCancelled { return }
                    Logger.app.error("风格处理失败: \(String(describing: error), privacy: .public)")
                    styleNotice = "风格处理失败，已使用原文：\(error.localizedDescription)"
                }
            }
            var storedResult = result
            storedResult.text = finalText
            appState.setLastResult(storedResult)

            if let logID = result.logID {
                Logger.app.info("识别完成 logID=\(logID, privacy: .public)")
            }

            if settings.settings.autoInsertEnabled,
               !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transition(to: .inserting)
                let outcome = await textInserter.insert(finalText, expectedFrontmostPID: targetApplicationPID)
                targetApplicationPID = nil
                guard currentSessionID == sessionID else {
                    // 输入期间用户取消/开始新录音：不再改写状态。
                    return
                }
                switch outcome {
                case .inserted:
                    if let styleNotice {
                        appState.present(notice: "已输入到前台应用。\(styleNotice)")
                    } else {
                        appState.present(notice: "已输入到前台应用。")
                    }
                    transition(to: .idle)
                case .requiresManualCopy(let reason):
                    appState.present(error: AppError(
                        message: "识别完成，但无法自动输入：\(reason)。请复制下方结果。",
                        recovery: .copyTranscript(finalText)
                    ))
                    transition(to: .failed)
                }
            } else {
                appState.present(notice: styleNotice ?? "识别完成，可在下方复制结果。")
                transition(to: .idle)
            }
        } catch {
            AudioCaptureService.removeRecording(at: metadata.fileURL)
            transcriptionSession = nil
            updatesTask?.cancel()
            updatesTask = nil
            appState.setInterimText("")

            if error is CancellationError
                || (error as? TranscriptionError)?.isCancellation == true
                || appState.state == .cancelling {
                transition(to: .idle)
                return
            }
            Logger.app.error("识别失败: \(String(describing: error), privacy: .public)")
            appState.present(error: AppError(message: error.localizedDescription))
            transition(to: .failed)
        }
    }

    /// 先结束当前会话；失败/空结果时按优先级用剩余模型重跑整段录音。
    private func transcribeWithFallback(
        wavURL: URL,
        duration: TimeInterval,
        sessionID: UUID
    ) async throws -> TranscriptionResult {
        var attempts: [String] = []

        if !streamingFailed, let session = transcriptionSession, let profile = activeSessionProfile {
            do {
                let result = try await session.finish(recordingURL: wavURL)
                if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return result
                }
                attempts.append("\(displayName(profile))：返回空结果")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                attempts.append("\(displayName(profile))：\(error.localizedDescription)")
            }
            transcriptionSession = nil
            updatesTask?.cancel()
            updatesTask = nil
        }

        for profile in sessionProfiles where !attemptedProfileIDs.contains(profile.id) {
            try Task.checkCancellation()
            guard currentSessionID == sessionID else { throw CancellationError() }
            attemptedProfileIDs.insert(profile.id)
            do {
                let result = try await transcribeRecordedFile(
                    wavURL,
                    profile: profile,
                    duration: duration
                )
                if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Logger.app.info("备用模型「\(profile.name, privacy: .public)」转写成功")
                    return result
                }
                attempts.append("\(displayName(profile))：返回空结果")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                Logger.app.error("备用模型「\(profile.name, privacy: .public)」失败：\(String(describing: error), privacy: .public)")
                attempts.append("\(displayName(profile))：\(error.localizedDescription)")
            }
        }

        throw AllModelsFailedError(attempts: attempts)
    }

    /// 用已经写好的 WAV 重新走一个模型；火山流式按 150ms 分片补发。
    private func transcribeRecordedFile(
        _ wavURL: URL,
        profile: EndpointProfile,
        duration: TimeInterval
    ) async throws -> TranscriptionResult {
        guard let provider = providers[profile.kind] else {
            throw TranscriptionError.unsupportedProvider(profile.kind)
        }
        let options = TranscriptionOptions(
            sessionID: UUID(),
            textMode: settings.settings.textMode,
            audioDuration: duration,
            lexicon: settings.settings.lexicon
        )
        let session = try await provider.makeSession(profile: profile, options: options)

        if profile.kind == .volcengineStreaming {
            let pcm = try AudioFileConverter.pcmFromWAV(wavURL)
            var offset = 0
            while offset < pcm.count {
                try Task.checkCancellation()
                let end = min(offset + 6_400, pcm.count)
                try await session.appendAudio(pcm.subdata(in: offset..<end))
                offset = end
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        return try await session.finish(recordingURL: wavURL)
    }

    private func displayName(_ profile: EndpointProfile) -> String {
        profile.name.isEmpty ? profile.kind.displayName : profile.name
    }

    /// 在后台执行可能阻塞的音频操作，并加超时保护，避免菜单栏状态永久卡住。
    private static func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .userInitiated) {
                try operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AudioCaptureError.engineStartTimedOut
            }
            guard let result = try await group.next() else {
                throw AudioCaptureError.engineStartTimedOut
            }
            group.cancelAll()
            return result
        }
    }

    private func handleStreamingFailure(_ error: Error, sessionID: UUID) async {
        guard currentSessionID == sessionID else { return }
        Logger.app.error("流式发送失败: \(String(describing: error), privacy: .public)")

        let remaining = sessionProfiles.filter { !attemptedProfileIDs.contains($0.id) }
        cleanupTranscriptionSession()
        pendingAudio.removeAll()

        if remaining.isEmpty {
            audioCapture.cancel()
            audioTask?.cancel()
            audioTask = nil
            appState.present(error: AppError(message: error.localizedDescription))
            transition(to: .failed)
            return
        }

        // 保留录音：不中断采集，结束后用剩余模型重跑整段音频。
        streamingFailed = true
        appState.present(notice: "当前模型连接中断，结束后会自动切换备用模型。")
    }

    private func failStart(_ error: Error, sessionID: UUID) {
        guard currentSessionID == sessionID else { return }
        Logger.app.error("启动识别失败: \(String(describing: error), privacy: .public)")
        audioCapture.cancel()
        audioTask?.cancel()
        audioTask = nil
        pendingAudio.removeAll()
        cleanupTranscriptionSession()
        appState.present(error: AppError(message: error.localizedDescription))
        transition(to: .failed)
    }

    private func cleanupTranscriptionSession() {
        updatesTask?.cancel()
        updatesTask = nil
        appState.setInterimText("")
        if let session = transcriptionSession {
            transcriptionSession = nil
            Task { await session.cancel() }
        }
        activeSessionProfile = nil
        capturedByteCount = 0
    }

    // MARK: - 内部

    /// 结束一次 session：清理 session 记账。调用前状态必须已到终态。
    private func finishSession() {
        currentSessionID = nil
        appState.endSession()
    }

    /// 计算 PCM16 单声道的归一化 RMS 音量（0...1），仅用于录音浮条。
    nonisolated static func audioLevel(fromPCM16 data: Data) -> Float {
        guard data.count >= 2 else { return 0 }
        var sum: Double = 0
        var count = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let value = Double(sample) / 32_768.0
                sum += value * value
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let rms = sqrt(sum / Double(count))
        let amplified = min(1.0, rms * 6.0)
        return Float(sqrt(amplified))
    }

    /// 把 200ms 的一包音频拆成多个约 40ms 的小段音量，让浮条波形接近实时。
    nonisolated static func audioLevels(fromPCM16 data: Data, windowBytes: Int = 1_280) -> [Float] {
        guard data.count >= 2 else { return [] }
        let window = max(2, windowBytes - (windowBytes % 2))
        return data.withUnsafeBytes { raw -> [Float] in
            let samples = raw.bindMemory(to: Int16.self)
            var levels: [Float] = []
            var start = 0
            while start < samples.count {
                let end = min(start + window / 2, samples.count)
                var sum = 0.0
                for index in start..<end {
                    let value = Double(samples[index]) / 32_768.0
                    sum += value * value
                }
                let rms = sqrt(sum / Double(max(1, end - start)))
                levels.append(Float(sqrt(min(1.0, rms * 6.0))))
                start = end
            }
            return levels
        }
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

/// 所有识别模型都失败时，把每个模型的失败原因汇总给用户。
struct AllModelsFailedError: LocalizedError {
    var attempts: [String]

    var errorDescription: String? {
        guard !attempts.isEmpty else { return "所有识别模型均失败，请检查模型配置。" }
        let detail = attempts.suffix(3).joined(separator: "；")
        return "所有识别模型均失败。\(detail)"
    }
}
