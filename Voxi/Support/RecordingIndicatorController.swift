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

    var body: some View {
        WaveformBars(levels: model.levels)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(width: 200, height: 44)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

struct WaveformBars: View {
    let levels: [Float]
    var barCount = 26

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.88))
                    .frame(width: 3, height: max(3, CGFloat(level(at: index)) * 18))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: levels)
    }

    private func level(at index: Int) -> Float {
        let recent = Array(levels.suffix(barCount))
        let start = barCount - recent.count
        guard index >= start else { return 0.06 }
        return max(0.06, recent[index - start])
    }
}
