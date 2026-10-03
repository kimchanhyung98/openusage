import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerAttemptStoreTests: XCTestCase {
    func testAtomicReservationAcrossStoreInstancesAndPrivateHashedRecord() throws {
        try withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let first = try XCTUnwrap(store.begin(accountKey: "private@example.com:workspace", resetBefore: nil, now: now))
            let secondStore = CodexWeeklyTimerAttemptStore(fileURL: store.fileURL)
            XCTAssertNil(try secondStore.begin(accountKey: "private@example.com:workspace", resetBefore: nil, now: now))
            XCTAssertEqual(try secondStore.attempt(for: "private@example.com:workspace"), first)
            let text = try String(contentsOf: store.fileURL, encoding: .utf8)
            XCTAssertFalse(text.contains("private@example.com"))
            XCTAssertFalse(text.contains("workspace"))
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let attempts = try XCTUnwrap(document["attempts"] as? [String: Any])
            XCTAssertEqual(attempts.keys.first?.count, 64)
            let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testMissingPastAndFutureResetsAllUseFixedCooldown() throws {
        try withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let future = now.addingTimeInterval(500)
            XCTAssertEqual(try store.begin(accountKey: "missing", resetBefore: nil, now: now)?.notBefore, now.addingTimeInterval(300))
            XCTAssertEqual(try store.begin(accountKey: "past", resetBefore: now.addingTimeInterval(-1), now: now)?.notBefore, now.addingTimeInterval(300))
            XCTAssertEqual(try store.begin(accountKey: "future", resetBefore: future, now: now)?.notBefore, now.addingTimeInterval(300))
        }
    }

    func testStaleAndDuplicateObservationsCannotReplaceBaselineOrExtendCooldown() throws {
        try withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            _ = try store.begin(accountKey: "a", resetBefore: nil, now: now)
            XCTAssertEqual(try store.observe(accountKey: "a", rawResetAt: now.addingTimeInterval(500), observedAt: now.addingTimeInterval(20)), .baseline)
            XCTAssertEqual(try store.observe(accountKey: "a", rawResetAt: now.addingTimeInterval(200), observedAt: now.addingTimeInterval(10)), .stale)
            XCTAssertEqual(try store.observe(accountKey: "a", rawResetAt: now.addingTimeInterval(900), observedAt: now.addingTimeInterval(20)), .stale)
            XCTAssertEqual(try store.observe(accountKey: "a", rawResetAt: now.addingTimeInterval(500), observedAt: now.addingTimeInterval(85)), .unchanged)
            XCTAssertEqual(try store.attempt(for: "a")?.notBefore, now.addingTimeInterval(300))
        }
    }

    func testStaleAttemptCannotOverwriteReplacementReservation() throws {
        try withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let original = try XCTUnwrap(store.begin(accountKey: "a", resetBefore: now.addingTimeInterval(1), now: now))
            let replacement = try XCTUnwrap(store.begin(accountKey: "a", resetBefore: nil, now: now.addingTimeInterval(301)))
            try store.update(accountKey: "a", attempt: original)
            XCTAssertEqual(try store.attempt(for: "a"), replacement)
        }
    }

    func testCorruptVersionAndInvalidKeysFailClosed() throws {
        try withStore { store in
            for invalid in ["{\"version\":3,\"attempts\":{}}", "broken"] {
                try Data(invalid.utf8).write(to: store.fileURL)
                XCTAssertThrowsError(try store.begin(accountKey: "a", resetBefore: nil, now: Date()))
                XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), invalid)
            }
        }
    }

    func testUnreadableDestinationCannotReserveAttempt() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
            XCTAssertThrowsError(try store.begin(accountKey: "a", resetBefore: nil, now: Date()))
        }
    }

    func testBaselinePersistsAcrossRestartAndMissingAbsoluteResetBreaksComparison() throws {
        try withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let reset = now.addingTimeInterval(900)
            XCTAssertEqual(try store.observe(accountKey: "a", rawResetAt: reset, observedAt: now), .baseline)
            let restarted = CodexWeeklyTimerAttemptStore(fileURL: store.fileURL)
            XCTAssertEqual(try restarted.observe(accountKey: "a", rawResetAt: reset, observedAt: now.addingTimeInterval(65)), .unchanged)
            XCTAssertEqual(try restarted.observe(accountKey: "a", rawResetAt: nil, observedAt: now.addingTimeInterval(66)), .incomparable)
            XCTAssertEqual(try restarted.observe(accountKey: "a", rawResetAt: reset, observedAt: now.addingTimeInterval(67)), .incomparable)
            XCTAssertEqual(try restarted.observe(accountKey: "a", rawResetAt: reset.addingTimeInterval(61), observedAt: now.addingTimeInterval(68)), .changed)
        }
    }

    func testRapidIdenticalObservationsRetainFirstStableTimestamp() throws {
        try withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let reset = now.addingTimeInterval(900)
            _ = try store.observe(accountKey: "a", rawResetAt: reset, observedAt: now)
            XCTAssertEqual(try store.observe(accountKey: "a", rawResetAt: reset, observedAt: now.addingTimeInterval(20)), .incomparable)
            XCTAssertEqual(try store.observe(accountKey: "a", rawResetAt: reset, observedAt: now.addingTimeInterval(60)), .incomparable)
            XCTAssertEqual(try store.observe(accountKey: "a", rawResetAt: reset, observedAt: now.addingTimeInterval(61)), .unchanged)
        }
    }

    func testReservationRejectsCandidateSupersededByNewerBaseline() throws {
        try withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            _ = try store.observe(accountKey: "a", rawResetAt: now.addingTimeInterval(900), observedAt: now)
            _ = try store.observe(accountKey: "a", rawResetAt: now.addingTimeInterval(961), observedAt: now.addingTimeInterval(1))
            XCTAssertNil(try store.begin(accountKey: "a", resetBefore: nil, now: now, expectedObservedAt: now))
            XCTAssertNotNil(try store.begin(accountKey: "a", resetBefore: nil, now: now, expectedObservedAt: now.addingTimeInterval(1)))
        }
    }

    func testOneMinuteResetTolerancePersistsWithoutFollowingCumulativeDrift() throws {
        try withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let reset = now.addingTimeInterval(900)
            _ = try store.observe(accountKey: "a", rawResetAt: reset, observedAt: now)
            let restarted = CodexWeeklyTimerAttemptStore(fileURL: store.fileURL)

            XCTAssertEqual(try restarted.observe(accountKey: "a", rawResetAt: reset.addingTimeInterval(60),
                                                 observedAt: now.addingTimeInterval(65)), .unchanged)
            XCTAssertEqual(try restarted.observe(accountKey: "a", rawResetAt: reset.addingTimeInterval(61),
                                                 observedAt: now.addingTimeInterval(130)), .changed)
            _ = try store.observe(accountKey: "b", rawResetAt: reset, observedAt: now)
            XCTAssertEqual(try store.observe(accountKey: "b", rawResetAt: reset.addingTimeInterval(-60),
                                             observedAt: now.addingTimeInterval(65)), .unchanged)
        }
    }

    func testRapidMovingResetsCannotBecomeStableInsideOneMinuteTolerance() throws {
        try withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let reset = now.addingTimeInterval(900)
            _ = try store.observe(accountKey: "a", rawResetAt: reset, observedAt: now)
            for offset: TimeInterval in [20, 40, 60] {
                XCTAssertEqual(try store.observe(accountKey: "a", rawResetAt: reset.addingTimeInterval(offset),
                                                 observedAt: now.addingTimeInterval(offset)), .incomparable)
            }
            XCTAssertEqual(try store.observe(accountKey: "a", rawResetAt: reset.addingTimeInterval(65),
                                             observedAt: now.addingTimeInterval(65)), .changed)
        }
    }

    func testVersionOneAttemptsMigrateWithoutLosingIdentityOrResults() throws {
        try withStore { store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var attempt = try XCTUnwrap(store.begin(accountKey: "a", resetBefore: now.addingTimeInterval(900), now: now))
            attempt.notBefore = now.addingTimeInterval(604_800)
            attempt.execution = .completed
            attempt.resetAfter = now.addingTimeInterval(950)
            try store.update(accountKey: "a", attempt: attempt)
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
            legacy["version"] = 1
            legacy["observations"] = nil
            try JSONSerialization.data(withJSONObject: legacy).write(to: store.fileURL)
            let restored = try XCTUnwrap(CodexWeeklyTimerAttemptStore(fileURL: store.fileURL).attempt(for: "a"))
            XCTAssertEqual(restored.id, attempt.id)
            XCTAssertEqual(restored.execution, .completed)
            XCTAssertEqual(restored.resetAfter, attempt.resetAfter)
            XCTAssertEqual(restored.notBefore, now.addingTimeInterval(300))
            XCTAssertEqual(try store.observe(accountKey: "a", rawResetAt: nil, observedAt: now), .baseline)
            let current = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
            XCTAssertEqual(current["version"] as? Int, 2)
        }
    }

    private func withStore(_ body: (CodexWeeklyTimerAttemptStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(CodexWeeklyTimerAttemptStore(fileURL: directory.appendingPathComponent("attempts.json")))
    }
}
