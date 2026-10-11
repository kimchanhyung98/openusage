import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerRevalidationStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testOrdinaryMovingObservationsKeepTheConfirmedWindow() throws {
        try withStore { store in
            let oldReset = try seedConfirmedWindow(store)
            let (first, second) = observations()
            try observe(first, in: store)
            try observe(second, in: store)

            XCTAssertGreaterThan(oldReset, second.observedAt)
            XCTAssertFalse(try store.canAttempt(accountKey: "a", now: second.observedAt))
            XCTAssertNil(try store.begin(accountKey: "a", resetBefore: second.rawResetAt, now: second.observedAt))
            XCTAssertEqual(try store.revalidationState(accountKey: "a", now: second.observedAt)?.confirmedReset, oldReset)
        }
    }

    func testScheduledEvidenceReplacesFutureHoldAndExpiredAttemptWithoutRestoringTheOldHold() throws {
        try withStore { store in
            let oldReset = try seedConfirmedWindow(store)
            let previous = try XCTUnwrap(store.attempt(for: "a"))
            let (first, second) = observations()
            try observe(first, in: store)
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
            let before = try Data(contentsOf: store.fileURL)

            XCTAssertGreaterThan(oldReset, second.observedAt)
            XCTAssertLessThan(previous.notBefore, first.observedAt)
            XCTAssertEqual(state.confirmedReset, oldReset)
            XCTAssertFalse(try store.canAttempt(accountKey: "a", now: second.observedAt))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), before)

            let attempt = try XCTUnwrap(store.beginAfterRevalidation(
                first: first, second: second, expectedState: state, now: second.observedAt
            ))
            XCTAssertNotEqual(attempt.id, previous.id)
            XCTAssertEqual(attempt.execution, .pending)
            XCTAssertEqual(attempt.attemptedAt, second.observedAt)
            XCTAssertEqual(attempt.notBefore, second.observedAt.addingTimeInterval(300))
            XCTAssertEqual(attempt.resetBefore, second.rawResetAt)
            XCTAssertNil(attempt.resetAfter)
            XCTAssertNil(attempt.lastVerifiedAt)

            let restarted = CodexWeeklyTimerAttemptStore(fileURL: store.fileURL)
            XCTAssertEqual(try restarted.attempt(for: "a"), attempt)
            XCTAssertTrue(try restarted.isLatest(second))
            XCTAssertFalse(try restarted.canAttempt(accountKey: "a", now: attempt.notBefore))
            let availableAt = previous.attemptedAt.addingTimeInterval(86_400)
            XCTAssertEqual(try restarted.sendLimitResetsAt(accountKey: "a", now: attempt.notBefore), availableAt)
            XCTAssertTrue(try restarted.canAttempt(accountKey: "a", now: availableAt))
            XCTAssertNil(try restarted.revalidationState(accountKey: "a", now: availableAt)?.confirmedReset)
        }
    }

    func testScheduledEvidenceCanReserveWithoutAnExistingConfirmedWindow() throws {
        try withStore { store in
            let (first, second) = observations()
            XCTAssertFalse(try store.isLatestReceived(first))
            try observe(first, in: store)
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
            XCTAssertNil(state.confirmedReset)

            XCTAssertNotNil(try store.beginAfterRevalidation(
                first: first, second: second, expectedState: state, now: second.observedAt
            ))
            XCTAssertTrue(try store.isLatest(second))
        }
    }

    func testAnAcceptedIncomparableFirstObservationCanAuthorizeScheduledEvidence() throws {
        try withStore { store in
            _ = try seedConfirmedWindow(store)
            let (first, second) = observations()
            _ = try store.observe(
                accountKey: "a", rawResetAt: first.rawResetAt?.addingTimeInterval(-1),
                observedAt: first.observedAt.addingTimeInterval(-1)
            )
            XCTAssertEqual(try store.observe(
                accountKey: "a", rawResetAt: first.rawResetAt, observedAt: first.observedAt
            ), .incomparable)
            XCTAssertFalse(try store.isLatest(first))
            XCTAssertTrue(try store.isLatestReceived(first))
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))

            XCTAssertNotNil(try store.beginAfterRevalidation(
                first: first, second: second, expectedState: state, now: second.observedAt
            ))
            XCTAssertTrue(try store.isLatest(second))
        }
    }

    func testTwoStoreInstancesCannotReserveTheSameScheduledEvidenceTwice() throws {
        try withStore { store in
            _ = try seedConfirmedWindow(store)
            let (first, second) = observations()
            try observe(first, in: store)
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
            let other = CodexWeeklyTimerAttemptStore(fileURL: store.fileURL)
            let attempt = try XCTUnwrap(other.beginAfterRevalidation(
                first: first, second: second, expectedState: state, now: second.observedAt
            ))

            try assertRejected(store, first: first, second: second, state: state)
            XCTAssertEqual(try store.attempt(for: "a"), attempt)
            XCTAssertNil(try other.revalidationState(accountKey: "a", now: second.observedAt))
        }
    }

    func testScheduledStateAndReservationRespectTheExactCooldownBoundary() throws {
        try withStore { store in
            let (first, second) = observations()
            let previous = try XCTUnwrap(store.begin(accountKey: "a", resetBefore: nil, now: first.observedAt))
            try observe(first, in: store)
            let before = try Data(contentsOf: store.fileURL)

            XCTAssertNil(try store.revalidationState(
                accountKey: "a", now: previous.notBefore.addingTimeInterval(-0.001)
            ))
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: previous.notBefore))
            XCTAssertNil(try store.beginAfterRevalidation(
                first: first, second: second, expectedState: state, now: previous.notBefore.addingTimeInterval(-0.001)
            ))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
            let attempt = try XCTUnwrap(store.beginAfterRevalidation(
                first: first, second: second, expectedState: state, now: previous.notBefore
            ))
            XCTAssertEqual(attempt.notBefore, previous.notBefore.addingTimeInterval(300))
        }
    }

    func testAResetThatExpiresBeforeReservationCannotClearTheHold() throws {
        try withStore { store in
            _ = try seedConfirmedWindow(store)
            var (first, second) = observations()
            first.rawResetAt = first.observedAt.addingTimeInterval(100)
            second.rawResetAt = second.observedAt.addingTimeInterval(100)
            try observe(first, in: store)
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
            let before = try Data(contentsOf: store.fileURL)

            XCTAssertNil(try store.beginAfterRevalidation(
                first: first, second: second, expectedState: state, now: try XCTUnwrap(second.rawResetAt)
            ))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        }
    }

    func testInvalidScheduledEvidenceDoesNotClearTheHoldOrReplaceTheAttempt() throws {
        let cases: [(String, (inout CodexWeeklyTimerObservation, inout CodexWeeklyTimerObservation) -> Void)] = [
            ("fixed reset", { first, second in second.rawResetAt = first.rawResetAt }),
            ("positive tolerance boundary", { first, second in second.rawResetAt = first.rawResetAt?.addingTimeInterval(60) }),
            ("negative tolerance boundary", { first, second in second.rawResetAt = first.rawResetAt?.addingTimeInterval(-60) }),
            ("fractional first usage", { first, _ in first.usedPercent = 0.1 }),
            ("fractional second usage", { _, second in second.usedPercent = 0.1 }),
            ("relative-only first reset", { first, _ in first.rawResetAt = nil }),
            ("relative-only second reset", { _, second in second.rawResetAt = nil }),
            ("expired first reset", { first, _ in first.rawResetAt = first.observedAt.addingTimeInterval(-1) }),
            ("expired second reset", { _, second in second.rawResetAt = second.observedAt.addingTimeInterval(-1) }),
            ("short observation interval", { first, second in second.observedAt = first.observedAt.addingTimeInterval(64.999) }),
            ("duplicate observation timestamp", { first, second in second.observedAt = first.observedAt }),
            ("older second observation", { first, second in second.observedAt = first.observedAt.addingTimeInterval(-1) }),
            ("different second account", { _, second in second.accountKey = "b" }),
        ]
        for (name, mutate) in cases {
            try withStore { store in
                _ = try seedConfirmedWindow(store)
                var (first, second) = observations()
                mutate(&first, &second)
                try observe(first, in: store)
                let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
                try assertRejected(store, first: first, second: second, state: state, message: name)
            }
        }
    }

    func testAnUnacceptedFirstTimestampCannotUseAValidCheckpoint() throws {
        try withStore { store in
            _ = try seedConfirmedWindow(store)
            var (first, second) = observations()
            try observe(first, in: store)
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
            first.observedAt = first.observedAt.addingTimeInterval(1)
            second.observedAt = second.observedAt.addingTimeInterval(1)

            try assertRejected(store, first: first, second: second, state: state)
        }
    }

    func testNewNormalObservationsInvalidateScheduledEvidenceWithoutBeingOverwritten() throws {
        for used: Double? in [0, 0.1, nil] {
            try withStore { store in
                _ = try seedConfirmedWindow(store)
                let (first, second) = observations()
                try observe(first, in: store)
                let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
                _ = try store.observe(
                    accountKey: "a", rawResetAt: used == nil ? nil : first.rawResetAt?.addingTimeInterval(61),
                    observedAt: first.observedAt.addingTimeInterval(61), usedPercent: used ?? 0
                )

                try assertRejected(store, first: first, second: second, state: state)
            }
        }
    }

    func testAnIncomparableAliasReadInvalidatesTheFullCheckpoint() throws {
        try withStore { store in
            _ = try seedConfirmedWindow(store)
            let (first, second) = observations()
            try observe(first, in: store)
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
            let anchor = try store.latestObservationAt(accountKey: "a")

            XCTAssertEqual(try store.observe(
                accountKey: "a", rawResetAt: first.rawResetAt,
                observedAt: first.observedAt.addingTimeInterval(1)
            ), .incomparable)
            XCTAssertEqual(try store.latestObservationAt(accountKey: "a"), anchor)
            XCTAssertFalse(try store.isLatestReceived(first))
            try assertRejected(store, first: first, second: second, state: state)
        }
    }

    func testUpdatingTheSameAttemptInvalidatesTheScheduledCheckpoint() throws {
        try withStore { store in
            _ = try seedConfirmedWindow(store)
            let (first, second) = observations()
            try observe(first, in: store)
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
            var attempt = try XCTUnwrap(store.attempt(for: "a"))
            let originalID = attempt.id
            let originalNotBefore = attempt.notBefore
            attempt.execution = .completed
            attempt.lastVerifiedAt = first.observedAt.addingTimeInterval(1)
            try store.update(accountKey: "a", attempt: attempt)

            XCTAssertEqual(attempt.id, originalID)
            XCTAssertEqual(attempt.notBefore, originalNotBefore)
            try assertRejected(store, first: first, second: second, state: state)
            XCTAssertEqual(try store.attempt(for: "a"), attempt)
        }
    }

    func testChangedConfirmationInvalidatesTheScheduledCheckpoint() throws {
        try withStore { store in
            let oldReset = try seedConfirmedWindow(store)
            let (first, second) = observations()
            try observe(first, in: store)
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
            var saved = try XCTUnwrap(document["observations"] as? [String: [String: Any]])
            let key = try XCTUnwrap(saved.keys.first)
            saved[key]?["confirmedResetAt"] = oldReset.addingTimeInterval(600).timeIntervalSinceReferenceDate
            document["observations"] = saved
            try JSONSerialization.data(withJSONObject: document).write(to: store.fileURL)

            XCTAssertEqual(try store.revalidationState(accountKey: "a", now: first.observedAt)?.confirmedReset,
                           oldReset.addingTimeInterval(600))
            try assertRejected(store, first: first, second: second, state: state)
        }
    }

    func testCheckpointFromAnotherAccountCannotAuthorizeAMatchingPair() throws {
        try withStore { store in
            let (first, _) = observations()
            try observe(first, in: store)
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
            let (otherFirst, otherSecond) = observations(accountKey: "b")
            try observe(otherFirst, in: store)

            try assertRejected(store, first: otherFirst, second: otherSecond, state: state)
            XCTAssertNil(try store.attempt(for: "b"))
        }
    }

    func testChangesToAnotherAccountDoNotInvalidateScheduledEvidence() throws {
        try withStore { store in
            let oldReset = try seedConfirmedWindow(store)
            let (first, second) = observations()
            try observe(first, in: store)
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
            _ = try store.observe(accountKey: "b", rawResetAt: oldReset,
                                  observedAt: first.observedAt.addingTimeInterval(61), usedPercent: 3)

            XCTAssertNotNil(try store.beginAfterRevalidation(
                first: first, second: second, expectedState: state, now: second.observedAt
            ))
            XCTAssertEqual(try store.revalidationState(accountKey: "b", now: second.observedAt)?.confirmedReset, oldReset)
        }
    }

    func testCorruptSavedStateThrowsWithoutReplacingTheFile() throws {
        try withStore { store in
            _ = try seedConfirmedWindow(store)
            let (first, second) = observations()
            try observe(first, in: store)
            let state = try XCTUnwrap(store.revalidationState(accountKey: "a", now: first.observedAt))
            let corrupted = Data("invalid-scheduled-state".utf8)
            try corrupted.write(to: store.fileURL)

            XCTAssertThrowsError(try store.revalidationState(accountKey: "a", now: second.observedAt))
            XCTAssertThrowsError(try store.beginAfterRevalidation(
                first: first, second: second, expectedState: state, now: second.observedAt
            ))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupted)
        }
    }

    private func observations(accountKey: String = "a") -> (CodexWeeklyTimerObservation, CodexWeeklyTimerObservation) {
        let observedAt = start.addingTimeInterval(3_600)
        let reset = start.addingTimeInterval(604_800)
        return (
            .init(accountKey: accountKey, usedPercent: 0, resetsAt: reset, observedAt: observedAt, rawResetAt: reset),
            .init(accountKey: accountKey, usedPercent: 0, resetsAt: reset.addingTimeInterval(65),
                  observedAt: observedAt.addingTimeInterval(65), rawResetAt: reset.addingTimeInterval(65))
        )
    }

    private func seedConfirmedWindow(_ store: CodexWeeklyTimerAttemptStore) throws -> Date {
        let reset = start.addingTimeInterval(3 * 24 * 60 * 60)
        _ = try store.begin(accountKey: "a", resetBefore: reset, now: start)
        _ = try store.observe(accountKey: "a", rawResetAt: reset, observedAt: start, usedPercent: 3)
        return reset
    }

    private func observe(_ observation: CodexWeeklyTimerObservation, in store: CodexWeeklyTimerAttemptStore) throws {
        _ = try store.observe(accountKey: observation.accountKey, rawResetAt: observation.rawResetAt,
                              observedAt: observation.observedAt, usedPercent: observation.usedPercent)
    }

    private func assertRejected(
        _ store: CodexWeeklyTimerAttemptStore, first: CodexWeeklyTimerObservation, second: CodexWeeklyTimerObservation,
        state: CodexWeeklyTimerAttemptStore.RevalidationState, message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let before = try Data(contentsOf: store.fileURL)
        XCTAssertNil(try store.beginAfterRevalidation(
            first: first, second: second, expectedState: state, now: max(first.observedAt, second.observedAt)
        ), message, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before, message, file: file, line: line)
    }

    private func withStore(_ body: (CodexWeeklyTimerAttemptStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(CodexWeeklyTimerAttemptStore(fileURL: directory.appendingPathComponent("attempts.json")))
    }
}
