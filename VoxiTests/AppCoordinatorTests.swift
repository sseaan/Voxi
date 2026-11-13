import XCTest
@testable import Voxi

/// 录音采集假实现：不访问麦克风，返回可控元数据。
final class StubAudioCapture: AudioCapturing {
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

@MainActor
final class AppCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        recordingMode: RecordingMode = .holdToTalk,
        audioCapture: StubAudioCapture = StubAudioCapture()
    ) -> (AppCoordinator, SettingsStore, AppState) {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        store.settings.recordingMode = recordingMode
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: StubMicrophoneGate(authorization: .granted, grants: true),
            audioCapture: audioCapture
        )
        return (coordinator, store, state)
    }

    func testStartRecordingCreatesSingleSession() {
        let (coordinator, _, state) = makeCoordinator()

        coordinator.startRecording()
        let firstSession = state.sessionID
        XCTAssertNotNil(firstSession)
        XCTAssertEqual(state.state, .recording)

        coordinator.startRecording()
        XCTAssertEqual(state.sessionID, firstSession, "重复开始不得创建新 session")
        XCTAssertEqual(state.state, .recording)
    }

    func testStopRecordingReturnsToIdleAndClearsSession() {
        let (coordinator, _, state) = makeCoordinator()
        coordinator.startRecording()
        coordinator.stopRecording()

        XCTAssertEqual(state.state, .idle)
        XCTAssertNil(state.sessionID)
        XCTAssertNil(coordinator.currentSessionID)
    }

    func testStopTwiceIsNoOp() {
        let (coordinator, _, state) = makeCoordinator()
        coordinator.startRecording()
        coordinator.stopRecording()
        coordinator.stopRecording()
        XCTAssertEqual(state.state, .idle)
    }

    func testStopWithoutStartIsNoOp() {
        let (coordinator, _, state) = makeCoordinator()
        coordinator.stopRecording()
        XCTAssertEqual(state.state, .idle)
        XCTAssertNil(state.sessionID)
    }

    func testCancelClearsSessionAndReturnsToIdle() {
        let (coordinator, _, state) = makeCoordinator()
        coordinator.startRecording()
        coordinator.cancelCurrentSession()
        XCTAssertEqual(state.state, .idle)
        XCTAssertNil(state.sessionID)
        XCTAssertNil(coordinator.currentSessionID)
    }

    func testCancelWhenIdleIsNoOp() {
        let (coordinator, _, state) = makeCoordinator()
        coordinator.cancelCurrentSession()
        XCTAssertEqual(state.state, .idle)
    }

    func testHoldToTalkShortcutMapping() {
        let (coordinator, _, state) = makeCoordinator(recordingMode: .holdToTalk)

        coordinator.handleShortcutPress()
        XCTAssertEqual(state.state, .recording)
        coordinator.handleShortcutRelease()
        XCTAssertEqual(state.state, .idle)

        // 松开事件丢失后重复 press 不得创建第二个 session
        coordinator.handleShortcutPress()
        let session = state.sessionID
        coordinator.handleShortcutPress()
        XCTAssertEqual(state.sessionID, session)
        coordinator.handleShortcutRelease()
        XCTAssertEqual(state.state, .idle)
    }

    func testToggleShortcutMapping() {
        let (coordinator, _, state) = makeCoordinator(recordingMode: .toggle)

        coordinator.handleShortcutPress()
        XCTAssertEqual(state.state, .recording)
        // 切换模式下松开不结束录音
        coordinator.handleShortcutRelease()
        XCTAssertEqual(state.state, .recording)
        coordinator.handleShortcutPress()
        XCTAssertEqual(state.state, .idle)
    }

    func testMissingProfileFailsCleanly() {
        let (coordinator, store, state) = makeCoordinator()
        store.settings.profiles = []
        store.settings.activeProfileID = nil

        coordinator.startRecording()
        XCTAssertEqual(state.state, .failed)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertNil(state.sessionID)
    }

    func testFailedStateCanStartAgain() {
        let (coordinator, store, state) = makeCoordinator()
        store.settings.profiles = []
        coordinator.startRecording()
        XCTAssertEqual(state.state, .failed)

        store.settings.profiles = [.defaultOpenAIProfile()]
        coordinator.startRecording()
        XCTAssertEqual(state.state, .recording)
        XCTAssertNotNil(state.sessionID)
    }

    func testMenuToggleUsesStateMachine() {
        let (coordinator, _, state) = makeCoordinator()
        coordinator.toggleFromMenu()
        XCTAssertEqual(state.state, .recording)
        coordinator.toggleFromMenu()
        XCTAssertEqual(state.state, .idle)
    }

    func testReleasingShortcutDuringPermissionPromptCancelsSession() async {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: StubMicrophoneGate(
                authorization: .notDetermined,
                grants: true,
                delayNanoseconds: 80_000_000
            ),
            audioCapture: StubAudioCapture()
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
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: StubMicrophoneGate(
                authorization: .notDetermined,
                grants: true,
                delayNanoseconds: 60_000_000
            ),
            audioCapture: StubAudioCapture()
        )

        coordinator.handleShortcutPress()
        XCTAssertEqual(state.state, .requestingPermission)
        // 只有 keyDown 没有对应 keyUp，但内部标记已复位（模拟松键丢失）
        coordinator.handleApplicationResignActive()

        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertNotEqual(state.state, .recording, "松键丢失时不得进入永久录音")
    }

    func testDeniedMicrophoneFailsWithRecoveryAction() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: StubMicrophoneGate(authorization: .denied, grants: false),
            audioCapture: StubAudioCapture()
        )

        coordinator.startRecording()

        XCTAssertEqual(state.state, .failed)
        XCTAssertEqual(state.error?.recovery, .openMicrophoneSettings)
        XCTAssertNil(state.sessionID)
    }

    func testNotDeterminedRequestsPermissionThenRecords() async {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: StubMicrophoneGate(authorization: .notDetermined, grants: true),
            audioCapture: StubAudioCapture()
        )

        coordinator.startRecording()
        XCTAssertEqual(state.state, .requestingPermission)

        await waitFor { state.state == .recording }
        XCTAssertEqual(state.state, .recording)
    }

    func testCancellingWhileRequestingPermissionStopsLateGrant() async {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        let state = AppState()
        let coordinator = AppCoordinator(
            settings: store,
            appState: state,
            microphoneGate: StubMicrophoneGate(authorization: .notDetermined, grants: true),
            audioCapture: StubAudioCapture()
        )

        coordinator.startRecording()
        XCTAssertEqual(state.state, .requestingPermission)
        coordinator.cancelCurrentSession()
        XCTAssertEqual(state.state, .idle)

        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(state.state, .idle, "取消后迟到的授权结果不得重新开始录音")
        XCTAssertNil(state.sessionID)
    }

    private func waitFor(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待状态超时")
    }

    func testAudioCaptureLifecycleOnStop() {
        let audio = StubAudioCapture(behaviour: .success(duration: 2.5))
        let (coordinator, _, state) = makeCoordinator(audioCapture: audio)

        coordinator.startRecording()
        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(state.state, .recording)

        coordinator.stopRecording()
        XCTAssertEqual(audio.finishCount, 1)
        XCTAssertEqual(state.state, .idle)
        XCTAssertTrue(state.noticeMessage?.contains("2.5") ?? false)
    }

    func testEmptyRecordingReturnsToIdleWithError() {
        let audio = StubAudioCapture(behaviour: .empty)
        let (coordinator, _, state) = makeCoordinator(audioCapture: audio)

        coordinator.startRecording()
        coordinator.stopRecording()

        XCTAssertEqual(state.state, .idle)
        XCTAssertNotNil(state.errorMessage)
    }

    func testCancelDuringRecordingStopsCapture() {
        let audio = StubAudioCapture()
        let (coordinator, _, state) = makeCoordinator(audioCapture: audio)

        coordinator.startRecording()
        coordinator.cancelCurrentSession()

        XCTAssertEqual(audio.cancelCount, 1)
        XCTAssertEqual(state.state, .idle)
        XCTAssertNil(state.sessionID)
    }

    func testMenuBarElapsedFormatting() {
        XCTAssertEqual(MenuBarView.formatted(elapsed: 0), "0:00")
        XCTAssertEqual(MenuBarView.formatted(elapsed: 65), "1:05")
        XCTAssertEqual(MenuBarView.formatted(elapsed: -3), "0:00")
    }
}
