import AVFoundation
import XCTest
@testable import Voxi

final class AudioConversionTests: XCTestCase {
    private func makeSineBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        frequency: Double = 440,
        amplitude: Float = 0.5
    ) throws -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channels = Int(format.channelCount)
        if let floatData = buffer.floatChannelData {
            for channel in 0..<channels {
                for frame in 0..<Int(frameCount) {
                    let t = Double(frame) / format.sampleRate
                    floatData[channel][frame] = amplitude * Float(sin(2 * .pi * frequency * t))
                }
            }
        } else if let intData = buffer.int16ChannelData {
            for channel in 0..<channels {
                for frame in 0..<Int(frameCount) {
                    let t = Double(frame) / format.sampleRate
                    intData[channel][frame] = Int16(amplitude * 32_767 * Float(sin(2 * .pi * frequency * t)))
                }
            }
        }
        return buffer
    }

    func testDownsamples48kHzStereoTo16kMonoPCM16() throws {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let converter = try XCTUnwrap(PCM16AudioConverter(inputFormat: inputFormat))
        let buffer = try makeSineBuffer(format: inputFormat, frameCount: 48_000) // 1 秒

        var data = try converter.convert(buffer)
        data.append(try converter.flush())

        XCTAssertEqual(data.count % 2, 0, "PCM16 数据必须是偶数字节")
        let sampleCount = data.count / 2
        XCTAssertEqual(Double(sampleCount), 16_000, accuracy: 200, "1 秒音频应约为 16000 个样本")

        // 检查输出是合理的 16 位幅度，而不是全零/溢出
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 10_000)
        XCTAssertLessThanOrEqual(peak, 32_767)
    }

    func testConvertsFloat32ToInt16Scale() throws {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(PCM16AudioConverter(inputFormat: inputFormat))
        let frameCount: AVAudioFrameCount = 1_600
        let buffer = try makeSineBuffer(format: inputFormat, frameCount: frameCount)

        let data = try converter.convert(buffer)

        XCTAssertEqual(Double(data.count / 2), 1_600, accuracy: 10)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 12_000, "0.5 幅度应接近 16383")
    }

    func testStereoIsDownmixedNotDuplicated() throws {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false)!
        let converter = try XCTUnwrap(PCM16AudioConverter(inputFormat: inputFormat))
        let buffer = try makeSineBuffer(format: inputFormat, frameCount: 1_600)
        let data = try converter.convert(buffer)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertGreaterThan(samples.count, 1_000)
        XCTAssertLessThanOrEqual(samples.count, 1_700, "立体声混成单声道，样本数不应翻倍")
    }

    func testOutputFormatIsTargetFormat() throws {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(PCM16AudioConverter(inputFormat: inputFormat))
        XCTAssertEqual(converter.outputFormat.sampleRate, 16_000)
        XCTAssertEqual(converter.outputFormat.channelCount, 1)
        XCTAssertEqual(converter.outputFormat.commonFormat, .pcmFormatInt16)
    }

    func testInvalidInputFormatFails() {
        let zeroFormat = AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)
        XCTAssertNil(PCM16AudioConverter(inputFormat: zeroFormat ?? AVAudioFormat()))
    }
}

