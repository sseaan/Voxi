import AppKit
import SwiftUI

/// 快捷键录制控件：点击后按下新的组合键完成录入，Esc 取消。
struct ShortcutRecorderView: NSViewRepresentable {
    let configuration: ShortcutConfiguration
    let onRecord: (ShortcutConfiguration) -> Void
    let onInvalid: (String) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.configuration = configuration
        view.onRecord = onRecord
        view.onInvalid = onInvalid
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.configuration = configuration
        nsView.onRecord = onRecord
        nsView.onInvalid = onInvalid
    }
}

final class ShortcutRecorderNSView: NSView {
    var configuration: ShortcutConfiguration = .default {
        didSet { needsDisplay = true }
    }
    var onRecord: ((ShortcutConfiguration) -> Void)?
    var onInvalid: ((String) -> Void)?

    private var isCapturing = false {
        didSet { needsDisplay = true }
    }
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 26) }

    override func mouseDown(with event: NSEvent) {
        beginCapture()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isCapturing ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isCapturing ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isCapturing ? 2 : 1
        path.stroke()

        let text = isCapturing ? "按下新的组合键…" : configuration.displayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isCapturing ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attributes)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { endCapture() }
    }

    private func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isCapturing else { return event }
            if event.type == .flagsChanged {
                self.handleFlagsChanged(event)
                return event
            }
            return self.handleKeyDown(event)
        }
    }

    /// Fn / 右 Option 通过 flagsChanged 捕获，作为单键快捷键。
    private func handleFlagsChanged(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        if keyCode == ShortcutConfiguration.fnKeyCode,
           event.modifierFlags.contains(.function) {
            accept(ShortcutConfiguration(keyCode: keyCode, carbonModifiers: 0))
        } else if keyCode == ShortcutConfiguration.rightOptionKeyCode,
                  event.modifierFlags.contains(.option) {
            accept(ShortcutConfiguration(keyCode: keyCode, carbonModifiers: 0))
        }
    }

    private func accept(_ configuration: ShortcutConfiguration) {
        guard configuration.isValid else {
            onInvalid?("快捷键至少需要一个修饰键（⌃⌥⇧⌘）和一个支持的按键。")
            endCapture()
            return
        }
        self.configuration = configuration
        endCapture()
        onRecord?(configuration)
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Esc 取消
        if event.keyCode == 53 {
            endCapture()
            return nil
        }
        // 纯修饰键不构成普通组合键（Fn / 右 Option 走 flagsChanged）
        if [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(Int(event.keyCode)) {
            return nil
        }

        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        let candidate = ShortcutConfiguration(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)

        guard candidate.isValid else {
            onInvalid?("快捷键至少需要一个修饰键（⌃⌥⇧⌘）和一个支持的按键。")
            endCapture()
            return nil
        }

        configuration = candidate
        endCapture()
        onRecord?(candidate)
        return nil
    }

    private func endCapture() {
        isCapturing = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// NSEvent 修饰键 → Carbon 修饰键掩码。
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= ShortcutConfiguration.Modifier.control.rawValue }
        if flags.contains(.option) { modifiers |= ShortcutConfiguration.Modifier.option.rawValue }
        if flags.contains(.shift) { modifiers |= ShortcutConfiguration.Modifier.shift.rawValue }
        if flags.contains(.command) { modifiers |= ShortcutConfiguration.Modifier.command.rawValue }
        return modifiers
    }
}
