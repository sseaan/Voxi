import Foundation
import XCTest
@testable import Voxi

/// 构造服务端帧的测试工具（独立于生产 encoder，避免循环验证）。
enum VolcFixture {
    static func be32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    static func serverFrame(
        messageType: UInt8 = 0x9,
        flags: UInt8 = 0x0,
        serialization: UInt8 = 0x1,
        compression: UInt8 = 0x1,
        sequence: Int32? = nil,
        payload: Data
    ) -> Data {
        var frame = Data([(0x1 << 4) | 0x1, (messageType << 4) | flags, (serialization << 4) | compression, 0x00])
        if flags & 0x1 != 0 {
            frame.append(contentsOf: be32(UInt32(bitPattern: sequence ?? 0)))
        }
        frame.append(contentsOf: be32(UInt32(payload.count)))
        frame.append(payload)
        return frame
    }

    static func gzipServerFrame(
        flags: UInt8 = 0x1,
        sequence: Int32 = 1,
        json: String
    ) throws -> Data {
        serverFrame(
            flags: flags,
            compression: 0x1,
            sequence: sequence,
            payload: try Gzip.compress(Data(json.utf8))
        )
    }

    static func errorFrame(code: Int, message: String) -> Data {
        let messageData = Data(message.utf8)
        // 官方图例：header + code + msgLen + msg
        var frame = Data([0x11, 0xF0, 0x10, 0x00])
        frame.append(contentsOf: be32(UInt32(code)))
        frame.append(contentsOf: be32(UInt32(messageData.count)))
        frame.append(messageData)
        return frame
    }
}

final class GzipTests: XCTestCase {
    func testRoundTrip() throws {
        let input = Data(String(repeating: "Voxi 语音识别 gzip 测试。", count: 50).utf8)
        let compressed = try Gzip.compress(input)
        XCTAssertNotEqual(compressed, input)
        XCTAssertEqual(try Gzip.decompress(compressed), input)
    }

    func testDecompressPythonFixture() throws {
        // Python: gzip.compress(b'{"result":{"text":"\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c"}}', mtime=0)
        let base64 = "H4sIAAAAAAAA/6tWKkotLs0pUbKqVipJrQDSSk/2Lni6dO+THdOeT+1Rqq0FALlS9HciAAAA"
        let compressed = try XCTUnwrap(Data(base64Encoded: base64))
        let decompressed = try Gzip.decompress(compressed)
        XCTAssertEqual(String(decoding: decompressed, as: UTF8.self), #"{"result":{"text":"你好世界"}}"#)
    }

    func testGarbageFails() {
        XCTAssertThrowsError(try Gzip.decompress(Data([0x00, 0x01, 0x02, 0x03])))
    }
}

final class VolcengineFrameEncoderTests: XCTestCase {
    func testFullClientRequestHeaderAndPayload() throws {
        let json = Data(#"{"user":{"uid":"test"}}"#.utf8)
        let frame = try VolcengineFrameEncoder.fullClientRequest(json: json)
        let bytes = [UInt8](frame)

        XCTAssertEqual(bytes[0], 0x11, "version 1 + header size 4")
        XCTAssertEqual(bytes[1], 0x11, "full client request + positive sequence")
        XCTAssertEqual(bytes[2], 0x11, "JSON + gzip")
        XCTAssertEqual(bytes[3], 0x00)

        let sequence = Int32(bitPattern: UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
        XCTAssertEqual(sequence, 1, "初始化帧占用序号 1")
        let payloadSize = Int(UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11]))
        XCTAssertEqual(payloadSize, frame.count - 12)
        XCTAssertEqual(try Gzip.decompress(frame.subdata(in: 12..<frame.count)), json)
    }

