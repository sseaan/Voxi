import Charts
import SwiftUI

/// 设置首页看板：口述统计 + 近 7 天字数 + 模型链/词库概览。
/// 只展示计数，不展示任何转写内容。
struct DashboardView: View {
    @ObservedObject var settings: SettingsStore
    var onRunOnboarding: () -> Void
    var onOpenTab: (SettingsTab) -> Void

    @State private var range: StatsRange = .all
    @State private var now = Date()

    private let columns = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18)
    ]

    private var usage: UsageStats { settings.settings.usage }
    private var aggregate: UsageAggregate { usage.aggregate(for: range, now: now) }
    private var points: [DailyCharacterPoint] { usage.dailyPoints(lastDays: 7, now: now) }
    private var weekCharacters: Int { points.reduce(0) { $0 + $1.characters } }
    private var candidates: [ASRModelCandidate] { settings.settings.asrCandidates }
    private var lexiconCount: Int { settings.settings.lexicon.entries.count }

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider().opacity(0.6)
                metrics
                Divider().opacity(0.6)
                chartSection
                Divider().opacity(0.6)
                infoCards
                footer
            }
            .padding(22)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .onAppear { now = Date() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("出口成文，因境而变")
                    .font(.system(size: 22, weight: .bold))
                HStack(spacing: 5) {
                    Text("按下")
                    Text(settings.settings.shortcut.displayString)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                    Text("开始和停止语音输入")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                if !usage.hasUsage {
                    Text("还没有使用记录，完成第一次口述后会在这里看到统计。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 10) {
                Button("引导") {
                    onRunOnboarding()
                }
                .controlSize(.small)
                HStack(spacing: 5) {
                    Text("统计范围")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Picker("", selection: $range) {
                        ForEach(StatsRange.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - 指标

    private var metrics: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            metric(
                icon: "clock",
                title: "口述时间",
                value: formatDuration(aggregate.seconds),
                unit: nil
            )
            metric(
                icon: "textformat.size",
                title: "口述字数",
                value: groupedNumber(aggregate.characters),
                unit: "字"
            )
            metric(
                icon: "waveform",
                title: "识别次数",
                value: "\(aggregate.sessions)",
                unit: "次"
            )
            metric(
                icon: "speedometer",
                title: "平均口述速度",
                value: "\(aggregate.averageCharactersPerMinute)",
                unit: "字/分钟"
            )
        }
    }

    private func metric(
        icon: String,
        title: String,
        value: String,
        unit: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 折线图

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("近 7 天每日字数")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(groupedNumber(weekCharacters)) 字")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if usage.hasUsage {
                Chart(points) { point in
                    AreaMark(
                        x: .value("日期", point.label),
                        y: .value("字数", point.characters)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("日期", point.label),
                        y: .value("字数", point.characters)
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    PointMark(
                        x: .value("日期", point.label),
                        y: .value("字数", point.characters)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(point.isToday ? 46 : 32)
                }
                .chartYScale(domain: 0...max(1, Double(maxCharacters) * 1.2))
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                            .font(.system(size: 9.5))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: points.map(\.label)) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                            .font(.system(size: 9.5))
                    }
                }
                .frame(height: 150)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 22))
                        .foregroundStyle(.quaternary)
                    Text("还没有口述记录")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
            }
        }
    }

    private var maxCharacters: Int {
        points.map(\.characters).max() ?? 0
    }

    // MARK: - 模型链 / 词库

    private var infoCards: some View {
        HStack(spacing: 12) {
            infoCard(
                icon: "square.stack.3d.up.fill",
                title: "模型链",
                value: primaryModelText,
                detail: modelDetailText,
                actionTitle: "管理模型"
            ) {
                onOpenTab(.endpoints)
            }

            infoCard(
                icon: "character.book.closed.fill",
                title: "个人词库",
                value: "\(lexiconCount)",
                detail: lexiconCount == 0 ? "还没有词条" : "术语与常见误写",
                actionTitle: "管理词库"
            ) {
                onOpenTab(.lexicon)
            }
        }
    }

    private var primaryModelText: String {
        guard let first = candidates.first else { return "未配置" }
        return first.model
    }

    private var modelDetailText: String {
        guard let first = candidates.first else { return "去模型页添加来源" }
        if candidates.count > 1 {
            return "\(first.sourceName) · 共 \(candidates.count) 个模型"
        }
        return first.sourceName
    }

    private func infoCard(
        icon: String,
        title: String,
        value: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Link("更新日志", destination: URL(string: "https://github.com/sseaan/Voxi/releases")!)
            Text("·")
                .foregroundStyle(.tertiary)
            Button("关于") {
                onOpenTab(.about)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Voxi \(Bundle.main.shortVersion)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: - 格式化

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private func groupedNumber(_ value: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        let remainingSeconds = total % 60
        if minutes < 60 {
            return remainingSeconds == 0
                ? "\(minutes) 分"
                : "\(minutes) 分 \(remainingSeconds) 秒"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0
            ? "\(hours) 小时"
            : "\(hours) 小时 \(remainingMinutes) 分"
    }
}
