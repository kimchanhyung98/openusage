import Foundation
import XCTest
@testable import OpenUsage

final class CursorSQLiteCredentialPreservationTests: XCTestCase {
    func testMatchingPairRotatesOnlyAccessAndKeepsSecretsBound() throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        let oldAccess = "old-'한글-🙂"
        let refresh = "refresh-'한글-🙂"
        let rotated = "rotated-'한글-🙂"
        try database.replaceAuth(accessToken: oldAccess, refreshToken: refresh)
        try database.setValue("keep-me", for: "unrelated-setting")
        let store = CursorAuthStore(sqlite: database, keychain: FakeKeychain())
        let original = try XCTUnwrap(store.loadAuthState())

        try store.saveAccessToken(rotated, replacing: original)

        XCTAssertEqual(try database.value(for: CursorAuthStore.accessTokenKey), rotated)
        XCTAssertEqual(try database.value(for: CursorAuthStore.refreshTokenKey), refresh)
        XCTAssertEqual(try database.value(for: "unrelated-setting"), "keep-me")
        for secret in [oldAccess, refresh, rotated] {
            XCTAssertFalse(database.sqlStatements.contains { $0.contains(secret) })
            XCTAssertFalse(database.processArguments.flatMap { $0 }.contains { $0.contains(secret) })
        }
    }

    func testRefreshOnlyStateCanCreateAccessWhileRefreshStillMatches() throws {
        let absentValues: [String?] = [nil, "", " ", "\t", "\n", "\r\n", "\u{00A0}\u{2003}\u{2028}\u{3000}"]
        for access in absentValues {
            let database = try CursorPreservationSQLite()
            defer { database.remove() }
            try database.replaceAuth(accessToken: access, refreshToken: "original-refresh")
            let store = CursorAuthStore(sqlite: database, keychain: FakeKeychain())
            let original = try XCTUnwrap(store.loadAuthState())
            XCTAssertNil(original.accessToken)

            try store.saveAccessToken("new-access", replacing: original)

            XCTAssertEqual(try database.value(for: CursorAuthStore.accessTokenKey), "new-access")
            XCTAssertEqual(try database.value(for: CursorAuthStore.refreshTokenKey), "original-refresh")
        }
    }

    func testPaddedCredentialsMatchLoaderNormalizationAndPreserveRawRefresh() throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        let access = "\t\u{00A0} original-access \n\u{3000}"
        let refresh = "\u{2003} original-refresh \t\u{2028}"
        try database.replaceAuth(accessToken: access, refreshToken: refresh)
        let store = CursorAuthStore(sqlite: database, keychain: FakeKeychain())
        let original = try XCTUnwrap(store.loadAuthState())
        XCTAssertEqual(original.accessToken, "original-access")
        XCTAssertEqual(original.refreshToken, "original-refresh")

        try store.saveAccessToken("new-access", replacing: original)

        XCTAssertEqual(try database.value(for: CursorAuthStore.accessTokenKey), "new-access")
        let storedRefreshHex = try database.queryValue(
            path: CursorAuthStore.stateDBPath,
            sql: "SELECT hex(value) FROM ItemTable WHERE key = 'cursorAuth/refreshToken';"
        )
        XCTAssertEqual(storedRefreshHex, Data(refresh.utf8).map { String(format: "%02X", $0) }.joined())
    }

    func testChangedOrDeletedCredentialRowsRejectStaleWriteback() throws {
        let replacements: [(String?, String?)] = [
            ("external-access", "original-refresh"),
            ("original-access", "external-refresh"),
            (nil, "original-refresh"),
            ("original-access", nil),
            (nil, nil)
        ]
        for (access, refresh) in replacements {
            let database = try CursorPreservationSQLite()
            defer { database.remove() }
            try database.replaceAuth(accessToken: "original-access", refreshToken: "original-refresh")
            let store = CursorAuthStore(sqlite: database, keychain: FakeKeychain())
            let original = try XCTUnwrap(store.loadAuthState())
            try database.replaceAuth(accessToken: access, refreshToken: refresh)

            XCTAssertThrowsError(try store.saveAccessToken("stale-rotation", replacing: original)) { error in
                XCTAssertEqual(error as? CursorAuthError, .credentialsChanged)
            }

            XCTAssertEqual(try database.value(for: CursorAuthStore.accessTokenKey), access)
            XCTAssertEqual(try database.value(for: CursorAuthStore.refreshTokenKey), refresh)
        }
    }

    func testChangeImmediatelyBeforeConditionalStatementIsNotOverwritten() throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        try database.replaceAuth(accessToken: "original-access", refreshToken: "original-refresh")
        let store = CursorAuthStore(sqlite: database, keychain: FakeKeychain())
        let original = try XCTUnwrap(store.loadAuthState())
        database.beforeNextConditionalWrite {
            try database.replaceAuth(accessToken: "external-access", refreshToken: "external-refresh")
        }

        XCTAssertThrowsError(try store.saveAccessToken("stale-rotation", replacing: original)) { error in
            XCTAssertEqual(error as? CursorAuthError, .credentialsChanged)
        }

        XCTAssertEqual(try database.value(for: CursorAuthStore.accessTokenKey), "external-access")
        XCTAssertEqual(try database.value(for: CursorAuthStore.refreshTokenKey), "external-refresh")
    }

    func testDeletedDatabaseIsNotRecreatedByStaleWriteback() throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        try database.replaceAuth(accessToken: "original-access", refreshToken: "original-refresh")
        let store = CursorAuthStore(sqlite: database, keychain: FakeKeychain())
        let original = try XCTUnwrap(store.loadAuthState())
        try database.removeDatabase()

        XCTAssertThrowsError(try store.saveAccessToken("stale-rotation", replacing: original))

        XCTAssertFalse(database.exists)
    }

    func testWriteErrorAfterExternalChangeIsAConflictAndPreservesNewPair() throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        try database.replaceAuth(accessToken: "original-access", refreshToken: "original-refresh")
        let store = CursorAuthStore(sqlite: database, keychain: FakeKeychain())
        let original = try XCTUnwrap(store.loadAuthState())
        database.beforeNextConditionalWrite {
            try database.replaceAuth(accessToken: "external-access", refreshToken: "external-refresh")
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertThrowsError(try store.saveAccessToken("stale-rotation", replacing: original)) { error in
            XCTAssertEqual(error as? CursorAuthError, .credentialsChanged)
        }

        XCTAssertEqual(try database.value(for: CursorAuthStore.accessTokenKey), "external-access")
        XCTAssertEqual(try database.value(for: CursorAuthStore.refreshTokenKey), "external-refresh")
    }

    func testRemovedCredentialTableFailsClosedWithoutRecreatingRows() throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        try database.replaceAuth(accessToken: "original-access", refreshToken: "original-refresh")
        let store = CursorAuthStore(sqlite: database, keychain: FakeKeychain())
        let original = try XCTUnwrap(store.loadAuthState())
        try database.execute(path: CursorAuthStore.stateDBPath, sql: "DROP TABLE ItemTable;")

        XCTAssertThrowsError(try store.saveAccessToken("stale-rotation", replacing: original)) { error in
            XCTAssertEqual(error as? CursorAuthError, .credentialsChanged)
        }

        XCTAssertNil(try database.queryValue(
            path: CursorAuthStore.stateDBPath,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ItemTable';"
        ))
    }

    func testMissingOriginalAuthenticationCannotCreateCredentialRows() throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        let store = CursorAuthStore(sqlite: database, keychain: FakeKeychain())
        let absent = CursorAuthState(accessToken: nil, refreshToken: nil, source: .sqlite)

        XCTAssertThrowsError(try store.saveAccessToken("unowned-token", replacing: absent)) { error in
            XCTAssertEqual(error as? CursorAuthError, .credentialsChanged)
        }

        XCTAssertNil(try database.value(for: CursorAuthStore.accessTokenKey))
        XCTAssertNil(try database.value(for: CursorAuthStore.refreshTokenKey))
    }

    func testConsecutiveRotationsRequireTheCurrentPair() throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        try database.replaceAuth(accessToken: "original-access", refreshToken: "same-refresh")
        let store = CursorAuthStore(sqlite: database, keychain: FakeKeychain())
        let original = try XCTUnwrap(store.loadAuthState())
        try store.saveAccessToken("first-rotation", replacing: original)

        XCTAssertThrowsError(try store.saveAccessToken("stale-rotation", replacing: original)) { error in
            XCTAssertEqual(error as? CursorAuthError, .credentialsChanged)
        }
        XCTAssertEqual(try database.value(for: CursorAuthStore.accessTokenKey), "first-rotation")
        let current = try XCTUnwrap(store.loadAuthState())
        try store.saveAccessToken("second-rotation", replacing: current)

        XCTAssertEqual(try database.value(for: CursorAuthStore.accessTokenKey), "second-rotation")
        XCTAssertEqual(try database.value(for: CursorAuthStore.refreshTokenKey), "same-refresh")
    }

    func testNativeChangesReportRowsAndBindNullValues() throws {
        let database = try CursorPreservationSQLite()
        defer { database.remove() }
        let inserted = try database.executeChanges(
            path: CursorAuthStore.stateDBPath,
            sql: "INSERT INTO ItemTable (key, value) VALUES (?, ?);", bindings: ["nullable", nil]
        )
        let skipped = try database.executeChanges(
            path: CursorAuthStore.stateDBPath,
            sql: "UPDATE ItemTable SET value = ? WHERE key = ?;", bindings: ["value", "missing"]
        )
        let updated = try database.executeChanges(
            path: CursorAuthStore.stateDBPath,
            sql: "UPDATE ItemTable SET value = ? WHERE key = ? AND value IS ?;",
            bindings: ["value", "nullable", nil]
        )

        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(updated, 1)
        XCTAssertEqual(try database.value(for: "nullable"), "value")
    }
}

