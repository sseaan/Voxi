import SwiftUI

struct TextModeEditorView: View {
    @ObservedObject var draft: SettingsDraft

    var body: some View {
        SettingsPage(title: "文本") {
            SettingsCard("识别语言", footer: "语言只是传给识别服务的提示，实际支持范围由服务决定。") {
                Picker("语言", selection: $draft.textMode.language) {
                    ForEach(TextMode.Language.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
            }

            SettingsCard(
                "Prompt",
                footer: "OpenAI-compatible 端点可能忽略 prompt；火山引擎流式接口不使用 prompt。Voxi 不会用第二个模型改写结果。"
            ) {
                TextEditor(text: $draft.textMode.prompt)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(height: 96)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12))
                    )
                HStack {
                    Text(draft.textMode.prompt.isEmpty ? "可留空" : "\(draft.textMode.prompt.count) 字符")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            SettingsCard("标点与换行", footer: "关闭标点后只去掉句尾标点，不改动正文。") {
                Toggle("保留标点", isOn: $draft.textMode.addPunctuation)

                SettingsRow("插入后追加") {
                    Picker("", selection: $draft.textMode.newlineBehavior) {
                        ForEach(TextMode.NewlineBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            SettingsCard("预览", footer: "仅演示本地标点与换行偏好，识别内容不会被改写。") {
                Text(previewText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var previewText: String {
        let sample = draft.textMode.language == .english
            ? "Hello, this is Voxi."
            : "你好，这是 Voxi 的识别结果。"
        let result = draft.textMode.finalize(sample)
        return result.isEmpty ? "（空）" : result.replacingOccurrences(of: "\n", with: "⏎")
    }
}
