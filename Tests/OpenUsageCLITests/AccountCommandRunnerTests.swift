import Darwin
import XCTest
@testable import OpenUsage
@testable import OpenUsageCLI

@MainActor
final class AccountCommandRunnerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "OpenUsageTests.AccountRunner.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { [defaults, suiteName] in
            if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        }
    }

    @discardableResult
    private func seedProfile(
        family: String = "codex",
        label: String,
        identityKey: String,
        preferred: Bool = false
    ) throws -> AccountProfile {
        let store = AccountProfilesStore(defaults: defaults)
        let profile = try store.add(family: family, label: label, identityKey: identityKey)
        if preferred {
            store.setPreferred(family: family, profileID: profile.id)
        }
        return profile
    }

    /// 실행 중 표준 출력 fd 1 캡처 — 버퍼링된 `print`와 직접 쓰기 모두 파이프로 수집.
    private func captureStandardOutput(_ body: () throws -> Int32) throws -> (code: Int32, output: String) {
        fflush(stdout)
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        defer { close(saved) }
        let code: Int32
        do {
            code = try body()
            fflush(stdout)
        } catch {
            fflush(stdout)
            dup2(saved, STDOUT_FILENO)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
        dup2(saved, STDOUT_FILENO)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (code, String(decoding: data, as: UTF8.self))
    }

    func testListMarksTheSelectedProfileAndPrintsNoPaths() throws {
        try seedProfile(label: "default", identityKey: "codex-1")
        try seedProfile(label: "Work", identityKey: "codex-2", preferred: true)
        let runner = AccountCommandRunner(defaults: defaults)

        let result = try captureStandardOutput { try runner.run(.list(family: "codex", json: false)) }

        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.output.contains("codex:"))
        XCTAssertTrue(result.output.contains("* Work"))
        XCTAssertTrue(result.output.contains("  default"))
        XCTAssertFalse(result.output.contains("~"), "list output never carries a path")
        XCTAssertFalse(result.output.contains("/"), "list output never carries a path")
    }

    func testListJSONCarriesExactlyIdFamilyLabelSelected() throws {
        struct Row: Codable, Equatable {
            var id: String
            var family: String
            var label: String
            var selected: Bool
        }
        let personal = try seedProfile(label: "default", identityKey: "codex-1")
        let work = try seedProfile(label: "Work", identityKey: "codex-2", preferred: true)
        let runner = AccountCommandRunner(defaults: defaults)

        let result = try captureStandardOutput { try runner.run(.list(family: nil, json: true)) }

        XCTAssertEqual(result.code, 0)
        let rows = try JSONDecoder().decode([Row].self, from: Data(result.output.utf8))
        XCTAssertEqual(rows, [
            Row(id: personal.id, family: "codex", label: "default", selected: false),
            Row(id: work.id, family: "codex", label: "Work", selected: true),
        ])
        let raw = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]]
        XCTAssertEqual(
            Set(raw?.first.map { Array($0.keys) } ?? []),
            ["id", "family", "label", "selected"]
        )
    }

    func testCurrentWithFamilyPrintsTheBareSelectedLabel() throws {
        try seedProfile(label: "Work", identityKey: "codex-2", preferred: true)
        let runner = AccountCommandRunner(defaults: defaults)

        let result = try captureStandardOutput { try runner.run(.current(family: "codex")) }

        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.output, "Work\n")
    }

    func testCurrentWithoutFamilyPrintsBothFamiliesWithDashWhenEmpty() throws {
        try seedProfile(family: "claude", label: "Personal", identityKey: "acct-1", preferred: true)
        let runner = AccountCommandRunner(defaults: defaults)

        let result = try captureStandardOutput { try runner.run(.current(family: nil)) }

        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.output, "claude: Personal\ncodex: -\n")
    }

    func testEmptyRegistryPointsAtSettings() throws {
        let runner = AccountCommandRunner(defaults: defaults)

        let result = try captureStandardOutput { try runner.run(.list(family: nil, json: false)) }

        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.output, "No managed accounts. Add one in OpenUsage Settings.\n")
    }

    func testUnreadableRegistryFailsInsteadOfPrintingAnEmptyList() {
        defaults.set(Data("not json".utf8), forKey: AccountProfilesStore.storageKey)
        let runner = AccountCommandRunner(defaults: defaults)

        XCTAssertThrowsError(try runner.run(.list(family: nil, json: false))) { error in
            XCTAssertEqual(error as? AccountProfileError, .registryUnreadable)
        }
    }

}