final class CursorPreservationSQLite: SQLiteAccessing, @unchecked Sendable {
    private let directory: URL
    private let databasePath: String
    private let runner: CursorPreservationProcessRecorder
    private let accessor: SQLiteCLIAccessor
    private let lock = NSLock()
    private var recordedSQL: [String] = []
    private var beforeWrite: (@Sendable () throws -> Void)?

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.CursorPreservation.\(UUID().uuidString)", isDirectory: true)
        databasePath = directory.appendingPathComponent("state.vscdb").path
        let runner = CursorPreservationProcessRecorder()
        self.runner = runner
        accessor = SQLiteCLIAccessor(processRunner: runner)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try accessor.execute(path: databasePath, sql: "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);")
    }

    var sqlStatements: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSQL
    }

    var processArguments: [[String]] { runner.arguments }
    var exists: Bool { FileManager.default.fileExists(atPath: databasePath) }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    func removeDatabase() throws { try FileManager.default.removeItem(atPath: databasePath) }

    func replaceAuth(accessToken: String?, refreshToken: String?) throws {
        try setValue(accessToken, for: CursorAuthStore.accessTokenKey)
        try setValue(refreshToken, for: CursorAuthStore.refreshTokenKey)
    }

    func setValue(_ value: String?, for key: String) throws {
        if let value {
            try execute(
                path: CursorAuthStore.stateDBPath,
                sql: "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?);", bindings: [key, value]
            )
        } else {
            try execute(path: CursorAuthStore.stateDBPath, sql: "DELETE FROM ItemTable WHERE key = ?;", bindings: [key])
        }
    }

    func value(for key: String) throws -> String? {
        try queryValue(path: CursorAuthStore.stateDBPath, sql: "SELECT value FROM ItemTable WHERE key = '\(key)';")
    }

    func beforeNextConditionalWrite(_ body: @escaping @Sendable () throws -> Void) {
        lock.lock()
        beforeWrite = body
        lock.unlock()
    }

    func queryValue(path: String, sql: String) throws -> String? {
        try validatePath(path)
        record(sql)
        return try accessor.queryValue(path: databasePath, sql: sql)
    }

    func execute(path: String, sql: String) throws {
        try validatePath(path)
        record(sql)
        try accessor.execute(path: databasePath, sql: sql)
    }

    func execute(path: String, sql: String, bindings: [String]) throws {
        try validatePath(path)
        record(sql)
        try accessor.execute(path: databasePath, sql: sql, bindings: bindings)
    }

    func executeChanges(path: String, sql: String, bindings: [String?]) throws -> Int {
        try validatePath(path)
        record(sql)
        lock.lock()
        let beforeWrite = self.beforeWrite
        self.beforeWrite = nil
        lock.unlock()
        try beforeWrite?()
        return try accessor.executeChanges(path: databasePath, sql: sql, bindings: bindings)
    }

    private func record(_ sql: String) {
        lock.lock()
        recordedSQL.append(sql)
        lock.unlock()
    }

    private func validatePath(_ path: String) throws {
        guard path == CursorAuthStore.stateDBPath else {
            throw SQLiteError.queryFailed("Unexpected test database path.")
        }
    }
}

private final class CursorPreservationProcessRecorder: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedArguments: [[String]] = []

    var arguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedArguments
    }

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) throws -> ProcessResult {
        lock.lock()
        recordedArguments.append(arguments)
        lock.unlock()
        return try SystemProcessRunner().run(
            executable: executable, arguments: arguments, environment: environment, timeout: timeout
        )
    }
}
