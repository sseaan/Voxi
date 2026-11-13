import AVFoundation
import Foundation

enum AudioCaptureError: Error, LocalizedError, Equatable {
    case alreadyRunning
    case notRunning
    case noInputDevice
    case converterCreationFailed
    case engineStartFailed(String)
    case fileWriteFailed(String)
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "录音已经在进行中。"
        case .notRunning: return "当前没有进行中的录音。"
        case .noInputDevice: return "没有可用的麦克风输入设备，请检查系统声音设置。"
        case .converterCreationFailed: return "无法创建音频格式转换器（16 kHz / 单声道 / PCM16）。"
        case let .engineStartFailed(message): return "无法启动录音引擎：\(message)"
        case let .fileWriteFailed(message): return "写入临时录音文件失败：\(message)"
        case .emptyRecording: return "没有采集到音频数据。"
        }
    }
}

/// 录音产物元数据。
struct AudioRecordingMetadata: Equatable {
    let fileURL: URL
    let sampleRate: Double
    let channelCount: Int
    let bitsPerSample: Int
    let sampleCount: Int

    var duration: TimeInterval {
        sampleRate > 0 ? Double(sampleCount) / sampleRate : 0
    }

    var byteCount: Int {
        sampleCount * (bitsPerSample / 8) * channelCount
    }
}

/// 把输入缓冲转换成 16 kHz / 单声道 / signed PCM16 little-endian。
final class PCM16AudioConverter {
    static let targetSampleRate: Double = 16_000
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: true
    )!

    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat = PCM16AudioConverter.targetFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            return nil
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        // 高质量重采样，避免 44.1k/48k 硬件采样率转换产生明显失真。
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }

    /// 冲刷重采样器内部缓冲，取出结尾残留样本。只能在最后调用一次。
    func flush() throws -> Data {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8_192) else {
            return Data()
        }
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        if let conversionError {
            throw AudioCaptureError.engineStartFailed(conversionError.localizedDescription)
        }
        guard output.frameLength > 0, let pointer = output.int16ChannelData?[0] else { return Data() }
        let byteCount = Int(output.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        return Data(bytes: pointer, count: byteCount)
    }

    /// 转换一个缓冲区。输出为紧凑的 Int16 LE 字节。
    func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.converterCreationFailed
        }

        var providedInput = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if providedInput {
                status.pointee = .noDataNow
                return nil
            }
            providedInput = true
            status.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw AudioCaptureError.engineStartFailed(conversionError.localizedDescription)
        }

        guard output.frameLength > 0, let pointer = output.int16ChannelData?[0] else {
            return Data()
        }
        let byteCount = Int(output.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        return Data(bytes: pointer, count: byteCount)
    }
}

/// 把连续 PCM 字节切成固定大小的分片（默认约 200 ms @ 16 kHz PCM16 = 6400 字节）。
struct PCMChunker {
    let chunkByteCount: Int
    private var buffer = Data()

    init(chunkByteCount: Int = 6_400) {
        self.chunkByteCount = chunkByteCount
    }

    var pendingByteCount: Int { buffer.count }

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var chunks: [Data] = []
        while buffer.count >= chunkByteCount {
            chunks.append(Data(buffer.prefix(chunkByteCount)))
            buffer.removeFirst(chunkByteCount)
        }
        return chunks
    }

    /// 取出不足一个分片的剩余字节。
    mutating func drain() -> Data? {
        guard !buffer.isEmpty else { return nil }
        let remainder = buffer
        buffer.removeAll(keepingCapacity: false)
        return remainder
    }
}

/// 录音采集接口，便于协调器注入假实现做状态机测试。
protocol AudioCapturing: AnyObject {
    /// 开始采集并返回 PCM 分片流；调用方必须持续消费。
    func start() throws -> AsyncStream<Data>
    /// 结束采集并返回录音元数据。
    func finish() throws -> AudioRecordingMetadata
    /// 取消采集并清理临时文件。
    func cancel()
}

/// 麦克风采集：AVAudioEngine tap → 16 kHz mono PCM16 分片 + 临时 WAV。
///
/// 线程模型：tap 在音频线程上回调，转换/写文件/分片都在该线程内完成；
/// `finish`/`cancel` 在主线程调用，用锁串行化。所有网络与 UI 工作都在外部进行。
final class AudioCaptureService: AudioCapturing {
    static let chunkByteCount = 6_400

    /// 开发诊断：设置 `VOXI_KEEP_RECORDINGS=1` 时保留临时 WAV 并打印路径。
    static var keepRecordingsForDiagnostics: Bool {
        ProcessInfo.processInfo.environment["VOXI_KEEP_RECORDINGS"] == "1"
    }

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var writer: WAVFileWriter?
    private var converter: PCM16AudioConverter?
    private var chunker = PCMChunker(chunkByteCount: AudioCaptureService.chunkByteCount)
    private var continuation: AsyncStream<Data>.Continuation?
    private var startedAt: Date?
    private var currentURL: URL?
    private var isRunning = false

