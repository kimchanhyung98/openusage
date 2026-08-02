import Foundation
import XCTest
@testable import OpenUsage

final class KimiCredentialLockTests: XCTestCase {
    func testProductionDefaultsMatchCLIProtocol() {
        XCTAssertEqual(
            KimiCredentialLock.Configuration.production,
            KimiCredentialLock.Configuration(
                staleInterval: 5,
                heartbeatInterval: 2.5,
                acquisitionBudget: 10,
                retryDelay: 0.5
            )
        )
    }

    func testAcquisitionUsesSentinelAndAtomicDirectoryLock() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lock = KimiCredentialLock(configuration: configuration())

        let handle = try await lock.acquire(target: fixture.target)

        var sentinelIsDirectory: ObjCBool = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.path, isDirectory: &sentinelIsDirectory))
        XCTAssertFalse(sentinelIsDirectory.boolValue)
        var lockIsDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.lockURL.path, isDirectory: &lockIsDirectory))
        XCTAssertTrue(lockIsDirectory.boolValue)

        await handle.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lockURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target.path))
    }

    func testSecondAcquirerWaitsWithoutBlockingUntilRelease() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstLock = KimiCredentialLock(configuration: configuration(acquisitionBudget: 0.5))
        let secondLock = KimiCredentialLock(configuration: configuration(acquisitionBudget: 0.5))
        let first = try await firstLock.acquire(target: fixture.target)

        let waiter = Task {
            try await secondLock.acquire(target: fixture.target)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(waiter.isCancelled)
        await first.release()

        let second = try await waiter.value
        let secondIsValid = await second.isValid()
        XCTAssertTrue(secondIsValid)
        await second.release()
    }

    func testHeartbeatRefreshesLockModificationTime() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lock = KimiCredentialLock(configuration: configuration(heartbeatInterval: 0.01))
        let handle = try await lock.acquire(target: fixture.target)
        let before = try modificationDate(fixture.lockURL)

        try await Task.sleep(nanoseconds: 40_000_000)

        let after = try modificationDate(fixture.lockURL)
        XCTAssertGreaterThan(after, before)
        let handleIsValid = await handle.isValid()
        XCTAssertTrue(handleIsValid)
        await handle.release()
    }

    func testHeartbeatContinuesWhileValidatedOperationSuspends() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lock = KimiCredentialLock(configuration: configuration(heartbeatInterval: 0.01))
        let handle = try await lock.acquire(target: fixture.target)
        let before = try modificationDate(fixture.lockURL)

        try await handle.performWhileValid {
            try await Task.sleep(nanoseconds: 40_000_000)
        }

        let after = try modificationDate(fixture.lockURL)
        XCTAssertGreaterThan(after, before)
        let handleIsValid = await handle.isValid()
        XCTAssertTrue(handleIsValid)
        await handle.release()
    }

    func testStaleDirectoryCanBeRecovered() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: fixture.target)
        try FileManager.default.createDirectory(at: fixture.lockURL, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)],
            ofItemAtPath: fixture.lockURL.path
        )
        let lock = KimiCredentialLock(configuration: configuration(staleInterval: 0.01))

        let handle = try await lock.acquire(target: fixture.target)

        let handleIsValid = await handle.isValid()
        XCTAssertTrue(handleIsValid)
        await handle.release()
    }

    func testFreshDirectoryIsNeverStolenBeforeBudgetExpires() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ownerLock = KimiCredentialLock(configuration: configuration(heartbeatInterval: 0.01))
        let contenderLock = KimiCredentialLock(configuration: configuration(
            staleInterval: 1,
            heartbeatInterval: 0.01,
            acquisitionBudget: 0.04,
            retryDelay: 0.005
        ))
        let owner = try await ownerLock.acquire(target: fixture.target)

        do {
            _ = try await contenderLock.acquire(target: fixture.target)
            XCTFail("expected lock acquisition to time out")
        } catch {
            XCTAssertEqual(error as? KimiAuthError, .credentialLockUnavailable)
        }

        let ownerIsValid = await owner.isValid()
        XCTAssertTrue(ownerIsValid)
        await owner.release()
    }

    func testWaitingAcquisitionHonorsCancellation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ownerLock = KimiCredentialLock(configuration: configuration(acquisitionBudget: 1))
        let waiterLock = KimiCredentialLock(configuration: configuration(acquisitionBudget: 1))
        let owner = try await ownerLock.acquire(target: fixture.target)
        let waiter = Task {
            try await waiterLock.acquire(target: fixture.target)
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let ownerIsValid = await owner.isValid()
        XCTAssertTrue(ownerIsValid)
        await owner.release()
    }

    func testExternalModificationMarksHandleCompromised() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lock = KimiCredentialLock(configuration: configuration(heartbeatInterval: 10))
        let handle = try await lock.acquire(target: fixture.target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: fixture.lockURL.path
        )

        let handleIsValid = await handle.isValid()
        let released = await handle.release()
        XCTAssertFalse(handleIsValid)
        XCTAssertFalse(released)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    func testReleaseLeavesReplacementObservedBeforeRemoval() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lock = KimiCredentialLock(configuration: configuration(heartbeatInterval: 10))
        let handle = try await lock.acquire(target: fixture.target)
        try FileManager.default.removeItem(at: fixture.lockURL)
        try FileManager.default.createDirectory(at: fixture.lockURL, withIntermediateDirectories: false)

        let firstRelease = await handle.release()
        let secondRelease = await handle.release()
        XCTAssertFalse(firstRelease)
        XCTAssertFalse(secondRelease)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.lockURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testValidatedOperationRejectsAReplacedLockBeforeWriting() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lock = KimiCredentialLock(configuration: configuration(heartbeatInterval: 10))
        let handle = try await lock.acquire(target: fixture.target)
        try FileManager.default.removeItem(at: fixture.lockURL)
        try FileManager.default.createDirectory(at: fixture.lockURL, withIntermediateDirectories: false)

        do {
            try await handle.performWhileValid { throw KimiLockTestError.operationExecuted }
            XCTFail("expected compromised lock rejection")
        } catch {
            XCTAssertEqual(error as? KimiAuthError, .credentialLockCompromised)
        }

        let released = await handle.release()
        XCTAssertFalse(released)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    func testExistingNonRegularSentinelIsRejected() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.target,
            withIntermediateDirectories: true
        )
        let lock = KimiCredentialLock(configuration: configuration())

        do {
            _ = try await lock.acquire(target: fixture.target)
            XCTFail("expected invalid sentinel rejection")
        } catch {
            XCTAssertEqual(error as? KimiAuthError, .credentialLockUnavailable)
        }
    }

    private func makeFixture() throws -> (root: URL, target: URL, lockURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-kimi-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("oauth/kimi-code")
        return (root, target, URL(fileURLWithPath: target.path + ".lock"))
    }

    private func configuration(
        staleInterval: TimeInterval = 1,
        heartbeatInterval: TimeInterval = 0.1,
        acquisitionBudget: TimeInterval = 0.2,
        retryDelay: TimeInterval = 0.005
    ) -> KimiCredentialLock.Configuration {
        KimiCredentialLock.Configuration(
            staleInterval: staleInterval,
            heartbeatInterval: heartbeatInterval,
            acquisitionBudget: acquisitionBudget,
            retryDelay: retryDelay
        )
    }

    private func modificationDate(_ url: URL) throws -> Date {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )
    }
}

private enum KimiLockTestError: Error {
    case operationExecuted
}
