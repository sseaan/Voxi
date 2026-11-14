import Foundation

/// 一次 Rime 词库扫描的条件。
struct RimeLexiconImportOptions: Equatable {
    var directoryURL: URL
    var minimumCommits: Int = RimeLexiconSettings.defaultMinimumCommits
    var includesCustomPhrases: Bool = true
    var maximumTerms: Int = RimeLexiconImporter.defaultMaximumTerms
}

/// 一次 Rime 词库扫描的结果。
struct RimeLexiconImportResult: Equatable {
    var terms: [RimeLexiconTerm] = []
    /// 明确找不到 Rime 用户目录时为 false，界面据此给出路径提示。
    var directoryExists: Bool = true
    /// 读到的原始条目数（含被过滤的），仅用于说明。
    var scannedEntryCount: Int = 0
    var failedSources: [String] = []
    var isTruncated: Bool = false

    var sourceCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for term in terms {
            counts[term.source, default: 0] += 1
        }
        return counts
    }
}

/// 从 Rime 用户目录导入个人词库。
///
/// 支持三类只读来源：
/// 1. `*.userdb` 目录（LevelDB，Rime 正在使用的用户词典）；
/// 2. `*.userdb.txt` 快照（Rime 同步目录或手动导出的用户词典）；
/// 3. `custom_phrase*.txt`（Rime 自定义短语）。
///
/// 只导入「多字词」：单字对语音识别帮助很小，却会挤占 prompt / 热词名额。
/// 词条按来源排序：自定义短语（人工维护）优先，其后按上屏次数从高到低。
enum RimeLexiconImporter {
    static let defaultMaximumTerms = 300
    static let maximumTermLength = 20

    static func importLexicon(options: RimeLexiconImportOptions) -> RimeLexiconImportResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: options.directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return RimeLexiconImportResult(directoryExists: false)
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: options.directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var candidates: [Candidate] = []
        var scannedEntryCount = 0
        var failedSources: [String] = []

        // 1. 正在使用的用户词典（LevelDB）。
        for url in contents
            .filter({ $0.pathExtension == "userdb" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.deletingPathExtension().lastPathComponent
            let pairs = LevelDBReader.keyValues(inDirectory: url)
            if pairs.isEmpty, hasTableOrLogFile(at: url) {
                failedSources.append(name)
                continue
            }
            scannedEntryCount += pairs.count
            for (key, value) in pairs {
                guard !key.hasPrefix("\u{1}") else { continue }  // 元数据键（/db_name 等）
                guard let entry = parseUserDBEntry(key: key, value: value) else { continue }
                guard entry.commits >= options.minimumCommits,
                      shouldInclude(term: entry.term)
                else { continue }
                candidates.append(Candidate(
                    term: entry.term,
                    commits: entry.commits,
                    source: name,
                    isCurated: false,
                    order: candidates.count
                ))
            }
        }

        // 2. 同步 / 导出的用户词典快照。
        for url in userDatabaseSnapshots(in: options.directoryURL, contents: contents) {
            guard let text = readText(url) else {
                failedSources.append(url.lastPathComponent)
                continue
            }
            let name = url.lastPathComponent.replacingOccurrences(of: ".userdb.txt", with: "")
            for entry in parseUserDBSnapshot(text) {
                scannedEntryCount += 1
                guard entry.commits >= options.minimumCommits,
                      shouldInclude(term: entry.term)
                else { continue }
                candidates.append(Candidate(
                    term: entry.term,
                    commits: entry.commits,
                    source: name,
                    isCurated: false,
                    order: candidates.count
                ))
            }
        }

        // 3. 自定义短语。
        if options.includesCustomPhrases {
            for url in contents
                .filter({ $0.pathExtension == "txt" && $0.lastPathComponent.hasPrefix("custom_phrase") })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let text = readText(url) else {
                    failedSources.append(url.lastPathComponent)
                    continue
                }
                for entry in parsePhraseFile(text) {
                    scannedEntryCount += 1
                    guard shouldInclude(term: entry.term) else { continue }
                    candidates.append(Candidate(
                        term: entry.term,
                        commits: entry.weight,
                        source: "自定义短语",
                        isCurated: true,
                        order: candidates.count
                    ))
                }
            }
        }

        let merged = merge(candidates)
        let truncated = merged.count > options.maximumTerms
        let terms = merged
            .prefix(max(0, options.maximumTerms))
            .map { RimeLexiconTerm(term: $0.term, commits: $0.commits, source: $0.source) }

