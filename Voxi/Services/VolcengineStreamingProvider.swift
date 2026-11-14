import Foundation

/// 火山引擎流式 ASR（双向流式优化版 bigmodel_async）。
@MainActor
final class VolcengineStreamingProvider: TranscriptionProvider {
    let kind: EndpointProfile.ProviderKind = .volcengineStreaming

    private let transportFactory: () -> VolcengineWebSocketTransport
    private let secretResolver: SecretResolving
    private let initializationTimeout: TimeInterval
    private let finalResultTimeout: TimeInterval

    init(
        transportFactory: @escaping () -> VolcengineWebSocketTransport = { URLSessionWebSocketTransport() },
        secretResolver: SecretResolving = KeychainSecretResolver(),
        initializationTimeout: TimeInterval = 8,
        finalResultTimeout: TimeInterval = 10
    ) {
        self.transportFactory = transportFactory
        self.secretResolver = secretResolver
        self.initializationTimeout = initializationTimeout
        self.finalResultTimeout = finalResultTimeout
    }

    func makeSession(profile: EndpointProfile, options: TranscriptionOptions) async throws -> any TranscriptionSession {
        guard profile.kind == .volcengineStreaming else {
            throw TranscriptionError.unsupportedProvider(profile.kind)
        }
        let validation = profile.validation()
        guard validation.isValid else {
            throw TranscriptionError.invalidConfiguration(validation.message ?? "火山端点配置无效。")
        }
        guard let url = URL(string: profile.endpointURL) else {
            throw TranscriptionError.invalidConfiguration("火山 endpoint URL 无效。")
        }

        let credentials = try await resolveCredentials(profile: profile)
        let connectID = UUID()
        let requestID = UUID()
        let headers = VolcengineRequestBuilder.headers(
            profile: profile,
            credentials: credentials,
            connectID: connectID,
            requestID: requestID
        )
        let initializationJSON = try VolcengineRequestBuilder.initializationJSON(
            profile: profile,
            textMode: options.textMode
        )

        let mode: VolcengineTranscriptAccumulator.Mode = profile.volcengine.resultType == .full ? .full : .single
        let session = VolcengineStreamingSession(
            profile: profile,
            options: options,
            transport: transportFactory(),
            accumulator: VolcengineTranscriptAccumulator(mode: mode),
            requestID: requestID.uuidString,
            finalResultTimeout: finalResultTimeout
        )

        let start = Date()
        do {
            try await session.start(url: url, headers: headers, initializationJSON: initializationJSON, timeout: initializationTimeout)
        } catch {
            await session.cancel()
            throw error
        }

        Logger.websocket.info(
            "火山连接就绪 url=\(Logger.redactedURL(profile.endpointURL), privacy: .public) requestID=\(requestID.uuidString, privacy: .public) logID=\(session.logID ?? "nil", privacy: .public) elapsed=\(Date().timeIntervalSince(start), privacy: .public)s"
        )
        return session
    }

    private func resolveCredentials(profile: EndpointProfile) async throws -> VolcengineRequestBuilder.Credentials {
        switch profile.volcengine.authMode {
        case .apiKey:
            guard let id = profile.apiKeyItemID else { throw TranscriptionError.missingCredential }
            return .init(apiKey: try await SecretReader.secret(secretResolver, for: id), appKey: nil, accessKey: nil)
        case .legacy:
            guard let appID = profile.appKeyItemID, let accessID = profile.accessKeyItemID else {
                throw TranscriptionError.missingCredential
            }
            return .init(
                apiKey: nil,
                appKey: try await SecretReader.secret(secretResolver, for: appID),
                accessKey: try await SecretReader.secret(secretResolver, for: accessID)
            )
        }
    }
}

enum VolcengineRequestBuilder {
    struct Credentials {
        var apiKey: String?
        var appKey: String?
        var accessKey: String?
    }

    /// 建连 headers。新版/旧版凭据绝不混发。
    static func headers(
        profile: EndpointProfile,
        credentials: Credentials,
        connectID: UUID,
        requestID: UUID
    ) -> [String: String] {
        var headers: [String: String] = [
            "X-Api-Resource-Id": profile.volcengine.resourceID,
            "X-Api-Connect-Id": connectID.uuidString,
            "X-Api-Request-Id": requestID.uuidString
        ]

        switch profile.volcengine.authMode {
        case .apiKey:
            if let apiKey = credentials.apiKey, !apiKey.isEmpty {
                headers["X-Api-Key"] = apiKey
            }
            // 新版控制台不需要 X-Api-Sequence；仅当用户所选接口要求时发送。
            if profile.volcengine.sendsApiSequenceHeader {
                headers["X-Api-Sequence"] = "-1"
            }
        case .legacy:
            if let appKey = credentials.appKey, !appKey.isEmpty {
                headers["X-Api-App-Key"] = appKey
            }
            if let accessKey = credentials.accessKey, !accessKey.isEmpty {
                headers["X-Api-Access-Key"] = accessKey
            }
            // 旧版控制台官方示例固定值。
            headers["X-Api-Sequence"] = "-1"
        }
        return headers
    }

