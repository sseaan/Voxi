import AppKit
import SwiftUI

/// 设置窗口。
///
/// LSUIElement 菜单栏应用对 SwiftUI `Settings` 场景的自动打开行为在旧系统上不可靠，
/// 这里用显式 `NSWindow` 承载同一份 SwiftUI 视图，保证菜单栏与快捷键都能稳定打开。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(settings: SettingsStore, appState: AppState, coordinator: AppCoordinator) {
        if window == nil {
            let rootView = SettingsView(settings: settings, appState: appState, coordinator: coordinator)
            let hosting = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Voxi 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 620, height: 520))
            window.minSize = NSSize(width: 560, height: 440)
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
