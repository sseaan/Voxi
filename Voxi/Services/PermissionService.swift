import AppKit
import AVFoundation
import ApplicationServices
import Foundation

/// 麦克风授权状态（与 AVFoundation 解耦，便于测试与展示）。
enum MicrophoneAuthorization: String, Equatable {
    case notDetermined
    case granted
    case denied
    case restricted

    var isUsable: Bool { self == .granted }

    var displayName: String {
        switch self {
        case .notDetermined: return "尚未请求"
        case .granted: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受系统限制"
        }
    }
}

/// 权限来源抽象。生产实现调用 AVFoundation / Accessibility，测试注入假实现。
protocol AudioPermissionProviding {
    var microphoneAuthorization: MicrophoneAuthorization { get }
    /// 首次调用会弹出系统麦克风授权框；已决定时直接返回结果，不重复弹窗。
    func requestMicrophoneAccess() async -> Bool
}

/// 系统实现。
final class SystemAudioPermissionProvider: AudioPermissionProviding {
    var microphoneAuthorization: MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestMicrophoneAccess() async -> Bool {
        switch microphoneAuthorization {
        case .granted:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }
}

/// 权限状态与系统设置跳转。只读查询，不主动弹窗。
@MainActor
final class PermissionService: ObservableObject {
    @Published private(set) var microphoneAuthorization: MicrophoneAuthorization
    @Published private(set) var accessibilityTrusted: Bool

    private let audioPermissions: AudioPermissionProviding

    init(audioPermissions: AudioPermissionProviding = SystemAudioPermissionProvider()) {
        self.audioPermissions = audioPermissions
        self.microphoneAuthorization = audioPermissions.microphoneAuthorization
        self.accessibilityTrusted = AXIsProcessTrusted()
    }

    func refresh() {
        microphoneAuthorization = audioPermissions.microphoneAuthorization
        accessibilityTrusted = AXIsProcessTrusted()
    }

    /// 首次调用会弹系统麦克风授权框；已决定时直接返回结果。
    @discardableResult
    func requestMicrophoneAccess() async -> Bool {
        let granted = await audioPermissions.requestMicrophoneAccess()
        refresh()
        return granted
    }

    /// 辅助功能是否已授权（自动输入需要）。
    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 弹出系统辅助功能授权引导（系统只会在第一次显示列表项）。
    @discardableResult
    func promptAccessibilityAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityTrusted = trusted
        return trusted
    }

    // MARK: - 系统设置跳转

    enum SettingsPane {
        case microphone
        case accessibility

        var url: URL {
            switch self {
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            }
        }
    }

    static func openSettingsPane(_ pane: SettingsPane) {
        NSWorkspace.shared.open(pane.url)
    }
}

/// 协调器使用的权限网关：把“请求 + 结果”收敛成一个布尔值。
protocol MicrophoneAccessGating {
    var authorization: MicrophoneAuthorization { get }
    func ensureAccess() async -> Bool
}

extension SystemAudioPermissionProvider: MicrophoneAccessGating {
    var authorization: MicrophoneAuthorization { microphoneAuthorization }

    func ensureAccess() async -> Bool {
        await requestMicrophoneAccess()
    }
}

/// 测试用的固定权限。`delayNanoseconds` 用于模拟系统弹窗耗时。
struct StubMicrophoneGate: MicrophoneAccessGating {
    var authorization: MicrophoneAuthorization
    var grants: Bool
    var delayNanoseconds: UInt64 = 0

    func ensureAccess() async -> Bool {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return grants
    }
}
