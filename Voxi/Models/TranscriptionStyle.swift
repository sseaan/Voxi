import Foundation

/// 语音识别完成后的整理风格。
/// - 内置三种预设 + 「原文」；
/// - 自定义风格只保存名称与提示词，不写死任何模型。
struct TranscriptionStyle: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case raw
        case simple
        case structured
        case formal
        case custom
    }

    var id: UUID
    var kind: Kind
    var name: String
    var detail: String
    var prompt: String
    /// 卡片中展示的效果示例；旧自定义风格没有这个字段。
    var example: String? = nil

    var requiresLLM: Bool { kind != .raw }

    var iconName: String {
        switch kind {
        case .raw: return "text.alignleft"
        case .simple: return "wand.and.stars"
        case .structured: return "list.bullet.rectangle"
        case .formal: return "doc.text"
        case .custom: return "text.quote"
        }
    }

    static let raw = TranscriptionStyle(
        id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
        kind: .raw,
        name: "原文",
        detail: "直接使用识别结果，不调用语言模型。",
        prompt: "",
        example: "呃，那个，我们明天下午三点开个会，然后聊一下新版本上线的事儿。"
    )

    static let simple = TranscriptionStyle(
        id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
        kind: .simple,
        name: "简单整理",
        detail: "补全标点、去掉口头禅，保留原话。",
        prompt: """
        你是一个语音转写整理助手。整理用户提供的语音转写文本：补全标点、按语义分段，删除口头禅、重复词和明显的语气词；保留原意和原有措辞，不要总结，不要添加原文没有的信息。只输出整理后的文本，不要解释。
        """,
        example: "我们明天下午三点开个会，聊一下新版本上线的事。"
    )

    static let structured = TranscriptionStyle(
        id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!,
        kind: .structured,
        name: "清晰结构",
        detail: "按语义分段，要点自动整理成列表。",
        prompt: """
        你是一个语音转写整理助手。将用户提供的语音转写文本整理成清晰的结构：补全标点，按语义分段；如果内容包含多个并列要点，使用以「- 」开头的简洁列表，否则使用自然段落。保留原意和事实，不要添加原文没有的信息。只输出整理后的文本，不要解释。
        """,
        example: "- 时间：明天下午三点\n- 议题：新版本上线计划"
    )

    static let formal = TranscriptionStyle(
        id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000004")!,
        kind: .formal,
        name: "正式表达",
        detail: "改写为正式、专业的书面表达。",
        prompt: """
        你是一个语音转写润色助手。将用户提供的语音转写文本改写为正式、专业、简洁的书面表达：补全标点并分段，去除口语化表达、口头禅和重复；保留事实和原意，不添加新信息，不要总结。只输出改写后的文本，不要解释。
        """,
        example: "拟定于明日十五时召开会议，讨论新版本上线计划。"
    )

    static let builtIns: [TranscriptionStyle] = [.raw, .simple, .structured, .formal]

    static func custom(name: String, prompt: String, id: UUID = UUID()) -> TranscriptionStyle {
        TranscriptionStyle(
            id: id,
            kind: .custom,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: "自定义提示词",
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
