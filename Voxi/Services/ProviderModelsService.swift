import Foundation

enum ProviderModelsError: LocalizedError {
    case invalidEndpoint
    case missingKey
    case unsupported
    case http(status: Int, message: String)
    case noModels
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Endpoint 地址无效，无法推导模型列表地址。"
        case .missingKey:
            return "请先填写 API Key，再获取模型列表。"
        case .unsupported:
            return "这个来源不支持获取模型列表。"
        case .http(let status, let message):
            let detail = message.isEmpty ? "" : "：\(message)"
            return "获取模型列表失败（HTTP \(status)）\(detail)"
        case .noModels:
            return "服务没有返回任何模型。"
        case .invalidResponse:
            return "模型列表响应无法解析。"
        }
    }
}

/// 从 OpenAI-compatible 的 `/models` 拉取模型列表。
struct ProviderModelsService {
    var urlSession: URLSession = .shared
    var secretResolver: SecretResolving = KeychainSecretResolver()

    func fetchASRModels(
        profile: EndpointProfile,
        apiKeyInput: String?
    ) async throws -> [String] {
        guard profile.kind == .openAICompatible else {
            throw ProviderModelsError.unsupported
        }
        guard let endpoint = URL(string: profile.endpointURL) else {
            throw ProviderModelsError.invalidEndpoint
        }
        guard let modelsURL = Self.modelsURL(from: endpoint) else {
            throw ProviderModelsError.invalidEndpoint
        }
        var headers: [String: String] = [:]
        switch profile.openAI.authMode {
        case .none:
            break
        case .bearer, .customHeader:
            let key = try await resolveKey(
                input: apiKeyInput,
                itemID: profile.apiKeyItemID
            )
            if profile.openAI.authMode == .bearer {
                headers["Authorization"] = "Bearer \(key)"
            } else {
                let name = profile.openAI.customAuthHeaderName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ProviderModelsError.missingKey }
                headers[name] = key
            }
        }
        return try await fetch(url: modelsURL, headers: headers, timeout: profile.openAI.timeoutSeconds)
    }

    func fetchLanguageModels(
        profile: LanguageModelProfile,
        apiKeyInput: String?
    ) async throws -> [String] {
        guard let modelsURL = profile.modelsURL else {
            throw ProviderModelsError.invalidEndpoint
        }
        var headers: [String: String] = [:]
        if profile.providerKind == .openCodeGo {
            headers["User-Agent"] = "Voxi/0.1.0 (macOS)"
            headers["x-opencode-client"] = "voxi"
            headers["x-opencode-session"] = profile.id.uuidString
            headers["x-opencode-request"] = UUID().uuidString
            headers["x-opencode-project"] = "default"
        }
        if profile.authMode == .bearer {
            let key = try await resolveKey(input: apiKeyInput, itemID: profile.apiKeyItemID)
            headers["Authorization"] = "Bearer \(key)"
        }
        return try await fetch(url: modelsURL, headers: headers, timeout: profile.timeoutSeconds)
    }

    /// 从 ASR / Chat 地址推导 `/models`：
    /// - /v1/audio/transcriptions -> /v1/models
    /// - /v1/chat/completions -> /v1/models
    /// - /v1 -> /v1/models
    /// - 裸域名 -> /v1/models
    static func modelsURL(from endpoint: URL) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/audio/transcriptions") {
            path = String(path.dropLast("/audio/transcriptions".count)) + "/models"
        } else if path.hasSuffix("/chat/completions") {
            path = String(path.dropLast("/chat/completions".count)) + "/models"
        } else if path.isEmpty {
            path = "/v1/models"
        } else if path.hasSuffix("/v1") {
            path += "/models"
        } else {
            let parent = (path as NSString).deletingLastPathComponent
            path = (parent.isEmpty ? "" : parent) + "/models"
        }
        components.path = path
        return components.url
    }

    private func resolveKey(input: String?, itemID: UUID?) async throws -> String {
        let typed = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !typed.isEmpty { return typed }
        guard let itemID else { throw ProviderModelsError.missingKey }
        return try await SecretReader.secret(secretResolver, for: itemID)
    }

    private func fetch(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> [String] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = max(10, timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let message = Self.errorMessage(from: data)
            throw ProviderModelsError.http(status: status, message: message)
        }
        return try Self.parseModels(data)
    }

    static func parseModels(_ data: Data) throws -> [String] {
        if let array = try? JSONDecoder().decode([String].self, from: data) {
            return try unique(array)
        }
        struct Response: Decodable {
            struct Item: Decodable {
                let id: String?
                let name: String?
            }

            let data: [Item]?
            let models: [Item]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ProviderModelsError.invalidResponse
        }
        let items = response.data ?? response.models ?? []
        let models = try unique(items.compactMap { $0.id ?? $0.name })
        guard !models.isEmpty else { throw ProviderModelsError.noModels }
        return models
    }

    private static func unique(_ models: [String]) throws -> [String] {
        var seen = Set<String>()
        let cleaned = models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !cleaned.isEmpty else { throw ProviderModelsError.noModels }
        return cleaned.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String {
                return message
            }
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(300)
            .description ?? ""
    }
}
