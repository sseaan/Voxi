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

    // MARK: - Rime 热词

    func testRimeTermsJoinPromptAfterManualTermsAndDeduplicate() {
        let lexicon = PersonalLexicon(
            entries: [
                LexiconEntry(term: "Voxi", aliases: ["voxy"]),
                LexiconEntry(term: "火山引擎")
            ],
            rimeTerms: [
                RimeLexiconTerm(term: "模型", commits: 14, source: "rime_ice"),
                RimeLexiconTerm(term: "voxi", commits: 9, source: "rime_ice")
            ]
        )

        XCTAssertEqual(lexicon.promptHint, "Voxi、火山引擎、模型")
        XCTAssertEqual(lexicon.promptTerms.count, 3)
    }

    func testRimeTermsArePromptOnlyAndDoNotReplaceText() {
        let lexicon = PersonalLexicon(
            entries: [LexiconEntry(term: "Voxi", aliases: ["voxy"])],
            rimeTerms: [RimeLexiconTerm(term: "Sean", commits: 4, source: "rime_ice")]
        )

        XCTAssertEqual(lexicon.replacing(in: "voxy 和 sean"), "Voxi 和 sean")
        XCTAssertEqual(lexicon.replacing(in: "模型"), "模型")
    }

    func testHotwordsUseFirstFortyTerms() throws {
        let rimeTerms = (1...45).map {
            RimeLexiconTerm(term: "词\($0)", commits: 1, source: "rime_ice")
        }
        let lexicon = PersonalLexicon(rimeTerms: rimeTerms)
        let raw = try XCTUnwrap(lexicon.hotwordsJSON)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let words = try XCTUnwrap(object["hotwords"] as? [[String: String]])
        XCTAssertEqual(words.count, 40)
        XCTAssertEqual(words.first?["word"], "词1")
        XCTAssertEqual(words.last?["word"], "词40")
    }

    func testLegacyLexiconPayloadWithoutRimeTermsDecodes() throws {
        let legacy = Data(#"{"entries":[{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","term":"Voxi","aliases":["voxy"]}]}"#.utf8)
        let decoded = try JSONDecoder().decode(PersonalLexicon.self, from: legacy)

        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertTrue(decoded.rimeTerms.isEmpty)
    }

    func testRimeTermsSurviveSettingsRoundTrip() throws {
        var settings = VoxiSettings()
        settings.lexicon.replaceRimeTerms([
            RimeLexiconTerm(term: "模型", commits: 14, source: "rime_ice"),
            RimeLexiconTerm(term: "Golang", commits: 1, source: "自定义短语")
        ])
        settings.rime = RimeLexiconSettings(
            directoryPath: "/tmp/rime",
            minimumCommits: 3,
            includesCustomPhrases: false,
            lastImportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let decoded = try JSONDecoder().decode(
            VoxiSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.lexicon.rimeTerms, settings.lexicon.rimeTerms)
        XCTAssertEqual(decoded.rime, settings.rime)
    }
}
