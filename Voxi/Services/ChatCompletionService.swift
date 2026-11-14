import Foundation

/// 通用 OpenAI-compatible Chat Completions 客户端。
/// 只承担“把一段文字按提示词整理”的职责，不做流式、不重试。
struct ChatCompletionService {
    var urlSession: URLSession = .shared
    var secretResolver: SecretResolving = KeychainSecretResolver()

    enum ChatError: LocalizedError {
        case invalidConfiguration(String)
        case http(status: Int, message: String)
        case invalidResponse
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let message):
                return message
            case .http(let status, let message):
                let hint: String
                switch status {
                case 401: hint = "API Key 无效或无权限"
                case 402: hint = "账户余额不足或额度用尽"
                case 403: hint = "无权访问该模型"
                case 404: hint = "Endpoint 路径或模型不存在"
                case 429: hint = "请求过于频繁或额度用尽"
                default: hint = "服务返回错误"
                }
                let detail = message.isEmpty ? "" : "：\(message)"
                return "语言模型请求失败（HTTP \(status)，\(hint)）\(detail)"
            case .invalidResponse:
                return "语言模型返回了无法解析的响应。"
            case .emptyResponse:
                return "语言模型没有返回文本。"
            }
        }
    }

    func complete(
        profile: LanguageModelProfile,
        systemPrompt: String,
        userText: String
    ) async throws -> String {
        if let message = profile.validation() {
            throw ChatError.invalidConfiguration(message)
        }
        guard let url = profile.chatCompletionsURL else {
            throw ChatError.invalidConfiguration("Chat Completions 地址无效。")
        }

        var secret: String?
        if profile.authMode == .bearer {
            guard let itemID = profile.apiKeyItemID else {
                throw ChatError.invalidConfiguration("缺少 API Key。")
            }
            secret = try await SecretReader.secret(secretResolver, for: itemID)
        }

        let payload = RequestPayload(
            model: profile.model.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userText)
            ],
            temperature: profile.temperature,
            stream: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = profile.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret, !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        let decoded = try? JSONDecoder().decode(ResponsePayload.self, from: data)
        guard (200...299).contains(status) else {
            let message = decoded?.error?.message
                ?? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            throw ChatError.http(status: status, message: String(message.prefix(300)))
        }
        guard let content = decoded?.choices?.first?.message?.content
            ?? decoded?.choices?.first?.text
        else {
            throw ChatError.invalidResponse
        }
        let output = Self.cleaning(content)
        guard !output.isEmpty else { throw ChatError.emptyResponse }
        return output
    }

    /// 去掉模型偶尔包上的 Markdown 代码围栏。
    static func cleaning(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            if let firstNewline = value.firstIndex(of: "\n") {
                value = String(value[value.index(after: firstNewline)...])
            }
            if value.hasSuffix("```") {
                value = String(value.dropLast(3))
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private struct RequestPayload: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool
    }

    private struct ResponsePayload: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message?
            let text: String?
        }

        struct APIError: Decodable {
            let message: String?
        }

        let choices: [Choice]?
        let error: APIError?
    }
}
