import Foundation

/// OpenAI 兼容渠道预设：只影响默认 Endpoint / model 与展示图标，不改变协议。
///
/// 这些渠道都提供通用 `/chat/completions` 且不需要额外自定义鉴权 header
/// （MiMo 的 ASR 端点使用 `api-key`，但语言模型走标准 Bearer）。
enum ModelVendor: String, Codable, CaseIterable, Identifiable {
    case custom
    case deepSeek
    case miniMax
    case miMo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .custom: return "通用 OpenAI"
        case .deepSeek: return "DeepSeek"
        case .miniMax: return "MiniMax"
        case .miMo: return "小米 MiMo"
        }
    }

    var subtitle: String {
        switch self {
        case .custom: return "Chat Completions"
        case .deepSeek: return "deepseek-flash / deepseek-v4-pro"
        case .miniMax: return "MiniMax-M3.1-Flash"
        case .miMo: return "mimo-v2.6-pro"
        }
    }

    /// Endpoint 预填值（仍可手动修改）。
    var defaultEndpoint: String {
        switch self {
        case .custom: return "https://api.openai.com/v1/chat/completions"
        case .deepSeek: return "https://api.deepseek.com/chat/completions"
        case .miniMax: return "https://api.minimax.cn/v1/chat/completions"
        case .miMo: return "https://api.xiaomimimo.com/v1/chat/completions"
        }
    }

    var defaultModel: String {
        switch self {
        case .custom: return "gpt-4o-mini"
        case .deepSeek: return "deepseek-flash"
        case .miniMax: return "MiniMax-M3.1-Flash"
        case .miMo: return "mimo-v2.6-pro"
        }
    }

    /// Assets.xcassets 中的渠道图标；`nil` 表示使用通用图标。
    var assetName: String? {
        switch self {
        case .custom: return nil
        case .deepSeek: return "ChannelDeepSeek"
        case .miniMax: return "ChannelMiniMax"
        case .miMo: return "ChannelMiMo"
        }
    }
}
