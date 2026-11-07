import XCTest
@testable import OpenUsage

@MainActor
final class OpenClawColdOwnerPathTests: XCTestCase {
    func testDatabaseSymlinkUsesDiscoveredOwnerAndDeduplicatesCanonicalStore() async throws {
        let store = try OpenClawTestStore()
        let cold = try OpenClawTestStore.message(id: "cold", cost: 0.25)
        let hot = try OpenClawTestStore.message(id: "hot", cost: 0.1)
        let archive = try OpenClawTestStore.ColdArchive(events: [(0, OpenClawTestStore.header), (1, cold)])
        try store.install([archive], storage: "file")
        try store.execute("INSERT INTO transcript_events VALUES('s1',2,\(OpenClawTestStore.literal(hot)),NULL,\(hot.utf8.count))")
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var roots: [URL] = []
        var archives: [URL] = []
        for name in ["a", "b"] {
            let owner = root.appendingPathComponent(name)
            let agent = owner.appendingPathComponent("agent")
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: agent.appendingPathComponent("openclaw-agent.sqlite"),
                                                       withDestinationURL: store.file)
            let archiveURL = owner.appendingPathComponent("sessions/cold").appendingPathComponent(archive.name)
            try UsageRecordFixture.write(archive.bytes, to: archiveURL)
            roots.append(agent)
            archives.append(archiveURL)
        }
        let collector = UsageSourceCollectors.openClawDatabaseCollector(roots: roots)
        let initial = await collector.collect(since: .distantPast)
        let result = try XCTUnwrap(initial)
        XCTAssertEqual(Set(result.records.compactMap(\.id)), Set(["cold", "hot"]))
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 240)
        XCTAssertEqual(result.sources.first?.completedStores, 1)
        XCTAssertEqual(result.readFailureCount, 0)
        for archiveURL in archives { try FileManager.default.removeItem(at: archiveURL) }
        let missing = await collector.collect(since: .distantPast)
        XCTAssertEqual(missing?.readFailureCount, 1)
        XCTAssertTrue(missing?.records.isEmpty == true)
    }
}
