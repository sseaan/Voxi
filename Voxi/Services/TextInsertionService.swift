import AppKit
import ApplicationServices
import Foundation

enum TextInsertionOutcome: Equatable {
    enum Method: String, Equatable {
        case accessibility
        case pasteboard
    }

    case inserted(via: Method)
    case requiresManualCopy(reason: String)

    var isInserted: Bool {
        if case .inserted = self { return true }
        return false
    }
}

protocol TextInserting: AnyObject {
    /// expectedFrontmostPID：录音开始时记录的前台应用；不一致时不做任何输入。
    @MainActor
    func insert(_ text: String, expectedFrontmostPID: pid_t?) async -> TextInsertionOutcome
}

/// 剪贴板快照：保留全部 item/type，粘贴完成后还原。
struct PasteboardSnapshot: Equatable {
    struct Entry: Equatable {
        var type: String
        var data: Data
    }

    var items: [[Entry]]

    var isEmpty: Bool { items.isEmpty }
}

protocol PasteboardAccessing: AnyObject {
    func snapshot() -> PasteboardSnapshot
    func writeString(_ string: String)
    func restore(_ snapshot: PasteboardSnapshot)
}

final class SystemPasteboard: PasteboardAccessing {
    func snapshot() -> PasteboardSnapshot {
        let items = NSPasteboard.general.pasteboardItems ?? []
        return PasteboardSnapshot(items: items.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return PasteboardSnapshot.Entry(type: type.rawValue, data: data)
            }
        })
    }

    func writeString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

protocol KeyboardSending: AnyObject {
    func sendPasteShortcut()
}

final class SystemKeyboardSender: KeyboardSending {
    func sendPasteShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode: CGKeyCode = 0x09 // kVK_ANSI_V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)
    }
}

/// 前台焦点元素快照（只读，用于判断能否安全输入）。
struct FocusedElementInfo: Equatable {
    var role: String?
    var subrole: String?
    var isProtected: Bool
    var canSetSelectedText: Bool
    var canSetValue: Bool
}

protocol AccessibilityInspecting {
    var isTrusted: Bool { get }
    func focusedElement() -> FocusedElementInfo?
    /// 尝试通过 AX 写入聚焦控件；返回 false 表示无法安全插入。
    func insertUsingAccessibility(_ text: String) -> Bool
    /// 读回确认。无法验证时返回 false，调用方会回退到剪贴板。
    func verifyInsertion(_ text: String) -> Bool
}

struct SystemAccessibilityInspector: AccessibilityInspecting {
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func focusedElement() -> FocusedElementInfo? {
        guard let element = focusedElementElement() else { return nil }
        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let protected = subrole == (kAXSecureTextFieldSubrole as String)
            || subrole == "AXSecureTextField"
        return FocusedElementInfo(
            role: role,
            subrole: subrole,
            isProtected: protected,
            canSetSelectedText: isSettable(element, kAXSelectedTextAttribute),
            canSetValue: isSettable(element, kAXValueAttribute)
        )
    }

    func insertUsingAccessibility(_ text: String) -> Bool {
        guard let element = focusedElementElement() else { return false }
        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return status == .success
    }

    func verifyInsertion(_ text: String) -> Bool {
        guard let element = focusedElementElement(),
              let value = stringAttribute(element, kAXValueAttribute)
        else { return false }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return value.contains(needle)
    }

    private func focusedElementElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    private func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
        return status == .success && settable.boolValue
    }
}

protocol FrontmostAppProviding {
    func currentPID() -> pid_t
    func currentBundleIdentifier() -> String?
}

struct SystemFrontmostApp: FrontmostAppProviding {
    func currentPID() -> pid_t {
        NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }

    func currentBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

/// 最终文本输入：优先辅助功能插入，否则剪贴板 + Cmd+V，并恢复剪贴板。
@MainActor
final class TextInsertionService: TextInserting {
    /// 已知无法可靠自动输入的终端类应用。
    static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "co.zeit.hyper"
    ]

    private let pasteboard: PasteboardAccessing
    private let keyboard: KeyboardSending
    private let accessibility: AccessibilityInspecting
    private let frontmost: FrontmostAppProviding
    private let pasteSettleNanoseconds: UInt64

    init(
        pasteboard: PasteboardAccessing = SystemPasteboard(),
        keyboard: KeyboardSending = SystemKeyboardSender(),
        accessibility: AccessibilityInspecting = SystemAccessibilityInspector(),
        frontmost: FrontmostAppProviding = SystemFrontmostApp(),
        pasteSettleNanoseconds: UInt64 = 250_000_000
    ) {
        self.pasteboard = pasteboard
        self.keyboard = keyboard
        self.accessibility = accessibility
        self.frontmost = frontmost
        self.pasteSettleNanoseconds = pasteSettleNanoseconds
    }

    func insert(_ text: String, expectedFrontmostPID: pid_t?) async -> TextInsertionOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .requiresManualCopy(reason: "识别结果为空")
        }

        if let expectedFrontmostPID, frontmost.currentPID() != expectedFrontmostPID {
            return .requiresManualCopy(reason: "前台应用已切换")
        }

        guard accessibility.isTrusted else {
            return .requiresManualCopy(reason: "未授予辅助功能权限")
        }

        if let bundleID = frontmost.currentBundleIdentifier(),
           Self.terminalBundleIdentifiers.contains(bundleID) {
            return .requiresManualCopy(reason: "终端类应用不支持自动输入")
        }

        if let element = accessibility.focusedElement() {
            if element.isProtected {
                return .requiresManualCopy(reason: "安全输入框不支持自动输入")
            }
            if element.canSetSelectedText || element.canSetValue,
               accessibility.insertUsingAccessibility(text),
               accessibility.verifyInsertion(text) {
                Logger.insertion.info("使用辅助功能插入文本")
                return .inserted(via: .accessibility)
            }
        }

        return await pasteWithPasteboardRestore(text)
    }

    private func pasteWithPasteboardRestore(_ text: String) async -> TextInsertionOutcome {
        let snapshot = pasteboard.snapshot()
        pasteboard.writeString(text)
        keyboard.sendPasteShortcut()
        // 等待目标应用完成粘贴后再恢复剪贴板，避免粘贴到旧内容。
        try? await Task.sleep(nanoseconds: pasteSettleNanoseconds)
        pasteboard.restore(snapshot)
        Logger.insertion.info("使用剪贴板粘贴插入文本")
        return .inserted(via: .pasteboard)
    }
}
