import Foundation

/// 通用 OpenAI-compatible Chat Completions 配置，用于转写后的风格整理。
/// 与语音识别端点分开保存；API Key 只存 Keychain item 引用。
struct LanguageModelProfile: Identifiable, Codable, Equatable {
    enum AuthMode: String, Codable, CaseIterable, Identifiable {
        case bearer
        case none

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .bearer: return "Bearer API Key"
            case .none: return "无鉴权（本地服务）"
            }
        }
    }

    var id: UUID
    var name: String
    var endpointURL: String
    var model: String
    var authMode: AuthMode
    var apiKeyItemID: UUID?
    var timeoutSeconds: Double
    var temperature: Double

    init(
        id: UUID = UUID(),
        name: String = "通用 OpenAI",
        endpointURL: String = "https://api.openai.com/v1/chat/completions",
        model: String = "gpt-4o-mini",
        authMode: AuthMode = .bearer,
        apiKeyItemID: UUID? = nil,
        timeoutSeconds: Double = 60,
        temperature: Double = 0.3
    ) {
        self.id = id
        self.name = name
        self.endpointURL = endpointURL
        self.model = model
        self.authMode = authMode
        self.apiKeyItemID = apiKeyItemID
        self.timeoutSeconds = timeoutSeconds
        self.temperature = temperature
    }

    /// 允许填完整 `/chat/completions`，也允许只填到 `/v1`。
    var chatCompletionsURL: URL? {
        var raw = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.lowercased().hasSuffix("/chat/completions") {
            raw += "/chat/completions"
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" { return url }
        if scheme == "http" {
            let host = url.host?.lowercased() ?? ""
            if host == "localhost" || host == "127.0.0.1" || host == "::1" { return url }
        }
        return nil
    }

    func validation() -> String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请填写名称。"
        }
        guard chatCompletionsURL != nil else {
            return "请填写有效的 https Chat Completions 地址（本机服务可用 http）。"
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请填写 model。"
        }
        if authMode == .bearer, apiKeyItemID == nil {
            return "请填写 API Key（保存在 Keychain）。"
        }
        guard timeoutSeconds > 0 else {
            return "超时时间必须大于 0 秒。"
        }
        guard (0...2).contains(temperature) else {
            return "temperature 需在 0 到 2 之间。"
        }
        return nil
    }
}
