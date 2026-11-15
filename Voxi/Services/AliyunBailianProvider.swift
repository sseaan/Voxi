import Foundation

/// 阿里云百炼 Paraformer 实时语音识别（DashScope WebSocket）。
///
/// 协议：`run-task` → `task-started` → 发送 PCM → `result-generated`（中间/最终）→
/// `finish-task` → `task-finished`；失败为 `task-failed`。
/// 文档：https://help.aliyun.com/zh/model-studio/websocket-for-paraformer-real-time-service
@MainActor
final class AliyunBailianProvider: TranscriptionProvider {
    let kind: EndpointProfile.ProviderKind = .aliyunBailianStreaming

    private let transportFactory: () -> VolcengineWebSocketTransport
    private let secretResolver: SecretResolving
    private let readyTimeout: TimeInterval
    private let finalResultTimeout: TimeInterval

    init(
        transportFactory: @escaping () -> VolcengineWebSocketTransport = { URLSessionWebSocketTransport() },
        secretResolver: SecretResolving = KeychainSecretResolver(),
        readyTimeout: TimeInterval = 10,
        finalResultTimeout: TimeInterval = 15
    ) {
        self.transportFactory = transportFactory
        self.secretResolver = secretResolver
        self.readyTimeout = readyTimeout
        self.finalResultTimeout = finalResultTimeout
    }

    func makeSession(
        profile: EndpointProfile,
        options: TranscriptionOptions
    ) async throws -> any TranscriptionSession {
        guard profile.kind == .aliyunBailianStreaming else {
            throw TranscriptionError.unsupportedProvider(profile.kind)
        }
        let validation = profile.validation()
        guard validation.isValid else {
            throw TranscriptionError.invalidConfiguration(validation.message ?? "阿里云百炼端点配置无效。")
        }
        guard let url = URL(string: profile.endpointURL) else {
            throw TranscriptionError.invalidConfiguration("阿里云百炼 endpoint URL 无效。")
        }
        guard let keyID = profile.apiKeyItemID else {
            throw TranscriptionError.missingCredential
        }
        let apiKey = try await SecretReader.secret(secretResolver, for: keyID)

        let taskID = UUID().uuidString
        let runTask = try AliyunRequestBuilder.runTaskJSON(
            profile: profile,
            textMode: options.textMode,
            taskID: taskID
        )
        let session = AliyunBailianSession(
            profile: profile,
            options: options,
            transport: transportFactory(),
            taskID: taskID,
            finalResultTimeout: finalResultTimeout
        )

        let start = Date()
        do {
            try await session.start(
                url: url,
                headers: AliyunRequestBuilder.headers(apiKey: apiKey),
                runTaskJSON: runTask,
                timeout: readyTimeout
            )
        } catch {
            await session.cancel()
            throw error
        }
        Logger.websocket.info(
            "百炼连接就绪 url=\(Logger.redactedURL(profile.endpointURL), privacy: .public) taskID=\(taskID, privacy: .public) elapsed=\(Date().timeIntervalSince(start), privacy: .public)s"
        )
        return session
    }
}

enum AliyunRequestBuilder {
    static func headers(apiKey: String) -> [String: String] {
        [
            "Authorization": "Bearer \(apiKey)",
            "user-agent": "Voxi/\(Bundle.main.shortVersion) (macOS)"
        ]
    }

    static func runTaskJSON(
        profile: EndpointProfile,
        textMode: TextMode,
        taskID: String
    ) throws -> Data {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16_000,
            "semantic_punctuation_enabled": profile.aliyun.semanticPunctuation,
            "max_sentence_silence": profile.aliyun.maxSentenceSilence,
            "punctuation_prediction_enabled": profile.aliyun.punctuationPrediction
                && textMode.addPunctuation,
            "disfluency_removal_enabled": profile.aliyun.disfluencyRemoval,
            "heartbeat": true
        ]
        let hints = profile.aliyun.languageHintList
        if !hints.isEmpty {
            parameters["language_hints"] = hints
        }
        let vocabulary = profile.aliyun.vocabularyID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocabulary.isEmpty {
            parameters["vocabulary_id"] = vocabulary
        }

        let root: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": profile.aliyun.model,
                "input": [:],
                "parameters": parameters
            ]
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func finishTaskJSON(taskID: String) throws -> Data {
        let root: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": ["input": [:]]
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

/// 事件解析：只关心 header.event 与 payload.output.sentence。
struct AliyunServerEvent: Equatable {
    var event: String
    var errorCode: String?
    var errorMessage: String?
    var sentenceText: String?
    var sentenceEnd: Bool
    var heartbeat: Bool

    static func parse(_ data: Data) throws -> AliyunServerEvent {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any],
              let event = header["event"] as? String
        else {
            throw TranscriptionError.invalidResponse("百炼事件不是合法 JSON")
        }
        let payload = root["payload"] as? [String: Any]
        let output = payload?["output"] as? [String: Any]
        let sentence = output?["sentence"] as? [String: Any]
        return AliyunServerEvent(
            event: event,
            errorCode: header["error_code"] as? String,
            errorMessage: header["error_message"] as? String,
            sentenceText: sentence?["text"] as? String,
            sentenceEnd: sentence?["sentence_end"] as? Bool ?? false,
            heartbeat: sentence?["heartbeat"] as? Bool ?? false
        )
    }
}

