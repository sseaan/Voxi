import AVFoundation
import XCTest
@testable import Voxi

/// 真实服务集成检查（默认跳过，需要显式提供环境变量）。
///
/// ```bash
/// VOXI_VOLC_API_KEY=... \
/// VOXI_SENSEVOICE_API_KEY=... \
/// VOXI_SENSEVOICE_ENDPOINT=https://.../v1/audio/transcriptions \
/// VOXI_SENSEVOICE_MODEL=sensevoice \
/// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/// xcodebuild test -project Voxi.xcodeproj -scheme Voxi \
///   -destination 'platform=macOS' -derivedDataPath build/DerivedData \
///   -only-testing:VoxiTests/RealServiceIntegrationTests
/// ```
///
/// 凭据只通过环境变量传入，不会写入仓库或 UserDefaults。
///
/// 注意：`xcodebuild test` 启动的测试宿主不会继承 shell 中临时设置的环境变量，
/// 因此默认会被跳过。日常复跑建议直接使用
/// `scripts/dev/run-real-service-check.sh`（编译同一批 provider 源码），
/// 或在 Xcode scheme 中配置环境变量后运行本测试。
@MainActor
final class RealServiceIntegrationTests: XCTestCase {
    private static let speechText = "你好，这是一次真实的语音输入测试。"
    private var audioURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        audioURL = try Self.makeSpeechWAV(text: Self.speechText)
    }

    override func tearDownWithError() throws {
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        audioURL = nil
        try super.tearDownWithError()
    }

    func testVolcengineRealService() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["VOXI_VOLC_API_KEY"], !apiKey.isEmpty else {
            throw XCTSkip("未设置 VOXI_VOLC_API_KEY")
        }
        let resourceID = environment["VOXI_VOLC_RESOURCE_ID"] ?? "volc.seedasr.sauc.duration"
        let keyID = UUID()
        var profile = EndpointProfile.defaultVolcengineProfile()
        profile.volcengine.resourceID = resourceID
        profile.apiKeyItemID = keyID

        let provider = VolcengineStreamingProvider(
            secretResolver: InMemorySecretResolver([keyID: apiKey]),
            initializationTimeout: 15,
            finalResultTimeout: 20
        )
        let session = try await provider.makeSession(
            profile: profile,
            options: TranscriptionOptions(
                sessionID: UUID(),
                textMode: TextMode(language: .simplifiedChinese, prompt: "", addPunctuation: true, newlineBehavior: .none),
                audioDuration: nil
            )
        )

        var interimTexts: [String] = []
        let updatesTask = Task {
            for try await update in session.updates {
                if case .interim(let text) = update {
                    interimTexts.append(text)
                }
            }
        }

        let pcm = try Self.pcmFromWAV(audioURL)
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 6_400, pcm.count)
            try await session.appendAudio(pcm.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        let result = try await session.finish(recordingURL: audioURL)
        try? await updatesTask.value

        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(interimTexts.isEmpty, "真实流式服务应返回中间结果")
        XCTAssertNotNil(result.logID, "应记录 X-Tt-Logid")
        XCTAssertEqual(result.providerKind, .volcengineStreaming)
    }

    func testSenseVoiceRealService() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["VOXI_SENSEVOICE_API_KEY"], !apiKey.isEmpty,
              let endpoint = environment["VOXI_SENSEVOICE_ENDPOINT"], !endpoint.isEmpty
        else {
            throw XCTSkip("未设置 VOXI_SENSEVOICE_API_KEY / VOXI_SENSEVOICE_ENDPOINT")
        }
        let model = environment["VOXI_SENSEVOICE_MODEL"] ?? "sensevoice"

        let keyID = UUID()
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.endpointURL = endpoint
        profile.openAI.model = model
        profile.openAI.authMode = .bearer
        profile.openAI.sendsLanguageField = false
        profile.openAI.sendsPromptField = false
        profile.apiKeyItemID = keyID

        let provider = OpenAICompatibleProvider(
            secretResolver: InMemorySecretResolver([keyID: apiKey])
        )
        let session = try await provider.makeSession(
            profile: profile,
            options: TranscriptionOptions(
                sessionID: UUID(),
                textMode: TextMode(language: .simplifiedChinese, prompt: "", addPunctuation: true, newlineBehavior: .none),
                audioDuration: nil
            )
        )
        let result = try await session.finish(recordingURL: audioURL)
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(result.providerKind, .openAICompatible)
    }

    // MARK: - 测试音频

    static func makeSpeechWAV(text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let aiff = directory.appendingPathComponent("voxi-test-\(UUID().uuidString).aiff")
        let wav = directory.appendingPathComponent("voxi-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: aiff) }

        try run("/usr/bin/say", ["-v", "Tingting", "-r", "170", "-o", aiff.path, text])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        return wav
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "RealServiceTest",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) 失败：\(message)"]
            )
        }
    }

    static func pcmFromWAV(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { throw TranscriptionError.audioFileUnreadable }
        var offset = 12
        while offset + 8 <= data.count {
            let identifier = data[offset..<offset + 4]
            let sizeBytes = data[offset + 4..<offset + 8]
            let size = Int(sizeBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            if identifier == Data("data".utf8) {
                return data.subdata(in: (offset + 8)..<min(offset + 8 + size, data.count))
            }
            offset += 8 + size + (size % 2)
        }
        throw TranscriptionError.audioFileUnreadable
    }
}
