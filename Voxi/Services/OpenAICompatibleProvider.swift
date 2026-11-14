import Foundation

/// 构造 OpenAI-compatible `v1/audio/transcriptions` multipart 请求。
///
/// 规则：
/// - endpoint 使用 profile 中的完整 URL，不拼接厂商域名；
/// - `file`、`model`、`response_format`、`language`、`prompt` 由 Voxi 统一写入；
/// - 自定义 header 不能覆盖 `Content-Type` / `Authorization`（bearer 模式）；
/// - 自定义 form field 不能使用保留字段名（见 `EndpointProfile.reservedFormFieldNames`）。
enum OpenAICompatibleRequestBuilder {
    static func makeRequest(
        profile: EndpointProfile,
        secret: String?,
        textMode: TextMode,
        fileURL: URL,
        fileData: Data,
        secretResolver: SecretResolving,
        boundary: String = "VoxiBoundary-\(UUID().uuidString)"
    ) throws -> URLRequest {
        let validation = profile.validation()
        guard validation.isValid else {
            throw TranscriptionError.invalidConfiguration(validation.message ?? "端点配置无效。")
        }
        guard let url = URL(string: profile.endpointURL) else {
            throw TranscriptionError.invalidConfiguration("端点 URL 无效。")
        }

        var form = MultipartFormData(boundary: boundary)
        form.addField(name: "model", value: profile.openAI.model)
        form.addField(name: "response_format", value: profile.openAI.responseFormat.requestValue)

        if profile.openAI.sendsLanguageField {
            form.addField(name: "language", value: textMode.language.iso639Code)
        }
        let prompt = textMode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if profile.openAI.sendsPromptField, !prompt.isEmpty {
            form.addField(name: "prompt", value: prompt)
        }
        for field in profile.openAI.customFormFields
        where !field.name.isEmpty
            && !EndpointProfile.reservedFormFieldNames.contains(field.name.lowercased()) {
            form.addField(name: field.name, value: try resolve(field, secretResolver: secretResolver))
        }

        form.addFile(name: "file", filename: fileURL.lastPathComponent, mimeType: "audio/wav", data: fileData)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = profile.openAI.timeoutSeconds
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain;q=0.9", forHTTPHeaderField: "Accept")

        if let secret, !secret.isEmpty {
            switch profile.openAI.authMode {
            case .bearer:
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            case .customHeader:
                let name = profile.openAI.customAuthHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    request.setValue(secret, forHTTPHeaderField: name)
                }
            case .none:
                break
            }
        }

        for header in profile.openAI.customHeaders {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let lowered = name.lowercased()
            guard lowered != "content-type", lowered != "authorization" else { continue }
            request.setValue(try resolve(header, secretResolver: secretResolver), forHTTPHeaderField: name)
        }

        request.httpBody = form.finalized()
        return request
    }

    private static func resolve(_ field: EndpointProfile.HTTPField, secretResolver: SecretResolving) throws -> String {
        switch field.value {
        case .literal(let value):
            return value
        case .keychain(let itemID):
            return try secretResolver.secret(for: itemID)
        }
    }
}

/// OpenAI-compatible provider：录音期间不发送，停止后一次性上传整段 WAV。
@MainActor
final class OpenAICompatibleProvider: TranscriptionProvider {
    let kind: EndpointProfile.ProviderKind = .openAICompatible

    private let urlSession: URLSession
    private let secretResolver: SecretResolving

    init(urlSession: URLSession = .shared, secretResolver: SecretResolving = KeychainSecretResolver()) {
        self.urlSession = urlSession
        self.secretResolver = secretResolver
    }

    func makeSession(profile: EndpointProfile, options: TranscriptionOptions) async throws -> any TranscriptionSession {
        let validation = profile.validation()
        guard validation.isValid else {
            throw TranscriptionError.invalidConfiguration(validation.message ?? "端点配置无效。")
        }
        return OpenAICompatibleSession(
            profile: profile,
            options: options,
            urlSession: urlSession,
            secretResolver: secretResolver
        )
    }
}

@MainActor
final class OpenAICompatibleSession: TranscriptionSession {
    let updates: AsyncThrowingStream<TranscriptionUpdate, Error>

