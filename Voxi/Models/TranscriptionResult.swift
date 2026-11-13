import Foundation

/// 一次录音流程的最终识别结果。
///
/// 只包含写入前台应用所需的信息；不保存音频与历史记录。
struct TranscriptionResult: Codable, Equatable {
    /// 最终文本（未经 `TextMode` 后处理）；临时/中间结果绝不写入这里。
    var text: String
    var providerKind: EndpointProfile.ProviderKind
    /// 本次录音的 session ID，用于丢弃迟到结果。
    var sessionID: UUID
    /// 服务端请求 ID（若提供）。
    var requestID: String?
    /// 火山引擎 `X-Tt-Logid` 等诊断信息，可展示给用户排障。
    var logID: String?
    /// 音频时长（秒），仅用于诊断。
    var audioDuration: TimeInterval?
    var createdAt: Date

    init(
        text: String,
        providerKind: EndpointProfile.ProviderKind,
        sessionID: UUID,
        requestID: String? = nil,
        logID: String? = nil,
        audioDuration: TimeInterval? = nil,
        createdAt: Date = Date()
    ) {
        self.text = text
        self.providerKind = providerKind
        self.sessionID = sessionID
        self.requestID = requestID
        self.logID = logID
        self.audioDuration = audioDuration
        self.createdAt = createdAt
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
