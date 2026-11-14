import AVFoundation
import Foundation

/// 把任意可读音频文件转换为 Voxi 统一格式：16 kHz / 单声道 / PCM16 LE WAV。
enum AudioFileConverter {
    struct Result {
        let url: URL
        let duration: TimeInterval
        let sampleCount: Int
    }

    enum ConversionError: Error, LocalizedError {
        case unsupportedFormat
        case emptyAudio
        case readFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "无法读取该音频格式。"
            case .emptyAudio: return "音频文件为空。"
            case let .readFailed(message): return "读取音频失败：\(message)"
            case let .writeFailed(message): return "写入临时音频失败：\(message)"
            }
        }
    }

    /// 在调用线程同步转换，调用方应放到后台执行。
    static func convertToPCM16WAV(
        source: URL,
        destination: URL,
        progress: ((Double) -> Void)? = nil
    ) throws -> Result {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: source)
        } catch {
            throw ConversionError.unsupportedFormat
        }

        let inputFormat = file.processingFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw ConversionError.unsupportedFormat
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: PCM16AudioConverter.targetFormat) else {
            throw ConversionError.unsupportedFormat
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let writer: WAVFileWriter
        do {
            writer = try WAVFileWriter(url: destination)
        } catch {
            throw ConversionError.writeFailed(error.localizedDescription)
        }

        let totalFrames = max(0, file.length)
        guard totalFrames > 0 else { throw ConversionError.emptyAudio }

        let bufferSize: AVAudioFrameCount = 8_192
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: bufferSize) else {
            throw ConversionError.unsupportedFormat
        }

        var processed: AVAudioFramePosition = 0
        let ratio = PCM16AudioConverter.targetFormat.sampleRate / inputFormat.sampleRate

        while processed < totalFrames {
            let remaining = totalFrames - processed
            let request = AVAudioFrameCount(min(AVAudioFramePosition(bufferSize), remaining))
            do {
                try file.read(into: input, frameCount: request)
            } catch {
                throw ConversionError.readFailed(error.localizedDescription)
            }
            guard input.frameLength > 0 else { break }
            processed += AVAudioFramePosition(input.frameLength)

            try appendConverted(
                input: input,
                converter: converter,
                ratio: ratio,
                writer: writer
            )
            progress?(min(1, Double(processed) / Double(totalFrames)))
        }

        // 冲刷重采样器尾部
        if let flush = try? flushConverter(converter) {
            try? writer.append(flush)
        }

        let dataBytes = try writer.finalize()
        let sampleCount = dataBytes / 2
        guard sampleCount > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw ConversionError.emptyAudio
        }
        return Result(
            url: destination,
            duration: Double(sampleCount) / PCM16AudioConverter.targetSampleRate,
            sampleCount: sampleCount
        )
    }

    private static func appendConverted(
        input: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        ratio: Double,
        writer: WAVFileWriter
    ) throws {
        let outputFormat = PCM16AudioConverter.targetFormat
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 2_048
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ConversionError.unsupportedFormat
        }
        var provided = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return input
        }
        if let conversionError {
            throw ConversionError.readFailed(conversionError.localizedDescription)
        }
        guard output.frameLength > 0, let pointer = output.int16ChannelData?[0] else { return }
        let byteCount = Int(output.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        try writer.append(Data(bytes: pointer, count: byteCount))
    }

    private static func flushConverter(_ converter: AVAudioConverter) throws -> Data {
        let outputFormat = PCM16AudioConverter.targetFormat
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8_192) else {
            return Data()
        }
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        if let conversionError {
            throw ConversionError.readFailed(conversionError.localizedDescription)
        }
        guard output.frameLength > 0, let pointer = output.int16ChannelData?[0] else { return Data() }
        let byteCount = Int(output.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        return Data(bytes: pointer, count: byteCount)
    }

    static func pcmFromWAV(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { throw ConversionError.emptyAudio }
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
        throw ConversionError.emptyAudio
    }
}
