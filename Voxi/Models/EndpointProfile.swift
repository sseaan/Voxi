import Foundation

/// 一个语音识别服务端点配置。
///
/// **不变量**：本类型与所有嵌套类型只保存普通配置和 Keychain item 引用，
/// 任何 API Key / Access Key / Authorization 值都只能存在于 Keychain。
struct EndpointProfile: Identifiable, Codable, Equatable {
    enum ProviderKind: String, Codable, CaseIterable, Identifiable {
        case openAICompatible
        case volcengineStreaming

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openAICompatible: return "OpenAI-compatible 转写"
            case .volcengineStreaming: return "火山引擎豆包流式识别"
            }
        }

        var summary: String {
            switch self {
            case .openAICompatible:
                return "录音结束后整段上传到你的 HTTP 端点（multipart）。"
            case .volcengineStreaming:
                return "录音过程中通过 WebSocket 实时发送音频分片，停止后等待最终结果。"
            }
        }
    }

    /// 密钥类配置的引用方式。secret 只能以 `.keychain` 形式出现。
    enum SecretReference: Codable, Equatable {
        case keychain(UUID)
        case literal(String)

        /// 只有非敏感值允许以 `.literal` 写入 UserDefaults。
        var isStoredOutsideKeychain: Bool {
            if case .literal = self { return true }
            return false
        }
    }

    /// 自定义 HTTP header 或 multipart 字段。
    struct HTTPField: Identifiable, Codable, Equatable {
        var id: UUID
        var name: String
        var value: SecretReference
        var isSecret: Bool

        init(id: UUID = UUID(), name: String, value: SecretReference, isSecret: Bool = false) {
            self.id = id
            self.name = name
            self.value = value
            self.isSecret = isSecret
        }
    }

    struct OpenAIOptions: Codable, Equatable {
        enum AuthMode: String, Codable, CaseIterable, Identifiable {
            /// `Authorization: Bearer <key>`
            case bearer
            /// 用户指定的 header 名，值直接使用 Keychain 中的 key。
            case customHeader
            /// 不发送鉴权 header。
            case none

            var id: String { rawValue }

            var displayName: String {
                switch self {
                case .bearer: return "Authorization: Bearer"
                case .customHeader: return "自定义鉴权 header"
                case .none: return "无鉴权"
                }
            }
        }

        enum ResponseFormat: String, Codable, CaseIterable, Identifiable {
            case json
            case text

            var id: String { rawValue }

            var displayName: String {
                switch self {
                case .json: return "JSON（{ \"text\": ... }）"
                case .text: return "纯文本"
                }
            }

            /// multipart 中 `response_format` 的取值。
            var requestValue: String {
                switch self {
                case .json: return "json"
                case .text: return "text"
                }
            }
        }

        var authMode: AuthMode = .bearer
        /// `customHeader` 模式下使用的 header 名，例如 `api-key`。
        var customAuthHeaderName: String = ""
        var model: String = ""
        var responseFormat: ResponseFormat = .json
        var timeoutSeconds: Double = 60
        /// 语言是否作为 multipart 字段发送（部分端点不支持）。
        var sendsLanguageField: Bool = true
        /// prompt 是否作为 multipart 字段发送。
        var sendsPromptField: Bool = true
        var customHeaders: [HTTPField] = []
        var customFormFields: [HTTPField] = []
        /// 仅对 loopback 地址生效：允许明文 HTTP。
        var allowsInsecureLocalHTTP: Bool = false
    }

    struct VolcengineOptions: Codable, Equatable {
        enum AuthMode: String, Codable, CaseIterable, Identifiable {
            /// 新版控制台：单 API Key。
            case apiKey
            /// 旧版控制台：App Key + Access Key。
            case legacy

            var id: String { rawValue }

            var displayName: String {
                switch self {
                case .apiKey: return "API Key（新版控制台）"
                case .legacy: return "App Key + Access Key（旧版控制台）"
                }
            }
        }

        /// 全量结果（每次返回累计文本）或单句结果。
        enum ResultType: String, Codable, CaseIterable, Identifiable {
            case full
            case single

            var id: String { rawValue }
            var displayName: String { self == .full ? "全量结果" : "单句结果" }

            /// 初始化 JSON 中的 `request.result_type`。
            var requestValue: String { rawValue }
        }

        var authMode: AuthMode = .apiKey
        var resourceID: String = "volc.seedasr.sauc.duration"
        /// `request.model_name`。
        var modelName: String = "bigmodel"
        var resultType: ResultType = .full
        /// 是否发送 `X-Api-Sequence`（按所选 v3 接口要求配置）。
        var sendsApiSequenceHeader: Bool = false
    }

    var id: UUID
    var name: String
    var kind: ProviderKind
    /// 用户提供的完整 endpoint URL，provider 不会拼接或替换厂商域名。
    var endpointURL: String
    var openAI: OpenAIOptions
    var volcengine: VolcengineOptions
    /// Keychain 中 API Key 的 item ID（OpenAI key / 火山 API Key）。
    var apiKeyItemID: UUID?
    /// 旧版火山控制台凭据的 Keychain item ID。
    var appKeyItemID: UUID?
    var accessKeyItemID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        endpointURL: String,
        openAI: OpenAIOptions = OpenAIOptions(),
        volcengine: VolcengineOptions = VolcengineOptions(),
        apiKeyItemID: UUID? = nil,
        appKeyItemID: UUID? = nil,
        accessKeyItemID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpointURL = endpointURL
        self.openAI = openAI
        self.volcengine = volcengine
        self.apiKeyItemID = apiKeyItemID
        self.appKeyItemID = appKeyItemID
        self.accessKeyItemID = accessKeyItemID
    }

    // MARK: - 默认配置

    static func defaultOpenAIProfile() -> EndpointProfile {
        var options = OpenAIOptions()
        options.model = "whisper-1"
        return EndpointProfile(
            name: "OpenAI-compatible",
            kind: .openAICompatible,
            endpointURL: "https://api.openai.com/v1/audio/transcriptions",
            openAI: options
        )
    }

    static func defaultVolcengineProfile() -> EndpointProfile {
        EndpointProfile(
            name: "火山引擎豆包",
            kind: .volcengineStreaming,
            endpointURL: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
        )
    }

    // MARK: - 校验

    /// 端点是否指向本机 loopback。
    var isLoopbackEndpoint: Bool {
        guard let host = URLComponents(string: endpointURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
            || host.hasSuffix(".localhost")
    }

    /// 读取某个 secret 引用的类型（不读取真实值）。
    func credentialReference(for kind: CredentialSlot) -> UUID? {
        switch kind {
        case .apiKey: return apiKeyItemID
        case .appKey: return appKeyItemID
        case .accessKey: return accessKeyItemID
        }
    }

    func validation() -> EndpointValidationResult {
        var errors: [EndpointValidationError] = []

        guard let components = URLComponents(string: endpointURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else {
            errors.append(.invalidURL)
            return .init(errors: [.invalidURL])
        }

        switch kind {
        case .openAICompatible:
            if scheme == "http" {
                if !isLoopbackEndpoint || !openAI.allowsInsecureLocalHTTP {
                    errors.append(.insecureRemoteURL)
                }
            } else if scheme != "https" {
                errors.append(.unsupportedScheme(scheme))
            }
            if openAI.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.missingModel)
            }
            if openAI.authMode != .none && apiKeyItemID == nil {
                errors.append(.missingAPIKey)
            }
            if openAI.authMode == .customHeader
                && openAI.customAuthHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.missingAuthHeaderName)
            }
            if openAI.timeoutSeconds <= 0 {
                errors.append(.invalidTimeout)
            }
            for name in openAI.customHeaders.map(\.name) where name
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyCustomFieldName)
            }
            if openAI.customHeaders.contains(where: { $0.name.lowercased() == "content-type" }) {
                errors.append(.reservedHeader("content-type"))
            }
            for name in openAI.customFormFields.map(\.name)
            where name == "file" || name == "boundary" || name == "model" {
                errors.append(.reservedFormField(name))
            }

        case .volcengineStreaming:
            if scheme != "wss" && scheme != "ws" {
                errors.append(.unsupportedScheme(scheme))
            }
            if scheme == "ws" && (!isLoopbackEndpoint) {
                errors.append(.insecureRemoteURL)
            }
            if volcengine.resourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.missingResourceID)
            }
            switch volcengine.authMode {
            case .apiKey:
                if apiKeyItemID == nil { errors.append(.missingAPIKey) }
                if appKeyItemID != nil || accessKeyItemID != nil { errors.append(.mixedCredentialModes) }
            case .legacy:
                if appKeyItemID == nil || accessKeyItemID == nil { errors.append(.missingLegacyCredentials) }
                if apiKeyItemID != nil { errors.append(.mixedCredentialModes) }
            }
        }

        return .init(errors: errors)
    }

    enum CredentialSlot {
        case apiKey
        case appKey
        case accessKey
    }
}

