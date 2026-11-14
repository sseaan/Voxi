import XCTest
@testable import Voxi

final class MultipartFormDataTests: XCTestCase {
    func testFieldsAndFileEncoding() {
        var form = MultipartFormData(boundary: "BOUNDARY")
        form.addField(name: "model", value: "whisper-1")
        form.addField(name: "language", value: "zh")
        form.addFile(name: "file", filename: "audio.wav", mimeType: "audio/wav", data: Data("FAKEWAV".utf8))

        let body = form.finalized()
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=BOUNDARY")
        XCTAssertTrue(text.hasPrefix("--BOUNDARY\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"language\"\r\n\r\nzh\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"))
        XCTAssertTrue(text.contains("Content-Type: audio/wav\r\n\r\nFAKEWAV\r\n"))
        XCTAssertTrue(text.hasSuffix("--BOUNDARY--\r\n"))
    }

    func testBodyIsBinarySafe() {
        var form = MultipartFormData(boundary: "B")
        let binary = Data([0x00, 0x01, 0x0D, 0x0A, 0xFF, 0x7F])
        form.addFile(name: "file", filename: "a.bin", mimeType: "application/octet-stream", data: binary)
        let body = form.finalized()
        XCTAssertNotNil(body.range(of: binary), "二进制内容必须原样写入，不被转义")
    }

    func testQuotesAndNewlinesInNamesAreEscaped() {
        var form = MultipartFormData(boundary: "B")
        form.addField(name: "na\"me\r\nX: y", value: "v")
        let text = String(decoding: form.finalized(), as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"na%22meX: y\""))
    }

    func testEmptyFormStillTerminates() {
        let form = MultipartFormData(boundary: "B")
        let text = String(decoding: form.finalized(), as: UTF8.self)
        XCTAssertEqual(text, "--B--\r\n")
    }
}

/// URLProtocol stub：不访问网络，记录请求并返回预设响应。
final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private(set) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requests = []
        handler = nil
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension StubURLProtocol {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func httpResponse(
        url: URL,
        status: Int,
        contentType: String?,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        var allHeaders = headers
        if let contentType { allHeaders["Content-Type"] = contentType }
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: allHeaders)!
    }
}

@MainActor
final class OpenAICompatibleProviderTests: XCTestCase {
    private var tempFileURL: URL!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai-test-\(UUID().uuidString).wav")
        try? Data("FAKEWAVDATA".utf8).write(to: tempFileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFileURL)
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeProfile(authMode: EndpointProfile.OpenAIOptions.AuthMode = .bearer) -> EndpointProfile {
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.endpointURL = "https://asr.example.com/v1/audio/transcriptions"
        profile.openAI.model = "whisper-1"
        profile.openAI.authMode = authMode
        profile.openAI.customAuthHeaderName = "api-key"
        profile.apiKeyItemID = UUID()
        return profile
    }

    private func makeSession(
        profile: EndpointProfile,
        secrets: [UUID: String],
        textMode: TextMode = TextMode(prompt: "测试提示")
    ) async throws -> (OpenAICompatibleSession, InMemorySecretResolver) {
        let resolver = InMemorySecretResolver(secrets)
        let provider = OpenAICompatibleProvider(
            urlSession: StubURLProtocol.makeSession(),
            secretResolver: resolver
        )
        let session = try await provider.makeSession(
            profile: profile,
            options: TranscriptionOptions(sessionID: UUID(), textMode: textMode, audioDuration: 1.5)
        )
        return (session as! OpenAICompatibleSession, resolver)
    }

