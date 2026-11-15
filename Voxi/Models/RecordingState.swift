import Foundation

/// 一次录音流程的全局状态。由 `AppCoordinator` 独占修改。
///
/// 合法流转（所有 provider 共用骨架，`connecting` 仅流式 provider 使用）：
///
/// ```
/// idle -> requestingPermission -> connecting? -> recording -> finalizingAudio
///      -> transcribing -> inserting -> idle
/// 任意处理中状态 -> cancelling -> idle
/// 任意状态 -> failed -> idle
/// ```
enum RecordingState: String, Codable, CaseIterable, Equatable {
    case idle
    case requestingPermission
    case connecting
    case recording
    case finalizingAudio
    case transcribing
    case inserting
    case cancelling
    case failed

    /// 是否处于一次录音流程内（此时拒绝重复开始）。
    var isBusy: Bool {
        switch self {
        case .idle, .failed:
            return false
        default:
            return true
        }
    }

    /// 是否已停止采集、正在等待识别结果。
    var isAwaitingResult: Bool {
        switch self {
        case .finalizingAudio, .transcribing:
            return true
        default:
            return false
        }
    }

    var isRecording: Bool {
        self == .recording
    }

    /// 状态机允许的下一状态集合。相同状态不算一步转换。
    var allowedNextStates: Set<RecordingState> {
        switch self {
        case .idle:
            return [.requestingPermission, .connecting, .recording, .failed]
        case .requestingPermission:
            return [.connecting, .recording, .cancelling, .failed]
        case .connecting:
            return [.recording, .cancelling, .failed]
        case .recording:
            return [.finalizingAudio, .cancelling, .failed]
        case .finalizingAudio:
            // 直接回 idle：音频为空或没有可发送的内容，无需请求服务。
            return [.transcribing, .idle, .cancelling, .failed]
        case .transcribing:
            return [.inserting, .idle, .cancelling, .failed]
        case .inserting:
            return [.idle, .cancelling, .failed]
        case .cancelling:
            return [.idle, .failed]
        case .failed:
            return [.idle]
        }
    }

    func canTransition(to next: RecordingState) -> Bool {
        allowedNextStates.contains(next)
    }

    /// 状态在菜单栏中的简短描述。
    var menuTitle: String {
        switch self {
        case .idle: return "待机"
        case .requestingPermission: return "请求麦克风权限…"
        case .connecting: return "连接识别服务…"
        case .recording: return "录音中"
        case .finalizingAudio: return "整理音频…"
        case .transcribing: return "识别中…"
        case .inserting: return "输入文字…"
        case .cancelling: return "取消中…"
        case .failed: return "出错"
        }
    }
}

/// 状态机错误在协调器中统一转换为可读提示。
enum RecordingStateError: LocalizedError, Equatable {
    case illegalTransition(from: RecordingState, to: RecordingState)

    var errorDescription: String? {
        switch self {
        case let .illegalTransition(from, to):
            return "内部状态错误：无法从「\(from.menuTitle)」切换到「\(to.menuTitle)」"
        }
    }
}