    func testAudioFrameWithPositiveSequence() throws {
        let pcm = Data(repeating: 0xAB, count: 6_400)
        let frame = try VolcengineFrameEncoder.audioFrame(pcm: pcm, sequence: 3, isLast: false)
        let bytes = [UInt8](frame)

        XCTAssertEqual(bytes[0], 0x11)
        XCTAssertEqual(bytes[1], 0x21, "audio only + positive sequence")
        XCTAssertEqual(bytes[2], 0x01, "raw serialization + gzip")
        let sequence = Int32(bitPattern: UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
        XCTAssertEqual(sequence, 3)

        let payload = frame.subdata(in: 12..<frame.count)
        XCTAssertEqual(try Gzip.decompress(payload), pcm)
    }

    func testLastAudioFrameHasNoSequence() throws {
        let pcm = Data(repeating: 0x01, count: 3_200)
        let frame = try VolcengineFrameEncoder.audioFrame(pcm: pcm, sequence: nil, isLast: true)
        let bytes = [UInt8](frame)

        XCTAssertEqual(bytes[1], 0x22, "最后一包 flags=0x2，无 sequence")
        let payloadSize = Int(UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
        XCTAssertEqual(payloadSize, frame.count - 8)
        XCTAssertEqual(try Gzip.decompress(frame.subdata(in: 8..<frame.count)), pcm)
    }

    func testSequenceIsBigEndian() throws {
        let frame = try VolcengineFrameEncoder.audioFrame(pcm: Data([0x00]), sequence: 0x0102_0304, isLast: false)
        let bytes = [UInt8](frame)
        XCTAssertEqual(Array(bytes[4..<8]), [0x01, 0x02, 0x03, 0x04])
    }
}

final class VolcengineFrameDecoderTests: XCTestCase {
    func testDecodesGzipResponseWithSequence() throws {
        let json = #"{"result":{"text":"你好世界"}}"#
        let frameData = try VolcFixture.gzipServerFrame(flags: 0x1, sequence: 2, json: json)
        let frame = try VolcengineFrameDecoder.decode(frameData)
        XCTAssertEqual(frame.messageType, 0x9)
        XCTAssertEqual(frame.flags, 0x1)
        XCTAssertEqual(frame.sequence, 2)
        XCTAssertFalse(frame.isFinal)
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), json)
    }

