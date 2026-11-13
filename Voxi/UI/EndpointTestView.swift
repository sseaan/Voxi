import AVFoundation
import SwiftUI

/// 端点连通性测试：必须真实录制一段音频并由用户确认后发送。
@MainActor
final class EndpointTestModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case recorded(TimeInterval)
        case sending
        case success(String)
        case failure(String)

        var isBusy: Bool { self == .recording || self == .sending }
    }

    @Published private(set) var phase: Phase = .idle
    private let profile: EndpointProfile
    private let capture = AudioCaptureService()
    private var recordingURL: URL?
    private var audioStreamTask: Task<Void, Never>?

    init(profile: EndpointProfile) {
        self.profile = profile
    }

    var canSend: Bool {
        if case .recorded = phase { return true }
        return false
    }

    func startRecording() {
        guard !phase.isBusy else { return }
        do {
            let stream = try capture.start()
            // 测试用途只关心文件，仍需要消费分片避免缓冲堆积。
            audioStreamTask = Task { @MainActor in
                for await _ in stream {}
            }
            phase = .recording
        } catch {
            phase = .failure(error.localizedDescription)
        }
    }

    func stopRecording() async {
        guard phase == .recording else { return }
        audioStreamTask?.cancel()
        do {
            let metadata = try capture.finish()
            recordingURL = metadata.fileURL
            phase = .recorded(metadata.duration)
        } catch {
            phase = .failure(error.localizedDescription)
        }
    }

    func send() async {
        guard let recordingURL, canSend else { return }
        phase = .sending
        do {
            let provider: TranscriptionProvider
            switch profile.kind {
            case .openAICompatible:
                provider = OpenAICompatibleProvider()
            case .volcengineStreaming:
                phase = .failure("火山引擎流式端点的测试将在流式协议接入后提供。请先用一次真实录音验证。")
                return
            }
            let session = try await provider.makeSession(
                profile: profile,
                options: TranscriptionOptions(
                    sessionID: UUID(),
                    textMode: TextMode(),
                    audioDuration: durationSeconds
                )
            )
            let result = try await session.finish(recordingURL: recordingURL)
            phase = .success(result.text)
        } catch {
            phase = .failure(error.localizedDescription)
        }
    }

    func reset() {
        audioStreamTask?.cancel()
        audioStreamTask = nil
        if let recordingURL, phase != .success("") {
            AudioCaptureService.removeRecording(at: recordingURL)
        }
        recordingURL = nil
        phase = .idle
    }

    func discardRecording() {
        if let recordingURL {
            AudioCaptureService.removeRecording(at: recordingURL)
        }
        recordingURL = nil
        phase = .idle
    }

    private var durationSeconds: TimeInterval? {
        if case .recorded(let duration) = phase { return duration }
        return nil
    }
}

struct EndpointTestView: View {
    let profile: EndpointProfile
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: EndpointTestModel

    init(profile: EndpointProfile) {
        self.profile = profile
        _model = StateObject(wrappedValue: EndpointTestModel(profile: profile))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("测试端点：\(profile.name)")
                .font(.headline)
            Text("将录制一段短音频并发送到这个端点（\(Logger.redactedURL(profile.endpointURL))）。录音只在内存与本机临时文件中，不会保存历史。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            content

            HStack {
                Spacer()
                Button("关闭") {
                    model.reset()
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear {
            model.reset()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            Button("开始录制测试音频") {
                model.startRecording()
            }
            .buttonStyle(.borderedProminent)
        case .recording:
            VStack(alignment: .leading, spacing: 8) {
                Label("正在录音…", systemImage: "waveform.circle.fill")
                    .foregroundStyle(.red)
                Button("停止录音") {
                    Task { await model.stopRecording() }
                }
            }
        case .recorded(let duration):
            VStack(alignment: .leading, spacing: 8) {
                Label(String(format: "已录制 %.1f 秒", duration), systemImage: "checkmark.circle")
                HStack {
                    Button("发送到端点") {
                        Task { await model.send() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("重录") {
                        model.discardRecording()
                    }
                }
            }
        case .sending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在上传并等待识别结果…")
            }
        case .success(let text):
            VStack(alignment: .leading, spacing: 6) {
                Label("端点可用", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(text)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        case .failure(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("测试失败", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") {
                    model.discardRecording()
                }
            }
        }
    }
}
