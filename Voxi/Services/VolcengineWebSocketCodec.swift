import Foundation

/// 火山引擎流式 ASR 二进制协议 codec。
///
/// 协议依据（v3 sauc，见 `docs/volcengine-protocol.md`）：
/// - 4 字节 header: version|headerSize, messageType|flags, serialization|compression, reserved
/// - 4 字节大端 payload size；当 flags 最低位为 1 时，还有 4 字节大端 sequence
/// - payload：JSON（gzip 压缩）或原始音频（按 header 声明压缩）
enum VolcengineMessageType: UInt8 {
    case fullClientRequest = 0x1
    case audioOnlyRequest = 0x2
    case fullServerResponse = 0x9
    case serverAck = 0xB
    case serverError = 0xF
}

enum VolcengineMessageFlags: UInt8 {
    case noSequence = 0x0
    case positiveSequence = 0x1
    case lastPacket = 0x2
    case lastPacketWithSequence = 0x3
}

enum VolcengineCodecError: Error, Equatable, LocalizedError {
    case truncatedFrame
    case invalidHeader
    case invalidPayloadSize
    case unsupportedMessageType(UInt8)
    case decompressionFailed
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .truncatedFrame: return "火山协议帧被截断。"
        case .invalidHeader: return "火山协议 header 无效。"
        case .invalidPayloadSize: return "火山协议 payload 长度无效。"
        case let .unsupportedMessageType(type): return "未知的火山消息类型：\(type)。"
        case .decompressionFailed: return "火山响应解压失败。"
        case let .invalidJSON(message): return "火山响应 JSON 无效：\(message)"
        }
    }
}

/// 服务端错误帧。
struct VolcengineServerError: Error, Equatable, LocalizedError {
    let code: Int
    let message: String

    var errorDescription: String? {
        switch code {
        case 45000001: return "火山引擎拒绝请求：参数无效（\(code)）\(message.isEmpty ? "" : "：\(message)")"
        case 45000002: return "火山引擎：空音频（\(code)）。"
        case 45000081: return "火山引擎：等包超时（\(code)），音频发送间隔过大。"
        case 45000151: return "火山引擎：音频格式不正确（\(code)）。"
        case 55000031: return "火山引擎服务繁忙（\(code)），请稍后重试。"
        default: return "火山引擎返回错误（\(code)）：\(message)"
        }
    }
}

/// 解码后的服务端帧。payload 已解压。
struct VolcengineServerFrame: Equatable {
    var messageType: UInt8
    var flags: UInt8
    var serialization: UInt8
    var compression: UInt8
    var sequence: Int32?
    var payload: Data

    var isFinal: Bool {
        flags & VolcengineMessageFlags.lastPacket.rawValue != 0
    }
}

enum VolcengineFrameEncoder {
    /// full client request：JSON + gzip，使用正序号 1。
    ///
    /// 服务端按 `autoAssignedSequence` 校验：初始化帧占序号 1，后续音频包必须从 2 开始，
    /// 否则返回 `45000000 ... mismatch sequence in request`。
    static func fullClientRequest(json: Data, sequence: Int32 = 1) throws -> Data {
        try makeFrame(
            messageType: .fullClientRequest,
            flags: .positiveSequence,
            serialization: 0x1,
            compression: 0x1,
            sequence: sequence,
            payload: try Gzip.compress(json)
        )
    }

    /// audio only request：PCM + gzip。序号从 1 递增；最后一包使用 flags = 0x2（无序号）。
    static func audioFrame(pcm: Data, sequence: Int32?, isLast: Bool) throws -> Data {
        let compressed = try Gzip.compress(pcm)
        if isLast {
            return try makeFrame(
                messageType: .audioOnlyRequest,
                flags: .lastPacket,
                serialization: 0x0,
                compression: 0x1,
                sequence: nil,
                payload: compressed
            )
        }
        return try makeFrame(
            messageType: .audioOnlyRequest,
            flags: sequence == nil ? .noSequence : .positiveSequence,
            serialization: 0x0,
            compression: 0x1,
            sequence: sequence,
            payload: compressed
        )
    }

    static func makeFrame(
        messageType: VolcengineMessageType,
        flags: VolcengineMessageFlags,
        serialization: UInt8,
        compression: UInt8,
        sequence: Int32?,
        payload: Data
    ) throws -> Data {
        var data = Data()
        data.append((0x1 << 4) | 0x1) // version 1, header size 4
        data.append((messageType.rawValue << 4) | flags.rawValue)
        data.append((serialization << 4) | compression)
        data.append(0x00)
        // 官方帧顺序：header → [sequence] → payload size → payload
        if flags == .positiveSequence || flags == .lastPacketWithSequence {
            let value = sequence ?? 0
            data.append(contentsOf: be32(UInt32(bitPattern: value)))
        }
        data.append(contentsOf: be32(UInt32(payload.count)))
        data.append(payload)
        return data
    }

    static func be32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}

