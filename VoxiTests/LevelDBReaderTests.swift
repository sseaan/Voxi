import XCTest
@testable import Voxi

final class LevelDBReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxi-leveldb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDatabase() throws -> URL {
        let url = directory.appendingPathComponent("test.userdb", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testReadsLogWriteBatchAndAppliesDeletes() throws {
        let database = try makeDatabase()
        try LevelDBTestFixture.log([
            ("\u{1}/db_name", "test"),
            ("ni hao \t你好", "c=3 d=1 t=10"),
            ("ni hao \t拟好", "c=1 d=1 t=9")
        ]).write(to: database.appendingPathComponent("000002.log"))
        try LevelDBTestFixture.log([
            ("ni hao \t拟好", nil)
        ]).write(to: database.appendingPathComponent("000003.log"))

        let pairs = LevelDBReader.keyValues(inDirectory: database)

        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs["\u{1}/db_name"], "test")
        XCTAssertEqual(pairs["ni hao \t你好"], "c=3 d=1 t=10")
        XCTAssertNil(pairs["ni hao \t拟好"], "后写入的删除记录应移除旧值")
    }

    func testReadsSSTableAndStripsInternalKeyTrailers() throws {
        let database = try makeDatabase()
        try LevelDBTestFixture.sstable([
            (key: "\u{1}/db_name", value: "test"),
            (key: "ni hao \t你好", value: "c=3 d=1 t=10")
        ]).write(to: database.appendingPathComponent("000005.ldb"))

        let pairs = LevelDBReader.keyValues(inDirectory: database)

        XCTAssertEqual(pairs["\u{1}/db_name"], "test")
        XCTAssertEqual(pairs["ni hao \t你好"], "c=3 d=1 t=10")
        XCTAssertEqual(Set(pairs.keys), ["\u{1}/db_name", "ni hao \t你好"], "8 字节 internal key 尾缀必须被剥离")
    }

    func testReadsCompressedSSTableBlock() throws {
        let database = try makeDatabase()
        try LevelDBTestFixture.sstable(
            [(key: "mo xing \t模型", value: "c=14 d=1 t=3")],
            compressDataBlock: true
        ).write(to: database.appendingPathComponent("000006.ldb"))

        let pairs = LevelDBReader.keyValues(inDirectory: database)

        XCTAssertEqual(pairs["mo xing \t模型"], "c=14 d=1 t=3")
    }

    func testNewerTableTombstoneHidesOlderValue() throws {
        let database = try makeDatabase()
        try LevelDBTestFixture.sstable([
            (key: "旧词", value: "c=9 d=1 t=1")
        ]).write(to: database.appendingPathComponent("000007.ldb"))
        try LevelDBTestFixture.sstable(
            [(key: "旧词", value: "")],
            tombstones: ["旧词"]
        ).write(to: database.appendingPathComponent("000008.ldb"))

        let pairs = LevelDBReader.keyValues(inDirectory: database)

        XCTAssertNil(pairs["旧词"], "新表里的删除标记应移除旧表的值")
    }

    func testLogOverridesTableValue() throws {
        let database = try makeDatabase()
        try LevelDBTestFixture.sstable([
            (key: "ni hao \t你好", value: "c=1 d=1 t=1")
        ]).write(to: database.appendingPathComponent("000009.ldb"))
        try LevelDBTestFixture.log([
            ("ni hao \t你好", "c=5 d=1 t=2")
        ]).write(to: database.appendingPathComponent("000010.log"))

        let pairs = LevelDBReader.keyValues(inDirectory: database)

        XCTAssertEqual(pairs["ni hao \t你好"], "c=5 d=1 t=2")
    }

    func testSnappyDecompressesLiteralAndOverlappingCopy() {
        // 声明长度 10；字面量 "hello"，再从偏移 5 复制 5 字节 → "hellohello"。
        let compressed: [UInt8] = [10, 0x10, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x12, 5, 0]
        XCTAssertEqual(
            LevelDBReader.decompressSnappy(compressed),
            Array("hellohello".utf8)
        )
    }

    func testSnappyRejectsTruncatedInput() {
        XCTAssertNil(LevelDBReader.decompressSnappy([10, 0x10, 0x68]))
        XCTAssertNil(LevelDBReader.decompressSnappy([1, 0x12, 5, 0]))
    }

    func testMissingDirectoryReturnsEmpty() {
        let pairs = LevelDBReader.keyValues(
            inDirectory: directory.appendingPathComponent("does-not-exist")
        )
        XCTAssertTrue(pairs.isEmpty)
    }
}
