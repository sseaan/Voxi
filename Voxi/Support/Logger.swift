import Foundation
import OSLog

/// 统一日志入口。禁止记录音频、完整转写文本、API Key、Authorization 等敏感内容。
enum Logger {
    private static let subsystem = "com.voxi.app"

    static let app = os.Logger(subsystem: subsystem, category: "app")
    static let settings = os.Logger(subsystem: subsystem, category: "settings")
    static let shortcut = os.Logger(subsystem: subsystem, category: "shortcut")
    static let audio = os.Logger(subsystem: subsystem, category: "audio")
    static let permissions = os.Logger(subsystem: subsystem, category: "permissions")
    static let keychain = os.Logger(subsystem: subsystem, category: "keychain")
    static let http = os.Logger(subsystem: subsystem, category: "http")
    static let websocket = os.Logger(subsystem: subsystem, category: "websocket")
    static let insertion = os.Logger(subsystem: subsystem, category: "insertion")

    /// URL 脱敏：只保留 scheme + host + path，去掉 query 与 userinfo（可能含 token）。
    static func redactedURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return "<invalid url>" }
        components.user = nil
        components.password = nil
        components.query = components.query == nil ? nil : "<redacted>"
        components.fragment = nil
        return components.string ?? "<invalid url>"
    }

    /// 值脱敏：只保留长度，避免把密钥写进日志。
    static func redactedValue(_ value: String) -> String {
        value.isEmpty ? "<empty>" : "<\(value.count) chars>"
    }
}