final class WAVFileWriterTests: XCTestCase {
    private func makePCM16Data(seconds: Double = 1, sampleRate: Double = 16_000) -> Data {
        let sampleCount = Int(seconds * sampleRate)
        var data = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let value = Int16(8_000 * sin(2 * .pi * 220 * Double(index) / sampleRate))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testWAVHeaderAndLength() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVFileWriter(url: url)
        let pcm = makePCM16Data(seconds: 1.5)
        try writer.append(pcm)
        let byteCount = try writer.finalize()

        XCTAssertEqual(byteCount, pcm.count)

        let fileData = try Data(contentsOf: url)
        XCTAssertEqual(fileData.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(fileData[8..<12], Data("WAVE".utf8))
        XCTAssertEqual(fileData[12..<16], Data("fmt ".utf8))

        let riffSize = fileData[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let dataSize = fileData[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: riffSize), UInt32(36 + pcm.count))
        XCTAssertEqual(UInt32(littleEndian: dataSize), UInt32(pcm.count))

        let sampleRate = fileData[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let channels = fileData[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        let bits = fileData[34..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        XCTAssertEqual(UInt32(littleEndian: sampleRate), 16_000)
        XCTAssertEqual(UInt16(littleEndian: channels), 1)
        XCTAssertEqual(UInt16(littleEndian: bits), 16)
    }

    func testWAVReadableByAVAudioFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wav-read-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVFileWriter(url: url)
        try writer.append(makePCM16Data(seconds: 2))
        try writer.finalize()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000, accuracy: 0.01)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(file.length, 32_000)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
    }

    func testMetadataDerivedValues() throws {
        let metadata = AudioRecordingMetadata(
            fileURL: URL(fileURLWithPath: "/tmp/x.wav"),
            sampleRate: 16_000,
            channelCount: 1,
            bitsPerSample: 16,
            sampleCount: 24_000
        )
        XCTAssertEqual(metadata.duration, 1.5, accuracy: 0.0001)
        XCTAssertEqual(metadata.byteCount, 48_000)
    }
}

final class AudioFileConverterTests: XCTestCase {
    func testConverts44kStereoFileTo16kMonoWAV() throws {
        let directory = FileManager.default.temporaryDirectory
        let source = directory.appendingPathComponent("src-\(UUID().uuidString).wav")
        let destination = directory.appendingPathComponent("dst-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        // 生成 1 秒 44.1kHz 立体声 WAV 源文件
        let writer = try WAVFileWriter(url: source, sampleRate: 44_100, channelCount: 2, bitsPerSample: 16)
        var pcm = Data()
        for index in 0..<44_100 {
            let value = Int16(2_000 * sin(2 * .pi * 440 * Double(index) / 44_100))
            for _ in 0..<2 {
                withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        try writer.append(pcm)
        try writer.finalize()

        var lastProgress = 0.0
        let result = try AudioFileConverter.convertToPCM16WAV(source: source, destination: destination) { progress in
            lastProgress = progress
        }

        XCTAssertEqual(lastProgress, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.duration, 1.0, accuracy: 0.05)
        XCTAssertGreaterThan(result.sampleCount, 15_000)
        XCTAssertLessThan(result.sampleCount, 17_000)

        let converted = try AVAudioFile(forReading: destination)
        XCTAssertEqual(converted.fileFormat.sampleRate, 16_000, accuracy: 0.01)
        XCTAssertEqual(converted.fileFormat.channelCount, 1)
    }

    func testUnsupportedOrEmptyFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not audio".utf8).write(to: url)
        XCTAssertThrowsError(try AudioFileConverter.convertToPCM16WAV(
            source: url,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).wav")
        ))
    }
}

final class AudioLevelTests: XCTestCase {
    func testChunkIsSplitIntoRealtimeSubLevels() {
        let chunk = Data(repeating: 0, count: 6_400)
        let levels = AppCoordinator.audioLevels(fromPCM16: chunk)
        XCTAssertEqual(levels.count, 5, "6400 字节按 1280 字节切成 5 段")
        XCTAssertTrue(levels.allSatisfy { $0 == 0 })
    }

    func testSilenceLevelIsZero() {
        let silence = Data(repeating: 0, count: 6_400)
        XCTAssertEqual(AppCoordinator.audioLevel(fromPCM16: silence), 0, accuracy: 0.001)
    }

    func testLoudSineLevelIsWithinRange() {
        var data = Data()
        for index in 0..<3_200 {
            let value = Int16(16_000 * sin(2 * .pi * 220 * Double(index) / 16_000))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let level = AppCoordinator.audioLevel(fromPCM16: data)
        XCTAssertGreaterThan(level, 0.3)
        XCTAssertLessThanOrEqual(level, 1.0)
    }
}

final class PCMChunkerTests: XCTestCase {
    func testSplitsIntoExactChunksAndKeepsRemainder() {
        var chunker = PCMChunker(chunkByteCount: 6_400)
        let chunks = chunker.append(Data(repeating: 0xAA, count: 7_000))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 6_400)
        XCTAssertEqual(chunker.pendingByteCount, 600)

        XCTAssertEqual(chunker.drain()?.count, 600)
        XCTAssertEqual(chunker.pendingByteCount, 0)
        XCTAssertNil(chunker.drain())
    }

    func testMultipleChunksAcrossAppends() {
        var chunker = PCMChunker(chunkByteCount: 6_400)
        var all: [Data] = []
        all += chunker.append(Data(repeating: 0x01, count: 6_000))
        all += chunker.append(Data(repeating: 0x02, count: 6_000))
        all += chunker.append(Data(repeating: 0x03, count: 6_000))
        XCTAssertEqual(all.count, 2, "18,000 字节应产生两个 6,400 字节分片")
        XCTAssertEqual(all.map(\.count), [6_400, 6_400])
        XCTAssertEqual(chunker.pendingByteCount, 5_200)
        XCTAssertEqual(chunker.drain()?.count, 5_200)
    }

    func testSmallInputProducesNoChunks() {
        var chunker = PCMChunker(chunkByteCount: 6_400)
        XCTAssertTrue(chunker.append(Data(repeating: 0x00, count: 100)).isEmpty)
        XCTAssertEqual(chunker.pendingByteCount, 100)
    }
}