    func testRequestContainsMultipartFieldsAndBearerAuth() async throws {
        var profile = makeProfile()
        profile.openAI.customHeaders = [.init(name: "x-org", value: .literal("acme"))]
        profile.openAI.customFormFields = [.init(name: "custom_field", value: .literal("v1"))]
        let keyID = profile.apiKeyItemID!
        let (session, _) = try await makeSession(profile: profile, secrets: [keyID: "sk-test-key"])

        StubURLProtocol.handler = { request in
            (StubURLProtocol.httpResponse(
                url: request.url!,
                status: 200,
                contentType: "application/json"
            ), Data(#"{"text":"你好世界"}"#.utf8))
        }

        let result = try await session.finish(recordingURL: tempFileURL)

        XCTAssertEqual(result.text, "你好世界")
        XCTAssertEqual(result.providerKind, .openAICompatible)

        let request = try XCTUnwrap(StubURLProtocol.recordedRequests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, profile.endpointURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-org"), "acme")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data; boundary=") == true)

        let body = String(decoding: StubURLProtocol.body(of: request), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nzh"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\n测试提示"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(body.contains("name=\"custom_field\"\r\n\r\nv1"))
        XCTAssertTrue(body.contains("filename=\"openai-test-"))
        XCTAssertTrue(body.contains("FAKEWAVDATA"))
        XCTAssertTrue(body.contains("--\r\n"), "multipart 必须以结束 boundary 收尾")
    }

    func testCustomAuthHeaderModeAvoidsAuthorizationHeader() async throws {
        var profile = makeProfile(authMode: .customHeader)
        profile.openAI.customAuthHeaderName = "api-key"
        let keyID = profile.apiKeyItemID!
        let (session, _) = try await makeSession(profile: profile, secrets: [keyID: "secret-123"])

        StubURLProtocol.handler = { request in
            (StubURLProtocol.httpResponse(url: request.url!, status: 200, contentType: "application/json"),
             Data(#"{"text":"ok"}"#.utf8))
        }
        _ = try await session.finish(recordingURL: tempFileURL)

        let request = try XCTUnwrap(StubURLProtocol.recordedRequests().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "secret-123")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testPlainTextResponseParsing() async throws {
        let profile = makeProfile()
        let (session, _) = try await makeSession(
            profile: profile,
            secrets: [profile.apiKeyItemID!: "k"],
            textMode: TextMode()
        )
        StubURLProtocol.handler = { request in
            (StubURLProtocol.httpResponse(url: request.url!, status: 200, contentType: "text/plain; charset=utf-8"),
             Data("hello world".utf8))
        }
        let result = try await session.finish(recordingURL: tempFileURL)
        XCTAssertEqual(result.text, "hello world")
    }

    func testEmptyTranscriptThrows() async throws {
        let profile = makeProfile()
        let (session, _) = try await makeSession(profile: profile, secrets: [profile.apiKeyItemID!: "k"])
        StubURLProtocol.handler = { request in
            (StubURLProtocol.httpResponse(url: request.url!, status: 200, contentType: "application/json"),
             Data(#"{"text":"   "}"#.utf8))
        }
        do {
            _ = try await session.finish(recordingURL: tempFileURL)
            XCTFail("空文本应报错")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .emptyTranscript)
        }
    }

    func testUnauthorizedAndRateLimitMapping() async throws {
        let profile = makeProfile()
        let (session, _) = try await makeSession(profile: profile, secrets: [profile.apiKeyItemID!: "k"])

        StubURLProtocol.handler = { request in
            (StubURLProtocol.httpResponse(url: request.url!, status: 401, contentType: "application/json"),
             Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }
        do {
            _ = try await session.finish(recordingURL: tempFileURL)
            XCTFail("401 应报错")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .unauthorized(status: 401))
        }

        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            (StubURLProtocol.httpResponse(
                url: request.url!,
                status: 429,
                contentType: "application/json",
                headers: ["Retry-After": "7"]
            ), Data())
        }
        let (session2, _) = try await makeSession(profile: profile, secrets: [profile.apiKeyItemID!: "k"])
        do {
            _ = try await session2.finish(recordingURL: tempFileURL)
            XCTFail("429 应报错")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .rateLimited(retryAfter: "7"))
        }
    }

    func testServerErrorAndNotFoundMapping() async throws {
        let profile = makeProfile()
        let key = profile.apiKeyItemID!
        let (session, _) = try await makeSession(profile: profile, secrets: [key: "k"])
        StubURLProtocol.handler = { request in
            (StubURLProtocol.httpResponse(url: request.url!, status: 503, contentType: "text/plain"), Data("busy".utf8))
        }
        do {
            _ = try await session.finish(recordingURL: tempFileURL)
            XCTFail("503 应报错")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .serverError(status: 503, detail: "busy"))
        }

        StubURLProtocol.reset()
        let (session2, _) = try await makeSession(profile: profile, secrets: [key: "k"])
        StubURLProtocol.handler = { request in
            (StubURLProtocol.httpResponse(url: request.url!, status: 404, contentType: "application/json"), Data())
        }
        do {
            _ = try await session2.finish(recordingURL: tempFileURL)
            XCTFail("404 应报错")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .httpStatus(404, detail: nil))
        }
    }

    func testTimeoutAndNetworkErrorMapping() async throws {
        let profile = makeProfile()
        let key = profile.apiKeyItemID!
        let (session, _) = try await makeSession(profile: profile, secrets: [key: "k"])
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await session.finish(recordingURL: tempFileURL)
            XCTFail("超时应报错")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .timeout)
        }

        StubURLProtocol.reset()
        let (session2, _) = try await makeSession(profile: profile, secrets: [key: "k"])
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await session2.finish(recordingURL: tempFileURL)
            XCTFail("网络错误应报错")
        } catch let error as TranscriptionError {
            guard case .network = error else {
                return XCTFail("应映射为 network，实际 \(error)")
            }
        }
    }

    func testInvalidJSONResponseThrows() async throws {
        let profile = makeProfile()
        let (session, _) = try await makeSession(profile: profile, secrets: [profile.apiKeyItemID!: "k"])
        StubURLProtocol.handler = { request in
            (StubURLProtocol.httpResponse(url: request.url!, status: 200, contentType: "application/json"),
             Data("not json".utf8))
        }
        do {
            _ = try await session.finish(recordingURL: tempFileURL)
            XCTFail("非法 JSON 应报错")
        } catch let error as TranscriptionError {
            guard case .invalidResponse = error else {
                return XCTFail("应映射为 invalidResponse，实际 \(error)")
            }
        }
    }

    func testAppendAudioNeverSendsRequest() async throws {
        let profile = makeProfile()
        let (session, _) = try await makeSession(profile: profile, secrets: [profile.apiKeyItemID!: "k"])

        try await session.appendAudio(Data(repeating: 0, count: 6_400))
        try await session.appendAudio(Data(repeating: 0, count: 6_400))

        XCTAssertTrue(StubURLProtocol.recordedRequests().isEmpty, "OpenAI-compatible 在录音期间不得发请求")
    }

    func testMissingCredentialFailsBeforeRequest() async throws {
        let profile = makeProfile()
        let (session, _) = try await makeSession(profile: profile, secrets: [:])
        do {
            _ = try await session.finish(recordingURL: tempFileURL)
            XCTFail("缺少 key 应报错")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .missingCredential)
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests().isEmpty)
    }

    func testCancellationDuringUpload() async throws {
        let profile = makeProfile()
        let (session, _) = try await makeSession(profile: profile, secrets: [profile.apiKeyItemID!: "k"])

        StubURLProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 0.5)
            throw URLError(.cancelled)
        }

        let task = Task { try await session.finish(recordingURL: self.tempFileURL) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await session.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后不得返回结果")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testRequestBuilderRejectsReservedCustomFields() throws {
        var profile = makeProfile()
        profile.openAI.customFormFields = [.init(name: "model", value: .literal("evil"))]
        XCTAssertThrowsError(try OpenAICompatibleRequestBuilder.makeRequest(
            profile: profile,
            secret: "k",
            textMode: TextMode(),
            fileURL: tempFileURL,
            fileData: Data("x".utf8),
            secretResolver: InMemorySecretResolver()
        )) { error in
            guard case .invalidConfiguration(let message)? = error as? TranscriptionError else {
                return XCTFail("应拒绝保留字段名，实际 \(error)")
            }
            XCTAssertTrue(message.contains("model"))
        }
    }

    func testLogRedactionHidesSecrets() {
        let redacted = Logger.redactedURL("https://user:pass@example.com/v1/audio/transcriptions?token=secret")
        XCTAssertFalse(redacted.contains("pass"))
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertTrue(redacted.contains("example.com"))
        XCTAssertEqual(Logger.redactedValue("sk-123456"), "<9 chars>")
    }

    func testLexiconTermsAreAppendedToPrompt() throws {
        let lexicon = PersonalLexicon(entries: [
            LexiconEntry(term: "Voxi"),
            LexiconEntry(term: "Sean")
        ])
        let request = try OpenAICompatibleRequestBuilder.makeRequest(
            profile: makeProfile(),
            secret: "sk-test",
            textMode: TextMode(prompt: "测试提示"),
            fileURL: tempFileURL,
            fileData: Data("FAKEWAVDATA".utf8),
            secretResolver: InMemorySecretResolver([:]),
            lexicon: lexicon
        )
        let body = String(decoding: StubURLProtocol.body(of: request), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\n测试提示，Voxi、Sean"))
    }
}
