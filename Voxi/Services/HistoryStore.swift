import Foundation

/// 识别历史存储：本地 JSON 文件，按时间倒序，超过上限时丢弃最旧条目。
///
/// 文本只在用户开启「记录识别历史」时写入；关闭或清空后立即从磁盘删除。
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL?

    /// `fileURL` 为 nil 时只在内存中工作（测试用）。
    init(fileURL: URL? = HistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    /// 默认路径：`~/Library/Application Support/Voxi/history.json`。
    nonisolated static func defaultFileURL() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Voxi", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    // MARK: - 写入

    func add(_ entry: HistoryEntry, maxEntries: Int) {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(entry, at: 0)
        if entries.count > max(maxEntries, 1) {
            entries.removeLast(entries.count - max(maxEntries, 1))
        }
        save()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// 关闭历史记录时调用：清空并删除文件。
    func clearAndRemoveFile() {
        entries = []
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 查询

    func query(_ query: HistoryQuery, now: Date = Date(), calendar: Calendar = .current) -> [HistoryEntry] {
        let keyword = query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let startOfToday = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        var result = entries.filter { entry in
            if !keyword.isEmpty,
               !entry.text.lowercased().contains(keyword),
               !entry.modelLabel.lowercased().contains(keyword) {
                return false
            }
            if let modelLabel = query.modelLabel, entry.modelLabel != modelLabel {
                return false
            }
            switch query.range {
            case .all:
                break
            case .today:
                if entry.createdAt < startOfToday { return false }
            case .week:
                if entry.createdAt < weekStart { return false }
            }
            return true
        }
        if result.count > query.limit {
            result = Array(result.prefix(query.limit))
        }
        return result
    }

    /// 历史里出现过的来源 · 模型，用于筛选菜单。
    var modelLabels: [String] {
        var seen = Set<String>()
        return entries
            .map(\.modelLabel)
            .filter { seen.insert($0).inserted }
    }

    // MARK: - 磁盘

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let stored = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = stored.sorted { $0.createdAt > $1.createdAt }
        } else {
            Logger.settings.error("历史记录解析失败，忽略已有文件")
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.settings.error("历史记录写入失败: \(String(describing: error), privacy: .public)")
        }
    }
}