/// 把逐句结果拼成整段文本：中文直接相邻，英文句子之间补空格。
struct AliyunTranscriptAccumulator: Equatable {
    private(set) var finalized: [String] = []
    private(set) var current: String = ""

    mutating func apply(text: String, sentenceEnd: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if sentenceEnd {
            finalized.append(trimmed)
            current = ""
        } else {
            current = trimmed
        }
    }

    var text: String {
        var result = ""
        for piece in finalized + (current.isEmpty ? [] : [current]) {
            result = Self.join(result, piece)
        }
        return result
    }

    private static func join(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        let lhsASCII = lhs.last?.isASCII ?? false
        let rhsASCII = rhs.first?.isASCII ?? false
        return (lhsASCII && rhsASCII) ? lhs + " " + rhs : lhs + rhs
    }
}

@MainActor
final class AliyunBailianSession: TranscriptionSession {
    let updates: AsyncThrowingStream<TranscriptionUpdate, Error>

    private let profile: EndpointProfile
    private let options: TranscriptionOptions
    private let transport: VolcengineWebSocketTransport
    private let taskID: String
    private let finalResultTimeout: TimeInterval
    private let continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation

    private var accumulator = AliyunTranscriptAccumulator()
    private var receiveTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var finalContinuation: CheckedContinuation<TranscriptionResult, Error>?

    private var finalResult: TranscriptionResult?
    private var failure: Error?
    private var isReady = false
    private var isCancelled = false
    private var isFinished = false
    private var lastPreview = ""

    init(
        profile: EndpointProfile,
        options: TranscriptionOptions,
        transport: VolcengineWebSocketTransport,
        taskID: String,
        finalResultTimeout: TimeInterval
    ) {
        self.profile = profile
        self.options = options
        self.transport = transport
        self.taskID = taskID
        self.finalResultTimeout = finalResultTimeout

        var streamContinuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation!
        self.updates = AsyncThrowingStream { streamContinuation = $0 }
        self.continuation = streamContinuation
    }

    // MARK: - 建连

    func start(url: URL, headers: [String: String], runTaskJSON: Data, timeout: TimeInterval) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = max(15, timeout + 5)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let runTaskText = String(decoding: runTaskJSON, as: UTF8.self)

