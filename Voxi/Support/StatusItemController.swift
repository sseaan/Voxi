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

        // 记录真实屏幕坐标，便于排查面板定位问题。
        DispatchQueue.main.async { [weak self] in
            self?.logGeometry(event: "launch")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.logGeometry(event: "launch+2s")
        }
    }

    private func logGeometry(event: String) {
        guard let button = statusItem.button, let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let panel = popover.contentViewController?.view.window?.frame
        Logger.app.debug(
            "菜单栏几何 [\(event, privacy: .public)] icon=\(rect.origin.x, privacy: .public),\(rect.origin.y, privacy: .public),\(rect.width, privacy: .public),\(rect.height, privacy: .public) panel=\(panel.map { "\($0.origin.x),\($0.origin.y),\($0.width),\($0.height)" } ?? "hidden", privacy: .public)"
        )
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // macOS 26/27 的 NSPopover 会把内容整体右移约 10pt，这里按需校正，
        // 保证箭头指向图标中心。靠近屏幕边缘时不做校正，避免把面板推出屏幕。
        if let panel = popover.contentViewController?.view.window, let screen = panel.screen ?? window.screen {
            let visible = screen.visibleFrame
            let delta = anchor.midX - panel.frame.midX
            let targetX = panel.frame.origin.x + delta
            let fitsHorizontally = targetX >= visible.minX + 4
                && targetX + panel.frame.width <= visible.maxX - 4
            if abs(delta) > 0.5, fitsHorizontally {
                panel.setFrameOrigin(NSPoint(x: targetX, y: panel.frame.origin.y))
            }
        }
        logGeometry(event: "show")
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
