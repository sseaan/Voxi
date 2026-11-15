import XCTest
@testable import Voxi

@MainActor
final class HistoryStoreTests: XCTestCase {
    private func entry(_ text: String, at date: Date, model: String = "sensevoice") -> HistoryEntry {
        HistoryEntry(
            createdAt: date,
            text: text,
            duration: 2,
            sourceName: "本机",
            model: model,
            providerKind: EndpointProfile.ProviderKind.openAICompatible.rawValue
        )
    }

    func testAddKeepsNewestFirstAndEnforcesLimit() {
        let store = HistoryStore(fileURL: nil)
        let now = Date()
        for index in 0..<5 {
            store.add(
                entry("文本\(index)", at: now.addingTimeInterval(Double(index))),
                maxEntries: 3
            )
        }
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries.map(\.text), ["文本4", "文本3", "文本2"])
    }

    func testEmptyTextIsIgnored() {
        let store = HistoryStore(fileURL: nil)
        store.add(entry("   ", at: Date()), maxEntries: 10)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testQueryFiltersByTextModelAndRange() {
        let store = HistoryStore(fileURL: nil)
        let now = Date()
        let calendar = Calendar.current
        store.add(entry("今天开会纪要", at: now, model: "paraformer-realtime-v2"), maxEntries: 100)
        store.add(entry("昨天的购物清单", at: now.addingTimeInterval(-2 * 86_400)), maxEntries: 100)
        store.add(entry("上周的纪要", at: now.addingTimeInterval(-20 * 86_400)), maxEntries: 100)

        XCTAssertEqual(store.query(HistoryQuery(text: "纪要"), now: now, calendar: calendar).count, 2)
        XCTAssertEqual(
            store.query(HistoryQuery(text: "", modelLabel: "本机 · paraformer-realtime-v2"), now: now, calendar: calendar).count,
            1
        )
        XCTAssertEqual(store.query(HistoryQuery(range: .today), now: now, calendar: calendar).count, 1)
        XCTAssertEqual(store.query(HistoryQuery(range: .week), now: now, calendar: calendar).count, 2)
        XCTAssertEqual(store.query(HistoryQuery(range: .all), now: now, calendar: calendar).count, 3)
    }

    func testModelLabelsAreUnique() {
        let store = HistoryStore(fileURL: nil)
        let now = Date()
        store.add(entry("a", at: now, model: "m1"), maxEntries: 10)
        store.add(entry("b", at: now, model: "m1"), maxEntries: 10)
        store.add(entry("c", at: now, model: "m2"), maxEntries: 10)
        XCTAssertEqual(store.modelLabels, ["本机 · m2", "本机 · m1"])
    }

    func testDeleteAndClear() {
        let store = HistoryStore(fileURL: nil)
        let now = Date()
        let first = entry("a", at: now)
        store.add(first, maxEntries: 10)
        store.add(entry("b", at: now), maxEntries: 10)
        store.delete(id: first.id)
        XCTAssertEqual(store.entries.count, 1)
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxi-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = HistoryStore(fileURL: url)
        store.add(entry("持久化", at: Date()), maxEntries: 10)

        let reloaded = HistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.map(\.text), ["持久化"])

        reloaded.clearAndRemoveFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLegacySettingsWithoutHistoryOrDefaultsEnabled() throws {
        let legacy = #"{"schemaVersion":1,"profiles":[],"recordingMode":"holdToTalk"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(VoxiSettings.self, from: legacy)
        XCTAssertTrue(settings.history.enabled)
        XCTAssertEqual(settings.history.maxEntries, 1_000)
        XCTAssertNil(settings.microphoneUID)
    }

    func testHistorySettingsRoundTrip() throws {
        var settings = VoxiSettings()
        settings.history.enabled = false
        settings.history.maxEntries = 200
        settings.microphoneUID = "device-uid"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(VoxiSettings.self, from: data)
        XCTAssertFalse(decoded.history.enabled)
        XCTAssertEqual(decoded.history.maxEntries, 200)
        XCTAssertEqual(decoded.microphoneUID, "device-uid")
    }
}
