import Foundation
import XCTest
@testable import OpenUsage

extension ClaudeDesktopAuthStoreTests {
    func testMalformedScopedOwnerFailsLoadAndLogsWithoutCredentialData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sink = LogFile(directory: directory, fileName: "test.log")
        sink.open()
        let previous = AppLog.sink
        AppLog.sink = sink
        defer {
            AppLog.sink = previous
            try? FileManager.default.removeItem(at: directory)
        }
        let fixture = try makeFixture(
            activeOrganization: organization,
            activeAccountUUID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            v2: ["acct:PRIVATE_INVALID_OWNER|\(cacheKey(organization: organization))": NSNull()],
            v1: [cacheKey(organization: organization): tokenEntry("PRIVATE_OLD_TOKEN", expiresIn: 3_600)]
        )
        let result = fixture.store.load(allowInteraction: false)
        XCTAssertEqual(result.status, .invalid)
        XCTAssertNil(result.oauth)
        let logged = try String(contentsOf: directory.appendingPathComponent("test.log"), encoding: .utf8)
        XCTAssertTrue(logged.contains("[ERROR]"))
        XCTAssertTrue(logged.contains("Claude Desktop cache has malformed account ownership"))
        for privateValue in ["PRIVATE_INVALID_OWNER", "PRIVATE_OLD_TOKEN", organization] {
            XCTAssertFalse(logged.contains(privateValue))
        }
    }
}
