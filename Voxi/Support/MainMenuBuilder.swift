import AppKit

/// 纯 AppKit 应用需要自己安装主菜单，否则文本框里的 ⌘V / ⌘C / ⌘A 不会生效。
enum MainMenuBuilder {
    @MainActor
    static func install(actions: AppMenuActions) {
        let mainMenu = NSMenu()

        // App 菜单
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Voxi")
        appMenuItem.submenu = appMenu

        let about = NSMenuItem(
            title: "关于 Voxi",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(about)
        appMenu.addItem(.separator())

        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(AppMenuActions.openSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = actions
        appMenu.addItem(settings)
        appMenu.addItem(.separator())

        let hide = NSMenuItem(title: "隐藏 Voxi", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hide)
        appMenu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Voxi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)

        // 编辑菜单：nil target 会路由到第一响应者（文本框）。
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "删除", action: Selector(("delete:")), keyEquivalent: "")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")

        // 窗口菜单
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

@MainActor
final class AppMenuActions: NSObject {
    private weak var settings: SettingsStore?
    private weak var appState: AppState?
    private weak var coordinator: AppCoordinator?

    func configure(settings: SettingsStore, appState: AppState, coordinator: AppCoordinator) {
        self.settings = settings
        self.appState = appState
        self.coordinator = coordinator
    }

    @objc func openSettings(_ sender: Any?) {
        guard let settings, let appState, let coordinator else { return }
        SettingsWindowController.shared.show(
            settings: settings,
            appState: appState,
            coordinator: coordinator
        )
    }
}
