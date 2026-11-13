import AVFoundation
import Foundation

/// 真实 ASR 服务连通性检查（开发工具，不进入 App）。
///
/// 用法（由 scripts/dev/run-real-service-check.sh 编译并调用）：
///     RealServiceCheck volcengine
///     RealServiceCheck openai
///
/// 凭据只从环境变量读取，不写入任何文件。
@main
struct RealServiceCheck {
    static func main() async {
        guard let command = CommandLine.arguments.dropFirst().first else {
            FileHandle.standardError.write(Data("usage: RealServiceCheck <volcengine|openai>\n".utf8))
            exit(2)
        }
        do {
            switch command {
            case "volcengine":
                try await runVolcengine()
            case "openai":
                try await runOpenAI()
            default:
                throw CheckError.invalidArgument(command)
            }
            exit(0)
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }

    // MARK: - 火山引擎

    @MainActor
    static func runVolcengine() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["VOLC_API_KEY"], !apiKey.isEmpty else {
            throw CheckError.missingEnvironment("VOLC_API_KEY")
        }
        let resourceID = environment["VOLC_RESOURCE_ID"] ?? "volc.seedasr.sauc.duration"
        let audioURL = try audioURL()
        let pcm = try pcmFromWAV(audioURL)
        print("volcengine: resourceID=\(resourceID) audio=\(String(format: "%.2f", Double(pcm.count) / 32_000))s")

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

        var interimCount = 0
        let updatesTask = Task {
            for try await update in session.updates {
                if case .interim = update { interimCount += 1 }
            }
        }

        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 6_400, pcm.count)
            try await session.appendAudio(pcm.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let result = try await session.finish(recordingURL: audioURL)
        try? await updatesTask.value

        print("volcengine: interim=\(interimCount) final=\(result.text)")
        print("volcengine: logID=\(result.logID ?? "nil")")
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CheckError.emptyTranscript
        }
        guard interimCount > 0 else { throw CheckError.noInterimResults }
        guard result.logID != nil else { throw CheckError.missingLogID }
    }

    // MARK: - OpenAI-compatible

    @MainActor
    static func runOpenAI() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
            throw CheckError.missingEnvironment("OPENAI_API_KEY")
        }
        guard let endpoint = environment["OPENAI_ENDPOINT"], !endpoint.isEmpty else {
            throw CheckError.missingEnvironment("OPENAI_ENDPOINT")
        }
        let model = environment["OPENAI_MODEL"] ?? "sensevoice"
        let audioURL = try audioURL()

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
        print("openai: model=\(model) final=\(result.text)")
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CheckError.emptyTranscript
        }
    }

    // MARK: - 音频

    static func audioURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["AUDIO"], !path.isEmpty else {
            throw CheckError.missingEnvironment("AUDIO")
        }
        return URL(fileURLWithPath: path)
    }

    static func pcmFromWAV(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { throw CheckError.unreadableAudio }
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
        throw CheckError.unreadableAudio
    }

    enum CheckError: Error, LocalizedError {
        case invalidArgument(String)
        case missingEnvironment(String)
        case unreadableAudio
        case emptyTranscript
        case noInterimResults
        case missingLogID

        var errorDescription: String? {
            switch self {
            case .invalidArgument(let value): return "未知参数：\(value)"
            case .missingEnvironment(let name): return "缺少环境变量 \(name)"
            case .unreadableAudio: return "无法读取 16 kHz mono PCM16 WAV 音频"
            case .emptyTranscript: return "识别结果为空"
            case .noInterimResults: return "没有收到任何流式中间结果"
            case .missingLogID: return "没有记录到 X-Tt-Logid"
            }
        }
    }
}
