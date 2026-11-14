import Foundation
import Security

enum KeychainError: Error, LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidSecretEncoding
    case accessDenied

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return "Keychain 操作失败（OSStatus \(status)）。"
        case .invalidSecretEncoding:
            return "密钥内容无法编码。"
        case .accessDenied:
            return "Keychain 拒绝访问。请在弹出的系统对话框中输入登录密码并选择“始终允许”，或在设置中重新保存该密钥。"
        }
    }
}

/// Keychain 中 secret 的读写。UserDefaults 只保存 item ID。
final class KeychainService {
    static let shared = KeychainService()

    private let service: String

    init(service: String = "com.voxi.app.credentials") {
        self.service = service
    }

    /// 写入（或覆盖）secret，返回 item ID。
    @discardableResult
    func store(_ secret: String, for itemID: UUID = UUID()) throws -> UUID {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainError.invalidSecretEncoding
        }
        try delete(itemID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: itemID.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            Logger.keychain.error("写入凭据失败 status=\(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
        return itemID
    }

    func secret(for itemID: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: itemID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidSecretEncoding
            }
            return secret
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            Logger.keychain.error("Keychain 访问被拒绝 status=\(status, privacy: .public)")
            throw KeychainError.accessDenied
        default:
            Logger.keychain.error("读取凭据失败 status=\(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func hasSecret(for itemID: UUID) -> Bool {
        (try? secret(for: itemID))?.isEmpty == false
    }

    func delete(_ itemID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: itemID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// provider 读取 secret 的抽象，测试注入内存实现。
protocol SecretResolving {
    func secret(for itemID: UUID) throws -> String
}

struct KeychainSecretResolver: SecretResolving {
    var keychain: KeychainService = .shared

    func secret(for itemID: UUID) throws -> String {
        guard let value = try keychain.secret(for: itemID), !value.isEmpty else {
            throw TranscriptionError.missingCredential
        }
        return value
    }
}

/// 测试/预览用：内存中的 secret 表。
final class InMemorySecretResolver: SecretResolving {
    private var storage: [UUID: String]

    init(_ storage: [UUID: String] = [:]) {
        self.storage = storage
    }

    func set(_ secret: String, for id: UUID) {
        storage[id] = secret
    }

    func secret(for itemID: UUID) throws -> String {
        guard let value = storage[itemID], !value.isEmpty else {
            throw TranscriptionError.missingCredential
        }
        return value
    }
}
