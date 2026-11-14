import XCTest
@testable import Voxi

/// 录音采集假实现：不访问麦克风，返回可控元数据。
final class StubAudioCapture: AudioCapturing, @unchecked Sendable {
    enum Behaviour {
        case success(duration: TimeInterval)
        case failure(Error)
        case empty
    }
    var behaviour: Behaviour
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private(set) var lastFileURL: URL?
    var chunkCount = 1

    init(behaviour: Behaviour = .success(duration: 1.2)) {
        self.behaviour = behaviour
    }

    func start() throws -> AsyncStream<Data> {
        startCount += 1
        let chunks = chunkCount
        return AsyncStream { continuation in
            for _ in 0..<chunks {
                continuation.yield(Data(repeating: 1, count: 6_400))
            }
            continuation.finish()
        }
    }

    func finish() throws -> AudioRecordingMetadata {
        finishCount += 1
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-\(UUID().uuidString).wav")
        lastFileURL = url
        switch behaviour {
        case .success(let duration):
            return AudioRecordingMetadata(
                fileURL: url,
                sampleRate: 16_000,
                channelCount: 1,
                bitsPerSample: 16,
                sampleCount: Int(duration * 16_000)
            )
        case .failure(let error):
            throw error
        case .empty:
            throw AudioCaptureError.emptyRecording
        }
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
final class FakeTranscriptionSession: TranscriptionSession {
    let updates: AsyncThrowingStream<TranscriptionUpdate, Error>
    private let continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation

    var appendedChunks: [Data] = []
    var finishCallCount = 0
    var cancelCallCount = 0
    var finishError: Error?
    var finishDelayNanoseconds: UInt64 = 0
    var resultText: String

    init(resultText: String = "识别结果") {
        self.resultText = resultText
        var streamContinuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation!
        self.updates = AsyncThrowingStream { streamContinuation = $0 }
        self.continuation = streamContinuation
    }

    func appendAudio(_ pcm16Mono16k: Data) async throws {
        appendedChunks.append(pcm16Mono16k)
    }

    func finish(recordingURL: URL) async throws -> TranscriptionResult {
        finishCallCount += 1
        if finishDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: finishDelayNanoseconds)
        }
        if let finishError { throw finishError }
        return TranscriptionResult(
            text: resultText,
            providerKind: .openAICompatible,
            sessionID: UUID(),
            audioDuration: 1.0
        )
    }

    func cancel() async {
        cancelCallCount += 1
        continuation.finish()
    }

    func emit(_ update: TranscriptionUpdate) {
        continuation.yield(update)
    }
}

@MainActor
final class FakeTranscriptionProvider: TranscriptionProvider {
    let kind: EndpointProfile.ProviderKind
    var makeSessionError: Error?
    var session: FakeTranscriptionSession
    var makeSessionDelayNanoseconds: UInt64 = 0
    private(set) var makeSessionCallCount = 0

    init(kind: EndpointProfile.ProviderKind = .openAICompatible) {
        self.kind = kind
        self.session = FakeTranscriptionSession()
    }

    func makeSession(profile: EndpointProfile, options: TranscriptionOptions) async throws -> any TranscriptionSession {
        makeSessionCallCount += 1
        if makeSessionDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: makeSessionDelayNanoseconds)
        }
        if let makeSessionError { throw makeSessionError }
        return session
    }
}

@MainActor
final class SequencedTranscriptionProvider: TranscriptionProvider {
    let kind: EndpointProfile.ProviderKind = .openAICompatible
    private var sessions: [FakeTranscriptionSession]
    private(set) var makeSessionCallCount = 0
    private(set) var requestedModels: [String] = []

    init(sessions: [FakeTranscriptionSession]) {
        self.sessions = sessions
    }

    func makeSession(profile: EndpointProfile, options: TranscriptionOptions) async throws -> any TranscriptionSession {
        makeSessionCallCount += 1
        requestedModels.append(profile.openAI.model)
        guard !sessions.isEmpty else { throw TranscriptionError.network("没有更多会话") }
        return sessions.removeFirst()
    }
}

