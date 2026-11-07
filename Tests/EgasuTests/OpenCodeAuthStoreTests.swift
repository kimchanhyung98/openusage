import XCTest
@testable import Egasu

final class OpenCodeAuthStoreTests: XCTestCase {
    private func store(_ json: String) -> OpenCodeAuthStore {
        store(files: FakeFiles(["/oc/auth.json": json]))
    }

    private func store(files: TextFileAccessing) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
    }

    func testReadsGoKey() throws {
        XCTAssertEqual(try store(#"{"opencode-go":{"type":"api","key":"sk-abc"}}"#).goAPIKey(), "sk-abc")
    }

    func testToleratesNonObjectSiblingEntries() throws {
        // opencode-go 옆의 schema marker(string)·array entry가 key를 가리지 않아야 함
        let json = #"{"$schema":"https://opencode.ai/auth.json","opencode-go":{"type":"api","key":"sk-xyz"},"weird":["a","b"]}"#
        XCTAssertEqual(try store(json).goAPIKey(), "sk-xyz")
    }

    func testCoexistsWithOtherProviderEntries() throws {
        let json = #"{"openai":{"type":"oauth","access":"x","refresh":"y"},"opencode-go":{"type":"api","key":"sk-1"}}"#
        XCTAssertEqual(try store(json).goAPIKey(), "sk-1")
    }

    func testMissingEmptyOrAbsentKeyIsNil() throws {
        XCTAssertNil(try store(#"{"opencode-go":{"type":"api"}}"#).goAPIKey())
        XCTAssertNil(try store(#"{"opencode-go":{"type":"api","key":"   "}}"#).goAPIKey())
        XCTAssertNil(try store(#"{"openai":{"type":"oauth"}}"#).goAPIKey())
        XCTAssertNil(try store(files: FakeFiles()).goAPIKey()) // file 부재 = 미로그인
    }

    func testMalformedJSONThrowsCredentialsUnreadable() {
        XCTAssertThrowsError(try store("not json").goAPIKey()) { error in
            guard case OpenCodeUsageError.credentialsUnreadable = error else {
                return XCTFail("expected credentialsUnreadable, got \(error)")
            }
        }
    }

    func testUnreadablePresentFileThrowsCredentialsUnreadable() {
        // 존재하지만 읽기 불가한 auth.json(권한·encoding)은 logout으로 위장 금지
        XCTAssertThrowsError(try store(files: UnreadableFiles(present: ["/oc/auth.json"])).goAPIKey()) { error in
            guard case OpenCodeUsageError.credentialsUnreadable = error else {
                return XCTFail("expected credentialsUnreadable, got \(error)")
            }
        }
    }

    func testCustomDatabasePathOverridesDiscoveryWithoutMovingAuthFile() throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let data = home.appendingPathComponent("data/opencode")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        for name in ["opencode.db", "opencode-next.db", "usage.sqlite", "opencode.db-wal"] {
            try Data().write(to: data.appendingPathComponent(name))
        }
        let environment = FakeEnvironment(["XDG_DATA_HOME": home.appendingPathComponent("data").path])
        XCTAssertEqual(try OpenCodePaths.databaseFiles(environment: environment, homeDirectory: home), [
            data.appendingPathComponent("opencode-next.db").path, data.appendingPathComponent("opencode.db").path
        ])
        let overridden = FakeEnvironment([
            "XDG_DATA_HOME": home.appendingPathComponent("data").path, "OPENCODE_DB": "usage.sqlite"
        ])
        XCTAssertEqual(try OpenCodePaths.databaseFiles(environment: overridden, homeDirectory: home), [
            data.appendingPathComponent("usage.sqlite").path
        ])
        let auth = OpenCodeAuthStore(files: FakeFiles(), environment: overridden, homeDirectory: { home })
        XCTAssertEqual(auth.authFilePath, data.appendingPathComponent("auth.json").path)
    }

    func testAbsoluteDatabaseOverrideMemoryAndMissingStore() throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appendingPathComponent("custom-store")
        try Data().write(to: database)
        XCTAssertEqual(try OpenCodePaths.databaseFiles(
            environment: FakeEnvironment(["OPENCODE_DB": database.path]), homeDirectory: home
        ), [database.path])
        for path in [":memory:", "missing.sqlite"] {
            XCTAssertTrue(try OpenCodePaths.databaseFiles(
                environment: FakeEnvironment(["OPENCODE_DB": path]), homeDirectory: home
            ).isEmpty)
        }
    }

    func testTildeDataOverridesUseTheInjectedHome() {
        let home = URL(fileURLWithPath: "/fixture-home")
        XCTAssertEqual(OpenCodePaths.dataDirectory(
            environment: FakeEnvironment(["XDG_DATA_HOME": "~/data"]), homeDirectory: home
        ), "/fixture-home/data/opencode")
        XCTAssertEqual(OpenCodePaths.dataDirectory(
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "~/custom"]), homeDirectory: home
        ), "/fixture-home/custom")
    }
}

/// 존재하지만 읽기는 항상 실패하는 file store (permission-denied auth.json 모사)
final class UnreadableFiles: TextFileAccessing, @unchecked Sendable {
    let present: Set<String>
    init(present: Set<String>) { self.present = present }

    func exists(_ path: String) -> Bool { present.contains(path) }
    func readText(_ path: String) throws -> String {
        throw CocoaError(.fileReadNoPermission)
    }
    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}
