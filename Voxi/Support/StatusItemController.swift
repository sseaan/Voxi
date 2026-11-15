import AppKit
import Combine

/// 菜单栏图标与原生下拉菜单。
///
/// 采用 `NSMenu`（系统竖式列表）：状态行 + 转写音频 / 设置 / 检查更新 / 提供反馈 / 退出。
/// 录音开始与结束仍由全局快捷键驱动，菜单只负责状态显示与命令入口。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private let coordinator: AppCoordinator
    private let settings: SettingsStore
    private let appState: AppState
    /// 最近一个非 Voxi 的前台应用，用于把文件转写结果输入回去。
    private var previousAppPID: pid_t?
    private var pendingRecovery: AppError.Recovery?

    private static let feedbackURL = URL(string: "https://github.com/sseaan/Voxi/issues/new")!

    init(settings: SettingsStore, appState: AppState, coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.settings = settings
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        super.init()

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Voxi")
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        appState.$state
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        updateIcon(for: appState.state)
    }

    @objc private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousAppPID = app.processIdentifier
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - 菜单构建

    private func rebuildMenu() {
        menu.removeAllItems()
        pendingRecovery = appState.error?.recovery

        menu.addItem(statusItemForCurrentState())
        menu.addItem(subtitleItem())
        if let notice = appState.noticeMessage, !notice.isEmpty {
            menu.addItem(hintItem(notice))
        }
        if let error = appState.error {
            menu.addItem(hintItem("⚠︎ \(error.message)"))
            if let recovery = error.recovery {
                let title = MenuBarLabels.recoveryTitle(recovery)
                menu.addItem(actionItem(title, action: #selector(performRecovery)))
            }
        }
        if appState.lastResult != nil {
            menu.addItem(actionItem("复制识别结果", action: #selector(copyLastResult)))
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("转写音频…", action: #selector(transcribeAudioFile)))
        let settingsItem = actionItem("设置…", action: #selector(openSettings), key: ",")
        menu.addItem(settingsItem)
        menu.addItem(actionItem("检查更新…", action: #selector(checkForUpdates)))
        menu.addItem(actionItem("提供反馈…", action: #selector(openFeedback)))
        menu.addItem(.separator())
        menu.addItem(actionItem("退出 Voxi", action: #selector(quit), key: "q"))
    }

    private func statusItemForCurrentState() -> NSMenuItem {
        let title: String
        if appState.state.isRecording, let startedAt = appState.recordingStartedAt {
            title = "\(appState.state.menuTitle) · \(MenuBarLabels.formatted(elapsed: Date().timeIntervalSince(startedAt)))"
        } else {
            title = appState.state.menuTitle
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = stateImage()
        item.image?.isTemplate = true
        item.isEnabled = false
        return item
    }

    private func subtitleItem() -> NSMenuItem {
        let text: String
        if appState.state.isRecording {
            text = "松开或按快捷键结束录音"
        } else if appState.state.isBusy {
            text = "正在处理，请稍候…"
        } else if let first = settings.settings.asrCandidates.first {
            let count = settings.settings.asrCandidates.count
            text = count > 1
                ? "\(first.model) · 自动回退 \(count) 个模型"
                : "\(first.sourceName) · \(first.model)"
        } else {
            text = "尚未配置识别端点"
        }
        return hintItem(text)
    }

    private func hintItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        return item
    }

    private func actionItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func stateImage() -> NSImage? {
        let image = NSImage(
            systemSymbolName: appState.state.menuBarSystemImage,
            accessibilityDescription: appState.state.menuTitle
        )
        if appState.state.isRecording {
            image?.isTemplate = false
        }
        return image
    }

    // MARK: - 动作

    @objc private func performRecovery() {
        guard let recovery = pendingRecovery else { return }
        MenuBarLabels.perform(recovery)
    }

    @objc private func copyLastResult() {
        guard let text = appState.lastResult?.text else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func transcribeAudioFile() {
        AudioFileTranscriptionWindowController.shared.show(
            settings: settings,
            targetPID: previousAppPID
        )
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(
            settings: settings,
            appState: appState,
            coordinator: coordinator
        )
    }

    @objc private func checkForUpdates() {
        Task { await UpdateController.shared.checkForUpdates() }
    }

    @objc private func openFeedback() {
        NSWorkspace.shared.open(Self.feedbackURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
}

/// 菜单文字与错误恢复动作（原自绘面板的纯函数，保留以便测试与复用）。
enum MenuBarLabels {
    static func formatted(elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func recoveryTitle(_ recovery: AppError.Recovery) -> String {
        switch recovery {
        case .openMicrophoneSettings: return "打开麦克风设置…"
        case .openAccessibilitySettings: return "打开辅助功能设置…"
        case .copyTranscript(let text): return text.isEmpty ? "复制" : "复制识别结果"
        }
    }

    @MainActor
    static func perform(_ recovery: AppError.Recovery) {
        switch recovery {
        case .openMicrophoneSettings:
            PermissionService.openSettingsPane(.microphone)
        case .openAccessibilitySettings:
            PermissionService.openSettingsPane(.accessibility)
        case .copyTranscript(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
