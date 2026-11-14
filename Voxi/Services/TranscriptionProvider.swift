import Foundation

/// 识别过程中的更新。`interim` 只更新预览，`final` 才允许写入前台应用。
enum TranscriptionUpdate: Equatable {
    case interim(String)
    case final(String)
}

struct TranscriptionOptions {
    var sessionID: UUID
    var textMode: TextMode
    var audioDuration: TimeInterval?
    /// 文件转写等长任务可覆盖端点默认超时。
    var requestTimeout: TimeInterval? = nil
    /// 个人词库：作为识别提示，并在本地修正常见误听。
    var lexicon: PersonalLexicon = PersonalLexicon()
}

/// ASR provider 统一边界。两种协议的网络交互不同，但都通过这个接口对协调器暴露。
@MainActor
protocol TranscriptionProvider: AnyObject {
    var kind: EndpointProfile.ProviderKind { get }

    func makeSession(profile: EndpointProfile, options: TranscriptionOptions) async throws -> any TranscriptionSession
}

@MainActor
protocol TranscriptionSession: AnyObject {
    /// 中间/最终结果流。OpenAI-compatible 只会在 finish 后产出（或为空）。
    var updates: AsyncThrowingStream<TranscriptionUpdate, Error> { get }

    /// 流式 provider 会立即发送；OpenAI-compatible 忽略音频，等待 finish 上传整段文件。
    func appendAudio(_ pcm16Mono16k: Data) async throws

    /// 结束录音并等待最终结果。
    func finish(recordingURL: URL) async throws -> TranscriptionResult

    /// 取消：关闭连接、丢弃迟到结果。
    func cancel() async
}

enum TranscriptionError: Error, LocalizedError, Equatable {
    case unsupportedProvider(EndpointProfile.ProviderKind)
    case invalidConfiguration(String)
    case missingCredential
    case unauthorized(status: Int)
    case rateLimited(retryAfter: String?)
    case serverError(status: Int, detail: String?)
    case httpStatus(Int, detail: String?)
    case timeout
    case cancelled
    case network(String)
    case invalidResponse(String)
    case emptyTranscript
    case unexpectedContentType(String?)
    case audioFileUnreadable

    var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(kind):
            return "当前版本尚未支持 \(kind.displayName)。"
        case let .invalidConfiguration(message):
            return message
        case .missingCredential:
            return "缺少 API Key，请在设置中重新填写。"
        case .unauthorized(let status):
            return "鉴权失败（HTTP \(status)）。请检查 API Key 是否有效、是否有该模型权限。"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "请求过于频繁（HTTP 429），请在 \(retryAfter) 秒后重试。"
            }
            return "请求过于频繁（HTTP 429），请稍后重试。"
        case let .serverError(status, detail):
            return "识别服务内部错误（HTTP \(status)）\(detail.map { "：\($0)" } ?? "")"
        case let .httpStatus(status, detail):
            return "识别服务返回 HTTP \(status)\(detail.map { "：\($0)" } ?? "")"
        case .timeout:
            return "识别请求超时。请检查网络或调大超时时间。"
        case .cancelled:
            return "识别已取消。"
        case let .network(message):
            return "网络错误：\(message)"
        case let .invalidResponse(message):
            return "无法解析识别服务的响应：\(message)"
        case .emptyTranscript:
            return "识别结果为空，没有可输入的文字。"
        case let .unexpectedContentType(contentType):
            return "响应格式不符合预期（Content-Type: \(contentType ?? "未知")）。"
        case .audioFileUnreadable:
            return "无法读取录音文件。"
        }
    }

    var isCancellation: Bool {
        self == .cancelled
    }

    /// 可重试的瞬时网络错误（断网、连接中断、DNS 失败等）。
    var isTransientNetwork: Bool {
        if case .network = self { return true }
        return false
    }

    /// 统一的 URLError 映射，避免把 -1009 直接抛给用户。
    static func mapURLError(_ error: NSError) -> TranscriptionError {
        switch error.code {
        case NSURLErrorTimedOut:
            return .timeout
        case NSURLErrorCancelled:
            return .cancelled
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorResourceUnavailable:
            return .network("网络连接不可用或已中断（\(error.code)）。请检查网络、VPN 或代理后重试。")
        default:
            return .network(error.localizedDescription)
        }
    }
}
