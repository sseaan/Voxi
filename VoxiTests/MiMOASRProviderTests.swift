import Foundation
import XCTest
@testable import Voxi

@MainActor
final class MiMOASRProviderTests: XCTestCase {
    private let keyID = UUID()

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func writeTempWAV(_ data: Data = Data(repeating: 0x11, count: 1_024)) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxi-mimo-\(UUID().uuidString).wav")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRequestUsesChatCompletionsAndAPIKeyHeader() throws {
        var profile = EndpointProfile.defaultMiMOProfile()
        let audio = Data(repeating: 0x01, count: 64)
        let request = try MiMORequestBuilder.makeRequest(
            profile: profile,
            apiKey: "sk-test",
            audioData: audio,
            timeout: 30
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.xiaomimimo.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "mimo-v2.5-asr")
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let inputAudio = try XCTUnwrap(content.first?["input_audio"] as? [String: Any])
        XCTAssertEqual(content.first?["type"] as? String, "input_audio")
        XCTAssertEqual(inputAudio["format"] as? String, "wav")
        let dataURL = try XCTUnwrap(inputAudio["data"] as? String)
        XCTAssertTrue(dataURL.hasPrefix("data:audio/wav;base64,"))

        profile.mimo.maxAudioBytes = 10
        XCTAssertThrowsError(
            try MiMORequestBuilder.makeRequest(profile: profile, apiKey: "k", audioData: audio, timeout: 30)
        )
    }

    func testParseTranscript() throws {
        let data = Data("""
        {"choices":[{"message":{"role":"assistant","content":"  你好，世界  "}}]}
        """.utf8)
        XCTAssertEqual(try MiMORequestBuilder.parseTranscript(data), "  你好，世界  ")

        let parts = Data("""
        {"choices":[{"message":{"content":[{"type":"text","text":"片段一"},{"type":"text","text":"片段二"}]}}]}
        """.utf8)
        XCTAssertEqual(try MiMORequestBuilder.parseTranscript(parts), "片段一片段二")

        let error = Data(#"{"error":{"message":"invalid api key"}}"#.utf8)
        XCTAssertThrowsError(try MiMORequestBuilder.parseTranscript(error))
    }

    func testProviderUploadsWavAndReturnsText() async throws {
        let url = try writeTempWAV()
        var profile = EndpointProfile.defaultMiMOProfile()
        profile.apiKeyItemID = keyID

        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "sk-test")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"choices":[{"message":{"role":"assistant","content":"识别结果"}}]}"#
            return (response, Data(json.utf8))
        }

        let provider = MiMOASRProvider(
            urlSession: makeSession(),
            secretResolver: InMemorySecretResolver([keyID: "sk-test"])
        )
        let session = try await provider.makeSession(
            profile: profile,
            options: TranscriptionOptions(sessionID: UUID(), textMode: TextMode())
        )
        let result = try await session.finish(recordingURL: url)
        XCTAssertEqual(result.text, "识别结果")
        XCTAssertEqual(result.providerKind, .mimoASR)
    }

    func testUnauthorizedIsMapped() async throws {
        let url = try writeTempWAV()
        var profile = EndpointProfile.defaultMiMOProfile()
        profile.apiKeyItemID = keyID

        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let provider = MiMOASRProvider(
            urlSession: makeSession(),
            secretResolver: InMemorySecretResolver([keyID: "bad"])
        )
        let session = try await provider.makeSession(
            profile: profile,
            options: TranscriptionOptions(sessionID: UUID(), textMode: TextMode())
        )
        do {
            _ = try await session.finish(recordingURL: url)
            XCTFail("expected unauthorized")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .unauthorized(status: 401))
        }
    }

    func testValidationForHTTPRequiresLocalOptIn() {
        var profile = EndpointProfile.defaultMiMOProfile()
        profile.apiKeyItemID = UUID()
        profile.endpointURL = "http://10.144.144.4:8080/v1/chat/completions"
        XCTAssertTrue(profile.validation().errors.contains(.insecureRemoteURL))

        profile.mimo.allowsInsecureLocalHTTP = true
        XCTAssertTrue(profile.validation().isValid)

        profile.endpointURL = "http://example.com/v1/chat/completions"
        XCTAssertTrue(profile.validation().errors.contains(.insecureRemoteURL))
    }

    func testLegacyProfileDecodesWithNewOptions() throws {
        // 模拟旧版本保存的 profile：编码后再删掉新增的 aliyun / mimo 键。
        var original = EndpointProfile.defaultOpenAIProfile()
        original.apiKeyItemID = UUID()
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "aliyun")
        object.removeValue(forKey: "mimo")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let profile = try JSONDecoder().decode(EndpointProfile.self, from: legacy)
        XCTAssertEqual(profile.aliyun.model, "paraformer-realtime-v2")
        XCTAssertEqual(profile.mimo.model, "mimo-v2.5-asr")
        XCTAssertFalse(profile.mimo.allowsInsecureLocalHTTP)
    }
}
