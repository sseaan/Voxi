import XCTest
@testable import Voxi

final class ModelsStubURLProtocol: URLProtocol {
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
        configuration.protocolClasses = [ModelsStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class ProviderModelsServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ModelsStubURLProtocol.handler = nil
        ModelsStubURLProtocol.requests = []
    }

    func testModelsURLDerivation() {
        func url(_ string: String) -> String {
            ProviderModelsService.modelsURL(from: URL(string: string)!)!.absoluteString
        }
        XCTAssertEqual(url("https://api.openai.com/v1/audio/transcriptions"), "https://api.openai.com/v1/models")
        XCTAssertEqual(url("https://api.openai.com/v1/chat/completions"), "https://api.openai.com/v1/models")
        XCTAssertEqual(url("https://api.openai.com/v1"), "https://api.openai.com/v1/models")
        XCTAssertEqual(url("https://api.openai.com"), "https://api.openai.com/v1/models")
        XCTAssertEqual(url("https://example.com/custom/asr"), "https://example.com/custom/models")
    }

    func testParseModelsSupportsDataAndModelsArrays() throws {
        let dataJSON = Data(#"{"data":[{"id":"b"},{"id":"a"},{"id":"a"}]}"#.utf8)
        XCTAssertEqual(try ProviderModelsService.parseModels(dataJSON), ["a", "b"])

        let modelsJSON = Data(#"{"models":[{"name":"x"},{"id":"y"}]}"#.utf8)
        XCTAssertEqual(try ProviderModelsService.parseModels(modelsJSON), ["x", "y"])

        let arrayJSON = Data(#"["one","two"]"#.utf8)
        XCTAssertEqual(try ProviderModelsService.parseModels(arrayJSON), ["one", "two"])
    }

    func testFetchASRUsesModelsPathAndBearerAuth() async throws {
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.endpointURL = "https://example.com/v1/audio/transcriptions"
        profile.apiKeyItemID = UUID()
        let keyID = profile.apiKeyItemID!
        ModelsStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":[{"id":"m1"}]}"#.utf8))
        }
        let service = ProviderModelsService(
            urlSession: ModelsStubURLProtocol.makeSession(),
            secretResolver: InMemorySecretResolver([keyID: "sk-test"])
        )
        let models = try await service.fetchASRModels(profile: profile, apiKeyInput: nil)
        XCTAssertEqual(models, ["m1"])
        let request = try XCTUnwrap(ModelsStubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testFetchLanguageModelsUsesChatPath() async throws {
        var profile = LanguageModelProfile()
        profile.endpointURL = "https://example.com/v1/chat/completions"
        profile.authMode = .none
        ModelsStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":[{"id":"gpt-a"}]}"#.utf8))
        }
        let service = ProviderModelsService(
            urlSession: ModelsStubURLProtocol.makeSession(),
            secretResolver: InMemorySecretResolver()
        )
        let models = try await service.fetchLanguageModels(profile: profile, apiKeyInput: nil)
        XCTAssertEqual(models, ["gpt-a"])
        XCTAssertNil(ModelsStubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }
}

final class ModelSelectionTests: XCTestCase {
    func testProfileEffectiveModelsAndResolution() {
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.openAI.model = "manual"
        XCTAssertEqual(profile.effectiveModels, ["manual"])

        profile.openAI.enabledModels = [" m1 ", "m2", "m1"]
        XCTAssertEqual(profile.effectiveModels, ["m1", "m2"])
        XCTAssertEqual(profile.resolved(for: "m2").openAI.model, "m2")
    }

    func testCandidatesExpandProfilesInOrder() {
        var first = EndpointProfile.defaultOpenAIProfile()
        first.openAI.enabledModels = ["a", "b"]
        var second = EndpointProfile.defaultVolcengineProfile()
        second.volcengine.modelName = "bigmodel"
        var settings = VoxiSettings()
        settings.profiles = [first, second]
        let candidates = settings.asrCandidates
        XCTAssertEqual(candidates.map(\.model), ["a", "b", "bigmodel"])
        XCTAssertEqual(candidates.first?.sourceName, first.name)
        XCTAssertEqual(candidates.last?.resolvedProfile.volcengine.modelName, "bigmodel")
    }

    func testExplicitASROrderOverridesProfileOrder() {
        var first = EndpointProfile.defaultOpenAIProfile()
        first.openAI.enabledModels = ["a", "b"]
        var second = EndpointProfile.defaultVolcengineProfile()
        second.volcengine.modelName = "bigmodel"
        var settings = VoxiSettings()
        settings.profiles = [first, second]

        // 跨来源显式排序：火山排到最前，剩余模型保持原顺序。
        settings.asrOrder = [
            ASRModelCandidate(profile: second, model: "bigmodel").id,
            ASRModelCandidate(profile: first, model: "b").id
        ]
        XCTAssertEqual(settings.asrCandidates.map(\.model), ["bigmodel", "b", "a"])

        // 失效 id 被忽略；未记录的新模型追加到末尾。
        settings.asrOrder = ["missing#id"]
        XCTAssertEqual(settings.asrCandidates.map(\.model), ["a", "b", "bigmodel"])
    }

    func testASROrderRoundTripAndLegacyDefault() throws {
        var settings = VoxiSettings()
        settings.asrOrder = ["p#m1", "p#m2"]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(VoxiSettings.self, from: data)
        XCTAssertEqual(decoded.asrOrder, ["p#m1", "p#m2"])

        let legacy = #"{"schemaVersion":1,"profiles":[],"recordingMode":"holdToTalk"}"#.data(using: .utf8)!
        let old = try JSONDecoder().decode(VoxiSettings.self, from: legacy)
        XCTAssertNil(old.asrOrder)
    }

    func testLanguageModelEffectiveModels() {
        var profile = LanguageModelProfile()
        profile.model = "manual"
        XCTAssertEqual(profile.effectiveModels, ["manual"])
        profile.enabledModels = ["m1", "m2"]
        XCTAssertEqual(profile.effectiveModels, ["m1", "m2"])
    }
}
