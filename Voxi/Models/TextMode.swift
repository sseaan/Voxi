import Foundation

/// 文本模式：只影响 ASR 参数，不做第二次模型调用，也不承诺 LLM 改写。
struct TextMode: Codable, Equatable {
    enum Language: String, Codable, CaseIterable, Identifiable {
        case simplifiedChinese
        case english

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .simplifiedChinese: return "简体中文"
            case .english: return "English"
            }
        }

        /// OpenAI-compatible `language` 字段使用的 ISO-639-1 值。
        var iso639Code: String {
            switch self {
            case .simplifiedChinese: return "zh"
            case .english: return "en"
            }
        }

        /// 火山引擎流式识别初始化 JSON 中的 `audio.language`。
        var volcengineLanguage: String {
            switch self {
            case .simplifiedChinese: return "zh-CN"
            case .english: return "en-US"
            }
        }
    }

    /// 换行偏好：不加、结尾一个换行、结尾一个空行。
    enum NewlineBehavior: String, Codable, CaseIterable, Identifiable {
        case none
        case trailingNewline
        case paragraphBreak

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: return "不添加"
            case .trailingNewline: return "结尾换行"
            case .paragraphBreak: return "结尾空行"
            }
        }

        var suffix: String {
            switch self {
            case .none: return ""
            case .trailingNewline: return "\n"
            case .paragraphBreak: return "\n\n"
            }
        }
    }

    var language: Language
    var prompt: String
    var addPunctuation: Bool
    var newlineBehavior: NewlineBehavior

    init(
        language: Language = .simplifiedChinese,
        prompt: String = "",
        addPunctuation: Bool = true,
        newlineBehavior: NewlineBehavior = .none
    ) {
        self.language = language
        self.prompt = prompt
        self.addPunctuation = addPunctuation
        self.newlineBehavior = newlineBehavior
    }

    /// 转写结果在插入前的最终文字处理。仅做本地标点/换行偏好，不改写内容。
    func finalize(_ text: String) -> String {
        var output = text
        if !addPunctuation {
            output = Self.strippingTrailingPunctuation(output)
        }
        if newlineBehavior != .none {
            output = output.trimmingCharacters(in: .whitespacesAndNewlines) + newlineBehavior.suffix
        }
        return output
    }

    /// 去掉句尾的中英文标点（不改动正文内部标点）。
    static func strippingTrailingPunctuation(_ text: String) -> String {
        let punctuation = CharacterSet(charactersIn: "。．，、；：！？,.;:!?")
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, punctuation.contains(last) || CharacterSet.newlines.contains(last) {
            scalars.removeLast()
            // `Trim` 只清句尾，内部标点保持不变。
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