enum VolcengineFrameDecoder {
    static func decode(_ data: Data) throws -> VolcengineServerFrame {
        guard data.count >= 8 else { throw VolcengineCodecError.truncatedFrame }
        let bytes = [UInt8](data)
        let version = bytes[0] >> 4
        let headerSize = Int(bytes[0] & 0x0F) * 4
        guard version == 0x1, headerSize >= 4, bytes.count >= headerSize else {
            throw VolcengineCodecError.invalidHeader
        }
        let messageType = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        let serialization = bytes[2] >> 4
        let compression = bytes[2] & 0x0F

        // 错误帧是唯一没有标准 payload size 的例外，单独解析。
        if messageType == VolcengineMessageType.serverError.rawValue {
            throw try decodeError(bytes: bytes, headerSize: headerSize)
        }

        guard bytes.count >= headerSize + 4 else { throw VolcengineCodecError.truncatedFrame }
        var offset = headerSize
        var sequence: Int32?
        if flags & VolcengineMessageFlags.positiveSequence.rawValue != 0 {
            guard bytes.count >= offset + 4 else { throw VolcengineCodecError.truncatedFrame }
            sequence = Int32(bitPattern: readBE32(bytes, offset))
            offset += 4
        }
        guard bytes.count >= offset + 4 else { throw VolcengineCodecError.truncatedFrame }
        let payloadSize = Int(readBE32(bytes, offset))
        offset += 4
        guard bytes.count >= offset + payloadSize else {
            throw VolcengineCodecError.invalidPayloadSize
        }

        var payload = Data(bytes[offset..<(offset + payloadSize)])
        switch compression {
        case 0x1:
            do {
                payload = try Gzip.decompress(payload)
            } catch {
                throw VolcengineCodecError.decompressionFailed
            }
        case 0x0:
            break
        default:
            throw VolcengineCodecError.invalidHeader
        }

        return VolcengineServerFrame(
            messageType: messageType,
            flags: flags,
            serialization: serialization,
            compression: compression,
            sequence: sequence,
            payload: payload
        )
    }

    /// 错误帧兼容两种布局：
    /// 1. header + payloadSize + code + msgLen + msg（常见实现）
    /// 2. header + code + msgLen + msg（官方图例省略 payload size）
    private static func decodeError(bytes: [UInt8], headerSize: Int) throws -> VolcengineServerError {
        guard bytes.count >= headerSize + 8 else { throw VolcengineCodecError.truncatedFrame }
        let first = Int(readBE32(bytes, headerSize))
        let second = Int(readBE32(bytes, headerSize + 4))

        // 布局 1：first = 8 + msgLen，message 从 headerSize+12 开始
        if bytes.count >= headerSize + 12 {
            let msgLen = Int(readBE32(bytes, headerSize + 8))
            if first == 8 + msgLen, bytes.count >= headerSize + 12 + msgLen {
                let message = String(
                    decoding: bytes[(headerSize + 12)..<(headerSize + 12 + msgLen)],
                    as: UTF8.self
                )
                return VolcengineServerError(code: second, message: message)
            }
        }

        // 布局 2：first = code，second = msgLen
        if bytes.count >= headerSize + 8 + second {
            let message = String(
                decoding: bytes[(headerSize + 8)..<(headerSize + 8 + second)],
                as: UTF8.self
            )
            return VolcengineServerError(code: first, message: message)
        }
        throw VolcengineCodecError.invalidPayloadSize
    }

    private static func readBE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}

// MARK: - 响应 JSON

/// 服务端 full server response 的 JSON。
struct VolcengineResponsePayload: Decodable, Equatable {
    struct Utterance: Decodable, Equatable {
        var text: String?
        var definite: Bool?
        var startTime: Int64?
        var endTime: Int64?

        private enum CodingKeys: String, CodingKey {
            case text, definite
            case startTime = "start_time"
            case endTime = "end_time"
        }
    }

    struct Result: Decodable, Equatable {
        var text: String?
        var utterances: [Utterance]?
    }

    struct AudioInfo: Decodable, Equatable {
        var duration: Int64?
    }

    var result: Result?
    var audioInfo: AudioInfo?

    private enum CodingKeys: String, CodingKey {
        case result
        case audioInfo = "audio_info"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioInfo = try container.decodeIfPresent(AudioInfo.self, forKey: .audioInfo)

        // 兼容 result 为对象或数组的两种实现。
        if let object = try? container.decodeIfPresent(Result.self, forKey: .result) {
            result = object
        } else if let array = try? container.decodeIfPresent([Result].self, forKey: .result) {
            result = array.last
        } else {
            result = nil
        }
    }

    /// 用于 UI 预览的累计文本。
    var fullText: String? {
        if let text = result?.text, !text.isEmpty {
            return text
        }
        guard let utterances = result?.utterances else { return nil }
        let joined = utterances.compactMap(\.text).joined()
        return joined.isEmpty ? nil : joined
    }

    /// 最后一个确定分句的文本。
    var lastDefiniteUtterance: String? {
        guard let utterances = result?.utterances else { return nil }
        return utterances.last(where: { $0.definite == true })?.text
    }
}

/// 把服务端累计/增量结果归一成最终文本。
///
/// - `full`：每次都是累计全文，直接替换，绝不拼接。
/// - `single`：增量结果，仅拼接新出现的确定分句。
struct VolcengineTranscriptAccumulator {
    enum Mode {
        case full
        case single
    }

    let mode: Mode
    private(set) var previewText = ""
    private(set) var finalizedText = ""
    private var lastUtteranceTime: Int64 = -1

    init(mode: Mode) {
        self.mode = mode
    }

    mutating func apply(_ payload: VolcengineResponsePayload) {
        switch mode {
        case .full:
            if let full = payload.fullText {
                previewText = full
            }
        case .single:
            var appended = finalizedText
            for utterance in payload.result?.utterances ?? [] {
                guard utterance.definite == true,
                      let text = utterance.text, !text.isEmpty,
                      let start = utterance.startTime else { continue }
                if start > lastUtteranceTime {
                    appended += text
                    lastUtteranceTime = start
                }
            }
            finalizedText = appended
            let partial = payload.result?.text ?? ""
            previewText = appended + partial
        }
    }

    /// 会话结束时使用：full 模式即最后一次预览；single 模式即已拼接的确定文本。
    var resultText: String {
        mode == .full ? previewText : finalizedText
    }
}
