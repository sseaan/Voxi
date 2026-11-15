import AppKit
import SwiftUI

/// 历史记录页：本机识别文本的查询、复制、删除与保留策略。
struct HistoryView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var store = HistoryStore.shared

    @State private var query = HistoryQuery()
    @State private var searchText = ""
    @State private var now = Date()
    @State private var message: String?

    private var history: HistorySettings {
        settings.settings.history
    }

    private var results: [HistoryEntry] {
        var resolved = query
        resolved.text = searchText
        return store.query(resolved, now: now)
    }

    private var modelOptions: [String] {
        store.modelLabels
    }

    var body: some View {
        SettingsPage(title: "历史记录") {
            SettingsListCard(
                "保留策略",
                footer: "识别文本只保存在本机（Application Support/Voxi/history.json）。关闭后不再写入新记录。"
            ) {
                SettingsFieldRow(
                    "记录识别历史",
                    subtitle: "关闭后不会保存新的识别文本"
                ) {
                    Toggle("", isOn: Binding(
                        get: { history.enabled },
                        set: { newValue in
                            if !newValue, !store.entries.isEmpty {
                                confirmDisable()
                            } else {
                                settings.settings.history.enabled = newValue
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
                SettingsDivider()
                SettingsFieldRow("最多保留", subtitle: "超出后自动删除最旧的记录") {
                    Picker("", selection: Binding(
                        get: { history.maxEntries },
                        set: { settings.settings.history.maxEntries = $0 }
                    )) {
                        ForEach(HistorySettings.allowedMaxEntries, id: \.self) { count in
                            Text("\(count) 条").tag(count)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!history.enabled)
                }
                SettingsDivider()
                SettingsFieldRow(
                    "清空历史",
                    subtitle: store.entries.isEmpty ? "暂无记录" : "共 \(store.entries.count) 条"
                ) {
                    Button("清空…") {
                        clearAll()
                    }
                    .controlSize(.small)
                    .disabled(store.entries.isEmpty)
                }
            }

            SettingsListCard(
                "识别记录",
                footer: "共 \(results.count) 条\(results.count == store.entries.count ? "" : "（已筛选）")。右键可复制或删除。"
            ) {
                HStack(spacing: 8) {
                    searchField
                    Picker("", selection: Binding(
                        get: { query.modelLabel ?? "" },
                        set: { query.modelLabel = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("全部模型").tag("")
                        ForEach(modelOptions, id: \.self) { label in
                            Text(label).tag(label)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .disabled(modelOptions.isEmpty)
                    Picker("", selection: Binding(
                        get: { query.range },
                        set: { query.range = $0 }
                    )) {
                        ForEach(HistoryQuery.TimeRange.allCases) { range in
                            Text(range.displayName).tag(range)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                SettingsDivider()

                if store.entries.isEmpty {
                    emptyState
                } else if results.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            SettingsDivider()
                        }
                        entryRow(entry)
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
        }
        .onAppear {
            now = Date()
        }
    }

    // MARK: - 组件

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("搜索识别文本或模型", text: $searchText)
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

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(store.entries.isEmpty ? "还没有识别记录" : "没有匹配的记录")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if store.entries.isEmpty {
                Text("完成一次语音输入后会自动出现在这里")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private func entryRow(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.timestamp.string(from: entry.createdAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(entry.modelLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let styleName = entry.styleName, !styleName.isEmpty {
                    Text(styleName)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(entry.characterCount) 字")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(entry.text, forType: .string)
                    message = "已复制到剪贴板。"
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("复制")
                Button {
                    store.delete(id: entry.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("删除这条记录")
            }
            Text(entry.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button("复制") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.text, forType: .string)
            }
            Button("删除", role: .destructive) {
                store.delete(id: entry.id)
            }
        }
    }

    // MARK: - 操作

    private func confirmDisable() {
        let alert = NSAlert()
        alert.messageText = "关闭历史记录"
        alert.informativeText = "是否同时删除已有的 \(store.entries.count) 条识别历史？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "关闭并删除")
        alert.addButton(withTitle: "关闭并保留")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            settings.settings.history.enabled = false
            store.clearAndRemoveFile()
            message = "历史记录已关闭，已有记录已删除。"
        case .alertSecondButtonReturn:
            settings.settings.history.enabled = false
            message = "历史记录已关闭，已有记录保留在本机。"
        default:
            break
        }
    }

    private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "清空识别历史"
        alert.informativeText = "将删除本机保存的全部 \(store.entries.count) 条记录，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clear()
        message = "历史已清空。"
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
