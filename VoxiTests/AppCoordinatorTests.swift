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

    init(behaviour: Behaviour = .success(duration: 1.2)) {
        self.behaviour = behaviour
    }

    func start() throws -> AsyncStream<Data> {
        startCount += 1
        return AsyncStream { continuation in
            continuation.yield(Data(repeating: 1, count: 6_400))
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
}

final class FakeTranscriptionProvider: TranscriptionProvider {
    let kind: EndpointProfile.ProviderKind = .openAICompatible
    var makeSessionError: Error?
    var session = FakeTranscriptionSession()
    private(set) var makeSessionCallCount = 0

    func makeSession(profile: EndpointProfile, options: TranscriptionOptions) async throws -> any TranscriptionSession {
        makeSessionCallCount += 1
        if let makeSessionError { throw makeSessionError }
        return session
    }
}

@MainActor
final class AppCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        recordingMode: RecordingMode = .holdToTalk,
        audioCapture: StubAudioCapture = StubAudioCapture(),
        provider: FakeTranscriptionProvider = FakeTranscriptionProvider(),
        microphoneGate: MicrophoneAccessGating = StubMicrophoneGate(authorization: .granted, grants: true)
    ) -> (AppCoordinator, SettingsStore, AppState, FakeTranscriptionProvider) {
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
            providers: [provider]
        )
        return (coordinator, store, state, provider)
    }

    private func waitFor(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待状态超时，当前状态 \(appStateDescription())")
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
        XCTAssertTrue(state.noticeMessage?.contains("识别完成") ?? false)
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
}