    func testDecodesFinalFrame() throws {
        let frameData = try VolcFixture.gzipServerFrame(flags: 0x3, sequence: -1, json: #"{"result":{"text":"完"}}"#)
        let frame = try VolcengineFrameDecoder.decode(frameData)
        XCTAssertTrue(frame.isFinal)
        XCTAssertEqual(frame.sequence, -1)
    }

    func testDecodesUncompressedResponse() throws {
        let json = Data(#"{"result":{"text":"未压缩"}}"#.utf8)
        let frameData = VolcFixture.serverFrame(flags: 0x0, compression: 0x0, payload: json)
        let frame = try VolcengineFrameDecoder.decode(frameData)
        XCTAssertEqual(frame.payload, json)
        XCTAssertFalse(frame.isFinal)
    }

    func testTruncatedFrameThrows() {
        XCTAssertThrowsError(try VolcengineFrameDecoder.decode(Data([0x11, 0x90, 0x11]))) { error in
            XCTAssertEqual(error as? VolcengineCodecError, .truncatedFrame)
        }
    }

    func testInvalidPayloadSizeThrows() {
        var frame = Data([0x11, 0x91, 0x11, 0x00])
        frame.append(contentsOf: VolcFixture.be32(1))     // sequence
        frame.append(contentsOf: VolcFixture.be32(100))   // payload size
        frame.append(contentsOf: Data([0x01, 0x02]))
        XCTAssertThrowsError(try VolcengineFrameDecoder.decode(frame)) { error in
            XCTAssertEqual(error as? VolcengineCodecError, .invalidPayloadSize)
        }
    }

    func testInvalidCompressionThrows() {
        var frame = Data([0x11, 0x90, 0x13, 0x00]) // compression 0x3
        frame.append(contentsOf: VolcFixture.be32(2))
        frame.append(contentsOf: Data([0x01, 0x02]))
        XCTAssertThrowsError(try VolcengineFrameDecoder.decode(frame)) { error in
            XCTAssertEqual(error as? VolcengineCodecError, .invalidHeader)
        }
    }

    func testErrorFrameThrowsServerError() {
        let frame = VolcFixture.errorFrame(code: 45000002, message: "")
        XCTAssertThrowsError(try VolcengineFrameDecoder.decode(frame)) { error in
            XCTAssertEqual(error as? VolcengineServerError, VolcengineServerError(code: 45000002, message: ""))
        }
    }

    func testErrorFrameWithLongMessage() {
        let frame = VolcFixture.errorFrame(code: 45000001, message: "invalid audio format")
        XCTAssertThrowsError(try VolcengineFrameDecoder.decode(frame)) { error in
            XCTAssertEqual(
                error as? VolcengineServerError,
                VolcengineServerError(code: 45000001, message: "invalid audio format")
            )
        }
    }

    func testResponsePayloadJSON() throws {
        let json = """
        {"audio_info":{"duration":1705},"result":{"text":"你好世界","utterances":[
          {"text":"你好","start_time":0,"end_time":800,"definite":true},
          {"text":"世界","start_time":800,"end_time":1705,"definite":false}
        ]}}
        """
        let payload = try JSONDecoder().decode(VolcengineResponsePayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.fullText, "你好世界")
        XCTAssertEqual(payload.audioInfo?.duration, 1705)
        XCTAssertEqual(payload.result?.utterances?.count, 2)
        XCTAssertEqual(payload.lastDefiniteUtterance, "你好")
    }

    func testResponsePayloadWithResultArray() throws {
        let json = #"{"result":[{"text":"第一段"},{"text":"第二段"}]}"#
        let payload = try JSONDecoder().decode(VolcengineResponsePayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.result?.text, "第二段")
    }
}

final class VolcengineAccumulatorTests: XCTestCase {
    private func payload(_ json: String) throws -> VolcengineResponsePayload {
        try JSONDecoder().decode(VolcengineResponsePayload.self, from: Data(json.utf8))
    }

    func testFullModeReplacesInsteadOfAppending() throws {
        var accumulator = VolcengineTranscriptAccumulator(mode: .full)
        accumulator.apply(try payload(#"{"result":{"text":"你好"}}"#))
        XCTAssertEqual(accumulator.previewText, "你好")

        accumulator.apply(try payload(#"{"result":{"text":"你好世界"}}"#))
        XCTAssertEqual(accumulator.previewText, "你好世界", "全量结果必须替换，不能拼接")
        XCTAssertEqual(accumulator.resultText, "你好世界")
    }

    func testSingleModeAppendsEachDefiniteUtteranceOnce() throws {
        var accumulator = VolcengineTranscriptAccumulator(mode: .single)
        accumulator.apply(try payload("""
        {"result":{"text":"你好","utterances":[{"text":"你好","start_time":0,"end_time":500,"definite":true}]}}
        """))
        XCTAssertEqual(accumulator.resultText, "你好")

        // 同一个确定分句再次出现，不能重复拼接
        accumulator.apply(try payload("""
        {"result":{"text":"你好","utterances":[{"text":"你好","start_time":0,"end_time":500,"definite":true}]}}
        """))
        XCTAssertEqual(accumulator.resultText, "你好")

        accumulator.apply(try payload("""
        {"result":{"text":"世界","utterances":[
          {"text":"你好","start_time":0,"end_time":500,"definite":true},
          {"text":"世界","start_time":500,"end_time":900,"definite":true}
        ]}}
        """))
        XCTAssertEqual(accumulator.resultText, "你好世界")
    }

    func testPreviewFallsBackToUtterancesWhenTextMissing() throws {
        var accumulator = VolcengineTranscriptAccumulator(mode: .full)
        accumulator.apply(try payload("""
        {"result":{"utterances":[{"text":"分句一","start_time":0,"end_time":100,"definite":true},{"text":"分句二","start_time":100,"end_time":200,"definite":false}]}}
        """))
        XCTAssertEqual(accumulator.previewText, "分句一分句二")
    }
}
