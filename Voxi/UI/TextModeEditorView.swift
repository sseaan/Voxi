import SwiftUI

/// 风格页：选择识别完成后的整理方式，或添加自定义提示词。
struct TextModeEditorView: View {
    @ObservedObject var settings: SettingsStore
    var onOpenModels: () -> Void = {}

    @State private var showingCustomSheet = false
    @State private var pendingDelete: TranscriptionStyle?

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var selectedStyleID: UUID? {
        settings.settings.selectedStyleID
    }

    private var activeStyle: TranscriptionStyle {
        settings.settings.activeStyle
    }

    var body: some View {
        SettingsPage(title: "风格") {
            SettingsCard(
                "转写风格",
                footer: "风格指令由语言模型执行；语音识别模型只负责转写。选择「原文」则直接使用识别结果。"
            ) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(TranscriptionStyle.builtIns) { style in
                        styleCard(style)
                    }
                }
            }

            customSection

            if settings.settings.languageModel == nil, activeStyle.requiresLLM {
                SettingsCard {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12))
                        Text("尚未配置语言模型，所选风格不会生效。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("去配置") {
                            onOpenModels()
                        }
                        .controlSize(.small)
                    }
                }
            }

            SettingsListCard(
                "识别与输出",
                footer: "这些选项只影响识别提示和插入格式；语言模型的整理内容由上面的风格决定。"
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
                SettingsDivider()
                SettingsFieldRow(
                    "识别提示",
                    subtitle: "可选；作为语音识别提示，不参与风格整理。"
                ) {
                    TextField("例如：会议记录、产品名", text: $settings.settings.textMode.prompt)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }
        }
        .sheet(isPresented: $showingCustomSheet) {
            CustomStyleSheet { name, prompt in
                let style = TranscriptionStyle.custom(name: name, prompt: prompt)
                settings.settings.customStyles.append(style)
                settings.settings.selectedStyleID = style.id
            }
        }
        .confirmationDialog(
            "删除这个自定义提示词？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { style in
            Button("删除", role: .destructive) {
                if settings.settings.selectedStyleID == style.id {
                    settings.settings.selectedStyleID = nil
                }
                settings.settings.customStyles.removeAll { $0.id == style.id }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { style in
            Text("将移除「\(style.name)」。")
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("自定义提示词")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingCustomSheet = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("添加自定义提示词")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)

            if settings.settings.customStyles.isEmpty {
                Text("还没有自定义提示词。点击右上角 + 添加，例如「会议纪要」「字幕断句」。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                Color.primary.opacity(0.08),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                    )
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(settings.settings.customStyles) { style in
                        styleCard(style)
                    }
                }
            }
        }
    }

    private func styleCard(_ style: TranscriptionStyle) -> some View {
        let selected = style.kind == .raw
            ? (selectedStyleID == nil || selectedStyleID == style.id)
            : selectedStyleID == style.id
        let isCustom = style.kind == .custom

        return HStack(alignment: .top, spacing: 4) {
            Button {
                settings.settings.selectedStyleID = style.kind == .raw ? nil : style.id
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: style.iconName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                        Text(style.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isCustom ? "提示词" : "效果示例")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(isCustom ? style.prompt : (style.example ?? style.detail))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.primary.opacity(0.82))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isCustom {
                Button {
                    pendingDelete = style
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("删除提示词")
                .padding(.top, 11)
                .padding(.trailing, 9)
            }
        }
        .background(
            selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.07),
                    lineWidth: selected ? 1.5 : 1
                )
        )
    }
}

private struct CustomStyleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String) -> Void
    @State private var name = ""
    @State private var prompt = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加自定义提示词")
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("名称")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("例如：会议纪要", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("提示词")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $prompt)
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        .frame(height: 130)
                    if prompt.isEmpty {
                        Text("例如：把内容整理成三条以内的要点，保留数字和专有名词，只输出结果。")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
            }

            Text("提示词会作为系统指令发送给语言模型；语音识别模型只负责转写。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(name, prompt)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}