    private let profile: EndpointProfile
    private let options: TranscriptionOptions
    private let urlSession: URLSession
    private let secretResolver: SecretResolving
    private let continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    private var uploadTask: Task<TranscriptionResult, Error>?
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

    /// OpenAI-compatible 接口不做实时识别，因此忽略录音中的分片。
    func appendAudio(_ pcm16Mono16k: Data) async throws {
        // 有意为空：不发送伪造的中间请求。
    }

    func finish(recordingURL: URL) async throws -> TranscriptionResult {
        guard !isFinished else { throw TranscriptionError.cancelled }
        isFinished = true

        let task = Task { () -> TranscriptionResult in
            try await self.performUpload(recordingURL: recordingURL)
        }
        uploadTask = task

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            uploadTask = nil
            continuation.yield(.final(result.text))
            continuation.finish()
            return result
        } catch {
            uploadTask = nil
            let mapped = Self.mapError(error)
            continuation.finish(throwing: mapped)
            throw mapped
        }
    }

    func cancel() async {
        isFinished = true
        uploadTask?.cancel()
        uploadTask = nil
        continuation.finish()
    }

    // MARK: - 上传

    private func performUpload(recordingURL: URL) async throws -> TranscriptionResult {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: recordingURL)
        } catch {
            throw TranscriptionError.audioFileUnreadable
        }

        let secret: String?
        if let itemID = profile.apiKeyItemID {
            secret = try await SecretReader.secret(secretResolver, for: itemID)
        } else {
            secret = nil
        }
        var request = try OpenAICompatibleRequestBuilder.makeRequest(
            profile: profile,
            secret: secret,
            textMode: options.textMode,
            fileURL: recordingURL,
            fileData: fileData,
            secretResolver: secretResolver
        )
        if let override = options.requestTimeout {
            request.timeoutInterval = override
        }

        Logger.http.info("上传转写请求 url=\(Logger.redactedURL(self.profile.endpointURL), privacy: .public) bytes=\(fileData.count, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Self.mapError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse("缺少 HTTP 响应")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw TranscriptionError.unauthorized(status: httpResponse.statusCode)
        case 429:
            throw TranscriptionError.rateLimited(retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After"))
        case 500..<600:
            throw TranscriptionError.serverError(
                status: httpResponse.statusCode,
                detail: Self.safeDetail(from: data)
            )
        default:
            throw TranscriptionError.httpStatus(httpResponse.statusCode, detail: Self.safeDetail(from: data))
        }

        let text = try Self.parseTranscript(data: data, response: httpResponse, configuredFormat: profile.openAI.responseFormat)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.emptyTranscript }

        Logger.http.info("转写成功 status=\(httpResponse.statusCode, privacy: .public) chars=\(trimmed.count, privacy: .public)")

        return TranscriptionResult(
            text: trimmed,
            providerKind: profile.kind,
            sessionID: options.sessionID,
            requestID: httpResponse.value(forHTTPHeaderField: "x-request-id"),
            logID: nil,
            audioDuration: options.audioDuration
        )
    }

    // MARK: - 解析与错误

    static func parseTranscript(
        data: Data,
        response: HTTPURLResponse,
        configuredFormat: EndpointProfile.OpenAIOptions.ResponseFormat
    ) throws -> String {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased()

        if let contentType, contentType.contains("application/json") {
            return try parseJSONText(data)
        }
        if let contentType, contentType.contains("text/") {
            return String(decoding: data, as: UTF8.self)
        }
        // 未声明 Content-Type（部分自建端点）时按配置格式尝试。
        switch configuredFormat {
        case .json:
            return try parseJSONText(data)
        case .text:
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func parseJSONText(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.invalidResponse("期望 JSON 对象")
        }
        if let text = object["text"] as? String {
            return text
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            throw TranscriptionError.invalidResponse(message)
        }
        throw TranscriptionError.invalidResponse("JSON 中缺少 text 字段")
    }

    /// 只保留很短的服务端错误片段，避免把敏感内容写进日志或 UI。
    private static func safeDetail(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let raw = String(decoding: data.prefix(400), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    static func mapError(_ error: Error) -> TranscriptionError {
        if let transcriptionError = error as? TranscriptionError {
            return transcriptionError
        }
        if error is CancellationError {
            return .cancelled
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return TranscriptionError.mapURLError(nsError)
        }
        return .network(nsError.localizedDescription)
    }
}
