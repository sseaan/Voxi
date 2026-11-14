import Foundation

/// 从 Rime 个人词库导入的一条热词。
/// 只作为识别提示（OpenAI prompt / 火山热词），不参与本地误写替换。
struct RimeLexiconTerm: Identifiable, Codable, Equatable, Hashable {
    /// 词条本身，例如「模型」「Golang」。
    var term: String
    /// 在 Rime 用户词典中的上屏次数；自定义短语使用文件里的权重。
    var commits: Int
    /// 来源：用户词典名（如 `rime_ice`）或「自定义短语」。
    var source: String

    var id: String { term }
}

/// Rime 导入设置：只保存本机路径与筛选条件，不联网、不写 Rime 文件。
struct RimeLexiconSettings: Codable, Equatable {
    static let defaultMinimumCommits = 8
    static let commitRange = 1...20

    /// 自定义 Rime 用户目录；nil 表示默认的 `~/Library/Rime`。
    var directoryPath: String?
    /// 用户词典里上屏次数达到该值的多字词才会导入。
    var minimumCommits: Int
    /// 是否导入 `custom_phrase*.txt`。
    var includesCustomPhrases: Bool
    /// 上次同步时间；仅用于界面展示。
    var lastImportedAt: Date?

    init(
        directoryPath: String? = nil,
        minimumCommits: Int = RimeLexiconSettings.defaultMinimumCommits,
        includesCustomPhrases: Bool = true,
        lastImportedAt: Date? = nil
    ) {
        self.directoryPath = directoryPath
        self.minimumCommits = minimumCommits
        self.includesCustomPhrases = includesCustomPhrases
        self.lastImportedAt = lastImportedAt
    }

    /// 实际扫描的目录。
    var directoryURL: URL {
        if let directoryPath, !directoryPath.isEmpty {
            return URL(fileURLWithPath: directoryPath, isDirectory: true)
        }
        return Self.defaultDirectoryURL
    }

    var isUsingDefaultDirectory: Bool {
        directoryPath?.isEmpty ?? true
    }

    static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Rime", isDirectory: true)
    }

    private enum CodingKeys: String, CodingKey {
        case directoryPath, minimumCommits, includesCustomPhrases, lastImportedAt
    }

    /// 旧配置没有 rime 字段时使用默认值；阈值越界时收敛到合法范围。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directoryPath = try container.decodeIfPresent(String.self, forKey: .directoryPath)
        let storedCommits = try container.decodeIfPresent(Int.self, forKey: .minimumCommits)
            ?? Self.defaultMinimumCommits
        minimumCommits = min(max(storedCommits, Self.commitRange.lowerBound), Self.commitRange.upperBound)
        includesCustomPhrases = try container.decodeIfPresent(Bool.self, forKey: .includesCustomPhrases) ?? true
        lastImportedAt = try container.decodeIfPresent(Date.self, forKey: .lastImportedAt)
    }
}
