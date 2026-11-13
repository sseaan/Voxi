import Foundation
import SwiftUI

/// 单一 UI 状态来源。只保存当前状态、提示、当前 provider 与临时识别预览；
/// 所有状态写入都必须经过 `AppCoordinator`。
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var activeProviderKind: EndpointProfile.ProviderKind?
    /// 火山流式识别的临时文本，仅用于菜单栏预览，绝不插入前台应用。
    @Published private(set) var interimText: String = ""
    @Published private(set) var sessionID: UUID?
    @Published private(set) var recordingStartedAt: Date?
    /// 最近一次最终结果，用于自动输入失败时的复制回退。
    @Published private(set) var lastResult: TranscriptionResult?
    @Published private(set) var lastLogID: String?

    // MARK: - 协调器内部写入

    func beginSession(id: UUID, provider: EndpointProfile.ProviderKind) {
        sessionID = id
        activeProviderKind = provider
        interimText = ""
        lastResult = nil
        lastLogID = nil
        errorMessage = nil
        noticeMessage = nil
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

    func present(error: String?) {
        errorMessage = error
        if error != nil {
            noticeMessage = nil
        }
    }

    func present(notice: String?) {
        noticeMessage = notice
        if notice != nil {
            errorMessage = nil
        }
    }

    func clearMessages() {
        errorMessage = nil
        noticeMessage = nil
    }

    func endSession() {
        sessionID = nil
        interimText = ""
        recordingStartedAt = nil
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
