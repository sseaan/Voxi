import Foundation

enum StyleProcessingError: LocalizedError {
    case missingLanguageModel
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .missingLanguageModel:
            return "尚未配置语言模型。请到「模型」中添加通用 OpenAI 接入。"
        case .emptyResult:
            return "风格处理没有返回文本。"
        }
    }
}

/// 把识别文本按当前风格交给语言模型整理。
/// 语言模型失败时调用方应回退到原文，不丢失识别结果。
enum StyleProcessor {
    static func process(
        text: String,
        settings: VoxiSettings,
        chatService: ChatCompletionService = ChatCompletionService()
    ) async throws -> String {
        let style = settings.activeStyle
        guard style.requiresLLM else { return text }
        guard let profile = settings.languageModel else {
            throw StyleProcessingError.missingLanguageModel
        }
        guard !style.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }
        let output = try await chatService.complete(
            profile: profile,
            systemPrompt: style.prompt,
            userText: text
        )
        let cleaned = ChatCompletionService.cleaning(output)
        guard !cleaned.isEmpty else { throw StyleProcessingError.emptyResult }
        return cleaned
    }
}
