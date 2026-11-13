import SwiftUI

@main
struct VoxiApp: App {
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var appState: AppState
    @StateObject private var coordinator: AppCoordinator

    init() {
        let settings = SettingsStore()
        let state = AppState()
        _settingsStore = StateObject(wrappedValue: settings)
        _appState = StateObject(wrappedValue: state)
        let coordinator = AppCoordinator(settings: settings, appState: state)
        _coordinator = StateObject(wrappedValue: coordinator)
        coordinator.activate()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(settings: settingsStore, appState: appState, coordinator: coordinator)
        } label: {
            Image(systemName: appState.state.menuBarSystemImage)
                .accessibilityLabel("Voxi：\(appState.state.menuTitle)")
        }
        .menuBarExtraStyle(.window)
    }
}
