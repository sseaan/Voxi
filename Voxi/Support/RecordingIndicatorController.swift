import AppKit
import Combine
import SwiftUI

/// Dock 上方的录音浮条：红点 + 计时 + 实时波形，不抢焦点、不接收鼠标。
@MainActor
final class RecordingIndicatorController {
    private let panel: NSPanel
    private let model = RecordingIndicatorModel()
    private var cancellables = Set<AnyCancellable>()

    private static let panelSize = NSSize(width: 268, height: 60)

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
            model.startedAt = appState.recordingStartedAt
            model.levels = appState.audioLevels
            positionPanel()
            panel.orderFrontRegardless()
            Logger.app.info("录音浮条显示 frame=\(self.panel.frame.debugDescription, privacy: .public)")
        default:
            if panel.isVisible {
                Logger.app.info("录音浮条隐藏 state=\(state.rawValue, privacy: .public)")
            }
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
    @Published var startedAt: Date?
    @Published var levels: [Float] = []
}

struct RecordingIndicatorView: View {
    @ObservedObject var model: RecordingIndicatorModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: Color.red.opacity(0.7), radius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text("正在录音")
                    .font(.system(size: 11, weight: .semibold))
                elapsed
            }

            WaveformBars(levels: model.levels)
                .frame(width: 96, height: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 12, y: 4)
        .padding(6)
    }

    @ViewBuilder
    private var elapsed: some View {
        if let startedAt = model.startedAt {
            TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                Text(Self.formatted(context.date.timeIntervalSince(startedAt)))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("0:00")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    static func formatted(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct WaveformBars: View {
    let levels: [Float]
    private let barCount = 18

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                let level = level(at: index)
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 3, height: max(3, CGFloat(level) * 22))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.12), value: levels)
    }

    private func level(at index: Int) -> Float {
        let recent = Array(levels.suffix(barCount))
        let start = barCount - recent.count
        guard index >= start else { return 0.05 }
        return max(0.08, recent[index - start])
    }
}
