import XCTest
@testable import Voxi

final class FakePasteboard: PasteboardAccessing {
    var snapshotValue = PasteboardSnapshot(items: [[
        .init(type: "public.utf8-plain-text", data: Data("原始剪贴板".utf8))
    ]])
    private(set) var writtenStrings: [String] = []
    private(set) var restoreCount = 0
    private(set) var lastRestored: PasteboardSnapshot?

    func snapshot() -> PasteboardSnapshot { snapshotValue }

    func writeString(_ string: String) {
        writtenStrings.append(string)
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        restoreCount += 1
        lastRestored = snapshot
    }
}

final class FakeKeyboardSender: KeyboardSending {
    private(set) var pasteCount = 0
    func sendPasteShortcut() { pasteCount += 1 }
}

struct FakeAccessibilityInspector: AccessibilityInspecting {
    var isTrusted = true
    var element: FocusedElementInfo? = FocusedElementInfo(
        role: "AXTextArea",
        subrole: nil,
        isProtected: false,
        canSetSelectedText: true,
        canSetValue: true
    )
    var insertResult = true
    var verifyResult = true

    func focusedElement() -> FocusedElementInfo? { element }
    func insertUsingAccessibility(_ text: String) -> Bool { insertResult }
    func verifyInsertion(_ text: String) -> Bool { verifyResult }
}

final class FakeFrontmostApp: FrontmostAppProviding {
    var pid: pid_t = 777
    var bundle: String? = "com.test.editor"

    func currentPID() -> pid_t { pid }
    func currentBundleIdentifier() -> String? { bundle }
}

@MainActor
final class TextInsertionServiceTests: XCTestCase {
    private var pasteboard: FakePasteboard!
    private var keyboard: FakeKeyboardSender!
    private var frontmost: FakeFrontmostApp!

    override func setUp() {
        super.setUp()
        pasteboard = FakePasteboard()
        keyboard = FakeKeyboardSender()
        frontmost = FakeFrontmostApp()
    }

    private func makeService(
        accessibility: FakeAccessibilityInspector = FakeAccessibilityInspector()
    ) -> TextInsertionService {
        TextInsertionService(
            pasteboard: pasteboard,
            keyboard: keyboard,
            accessibility: accessibility,
            frontmost: frontmost,
            pasteSettleNanoseconds: 1_000_000
        )
    }

    func testAccessibilityInsertionSucceedsWithoutTouchingPasteboard() async {
        let service = makeService()
        let outcome = await service.insert("你好世界", expectedFrontmostPID: 777)

        XCTAssertEqual(outcome, .inserted(via: .accessibility))
        XCTAssertEqual(keyboard.pasteCount, 0)
        XCTAssertTrue(pasteboard.writtenStrings.isEmpty)
        XCTAssertEqual(pasteboard.restoreCount, 0)
    }

    func testFallsBackToPasteboardWhenVerificationFails() async {
        var accessibility = FakeAccessibilityInspector()
        accessibility.verifyResult = false
        let service = makeService(accessibility: accessibility)

        let outcome = await service.insert("你好世界", expectedFrontmostPID: 777)

        XCTAssertEqual(outcome, .inserted(via: .pasteboard))
        XCTAssertEqual(keyboard.pasteCount, 1)
        XCTAssertEqual(pasteboard.writtenStrings, ["你好世界"])
        XCTAssertEqual(pasteboard.restoreCount, 1)
        XCTAssertEqual(pasteboard.lastRestored, pasteboard.snapshotValue)
    }

    func testFallsBackWhenElementCannotSetText() async {
        var accessibility = FakeAccessibilityInspector()
        accessibility.element = FocusedElementInfo(
            role: "AXButton",
            subrole: nil,
            isProtected: false,
            canSetSelectedText: false,
            canSetValue: false
        )
        let service = makeService(accessibility: accessibility)

        let outcome = await service.insert("文本", expectedFrontmostPID: 777)
        XCTAssertEqual(outcome, .inserted(via: .pasteboard))
        XCTAssertEqual(pasteboard.restoreCount, 1)
    }

    func testSecureTextFieldRequiresManualCopy() async {
        var accessibility = FakeAccessibilityInspector()
        accessibility.element = FocusedElementInfo(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            isProtected: true,
            canSetSelectedText: true,
            canSetValue: true
        )
        let service = makeService(accessibility: accessibility)

        let outcome = await service.insert("密码", expectedFrontmostPID: 777)
        XCTAssertEqual(outcome, .requiresManualCopy(reason: "安全输入框不支持自动输入"))
        XCTAssertEqual(keyboard.pasteCount, 0, "不得向安全输入框粘贴")
    }

    func testAccessibilityNotTrustedRequiresManualCopy() async {
        var accessibility = FakeAccessibilityInspector()
        accessibility.isTrusted = false
        let service = makeService(accessibility: accessibility)

        let outcome = await service.insert("文本", expectedFrontmostPID: 777)
        XCTAssertEqual(outcome, .requiresManualCopy(reason: "未授予辅助功能权限"))
        XCTAssertEqual(keyboard.pasteCount, 0)
    }

    func testFrontmostAppChangedRequiresManualCopy() async {
        let service = makeService()
        frontmost.pid = 999

        let outcome = await service.insert("文本", expectedFrontmostPID: 777)
        XCTAssertEqual(outcome, .requiresManualCopy(reason: "前台应用已切换"))
        XCTAssertEqual(keyboard.pasteCount, 0)
        XCTAssertTrue(pasteboard.writtenStrings.isEmpty)
    }

    func testTerminalAppRequiresManualCopy() async {
        frontmost.bundle = "com.apple.Terminal"
        let service = makeService()

        let outcome = await service.insert("文本", expectedFrontmostPID: 777)
        XCTAssertEqual(outcome, .requiresManualCopy(reason: "终端类应用不支持自动输入"))
        XCTAssertEqual(keyboard.pasteCount, 0)
    }

    func testEmptyTextIsRejected() async {
        let service = makeService()
        let outcome = await service.insert("   ", expectedFrontmostPID: nil)
        XCTAssertEqual(outcome, .requiresManualCopy(reason: "识别结果为空"))
    }

    func testPasteboardRestoreHappensAfterPaste() async {
        var accessibility = FakeAccessibilityInspector()
        accessibility.element = nil
        let service = makeService(accessibility: accessibility)

        _ = await service.insert("文本", expectedFrontmostPID: nil)
        XCTAssertEqual(keyboard.pasteCount, 1)
        XCTAssertEqual(pasteboard.restoreCount, 1)
    }
}
