import AppKit
import Combine
import SwiftUI

/// Dock 上方的录音浮条：只显示实时波形，毛玻璃胶囊，不抢焦点、不接收鼠标。
@MainActor
final class RecordingIndicatorController {
    private let panel: NSPanel
    private let model = RecordingIndicatorModel()
    private var cancellables = Set<AnyCancellable>()

    private static let panelSize = NSSize(width: 200, height: 44)

    init(appState: AppState) {
        let hosting = NSHostingController(rootView: RecordingIndicatorView(model: model))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none

        appState.$state
            .sink { [weak self] state in
                self?.handleState(state, appState: appState)
            }
            .store(in: &cancellables)

        appState.$audioLevels
            .sink { [weak self] levels in
                self?.model.levels = levels
            }
            .store(in: &cancellables)
    }

    private func handleState(_ state: RecordingState, appState: AppState) {
        switch state {
        case .recording:
            model.levels = appState.audioLevels
            positionPanel()
            panel.orderFrontRegardless()
        default:
            panel.orderOut(nil)
        }
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visible.midX - Self.panelSize.width / 2,
            y: visible.minY + 14
        )
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
    }
}

@MainActor
final class RecordingIndicatorModel: ObservableObject {
    @Published var levels: [Float] = []
}

struct RecordingIndicatorView: View {
    @ObservedObject var model: RecordingIndicatorModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WaveformBars(levels: model.levels, isDark: colorScheme == .dark)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: 200, height: 44)
            .background(
                Capsule()
                    .fill(colorScheme == .dark
                          ? Color.black.opacity(0.78)
                          : Color.white.opacity(0.94))
            )
            .overlay(
                Capsule()
                    .stroke(colorScheme == .dark
                            ? Color.white.opacity(0.14)
                            : Color.black.opacity(0.08),
                            lineWidth: 0.8)
            )
    }
}

struct WaveformBars: View {
    let levels: [Float]
    var isDark: Bool
    var barCount = 26

    private var gradient: LinearGradient {
        if isDark {
            return LinearGradient(
                colors: [Color.white.opacity(0.96), Color(red: 0.55, green: 0.8, blue: 1.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color(white: 0.18), Color(red: 0.12, green: 0.36, blue: 0.86)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(gradient)
                    .frame(width: 3, height: max(3, CGFloat(level(at: index)) * 20))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.linear(duration: 0.05), value: levels)
    }

    private func level(at index: Int) -> Float {
        let recent = Array(levels.suffix(barCount))
        let start = barCount - recent.count
        guard index >= start else { return 0.06 }
        return max(0.06, recent[index - start])
    }
}