    /// 初始化 JSON（full client request payload）。
    static func initializationJSON(profile: EndpointProfile, textMode: TextMode) throws -> Data {
        let audio: [String: Any] = [
            "format": "pcm",
            "codec": "raw",
            "rate": 16_000,
            "bits": 16,
            "channel": 1,
            "language": textMode.language.volcengineLanguage
        ]
        let request: [String: Any] = [
            "model_name": profile.volcengine.modelName,
            "result_type": profile.volcengine.resultType.requestValue,
            "enable_punc": textMode.addPunctuation,
            "enable_itn": true,
            "show_utterances": true
        ]
        let root: [String: Any] = [
            "user": ["uid": UUID().uuidString],
            "audio": audio,
            "request": request
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

@MainActor
final class VolcengineStreamingSession: TranscriptionSession {
    let updates: AsyncThrowingStream<TranscriptionUpdate, Error>

    private let profile: EndpointProfile
    private let options: TranscriptionOptions
    private let transport: VolcengineWebSocketTransport
    private let finalResultTimeout: TimeInterval
    private let requestID: String
    private let continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation

    private var accumulator: VolcengineTranscriptAccumulator
    private var receiveTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var finalContinuation: CheckedContinuation<TranscriptionResult, Error>?

    private var pendingChunk: Data?
    // 序号 1 已被 full client request 占用，音频从 2 开始。
    private var audioSequence: Int32 = 1
    private var finalResult: TranscriptionResult?
    private var failure: Error?
    private var isReady = false
    private var lastPreview = ""
    private var isCancelled = false
    private var isFinished = false

    private(set) var logID: String?

    init(
        profile: EndpointProfile,
        options: TranscriptionOptions,
        transport: VolcengineWebSocketTransport,
        accumulator: VolcengineTranscriptAccumulator,
        requestID: String,
        finalResultTimeout: TimeInterval
    ) {
        self.profile = profile
        self.options = options
        self.transport = transport
        self.accumulator = accumulator
        self.requestID = requestID
        self.finalResultTimeout = finalResultTimeout

        var streamContinuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation!
        self.updates = AsyncThrowingStream { streamContinuation = $0 }
        self.continuation = streamContinuation
    }

    // MARK: - 建连

    func start(url: URL, headers: [String: String], initializationJSON: Data, timeout: TimeInterval) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = max(15, timeout + 5)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // 某些网络/系统状态下 WebSocket 握手或首包发送可能长时间挂起。
        // 注意不能使用 task group：作用域退出时会等待未响应取消的子任务，
        // 导致超时永远不返回。这里用“先完成者生效”的竞速。
        do {
            let transport = self.transport
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = Self.OnceResume(continuation)
                Task.detached {
                    do {
                        try await transport.connect(request: request)
                        let frame = try VolcengineFrameEncoder.fullClientRequest(json: initializationJSON)
                        try await transport.send(frame)
                        once.resume(.success(()))
                    } catch {
                        once.resume(.failure(error))
                    }
                }
                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    once.resume(.failure(TranscriptionError.timeout))
                    // 超时后主动断开，帮助挂起的 send/receive 退出。
                    transport.close()
                }
            }
        } catch {
            transport.close()
            throw Self.mapTransportError(error)
        }

        startReceiving()
        try await waitUntilReady(timeout: timeout)
        if logID == nil {
            logID = transport.logID
        }
    }

    // MARK: - TranscriptionSession

    func appendAudio(_ pcm16Mono16k: Data) async throws {
        guard !isFinished, !isCancelled else { return }
        // 保留最后一包：finish 时用它作为“最后一包音频”，避免发送空结束包。
        if let pending = pendingChunk {
            try await sendAudio(pending, isLast: false)
        }
        pendingChunk = pcm16Mono16k
    }

