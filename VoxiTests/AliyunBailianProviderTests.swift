import Foundation
import XCTest
@testable import Voxi

@MainActor
final class AliyunBailianProviderTests: XCTestCase {
    private let keyID = UUID()

    private func event(_ json: String) -> Data { Data(json.utf8) }

    private func resultEvent(_ text: String, sentenceEnd: Bool, heartbeat: Bool = false) -> Data {
        event("""
        {"header":{"task_id":"t","event":"result-generated","attributes":{}},
         "payload":{"output":{"sentence":{"begin_time":0,"end_time":1,"text":"\(text)","heartbeat":\(heartbeat),"sentence_end":\(sentenceEnd)}}}}
        """)
    }

    func testRunTaskJSONMatchesProtocol() throws {
        var profile = EndpointProfile.defaultAliyunProfile()
        profile.aliyun.model = "paraformer-realtime-v2"
        profile.aliyun.languageHints = "zh,en"
        profile.aliyun.maxSentenceSilence = 2_000
        profile.aliyun.semanticPunctuation = true

        let data = try AliyunRequestBuilder.runTaskJSON(
            profile: profile,
            textMode: TextMode(),
            taskID: "task-1"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let header = try XCTUnwrap(root["header"] as? [String: Any])
        XCTAssertEqual(header["action"] as? String, "run-task")
        XCTAssertEqual(header["task_id"] as? String, "task-1")
        XCTAssertEqual(header["streaming"] as? String, "duplex")

        let payload = try XCTUnwrap(root["payload"] as? [String: Any])
        XCTAssertEqual(payload["task_group"] as? String, "audio")
        XCTAssertEqual(payload["task"] as? String, "asr")
        XCTAssertEqual(payload["function"] as? String, "recognition")
        XCTAssertEqual(payload["model"] as? String, "paraformer-realtime-v2")

        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["format"] as? String, "pcm")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(parameters["language_hints"] as? [String], ["zh", "en"])
        XCTAssertEqual(parameters["max_sentence_silence"] as? Int, 2_000)
        XCTAssertEqual(parameters["semantic_punctuation_enabled"] as? Bool, true)
    }

    func testFinishTaskJSON() throws {
        let data = try AliyunRequestBuilder.finishTaskJSON(taskID: "task-9")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let header = try XCTUnwrap(root["header"] as? [String: Any])
        XCTAssertEqual(header["action"] as? String, "finish-task")
        XCTAssertEqual(header["task_id"] as? String, "task-9")
        XCTAssertNotNil(root["payload"] as? [String: Any])
    }

    func testServerEventParsing() throws {
        let parsed = try AliyunServerEvent.parse(resultEvent("你好", sentenceEnd: true))
        XCTAssertEqual(parsed.event, "result-generated")
        XCTAssertEqual(parsed.sentenceText, "你好")
        XCTAssertTrue(parsed.sentenceEnd)
        XCTAssertFalse(parsed.heartbeat)

        let failed = try AliyunServerEvent.parse(event("""
        {"header":{"event":"task-failed","error_code":"CLIENT_ERROR","error_message":"bad key"}}
        """))
        XCTAssertEqual(failed.errorCode, "CLIENT_ERROR")
        XCTAssertEqual(failed.errorMessage, "bad key")
    }

    func testAccumulatorJoinsSentences() {
        var accumulator = AliyunTranscriptAccumulator()
        accumulator.apply(text: "你好", sentenceEnd: false)
        XCTAssertEqual(accumulator.text, "你好")
        accumulator.apply(text: "你好，世界", sentenceEnd: true)
        XCTAssertEqual(accumulator.text, "你好，世界")
        accumulator.apply(text: "Hello", sentenceEnd: true)
        accumulator.apply(text: "world", sentenceEnd: true)
        XCTAssertEqual(accumulator.text, "你好，世界Hello world")
    }

    func testStreamingSessionReturnsFinalText() async throws {
        let transport = FakeVolcengineTransport()
        transport.enqueue(event("""
        {"header":{"task_id":"t","event":"task-started","attributes":{}},"payload":{}}
        """))
        let provider = AliyunBailianProvider(
            transportFactory: { transport },
            secretResolver: InMemorySecretResolver([keyID: "test-key"]),
            readyTimeout: 2,
            finalResultTimeout: 2
        )
        var profile = EndpointProfile.defaultAliyunProfile()
        profile.apiKeyItemID = keyID
        let session = try await provider.makeSession(
            profile: profile,
            options: TranscriptionOptions(sessionID: UUID(), textMode: TextMode())
        )

        XCTAssertEqual(
            transport.connectedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-key"
        )
        XCTAssertTrue(transport.sentFrames.count >= 1)
        let runTask = try XCTUnwrap(
            JSONSerialization.jsonObject(with: transport.sentFrames[0]) as? [String: Any]
        )
        XCTAssertEqual((runTask["header"] as? [String: Any])?["action"] as? String, "run-task")

        transport.enqueue(resultEvent("你好", sentenceEnd: false))
        transport.enqueue(resultEvent("你好，世界", sentenceEnd: true))
        try await session.appendAudio(Data(repeating: 0x01, count: 3_200))
        transport.enqueue(event("""
        {"header":{"task_id":"t","event":"task-finished","attributes":{}},"payload":{}}
        """))

        let result = try await session.finish(recordingURL: URL(fileURLWithPath: "/tmp/empty.wav"))
        XCTAssertEqual(result.text, "你好，世界")
        XCTAssertEqual(result.providerKind, .aliyunBailianStreaming)

        let finishFrame = try XCTUnwrap(transport.sentFrames.last)
        let finish = try XCTUnwrap(JSONSerialization.jsonObject(with: finishFrame) as? [String: Any])
        XCTAssertEqual((finish["header"] as? [String: Any])?["action"] as? String, "finish-task")
    }

    func testTaskFailedSurfacesRemoteError() async throws {
        let transport = FakeVolcengineTransport()
        transport.enqueue(event("""
        {"header":{"task_id":"t","event":"task-started","attributes":{}},"payload":{}}
        """))
        let provider = AliyunBailianProvider(
            transportFactory: { transport },
            secretResolver: InMemorySecretResolver([keyID: "k"]),
            readyTimeout: 2,
            finalResultTimeout: 2
        )
        var profile = EndpointProfile.defaultAliyunProfile()
        profile.apiKeyItemID = keyID
        let session = try await provider.makeSession(
            profile: profile,
            options: TranscriptionOptions(sessionID: UUID(), textMode: TextMode())
        )
        transport.enqueue(event("""
        {"header":{"event":"task-failed","error_code":"InvalidApiKey","error_message":"bad key"}}
        """))
        do {
            _ = try await session.finish(recordingURL: URL(fileURLWithPath: "/tmp/empty.wav"))
            XCTFail("expected failure")
        } catch let error as TranscriptionError {
            if case .remoteError(let message) = error {
                XCTAssertTrue(message.contains("bad key"))
            } else {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testValidationRequiresAPIKey() {
        var profile = EndpointProfile.defaultAliyunProfile()
        XCTAssertTrue(profile.validation().errors.contains(.missingAPIKey))
        profile.apiKeyItemID = UUID()
        XCTAssertTrue(profile.validation().isValid)
    }
}