    var recordingURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return currentURL
    }

    /// 开始采集并返回 PCM 分片流。调用方必须消费该流，否则内存会增长。
    func start() throws -> AsyncStream<Data> {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { throw AudioCaptureError.alreadyRunning }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Voxi-\(UUID().uuidString).wav")
        let writer = try WAVFileWriter(url: url)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }
        guard let converter = PCM16AudioConverter(inputFormat: hardwareFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }

        var streamContinuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            streamContinuation = continuation
        }

        input.installTap(onBus: 0, bufferSize: 4_096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        self.engine = engine
        self.writer = writer
        self.converter = converter
        self.continuation = streamContinuation
        self.chunker = PCMChunker(chunkByteCount: Self.chunkByteCount)
        self.startedAt = Date()
        self.currentURL = url
        self.isRunning = true

        Logger.audio.info("开始采集 hardware=\(Int(hardwareFormat.sampleRate), privacy: .public)Hz ch=\(hardwareFormat.channelCount, privacy: .public) url=\(url.lastPathComponent, privacy: .public)")
        return stream
    }

    /// 结束采集，写完 WAV 并返回元数据。空的录音会抛 `emptyRecording`。
    func finish() throws -> AudioRecordingMetadata {
        lock.lock()
        guard isRunning, let engine, let writer, let url = currentURL else {
            lock.unlock()
            throw AudioCaptureError.notRunning
        }
        isRunning = false
        lock.unlock()

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        lock.lock()
        var flushData: Data?
        if let converter = self.converter {
            flushData = try? converter.flush()
        }
        if let flushData, !flushData.isEmpty, let writer = self.writer {
            try? writer.append(flushData)
        }
        var remainder: Data?
        if chunker.pendingByteCount > 0 {
            remainder = chunker.drain()
        }
        let continuation = self.continuation
        self.continuation = nil
        self.engine = nil
        self.converter = nil
        self.writer = nil
        self.currentURL = nil
        let startedAt = self.startedAt
        self.startedAt = nil
        lock.unlock()

        if let remainder, !remainder.isEmpty {
            try? writer.append(remainder)
            continuation?.yield(remainder)
        }
        continuation?.finish()

        let dataBytes = try writer.finalize()
        let metadata = AudioRecordingMetadata(
            fileURL: url,
            sampleRate: PCM16AudioConverter.targetSampleRate,
            channelCount: 1,
            bitsPerSample: 16,
            sampleCount: dataBytes / 2
        )

        Logger.audio.info("结束采集 bytes=\(dataBytes, privacy: .public) duration=\(String(format: "%.2f", metadata.duration), privacy: .public)s")

        guard dataBytes > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureError.emptyRecording
        }
        if let startedAt {
            Logger.audio.debug("采集耗时 \(Date().timeIntervalSince(startedAt), privacy: .public)s")
        }
        return metadata
    }

    /// 取消采集并删除临时文件。
    func cancel() {
        lock.lock()
        guard isRunning, let engine else {
            lock.unlock()
            cleanupFileOnly()
            return
        }
        isRunning = false
        let continuation = self.continuation
        let url = currentURL
        self.continuation = nil
        self.engine = nil
        self.converter = nil
        self.writer = nil
        self.currentURL = nil
        self.startedAt = nil
        self.chunker = PCMChunker(chunkByteCount: Self.chunkByteCount)
        lock.unlock()

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        continuation?.finish()

        if let url, !Self.keepRecordingsForDiagnostics {
            try? FileManager.default.removeItem(at: url)
        }
        Logger.audio.info("取消采集，已清理临时文件")
    }

    /// 删除指定录音文件（正常流程结束后调用）。
    static func removeRecording(at url: URL) {
        guard !keepRecordingsForDiagnostics else {
            Logger.audio.info("保留诊断录音: \(url.path, privacy: .public)")
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func cleanupFileOnly() {
        if let url = currentURL, !Self.keepRecordingsForDiagnostics {
            try? FileManager.default.removeItem(at: url)
        }
        currentURL = nil
    }

    // MARK: - 音频线程

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let converter = self.converter
        lock.unlock()

        guard let converter else { return }

        let data: Data
        do {
            data = try converter.convert(buffer)
        } catch {
            Logger.audio.error("音频转换失败: \(String(describing: error), privacy: .public)")
            return
        }
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }

        if let writer {
            do {
                try writer.append(data)
            } catch {
                Logger.audio.error("写入 WAV 失败: \(String(describing: error), privacy: .public)")
            }
        }
        for chunk in chunker.append(data) {
            continuation?.yield(chunk)
        }
    }
}
