import XCTest
@testable import Voxi

final class LocalHostPolicyTests: XCTestCase {
    func testLoopbackHosts() {
        for host in ["localhost", "LOCALHOST", "api.localhost", "127.0.0.1", "127.8.9.10", "::1", "[::1]"] {
            XCTAssertTrue(LocalHostPolicy.isLoopback(host: host), host)
            XCTAssertTrue(LocalHostPolicy.isLocalOrPrivate(host: host), host)
        }
    }

    func testNonLoopbackHosts() {
        for host in ["10.144.144.4", "192.168.1.10", "172.16.0.5", "example.com", "pi.local", "raspberrypi", "::2"] {
            XCTAssertFalse(LocalHostPolicy.isLoopback(host: host), host)
        }
    }

    func testPrivateAndLocalHosts() {
        for host in [
            "10.144.144.4",          // EasyTier 默认网段
            "10.0.0.1",
            "172.16.0.1",
            "172.31.255.254",
            "192.168.1.10",
            "100.64.0.7",            // CGNAT / Tailscale
            "100.127.255.1",
            "169.254.10.2",          // link-local
            "010.0.0.1",             // 带前导零
            "fd00::1",               // ULA
            "fc12::abcd",
            "fe80::1",               // link-local
            "fe80::1%en0",
            "::ffff:10.144.144.4",   // IPv4-mapped
            "pi.local",
            "raspberrypi"            // 单标签主机名
        ] {
            XCTAssertTrue(LocalHostPolicy.isLocalOrPrivate(host: host), host)
        }
    }

    func testPublicHostsAreNotLocal() {
        for host in [
            "8.8.8.8",
            "1.1.1.1",
            "172.32.0.1",            // 紧邻 RFC1918 172.16/12 之外
            "100.128.0.1",           // 紧邻 CGNAT 100.64/10 之外
            "169.253.0.1",
            "192.169.0.1",
            "example.com",
            "nas.lan.example.",      // 远程域名即使带尾点也不算本地
            "2001:4860:4860::8888",
            "::"
        ] {
            XCTAssertFalse(LocalHostPolicy.isLocalOrPrivate(host: host), host)
        }
    }
}
