import AppKit
import Combine
import SwiftUI

/// 录音浮条：参考 OpenVoice 的深色磨砂胶囊。
/// - 聆听阶段：呼吸绿点 + 5 段实时波形 + “正在聆听”；
/// - 转录阶段：转圈 + “正在转录…”；
/// - 不抢焦点、不接收鼠标；出现时 0.15s 淡入。
@MainActor
final class RecordingIndicatorController {
    private let panel: NSPanel
    private let model = RecordingIndicatorModel()
    private var cancellables = Set<AnyCancellable>()

    private static let listeningSize = NSSize(width: 138, height: 36)
    private static let transcribingSize = NSSize(width: 128, height: 36)

    init(appState: AppState) {
        let hosting = NSHostingController(rootView: RecordingIndicatorView(model: model))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.listeningSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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
            model.phase = .listening
            show(size: Self.listeningSize)
        case .finalizingAudio, .transcribing:
            model.phase = .transcribing
            show(size: Self.transcribingSize)
        default:
            panel.orderOut(nil)
        }
    }

    private func show(size: NSSize) {
        positionPanel(size: size)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func positionPanel(size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 64
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

@MainActor
final class RecordingIndicatorModel: ObservableObject {
    enum Phase {
        case listening
        case transcribing
    }

    @Published var phase: Phase = .listening
    @Published var levels: [Float] = []
}

struct RecordingIndicatorView: View {
    @ObservedObject var model: RecordingIndicatorModel

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
    }

    private var size: NSSize {
        model.phase == .listening
            ? NSSize(width: 138, height: 36)
            : NSSize(width: 128, height: 36)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening:
            HStack(spacing: 10) {
                PulsingDot()
                WaveformView(levels: Array(model.levels.suffix(5)))
                Text("正在聆听")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        case .transcribing:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.8))
                Text("正在转录…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }
}

/// 呼吸的录音点（与 OpenVoice 一致：1s 往复）。
struct PulsingDot: View {
    @State private var pulsing = false
    private static let dotColor = Color(red: 0.24, green: 0.84, blue: 0.42)

    var body: some View {
        Circle()
            .fill(Self.dotColor)
            .frame(width: 7, height: 7)
            .shadow(color: Self.dotColor.opacity(pulsing ? 0.7 : 0.2), radius: pulsing ? 5 : 2)
            .opacity(pulsing ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

/// 最近 5 个音量采样，向右流动（OpenVoice 的 WaveformView）。
struct WaveformView: View {
    var levels: [Float]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2.5, height: height(for: level))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: levels)
    }

    private func height(for level: Float) -> CGFloat {
        3 + CGFloat(min(1, level)) * 13
    }
}
