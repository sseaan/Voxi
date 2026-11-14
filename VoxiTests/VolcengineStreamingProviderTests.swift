import Foundation
import XCTest
@testable import Voxi

/// 可控的 WebSocket fake transport：记录发送帧，按需返回服务端帧。
final class FakeVolcengineTransport: VolcengineWebSocketTransport {
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data?, Error>?

    private(set) var connectedRequest: URLRequest?
    private(set) var sentFrames: [Data] = []
    private(set) var connectCount = 0
    private(set) var isClosed = false

    var connectError: Error?
    var sendError: Error?
    var connectDelayNanoseconds: UInt64 = 0
    var sendDelayNanoseconds: UInt64 = 0
    var logID: String? = "test-logid-1"
    var onSend: ((Data) -> Void)?

    func connect(request: URLRequest) async throws {
        connectCount += 1
        if connectDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: connectDelayNanoseconds)
        }
        if let connectError { throw connectError }
        connectedRequest = request
    }

    func send(_ data: Data) async throws {
        if sendDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        if let sendError { throw sendError }
        sentFrames.append(data)
        onSend?(data)
    }

    func receive() async throws -> Data? {
        if !queue.isEmpty {
            return queue.removeFirst()
        }
        if isClosed {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func close() {
        isClosed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func enqueue(_ frame: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: frame)
        } else {
            queue.append(frame)
        }
    }
}

@MainActor
final class VolcengineStreamingProviderTests: XCTestCase {
    private let keyID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let appKeyID = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!
    private let accessKeyID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func makeProfile(
        authMode: EndpointProfile.VolcengineOptions.AuthMode = .apiKey,
        sendsSequenceHeader: Bool = false
    ) -> EndpointProfile {
        var profile = EndpointProfile.defaultVolcengineProfile()
        profile.volcengine.authMode = authMode
        profile.volcengine.sendsApiSequenceHeader = sendsSequenceHeader
        switch authMode {
        case .apiKey:
            profile.apiKeyItemID = keyID
        case .legacy:
            profile.appKeyItemID = appKeyID
            profile.accessKeyItemID = accessKeyID
        }
        return profile
    }

    private func makeProvider(
        transport: FakeVolcengineTransport,
        secrets: [UUID: String],
        initTimeout: TimeInterval = 1,
        finalTimeout: TimeInterval = 1
    ) -> VolcengineStreamingProvider {
        VolcengineStreamingProvider(
            transportFactory: { transport },
            secretResolver: InMemorySecretResolver(secrets),
            initializationTimeout: initTimeout,
            finalResultTimeout: finalTimeout
        )
    }

    private func ackFrame() -> Data {
        VolcFixture.serverFrame(
            messageType: 0xB,
            flags: 0x0,
            compression: 0x0,
            payload: Data()
        )
    }

    private func makeSession(
        _ provider: VolcengineStreamingProvider,
        profile: EndpointProfile,
        textMode: TextMode = TextMode()
    ) async throws -> any TranscriptionSession {
        try await provider.makeSession(
            profile: profile,
            options: TranscriptionOptions(sessionID: UUID(), textMode: textMode, audioDuration: 1.0)
        )
    }

    // MARK: - 鉴权 headers

    func testReadySessionIsNotClosedByInitializationTimeout() async throws {
        let transport = FakeVolcengineTransport()
        transport.enqueue(ackFrame())
        let provider = makeProvider(transport: transport, secrets: [keyID: "api-key-value"], initTimeout: 0.2)
        _ = try await makeSession(provider, profile: makeProfile())
        XCTAssertFalse(transport.isClosed)

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(transport.isClosed, "初始化超时不应关闭已经就绪的长连接")
        XCTAssertTrue(transport.isClosed == false)
    }

