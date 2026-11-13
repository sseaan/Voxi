import Foundation

/// 全局快捷键配置。只保存键码与修饰键，不保存任何 secret。
/// Carbon `RegisterEventHotKey` 使用的是 `kVK_*` 虚拟键码与 Carbon 修饰键掩码。
struct ShortcutConfiguration: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Carbon 修饰键掩码。
    enum Modifier: UInt32 {
        case command = 0x0100   // cmdKey
        case shift = 0x0200     // shiftKey
        case option = 0x0800    // optionKey
        case control = 0x1000   // controlKey
    }

    static let `default` = ShortcutConfiguration(
        keyCode: 0x31, // kVK_Space
        carbonModifiers: Modifier.control.rawValue | Modifier.option.rawValue
    )

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    var modifierNames: [String] {
        var names: [String] = []
        if carbonModifiers & Modifier.control.rawValue != 0 { names.append("⌃") }
        if carbonModifiers & Modifier.option.rawValue != 0 { names.append("⌥") }
        if carbonModifiers & Modifier.shift.rawValue != 0 { names.append("⇧") }
        if carbonModifiers & Modifier.command.rawValue != 0 { names.append("⌘") }
        return names
    }

    /// 供设置界面显示的文本，例如 `⌃⌥Space`。
    var displayString: String {
        modifierNames.joined() + Self.keyName(for: keyCode)
    }

    /// 至少需要一个修饰键，避免抢占普通输入按键。
    var isValid: Bool {
        carbonModifiers != 0 && Self.keyName(for: keyCode) != "?"
    }

    private static let keyNames: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x19: "9", 0x1A: "7", 0x1C: "8", 0x1D: "0",
        0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J",
        0x28: "K", 0x2D: "N", 0x2E: "M",
        0x18: "=", 0x1B: "-", 0x21: "[", 0x27: "'", 0x29: ";", 0x2A: "\\",
        0x2B: ",", 0x2C: "/", 0x2F: ".", 0x32: "`",
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete", 0x35: "Esc",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x69: "F13"
    ]

    static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "?"
    }
}
