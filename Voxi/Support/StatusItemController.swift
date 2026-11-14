import AppKit
import Combine
import SwiftUI

/// 菜单栏图标与弹出面板。
///
/// 不使用 SwiftUI `MenuBarExtra`（macOS 26/27 反复开合后可能失灵），
/// 也不使用 `NSPopover`（其窗口阴影左右不对称，箭头与面板中心无法同时对齐）。
/// 这里用无边框 `NSPanel`，内容严格以状态图标中心对齐。
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private var hosting: NSHostingController<MenuBarView>!
    private var cancellables = Set<AnyCancellable>()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pendingLayout: DispatchWorkItem?
    private var previousApp: NSRunningApplication?
    private let coordinator: AppCoordinator

    /// 面板内容宽度（与 MenuBarView 的固定宽度一致）。
    private static let contentWidth: CGFloat = 340
    /// 面板与菜单栏之间的间距。
    private static let topGap: CGFloat = 6

    init(settings: SettingsStore, appState: AppState, coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        super.init()

        let root = MenuBarView(
            settings: settings,
            appState: appState,
            coordinator: coordinator,
            onRequestClose: { [weak panel] in
                panel?.orderOut(nil)
            },
            onStartRecording: { [weak self] in
                self?.startRecordingFromPanel()
            },
            onStopRecording: { [weak self] in
                self?.stopRecordingFromPanel()
            }
        )
        hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.becomesKeyOnlyIfNeeded = false

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

        // 内容高度随状态（错误、结果、临时文本）变化，变化后重新布局。
        appState.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleLayout()
            }
            .store(in: &cancellables)

        updateIcon(for: appState.state)
        installEventMonitors()

        DispatchQueue.main.async { [weak self] in
            self?.logGeometry(event: "launch")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.logGeometry(event: "launch+2s")
        }
    }

    // MARK: - 显示 / 隐藏

    @objc private func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        layoutPanel(keepTop: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        logGeometry(event: "show")
    }

    /// 从菜单栏开始录音：先收起面板并把前台还给原应用，避免结果粘回 Voxi。
    private func startRecordingFromPanel() {
        hidePanel()
        if let previousApp {
            previousApp.activate(options: [.activateIgnoringOtherApps])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.coordinator.startRecording()
        }
    }

    private func stopRecordingFromPanel() {
        if let previousApp {
            previousApp.activate(options: [.activateIgnoringOtherApps])
        }
        coordinator.stopRecording()
    }

    func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    // MARK: - 布局

    private func scheduleLayout() {
        pendingLayout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.layoutPanel(keepTop: true)
        }
        pendingLayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func layoutPanel(keepTop: Bool) {
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))

        hosting.sizingOptions = .preferredContentSize
        let ideal = hosting.sizeThatFits(in: NSSize(width: Self.contentWidth, height: 2_000))
        let fitting = hosting.view.fittingSize
        let preferred = hosting.preferredContentSize
        Logger.app.debug(
            "面板测量 preferred=\(preferred.width, privacy: .public)x\(preferred.height, privacy: .public) fitting=\(fitting.width, privacy: .public)x\(fitting.height, privacy: .public) sizeThatFits=\(ideal.width, privacy: .public)x\(ideal.height, privacy: .public) view=\(self.hosting.view.frame.width, privacy: .public)x\(self.hosting.view.frame.height, privacy: .public)"
        )
        let height = max(120, max(ideal.height, max(fitting.height, preferred.height)).rounded(.up) + 2)
        let width = Self.contentWidth

        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.midX - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        let top = keepTop ? panel.frame.maxY : anchor.minY - Self.topGap
        let origin = NSPoint(x: x, y: top - height)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
    }

    // MARK: - 事件

    private func installEventMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53 { // Esc
                self.hidePanel()
                return nil
            }
            if event.type == .leftMouseDown {
                let location = NSEvent.mouseLocation
                if !self.panel.frame.contains(location) {
                    self.hidePanel()
                }
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.hidePanel()
                }
            }
        }
    }

    // MARK: - 图标

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

    private func logGeometry(event: String) {
        guard let button = statusItem.button, let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        Logger.app.debug(
            "菜单栏几何 [\(event, privacy: .public)] icon=\(rect.origin.x, privacy: .public),\(rect.origin.y, privacy: .public),\(rect.width, privacy: .public),\(rect.height, privacy: .public) panel=\(self.panel.frame.origin.x, privacy: .public),\(self.panel.frame.origin.y, privacy: .public),\(self.panel.frame.width, privacy: .public),\(self.panel.frame.height, privacy: .public)"
        )
    }
}
