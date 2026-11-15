import XCTest
@testable import Voxi

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertEqual(UpdateChecker.compareVersions("1.0.1", "1.0.1"), 0)
        XCTAssertEqual(UpdateChecker.compareVersions("v1.0.10", "1.0.9"), 1)
        XCTAssertEqual(UpdateChecker.compareVersions("1.0.0", "1.0"), 0)
        XCTAssertEqual(UpdateChecker.compareVersions("1.1.0", "1.1.0-beta.1"), 1)
        XCTAssertEqual(UpdateChecker.compareVersions("1.1.0-beta.2", "1.1.0-beta.1"), 1)
        XCTAssertEqual(UpdateChecker.compareVersions("2.0", "1.99.99"), 1)
        XCTAssertEqual(UpdateChecker.compareVersions("0.9", "1.0"), -1)
    }

    func testNormalizedVersionStripsLeadingV() {
        XCTAssertEqual(UpdateChecker.normalizedVersion("v1.2.3"), "1.2.3")
        XCTAssertEqual(UpdateChecker.normalizedVersion(" 1.2.3 "), "1.2.3")
    }

    func testLatestReleaseParsingPrefersDmgAsset() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            let json = """
            {
              "tag_name": "v1.2.0",
              "name": "Voxi 1.2.0",
              "html_url": "https://github.com/sseaan/Voxi/releases/tag/v1.2.0",
              "body": "- 新增历史记录",
              "assets": [
                {"name": "manifest.txt", "browser_download_url": "https://example.com/manifest.txt"},
                {"name": "Voxi-1.2.0.dmg", "browser_download_url": "https://example.com/Voxi-1.2.0.dmg"}
              ]
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, json.data(using: .utf8)!)
        }

        let checker = UpdateChecker(session: session, currentVersion: "1.1.0")
        let release = try await checker.latestRelease()
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.downloadURL?.lastPathComponent, "Voxi-1.2.0.dmg")
        XCTAssertEqual(release.notes, "- 新增历史记录")

        let result = try await checker.check()
        XCTAssertEqual(result, .available(release))
    }

    func testUpToDateResult() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            let json = """
            {"tag_name": "v1.1.0", "html_url": "https://example.com", "body": "", "assets": []}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json.data(using: .utf8)!)
        }

        let checker = UpdateChecker(session: session, currentVersion: "1.1.0")
        let result = try await checker.check()
        XCTAssertEqual(result, .upToDate(current: "1.1.0"))
    }

    func testRateLimitIsReported() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let checker = UpdateChecker(session: session, currentVersion: "1.1.0")
        do {
            _ = try await checker.check()
            XCTFail("expected rate limit error")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, .rateLimited)
        }
    }
}
