import Foundation

/// 快捷键行为：按住说话，或按一次开始、再按一次结束。
enum RecordingMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case holdToTalk
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .holdToTalk: return "按住说话"
        case .toggle: return "按下开始 / 再次按下结束"
        }
    }

    var explanation: String {
        switch self {
        case .holdToTalk: return "按住快捷键录音，松开后结束并识别。"
        case .toggle: return "按一次快捷键开始录音，再按一次结束并识别。"
        }
    }
}
