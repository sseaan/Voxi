import AppKit
import SwiftUI

/// 个人词库：术语 + 常见误写。
/// - 术语作为识别提示（OpenAI prompt / 火山热词）；
/// - 常见误写在本地替换成正确写法。
struct LexiconView: View {
    @ObservedObject var settings: SettingsStore
    @State private var query = ""
    @State private var newTerm = ""
    @State private var newAliases = ""
    @State private var notice: String?

    private var allEntries: [LexiconEntry] {
        settings.settings.lexicon.entries
    }

    private var entries: [LexiconEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return allEntries }
        return allEntries.filter { entry in
            entry.term.localizedCaseInsensitiveContains(needle)
                || entry.aliases.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    var body: some View {
        SettingsPage(title: "个人词库") {
            SettingsListCard(
                footer: "术语会作为识别提示；常见误写会在识别完成后自动替换成正确写法。词库只保存在本机。"
            ) {
                HStack(spacing: 8) {
                    searchField
                    Button("导入…") { importFile() }
                        .controlSize(.small)
                    Button("导出…") { exportFile() }
                        .controlSize(.small)
                        .disabled(allEntries.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                SettingsDivider()

                if entries.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            SettingsDivider()
                        }
                        entryRow(entry)
                    }
                }

                SettingsDivider()

                SettingsFieldRow("术语") {
                    lexiconField("例如 Voxi", text: $newTerm)
                        .frame(width: 250)
                }
                SettingsDivider()
                SettingsFieldRow("常见误写", subtitle: "逗号分隔，可留空") {
                    HStack(spacing: 8) {
                        lexiconField("voxy, boxy", text: $newAliases)
                            .frame(minWidth: 110, maxWidth: 160)
                        Button("添加", action: addEntry)
                            .controlSize(.small)
                            .fixedSize()
                            .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            if let notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("搜索术语或误写", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func lexiconField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .onSubmit(addEntry)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text(query.isEmpty
                 ? "还没有词条。添加人名、项目名、常被识别错的词。"
                 : "没有匹配的词条")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func entryRow(_ entry: LexiconEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term)
                    .font(.system(size: 13))
                if !entry.aliases.isEmpty {
                    Text("误写：\(entry.aliases.joined(separator: "、"))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                settings.settings.lexicon.remove(id: entry.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除词条")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func addEntry() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let aliases = newAliases
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map(String.init)
        settings.settings.lexicon.add(term: term, aliases: aliases)
        newTerm = ""
        newAliases = ""
        notice = "已添加到个人词库"
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择文本文件，每行一个词条（术语 或 术语=误写1,误写2）"
        panel.prompt = "导入"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let count = settings.settings.lexicon.importText(content)
        notice = count > 0 ? "已导入 \(count) 个词条" : "没有新的词条可导入"
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Voxi-词库.txt"
        panel.message = "导出个人词库"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = allEntries.map { entry in
            entry.aliases.isEmpty
                ? entry.term
                : "\(entry.term)=\(entry.aliases.joined(separator: ","))"
        }.joined(separator: "\n")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            notice = "已导出：\(url.lastPathComponent)"
        } catch {
            notice = "导出失败：\(error.localizedDescription)"
        }
    }
}