enum EndpointValidationError: Error, Equatable, LocalizedError {
    case invalidURL
    case unsupportedScheme(String)
    case insecureRemoteURL
    case missingModel
    case missingAPIKey
    case missingAuthHeaderName
    case invalidTimeout
    case emptyCustomFieldName
    case reservedHeader(String)
    case reservedFormField(String)
    case missingResourceID
    case missingLegacyCredentials
    case mixedCredentialModes

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "端点 URL 无效，请填写完整地址（含 https:// 或 wss://）。"
        case let .unsupportedScheme(scheme):
            return "不支持的 URL scheme：\(scheme)。请使用 https 或 wss。"
        case .insecureRemoteURL:
            return "远程端点必须使用 HTTPS/WSS；只有本机 loopback 地址才可以在明确允许时使用 HTTP。"
        case .missingModel:
            return "请填写 model。"
        case .missingAPIKey:
            return "请填写 API Key（保存在 Keychain）。"
        case .missingAuthHeaderName:
            return "请填写自定义鉴权 header 名称。"
        case .invalidTimeout:
            return "超时时间必须大于 0 秒。"
        case .emptyCustomFieldName:
            return "自定义 header / 字段名称不能为空。"
        case let .reservedHeader(name):
            return "自定义 header 不能覆盖 \(name)，它由 multipart 请求固定设置。"
        case let .reservedFormField(name):
            return "自定义表单字段不能使用保留字段名 \(name)。"
        case .missingResourceID:
            return "请填写火山引擎 Resource ID（与控制台开通的资源一致）。"
        case .missingLegacyCredentials:
            return "旧版控制台鉴权需要同时填写 App Key 与 Access Key。"
        case .mixedCredentialModes:
            return "API Key 与旧版 App Key/Access Key 不能混用，请只保留一种认证模式。"
        }
    }
}

struct EndpointValidationResult: Equatable {
    var errors: [EndpointValidationError]

    var isValid: Bool { errors.isEmpty }

    var message: String? {
        errors.first?.errorDescription?.appending(errors.count > 1 ? "（共 \(errors.count) 项问题）" : "")
    }
}
