import Foundation

/// 全部非敏感配置。Codable 模型里 **不能** 出现 API Key、Access Key、Authorization 值。
struct VoxiSettings: Codable, Equatable {
    /// 配置结构版本，用于将来迁移。
    var schemaVersion: Int
    var profiles: [EndpointProfile]
    var activeProfileID: UUID?
    var recordingMode: RecordingMode
    var shortcut: ShortcutConfiguration
    var textMode: TextMode
    var autoInsertEnabled: Bool
    var showInterimTextInMenuBar: Bool
    var lexicon: PersonalLexicon
    /// 转写后的整理风格；nil 表示原文。
    var selectedStyleID: UUID?
    var customStyles: [TranscriptionStyle]
    /// 通用 OpenAI Chat 配置；未配置时风格不生效。
    var languageModel: LanguageModelProfile?

    static let currentSchemaVersion = 1

    init(
        schemaVersion: Int = VoxiSettings.currentSchemaVersion,
        profiles: [EndpointProfile] = VoxiSettings.defaultProfiles(),
        activeProfileID: UUID? = nil,
        recordingMode: RecordingMode = .holdToTalk,
        shortcut: ShortcutConfiguration = .default,
        textMode: TextMode = TextMode(),
        autoInsertEnabled: Bool = true,
        showInterimTextInMenuBar: Bool = true,
        lexicon: PersonalLexicon = PersonalLexicon(),
        selectedStyleID: UUID? = nil,
        customStyles: [TranscriptionStyle] = [],
        languageModel: LanguageModelProfile? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.activeProfileID = activeProfileID ?? profiles.first?.id
        self.recordingMode = recordingMode
        self.shortcut = shortcut
        self.textMode = textMode
        self.autoInsertEnabled = autoInsertEnabled
        self.showInterimTextInMenuBar = showInterimTextInMenuBar
        self.lexicon = lexicon
        self.selectedStyleID = selectedStyleID
        self.customStyles = customStyles
        self.languageModel = languageModel
    }

    /// 默认创建一个 OpenAI-compatible endpoint 示例（尚未填 Key）。
    static func defaultProfiles() -> [EndpointProfile] {
        [.defaultOpenAIProfile()]
    }

    /// 首选模型 = 回退链的第一个。`activeProfileID` 仅用于旧配置迁移。
    var activeProfile: EndpointProfile? {
        profiles.first
    }

    /// 当前选中的整理风格；未选择或已删除时回落到原文。
    var activeStyle: TranscriptionStyle {
        guard let selectedStyleID else { return .raw }
        return TranscriptionStyle.builtIns.first { $0.id == selectedStyleID }
            ?? customStyles.first { $0.id == selectedStyleID }
            ?? .raw
    }

    // MARK: - 迁移

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profiles, activeProfileID, recordingMode, shortcut,
             textMode, autoInsertEnabled, showInterimTextInMenuBar, lexicon,
             selectedStyleID, customStyles, languageModel
    }

    /// 旧配置缺少字段时使用默认值，而不是让整个设置反序列化失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoxiSettings()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        let storedProfiles = try container.decodeIfPresent([EndpointProfile].self, forKey: .profiles) ?? []
        profiles = storedProfiles.isEmpty ? defaults.profiles : storedProfiles
        let storedActive = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        // 旧版本只有一个“当前模型”：迁移时把它放到回退链首位。
        if let storedActive, let index = profiles.firstIndex(where: { $0.id == storedActive }), index > 0 {
            profiles.insert(profiles.remove(at: index), at: 0)
        }
        activeProfileID = profiles.first?.id
        recordingMode = try container.decodeIfPresent(RecordingMode.self, forKey: .recordingMode) ?? .holdToTalk
        shortcut = try container.decodeIfPresent(ShortcutConfiguration.self, forKey: .shortcut) ?? .default
        textMode = try container.decodeIfPresent(TextMode.self, forKey: .textMode) ?? TextMode()
        autoInsertEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoInsertEnabled) ?? true
        showInterimTextInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showInterimTextInMenuBar) ?? true
        lexicon = try container.decodeIfPresent(PersonalLexicon.self, forKey: .lexicon) ?? PersonalLexicon()
        selectedStyleID = try container.decodeIfPresent(UUID.self, forKey: .selectedStyleID)
        customStyles = try container.decodeIfPresent([TranscriptionStyle].self, forKey: .customStyles) ?? []
        languageModel = try container.decodeIfPresent(LanguageModelProfile.self, forKey: .languageModel)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(VoxiSettings.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(profiles, forKey: .profiles)
        try container.encodeIfPresent(activeProfileID, forKey: .activeProfileID)
        try container.encode(recordingMode, forKey: .recordingMode)
        try container.encode(shortcut, forKey: .shortcut)
        try container.encode(textMode, forKey: .textMode)
        try container.encode(autoInsertEnabled, forKey: .autoInsertEnabled)
        try container.encode(showInterimTextInMenuBar, forKey: .showInterimTextInMenuBar)
        try container.encode(lexicon, forKey: .lexicon)
        try container.encodeIfPresent(selectedStyleID, forKey: .selectedStyleID)
        try container.encode(customStyles, forKey: .customStyles)
        try container.encodeIfPresent(languageModel, forKey: .languageModel)
    }
}

/// UserDefaults 持久化。敏感值走 `KeychainService`，这里只存 item 引用。
@MainActor
final class SettingsStore: ObservableObject {
    nonisolated static let storageKey = "com.voxi.settings"

    private let defaults: UserDefaults
    private let storageKey: String

    @Published var settings: VoxiSettings {
        didSet { persist() }
    }

    init(userDefaults: UserDefaults = .standard, storageKey: String = SettingsStore.storageKey) {
        self.defaults = userDefaults
        self.storageKey = storageKey
        self.settings = Self.load(from: userDefaults, storageKey: storageKey)
    }

    var activeProfile: EndpointProfile? {
        settings.activeProfile
    }

    func updateActiveProfile(_ profile: EndpointProfile) {
        if let index = settings.profiles.firstIndex(where: { $0.id == profile.id }) {
            settings.profiles[index] = profile
        } else {
            settings.profiles.append(profile)
        }
        settings.activeProfileID = profile.id
    }

    func addProfile(_ profile: EndpointProfile) {
        settings.profiles.append(profile)
        settings.activeProfileID = profile.id
    }

    func removeProfile(id: UUID) {
        settings.profiles.removeAll { $0.id == id }
        if settings.activeProfileID == id {
            settings.activeProfileID = settings.profiles.first?.id
        }
        if settings.profiles.isEmpty {
            settings.profiles = VoxiSettings.defaultProfiles()
            settings.activeProfileID = settings.profiles.first?.id
        }
    }

    // MARK: - 读写

    nonisolated static func load(from defaults: UserDefaults, storageKey: String = storageKey) -> VoxiSettings {
        guard let data = defaults.data(forKey: storageKey) else {
            return VoxiSettings()
        }
        do {
            return try JSONDecoder().decode(VoxiSettings.self, from: data)
        } catch {
            Logger.settings.error("设置解析失败，使用默认配置: \(String(describing: error), privacy: .public)")
            return VoxiSettings()
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: storageKey)
        } catch {
            Logger.settings.error("设置写入失败: \(String(describing: error), privacy: .public)")
        }
    }
}
