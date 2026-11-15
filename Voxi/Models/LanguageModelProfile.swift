import Foundation

/// 通用 OpenAI-compatible Chat Completions 配置，用于转写后的风格整理。
/// 与语音识别端点分开保存；API Key 只存 Keychain item 引用。
struct LanguageModelProfile: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case openAICompatible
        case openCodeGo

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openAICompatible: return "通用 OpenAI"
            case .openCodeGo: return "OpenCode Go"
            }
        }

        var defaultEndpoint: String {
            switch self {
            case .openAICompatible:
                return "https://api.openai.com/v1/chat/completions"
            case .openCodeGo:
                return "https://opencode.ai/inference/go/openai/v1/chat/completions"
            }
        }

        var defaultModel: String {
            switch self {
            case .openAICompatible: return "gpt-4o-mini"
            case .openCodeGo: return "deepseek-v4.1-flash"
            }
        }

        /// Assets.xcassets 中的渠道图标；`nil` 表示使用通用图标。
        var assetName: String? {
            switch self {
            case .openAICompatible: return nil
            case .openCodeGo: return "ChannelOpenCode"
            }
        }
    }

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
    /// 旧配置没有这个字段时按通用 OpenAI 处理。
    var kind: Kind? = nil
    var name: String
    var endpointURL: String
    var model: String
    var authMode: AuthMode
    var apiKeyItemID: UUID?
    var timeoutSeconds: Double
    var temperature: Double
    /// 从 /models 获取并勾选的模型；nil 表示只使用 `model`。
    var enabledModels: [String]? = nil
    /// 渠道预设；旧配置没有该字段时按「通用 OpenAI」处理。
    var vendor: ModelVendor? = nil

    init(
        id: UUID = UUID(),
        kind: Kind = .openAICompatible,
        name: String? = nil,
        endpointURL: String? = nil,
        model: String? = nil,
        authMode: AuthMode = .bearer,
        apiKeyItemID: UUID? = nil,
        timeoutSeconds: Double = 60,
        temperature: Double = 0.3,
        vendor: ModelVendor = .custom
    ) {
        self.id = id
        self.kind = kind
        self.name = name ?? (kind == .openCodeGo ? "OpenCode Go" : "通用 OpenAI")
        self.endpointURL = endpointURL ?? kind.defaultEndpoint
        self.model = model ?? kind.defaultModel
        self.authMode = authMode
        self.apiKeyItemID = apiKeyItemID
        self.timeoutSeconds = timeoutSeconds
        self.temperature = temperature
        self.vendor = vendor
    }

    /// 已启用模型；没有多选时回落到单个 model。
    var effectiveModels: [String] {
        let values = (enabledModels ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !values.isEmpty {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        let manual = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return manual.isEmpty ? [] : [manual]
    }

    var providerKind: Kind { kind ?? .openAICompatible }

    /// 渠道预设（旧配置为自定义）。
    var resolvedVendor: ModelVendor { vendor ?? .custom }

    var providerDisplayName: String { providerKind.displayName }

    static func defaultProfile(for kind: Kind) -> LanguageModelProfile {
        LanguageModelProfile(kind: kind)
    }

    /// 允许填完整 `/chat/completions`，也允许只填到 `/v1`。
    var chatCompletionsURL: URL? {
        if providerKind == .openCodeGo {
            return URL(string: "https://opencode.ai/inference/go/openai/v1/chat/completions")
        }
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

    /// OpenCode Go 的模型列表地址与 Chat 地址不同。
    var modelsURL: URL? {
        if providerKind == .openCodeGo {
            return URL(string: "https://opencode.ai/inference/go/v1/models")
        }
        guard let endpoint = URL(string: endpointURL) else { return nil }
        return ProviderModelsService.modelsURL(from: endpoint)
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
