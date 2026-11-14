import AppKit
import Carbon.HIToolbox

/// 全局快捷键事件（Carbon 只提供按下/松开；失焦保护由协调器补充）。
enum ShortcutEvent: Equatable {
    case keyDown
    case keyUp
    /// 应用失焦或键盘事件丢失时的兜底事件。
    case lostFocus
}

enum ShortcutAction: Equatable {
    case start
    case stop
    case ignore
}

/// 纯逻辑：把快捷键事件 + 录音模式 + 当前是否录音映射成动作。
///
/// 规则：
/// - `holdToTalk`：keyDown 开始，keyUp 结束；重复 keyDown 被忽略。
/// - `toggle`：keyDown 在开始/结束之间切换；keyUp 忽略。
/// - 失焦保护只在 `holdToTalk` 且正在录音时结束录音。
struct ShortcutEventMapper {
    static func action(for event: ShortcutEvent, mode: RecordingMode, isRecording: Bool) -> ShortcutAction {
        switch (event, mode) {
        case (.keyDown, .holdToTalk):
            return isRecording ? .ignore : .start
        case (.keyUp, .holdToTalk):
            return isRecording ? .stop : .ignore
        case (.keyDown, .toggle):
            return isRecording ? .stop : .start
        case (.keyUp, .toggle):
            return .ignore
        case (.lostFocus, .holdToTalk):
            return isRecording ? .stop : .ignore
        case (.lostFocus, .toggle):
            return .ignore
        }
    }
}

/// 用 Carbon `RegisterEventHotKey` 注册全局快捷键。
///
/// 不使用 CGEventTap，因此不需要额外权限；也不需要辅助功能权限即可监听组合键。
@MainActor
final class ShortcutService {
    enum RegistrationError: Error, LocalizedError, Equatable {
        case invalidCombination
        case conflict
        case systemFailure(OSStatus)
        case accessibilityRequired

        var errorDescription: String? {
            switch self {
            case .invalidCombination:
                return "快捷键至少需要一个修饰键（⌃⌥⇧⌘）和一个支持的按键。"
            case .conflict:
                return "该快捷键已被其他应用占用，请换一个组合。"
            case .systemFailure(let status):
                return "快捷键注册失败（OSStatus \(status)）。"
            case .accessibilityRequired:
                return "Fn / 右 Option 单键需要辅助功能权限才能全局监听，请先在设置中授权。"
            }
        }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var modifierGlobalMonitor: Any?
    private var modifierLocalMonitor: Any?
    private var isModifierDown = false
    private var isKeyDown = false
    private(set) var registeredShortcut: ShortcutConfiguration?

    /// 注册（或替换）全局快捷键。重复注册会先注销旧组合。
    func register(_ configuration: ShortcutConfiguration) throws {
        guard configuration.isValid else {
            unregister()
            throw RegistrationError.invalidCombination
        }

        unregister()

        if configuration.isModifierOnly {
            try installModifierMonitor(configuration)
            registeredShortcut = configuration
            Logger.shortcut.info("已注册单键修饰符快捷键 \(configuration.displayString, privacy: .public)")
            return
        }

        var hotKeyID = EventHotKeyID(signature: OSType(0x5658_4F49), id: 1) // 'VXOI'
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            configuration.keyCode,
            configuration.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            throw status == eventHotKeyExistsErr
                ? RegistrationError.conflict
                : RegistrationError.systemFailure(status)
        }
        self.hotKeyRef = hotKeyRef
        _ = hotKeyID

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            shortcutEventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            throw RegistrationError.systemFailure(handlerStatus)
        }

        registeredShortcut = configuration
        isKeyDown = false
        Logger.shortcut.info("已注册全局快捷键 keyCode=\(configuration.keyCode, privacy: .public)")
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
        removeModifierMonitor()
        registeredShortcut = nil
        isKeyDown = false
        isModifierDown = false
    }

    // MARK: - Fn / 右 Option 单键

    private func installModifierMonitor(_ configuration: ShortcutConfiguration) throws {
        guard AXIsProcessTrusted() else {
            throw RegistrationError.accessibilityRequired
        }

        let handler: (NSEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                self?.handleModifierEvent(event)
            }
        }
        modifierGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
        }
        modifierLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
        if modifierGlobalMonitor == nil && modifierLocalMonitor == nil {
            throw RegistrationError.accessibilityRequired
        }
        _ = configuration
    }

    private func removeModifierMonitor() {
        if let modifierGlobalMonitor {
            NSEvent.removeMonitor(modifierGlobalMonitor)
        }
        modifierGlobalMonitor = nil
        if let modifierLocalMonitor {
            NSEvent.removeMonitor(modifierLocalMonitor)
        }
        modifierLocalMonitor = nil
    }

    private func handleModifierEvent(_ event: NSEvent) {
        guard let configuration = registeredShortcut, configuration.isModifierOnly else { return }
        guard UInt32(event.keyCode) == configuration.keyCode else { return }

        let pressed: Bool
        if configuration.keyCode == ShortcutConfiguration.fnKeyCode {
            pressed = event.modifierFlags.contains(.function)
        } else {
            pressed = event.modifierFlags.contains(.option)
        }

        if pressed, !isModifierDown {
            isModifierDown = true
            onPress?()
        } else if !pressed, isModifierDown {
            isModifierDown = false
            onRelease?()
        }
    }

    /// 按键状态复位（例如应用失焦后松开事件丢失）。
    func resetKeyState() {
        isKeyDown = false
        isModifierDown = false
    }

    fileprivate func handleEvent(kind: UInt32) {
        switch Int(kind) {
        case kEventHotKeyPressed:
            guard !isKeyDown else { return } // 过滤自动重复
            isKeyDown = true
            onPress?()
        case kEventHotKeyReleased:
            guard isKeyDown else { return }
            isKeyDown = false
            onRelease?()
        default:
            break
        }
    }
}

/// Carbon 回调在应用主线程触发；用 `assumeIsolated` 安全回到主 actor。
private func shortcutEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let service = Unmanaged<ShortcutService>.fromOpaque(userData).takeUnretainedValue()
    let kind = GetEventKind(event)
    MainActor.assumeIsolated {
        service.handleEvent(kind: kind)
    }
    return noErr
}
