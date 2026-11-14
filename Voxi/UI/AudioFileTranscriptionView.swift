import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AudioFileTranscriptionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case converting(Double)
        case transcribing(Double)
        case done(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .converting, .transcribing: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var fileName = ""
    @Published private(set) var interimText = ""
    @Published private(set) var notice: String?

    private let settings: SettingsStore
    private var targetPID: pid_t?
    private var sourceURL: URL?
    private var wavURL: URL?
    private var workTask: Task<Void, Never>?
    private var session: (any TranscriptionSession)?

    init(settings: SettingsStore, targetPID: pid_t?) {
        self.settings = settings
        self.targetPID = targetPID
    }

    var providerName: String {
        settings.activeProfile?.name ?? "未配置识别端点"
    }

    var canStart: Bool {
        sourceURL != nil && settings.activeProfile != nil && !phase.isBusy
    }

    func updateTargetPID(_ pid: pid_t?) {
        targetPID = pid
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "选择"
        panel.message = "选择要转写的音频文件（wav / mp3 / m4a / aiff 等）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceURL = url
        fileName = url.lastPathComponent
        phase = .idle
        notice = nil
    }

    func start() {
        guard let sourceURL, let profile = settings.activeProfile, !phase.isBusy else { return }
        cleanTempFile()
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Voxi-upload-\(UUID().uuidString).wav")
        self.wavURL = wavURL
        phase = .converting(0)

        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try AudioFileConverter.convertToPCM16WAV(
                        source: sourceURL,
                        destination: wavURL
                    ) { progress in
                        Task { @MainActor [weak self] in
                            guard let self, case .converting = self.phase else { return }
                            self.phase = .converting(progress)
                        }
                    }
                }.value
                try Task.checkCancellation()
                try await self.transcribe(result: result, profile: profile)
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        workTask?.cancel()
        workTask = nil
        if let session {
            self.session = nil
            Task { await session.cancel() }
        }
        phase = .idle
        interimText = ""
    }

    func retry() {
        phase = .idle
        start()
    }

    func copyResult() {
        guard case .done(let text) = phase else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        notice = "已复制到剪贴板"
    }

    func insertResult() {
        guard case .done(let text) = phase else { return }
        let pid = targetPID
        if let pid {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        }
        Task { [weak self] in
            if pid != nil {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            let outcome = await TextInsertionService().insert(text, expectedFrontmostPID: pid)
            guard let self else { return }
            switch outcome {
            case .inserted:
                self.notice = "已输入到前台应用"
            case .requiresManualCopy(let reason):
                self.notice = "无法自动输入：\(reason)。可复制后手动粘贴。"
            }
        }
    }

    func close() {
        cancel()
        cleanTempFile()
    }

    // MARK: - 识别

    private func transcribe(result: AudioFileConverter.Result, profile: EndpointProfile) async throws {
        let validation = profile.validation()
        guard validation.isValid else {
            throw TranscriptionError.invalidConfiguration(validation.message ?? "端点配置无效。")
        }

        let provider: TranscriptionProvider
        switch profile.kind {
        case .openAICompatible:
            provider = OpenAICompatibleProvider()
        case .volcengineStreaming:
            provider = VolcengineStreamingProvider()
        }

        let options = TranscriptionOptions(
            sessionID: UUID(),
            textMode: settings.settings.textMode,
            audioDuration: result.duration
        )
        let session = try await provider.makeSession(profile: profile, options: options)
        self.session = session
        phase = .transcribing(profile.kind == .volcengineStreaming ? 0 : -1)

        let updatesTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await update in session.updates {
                    if case .interim(let text) = update {
                        self.interimText = text
                    }
                }
            } catch {
                // 最终错误由 finish 抛出。
            }
        }

        let text: String
        if profile.kind == .volcengineStreaming {
            let pcm = try AudioFileConverter.pcmFromWAV(result.url)
            var offset = 0
            while offset < pcm.count {
                try Task.checkCancellation()
                let end = min(offset + 6_400, pcm.count)
                try await session.appendAudio(pcm.subdata(in: offset..<end))
                offset = end
                phase = .transcribing(Double(offset) / Double(pcm.count))
                // 文件转写按 150ms/分片发送，略快于实时，避免长文件等待过久。
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        do {
            let transcription = try await session.finish(recordingURL: result.url)
            updatesTask.cancel()
            self.session = nil
            let finalText = settings.settings.textMode.finalize(transcription.text)
            phase = .done(finalText)
            interimText = ""
        } catch {
            updatesTask.cancel()
            self.session = nil
            throw error
        }
    }

    private func cleanTempFile() {
        if let wavURL {
            try? FileManager.default.removeItem(at: wavURL)
        }
        wavURL = nil
    }
}

struct AudioFileTranscriptionView: View {
    @ObservedObject var model: AudioFileTranscriptionModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            footer
        }
        .padding(20)
        .frame(width: 600, height: 480)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("转写音频文件")
                    .font(.title3.weight(.semibold))
                Text("使用当前端点：\(model.providerName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("选择音频文件…") {
                model.chooseFile()
            }
            .disabled(model.phase.isBusy)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.fileName.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                Text(model.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }

        switch model.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text("支持 wav、mp3、m4a、aiff 等常见音频。Voxi 会先转换为 16 kHz 单声道 PCM。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("使用火山流式端点时按分片发送，长文件可能需要接近音频时长的等待。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("开始转写") {
                    model.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
            }

        case .converting(let progress):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress)
                Text("正在转换音频… \(Int(progress * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .transcribing(let progress):
            VStack(alignment: .leading, spacing: 8) {
                if progress >= 0 {
                    ProgressView(value: progress)
                    Text("正在转写… \(Int(progress * 100))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在上传并等待识别结果…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if !model.interimText.isEmpty {
                    Text(model.interimText)
                        .font(.callout)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                }
            }

        case .done(let text):
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 120)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("复制") { model.copyResult() }
                    Button("插入到前台应用") { model.insertResult() }
                    Spacer()
                    Button("再转写一次") { model.retry() }
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("转写失败", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") { model.retry() }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.phase.isBusy {
                Button("取消") { model.cancel() }
            }
            Spacer()
            Button("关闭") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

@MainActor
final class AudioFileTranscriptionWindowController: NSObject, NSWindowDelegate {
    static let shared = AudioFileTranscriptionWindowController()

    private var window: NSWindow?
    private var model: AudioFileTranscriptionModel?

    func show(settings: SettingsStore, targetPID: pid_t?) {
        if let window {
            close()
            window.orderOut(nil)
        }
        let model = AudioFileTranscriptionModel(settings: settings, targetPID: targetPID)
        let hosting = NSHostingController(
            rootView: AudioFileTranscriptionView(model: model) { [weak self] in
                self?.close()
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "转写音频文件"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.model = model
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        model?.close()
        model = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        model?.close()
        model = nil
        window = nil
    }
}
