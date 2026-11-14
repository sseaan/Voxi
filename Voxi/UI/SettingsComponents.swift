import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case text
    case endpoints
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .text: return "文本"
        case .endpoints: return "识别服务"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .text: return "textformat"
        case .endpoints: return "antenna.radiowaves.left.and.right"
        case .about: return "info.circle"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .text: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .endpoints: return Color(red: 0.06, green: 0.64, blue: 0.60)
        case .about: return Color(red: 0.42, green: 0.47, blue: 0.55)
        }
    }
}

/// 通用页与文本页的草稿：显式保存，保存后给出时间反馈。
@MainActor
final class SettingsDraft: ObservableObject {
    struct General: Equatable {
        var recordingMode: RecordingMode
        var autoInsertEnabled: Bool
        var showInterimTextInMenuBar: Bool
        var shortcut: ShortcutConfiguration
    }

    @Published var general: General
    @Published var textMode: TextMode
    @Published private(set) var lastSavedAt: Date?

    private var baselineGeneral: General
    private var baselineTextMode: TextMode

    init(settings: VoxiSettings) {
        let general = General(
            recordingMode: settings.recordingMode,
            autoInsertEnabled: settings.autoInsertEnabled,
            showInterimTextInMenuBar: settings.showInterimTextInMenuBar,
            shortcut: settings.shortcut
        )
        self.general = general
        self.textMode = settings.textMode
        self.baselineGeneral = general
        self.baselineTextMode = settings.textMode
    }

    var hasChanges: Bool {
        general != baselineGeneral || textMode != baselineTextMode
    }

    var statusText: String {
        if hasChanges {
            return "有未保存的更改"
        }
        if let lastSavedAt {
            return "已保存 \(Self.timeFormatter.string(from: lastSavedAt))"
        }
        return "修改后点击保存"
    }

    func save(into store: SettingsStore) {
        guard hasChanges else { return }
        store.settings.recordingMode = general.recordingMode
        store.settings.autoInsertEnabled = general.autoInsertEnabled
        store.settings.showInterimTextInMenuBar = general.showInterimTextInMenuBar
        store.settings.shortcut = general.shortcut
        store.settings.textMode = textMode
        baselineGeneral = general
        baselineTextMode = textMode
        lastSavedAt = Date()
    }

    func revert(to settings: VoxiSettings) {
        let general = General(
            recordingMode: settings.recordingMode,
            autoInsertEnabled: settings.autoInsertEnabled,
            showInterimTextInMenuBar: settings.showInterimTextInMenuBar,
            shortcut: settings.shortcut
        )
        self.general = general
        self.textMode = settings.textMode
        baselineGeneral = general
        baselineTextMode = settings.textMode
        lastSavedAt = nil
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// 统一的分组卡片。
struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 左标签、右控件的行，避免 `LabeledContent` 把内容推到窗口两端。
struct SettingsRow<Content: View>: View {
    var label: String
    var caption: String?
    var labelWidth: CGFloat = 104
    @ViewBuilder var content: Content

    init(_ label: String, caption: String? = nil, labelWidth: CGFloat = 104, @ViewBuilder content: () -> Content) {
        self.label = label
        self.caption = caption
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: labelWidth, alignment: .leading)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                content
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct StatusBadge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

/// 设置页内滚动内容的统一容器：限制宽度、统一留白。
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }
}
