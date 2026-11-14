import XCTest
@testable import Voxi

final class PersonalLexiconTests: XCTestCase {
    func testPromptHintJoinsTerms() {
        let lexicon = PersonalLexicon(entries: [
            LexiconEntry(term: "Voxi"),
            LexiconEntry(term: "  火山引擎  "),
            LexiconEntry(term: "")
        ])
        XCTAssertEqual(lexicon.promptHint, "Voxi、火山引擎")
        XCTAssertNil(PersonalLexicon().promptHint)
    }

    func testHotwordsJSONIsSerializedString() throws {
        let lexicon = PersonalLexicon(entries: [
            LexiconEntry(term: "Voxi", aliases: ["voxy"]),
            LexiconEntry(term: "Sean")
        ])
        let raw = try XCTUnwrap(lexicon.hotwordsJSON)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )
        let words = try XCTUnwrap(object["hotwords"] as? [[String: String]])
        XCTAssertEqual(words.compactMap { $0["word"] }, ["Voxi", "Sean"])
        XCTAssertTrue(raw.contains("\"word\""))
    }

    func testAliasesAreReplacedCaseInsensitivelyAndLongestFirst() {
        let lexicon = PersonalLexicon(entries: [
            LexiconEntry(term: "Voxi", aliases: ["voxy", "boxy"]),
            LexiconEntry(term: "火山引擎", aliases: ["火山引起"])
        ])
        XCTAssertEqual(lexicon.replacing(in: "voxy 和 火山引起"), "Voxi 和 火山引擎")
        XCTAssertEqual(lexicon.replacing(in: "BOXy"), "Voxi")
        XCTAssertEqual(lexicon.replacing(in: "VOXI"), "Voxi", "正确写法本身不参与替换")
    }

    func testAddMergesAliasesAndImportParsesLines() {
        var lexicon = PersonalLexicon()
        lexicon.add(term: "Voxi", aliases: ["voxy"])
        lexicon.add(term: "voxi", aliases: ["boxy", "voxy"])
        XCTAssertEqual(lexicon.entries.count, 1)
        XCTAssertEqual(lexicon.entries[0].aliases, ["voxy", "boxy"])

        let count = lexicon.importText("""
        # comment
        火山引擎=火山引起, 火山应请
        Sean
        """)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(lexicon.entries.count, 3)
        XCTAssertEqual(lexicon.entries[1].term, "火山引擎")
        XCTAssertEqual(lexicon.entries[1].aliases, ["火山引起", "火山应请"])
    }

    func testLexiconSurvivesSettingsRoundTrip() throws {
        var settings = VoxiSettings()
        settings.lexicon.add(term: "Voxi", aliases: ["voxy"])
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(VoxiSettings.self, from: data)
        XCTAssertEqual(decoded.lexicon, settings.lexicon)
    }
}
