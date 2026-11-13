import XCTest
@testable import Voxi

final class RecordingStateTests: XCTestCase {
    func testIdleAcceptsStartStates() {
        XCTAssertTrue(RecordingState.idle.canTransition(to: .requestingPermission))
        XCTAssertTrue(RecordingState.idle.canTransition(to: .connecting))
        XCTAssertTrue(RecordingState.idle.canTransition(to: .recording))
    }

    func testOpenAIFlowTransitions() {
        let flow: [RecordingState] = [
            .idle, .requestingPermission, .recording,
            .finalizingAudio, .transcribing, .inserting, .idle
        ]
        for (from, to) in zip(flow, flow.dropFirst()) {
            XCTAssertTrue(from.canTransition(to: to), "\(from) -> \(to) 应当合法")
        }
    }

    func testVolcengineFlowTransitions() {
        let flow: [RecordingState] = [
            .idle, .requestingPermission, .connecting, .recording,
            .finalizingAudio, .transcribing, .inserting, .idle
        ]
        for (from, to) in zip(flow, flow.dropFirst()) {
            XCTAssertTrue(from.canTransition(to: to), "\(from) -> \(to) 应当合法")
        }
    }

    func testIllegalTransitions() {
        // 未开始录音不能直接进入识别/输入状态
        XCTAssertFalse(RecordingState.idle.canTransition(to: .transcribing))
        XCTAssertFalse(RecordingState.idle.canTransition(to: .inserting))
        XCTAssertFalse(RecordingState.idle.canTransition(to: .cancelling))
        // 录音中不能跳过整理直接识别
        XCTAssertFalse(RecordingState.recording.canTransition(to: .transcribing))
        // 输入完成后不能凭空回到录音
        XCTAssertFalse(RecordingState.inserting.canTransition(to: .recording))
        // 失败状态必须先回到 idle
        XCTAssertFalse(RecordingState.failed.canTransition(to: .recording))
        XCTAssertTrue(RecordingState.failed.canTransition(to: .idle))
    }

    func testEveryProcessingStateCanCancel() {
        for state in RecordingState.allCases where state.isBusy && state != .cancelling {
            XCTAssertTrue(state.allowedNextStates.contains(.cancelling),
                          "\(state) 应当允许取消")
        }
    }

    func testBusyFlag() {
        XCTAssertFalse(RecordingState.idle.isBusy)
        XCTAssertFalse(RecordingState.failed.isBusy)
        for state in [RecordingState.requestingPermission, .connecting, .recording,
                      .finalizingAudio, .transcribing, .inserting, .cancelling] {
            XCTAssertTrue(state.isBusy, "\(state) 应当视为处理中")
        }
    }

    func testAwaitingResultFlag() {
        XCTAssertTrue(RecordingState.finalizingAudio.isAwaitingResult)
        XCTAssertTrue(RecordingState.transcribing.isAwaitingResult)
        XCTAssertFalse(RecordingState.recording.isAwaitingResult)
        XCTAssertFalse(RecordingState.idle.isAwaitingResult)
    }
}

final class ShortcutConfigurationTests: XCTestCase {
    func testDefaultIsValid() {
        XCTAssertTrue(ShortcutConfiguration.default.isValid)
        XCTAssertEqual(ShortcutConfiguration.default.displayString, "⌃⌥Space")
    }

    func testModifierOnlyConfigurationIsInvalid() {
        let config = ShortcutConfiguration(keyCode: 0x31, carbonModifiers: 0)
        XCTAssertFalse(config.isValid)
    }

    func testUnknownKeyCodeRendersQuestionMark() {
        let config = ShortcutConfiguration(keyCode: 0xFF, carbonModifiers: ShortcutConfiguration.Modifier.command.rawValue)
        XCTAssertEqual(config.displayString, "⌘?")
        XCTAssertFalse(config.isValid)
    }

    func testDisplayStringOrdering() {
        let config = ShortcutConfiguration(
            keyCode: 0x00, // A
            carbonModifiers: ShortcutConfiguration.Modifier.command.rawValue
                | ShortcutConfiguration.Modifier.shift.rawValue
        )
        XCTAssertEqual(config.displayString, "⇧⌘A")
    }
}
