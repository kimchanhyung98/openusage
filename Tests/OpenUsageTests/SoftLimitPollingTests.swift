import XCTest
@testable import OpenUsage

@MainActor
final class SoftLimitPollingTests: XCTestCase {
    func testDisabledUnverifiedAndBelowLimitStatesNeverSchedulePolling() async throws {
        for state in [State.disabled, .unverified, .providerDisabled, .belowLimit, .missingObservation] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            fixture.settings.enabled = state != .disabled
            fixture.scopeVerified = state != .unverified
            fixture.providerEnabled = state != .providerDisabled
            if state != .missingObservation { fixture.receive(used: state == .belowLimit ? 89 : 95) }
            let slept = expectation(description: "No polling for \(state)")
            slept.isInverted = true
            fixture.sleeper.onSleep = { slept.fulfill() }

            fixture.coordinator.start()
            await fulfillment(of: [slept], timeout: 0.05)

            XCTAssertEqual(fixture.sleeper.calls, 0, "\(state)")
            XCTAssertEqual(fixture.adapter.listCalls, 0, "\(state)")
        }
    }

    func testEnablementRequiresFreshQuotaThenRestartsOnePollingTask() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.settings.enabled = false
        fixture.coordinator.start()
        fixture.settings.enabled = true
        let beforeQuota = expectation(description: "No polling before fresh quota")
        beforeQuota.isInverted = true
        fixture.sleeper.onSleep = { beforeQuota.fulfill() }
        await fulfillment(of: [beforeQuota], timeout: 0.05)

        let started = expectation(description: "Fresh breach starts polling")
        fixture.sleeper.onSleep = { started.fulfill() }
        fixture.receive()
        fixture.coordinator.start()
        fixture.coordinator.start()
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(fixture.sleeper.calls, 1)

        let stopped = expectation(description: "Disabling cancels sleep")
        fixture.sleeper.onCancel = { stopped.fulfill() }
        fixture.settings.enabled = false
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(fixture.sleeper.pendingCount, 0)

        fixture.settings.enabled = true
        let restarted = expectation(description: "New quota restarts polling")
        fixture.sleeper.onSleep = { restarted.fulfill() }
        fixture.receive()
        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(fixture.sleeper.calls, 2)
        XCTAssertEqual(fixture.adapter.listCalls, 0)
    }

    func testPollingChecksNewTasksThenStopsAtQuotaExpiry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.receive()
        let started = expectation(description: "Polling starts")
        fixture.sleeper.onSleep = { started.fulfill() }
        fixture.coordinator.start()
        await fulfillment(of: [started], timeout: 1)

        let repeated = expectation(description: "Polling repeats after checking")
        fixture.sleeper.onSleep = { repeated.fulfill() }
        fixture.sleeper.wake()
        await fulfillment(of: [repeated], timeout: 1)
        XCTAssertEqual(fixture.adapter.listCalls, 1)
        XCTAssertEqual(fixture.adapter.cancelCalls, 1)

        fixture.now = fixture.now.addingTimeInterval(300)
        let noNextSleep = expectation(description: "Expired quota stops polling")
        noNextSleep.isInverted = true
        fixture.sleeper.onSleep = { noNextSleep.fulfill() }
        fixture.sleeper.wake()
        await fulfillment(of: [noNextSleep], timeout: 0.05)
        XCTAssertEqual(fixture.sleeper.pendingCount, 0)
        XCTAssertEqual(fixture.adapter.listCalls, 1)
    }

    func testInvalidationCancelsPollingAndFreshSuccessRearms() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.receive()
        let started = expectation(description: "Polling starts")
        fixture.sleeper.onSleep = { started.fulfill() }
        fixture.coordinator.start()
        await fulfillment(of: [started], timeout: 1)
        let stopped = expectation(description: "Invalidation cancels polling")
        fixture.sleeper.onCancel = { stopped.fulfill() }
        fixture.coordinator.invalidate(providerID: "codex")
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(fixture.sleeper.pendingCount, 0)

        let restarted = expectation(description: "Fresh success rearms")
        fixture.sleeper.onSleep = { restarted.fulfill() }
        fixture.receive()
        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(fixture.sleeper.calls, 2)
    }

    func testScopeAndProviderRevocationStopPollingUntilFreshEligibleQuota() async throws {
        for revokeScope in [true, false] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            fixture.receive()
            let started = expectation(description: "Polling starts")
            fixture.sleeper.onSleep = { started.fulfill() }
            fixture.coordinator.start()
            await fulfillment(of: [started], timeout: 1)

            fixture.scopeVerified = !revokeScope
            fixture.providerEnabled = revokeScope
            let noNextSleep = expectation(description: "Revoked eligibility stops polling")
            noNextSleep.isInverted = true
            fixture.sleeper.onSleep = { noNextSleep.fulfill() }
            fixture.sleeper.wake()
            await fulfillment(of: [noNextSleep], timeout: 0.05)
            XCTAssertEqual(fixture.adapter.listCalls, 0)
            XCTAssertEqual(fixture.sleeper.pendingCount, 0)

            fixture.scopeVerified = true
            fixture.providerEnabled = true
            let restarted = expectation(description: "Fresh eligible quota restarts")
            fixture.sleeper.onSleep = { restarted.fulfill() }
            fixture.receive()
            await fulfillment(of: [restarted], timeout: 1)
        }
    }

    func testStopPreventsRearmingUntilStartedAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.coordinator.start()
        fixture.coordinator.stop()
        let noSleep = expectation(description: "Stopped coordinator does not rearm")
        noSleep.isInverted = true
        fixture.sleeper.onSleep = { noSleep.fulfill() }
        fixture.receive()
        fixture.settings.thresholdPercent = 91
        fixture.receive()
        await fulfillment(of: [noSleep], timeout: 0.05)

        let restarted = expectation(description: "Explicit start rearms")
        fixture.sleeper.onSleep = { restarted.fulfill() }
        fixture.coordinator.start()
        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(fixture.sleeper.calls, 1)
    }

    func testCancelledEnumerationCannotClearReplacementPollingTask() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let gate = Gate()
        let enumerating = expectation(description: "Old polling is enumerating")
        let enumerationReturned = expectation(description: "Old enumeration returns")
        fixture.adapter.onList = { [weak adapter = fixture.adapter] in
            if adapter?.listCalls == 1 {
                enumerating.fulfill()
                await gate.wait()
                enumerationReturned.fulfill()
            }
        }
        fixture.receive()
        let started = expectation(description: "First polling starts")
        fixture.sleeper.onSleep = { started.fulfill() }
        fixture.coordinator.start()
        await fulfillment(of: [started], timeout: 1)
        fixture.sleeper.wake()
        await fulfillment(of: [enumerating], timeout: 1)

        fixture.settings.enabled = false
        fixture.settings.enabled = true
        let replacementStarted = expectation(description: "Replacement polling starts")
        fixture.sleeper.onSleep = { replacementStarted.fulfill() }
        fixture.receive()
        await fulfillment(of: [replacementStarted], timeout: 1)
        gate.open()
        await fulfillment(of: [enumerationReturned], timeout: 1)
        XCTAssertEqual(fixture.adapter.cancelCalls, 0)

        let noDuplicate = expectation(description: "Old task did not clear replacement owner")
        noDuplicate.isInverted = true
        fixture.sleeper.onSleep = { noDuplicate.fulfill() }
        fixture.receive()
        await fulfillment(of: [noDuplicate], timeout: 0.05)
        XCTAssertEqual(fixture.sleeper.calls, 2)
        XCTAssertEqual(fixture.sleeper.pendingCount, 1)

        let checked = expectation(description: "Replacement polling continues")
        fixture.sleeper.onSleep = { checked.fulfill() }
        fixture.sleeper.wake()
        await fulfillment(of: [checked], timeout: 1)
        XCTAssertEqual(fixture.adapter.listCalls, 2)
        XCTAssertEqual(fixture.adapter.cancelCalls, 1)
    }

    private enum State { case disabled, unverified, providerDisabled, belowLimit, missingObservation }

    @MainActor
    private final class Fixture {
        let suite = "OpenUsageTests.SoftLimitPolling.\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: SoftLimitSettingsStore
        let sleeper = Sleeper()
        let adapter = Adapter()
        var scopeVerified = true
        var providerEnabled = true
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        lazy var coordinator: SoftLimitCoordinator = {
            let coordinator = SoftLimitCoordinator(
                settings: settings, adapters: [adapter],
                isProviderEnabled: { [unowned self] _ in providerEnabled },
                isCancellationScopeVerified: { [unowned self] _ in scopeVerified },
                now: { [unowned self] in now },
                pollingSleep: { [sleeper] in try await sleeper.sleep() }
            )
            settings.onChange = { [weak coordinator] in coordinator?.settingsDidChange() }
            return coordinator
        }()

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            settings = SoftLimitSettingsStore(defaults: defaults)
            settings.enabled = true
        }

        func receive(used: Double = 95) {
            let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
            let descriptor = WidgetDescriptor.percent(id: "codex.weekly", provider: provider, title: "Weekly")
                .supportingSoftLimit(.weekly).exportingLimit("weekly", unit: "percent")
            let snapshot = ProviderSnapshot(
                providerID: "codex", displayName: "Codex",
                lines: [.progress(label: "Weekly", used: used, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)],
                refreshedAt: now, liveQuotaObservedAt: now
            )
            coordinator.receive(snapshot, descriptors: [descriptor])
        }

        func cleanUp() {
            sleeper.onSleep = nil
            sleeper.onCancel = nil
            coordinator.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor
    private final class Sleeper {
        var calls = 0
        var onSleep: (() -> Void)?
        var onCancel: (() -> Void)?
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var pendingCount: Int { waiters.count }

        func sleep() async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                calls += 1
                try await withCheckedThrowingContinuation { continuation in
                    waiters[id] = continuation
                    onSleep?()
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, let waiter = waiters.removeValue(forKey: id) else { return }
                    waiter.resume(throwing: CancellationError())
                    onCancel?()
                }
            }
        }

        func wake() {
            let waiting = waiters
            waiters.removeAll()
            for waiter in waiting.values { waiter.resume() }
        }
    }

    @MainActor
    private final class Adapter: SoftLimitCancelling {
        let providerID = "codex"
        let coverageNotice = "Fixture only."
        var listCalls = 0
        var cancelCalls = 0
        var onList: (@MainActor () async -> Void)?
        func runningTasks() async throws -> [SoftLimitTask] {
            listCalls += 1
            await onList?()
            return [.init(providerID: providerID, sessionID: "session", operationID: "turn")]
        }
        func cancel(_ task: SoftLimitTask, isAuthorized: @escaping @MainActor () -> Bool) async throws -> SoftLimitCancellationOutcome {
            guard isAuthorized() else { throw CancellationError() }
            cancelCalls += 1
            return .cancelled
        }
        func disconnect() {}
    }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func open() {
            continuation?.resume()
            continuation = nil
        }
    }
}
