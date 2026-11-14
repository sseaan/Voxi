import XCTest
@testable import Voxi

final class SettingsStoreTests: XCTestCase {
    private func makeDefaults(suite: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testSettingsRoundTrip() throws {
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.openAI.customHeaders = [
            .init(name: "X-Org", value: .literal("public-org"), isSecret: false)
        ]
        profile.apiKeyItemID = UUID()
        var settings = VoxiSettings(profiles: [profile])
        settings.recordingMode = .toggle
        settings.shortcut = ShortcutConfiguration(keyCode: 0x0F, carbonModifiers: ShortcutConfiguration.Modifier.option.rawValue)
        settings.textMode = TextMode(language: .english, prompt: "hello", addPunctuation: false, newlineBehavior: .trailingNewline)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(VoxiSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.profiles.first?.id, profile.id)
        XCTAssertEqual(decoded.activeProfile?.id, profile.id)
    }

    func testLegacyPayloadMigrationUsesDefaults() throws {
        let legacyJSON = """
        {
          "profiles": [],
          "recordingMode": "toggle"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VoxiSettings.self, from: legacyJSON)

        XCTAssertEqual(decoded.recordingMode, .toggle)
        XCTAssertEqual(decoded.shortcut, .default)
        XCTAssertEqual(decoded.textMode, TextMode())
        XCTAssertTrue(decoded.autoInsertEnabled)
        XCTAssertTrue(decoded.showInterimTextInMenuBar)
        XCTAssertFalse(decoded.profiles.isEmpty, "缺少 profiles 时应回落到默认 profile")
        XCTAssertEqual(decoded.schemaVersion, 0, "旧配置缺少 schemaVersion 时按 0 读取，写出时升级")

        let reencoded = try JSONEncoder().encode(decoded)
        let reloaded = try JSONDecoder().decode(VoxiSettings.self, from: reencoded)
        XCTAssertEqual(reloaded.schemaVersion, VoxiSettings.currentSchemaVersion)
    }

    func testSchemaVersionIsAlwaysWrittenAsCurrent() throws {
        var settings = VoxiSettings()
        settings.schemaVersion = 0
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(VoxiSettings.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, VoxiSettings.currentSchemaVersion)
    }

    @MainActor
    func testPersistenceAcrossStoreInstances() {
        let suite = UUID().uuidString
        let defaults = makeDefaults(suite: suite)
        let key = "test.settings"

        let store = SettingsStore(userDefaults: defaults, storageKey: key)
        store.settings.recordingMode = .toggle
        store.settings.textMode.prompt = "自定义 prompt"
        let profileID = store.settings.profiles[0].id

        let reloaded = SettingsStore(userDefaults: defaults, storageKey: key)
        XCTAssertEqual(reloaded.settings.recordingMode, .toggle)
        XCTAssertEqual(reloaded.settings.textMode.prompt, "自定义 prompt")
        XCTAssertEqual(reloaded.activeProfile?.id, profileID)
    }

    @MainActor
    func testCorruptedSettingsFallBackToDefaults() {
        let suite = UUID().uuidString
        let defaults = makeDefaults(suite: suite)
        let key = "test.settings"
        defaults.set(Data("not json".utf8), forKey: key)

        let store = SettingsStore(userDefaults: defaults, storageKey: key)
        XCTAssertEqual(store.settings.recordingMode, .holdToTalk)
        XCTAssertEqual(store.settings.profiles.count, 1)
    }

    @MainActor
    func testProfileMutationHelpers() {
        let defaults = makeDefaults()
        let store = SettingsStore(userDefaults: defaults, storageKey: "test.settings")
        let original = store.settings.profiles[0]

        var edited = original
        edited.name = "公司内网"
        store.updateActiveProfile(edited)
        XCTAssertEqual(store.activeProfile?.name, "公司内网")
        XCTAssertEqual(store.settings.profiles.count, 1)

        let added = EndpointProfile(
            name: "火山",
            kind: .volcengineStreaming,
            endpointURL: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
        )
        store.addProfile(added)
        XCTAssertEqual(store.settings.profiles.count, 2)
        XCTAssertEqual(store.activeProfile?.id, original.id, "首选模型始终是回退链第一个")
        XCTAssertEqual(store.settings.profiles.last?.id, added.id)

        store.removeProfile(id: added.id)
        XCTAssertEqual(store.settings.profiles.count, 1)
        XCTAssertEqual(store.activeProfile?.id, original.id, "删除当前 profile 后应回落到剩余项")
    }

    @MainActor
    func testEncodedSettingsContainNoSecretValues() throws {
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.apiKeyItemID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        profile.openAI.customHeaders = [
            .init(name: "X-Api-Token", value: .keychain(UUID()), isSecret: true)
        ]
        let defaults = makeDefaults()
        let store = SettingsStore(userDefaults: defaults, storageKey: "test.settings")
        store.addProfile(profile)

        let data = defaults.data(forKey: "test.settings") ?? Data()
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.lowercased().contains("bearer "))
        XCTAssertFalse(json.contains("sk-"))
        XCTAssertTrue(json.contains("11111111-2222-3333-4444-555555555555"))
    }
}

final class TextModeTests: XCTestCase {
    func testLanguageCodes() {
        XCTAssertEqual(TextMode.Language.simplifiedChinese.iso639Code, "zh")
        XCTAssertEqual(TextMode.Language.english.iso639Code, "en")
        XCTAssertEqual(TextMode.Language.simplifiedChinese.volcengineLanguage, "zh-CN")
        XCTAssertEqual(TextMode.Language.english.volcengineLanguage, "en-US")
    }

    func testTrailingPunctuationRemovalKeepsInnerPunctuation() {
        XCTAssertEqual(TextMode.strippingTrailingPunctuation("你好，世界。"), "你好，世界")
        XCTAssertEqual(TextMode.strippingTrailingPunctuation("Hello, world!!"), "Hello, world")
        XCTAssertEqual(TextMode.strippingTrailingPunctuation("a, b. c"), "a, b. c")
    }

    func testFinalizeAppliesNewlinePreference() {
        var mode = TextMode(addPunctuation: true, newlineBehavior: .trailingNewline)
        XCTAssertEqual(mode.finalize("你好。"), "你好。\n")

        mode.newlineBehavior = .paragraphBreak
        XCTAssertEqual(mode.finalize("你好。"), "你好。\n\n")

        mode.newlineBehavior = .none
        mode.addPunctuation = false
        XCTAssertEqual(mode.finalize("你好。"), "你好")
    }
}

final class EndpointProfileValidationTests: XCTestCase {
    func testRemoteHTTPIsRejected() {
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.endpointURL = "http://example.com/v1/audio/transcriptions"
        profile.apiKeyItemID = UUID()
        XCTAssertTrue(profile.validation().errors.contains(.insecureRemoteURL))
    }

    func testLoopbackHTTPRequiresExplicitOptIn() {
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.endpointURL = "http://127.0.0.1:8080/v1/audio/transcriptions"
        profile.apiKeyItemID = UUID()
        XCTAssertTrue(profile.validation().errors.contains(.insecureRemoteURL))

        profile.openAI.allowsInsecureLocalHTTP = true
        XCTAssertTrue(profile.validation().isValid)
    }

    func testLoopbackHTTPSIsValid() {
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.endpointURL = "https://localhost:8443/v1/audio/transcriptions"
        profile.apiKeyItemID = UUID()
        XCTAssertTrue(profile.validation().isValid)
    }

    func testMissingModelAndKey() {
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.openAI.model = "  "
        profile.apiKeyItemID = nil
        let errors = profile.validation().errors
        XCTAssertTrue(errors.contains(.missingModel))
        XCTAssertTrue(errors.contains(.missingAPIKey))
    }

    func testCustomHeaderCannotOverrideContentType() {
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.apiKeyItemID = UUID()
        profile.openAI.customHeaders = [.init(name: "content-type", value: .literal("x/y"))]
        XCTAssertTrue(profile.validation().errors.contains(.reservedHeader("content-type")))
    }

    func testCustomFormFieldCannotOverrideFileOrModel() {
        var profile = EndpointProfile.defaultOpenAIProfile()
        profile.apiKeyItemID = UUID()
        profile.openAI.customFormFields = [.init(name: "file", value: .literal("x"))]
        XCTAssertTrue(profile.validation().errors.contains(.reservedFormField("file")))
    }

    func testVolcengineRequiresWSS() {
        var profile = EndpointProfile.defaultVolcengineProfile()
        profile.apiKeyItemID = UUID()
        profile.endpointURL = "https://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
        XCTAssertTrue(profile.validation().errors.contains(.unsupportedScheme("https")))
    }

    func testVolcengineCredentialModesCannotMix() {
        var profile = EndpointProfile.defaultVolcengineProfile()
        profile.apiKeyItemID = UUID()
        profile.appKeyItemID = UUID()
        profile.accessKeyItemID = UUID()
        XCTAssertTrue(profile.validation().errors.contains(.mixedCredentialModes))
    }

    func testVolcengineLegacyModeNeedsBothKeys() {
        var profile = EndpointProfile.defaultVolcengineProfile()
        profile.volcengine.authMode = .legacy
        profile.appKeyItemID = UUID()
        XCTAssertTrue(profile.validation().errors.contains(.missingLegacyCredentials))

        profile.accessKeyItemID = UUID()
        XCTAssertTrue(profile.validation().isValid)
    }

    func testVolcengineDefaults() {
        let profile = EndpointProfile.defaultVolcengineProfile()
        XCTAssertEqual(profile.volcengine.resourceID, "volc.seedasr.sauc.duration")
        XCTAssertEqual(profile.volcengine.modelName, "bigmodel")
        XCTAssertEqual(profile.volcengine.resultType, .full)
        XCTAssertFalse(profile.volcengine.sendsApiSequenceHeader)
    }

    func testOnboardingFlagDefaultsIncompleteAndLegacySettingsAreComplete() throws {
        XCTAssertFalse(VoxiSettings().hasCompletedOnboarding)

        let encoded = try JSONEncoder().encode(VoxiSettings())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "hasCompletedOnboarding")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(VoxiSettings.self, from: legacyData)
        XCTAssertTrue(legacy.hasCompletedOnboarding, "旧配置升级后不强制重新引导")

        var completed = VoxiSettings()
        completed.hasCompletedOnboarding = true
        let roundTrip = try JSONDecoder().decode(
            VoxiSettings.self,
            from: JSONEncoder().encode(completed)
        )
        XCTAssertTrue(roundTrip.hasCompletedOnboarding)
    }
}
