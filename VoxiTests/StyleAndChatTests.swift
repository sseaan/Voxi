import XCTest
@testable import Voxi

final class ChatStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class ChatCompletionServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ChatStubURLProtocol.handler = nil
        ChatStubURLProtocol.requests = []
    }

    private func makeProfile(endpoint: String = "https://example.com/v1") -> (LanguageModelProfile, UUID) {
        let keyID = UUID()
        var profile = LanguageModelProfile()
        profile.endpointURL = endpoint
        profile.model = "gpt-4o-mini"
        profile.apiKeyItemID = keyID
        return (profile, keyID)
    }

    func testAppendsChatCompletionsAndParsesContent() async throws {
        let (profile, keyID) = makeProfile()
        ChatStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"choices":[{"message":{"content":"整理后的文本"}}]}"#.utf8))
        }
        let service = ChatCompletionService(
            urlSession: ChatStubURLProtocol.makeSession(),
            secretResolver: InMemorySecretResolver([keyID: "sk-test"])
        )
        let result = try await service.complete(
            profile: profile,
            systemPrompt: "系统提示",
            userText: "原始文本"
        )
        XCTAssertEqual(result, "整理后的文本")

        let request = try XCTUnwrap(ChatStubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = String(decoding: ChatStubURLProtocol.body(of: request), as: UTF8.self)
        XCTAssertTrue(body.contains("\"model\":\"gpt-4o-mini\""))
        XCTAssertTrue(body.contains("\"role\":\"system\""))
        XCTAssertTrue(body.contains("系统提示"))
        XCTAssertTrue(body.contains("原始文本"))
        XCTAssertTrue(body.contains("\"stream\":false"))
    }

    func testOpenCodeGoUsesDedicatedEndpointAndHeaders() async throws {
        let keyID = UUID()
        var profile = LanguageModelProfile(kind: .openCodeGo)
        profile.model = "deepseek-v4.1-flash"
        profile.apiKeyItemID = keyID
        ChatStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"choices":[{"message":{"content":"go 结果"}}]}"#.utf8))
        }
        let service = ChatCompletionService(
            urlSession: ChatStubURLProtocol.makeSession(),
            secretResolver: InMemorySecretResolver([keyID: "go-key"])
        )
        let result = try await service.complete(profile: profile, systemPrompt: "s", userText: "u")
        XCTAssertEqual(result, "go 结果")

        let request = try XCTUnwrap(ChatStubURLProtocol.requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://opencode.ai/inference/go/openai/v1/chat/completions"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer go-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-session"), profile.id.uuidString)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "x-opencode-request"))
        let body = String(decoding: ChatStubURLProtocol.body(of: request), as: UTF8.self)
        XCTAssertTrue(body.contains("max_tokens"))
        XCTAssertFalse(body.contains("temperature"))
        XCTAssertTrue(body.contains("deepseek-v4.1-flash"))
    }

    func testNoneAuthOmitsAuthorization() async throws {
        var (profile, _) = makeProfile()
        profile.authMode = .none
        ChatStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        }
        let service = ChatCompletionService(
            urlSession: ChatStubURLProtocol.makeSession(),
            secretResolver: InMemorySecretResolver()
        )
        let result = try await service.complete(profile: profile, systemPrompt: "s", userText: "u")
        XCTAssertEqual(result, "ok")
        XCTAssertNil(ChatStubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testHTTPErrorSurfacesMessage() async {
        let (profile, keyID) = makeProfile()
        ChatStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":{"message":"invalid key"}}"#.utf8))
        }
        let service = ChatCompletionService(
            urlSession: ChatStubURLProtocol.makeSession(),
            secretResolver: InMemorySecretResolver([keyID: "bad"])
        )
        do {
            _ = try await service.complete(profile: profile, systemPrompt: "s", userText: "u")
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid key"))
        }
    }

    func testCleaningStripsCodeFence() {
        XCTAssertEqual(
            ChatCompletionService.cleaning("```text\n你好\n```"),
            "你好"
        )
    }
}

final class TranscriptionStyleTests: XCTestCase {
    func testDefaultsToRaw() {
        let settings = VoxiSettings()
        XCTAssertEqual(settings.activeStyle.kind, .raw)
        XCTAssertFalse(settings.activeStyle.requiresLLM)
    }

    func testBuiltInSelectionResolves() {
        var settings = VoxiSettings()
        settings.selectedStyleID = TranscriptionStyle.structured.id
        XCTAssertEqual(settings.activeStyle.kind, .structured)
        XCTAssertTrue(settings.activeStyle.requiresLLM)
    }

    func testCustomStyleResolvesAndFallsBackWhenDeleted() {
        var settings = VoxiSettings()
        let custom = TranscriptionStyle.custom(name: "会议纪要", prompt: "整理成要点")
        settings.customStyles = [custom]
        settings.selectedStyleID = custom.id
        XCTAssertEqual(settings.activeStyle.name, "会议纪要")
        settings.customStyles = []
        XCTAssertEqual(settings.activeStyle.kind, .raw)
    }

    func testStyleProcessorReturnsRawWithoutStyle() async throws {
        let settings = VoxiSettings()
        let output = try await StyleProcessor.process(text: "原文", settings: settings)
        XCTAssertEqual(output, "原文")
    }

    func testStyleProcessorSendsStylePromptToChat() async throws {
        var settings = VoxiSettings()
        settings.selectedStyleID = TranscriptionStyle.simple.id
        settings.languageModel = LanguageModelProfile(
            endpointURL: "https://example.com/v1",
            model: "m",
            authMode: .none
        )
        ChatStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"choices":[{"message":{"content":"整理结果"}}]}"#.utf8))
        }
        let service = ChatCompletionService(
            urlSession: ChatStubURLProtocol.makeSession(),
            secretResolver: InMemorySecretResolver()
        )
        let output = try await StyleProcessor.process(
            text: "原文",
            settings: settings,
            chatService: service
        )
        XCTAssertEqual(output, "整理结果")
    }

    func testStyleProcessorRequiresLanguageModel() async {
        var settings = VoxiSettings()
        settings.selectedStyleID = TranscriptionStyle.simple.id
        do {
            _ = try await StyleProcessor.process(text: "原文", settings: settings)
            XCTFail("应当提示缺少语言模型")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("语言模型"))
        }
    }

    func testSettingsRoundTripKeepsStylesAndLanguageModel() throws {
        var settings = VoxiSettings()
        let custom = TranscriptionStyle.custom(name: "字幕", prompt: "每句一行")
        settings.customStyles = [custom]
        settings.selectedStyleID = custom.id
        var model = LanguageModelProfile(name: "本地", endpointURL: "http://localhost:11434/v1")
        model.authMode = .none
        settings.languageModel = model

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(VoxiSettings.self, from: data)
        XCTAssertEqual(decoded.customStyles, settings.customStyles)
        XCTAssertEqual(decoded.selectedStyleID, custom.id)
        XCTAssertEqual(decoded.languageModel, settings.languageModel)
    }
}
