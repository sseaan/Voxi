import AppKit
import SwiftUI

/// 词库页的 Rime 卡片：只读扫描 Rime 用户目录，把高频多字词导入为识别热词。
/// 不写 Rime 文件，也不参与本地误写替换。
struct RimeLexiconCard: View {
    @ObservedObject var settings: SettingsStore

    @State private var isSyncing = false
    @State private var showsImportedTerms = false
    @State private var notice: String?

    private var terms: [RimeLexiconTerm] {
        settings.settings.lexicon.rimeTerms
    }

    private var rime: RimeLexiconSettings {
        settings.settings.rime
    }

    private var directoryExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: rime.directoryURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private var displayPath: String {
        (rime.directoryURL.path as NSString).abbreviatingWithTildeInPath
    }

    private var sourceSummary: String {
        let counts = Dictionary(grouping: terms, by: \.source).mapValues(\.count)
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
    }

    var body: some View {
        SettingsListCard(
            "Rime 个人词库",
            footer: "只读取 Rime 的用户词典（*.userdb）和自定义短语（custom_phrase*.txt），不会修改 Rime 文件。导入的词条只作为识别提示（OpenAI prompt / 火山热词，最多取前 50 个），不参与本地误写替换。"
        ) {
            header
            SettingsDivider()
            directoryRow
            SettingsDivider()
            minimumCommitsRow
            SettingsDivider()
            customPhraseRow

            if !terms.isEmpty {
                SettingsDivider()
                importedTermsRow
            }

            if let notice {
                SettingsDivider()
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(red: 0.95, green: 0.61, blue: 0.19))
            VStack(alignment: .leading, spacing: 2) {
                Text(terms.isEmpty ? "尚未从 Rime 导入词条" : "已导入 \(terms.count) 个热词")
                    .font(.system(size: 13))
                Text(statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !terms.isEmpty {
                Button("清除") { clearTerms() }
                    .controlSize(.small)
                    .disabled(isSyncing)
                    .help("清除 Rime 热词，保留手动词条")
            }
            Button(action: sync) {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("同步词条")
                }
            }
            .controlSize(.small)
            .disabled(isSyncing || !directoryExists)
            .help(directoryExists ? "重新读取 Rime 词库" : "找不到 Rime 用户目录")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var statusDetail: String {
        if !directoryExists {
            return "找不到 \(displayPath) · 请确认已安装鼠须管（Squirrel）并完成部署"
        }
        guard !terms.isEmpty else {
            return "\(displayPath) · 读取用户词典与自定义短语"
        }
        var parts: [String] = []
        if let lastImportedAt = rime.lastImportedAt {
            parts.append("上次同步 \(Self.syncFormatter.string(from: lastImportedAt))")
        }
        if !sourceSummary.isEmpty {
            parts.append(sourceSummary)
        }
        return parts.isEmpty ? displayPath : parts.joined(separator: " · ")
    }

    private var directoryRow: some View {
        SettingsFieldRow(
            "Rime 目录",
            subtitle: directoryExists ? displayPath : "\(displayPath)（不存在）"
        ) {
            HStack(spacing: 6) {
                Button("选择…") { chooseDirectory() }
                    .controlSize(.small)
                if !rime.isUsingDefaultDirectory {
                    Button("默认") {
                        settings.settings.rime.directoryPath = nil
                        notice = "已恢复默认目录，点击「同步词条」生效。"
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var minimumCommitsRow: some View {
        SettingsFieldRow(
            "最低上屏次数",
            subtitle: "用户词典中上屏达到该值的多字词才会导入；默认 8 次，越低词条越多"
        ) {
            Stepper(value: minimumCommitsBinding, in: RimeLexiconSettings.commitRange) {
                Text("\(rime.minimumCommits) 次")
                    .font(.system(size: 12.5))
                    .frame(minWidth: 38, alignment: .trailing)
            }
            .controlSize(.small)
        }
    }

    private var customPhraseRow: some View {
        SettingsFieldRow(
            "导入自定义短语",
            subtitle: "custom_phrase.txt 中人工维护的单行多字词条"
        ) {
            Toggle("", isOn: includesCustomPhrasesBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private var importedTermsRow: some View {
        DisclosureGroup(isExpanded: $showsImportedTerms) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(terms.prefix(50)) { term in
                    HStack(spacing: 8) {
                        Text(term.term)
                            .font(.system(size: 12))
                        Spacer(minLength: 8)
                        Text("\(term.commits) 次 · \(term.source)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
                if terms.count > 50 {
                    Text("仅显示前 50 个，共 \(terms.count) 个")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("查看导入的热词（\(terms.count)）")
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var minimumCommitsBinding: Binding<Int> {
        Binding(
            get: { settings.settings.rime.minimumCommits },
            set: { value in
                settings.settings.rime.minimumCommits = min(
                    max(value, RimeLexiconSettings.commitRange.lowerBound),
                    RimeLexiconSettings.commitRange.upperBound
                )
                notice = "条件已修改，点击「同步词条」生效。"
            }
        )
    }

    private var includesCustomPhrasesBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.rime.includesCustomPhrases },
            set: { value in
                settings.settings.rime.includesCustomPhrases = value
                notice = "条件已修改，点击「同步词条」生效。"
            }
        )
    }

    // MARK: - 动作

    private func sync() {
        guard !isSyncing else { return }
        let options = RimeLexiconImportOptions(
            directoryURL: rime.directoryURL,
            minimumCommits: rime.minimumCommits,
            includesCustomPhrases: rime.includesCustomPhrases
        )
        isSyncing = true
        notice = nil

        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                RimeLexiconImporter.importLexicon(options: options)
            }.value
            isSyncing = false
            apply(result, options: options)
        }
    }

    private func apply(_ result: RimeLexiconImportResult, options: RimeLexiconImportOptions) {
        guard result.directoryExists else {
            notice = "找不到 Rime 目录：\(options.directoryURL.path)"
            return
        }

        settings.settings.lexicon.replaceRimeTerms(result.terms)
        settings.settings.rime.lastImportedAt = Date()

        guard !result.terms.isEmpty else {
            notice = "没有符合条件的词条。可以降低「最低上屏次数」，或先在 Rime 中输入几次想要的词。"
            return
        }

        var message = "已导入 \(result.terms.count) 个热词"
        if result.scannedEntryCount > 0 {
            message += "（扫描 \(result.scannedEntryCount) 条记录）"
        }
        if result.isTruncated {
            message += "，按上屏次数截取前 \(options.maximumTerms) 个"
        }
        if !result.failedSources.isEmpty {
            message += "；读取失败：\(result.failedSources.joined(separator: "、"))"
        }
        notice = message + "。"
    }

    private func clearTerms() {
        settings.settings.lexicon.replaceRimeTerms([])
        settings.settings.rime.lastImportedAt = nil
        notice = "已清除 Rime 热词；手动词条不受影响。"
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rime.directoryURL
        panel.message = "选择 Rime 用户目录（通常为 ~/Library/Rime）"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.settings.rime.directoryPath = url.path
        notice = "已切换 Rime 目录，点击「同步词条」生效。"
    }

    private static let syncFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
