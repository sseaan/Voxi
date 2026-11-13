import AppKit
import SwiftUI

@main
struct VoxiApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsStore: SettingsStore!
    private var appState: AppState!
    private var coordinator: AppCoordinator!
    private var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore()
        let state = AppState()
        let coordinator = AppCoordinator(settings: settings, appState: state)
        self.settingsStore = settings
        self.appState = state
        self.coordinator = coordinator
        self.statusItem = StatusItemController(settings: settings, appState: state, coordinator: coordinator)
        coordinator.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
