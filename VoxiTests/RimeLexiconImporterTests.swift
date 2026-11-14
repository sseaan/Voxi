import XCTest
@testable import Voxi

final class RimeLexiconImporterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxi-rime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 导入

    func testImportsHighFrequencyMultiCharacterTermsAndCustomPhrases() throws {
        try writeUserDatabase(name: "rime_ice", entries: [
            ("\u{1}/db_name", "rime_ice"),
            ("xian zai \t现在", "c=20 d=1 t=1"),
            ("mo xing \t模型", "c=14 d=1 t=2"),
            ("ba \t吧", "c=9 d=1 t=3"),  // 单字
            ("di ci \t低频", "c=1 d=1 t=4"),  // 低于阈值
            ("statistics/day/1 \tabcdef12", "c=99 d=0 t=0"),  // 统计词典
            ("chang ju \t这是一个非常非常长而且超过长度限制的完整句子", "c=5 d=1 t=5")
        ])
        try writeFile("custom_phrase.txt", content: """
        # Rime table
        有\tu\t3
        Go\tg
        Golang\tgolang
        静夜思\\n床前明月光\\tjy\t5
        """)

        let result = RimeLexiconImporter.importLexicon(options: options())

        XCTAssertEqual(result.terms.map(\.term), ["Golang", "现在", "模型"])
        XCTAssertEqual(result.terms.first?.source, "自定义短语")
        XCTAssertEqual(result.sourceCounts["rime_ice"], 2)
        XCTAssertEqual(result.sourceCounts["自定义短语"], 1)
        XCTAssertTrue(result.failedSources.isEmpty)
        XCTAssertGreaterThan(result.scannedEntryCount, 0)
    }

    func testDefaultThresholdIsEightCommits() throws {
        XCTAssertEqual(RimeLexiconSettings().minimumCommits, 8)
        XCTAssertEqual(RimeLexiconImportOptions(directoryURL: root).minimumCommits, 8)

        try writeUserDatabase(name: "rime_ice", entries: [
            ("qi \t七次", "c=7 d=1 t=1"),
            ("ba \t八次", "c=8 d=1 t=2")
        ])

        let result = RimeLexiconImporter.importLexicon(
            options: RimeLexiconImportOptions(directoryURL: root)
        )

        XCTAssertEqual(result.terms.map(\.term), ["八次"])
    }

    func testMinimumCommitsAndLengthFilter() throws {
        try writeUserDatabase(name: "rime_ice", entries: [
            ("di ci \t低频", "c=1 d=1 t=1"),
            ("ci yu \t词语", "c=2 d=1 t=2"),
            ("dan zi \t字", "c=8 d=1 t=3")
        ])

        let result = RimeLexiconImporter.importLexicon(options: options(minimumCommits: 1))

        XCTAssertEqual(result.terms.map(\.term), ["词语", "低频"])
        XCTAssertTrue(result.terms.allSatisfy { $0.term.count >= 2 })
    }

    func testSnapshotFromSyncDirectoryMergesWithUserDatabase() throws {
        try writeUserDatabase(name: "rime_ice", entries: [
            ("ni hao \t你好", "c=2 d=1 t=1")
        ])
        let sync = root.appendingPathComponent("sync/device", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        try writeFile("sync/device/rime_ice.userdb.txt", content: """
        # Rime user dictionary
        #@/db_name\trime_ice
        ni hao \t你好\tc=4 d=1 t=2
        yu yin \t语音输入\tc=3 d=1 t=3
        di ci \t低频\tc=1 d=1 t=4
        statistics/day/1 \tabcdef12\tc=9 d=0 t=0
        """)

        let result = RimeLexiconImporter.importLexicon(options: options())

        XCTAssertEqual(result.terms.map(\.term), ["你好", "语音输入"])
        let hello = try XCTUnwrap(result.terms.first { $0.term == "你好" })
        XCTAssertEqual(hello.commits, 4, "快照里更高的上屏次数应生效")
        XCTAssertEqual(hello.source, "rime_ice")
    }

    func testCustomPhrasesRankLatinNamesBeforeCommonPhrases() throws {
        try writeUserDatabase(name: "rime_ice", entries: [
            ("mo xing \t模型", "c=20 d=1 t=1")
        ])
        try writeFile("custom_phrase.txt", content: """
        又双叒叕\tuuuu
        Amazon\tamazon
        是一个\tsig
        """)

        let result = RimeLexiconImporter.importLexicon(options: options())

        XCTAssertEqual(result.terms.map(\.term), ["Amazon", "又双叒叕", "是一个", "模型"])
    }

    func testCustomPhrasesCanBeDisabled() throws {
        try writeUserDatabase(name: "rime_ice", entries: [
            ("mo xing \t模型", "c=14 d=1 t=1")
        ])
        try writeFile("custom_phrase.txt", content: "Amazon\tamazon\n")

        let result = RimeLexiconImporter.importLexicon(options: options(includesCustomPhrases: false))

        XCTAssertEqual(result.terms.map(\.term), ["模型"])
    }

    func testMaximumTermsTruncates() throws {
        try writeUserDatabase(name: "rime_ice", entries: [
            ("yi \t词语一", "c=3 d=1 t=1"),
            ("er \t词语二", "c=2 d=1 t=2")
        ])

        var options = options()
        options.maximumTerms = 1
        let result = RimeLexiconImporter.importLexicon(options: options)

        XCTAssertEqual(result.terms.map(\.term), ["词语一"])
        XCTAssertTrue(result.isTruncated)
    }

    func testMissingDirectoryIsReported() {
        let result = RimeLexiconImporter.importLexicon(
            options: RimeLexiconImportOptions(directoryURL: root.appendingPathComponent("missing"))
        )

        XCTAssertFalse(result.directoryExists)
        XCTAssertTrue(result.terms.isEmpty)
    }

    // MARK: - 解析细节

    func testUserDatabaseEntryParsing() {
        let entry = RimeLexiconImporter.parseUserDBEntry(
            key: "mo xing \t模型",
            value: "c=14 d=1.54338 t=992"
        )
        XCTAssertEqual(entry?.term, "模型")
        XCTAssertEqual(entry?.commits, 14)

        XCTAssertNil(RimeLexiconImporter.parseUserDBEntry(key: "no-tab", value: "c=1"))
        XCTAssertNil(RimeLexiconImporter.parseUserDBEntry(key: "statistics/day/1 \tuser", value: "c=9"))
        XCTAssertNil(RimeLexiconImporter.parseUserDBEntry(key: "mo xing \t模型", value: "d=1 t=2"))
    }

    func testTermFilter() {
        XCTAssertTrue(RimeLexiconImporter.shouldInclude(term: "模型"))
        XCTAssertTrue(RimeLexiconImporter.shouldInclude(term: "Golang"))
        XCTAssertTrue(RimeLexiconImporter.shouldInclude(term: "Go程"))
        XCTAssertTrue(RimeLexiconImporter.shouldInclude(term: "sean@example.com"))

        XCTAssertFalse(RimeLexiconImporter.shouldInclude(term: "吧"))
        XCTAssertFalse(RimeLexiconImporter.shouldInclude(term: "go"))
        XCTAssertFalse(RimeLexiconImporter.shouldInclude(term: "12345"))
        XCTAssertFalse(RimeLexiconImporter.shouldInclude(term: "，。！"))
        XCTAssertFalse(RimeLexiconImporter.shouldInclude(term: "静夜思\\n床前明月光"))
        XCTAssertFalse(RimeLexiconImporter.shouldInclude(term: String(repeating: "很", count: 21)))
    }

    func testPhraseFileParsingSkipsCommentsAndReadsWeight() {
        let entries = RimeLexiconImporter.parsePhraseFile("""
        # comment
        Amazon\tamazon\t5
        Voxi\tvoxi
        没有编码
        """)

        XCTAssertEqual(entries.map(\.term), ["Amazon", "Voxi"])
        XCTAssertEqual(entries.first?.weight, 5)
        XCTAssertEqual(entries.last?.weight, 1)
    }

    // MARK: - 辅助

    private func options(
        minimumCommits: Int = 2,
        includesCustomPhrases: Bool = true
    ) -> RimeLexiconImportOptions {
        RimeLexiconImportOptions(
            directoryURL: root,
            minimumCommits: minimumCommits,
            includesCustomPhrases: includesCustomPhrases
        )
    }

    private func writeUserDatabase(name: String, entries: [(String, String)]) throws {
        let database = root.appendingPathComponent("\(name).userdb", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let log = LevelDBTestFixture.log(entries.map { (key: $0.0, value: $0.1) })
        try log.write(to: database.appendingPathComponent("000001.log"))
    }

    private func writeFile(_ relativePath: String, content: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