@MainActor
final class FakeTextInserter: TextInserting {
    var outcome: TextInsertionOutcome = .inserted(via: .pasteboard)
    private(set) var insertions: [(text: String, pid: pid_t?)] = []

    func insert(_ text: String, expectedFrontmostPID: pid_t?) async -> TextInsertionOutcome {
        insertions.append((text, expectedFrontmostPID))
        return outcome
    }
}

@MainActor
final class AppCoordinatorTests: XCTestCase {
    private var textInserter: FakeTextInserter!
    private var frontmost: FakeFrontmostApp!

    override func setUp() {
        super.setUp()
        textInserter = FakeTextInserter()
        frontmost = FakeFrontmostApp()
    }

    private func makeCoordinator(
        recordingMode: RecordingMode = .holdToTalk,
        audioCapture: StubAudioCapture = StubAudioCapture(),
        provider: FakeTranscriptionProvider? = nil,
        microphoneGate: MicrophoneAccessGating = StubMicrophoneGate(authorization: .granted, grants: true),
        styleProcessor: @escaping (String, VoxiSettings) async throws -> String = { text, _ in text }
    ) -> (AppCoordinator, SettingsStore, AppState, FakeTranscriptionProvider) {
        let provider = provider ?? FakeTranscriptionProvider()
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        store.settings.recordingMode = recordingMode
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: microphoneGate,
            audioCapture: audioCapture,
            providers: [provider],
            textInserter: textInserter,
            frontmostProvider: frontmost,
            styleProcessor: styleProcessor
        )
        return (coordinator, store, state, provider)
    }

    private func waitFor(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待状态超时")
    }

    private func appStateDescription() -> String { "" }

    // MARK: - session 唯一性

    func testStartRecordingCreatesSingleSession() async {
        let (coordinator, _, state, provider) = makeCoordinator()

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        let firstSession = state.sessionID
        XCTAssertNotNil(firstSession)
        XCTAssertEqual(provider.makeSessionCallCount, 1)

        coordinator.startRecording()
        XCTAssertEqual(state.sessionID, firstSession, "重复开始不得创建新 session")
        XCTAssertEqual(state.state, .recording)
    }

    func testStopRecordingReturnsToIdleAndKeepsResult() async {
        let (coordinator, _, state, provider) = makeCoordinator()
        provider.session.resultText = "你好，世界"

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor { state.state == .idle }

        XCTAssertEqual(provider.session.finishCallCount, 1)
        XCTAssertEqual(state.lastResult?.text, "你好，世界")
        XCTAssertNil(state.sessionID)
        XCTAssertNil(coordinator.currentSessionID)
    }

    func testStopTwiceOnlyFinishesOnce() async {
        let (coordinator, _, state, provider) = makeCoordinator()
        coordinator.startRecording()
        await waitFor { state.state == .recording }

        coordinator.stopRecording()
        coordinator.stopRecording()
        await waitFor { state.state == .idle }

        XCTAssertEqual(provider.session.finishCallCount, 1)
    }

    func testStopWithoutStartIsNoOp() async {
        let (coordinator, _, state, _) = makeCoordinator()
        coordinator.stopRecording()
        XCTAssertEqual(state.state, .idle)
        XCTAssertNil(state.sessionID)
    }

    // MARK: - 取消

    func testCancelClearsSessionAndReturnsToIdle() async {
        let (coordinator, _, state, provider) = makeCoordinator()
        coordinator.startRecording()
        await waitFor { state.state == .recording }

        coordinator.cancelCurrentSession()
        XCTAssertEqual(state.state, .idle)
        XCTAssertNil(state.sessionID)
        XCTAssertNil(coordinator.currentSessionID)

        await waitFor { provider.session.cancelCallCount == 1 }
    }

    func testCancelWhileFinalizingDiscardsLateResult() async {
        let (coordinator, _, state, provider) = makeCoordinator()
        provider.session.finishDelayNanoseconds = 150_000_000

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor { state.state == .transcribing }
        coordinator.cancelCurrentSession()
        XCTAssertEqual(state.state, .idle)

        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(state.state, .idle, "取消后迟到的最终结果不得改写状态")
        XCTAssertNil(state.lastResult, "取消后不得保留/插入结果")
    }

    func testCancelWhenIdleIsNoOp() {
        let (coordinator, _, state, _) = makeCoordinator()
        coordinator.cancelCurrentSession()
        XCTAssertEqual(state.state, .idle)
    }

    // MARK: - 快捷键映射

    func testHoldToTalkShortcutMapping() async {
        let (coordinator, _, state, _) = makeCoordinator(recordingMode: .holdToTalk)

        coordinator.handleShortcutPress()
        await waitFor { state.state == .recording }
        coordinator.handleShortcutRelease()
        await waitFor { state.state == .idle }

        // 松开事件丢失后重复 press 不得创建第二个 session
        coordinator.handleShortcutPress()
        await waitFor { state.state == .recording }
        let session = state.sessionID
        coordinator.handleShortcutPress()
        XCTAssertEqual(state.sessionID, session)
        coordinator.handleShortcutRelease()
        await waitFor { state.state == .idle }
    }

    func testToggleShortcutMapping() async {
        let (coordinator, _, state, _) = makeCoordinator(recordingMode: .toggle)

        coordinator.handleShortcutPress()
        await waitFor { state.state == .recording }
        coordinator.handleShortcutRelease()
        XCTAssertEqual(state.state, .recording, "切换模式松开不结束录音")
        coordinator.handleShortcutPress()
        await waitFor { state.state == .idle }
    }

    func testMenuToggleUsesStateMachine() async {
        let (coordinator, _, state, _) = makeCoordinator()
        coordinator.toggleFromMenu()
        await waitFor { state.state == .recording }
        coordinator.toggleFromMenu()
        await waitFor { state.state == .idle }
    }

    // MARK: - 权限

    func testDeniedMicrophoneFailsWithRecoveryAction() {
        let (coordinator, _, state, _) = makeCoordinator(
            microphoneGate: StubMicrophoneGate(authorization: .denied, grants: false)
        )

        coordinator.startRecording()

        XCTAssertEqual(state.state, .failed)
        XCTAssertEqual(state.error?.recovery, .openMicrophoneSettings)
        XCTAssertNil(state.sessionID)
    }

    func testNotDeterminedRequestsPermissionThenRecords() async {
        let (coordinator, _, state, _) = makeCoordinator(
            microphoneGate: StubMicrophoneGate(authorization: .notDetermined, grants: true)
        )

        coordinator.startRecording()
        XCTAssertEqual(state.state, .requestingPermission)

        await waitFor { state.state == .recording }
    }

    func testCancellingWhileRequestingPermissionStopsLateGrant() async {
        let (coordinator, _, state, _) = makeCoordinator(
            microphoneGate: StubMicrophoneGate(
                authorization: .notDetermined,
                grants: true,
                delayNanoseconds: 120_000_000
            )
        )

        coordinator.startRecording()
        XCTAssertEqual(state.state, .requestingPermission)
        coordinator.cancelCurrentSession()
        XCTAssertEqual(state.state, .idle)

        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(state.state, .idle, "取消后迟到的授权结果不得重新开始录音")
        XCTAssertNil(state.sessionID)
    }

    func testReleasingShortcutDuringPermissionPromptCancelsSession() async {
        let (coordinator, _, state, _) = makeCoordinator(
            microphoneGate: StubMicrophoneGate(
                authorization: .notDetermined,
                grants: true,
                delayNanoseconds: 80_000_000
            )
        )

        coordinator.handleShortcutPress()
        XCTAssertEqual(state.state, .requestingPermission)
        coordinator.handleShortcutRelease()
        XCTAssertEqual(state.state, .idle, "权限弹窗期间松键必须取消本次录音")

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(state.state, .idle, "迟到的授权不得开始录音")
        XCTAssertNil(state.sessionID)
    }

    func testPermissionGrantAfterLostReleaseDoesNotStartRecording() async {
        let (coordinator, _, state, _) = makeCoordinator(
            microphoneGate: StubMicrophoneGate(
                authorization: .notDetermined,
                grants: true,
                delayNanoseconds: 60_000_000
            )
        )

        coordinator.handleShortcutPress()
        XCTAssertEqual(state.state, .requestingPermission)
        coordinator.handleApplicationResignActive()

        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertNotEqual(state.state, .recording, "松键丢失时不得进入永久录音")
    }

    // MARK: - 配置错误

    func testMissingProfileFailsCleanly() {
        let (coordinator, store, state, _) = makeCoordinator()
        store.settings.profiles = []
        store.settings.activeProfileID = nil

        coordinator.startRecording()
        XCTAssertEqual(state.state, .failed)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertNil(state.sessionID)
    }

    func testFailedStateCanStartAgain() async {
        let (coordinator, store, state, _) = makeCoordinator()
        store.settings.profiles = []
        coordinator.startRecording()
        XCTAssertEqual(state.state, .failed)

        store.settings.profiles = [.defaultOpenAIProfile()]
        coordinator.startRecording()
        await waitFor { state.state == .recording }
        XCTAssertNotNil(state.sessionID)
    }

    func testProviderSetupFailureSurfacesError() async {
        let provider = FakeTranscriptionProvider()
        provider.makeSessionError = TranscriptionError.missingCredential
        let (coordinator, _, state, _) = makeCoordinator(provider: provider)

        coordinator.startRecording()
        await waitFor { state.state == .failed }
        XCTAssertTrue(state.errorMessage?.contains("API Key") ?? false)
        XCTAssertNil(state.sessionID)
    }

    func testProviderFinishFailureIsRecoverable() async {
        let provider = FakeTranscriptionProvider()
        provider.session.finishError = TranscriptionError.serverError(status: 500, detail: "boom")
        let (coordinator, _, state, _) = makeCoordinator(provider: provider)

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor { state.state == .failed }
        XCTAssertTrue(state.errorMessage?.contains("500") ?? false)

        coordinator.startRecording()
        await waitFor { state.state == .recording }
    }

    // MARK: - 音频

    func testAudioCaptureLifecycleOnStop() async {
        let audio = StubAudioCapture(behaviour: .success(duration: 2.5))
        let (coordinator, _, state, _) = makeCoordinator(audioCapture: audio)

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        XCTAssertEqual(audio.startCount, 1)

        coordinator.stopRecording()
        await waitFor { state.state == .idle }
        XCTAssertEqual(audio.finishCount, 1)
        XCTAssertNotNil(state.lastResult)
    }

    func testEmptyRecordingReturnsToIdleWithError() async {
        let audio = StubAudioCapture(behaviour: .empty)
        let (coordinator, _, state, _) = makeCoordinator(audioCapture: audio)

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor { state.state == .idle }

        XCTAssertNotNil(state.errorMessage)
    }

    func testCancelDuringRecordingStopsCapture() async {
        let audio = StubAudioCapture()
        let (coordinator, _, state, _) = makeCoordinator(audioCapture: audio)

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.cancelCurrentSession()

        XCTAssertEqual(audio.cancelCount, 1)
        XCTAssertEqual(state.state, .idle)
        XCTAssertNil(state.sessionID)
    }

    // MARK: - UI 辅助

    func testVolcengineFlowShowsConnectingBeforeRecording() async {
        let provider = FakeTranscriptionProvider(kind: .volcengineStreaming)
        provider.makeSessionDelayNanoseconds = 120_000_000
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        store.settings.profiles = [.defaultVolcengineProfile()]
        store.settings.activeProfileID = store.settings.profiles.first?.id
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: StubMicrophoneGate(authorization: .granted, grants: true),
            audioCapture: StubAudioCapture(),
            providers: [provider],
            textInserter: textInserter,
            frontmostProvider: frontmost
        )

        coordinator.startRecording()
        XCTAssertEqual(state.state, .connecting, "火山必须先进入连接状态")
        await waitFor { state.state == .recording }
    }

    func testReleasingShortcutWhileConnectingFinishesInsteadOfDiscarding() async {
        let provider = FakeTranscriptionProvider(kind: .volcengineStreaming)
        provider.makeSessionDelayNanoseconds = 150_000_000
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        store.settings.profiles = [.defaultVolcengineProfile()]
        store.settings.activeProfileID = store.settings.profiles.first?.id
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: StubMicrophoneGate(authorization: .granted, grants: true),
            audioCapture: StubAudioCapture(),
            providers: [provider],
            textInserter: textInserter,
            frontmostProvider: frontmost
        )

        coordinator.handleShortcutPress()
        await waitFor { state.state == .connecting }
        coordinator.handleShortcutRelease()
        // 连接期间松键：不取消，等连接完成后收尾并识别。
        await waitFor(timeout: 3) { state.state == .idle }
        XCTAssertEqual(provider.session.finishCallCount, 1)
        XCTAssertEqual(provider.session.cancelCallCount, 0)
        XCTAssertNil(state.sessionID)
    }

    func testBufferedAudioIsSentAfterSessionBecomesReady() async {
        let audio = StubAudioCapture()
        audio.chunkCount = 3
        let provider = FakeTranscriptionProvider(kind: .volcengineStreaming)
        provider.makeSessionDelayNanoseconds = 150_000_000
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        store.settings.profiles = [.defaultVolcengineProfile()]
        store.settings.activeProfileID = store.settings.profiles.first?.id
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: StubMicrophoneGate(authorization: .granted, grants: true),
            audioCapture: audio,
            providers: [provider],
            textInserter: textInserter,
            frontmostProvider: frontmost
        )

        coordinator.startRecording()
        await waitFor(timeout: 3) { provider.session.appendedChunks.count >= 3 }
        XCTAssertEqual(provider.session.appendedChunks.count, 3, "连接期间缓冲的音频必须在就绪后补发")
        coordinator.stopRecording()
        await waitFor { state.state == .idle }
        XCTAssertEqual(provider.session.finishCallCount, 1)
    }

    func testInterimUpdatesOnlyAffectPreviewAndNeverResult() async {
        let provider = FakeTranscriptionProvider()
        let (coordinator, _, state, _) = makeCoordinator(provider: provider)

        coordinator.startRecording()
        await waitFor { state.state == .recording }

        provider.session.emit(.interim("临时文本一"))
        await waitFor { state.interimText == "临时文本一" }
        XCTAssertNil(state.lastResult, "临时结果不得进入最终结果")

        provider.session.emit(.interim("临时文本一，更多"))
        await waitFor { state.interimText == "临时文本一，更多" }

        coordinator.stopRecording()
        await waitFor { state.state == .idle }
        XCTAssertEqual(state.interimText, "", "结束流程后清空预览")
        XCTAssertEqual(state.lastResult?.text, "识别结果")
    }

    func testAutoInsertUsesFinalizedTextAndCapturedPID() async {
        let provider = FakeTranscriptionProvider()
        provider.session.resultText = "你好。"
        let (coordinator, store, state, _) = makeCoordinator(provider: provider)
        store.settings.textMode = TextMode(
            language: .simplifiedChinese,
            prompt: "",
            addPunctuation: false,
            newlineBehavior: .trailingNewline
        )

        coordinator.handleShortcutPress()
        await waitFor { state.state == .recording }
        coordinator.handleShortcutRelease()
        await waitFor { state.state == .idle }

        XCTAssertEqual(textInserter.insertions.count, 1)
        XCTAssertEqual(textInserter.insertions.first?.text, "你好\n")
        XCTAssertEqual(textInserter.insertions.first?.pid, 777, "应记录快捷键触发时的前台 PID")
        XCTAssertEqual(state.lastResult?.text, "你好\n")
        XCTAssertTrue(state.noticeMessage?.contains("已输入") ?? false)
    }

    func testMenuTriggeredInsertionCapturesFrontmostPID() async {
        let (coordinator, _, state, _) = makeCoordinator()

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor { state.state == .idle }

        XCTAssertEqual(textInserter.insertions.count, 1)
        XCTAssertEqual(textInserter.insertions.first?.pid, 777, "菜单触发的录音也应锁定开始时的前台 PID")
    }

    func testAutoInsertDisabledKeepsResultForManualCopy() async {
        let (coordinator, store, state, _) = makeCoordinator()
        store.settings.autoInsertEnabled = false

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor { state.state == .idle }

        XCTAssertTrue(textInserter.insertions.isEmpty)
        XCTAssertNotNil(state.lastResult)
        XCTAssertTrue(state.noticeMessage?.contains("复制") ?? false)
    }

    func testInsertionFailureOffersCopyFallback() async {
        let provider = FakeTranscriptionProvider()
        provider.session.resultText = "保留的文本"
        let (coordinator, _, state, _) = makeCoordinator(provider: provider)
        textInserter.outcome = .requiresManualCopy(reason: "前台应用已切换")

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor { state.state == .failed }

        XCTAssertEqual(state.lastResult?.text, "保留的文本")
        XCTAssertEqual(state.error?.recovery, .copyTranscript("保留的文本"))
        XCTAssertTrue(state.errorMessage?.contains("前台应用已切换") ?? false)
    }

    func testMenuBarElapsedFormatting() {
        XCTAssertEqual(MenuBarView.formatted(elapsed: 0), "0:00")
        XCTAssertEqual(MenuBarView.formatted(elapsed: 65), "1:05")
        XCTAssertEqual(MenuBarView.formatted(elapsed: -3), "0:00")
    }

    func testErrorRecoveryTitles() {
        XCTAssertEqual(
            MenuBarView.recoveryTitle(.openMicrophoneSettings),
            "打开麦克风设置…"
        )
        XCTAssertEqual(
            MenuBarView.recoveryTitle(.copyTranscript("hi")),
            "复制识别结果"
        )
    }

    // MARK: - 多模型自动回退

    func testFallsBackToNextModelWhenSessionCreationFails() async {
        let failing = FakeTranscriptionProvider(kind: .volcengineStreaming)
        failing.makeSessionError = TranscriptionError.network("连接失败")
        let working = FakeTranscriptionProvider(kind: .openAICompatible)
        let capture = StubAudioCapture()
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let multiStore = SettingsStore(userDefaults: defaults, storageKey: "settings")
        multiStore.settings.profiles = [.defaultVolcengineProfile(), .defaultOpenAIProfile()]
        let multiState = AppState()
        let multi = AppCoordinator(
            settings: multiStore,
            appState: multiState,
            microphoneGate: StubMicrophoneGate(authorization: .granted, grants: true),
            audioCapture: capture,
            providers: [failing, working],
            textInserter: textInserter,
            frontmostProvider: frontmost
        )

        multi.startRecording()
        await waitFor { multiState.state == .recording }
        XCTAssertEqual(failing.makeSessionCallCount, 1)
        XCTAssertEqual(working.makeSessionCallCount, 1)
        XCTAssertEqual(multiState.state, .recording)
    }

    func testFallsBackToNextProfileWhenFinishFails() async {
        let failingSession = FakeTranscriptionSession()
        failingSession.finishError = TranscriptionError.serverError(status: 500, detail: "boom")
        let backupSession = FakeTranscriptionSession(resultText: "备用模型结果")
        let provider = SequencedTranscriptionProvider(sessions: [failingSession, backupSession])

        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        store.settings.profiles = [.defaultOpenAIProfile(), .defaultOpenAIProfile()]
        store.settings.autoInsertEnabled = false
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: StubMicrophoneGate(authorization: .granted, grants: true),
            audioCapture: StubAudioCapture(),
            providers: [provider],
            textInserter: textInserter,
            frontmostProvider: frontmost
        )

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor(timeout: 4) { state.state == .idle || state.state == .failed }

        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(state.lastResult?.text, "备用模型结果")
        XCTAssertGreaterThan(backupSession.finishCallCount, 0)
        XCTAssertEqual(provider.makeSessionCallCount, 2)
    }

    func testLexiconAliasIsAppliedToFinalResult() async {
        let provider = FakeTranscriptionProvider()
        provider.session.resultText = "voxy 你好"
        let (coordinator, store, state, _) = makeCoordinator(provider: provider)
        store.settings.lexicon.add(term: "Voxi", aliases: ["voxy"])
        store.settings.autoInsertEnabled = false

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor(timeout: 4) { state.state == .idle }

        XCTAssertEqual(state.lastResult?.text, "Voxi 你好")
    }

    func testStyleProcessorRewritesFinalResult() async {
        let provider = FakeTranscriptionProvider()
        provider.session.resultText = "原始文本"
        let (coordinator, store, state, _) = makeCoordinator(
            provider: provider,
            styleProcessor: { text, _ in "【\(text)】" }
        )
        store.settings.selectedStyleID = TranscriptionStyle.simple.id
        store.settings.autoInsertEnabled = false

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor(timeout: 4) { state.state == .idle }

        XCTAssertEqual(state.lastResult?.text, "【原始文本】")
    }

    func testStyleFailureFallsBackToRawText() async {
        let provider = FakeTranscriptionProvider()
        provider.session.resultText = "原始文本"
        let (coordinator, store, state, _) = makeCoordinator(
            provider: provider,
            styleProcessor: { _, _ in throw StyleProcessingError.emptyResult }
        )
        store.settings.selectedStyleID = TranscriptionStyle.simple.id
        store.settings.autoInsertEnabled = false

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor(timeout: 4) { state.state == .idle }

        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(state.lastResult?.text, "原始文本")
        XCTAssertTrue(state.noticeMessage?.contains("风格处理失败") ?? false)
    }

    func testFallsBackAcrossModelsWithinSameProfile() async {
        let failing = FakeTranscriptionSession()
        failing.finishError = TranscriptionError.serverError(status: 500, detail: "boom")
        let backup = FakeTranscriptionSession(resultText: "第二个模型结果")
        let provider = SequencedTranscriptionProvider(sessions: [failing, backup])

        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.openAI.enabledModels = ["m1", "m2"]
        profile.openAI.model = "m1"
        store.settings.profiles = [profile]
        store.settings.autoInsertEnabled = false
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: StubMicrophoneGate(authorization: .granted, grants: true),
            audioCapture: StubAudioCapture(),
            providers: [provider],
            textInserter: textInserter,
            frontmostProvider: frontmost
        )

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor(timeout: 4) { state.state == .idle || state.state == .failed }

        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(state.lastResult?.text, "第二个模型结果")
        XCTAssertEqual(provider.requestedModels, ["m1", "m2"])
    }

    func testSuccessfulRecordingRecordsUsageWithoutTranscript() async {
        let provider = FakeTranscriptionProvider()
        provider.session.resultText = "你好世界"
        let (coordinator, store, state, _) = makeCoordinator(provider: provider)

        coordinator.startRecording()
        await waitFor { state.state == .recording }
        coordinator.stopRecording()
        await waitFor(timeout: 4) { state.state == .idle }

        XCTAssertEqual(store.settings.usage.totalSessions, 1)
        XCTAssertEqual(store.settings.usage.totalCharacters, 4)
        XCTAssertEqual(store.settings.usage.totalSeconds, 1.2, accuracy: 0.01)
        XCTAssertNil(store.settings.usage.daily.values.first { $0.characters == 0 })
    }
}
