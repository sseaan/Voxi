import Foundation

/// 明文 HTTP 的主机放行规则。
///
/// Voxi 默认要求 https（火山引擎为 wss）。只有「不经过公网」的地址才允许明文 HTTP，
/// 而且仍要用户在端点页显式打开开关，避免把 Key 与音频明文发到远程主机：
///
/// - loopback：`localhost`、`127.0.0.0/8`、`::1`
/// - 私有网段：`10/8`、`172.16/12`、`192.168/16`、`100.64/10`（CGNAT / Tailscale / EasyTier）、`169.254/16`
/// - IPv6：`fc00::/7`（ULA）、`fe80::/10`（link-local），以及映射到私有网段的 IPv4-mapped 地址
/// - 局域网主机名：`.local`、单标签主机名（如 `raspberrypi`）
///
/// 其余地址（公网 IP、公网域名）一律视为远程端点，http 会被拒绝。
enum LocalHostPolicy {
    /// 严格 loopback：`localhost`、`127.0.0.0/8`、`::1`。
    static func isLoopback(host: String) -> Bool {
        let host = normalize(host)
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if let ipv4 = ipv4Bytes(host) { return ipv4[0] == 127 }
        if let ipv6 = ipv6Bytes(host) {
            return ipv6[0..<15].allSatisfy { $0 == 0 } && ipv6[15] == 1
        }
        return false
    }

    /// 本机或局域网 / 私有网络地址（包含 loopback）。
    ///
    /// EasyTier、Tailscale 这类虚拟局域网用的是私有网段（EasyTier 默认 `10.144.144.0/24`），因此同样命中。
    static func isLocalOrPrivate(host: String) -> Bool {
        let host = normalize(host)
        guard !host.isEmpty else { return false }
        if isLoopback(host: host) { return true }
        if let ipv4 = ipv4Bytes(host) { return isPrivateIPv4(ipv4) }
        if let ipv6 = ipv6Bytes(host) { return isPrivateIPv6(ipv6) }
        // mDNS 名字与内网单标签主机名；公网域名一定带点。
        return host.hasSuffix(".local") || !host.contains(".")
    }

    // MARK: - 解析

    /// 去掉方括号、IPv6 zone id、FQDN 尾点，并统一小写。
    private static func normalize(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if let zone = value.firstIndex(of: "%") {
            value = String(value[value.startIndex..<zone])
        }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        if inet_pton(AF_INET, host, &address) == 1 {
            // s_addr 是网络字节序，内存里第一个字节就是第一段。
            return withUnsafeBytes(of: &address) { Array($0) }
        }
        // 允许 `010.0.0.1` 这类带前导零的写法（inet_pton 不认）。
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let value = UInt16(part), value <= 255 else { return nil }
            bytes.append(UInt8(value))
        }
        return bytes
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    // MARK: - 网段判断

    private static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _),      // RFC1918 10/8
             (127, _),     // loopback
             (192, 168),   // RFC1918 192.168/16
             (169, 254):   // link-local
            return true
        case (172, 16...31),    // RFC1918 172.16/12
             (100, 64...127):   // CGNAT 100.64/10
            return true
        default:
            return false
        }
    }

    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isPrivateIPv4(Array(bytes[12..<16]))
        }
        if (bytes[0] & 0xFE) == 0xFC { return true }                       // fc00::/7 ULA
        return bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80               // fe80::/10 link-local
    }
}
