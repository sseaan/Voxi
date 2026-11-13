import XCTest
@testable import Voxi

@MainActor
final class AppCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        recordingMode: RecordingMode = .holdToTalk
    ) -> (AppCoordinator, SettingsStore, AppState) {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")
        store.settings.recordingMode = recordingMode
        let state = AppState()
        let coordinator = AppCoordinator(settings: store, appState: state)
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

    func testMenuBarElapsedFormatting() {
        XCTAssertEqual(MenuBarView.formatted(elapsed: 0), "0:00")
        XCTAssertEqual(MenuBarView.formatted(elapsed: 65), "1:05")
        XCTAssertEqual(MenuBarView.formatted(elapsed: -3), "0:00")
    }
}
