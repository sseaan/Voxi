import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case dashboard
    case history
    case general
    case endpoints
    case text
    case lexicon
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "看板"
        case .history: return "历史记录"
        case .general: return "通用"
        case .endpoints: return "模型"
        case .text: return "风格"
        case .lexicon: return "词库"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "rectangle.grid.2x2.fill"
        case .history: return "clock.arrow.circlepath"
        case .general: return "gearshape.fill"
        case .endpoints: return "square.stack.3d.up.fill"
        case .text: return "wand.and.stars"
        case .lexicon: return "character.book.closed.fill"
        case .about: return "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .dashboard: return Color(red: 0.18, green: 0.55, blue: 0.95)
        case .history: return Color(red: 0.36, green: 0.62, blue: 0.55)
        case .general: return Color(red: 0.42, green: 0.48, blue: 0.56)
        case .endpoints: return Color(red: 0.33, green: 0.47, blue: 0.92)
        case .text: return Color(red: 0.64, green: 0.42, blue: 0.94)
        case .lexicon: return Color(red: 0.95, green: 0.61, blue: 0.19)
        case .about: return Color(red: 0.52, green: 0.56, blue: 0.62)
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

/// OpenVoice 风格的设置行：左侧标题/说明，右侧控件，行本身负责 12/9 内边距。
struct SettingsFieldRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 12).opacity(0.6)
    }
}

/// 连续行卡片：行之间用分隔线，内边距由行自己负责（OpenVoice 的 SettingsCard 语义）。
struct SettingsListCard<Content: View>: View {
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
            VStack(spacing: 0) { content }
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
    var title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let title {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .padding(.top, 34)
                }
                content
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, title == nil ? 12 : 0)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }
}


/// 登录时启动开关。失败时回退到系统实际状态并显示原因。
struct LaunchAtLoginToggle: View {
    @State private var enabled = LaunchAtLoginService.isEnabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()

            if let error {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            } else if LaunchAtLoginService.requiresApproval {
                Text("需在系统设置中允许")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            enabled = LaunchAtLoginService.isEnabled
        }
    }

    private func setEnabled(_ value: Bool) {
        error = nil
        do {
            try LaunchAtLoginService.set(value)
            enabled = LaunchAtLoginService.isEnabled
            if value && !LaunchAtLoginService.isEnabled {
                error = "需在系统设置 → 通用 → 登录项中允许"
            }
        } catch {
            enabled = LaunchAtLoginService.isEnabled
            self.error = error.localizedDescription
        }
    }
}
