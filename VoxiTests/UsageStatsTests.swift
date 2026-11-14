import XCTest
@testable import Voxi

final class UsageStatsTests: XCTestCase {
    func testCharacterCountIgnoresWhitespace() {
        XCTAssertEqual(UsageStats.characterCount("你好 世界\n"), 4)
        XCTAssertEqual(UsageStats.characterCount("hello world"), 10)
        XCTAssertEqual(UsageStats.characterCount("   "), 0)
    }

    func testRecordAndAllRange() {
        var stats = UsageStats()
        stats.record(duration: 60, text: "你好世界")
        stats.record(duration: 30, text: "再见")

        XCTAssertEqual(stats.totalSessions, 2)
        XCTAssertEqual(stats.totalCharacters, 6)
        XCTAssertEqual(stats.totalSeconds, 90, accuracy: 0.001)
        let all = stats.aggregate(for: .all)
        XCTAssertEqual(all.sessions, 2)
        XCTAssertEqual(all.characters, 6)
        XCTAssertEqual(all.averageCharactersPerMinute, 4)
    }

    func testTodayAndWeekRanges() {
        let calendar = Calendar.current
        let now = Date()
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now)!
        var stats = UsageStats()
        stats.record(duration: 60, text: "今天四个字", on: now, calendar: calendar)
        stats.record(duration: 120, text: "前天的字", on: twoDaysAgo, calendar: calendar)

        let today = stats.aggregate(for: .today, now: now, calendar: calendar)
        XCTAssertEqual(today.sessions, 1)
        XCTAssertEqual(today.characters, 5)
        XCTAssertEqual(today.seconds, 60, accuracy: 0.001)

        let week = stats.aggregate(for: .week, now: now, calendar: calendar)
        XCTAssertEqual(week.sessions, 2)
        XCTAssertEqual(week.characters, 9)
        XCTAssertEqual(week.seconds, 180, accuracy: 0.001)

        let points = stats.dailyPoints(lastDays: 7, now: now, calendar: calendar)
        XCTAssertEqual(points.count, 7)
        XCTAssertEqual(points.last?.characters, 5)
        XCTAssertTrue(points.last?.isToday == true)
        XCTAssertEqual(points.first?.characters, 0)
    }

    func testPruneKeepsRecentDays() {
        let calendar = Calendar.current
        let now = Date()
        let old = calendar.date(byAdding: .day, value: -200, to: now)!
        var stats = UsageStats()
        stats.record(duration: 10, text: "旧记录", on: old, calendar: calendar)
        stats.record(duration: 10, text: "新记录", on: now, calendar: calendar)

        XCTAssertEqual(stats.daily.count, 1)
        XCTAssertEqual(stats.totalCharacters, 6)
    }

    func testLegacySettingsDecodeWithoutUsage() throws {
        let encoded = try JSONEncoder().encode(VoxiSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "usage")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VoxiSettings.self, from: data)
        XCTAssertEqual(decoded.usage, UsageStats())
    }

    func testUsageRoundTrip() throws {
        var settings = VoxiSettings()
        settings.usage.record(duration: 12.5, text: "测试文本")
        let decoded = try JSONDecoder().decode(
            VoxiSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.usage, settings.usage)
    }
}
