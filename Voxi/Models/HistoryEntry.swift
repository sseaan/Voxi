import Foundation

/// 一条识别历史。文本只保存在本机（Application Support/Voxi/history.json）。
struct HistoryEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var createdAt: Date
    /// 最终文本（已应用词库替换、标点与风格处理）。
    var text: String
    var duration: TimeInterval
    var sourceName: String
    var model: String
    var providerKind: String
    var styleName: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String,
        duration: TimeInterval,
        sourceName: String,
        model: String,
        providerKind: String,
        styleName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.duration = duration
        self.sourceName = sourceName
        self.model = model
        self.providerKind = providerKind
        self.styleName = styleName
    }

    var characterCount: Int { text.count }

    /// 来源 + 模型，用于列表与筛选。
    var modelLabel: String {
        sourceName.isEmpty ? model : "\(sourceName) · \(model)"
    }
}

/// 历史记录的保留策略。旧配置缺少该字段时按默认值（开启、最多 1000 条）迁移。
struct HistorySettings: Codable, Equatable {
    var enabled: Bool = true
    var maxEntries: Int = 1_000

    static let allowedMaxEntries = [200, 500, 1_000, 2_000, 5_000]
}

/// 历史页筛选条件。
struct HistoryQuery: Equatable {
    enum TimeRange: String, CaseIterable, Identifiable {
        case all
        case today
        case week

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return "全部"
            case .today: return "今天"
            case .week: return "近 7 天"
            }
        }
    }

    var text: String = ""
    var modelLabel: String? = nil
    var range: TimeRange = .all
    var limit: Int = 500
}
