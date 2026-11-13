import AppKit
import XCTest
@testable import Voxi

final class ShortcutEventMapperTests: XCTestCase {
    func testHoldToTalkMapping() {
        XCTAssertEqual(
            ShortcutEventMapper.action(for: .keyDown, mode: .holdToTalk, isRecording: false),
            .start
        )
        XCTAssertEqual(
            ShortcutEventMapper.action(for: .keyDown, mode: .holdToTalk, isRecording: true),
            .ignore,
            "重复 keyDown 不得重复开始"
        )
        XCTAssertEqual(
            ShortcutEventMapper.action(for: .keyUp, mode: .holdToTalk, isRecording: true),
            .stop
        )
        XCTAssertEqual(
            ShortcutEventMapper.action(for: .keyUp, mode: .holdToTalk, isRecording: false),
            .ignore
        )
        XCTAssertEqual(
            ShortcutEventMapper.action(for: .lostFocus, mode: .holdToTalk, isRecording: true),
            .stop,
            "失焦时必须停止录音，避免永久录音"
        )
    }

    func testToggleMapping() {
        XCTAssertEqual(
            ShortcutEventMapper.action(for: .keyDown, mode: .toggle, isRecording: false),
            .start
        )
        XCTAssertEqual(
            ShortcutEventMapper.action(for: .keyDown, mode: .toggle, isRecording: true),
            .stop
        )
        XCTAssertEqual(
            ShortcutEventMapper.action(for: .keyUp, mode: .toggle, isRecording: true),
            .ignore,
            "切换模式松开不结束录音"
        )
        XCTAssertEqual(
            ShortcutEventMapper.action(for: .lostFocus, mode: .toggle, isRecording: true),
            .ignore,
            "切换模式失焦不打断录音"
        )
    }

    func testCarbonModifierConversion() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let carbon = ShortcutRecorderNSView.carbonModifiers(from: flags)
        let expected = ShortcutConfiguration.Modifier.command.rawValue
            | ShortcutConfiguration.Modifier.shift.rawValue
            | ShortcutConfiguration.Modifier.option.rawValue
            | ShortcutConfiguration.Modifier.control.rawValue
        XCTAssertEqual(carbon, expected)
        XCTAssertEqual(ShortcutRecorderNSView.carbonModifiers(from: []), 0)
        XCTAssertEqual(ShortcutRecorderNSView.carbonModifiers(from: [.capsLock]), 0)
    }
}

@MainActor
final class ShortcutRegistrationTests: XCTestCase {
    func testInvalidCombinationIsRejectedBeforeTouchingCarbon() {
        let service = ShortcutService()
        let invalid = ShortcutConfiguration(keyCode: 0x31, carbonModifiers: 0)
        XCTAssertThrowsError(try service.register(invalid)) { error in
            XCTAssertEqual(error as? ShortcutService.RegistrationError, .invalidCombination)
        }
        XCTAssertNil(service.registeredShortcut)
    }

    func testRegisterAndUnregisterKeepsStateConsistent() throws {
        let service = ShortcutService()
        // 避开测试宿主 app 自己注册的默认组合键（⌃⌥Space）。
        let config = ShortcutConfiguration(
            keyCode: 0x50, // kVK_F19
            carbonModifiers: ShortcutConfiguration.Modifier.control.rawValue
                | ShortcutConfiguration.Modifier.option.rawValue
                | ShortcutConfiguration.Modifier.shift.rawValue
        )
        defer { service.unregister() }
        try service.register(config)
        XCTAssertEqual(service.registeredShortcut, config)
        service.unregister()
        XCTAssertNil(service.registeredShortcut)
    }
}
