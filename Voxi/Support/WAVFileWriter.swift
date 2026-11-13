import Foundation

/// 写 16-bit PCM WAV 文件。header 先写占位长度，finalize 时回填，
/// 避免依赖 `AVAudioFile` 的容器行为，方便单元测试。
final class WAVFileWriter {
    let url: URL
    let sampleRate: UInt32
    let channelCount: UInt16
    let bitsPerSample: UInt16

    private let handle: FileHandle
    private var dataByteCount: UInt32 = 0
    private var isFinalized = false

    var byteCount: Int { Int(dataByteCount) }

    init(url: URL, sampleRate: UInt32 = 16_000, channelCount: UInt16 = 1, bitsPerSample: UInt16 = 16) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw AudioCaptureError.fileWriteFailed(url.lastPathComponent)
        }
        self.handle = handle
        try handle.write(contentsOf: Self.header(
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitsPerSample: bitsPerSample,
            dataByteCount: 0
        ))
    }

    func append(_ data: Data) throws {
        guard !isFinalized else { throw AudioCaptureError.fileWriteFailed("writer already finalized") }
        guard !data.isEmpty else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw AudioCaptureError.fileWriteFailed(error.localizedDescription)
        }
        dataByteCount += UInt32(data.count)
    }

    /// 回填 RIFF/data 长度并关闭文件。
    @discardableResult
    func finalize() throws -> Int {
        guard !isFinalized else { return Int(dataByteCount) }
        isFinalized = true
        do {
            // RIFF chunk size = 36 + data bytes
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: Self.uint32LE(36 + dataByteCount))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: Self.uint32LE(dataByteCount))
            try handle.close()
        } catch {
            throw AudioCaptureError.fileWriteFailed(error.localizedDescription)
        }
        return Int(dataByteCount)
    }

    // MARK: - Header

    static let headerByteCount = 44

    static func header(
        sampleRate: UInt32,
        channelCount: UInt16,
        bitsPerSample: UInt16,
        dataByteCount: UInt32
    ) -> Data {
        var data = Data()
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)

        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(36 + dataByteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))                 // fmt chunk size
        data.append(uint16LE(1))                  // PCM
        data.append(uint16LE(channelCount))
        data.append(uint32LE(sampleRate))
        data.append(uint32LE(byteRate))
        data.append(uint16LE(blockAlign))
        data.append(uint16LE(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(dataByteCount))
        return data
    }

    static func uint32LE(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 4)
    }

    static func uint16LE(_ value: UInt16) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 2)
    }
}
