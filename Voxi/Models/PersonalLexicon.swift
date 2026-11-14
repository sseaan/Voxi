import Foundation

/// 个人词库中的一条：期望写法 + 常见误听/误写。
struct LexiconEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var term: String
    var aliases: [String]

    init(id: UUID = UUID(), term: String, aliases: [String] = []) {
        self.id = id
        self.term = term
        self.aliases = aliases
    }

    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 个人词库：本地保存，不联网。用于两件事：
/// 1. 作为识别提示（OpenAI-compatible 的 prompt / 火山流式的 corpus.context 热词）；
/// 2. 识别完成后在本地把常见误听替换成正确写法。
struct PersonalLexicon: Codable, Equatable {
    var entries: [LexiconEntry]

    init(entries: [LexiconEntry] = []) {
        self.entries = entries
    }

    var isEmpty: Bool {
        entries.allSatisfy { LexiconEntry.normalized($0.term).isEmpty }
    }

    var promptHint: String? {
        let terms = entries
            .map { LexiconEntry.normalized($0.term) }
            .filter { !$0.isEmpty }
            .prefix(50)
        return terms.isEmpty ? nil : terms.joined(separator: "、")
    }

    /// 火山 `corpus.context` 要求是转义后的 JSON 字符串。
    var hotwordsJSON: String? {
        let words = entries
            .map { LexiconEntry.normalized($0.term) }
            .filter { !$0.isEmpty }
            .prefix(40)
            .map { ["word": $0] }
        guard !words.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["hotwords": words]),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    /// 把常见误听替换成正确写法；长别名优先，避免短词抢先匹配。
    func replacing(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var pairs: [(alias: String, term: String)] = []
        for entry in entries {
            let term = LexiconEntry.normalized(entry.term)
            guard !term.isEmpty else { continue }
            // 术语本身也参与大小写归一（voxi -> Voxi）。
            pairs.append((term, term))
            for alias in entry.aliases {
                let value = LexiconEntry.normalized(alias)
                guard !value.isEmpty, value.caseInsensitiveCompare(term) != .orderedSame else { continue }
                pairs.append((value, term))
            }
        }
        var result = text
        for pair in pairs.sorted(by: { $0.alias.count > $1.alias.count }) {
            result = result.replacingOccurrences(
                of: pair.alias,
                with: pair.term,
                options: [.caseInsensitive]
            )
        }
        return result
    }

    mutating func add(term: String, aliases: [String]) {
        let value = LexiconEntry.normalized(term)
        guard !value.isEmpty else { return }
        let aliasValues = aliases
            .map { LexiconEntry.normalized($0) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(value) != .orderedSame }
        if let index = entries.firstIndex(where: {
            LexiconEntry.normalized($0.term).caseInsensitiveCompare(value) == .orderedSame
        }) {
            var merged = entries[index].aliases
            for alias in aliasValues where !merged.contains(where: {
                $0.caseInsensitiveCompare(alias) == .orderedSame
            }) {
                merged.append(alias)
            }
            entries[index].aliases = merged
        } else {
            entries.append(LexiconEntry(term: value, aliases: aliasValues))
        }
    }

    mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// 每行 `术语` 或 `术语=误听1,误听2`。
    @discardableResult
    mutating func importText(_ content: String) -> Int {
        var added = 0
        for line in content.split(whereSeparator: \.isNewline) {
            let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !raw.hasPrefix("#") else { continue }
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let term = String(parts[0])
            let aliases = parts.count > 1
                ? parts[1].split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
                    .map(String.init)
                : []
            let before = entries.count
            add(term: term, aliases: aliases)
            if entries.count > before { added += 1 }
        }
        return added
    }
}