        return RimeLexiconImportResult(
            terms: Array(terms),
            scannedEntryCount: scannedEntryCount,
            failedSources: failedSources,
            isTruncated: truncated
        )
    }

    // MARK: - 解析

    /// 用户词典键：`编码 \t 词条`，值：`c=上屏次数 d=热度 t=tick`。
    /// 统计 / 序列等内部词典的编码含 `/`，需要排除，否则会把用户 ID 当词条导入。
    static func parseUserDBEntry(key: String, value: String) -> (term: String, commits: Int)? {
        guard let separator = key.firstIndex(of: "\t") else { return nil }
        let code = String(key[key.startIndex..<separator])
        let term = String(key[key.index(after: separator)...])
        guard !code.contains("/") else { return nil }
        guard let commits = commits(in: value) else { return nil }
        return (term, commits)
    }

    /// 解析 `c=NN`；找不到时返回 nil，避免把没有使用记录的键当词条。
    static func commits(in value: String) -> Int? {
        for field in value.split(separator: " ") {
            guard field.hasPrefix("c=") else { continue }
            return Int(field.dropFirst(2))
        }
        return nil
    }

    /// `*.userdb.txt` 快照：每行 `编码 \t 词条 \t 值`，注释以 `#` 开头。
    static func parseUserDBSnapshot(_ text: String) -> [(term: String, commits: Int)] {
        var result: [(term: String, commits: Int)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            guard !fields[0].contains("/") else { continue }
            guard let value = commits(in: String(fields[2])) else { continue }
            result.append((String(fields[1]), value))
        }
        return result
    }

    /// `custom_phrase.txt`：每行 `词条 \t 编码 [\t 权重]`。
    static func parsePhraseFile(_ text: String) -> [(term: String, weight: Int)] {
        var result: [(term: String, weight: Int)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let term = String(fields[0])
            let weight = fields.count >= 3 ? Int(fields[2].trimmingCharacters(in: .whitespaces)) ?? 1 : 1
            result.append((term, max(weight, 1)))
        }
        return result
    }

    /// 多字词过滤：单字、纯符号/数字、超长句、含 Rime 转义或控制字符的词条都跳过。
    static func shouldInclude(term raw: String) -> Bool {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2, term.count <= maximumTermLength else { return false }
        guard !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        // `\n`、`\T` 等 Rime 转义与占位符不是实际词条。
        guard !term.contains("\\"), !term.contains("|") else { return false }
        guard term.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return false
        }
        // 纯英文至少 3 个字符，避免 go / ok / 无意义的键盘练习词。
        if term.unicodeScalars.allSatisfy({ $0.isASCII }), term.count < 3 {
            return false
        }
        return true
    }

    // MARK: - 合并

    private struct Candidate {
        var term: String
        var commits: Int
        var source: String
        var isCurated: Bool
        var order: Int
    }

    private static func merge(_ candidates: [Candidate]) -> [Candidate] {
        var best: [String: Candidate] = [:]
        for candidate in candidates {
            let key = candidate.term.lowercased()
            guard var existing = best[key] else {
                best[key] = candidate
                continue
            }
            // 自定义短语优先；同类型保留先出现的一条，只把上屏次数取高值。
            if candidate.isCurated, !existing.isCurated {
                best[key] = candidate
                continue
            } else if candidate.isCurated == existing.isCurated {
                existing.commits = max(existing.commits, candidate.commits)
            }
            best[key] = existing
        }

        return best.values.sorted { left, right in
            if left.isCurated != right.isCurated { return left.isCurated }
            if left.isCurated {
                // 自定义短语：显式权重优先，其次英文/数字专名，再按长度。
                if left.commits != right.commits { return left.commits > right.commits }
                let leftIsName = containsLatin(left.term)
                let rightIsName = containsLatin(right.term)
                if leftIsName != rightIsName { return leftIsName }
                if left.term.count != right.term.count { return left.term.count > right.term.count }
                return left.order < right.order
            }
            if left.commits != right.commits { return left.commits > right.commits }
            return left.order < right.order
        }
    }

    private static func containsLatin(_ term: String) -> Bool {
        term.unicodeScalars.contains { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    // MARK: - 文件

    private static func userDatabaseSnapshots(in directory: URL, contents: [URL]) -> [URL] {
        var urls = contents
            .filter { $0.lastPathComponent.hasSuffix(".userdb.txt") }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

        let syncDirectory = directory.appendingPathComponent("sync", isDirectory: true)
        if let devices = try? FileManager.default.contentsOfDirectory(
            at: syncDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for device in devices.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: device,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                urls.append(contentsOf: files
                    .filter { $0.lastPathComponent.hasSuffix(".userdb.txt") }
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }))
            }
        }
        return urls
    }

    private static func hasTableOrLogFile(at directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.contains { $0.pathExtension == "ldb" || $0.pathExtension == "log" }
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= 32 * 1024 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