        do {
            let transport = self.transport
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = AliyunOnceResume(continuation)
                Task.detached {
                    do {
                        try await transport.connect(request: request)
                        try await transport.sendText(runTaskText)
                        once.resume(.success(()))
                    } catch {
                        once.resume(.failure(error))
                    }
                }
                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if once.resume(.failure(TranscriptionError.timeout)) {
                        transport.close()
                    }
                }
            }
        } catch {
            transport.close()
            throw Self.mapError(error)
        }

        startReceiving()
        try await waitUntilReady(timeout: timeout)
    }

    // MARK: - TranscriptionSession

    func appendAudio(_ pcm16Mono16k: Data) async throws {
        guard !isFinished, !isCancelled, !pcm16Mono16k.isEmpty else { return }
        do {
            try await transport.send(pcm16Mono16k)
        } catch {
            let mapped = Self.mapError(error)
            fail(mapped)
            throw mapped
        }
    }

    func finish(recordingURL: URL) async throws -> TranscriptionResult {
        guard !isFinished else { throw TranscriptionError.cancelled }
        isFinished = true
        if let failure { throw failure }

        do {
            try await transport.sendText(
                String(decoding: try AliyunRequestBuilder.finishTaskJSON(taskID: taskID), as: UTF8.self)
            )
        } catch {
            let mapped = Self.mapError(error)
            fail(mapped)
            throw failure ?? mapped
        }
        return try await waitForFinalResult()
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        receiveTask?.cancel()
        receiveTask = nil
        transport.close()
        resumePendingContinuations(with: TranscriptionError.cancelled)
        continuation.finish()
    }

    // MARK: - 收包

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    guard let data = try await self.transport.receive() else {
                        self.handleConnectionClosed()
                        return
                    }
                    try self.handleFrame(data)
                    if self.finalResult != nil || self.isCancelled {
                        return
                    }
                } catch {
                    if self.isCancelled { return }
                    self.fail(Self.mapError(error))
                    return
                }
            }
        }
    }

    private func handleFrame(_ data: Data) throws {
        let event = try AliyunServerEvent.parse(data)
        switch event.event {
        case "task-started":
            markReady()

        case "result-generated":
            if event.heartbeat { return }
            if let text = event.sentenceText {
                accumulator.apply(text: text, sentenceEnd: event.sentenceEnd)
                let preview = accumulator.text
                if !preview.isEmpty, preview != lastPreview {
                    lastPreview = preview
                    continuation.yield(.interim(preview))
                }
            }
            if event.sentenceEnd {
                continuation.yield(.interim(accumulator.text))
            }

        case "task-finished":
            complete()

        case "task-failed":
            let code = event.errorCode ?? "UNKNOWN"
            let message = event.errorMessage ?? "任务失败"
            fail(TranscriptionError.remoteError("\(code)：\(message)"))

        default:
            Logger.websocket.debug("忽略百炼事件 \(event.event, privacy: .public)")
        }
    }

    private func handleConnectionClosed() {
        guard !isCancelled, finalResult == nil else { return }
        if isFinished, !accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            complete()
        } else {
            fail(TranscriptionError.invalidResponse("连接已关闭，未收到最终识别结果"))
        }
    }

    private func complete() {
        guard finalResult == nil, !isCancelled else { return }
        let text = accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            fail(TranscriptionError.emptyTranscript)
            return
        }
        let result = TranscriptionResult(
            text: text,
            providerKind: .aliyunBailianStreaming,
            sessionID: options.sessionID,
            requestID: taskID,
            logID: nil,
            audioDuration: options.audioDuration
        )
        finalResult = result
        continuation.yield(.final(text))
        continuation.finish()
        finalContinuation?.resume(returning: result)
        finalContinuation = nil
        transport.close()
    }

    // MARK: - 等待

    private func waitUntilReady(timeout: TimeInterval) async throws {
        if isReady { return }
        if let failure { throw failure }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    try await self?.awaitReady()
                }
                group.addTask { [weak self] in
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await MainActor.run {
                        self?.resumeReady(with: TranscriptionError.timeout)
                    }
                    throw TranscriptionError.timeout
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            let mapped = Self.mapError(error)
            resumeReady(with: mapped)
            throw mapped
        }
    }

    private func awaitReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if isReady {
                continuation.resume()
            } else if let failure {
                continuation.resume(throwing: failure)
            } else if isCancelled {
                continuation.resume(throwing: TranscriptionError.cancelled)
            } else {
                readyContinuation = continuation
            }
        }
    }

    private func markReady() {
        guard !isReady else { return }
        isReady = true
        readyContinuation?.resume()
        readyContinuation = nil
    }

    private func waitForFinalResult() async throws -> TranscriptionResult {
        if let finalResult { return finalResult }
        if let failure { throw failure }

        do {
            return try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
                group.addTask { [weak self] in
                    guard let self else { throw TranscriptionError.cancelled }
                    return try await self.awaitFinalResult()
                }
                group.addTask { [weak self, finalResultTimeout] in
                    try await Task.sleep(nanoseconds: UInt64(finalResultTimeout * 1_000_000_000))
                    await MainActor.run {
                        self?.resumeFinal(with: TranscriptionError.timeout)
                    }
                    throw TranscriptionError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            let mapped = Self.mapError(error)
            resumeFinal(with: mapped)
            throw mapped
        }
    }

    private func awaitFinalResult() async throws -> TranscriptionResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscriptionResult, Error>) in
            if let finalResult {
                continuation.resume(returning: finalResult)
            } else if let failure {
                continuation.resume(throwing: failure)
            } else if isCancelled {
                continuation.resume(throwing: TranscriptionError.cancelled)
            } else {
                finalContinuation = continuation
            }
        }
    }

    private func fail(_ error: Error) {
        guard finalResult == nil, !isCancelled else { return }
        failure = error
        resumePendingContinuations(with: error)
        continuation.finish(throwing: error)
        transport.close()
        Logger.websocket.error(
            "百炼会话失败 taskID=\(self.taskID, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
    }

    private func resumeReady(with error: Error) {
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
    }

    private func resumeFinal(with error: Error) {
        finalContinuation?.resume(throwing: error)
        finalContinuation = nil
    }

    private func resumePendingContinuations(with error: Error) {
        resumeReady(with: error)
        resumeFinal(with: error)
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
            if nsError.code == NSURLErrorBadServerResponse {
                return TranscriptionError.invalidResponse("百炼 WebSocket 握手被拒绝（请检查 API Key / 模型权限）")
            }
            return TranscriptionError.mapURLError(nsError)
        }
        return TranscriptionError.network(nsError.localizedDescription)
    }
}

/// 只允许第一个结果生效，避免建连/超时竞速双方重复 resume。
final class AliyunOnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return false
        }
        didResume = true
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
