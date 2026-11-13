import AppKit
import Combine
import SwiftUI

/// 菜单栏图标与弹出面板。
///
/// 不使用 SwiftUI `MenuBarExtra`：macOS 26/27 上它反复开合后可能不再响应点击，
/// 也无法在需要时可靠地定位面板。直接管理 `NSStatusItem` + `NSPopover` 更稳定。
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore, appState: AppState, coordinator: AppCoordinator) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let hosting = NSHostingController(
            rootView: MenuBarView(settings: settings, appState: appState, coordinator: coordinator)
        )
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Voxi")
        }

        appState.$state
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
            .store(in: &cancellables)

        updateIcon(for: appState.state)
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func updateIcon(for state: RecordingState) {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: state.menuBarSystemImage,
            accessibilityDescription: state.menuTitle
        )
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = state == .recording ? .systemRed : nil
        button.setAccessibilityLabel("Voxi：\(state.menuTitle)")
    }
}
