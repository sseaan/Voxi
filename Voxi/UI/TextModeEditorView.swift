import SwiftUI

struct TextModeEditorView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsPage(title: "文本") {
            SettingsListCard(
                "识别",
                footer: "语言只是传给识别服务的提示，实际支持范围由服务决定。"
            ) {
                SettingsFieldRow("识别语言") {
                    Picker("", selection: $settings.settings.textMode.language) {
                        ForEach(TextMode.Language.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsDivider()
                SettingsFieldRow(
                    "保留标点",
                    subtitle: "关闭后只去掉句尾标点，不改动正文。"
                ) {
                    Toggle("", isOn: $settings.settings.textMode.addPunctuation)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsFieldRow("插入后追加") {
                    Picker("", selection: $settings.settings.textMode.newlineBehavior) {
                        ForEach(TextMode.NewlineBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsCard(
                "Prompt",
                footer: "OpenAI-compatible 端点可能忽略 prompt；火山引擎使用个人词库作为热词。Voxi 不会用第二个模型改写结果。"
            ) {
                TextEditor(text: $settings.settings.textMode.prompt)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .frame(height: 84)
                    .padding(8)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                HStack {
                    Text(settings.settings.textMode.prompt.isEmpty ? "可留空" : "\(settings.settings.textMode.prompt.count) 字符")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }

            SettingsCard("预览", footer: "仅演示本地标点、词库替换与换行偏好。") {
                Text(previewText)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    )
            }
        }
    }

    private var previewText: String {
        let sample = settings.settings.textMode.language == .english
            ? "Hello, this is Voxi."
            : "你好，这是 Voxi 的识别结果。"
        let result = settings.settings.textMode.finalize(settings.settings.lexicon.replacing(in: sample))
        return result.isEmpty ? "（空）" : result.replacingOccurrences(of: "\n", with: "⏎")
    }
}