    func finish(recordingURL: URL) async throws -> TranscriptionResult {
        guard !isFinished else { throw TranscriptionError.cancelled }
        isFinished = true

        if let failure { throw failure }

        let lastChunk = pendingChunk ?? Data()
        pendingChunk = nil
        do {
            try await sendAudio(lastChunk, isLast: true)
        } catch {
            let mapped = Self.mapTransportError(error)
            fail(mapped)
            // 如果接收循环已经拿到服务端错误，优先上报它。
            throw failure ?? mapped
        }

        return try await waitForFinalResult()
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        receiveTask?.cancel()
        receiveTask = nil
        pendingChunk = nil
        transport.close()
        resumePendingContinuations(with: TranscriptionError.cancelled)
        continuation.finish()
        Logger.websocket.info("火山连接已取消 requestID=\(self.requestID, privacy: .public)")
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
                    self.fail(Self.mapTransportError(error))
                    return
                }
            }
        }
    }

    private func handleFrame(_ data: Data) throws {
        let frame = try VolcengineFrameDecoder.decode(data)
        if logID == nil {
            logID = transport.logID
        }

        switch frame.messageType {
        case VolcengineMessageType.fullServerResponse.rawValue,
             VolcengineMessageType.serverAck.rawValue:
            markReady()
            guard !frame.payload.isEmpty else { return }

            let payload: VolcengineResponsePayload
            do {
                payload = try JSONDecoder().decode(VolcengineResponsePayload.self, from: frame.payload)
            } catch {
                throw TranscriptionError.invalidResponse("火山响应 JSON 解析失败")
            }

            accumulator.apply(payload)
            if frame.isFinal {
                complete(finalText: accumulator.resultText)
            } else {
                let preview = accumulator.previewText
                if !preview.isEmpty, preview != lastPreview {
                    lastPreview = preview
                    continuation.yield(.interim(preview))
                }
            }

        default:
            Logger.websocket.debug("忽略未知火山消息类型 \(frame.messageType, privacy: .public)")
        }
    }

    private func handleConnectionClosed() {
        guard !isCancelled else { return }
        if finalResult != nil { return }
        let text = accumulator.resultText
        if isFinished, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 服务端未显式发送 final 标记但已关闭连接：使用已确认文本。
            complete(finalText: text)
        } else {
            fail(TranscriptionError.invalidResponse("连接已关闭，未收到最终识别结果"))
        }
    }

    private func complete(finalText: String) {
        guard finalResult == nil, !isCancelled else { return }
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail(TranscriptionError.emptyTranscript)
            return
        }
        let result = TranscriptionResult(
            text: trimmed,
            providerKind: .volcengineStreaming,
            sessionID: options.sessionID,
            requestID: requestID,
            logID: logID,
            audioDuration: options.audioDuration
        )
        finalResult = result
        continuation.yield(.final(trimmed))
        continuation.finish()
        finalContinuation?.resume(returning: result)
        finalContinuation = nil
        transport.close()
    }

    // MARK: - 音频发送

    private func sendAudio(_ pcm: Data, isLast: Bool) async throws {
        let sequence: Int32?
        if isLast {
            sequence = nil
        } else {
            audioSequence += 1
            sequence = audioSequence
        }
        let frame = try VolcengineFrameEncoder.audioFrame(pcm: pcm, sequence: sequence, isLast: isLast)
        do {
            try await transport.send(frame)
        } catch {
            throw Self.mapTransportError(error)
        }
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
                    // 先唤醒等待者再抛错，否则 group 退出时会等待永不完成的 continuation。
                    await MainActor.run {
                        self?.resumeReady(with: TranscriptionError.timeout)
                    }
                    throw TranscriptionError.timeout
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            let mapped = Self.mapTransportError(error)
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
            let mapped = Self.mapTransportError(error)
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
        Logger.websocket.error("火山会话失败 requestID=\(self.requestID, privacy: .public) error=\(String(describing: error), privacy: .public)")
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

    /// 只允许第一个结果生效，避免竞速双方重复 resume。
    final class OnceResume: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private let continuation: CheckedContinuation<Void, Error>

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<Void, Error>) {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }
            didResume = true
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    static func mapTransportError(_ error: Error) -> Error {
        if let transcriptionError = error as? TranscriptionError {
            return transcriptionError
        }
        if let serverError = error as? VolcengineServerError {
            return serverError
        }
        if let codecError = error as? VolcengineCodecError {
            return TranscriptionError.invalidResponse(codecError.localizedDescription)
        }
        if let gzipError = error as? GzipError {
            return TranscriptionError.invalidResponse(gzipError.localizedDescription)
        }
        if error is CancellationError {
            return TranscriptionError.cancelled
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorBadServerResponse {
                return TranscriptionError.invalidResponse("WebSocket 握手被拒绝（请检查 API Key / Resource ID）")
            }
            return TranscriptionError.mapURLError(nsError)
        }
        return TranscriptionError.network(nsError.localizedDescription)
    }
}
