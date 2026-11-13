import XCTest
@testable import Voxi

final class KeychainServiceTests: XCTestCase {
    private var service: KeychainService!
    private var itemIDs: [UUID] = []

    override func setUpWithError() throws {
        service = KeychainService(service: "com.voxi.app.tests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        for id in itemIDs {
            try? service.delete(id)
        }
        itemIDs = []
    }

    private func store(_ secret: String) throws -> UUID {
        let id = try service.store(secret)
        itemIDs.append(id)
        return id
    }

    func testStoreReadOverwriteDelete() throws {
        let id = try store("sk-first")
        XCTAssertEqual(try service.secret(for: id), "sk-first")
        XCTAssertTrue(service.hasSecret(for: id))

        try service.store("sk-second", for: id)
        XCTAssertEqual(try service.secret(for: id), "sk-second")

        try service.delete(id)
        XCTAssertNil(try service.secret(for: id))
        XCTAssertFalse(service.hasSecret(for: id))
    }

    func testMissingItemReturnsNil() throws {
        XCTAssertNil(try service.secret(for: UUID()))
        XCTAssertFalse(service.hasSecret(for: UUID()))
    }

    func testItemsAreIsolatedByID() throws {
        let first = try store("one")
        let second = try store("two")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try service.secret(for: first), "one")
        XCTAssertEqual(try service.secret(for: second), "two")
    }

    func testSecretResolverThrowsWhenMissing() {
        let resolver = KeychainSecretResolver(keychain: service)
        XCTAssertThrowsError(try resolver.secret(for: UUID())) { error in
            XCTAssertEqual(error as? TranscriptionError, .missingCredential)
        }
    }

    func testSecretResolverReadsStoredValue() throws {
        let id = try store("resolved")
        let resolver = KeychainSecretResolver(keychain: service)
        XCTAssertEqual(try resolver.secret(for: id), "resolved")
    }

    func testInMemoryResolver() throws {
        let resolver = InMemorySecretResolver()
        let id = UUID()
        resolver.set("abc", for: id)
        XCTAssertEqual(try resolver.secret(for: id), "abc")
        XCTAssertThrowsError(try resolver.secret(for: UUID()))
    }
}
