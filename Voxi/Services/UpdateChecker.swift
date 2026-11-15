import AppKit
import Foundation

/// GitHub Releases 上的一个版本。
struct UpdateRelease: Equatable, Sendable {
    var tag: String
    var version: String
    var title: String?
    var notes: String
    var htmlURL: URL
    var downloadURL: URL?
}

enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: String)
    case available(UpdateRelease)
}

enum UpdateCheckError: LocalizedError, Equatable {
    case network(String)
    case rateLimited
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .network(message):
            return "检查更新失败：\(message)"
        case .rateLimited:
            return "检查更新失败：GitHub API 请求过于频繁，请稍后再试或直接打开 GitHub Releases。"
        case let .httpStatus(status):
            return "检查更新失败：GitHub 返回 HTTP \(status)。"
        case .invalidResponse:
            return "检查更新失败：无法解析 GitHub Releases 响应。"
        }
    }
}

/// 通过 GitHub Releases API 检查新版本。
///
/// 不引入 Sparkle：当前分发是自签名 / ad-hoc 签名且未 notarize，
/// 只要提示版本并引导到发布页下载 DMG 即可。评估见 `docs/sparkle-update-plan.md`。
struct UpdateChecker: Sendable {
    /// 更新的唯一数据源。
    static let repository = "sseaan/Voxi"

    var session: URLSession = .shared
    var currentVersion: String = Bundle.main.shortVersion
    var repository: String = UpdateChecker.repository

    func check() async throws -> UpdateCheckResult {
        let release = try await latestRelease()
        if Self.compareVersions(release.version, currentVersion) > 0 {
            return .available(release)
        }
        return .upToDate(current: currentVersion)
    }

    /// 拉取 `releases/latest`。稳定版标签从 `tag_name` 读取（`v1.2.3`）。
    func latestRelease() async throws -> UpdateRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateCheckError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Voxi/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw UpdateCheckError.network(error.localizedDescription)
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 403, 429:
            throw UpdateCheckError.rateLimited
        default:
            throw UpdateCheckError.httpStatus(http.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let html = object["html_url"] as? String,
              let htmlURL = URL(string: html)
        else {
            throw UpdateCheckError.invalidResponse
        }

        let assets = object["assets"] as? [[String: Any]] ?? []
        let candidates = assets.compactMap { asset -> (String, URL)? in
            guard let name = asset["name"] as? String,
                  let raw = asset["browser_download_url"] as? String,
                  let url = URL(string: raw)
            else { return nil }
            return (name, url)
        }
        let downloadURL = candidates.first { $0.0.lowercased().hasSuffix(".dmg") }?.1
            ?? candidates.first { $0.0.lowercased().hasSuffix(".zip") }?.1

        return UpdateRelease(
            tag: tag,
            version: Self.normalizedVersion(tag),
            title: object["name"] as? String,
            notes: (object["body"] as? String) ?? "",
            htmlURL: htmlURL,
            downloadURL: downloadURL
        )
    }

    /// `v1.2.3-beta` -> `1.2.3-beta`。
    static func normalizedVersion(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        return value
    }

    /// 语义化版本比较：数字段逐位比较，核心相同时稳定版大于预发布版。
    /// 返回值 > 0 表示 `lhs` 更新。
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = parse(lhs)
        let right = parse(rhs)
        let count = max(left.numbers.count, right.numbers.count)
        for index in 0..<count {
            let a = index < left.numbers.count ? left.numbers[index] : 0
            let b = index < right.numbers.count ? right.numbers[index] : 0
            if a != b { return a > b ? 1 : -1 }
        }
        if left.prerelease == right.prerelease { return 0 }
        if left.prerelease.isEmpty { return 1 }
        if right.prerelease.isEmpty { return -1 }
        return left.prerelease > right.prerelease ? 1 : -1
    }

    private static func parse(_ raw: String) -> (numbers: [Int], prerelease: String) {
        let value = normalizedVersion(raw)
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts.first.map(String.init) ?? value
        let prerelease = parts.count > 1 ? String(parts[1]) : ""
        let numbers = core
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        return (numbers, prerelease)
    }
}

/// 检查更新的交互层：菜单项与设置页共用，负责提示与打开链接。
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(UpdateRelease)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private var isChecking = false

    var statusText: String? {
        switch status {
        case .idle, .checking:
            return nil
        case let .upToDate(version):
            return "已是最新版本（\(version)）。"
        case let .available(release):
            return "发现新版本 \(release.version)。"
        case let .failed(message):
            return message
        }
    }

    func checkForUpdates(interactive: Bool = true) async {
        guard !isChecking else { return }
        isChecking = true
        status = .checking
        defer { isChecking = false }

        do {
            let result = try await UpdateChecker().check()
            switch result {
            case let .upToDate(current):
                status = .upToDate(current)
                if interactive {
                    present(
                        title: "已是最新版本",
                        message: "当前版本 \(current) 已是最新。",
                        actions: []
                    )
                }
            case let .available(release):
                status = .available(release)
                if interactive {
                    presentAvailable(release)
                }
            }
        } catch {
            let message = error.localizedDescription
            status = .failed(message)
            if interactive {
                present(
                    title: "检查更新失败",
                    message: message,
                    actions: [
                        AlertAction(title: "打开 GitHub Releases") {
                            if let url = URL(string: "https://github.com/\(UpdateChecker.repository)/releases") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    ]
                )
            }
        }
    }

    func openReleasePage(_ release: UpdateRelease) {
        NSWorkspace.shared.open(release.downloadURL ?? release.htmlURL)
    }

    // MARK: - 提示

    private struct AlertAction {
        let title: String
        let handler: () -> Void
    }

    private func presentAvailable(_ release: UpdateRelease) {
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600))
        var actions: [AlertAction] = []
        if let downloadURL = release.downloadURL {
            actions.append(AlertAction(title: "下载 DMG") { [weak self] in
                NSWorkspace.shared.open(downloadURL)
            })
            actions.append(AlertAction(title: "打开发布页") {
                NSWorkspace.shared.open(release.htmlURL)
            })
        } else {
            actions.append(AlertAction(title: "打开发布页") {
                NSWorkspace.shared.open(release.htmlURL)
            })
        }
        present(
            title: "发现新版本 \(release.version)",
            message: "当前版本 \(Bundle.main.shortVersion)。下载后把 Voxi 拖入“应用程序”覆盖即可。\(detail)",
            actions: actions
        )
    }

    private func present(title: String, message: String, actions: [AlertAction]) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        for action in actions {
            alert.addButton(withTitle: action.title)
        }
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index >= 0, index < actions.count {
            actions[index].handler()
        }
    }
}