    func testApiKeyHeaders() async throws {
        let transport = FakeVolcengineTransport()
        transport.enqueue(ackFrame())
        let provider = makeProvider(transport: transport, secrets: [keyID: "api-key-value"])
        _ = try await makeSession(provider, profile: makeProfile())

        let request = try XCTUnwrap(transport.connectedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "api-key-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.seedasr.sauc.duration")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Api-Connect-Id"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Api-Request-Id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-App-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Access-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Sequence"))
        XCTAssertEqual(request.url?.absoluteString, "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")
    }

    func testApiKeySendsSequenceHeaderOnlyWhenConfigured() async throws {
        let transport = FakeVolcengineTransport()
        transport.enqueue(ackFrame())
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"])
        _ = try await makeSession(provider, profile: makeProfile(sendsSequenceHeader: true))
        XCTAssertEqual(transport.connectedRequest?.value(forHTTPHeaderField: "X-Api-Sequence"), "-1")
    }

    func testLegacyHeadersDoNotMixWithApiKey() async throws {
        let transport = FakeVolcengineTransport()
        transport.enqueue(ackFrame())
        let provider = makeProvider(
            transport: transport,
            secrets: [appKeyID: "app-123", accessKeyID: "access-456"]
        )
        _ = try await makeSession(provider, profile: makeProfile(authMode: .legacy))

        let request = try XCTUnwrap(transport.connectedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-App-Key"), "app-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Access-Key"), "access-456")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Sequence"), "-1")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
    }

    func testMissingCredentialFailsBeforeConnect() async {
        let transport = FakeVolcengineTransport()
        let provider = makeProvider(transport: transport, secrets: [:])
        do {
            _ = try await makeSession(provider, profile: makeProfile())
            XCTFail("缺少 API Key 应报错")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .missingCredential)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
        XCTAssertEqual(transport.connectCount, 0)
    }

    // MARK: - 初始化 JSON

    func testInitializationJSONFields() async throws {
        let transport = FakeVolcengineTransport()
        transport.enqueue(ackFrame())
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"])
        _ = try await makeSession(
            provider,
            profile: makeProfile(),
            textMode: TextMode(language: .english, prompt: "ignored", addPunctuation: false)
        )

        let frame = try XCTUnwrap(transport.sentFrames.first)
        let bytes = [UInt8](frame)
        XCTAssertEqual(bytes[1], 0x11, "full client request + positive sequence")
        XCTAssertEqual(bytes[2], 0x11, "JSON + gzip")
        let decoded = try VolcengineFrameDecoder.decode(frame)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: decoded.payload) as? [String: Any]
        )

        let audio = try XCTUnwrap(json["audio"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "pcm")
        XCTAssertEqual(audio["codec"] as? String, "raw")
        XCTAssertEqual(audio["rate"] as? Int, 16_000)
        XCTAssertEqual(audio["bits"] as? Int, 16)
        XCTAssertEqual(audio["channel"] as? Int, 1)
        XCTAssertEqual(audio["language"] as? String, "en-US")

        let request = try XCTUnwrap(json["request"] as? [String: Any])
        XCTAssertEqual(request["model_name"] as? String, "bigmodel")
        XCTAssertEqual(request["result_type"] as? String, "full")
        XCTAssertEqual(request["show_utterances"] as? Bool, true)
        XCTAssertEqual(request["enable_punc"] as? Bool, false)

        let user = try XCTUnwrap(json["user"] as? [String: Any])
        XCTAssertNotNil(user["uid"] as? String)
    }

    // MARK: - 流式流程

    func testStreamingFlowSendsBufferedAudioAndReturnsFinalText() async throws {
        let transport = FakeVolcengineTransport()
        transport.enqueue(ackFrame())
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"])
        let session = try await makeSession(provider, profile: makeProfile())

        transport.onSend = { [weak transport] frame in
            guard let transport else { return }
            let bytes = [UInt8](frame)
            if bytes.count > 1, bytes[1] & 0x0F == 0x2 {
                // 收到最后一包后返回最终结果
                let final = try! VolcFixture.gzipServerFrame(
                    flags: 0x3,
                    sequence: -1,
                    json: #"{"result":{"text":"最终文本"}}"#
                )
                transport.enqueue(final)
            }
        }

        try await session.appendAudio(Data(repeating: 0x01, count: 6_400))
        try await session.appendAudio(Data(repeating: 0x02, count: 6_400))
        // 第一包已发送，第二包保留到 finish
        let audioFrames = transport.sentFrames.filter { [UInt8]($0)[1] >> 4 == 0x2 }
        XCTAssertEqual(audioFrames.count, 1)

        let result = try await session.finish(recordingURL: URL(fileURLWithPath: "/tmp/empty.wav"))
        XCTAssertEqual(result.text, "最终文本")
        XCTAssertEqual(result.providerKind, .volcengineStreaming)
        XCTAssertEqual(result.logID, "test-logid-1")

        let allAudio = transport.sentFrames.filter { [UInt8]($0)[1] >> 4 == 0x2 }
        XCTAssertEqual(allAudio.count, 2)
        let lastBytes = [UInt8](allAudio[1])
        XCTAssertEqual(lastBytes[1] & 0x0F, 0x2, "最后一包必须带结束 flag")
    }

    func testInterimUpdatesReplaceTextAndFinalYieldsOnce() async throws {
        let transport = FakeVolcengineTransport()
        transport.enqueue(ackFrame())
        transport.enqueue(try VolcFixture.gzipServerFrame(flags: 0x1, sequence: 1, json: #"{"result":{"text":"你好"}}"#))
        transport.enqueue(try VolcFixture.gzipServerFrame(flags: 0x1, sequence: 2, json: #"{"result":{"text":"你好世界"}}"#))
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"])
        let session = try await makeSession(provider, profile: makeProfile())

        var updates: [TranscriptionUpdate] = []
        let collectTask = Task {
            for try await update in session.updates {
                updates.append(update)
            }
        }

        transport.onSend = { [weak transport] frame in
            guard let transport else { return }
            let bytes = [UInt8](frame)
            if bytes[1] & 0x0F == 0x2 {
                transport.enqueue(try! VolcFixture.gzipServerFrame(
                    flags: 0x3,
                    sequence: -1,
                    json: #"{"result":{"text":"你好世界"}}"#
                ))
            }
        }

        try await session.appendAudio(Data(repeating: 0, count: 6_400))
        let result = try await session.finish(recordingURL: URL(fileURLWithPath: "/tmp/x.wav"))
        _ = try? await collectTask.value

        XCTAssertEqual(result.text, "你好世界")
        let interim = updates.compactMap { update -> String? in
            if case .interim(let text) = update { return text }
            return nil
        }
        XCTAssertEqual(interim, ["你好", "你好世界"], "中间结果应替换而不是拼接")
        let finals = updates.filter { update in
            if case .final = update { return true }
            return false
        }
        XCTAssertEqual(finals.count, 1, "最终结果只允许出现一次")
    }

    func testServerErrorFrameFailsSession() async {
        let transport = FakeVolcengineTransport()
        transport.enqueue(VolcFixture.errorFrame(code: 45000002, message: ""))
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"])
        do {
            _ = try await makeSession(provider, profile: makeProfile())
            XCTFail("错误帧应导致会话失败")
        } catch let error as VolcengineServerError {
            XCTAssertEqual(error.code, 45000002)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    func testInitializationTimeout() async {
        let transport = FakeVolcengineTransport()
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"], initTimeout: 0.2)
        do {
            _ = try await makeSession(provider, profile: makeProfile())
            XCTFail("初始化超时应报错")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
        XCTAssertTrue(transport.isClosed)
    }

    func testFinalResultTimeout() async throws {
        let transport = FakeVolcengineTransport()
        transport.enqueue(ackFrame())
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"], finalTimeout: 0.2)
        let session = try await makeSession(provider, profile: makeProfile())

        try await session.appendAudio(Data(repeating: 0, count: 6_400))
        do {
            _ = try await session.finish(recordingURL: URL(fileURLWithPath: "/tmp/x.wav"))
            XCTFail("等待最终包超时应报错")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    func testSlowHandshakeTimesOutInsteadOfHanging() async {
        let transport = FakeVolcengineTransport()
        transport.connectDelayNanoseconds = 3_000_000_000
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"], initTimeout: 0.2)
        let started = Date()
        do {
            _ = try await makeSession(provider, profile: makeProfile())
            XCTFail("握手超时应报错")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "必须在超时后尽快返回")
        XCTAssertTrue(transport.isClosed)
    }

    func testConnectFailureIsMapped() async {
        let transport = FakeVolcengineTransport()
        transport.connectError = URLError(.badServerResponse)
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"])
        do {
            _ = try await makeSession(provider, profile: makeProfile())
            XCTFail("握手失败应报错")
        } catch let error as TranscriptionError {
            guard case .invalidResponse = error else {
                return XCTFail("应映射为 invalidResponse，实际 \(error)")
            }
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    func testCancelStopsSessionAndRejectsFinish() async throws {
        let transport = FakeVolcengineTransport()
        transport.enqueue(ackFrame())
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"])
        let session = try await makeSession(provider, profile: makeProfile())

        await session.cancel()
        XCTAssertTrue(transport.isClosed)
        do {
            _ = try await session.finish(recordingURL: URL(fileURLWithPath: "/tmp/x.wav"))
            XCTFail("取消后 finish 不得返回结果")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
    }

    func testSingleResultTypeUsesAccumulator() async throws {
        var profile = makeProfile()
        profile.volcengine.resultType = .single
        let transport = FakeVolcengineTransport()
        transport.enqueue(ackFrame())
        transport.enqueue(try VolcFixture.gzipServerFrame(flags: 0x1, sequence: 1, json: """
        {"result":{"text":"第一句","utterances":[{"text":"第一句","start_time":0,"end_time":500,"definite":true}]}}
        """))
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"])
        let session = try await makeSession(provider, profile: profile)

        transport.onSend = { [weak transport] frame in
            guard let transport else { return }
            let bytes = [UInt8](frame)
            if bytes[1] & 0x0F == 0x2 {
                transport.enqueue(try! VolcFixture.gzipServerFrame(flags: 0x3, sequence: -1, json: """
                {"result":{"text":"第二句","utterances":[
                  {"text":"第一句","start_time":0,"end_time":500,"definite":true},
                  {"text":"第二句","start_time":500,"end_time":900,"definite":true}
                ]}}
                """))
            }
        }

        try await session.appendAudio(Data(repeating: 0, count: 6_400))
        let result = try await session.finish(recordingURL: URL(fileURLWithPath: "/tmp/x.wav"))
        XCTAssertEqual(result.text, "第一句第二句")
    }

    func testInvalidProfileFailsBeforeConnecting() async {
        var profile = makeProfile()
        profile.endpointURL = "https://example.com/asr"
        let transport = FakeVolcengineTransport()
        let provider = makeProvider(transport: transport, secrets: [keyID: "k"])
        do {
            _ = try await makeSession(provider, profile: profile)
            XCTFail("https endpoint 应报配置错误")
        } catch let error as TranscriptionError {
            guard case .invalidConfiguration = error else {
                return XCTFail("应映射为 invalidConfiguration，实际 \(error)")
            }
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
        XCTAssertEqual(transport.connectCount, 0)
    }

    func testInitializationIncludesLexiconHotwords() throws {
        let lexicon = PersonalLexicon(entries: [LexiconEntry(term: "Voxi")])
        let data = try VolcengineRequestBuilder.initializationJSON(
            profile: makeProfile(),
            textMode: TextMode(),
            lexicon: lexicon
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try XCTUnwrap(root["request"] as? [String: Any])
        let corpus = try XCTUnwrap(request["corpus"] as? [String: Any])
        XCTAssertEqual(corpus["context"] as? String, lexicon.hotwordsJSON)
    }
}
