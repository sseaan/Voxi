import Foundation

/// 小米 MiMo 语音识别（MiMo-V2.5-ASR）。
///
/// 注意：MiMo 不使用 `/v1/audio/transcriptions`，而是 OpenAI 兼容的
/// `/v1/chat/completions`：音频以 base64 `input_audio` 放进 user message，
/// 结果从 `choices[0].message.content` 读取；鉴权用 `api-key` header。
/// 文档：https://mimo.mi.com/docs/zh-CN/api/audio/Speech-Recognition
@MainActor
final class MiMOASRProvider: TranscriptionProvider {
    let kind: EndpointProfile.ProviderKind = .mimoASR

    private let urlSession: URLSession
    private let secretResolver: SecretResolving

    init(urlSession: URLSession = .shared, secretResolver: SecretResolving = KeychainSecretResolver()) {
        self.urlSession = urlSession
        self.secretResolver = secretResolver
    }

    func makeSession(
        profile: EndpointProfile,
        options: TranscriptionOptions
    ) async throws -> any TranscriptionSession {
        guard profile.kind == .mimoASR else {
            throw TranscriptionError.unsupportedProvider(profile.kind)
        }
        let validation = profile.validation()
        guard validation.isValid else {
            throw TranscriptionError.invalidConfiguration(validation.message ?? "MiMo 端点配置无效。")
        }
        return MiMOASRSession(
            profile: profile,
            options: options,
            urlSession: urlSession,
            secretResolver: secretResolver
        )
    }
}

enum MiMORequestBuilder {
    static func makeRequest(
        profile: EndpointProfile,
        apiKey: String,
        audioData: Data,
        format: String = "wav",
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: profile.endpointURL) else {
            throw TranscriptionError.invalidConfiguration("MiMo endpoint URL 无效。")
        }
        guard audioData.count <= profile.mimo.maxAudioBytes else {
            let limit = Double(profile.mimo.maxAudioBytes) / 1_000_000
            let actual = Double(audioData.count) / 1_000_000
            throw TranscriptionError.invalidConfiguration(
                String(format: "音频大小 %.1fMB 超过 MiMo 单次请求上限 %.1fMB，请缩短录音。", actual, limit)
            )
        }
        let mime = format == "mp3" ? "audio/mpeg" : "audio/wav"
        let dataURL = "data:\(mime);base64,\(audioData.base64EncodedString())"
        let body: [String: Any] = [
            "model": profile.mimo.model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": dataURL,
                                "format": format
                            ]
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 从 Chat Completions 响应中取转写文本。
    static func parseTranscript(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.invalidResponse("MiMo 响应不是合法 JSON")
        }
        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw TranscriptionError.remoteError(message)
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else {
            throw TranscriptionError.invalidResponse("MiMo 响应缺少 choices")
        }
        if let text = message["content"] as? String {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        throw TranscriptionError.invalidResponse("MiMo 响应缺少文本内容")
    }
}

@MainActor
final class MiMOASRSession: TranscriptionSession {
    let updates: AsyncThrowingStream<TranscriptionUpdate, Error>

    private let profile: EndpointProfile
    private let options: TranscriptionOptions
    private let urlSession: URLSession
    private let secretResolver: SecretResolving
    private let continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    private var isCancelled = false
    private var isFinished = false

    init(
        profile: EndpointProfile,
        options: TranscriptionOptions,
        urlSession: URLSession,
        secretResolver: SecretResolving
    ) {
        self.profile = profile
        self.options = options
        self.urlSession = urlSession
        self.secretResolver = secretResolver
        var streamContinuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation!
        self.updates = AsyncThrowingStream { streamContinuation = $0 }
        self.continuation = streamContinuation
    }

    /// MiMo 只接受整段音频，录音过程中不发送。
    func appendAudio(_ pcm16Mono16k: Data) async throws {}

    func finish(recordingURL: URL) async throws -> TranscriptionResult {
        guard !isFinished else { throw TranscriptionError.cancelled }
        isFinished = true
        guard !isCancelled else { throw TranscriptionError.cancelled }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: recordingURL)
        } catch {
            throw TranscriptionError.audioFileUnreadable
        }
        guard !audioData.isEmpty else { throw TranscriptionError.emptyTranscript }
        guard let keyID = profile.apiKeyItemID else { throw TranscriptionError.missingCredential }
        let apiKey = try await SecretReader.secret(secretResolver, for: keyID)

        let timeout = options.requestTimeout ?? profile.mimo.timeoutSeconds
        let request = try MiMORequestBuilder.makeRequest(
            profile: profile,
            apiKey: apiKey,
            audioData: audioData,
            timeout: timeout
        )
        Logger.http.info(
            "MiMo 上传转写 url=\(Logger.redactedURL(self.profile.endpointURL), privacy: .public) bytes=\(audioData.count, privacy: .public)"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Self.mapError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse("缺少 HTTP 响应")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw TranscriptionError.unauthorized(status: http.statusCode)
        case 429:
            throw TranscriptionError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        case 500..<600:
            throw TranscriptionError.serverError(status: http.statusCode, detail: Self.safeDetail(data))
        default:
            throw TranscriptionError.httpStatus(http.statusCode, detail: Self.safeDetail(data))
        }

        let text = try MiMORequestBuilder.parseTranscript(data)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }

        let result = TranscriptionResult(
            text: text,
            providerKind: .mimoASR,
            sessionID: options.sessionID,
            requestID: http.value(forHTTPHeaderField: "x-request-id"),
            logID: nil,
            audioDuration: options.audioDuration
        )
        continuation.yield(.final(text))
        continuation.finish()
        return result
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        continuation.finish()
    }

    private static func safeDetail(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let raw = String(decoding: data.prefix(400), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    static func mapError(_ error: Error) -> Error {
        if let transcriptionError = error as? TranscriptionError {
            return transcriptionError
        }
        if error is CancellationError {
            return TranscriptionError.cancelled
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return TranscriptionError.mapURLError(nsError)
        }
        return TranscriptionError.network(nsError.localizedDescription)
    }
}
