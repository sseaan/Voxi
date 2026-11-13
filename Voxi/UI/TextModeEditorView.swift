import SwiftUI

struct TextModeEditorView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("识别语言") {
                Picker("语言", selection: $settings.settings.textMode.language) {
                    ForEach(TextMode.Language.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                Text("语言只是传给识别服务的提示；实际支持范围由服务决定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Prompt") {
                TextEditor(text: $settings.settings.textMode.prompt)
                    .font(.callout)
                    .frame(minHeight: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                Text("OpenAI-compatible 端点可能忽略 prompt；火山引擎流式接口不使用 prompt。Voxi 不会用第二个模型改写结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("标点与换行") {
                Toggle("保留标点", isOn: $settings.settings.textMode.addPunctuation)
                Text("关闭后只去掉句尾标点，不改动正文。服务端是否支持标点控制取决于端点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("插入后追加", selection: $settings.settings.textMode.newlineBehavior) {
                    ForEach(TextMode.NewlineBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
            }

            Section("预览") {
                Text(previewText)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .formStyle(.grouped)
    }

    private var previewText: String {
        let sample = settings.settings.textMode.language == .english
            ? "Hello, this is Voxi."
            : "你好，这是 Voxi 的识别结果。"
        let result = settings.settings.textMode.finalize(sample)
        return result.isEmpty ? "（空）" : result.replacingOccurrences(of: "\n", with: "⏎")
    }
}
