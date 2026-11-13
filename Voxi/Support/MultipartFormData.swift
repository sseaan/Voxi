import Foundation

/// RFC 7578 multipart/form-data 构造器。
///
/// 只负责字节编码，不做网络请求；boundary 由创建者指定，便于测试。
struct MultipartFormData {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "VoxiBoundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// 添加普通文本字段。
    mutating func addField(name: String, value: String) {
        body.append(Self.utf8("--\(boundary)\r\n"))
        body.append(Self.utf8("Content-Disposition: form-data; name=\"\(Self.escaped(name))\"\r\n\r\n"))
        body.append(Self.utf8(value))
        body.append(Self.crlf)
    }

    /// 添加文件字段。
    mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        body.append(Self.utf8("--\(boundary)\r\n"))
        body.append(Self.utf8(
            "Content-Disposition: form-data; name=\"\(Self.escaped(name))\"; filename=\"\(Self.escaped(filename))\"\r\n"
        ))
        body.append(Self.utf8("Content-Type: \(mimeType)\r\n\r\n"))
        body.append(data)
        body.append(Self.crlf)
    }

    /// 结束符，返回最终 body。
    func finalized() -> Data {
        var final = body
        final.append(Self.utf8("--\(boundary)--\r\n"))
        return final
    }

    // MARK: - 辅助

    private static let crlf = Data([0x0D, 0x0A])

    private static func utf8(_ string: String) -> Data {
        Data(string.utf8)
    }

    /// 防止字段名里的引号破坏 header。
    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
