import AppKit
import SwiftUI

/// 首次启动引导窗口：竖向小窗，不打开设置页；完成后才打开设置。
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let settings: SettingsStore
    private let coordinator: AppCoordinator

    init(settings: SettingsStore, coordinator: AppCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }

    func show() {
        let view = OnboardingView(
            settings: settings,
            permissions: coordinator.permissions,
            onFinish: { [weak self] in
                self?.finish()
            }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "欢迎使用 Voxi"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 480, height: 640))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        settings.settings.hasCompletedOnboarding = true
        window?.close()
        SettingsWindowController.shared.show(
            settings: settings,
            appState: coordinator.appState,
            coordinator: coordinator
        )
    }
}
