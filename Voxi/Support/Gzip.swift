import Foundation

enum GzipError: Error, LocalizedError, Equatable {
    case compressionFailed
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .compressionFailed: return "gzip 压缩失败。"
        case .decompressionFailed: return "gzip 解压失败。"
        }
    }
}

/// Gzip 工具（火山协议 JSON payload 压缩）。
enum Gzip {
    static func compress(_ data: Data) throws -> Data {
        guard let compressed = VoxiGzipCompress(data) else {
            throw GzipError.compressionFailed
        }
        return compressed
    }

    static func decompress(_ data: Data) throws -> Data {
        if let decompressed = VoxiGzipDecompress(data) {
            return decompressed
        }
        // 少数服务端实现使用 zlib 容器
        if let decompressed = VoxiZlibDecompress(data) {
            return decompressed
        }
        throw GzipError.decompressionFailed
    }
}
