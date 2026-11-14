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
        let profiles = settings.settings.profiles
        guard let first = profiles.first else { return "未配置识别端点" }
        return profiles.count > 1
            ? "\(first.name) + \(profiles.count - 1) 个备用模型"
            : first.name
    }

    var canStart: Bool {
        sourceURL != nil && !settings.settings.profiles.isEmpty && !phase.isBusy
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
        guard let sourceURL, !settings.settings.profiles.isEmpty, !phase.isBusy else { return }
        cleanTempFile()
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Voxi-upload-\(UUID().uuidString).wav")
        self.wavURL = wavURL
        phase = .converting(0)
        notice = nil

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
                try await self.transcribeWithFallback(result: result)
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

    func exportTXT() {
        guard case .done(let text) = phase else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let base = (fileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = (base.isEmpty ? "转写结果" : base) + ".txt"
        panel.message = "导出转写文本"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            notice = "已导出：\(url.lastPathComponent)"
        } catch {
            notice = "导出失败：\(error.localizedDescription)"
        }
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

    /// 火山流式单次连接适合 ≤60 秒音频，长文件自动分段，逐段转写后拼接。
    private static let volcengineSegmentBytes = 1_600_000  // 50 秒 @ 16 kHz / mono / PCM16

    private func transcribeWithFallback(result: AudioFileConverter.Result) async throws {
        var attempts: [String] = []
        let profiles = settings.settings.profiles
        for (index, profile) in profiles.enumerated() {
            try Task.checkCancellation()
            do {
                let text = try await transcribe(result: result, profile: profile)
                var styledText = text
                var styleFailure: String?
                let style = settings.settings.activeStyle
                if style.requiresLLM {
                    phase = .transcribing(-1)
                    notice = "正在按「\(style.name)」整理…"
                    do {
                        styledText = try await StyleProcessor.process(
                            text: text,
                            settings: settings.settings
                        )
                        try Task.checkCancellation()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        styleFailure = "风格处理失败，已使用原文：\(error.localizedDescription)"
                    }
                }
                let finalText = settings.settings.textMode.finalize(
                    settings.settings.lexicon.replacing(in: styledText)
                )
                phase = .done(finalText)
                interimText = ""
                notice = styleFailure
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let name = profile.name.isEmpty ? profile.kind.displayName : profile.name
                attempts.append("\(name)：\(error.localizedDescription)")
                interimText = ""
                if index < profiles.count - 1 {
                    notice = "「\(name)」失败，正在尝试备用模型…"
                }
            }
        }
        throw AllModelsFailedError(attempts: attempts)
    }

    private func transcribe(result: AudioFileConverter.Result, profile: EndpointProfile) async throws -> String {
        let validation = profile.validation()
        guard validation.isValid else {
            throw TranscriptionError.invalidConfiguration(validation.message ?? "端点配置无效。")
        }

        if profile.kind == .volcengineStreaming {
            return try await transcribeWithVolcengine(result: result, profile: profile)
        } else {
            return try await transcribeWithOpenAI(result: result, profile: profile)
        }
    }

    private func transcribeWithOpenAI(result: AudioFileConverter.Result, profile: EndpointProfile) async throws -> String {
        let provider = OpenAICompatibleProvider()
        // 长音频的服务端处理时间可能超过端点默认超时，按音频时长放宽。
        let timeout = max(profile.openAI.timeoutSeconds, result.duration * 1.2 + 60)
        let options = TranscriptionOptions(
            sessionID: UUID(),
            textMode: settings.settings.textMode,
            audioDuration: result.duration,
            requestTimeout: timeout,
            lexicon: settings.settings.lexicon
        )
        let session = try await provider.makeSession(profile: profile, options: options)
        self.session = session
        phase = .transcribing(-1)

        do {
            let transcription = try await session.finish(recordingURL: result.url)
            self.session = nil
            return transcription.text
        } catch {
            self.session = nil
            throw error
        }
    }

    private func transcribeWithVolcengine(result: AudioFileConverter.Result, profile: EndpointProfile) async throws -> String {
        let provider = VolcengineStreamingProvider()
        let pcm = try AudioFileConverter.pcmFromWAV(result.url)
        let totalBytes = max(pcm.count, 1)
        var offset = 0
        var pieces: [String] = []

        while offset < pcm.count {
            try Task.checkCancellation()
            let end = min(offset + Self.volcengineSegmentBytes, pcm.count)
            let segment = pcm.subdata(in: offset..<end)
            let options = TranscriptionOptions(
                sessionID: UUID(),
                textMode: settings.settings.textMode,
                audioDuration: Double(segment.count) / 32_000,
                lexicon: settings.settings.lexicon
            )
            let session = try await provider.makeSession(profile: profile, options: options)
            self.session = session

            let prefix = Self.joinTranscripts(pieces)
            let updatesTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await update in session.updates {
                        if case .interim(let text) = update {
                            self.interimText = Self.joinTranscripts([prefix, text])
                        }
                    }
                } catch {
                    // 最终错误由 finish 抛出。
                }
            }

            var segmentOffset = 0
            while segmentOffset < segment.count {
                try Task.checkCancellation()
                let chunkEnd = min(segmentOffset + 6_400, segment.count)
                try await session.appendAudio(segment.subdata(in: segmentOffset..<chunkEnd))
                segmentOffset = chunkEnd
                phase = .transcribing(Double(offset + segmentOffset) / Double(totalBytes))
                // 略快于实时发送，长文件才不至于等太久。
                try? await Task.sleep(nanoseconds: 150_000_000)
            }

            do {
                let transcription = try await session.finish(recordingURL: result.url)
                updatesTask.cancel()
                self.session = nil
                let piece = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { pieces.append(piece) }
                offset = end
            } catch {
                updatesTask.cancel()
                self.session = nil
                throw error
            }
        }

        return Self.joinTranscripts(pieces)
    }

    /// 段间拼接：两侧都是 ASCII 字符时补一个空格，中文直接相连。
    nonisolated static func joinTranscripts(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if let last = result.last, let first = part.first,
               last.isASCII, first.isASCII,
               !last.isWhitespace, !first.isWhitespace {
                result += " "
            }
            result += part
        }
        return result
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
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
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
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
                HStack {
                    Button("复制") { model.copyResult() }
                    Button("导出 TXT…") { model.exportTXT() }
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
        if window != nil {
            close()
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
