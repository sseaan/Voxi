import Foundation

/// 单日用量。只保存计数，不保存任何转写内容。
struct UsageDay: Codable, Equatable {
    var seconds: Double = 0
    var characters: Int = 0
    var sessions: Int = 0
}

/// 本地看板统计：总时长、字数、次数 + 每日字数。
/// 不记录历史文本、音频或模型输入。
struct UsageStats: Codable, Equatable {
    var totalSeconds: Double = 0
    var totalCharacters: Int = 0
    var totalSessions: Int = 0
    var daily: [String: UsageDay] = [:]

    var hasUsage: Bool { totalSessions > 0 }

    /// 统计口径：非空白字符数。中文按字、英文按字符计。
    static func characterCount(_ text: String) -> Int {
        text.reduce(0) { count, character in
            character.isWhitespace ? count : count + 1
        }
    }

    mutating func record(
        duration: TimeInterval,
        text: String,
        on date: Date = Date(),
        calendar: Calendar = .current
    ) {
        let characters = Self.characterCount(text)
        guard characters > 0 else { return }

        let seconds = max(0, duration)
        totalSeconds += seconds
        totalCharacters += characters
        totalSessions += 1

        let key = Self.dayKey(for: date, calendar: calendar)
        var day = daily[key] ?? UsageDay()
        day.seconds += seconds
        day.characters += characters
        day.sessions += 1
        daily[key] = day

        prune(keepingDays: 120, now: Date(), calendar: calendar)
    }

    func aggregate(
        for range: StatsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageAggregate {
        switch range {
        case .all:
            return UsageAggregate(
                seconds: totalSeconds,
                characters: totalCharacters,
                sessions: totalSessions
            )
        case .today:
            let day = daily[Self.dayKey(for: now, calendar: calendar)] ?? UsageDay()
            return UsageAggregate(
                seconds: day.seconds,
                characters: day.characters,
                sessions: day.sessions
            )
        case .week:
            var aggregate = UsageAggregate()
            for date in Self.lastDays(7, now: now, calendar: calendar) {
                let day = daily[Self.dayKey(for: date, calendar: calendar)] ?? UsageDay()
                aggregate.seconds += day.seconds
                aggregate.characters += day.characters
                aggregate.sessions += day.sessions
            }
            return aggregate
        }
    }

    /// 最近 N 天（从旧到新），用于折线图。
    func dailyPoints(
        lastDays: Int = 7,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyCharacterPoint] {
        Self.lastDays(lastDays, now: now, calendar: calendar).map { date in
            let key = Self.dayKey(for: date, calendar: calendar)
            return DailyCharacterPoint(
                date: date,
                label: Self.weekdayLabel(for: date, calendar: calendar),
                characters: daily[key]?.characters ?? 0,
                isToday: calendar.isDate(date, inSameDayAs: now)
            )
        }
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func lastDays(
        _ count: Int,
        now: Date,
        calendar: Calendar
    ) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(1, count)).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
        }
    }

    private static func weekdayLabel(for date: Date, calendar: Calendar) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let index = calendar.component(.weekday, from: date) - 1
        return names.indices.contains(index) ? names[index] : ""
    }

    private mutating func prune(
        keepingDays: Int,
        now: Date,
        calendar: Calendar
    ) {
        let keep = Set(
            Self.lastDays(keepingDays, now: now, calendar: calendar)
                .map { Self.dayKey(for: $0, calendar: calendar) }
        )
        daily = daily.filter { keep.contains($0.key) }
    }
}

struct UsageAggregate: Equatable {
    var seconds: Double = 0
    var characters: Int = 0
    var sessions: Int = 0

    var averageCharactersPerMinute: Int {
        guard seconds > 0 else { return 0 }
        return Int((Double(characters) / (seconds / 60)).rounded())
    }
}

struct DailyCharacterPoint: Identifiable, Equatable {
    var date: Date
    var label: String
    var characters: Int
    var isToday: Bool

    var id: Date { date }
}

enum StatsRange: String, CaseIterable, Identifiable {
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
