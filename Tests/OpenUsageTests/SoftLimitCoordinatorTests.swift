import XCTest
@testable import OpenUsage

@MainActor
final class SoftLimitCoordinatorTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    func testSharedNinetyPercentCancelsEveryCodexTaskButNoClaudeTask() async {
        let codex = RecordingSoftLimitAdapter("codex", operations: ["first", "second"])
        let claude = RecordingSoftLimitAdapter("claude", operations: ["untouched"])
        let coordinator = makeCoordinator([codex, claude])
        observe("codex", used: 90, coordinator: coordinator)
        observe("claude", used: 30, coordinator: coordinator)

        await coordinator.check()

        XCTAssertEqual(Set(codex.requests.map(\.operationID)), ["first", "second"])
        XCTAssertEqual(claude.listCalls, 0)
        XCTAssertTrue(claude.requests.isEmpty)
        XCTAssertEqual(coordinator.status(for: "codex").cancelledCount, 2)
        XCTAssertEqual(coordinator.status(for: "claude").phase, .belowLimit)
    }

    func testComparisonUsesRawQuotaInsteadOfRoundedDisplayPercent() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
        let coordinator = makeCoordinator([adapter])
        observe("codex", used: 89.999, coordinator: coordinator)
        await coordinator.check()
        XCTAssertTrue(adapter.requests.isEmpty)

        observe("codex", used: 90, coordinator: coordinator)
        await coordinator.check()
        XCTAssertEqual(adapter.requests.count, 1)
    }

    func testCachedFallbackExpiredAndFutureObservationsNeverCancel() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
        let coordinator = makeCoordinator([adapter])
        for date in [nil, instant.addingTimeInterval(-301), instant.addingTimeInterval(1)] as [Date?] {
            var snapshot = snapshot("codex", used: 100)
            snapshot.liveQuotaObservedAt = date
            coordinator.receive(snapshot, descriptors: [descriptor("codex")])
            await coordinator.check()
        }
        XCTAssertEqual(adapter.listCalls, 0)
        XCTAssertTrue(adapter.requests.isEmpty)
    }

    func testInvalidQuotaWrongWindowAndInactiveAccountNeverCancel() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
        let coordinator = makeCoordinator([adapter])
        for (used, limit, period) in [
            (Double.nan, 100.0, MetricPeriod.weekMs),
            (Double.infinity, 100, MetricPeriod.weekMs),
            (100, 0, MetricPeriod.weekMs),
            (-1, 100, MetricPeriod.weekMs),
            (100, 100, MetricPeriod.sessionMs)
        ] {
            var value = snapshot("codex", used: used)
            value.lines = [.progress(label: "Weekly", used: used, limit: limit, format: .percent, periodDurationMs: period)]
            coordinator.receive(value, descriptors: [descriptor("codex")])
            await coordinator.check()
        }
        coordinator.receive(snapshot("codex@12345678", used: 100), descriptors: [descriptor("codex@12345678")])
        await coordinator.check()
        XCTAssertTrue(adapter.requests.isEmpty)
    }

    func testNewTasksAreCancelledWhileBreachIsFreshWithoutRepeatingFinishedTasks() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
        let coordinator = makeCoordinator([adapter])
        observe("codex", used: 95, coordinator: coordinator)
        await coordinator.check()
        await coordinator.check()
        adapter.tasks.append(.init(providerID: "codex", sessionID: "second-session", operationID: "second"))
        await coordinator.check()

        XCTAssertEqual(adapter.requests.map(\.operationID), ["first", "second"])
    }

    func testOneFailedTaskDoesNotPreventOtherTasksFromBeingCancelled() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first", "second"])
        adapter.failedOperations = ["first"]
        let coordinator = makeCoordinator([adapter])
        observe("codex", used: 90, coordinator: coordinator)

        await coordinator.check()

        XCTAssertEqual(adapter.requests.count, 2)
        XCTAssertEqual(coordinator.status(for: "codex").phase, .failed)
        XCTAssertEqual(coordinator.status(for: "codex").failedCount, 1)
        XCTAssertEqual(coordinator.status(for: "codex").cancelledCount, 1)
    }

    func testDisablingWhileEnumerationIsSuspendedPreventsCancellation() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
        let settings = makeSettings()
        let coordinator = makeCoordinator([adapter], settings: settings)
        adapter.onList = { settings.enabled = false }
        observe("codex", used: 90, coordinator: coordinator)

        await coordinator.check()

        XCTAssertTrue(adapter.requests.isEmpty)
    }

    func testChangingThresholdInvalidatesPreviousObservationUntilFreshSuccess() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
        let settings = makeSettings()
        let coordinator = makeCoordinator([adapter], settings: settings)
        observe("codex", used: 95, coordinator: coordinator)
        settings.thresholdPercent = 94
        await coordinator.check()
        XCTAssertTrue(adapter.requests.isEmpty)

        observe("codex", used: 95, coordinator: coordinator)
        await coordinator.check()
        XCTAssertEqual(adapter.requests.count, 1)
    }

    func testFailedRefreshRevokesPreviouslyFreshBreach() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
        let coordinator = makeCoordinator([adapter])
        observe("codex", used: 95, coordinator: coordinator)
        coordinator.invalidate(providerID: "codex")
        await coordinator.check()
        XCTAssertTrue(adapter.requests.isEmpty)
    }

    func testQuotaObservedBeforeASettingChangeCannotAuthorizeLateCancellation() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
        let settings = makeSettings()
        var current = instant
        let coordinator = SoftLimitCoordinator(
            settings: settings, adapters: [adapter], isProviderEnabled: { _ in true },
            isCancellationScopeVerified: { _ in true }, now: { current }
        )
        settings.onChange = { [weak coordinator] in coordinator?.settingsDidChange() }
        let earlierQuota = snapshot("codex", used: 95)
        current = instant.addingTimeInterval(1)
        settings.thresholdPercent = 94

        coordinator.receive(earlierQuota, descriptors: [descriptor("codex")])
        await coordinator.check()

        XCTAssertEqual(adapter.listCalls, 0)
        XCTAssertTrue(adapter.requests.isEmpty)

        var freshQuota = earlierQuota
        freshQuota.liveQuotaObservedAt = current
        coordinator.receive(freshQuota, descriptors: [descriptor("codex")])
        await coordinator.check()
        XCTAssertEqual(adapter.requests.count, 1)
    }

    func testExpiryAndProviderDisablePreventNewCancellation() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
        let settings = makeSettings()
        var current = instant
        var providerEnabled = true
        let coordinator = SoftLimitCoordinator(settings: settings, adapters: [adapter], isProviderEnabled: { _ in providerEnabled }, isCancellationScopeVerified: { _ in true }, now: { current })
        observe("codex", used: 95, coordinator: coordinator)
        current = instant.addingTimeInterval(300)
        await coordinator.check()
        XCTAssertTrue(adapter.requests.isEmpty)
        current = instant
        providerEnabled = false
        await coordinator.check()
        XCTAssertTrue(adapter.requests.isEmpty)
    }

    func testForeignTaskFromAdapterIsRejectedWithoutAnyCancellation() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
        adapter.tasks.append(.init(providerID: "claude", sessionID: "foreign", operationID: "foreign"))
        let coordinator = makeCoordinator([adapter])
        observe("codex", used: 95, coordinator: coordinator)
        await coordinator.check()
        XCTAssertTrue(adapter.requests.isEmpty)
        XCTAssertEqual(coordinator.status(for: "codex").phase, .failed)
    }

    func testUnsupportedProviderIsNotReportedAsCancelled() async {
        let coordinator = makeCoordinator([])
        observe("claude", used: 95, coordinator: coordinator)
        await coordinator.check()
        XCTAssertEqual(coordinator.status(for: "claude").phase, .unsupported)
        XCTAssertEqual(coordinator.status(for: "claude").cancelledCount, 0)
    }

    func testUnverifiedAccountScopeNeverEnumeratesOrCancels() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["other-account"])
        let coordinator = SoftLimitCoordinator(settings: makeSettings(), adapters: [adapter], isProviderEnabled: { _ in true }, now: { [instant] in instant })
        observe("codex", used: 95, coordinator: coordinator)
        await coordinator.check()
        XCTAssertEqual(adapter.listCalls, 0)
        XCTAssertTrue(adapter.requests.isEmpty)
        XCTAssertEqual(coordinator.status(for: "codex").phase, .unsupported)
    }

    func testAccountScopeRevokedDuringEnumerationPreventsCancellation() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
        var verified = true
        let coordinator = SoftLimitCoordinator(
            settings: makeSettings(), adapters: [adapter], isProviderEnabled: { _ in true },
            isCancellationScopeVerified: { _ in verified }, now: { [instant] in instant }
        )
        adapter.onList = { verified = false }
        observe("codex", used: 95, coordinator: coordinator)

        await coordinator.check()

        XCTAssertEqual(adapter.listCalls, 1)
        XCTAssertTrue(adapter.requests.isEmpty)
        XCTAssertEqual(coordinator.status(for: "codex").phase, .unsupported)
    }

    func testFailedTaskRetriesAreBoundedWithoutRepeatingSuccessfulTasks() async {
        let adapter = RecordingSoftLimitAdapter("codex", operations: ["first", "second"])
        adapter.failedOperations = ["first"]
        var current = instant
        let coordinator = SoftLimitCoordinator(
            settings: makeSettings(), adapters: [adapter], isProviderEnabled: { _ in true },
            isCancellationScopeVerified: { _ in true }, now: { current }
        )
        observe("codex", used: 95, coordinator: coordinator)

        await coordinator.check()
        await coordinator.check()
        XCTAssertEqual(adapter.listCalls, 1, "Failed cancellation must respect the retry delay")
        for _ in 0..<3 {
            current = current.addingTimeInterval(10)
            await coordinator.check()
        }

        XCTAssertEqual(adapter.requests.filter { $0.operationID == "first" }.count, 3)
        XCTAssertEqual(adapter.requests.filter { $0.operationID == "second" }.count, 1)
        XCTAssertEqual(coordinator.status(for: "codex").phase, .failed)
        XCTAssertEqual(coordinator.status(for: "codex").cancelledCount, 1)
        XCTAssertEqual(coordinator.status(for: "codex").failedCount, 1)
    }

    func testAuthenticationAndCredentialBoundariesRevokeFreshBreach() async {
        let changes: [(String, (WidgetDataStore) -> Void)] = [
            ("reauthentication", { $0.invalidateAuthentication(for: "codex") }),
            ("credentials", { _ = $0.credentialsDidChange(for: "codex") }),
            ("reconciliation", { $0.setExternalProviderError("Account reconciliation failed", for: "codex") })
        ]
        for (name, change) in changes {
            let adapter = RecordingSoftLimitAdapter("codex", operations: ["first"])
            let coordinator = makeCoordinator([adapter])
            let metric = descriptor("codex")
            let runtime = TestProviderRuntime(
                provider: .init(id: "codex", displayName: "Codex", icon: .providerMark("codex")),
                descriptors: [metric], snapshot: snapshot("codex", used: 95)
            )
            let suite = "OpenUsageTests.SoftLimitBoundary.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [runtime.provider], descriptors: [metric]),
                providers: [runtime],
                cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
                defaults: defaults
            )
            store.onFreshSnapshot = { coordinator.receive($0, descriptors: $1) }
            store.onQuotaInvalidated = { coordinator.settingsDidChange() }
            await store.refresh(providerID: "codex", force: true)

            change(store)
            await coordinator.check()
            XCTAssertTrue(adapter.requests.isEmpty, name)
            XCTAssertEqual(adapter.listCalls, 0, name)

            await store.refresh(providerID: "codex", force: true)
            await coordinator.check()
            XCTAssertEqual(adapter.requests.count, 1, "Fresh success must rearm after \(name)")
        }
    }

    private func makeSettings() -> SoftLimitSettingsStore {
        let suite = "OpenUsageTests.SoftLimitCoordinator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = SoftLimitSettingsStore(defaults: defaults)
        settings.enabled = true
        return settings
    }

    private func makeCoordinator(_ adapters: [any SoftLimitCancelling], settings: SoftLimitSettingsStore? = nil) -> SoftLimitCoordinator {
        let settings = settings ?? makeSettings()
        let coordinator = SoftLimitCoordinator(settings: settings, adapters: adapters, isProviderEnabled: { _ in true }, isCancellationScopeVerified: { _ in true }, now: { [instant] in instant })
        settings.onChange = { [weak coordinator] in coordinator?.settingsDidChange() }
        return coordinator
    }

    private func snapshot(_ providerID: String, used: Double) -> ProviderSnapshot {
        .init(providerID: providerID, displayName: providerID,
              lines: [.progress(label: "Weekly", used: used, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)],
              refreshedAt: instant, liveQuotaObservedAt: instant)
    }

    private func descriptor(_ providerID: String) -> WidgetDescriptor {
        .percent(id: "\(providerID).weekly", provider: .init(id: providerID, displayName: providerID, icon: .providerMark("codex")), title: "Weekly")
        .supportingSoftLimit(.weekly)
        .exportingLimit("weekly", unit: "percent")
    }

    private func observe(_ providerID: String, used: Double, coordinator: SoftLimitCoordinator) {
        coordinator.receive(snapshot(providerID, used: used), descriptors: [descriptor(providerID)])
    }
}

@MainActor
private final class RecordingSoftLimitAdapter: SoftLimitCancelling {
    let providerID: String
    let coverageNotice = "Fixture connection only."
    var tasks: [SoftLimitTask]
    var requests: [SoftLimitTask] = []
    var listCalls = 0
    var failedOperations: Set<String> = []
    var onList: (@MainActor () async -> Void)?

    init(_ providerID: String, operations: [String]) {
        self.providerID = providerID
        tasks = operations.map { .init(providerID: providerID, sessionID: $0, operationID: $0) }
    }

    func runningTasks() async throws -> [SoftLimitTask] {
        listCalls += 1
        await onList?()
        return tasks
    }

    func cancel(_ task: SoftLimitTask, isAuthorized: @escaping @MainActor () -> Bool) async throws -> SoftLimitCancellationOutcome {
        guard isAuthorized() else { throw CancellationError() }
        requests.append(task)
        if failedOperations.contains(task.operationID) { throw SoftLimitControlError.timedOut }
        return .cancelled
    }

    func disconnect() {}
}
