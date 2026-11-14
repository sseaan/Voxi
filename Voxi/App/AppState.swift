import Foundation
import SwiftUI

/// 可恢复错误。UI 根据 `recovery` 提供“打开系统设置”“复制文本”等动作。
struct AppError: Identifiable, Equatable {
    enum Recovery: Equatable {
        case openMicrophoneSettings
        case openAccessibilitySettings
        case copyTranscript(String)
    }

    var id = UUID()
    var message: String
    var recovery: Recovery?

    init(message: String, recovery: Recovery? = nil) {
        self.message = message
        self.recovery = recovery
    }
}

/// 单一 UI 状态来源。只保存当前状态、提示、当前 provider 与临时识别预览；
/// 所有状态写入都必须经过 `AppCoordinator`。
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var error: AppError?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var activeProviderKind: EndpointProfile.ProviderKind?
    /// 火山流式识别的临时文本，仅用于菜单栏预览，绝不插入前台应用。
    @Published private(set) var interimText: String = ""
    @Published private(set) var sessionID: UUID?
    @Published private(set) var recordingStartedAt: Date?
    /// 最近一次最终结果，用于自动输入失败时的复制回退。
    @Published private(set) var lastResult: TranscriptionResult?
    @Published private(set) var lastLogID: String?
    /// 最近约 36 个 200ms 音频片段的归一化音量，用于录音浮条波形。
    @Published private(set) var audioLevels: [Float] = []

    var errorMessage: String? { error?.message }

    // MARK: - 协调器内部写入

    func beginSession(id: UUID, provider: EndpointProfile.ProviderKind) {
        sessionID = id
        activeProviderKind = provider
        interimText = ""
        lastResult = nil
        lastLogID = nil
        audioLevels = []
        error = nil
        noticeMessage = nil
    }

    func updateAudioLevel(_ level: Float) {
        var levels = audioLevels
        levels.append(max(0, min(1, level)))
        if levels.count > 36 {
            levels.removeFirst(levels.count - 36)
        }
        audioLevels = levels
    }

    func updateState(_ newState: RecordingState, startedAt: Date?) {
        state = newState
        recordingStartedAt = (newState == .recording) ? (startedAt ?? Date()) : nil
    }

    func setInterimText(_ text: String) {
        interimText = text
    }

    func setLastResult(_ result: TranscriptionResult?) {
        lastResult = result
        if let logID = result?.logID {
            lastLogID = logID
        }
    }

    func present(error: AppError?) {
        self.error = error
        if error != nil {
            noticeMessage = nil
        }
    }

    func present(notice: String?) {
        noticeMessage = notice
        if notice != nil {
            error = nil
        }
    }

    func clearMessages() {
        error = nil
        noticeMessage = nil
    }

    func endSession() {
        sessionID = nil
        interimText = ""
        recordingStartedAt = nil
        audioLevels = []
    }
}

extension RecordingState {
    /// 菜单栏图标（SF Symbols）。
    var menuBarSystemImage: String {
        switch self {
        case .idle: return "waveform"
        case .requestingPermission: return "mic.badge.plus"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .recording: return "waveform.circle.fill"
        case .finalizingAudio: return "waveform.badge.magnifyingglass"
        case .transcribing: return "ellipsis.circle"
        case .inserting: return "text.cursor"
        case .cancelling: return "xmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
