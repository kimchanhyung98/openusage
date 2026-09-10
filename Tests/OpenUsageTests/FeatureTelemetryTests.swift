import XCTest
@testable import OpenUsage

@MainActor
final class FeatureTelemetryTests: XCTestCase {
    private final class Sink: TelemetrySink {
        var isAvailable = true
        var events: [(String, [String: Any])] = []
        func capture(_ event: String, _ properties: [String: Any]) { events.append((event, properties)) }
        func setEnabled(_ enabled: Bool) {}
        func flush() {}
        func events(_ name: String) -> [[String: Any]] { events.filter { $0.0 == name }.map(\.1) }
    }
    private final class Clock { var value = Date(timeIntervalSince1970: 1_780_000_000) }
    @MainActor
    private final class Fixture {
        let suite = "FeatureTelemetryTests." + UUID().uuidString
        let store: TelemetryStore
        let defaults: UserDefaults
        let sink = Sink()
        let clock = Clock()
        let recorder: TelemetryRecorder
        init() {
            defaults = UserDefaults(suiteName: suite)!
            store = TelemetryStore(defaults: defaults)
            store.enabled = true
            let sink = self.sink, clock = self.clock
            recorder = TelemetryRecorder(sink: sink, store: store, snapshot: {
                TelemetryConfigSnapshot(enabledProviders: ["claude"], enabledMetricIDs: [], pinnedMetricIDs: [], expandedMetricIDs: [], menuBarStyle: "text")
            }, now: { clock.value })
        }
        func cleanUp() { recorder.stopDiagnostics(); defaults.removePersistentDomain(forName: suite) }
    }

    func testRepeatedFailureIsImmediateOnceAndDailyCounterRetainsEveryOccurrence() {
        let f = Fixture()
        defer { f.cleanUp() }
        for _ in 0..<10 {
            f.recorder.recordDiagnostic(DiagnosticEvent(.accountReconcile, result: .failure, category: .credentialAccess, providerID: "claude@profile-A"))
        }
        XCTAssertEqual(f.sink.events("feature_operation_result").count, 1)
        f.clock.value = f.clock.value.addingTimeInterval(86400)
        f.recorder.tick()
        let rollups = f.sink.events("feature_operation_daily")
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups.first?["count"] as? Int, 10)
        XCTAssertEqual(rollups.first?["provider_id"] as? String, "claude")
    }

    func testRecoveryIsReportedWithoutTreatingEverySuccessAsAnAlert() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.recorder.recordDiagnostic(DiagnosticEvent(.tokscaleSubmit, result: .success))
        XCTAssertTrue(f.sink.events("feature_operation_result").isEmpty)
        f.recorder.recordDiagnostic(DiagnosticEvent(.tokscaleSubmit, result: .failure, category: .subprocess))
        f.recorder.recordDiagnostic(DiagnosticEvent(.tokscaleSubmit, result: .success))
        f.recorder.recordDiagnostic(DiagnosticEvent(.tokscaleSubmit, result: .success))
        XCTAssertEqual(f.sink.events("feature_operation_result").compactMap { $0["result"] as? String }, ["failure", "recovered"])
    }

    func testOneAccountSuccessCannotDeclareAnotherAccountRecovered() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.recorder.record(providerID: "claude@profile-A", outcome: .failed, category: .network, trigger: .scheduled)
        f.recorder.record(providerID: "claude@profile-B", outcome: .refreshed, category: nil, trigger: .scheduled)
        XCTAssertEqual(f.sink.events("feature_operation_result").compactMap { $0["result"] as? String }, ["failure"])
    }

    func testCursorOptionalSuccessCannotDeclareAPreviousAccountRecovered() {
        let f = Fixture()
        defer { f.cleanUp() }
        let operations: [DiagnosticOperation] = [.cursorPlan, .cursorCredits, .cursorBalance, .cursorSummary, .cursorFallback]
        for operation in operations {
            f.recorder.recordDiagnostic(DiagnosticEvent(operation, result: .degraded, category: .network, providerID: "cursor"))
            f.recorder.recordDiagnostic(DiagnosticEvent(operation, result: .success, providerID: "cursor"))
        }
        let results = f.sink.events("feature_operation_result").compactMap { $0["result"] as? String }
        XCTAssertEqual(results, Array(repeating: "degraded", count: operations.count))
    }

    func testNormalMissingLoginDoesNotCreateARecoveryAlert() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.recorder.recordDiagnostic(DiagnosticEvent(.tokscaleSubmit, result: .failure, category: .notLoggedIn))
        f.recorder.recordDiagnostic(DiagnosticEvent(.tokscaleSubmit, result: .success))
        XCTAssertTrue(f.sink.events("feature_operation_result").isEmpty)
    }

    func testImmediateDiagnosticCapAndExpectedErrors() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.recorder.recordDiagnostic(DiagnosticEvent(.accountSignIn, result: .cancelled))
        f.recorder.recordDiagnostic(DiagnosticEvent(.providerRefresh, result: .failure, category: .notLoggedIn, providerID: "codex"))
        XCTAssertTrue(f.sink.events("feature_operation_result").isEmpty)
        for operation in DiagnosticOperation.allCases {
            f.recorder.recordDiagnostic(DiagnosticEvent(operation, result: .failure, category: .network))
        }
        XCTAssertEqual(f.sink.events("feature_operation_result").count, 30)
        XCTAssertGreaterThan(f.store.featureCounters().count, 30)
    }

    func testQueuedDiagnosticCannotCrossAnOffOnConsentBoundary() async {
        let f = Fixture()
        defer { f.cleanUp() }
        f.recorder.startDiagnostics()
        AppDiagnostics.record(.accountSwitch, result: .failure, category: .storage)
        let oldConsent = f.store.consentID
        f.recorder.setEnabled(false)
        f.recorder.setEnabled(true)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(f.sink.events("feature_operation_result").isEmpty)
        XCTAssertTrue(f.store.featureCounters().isEmpty)
        XCTAssertNotEqual(f.store.consentID, oldConsent)
    }

    func testUnavailableSinkRetainsCountersAndDoesNotConsumeActiveDay() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.sink.isAvailable = false
        f.recorder.record(providerID: "claude", outcome: .refreshed, category: nil, trigger: .scheduled)
        f.clock.value = f.clock.value.addingTimeInterval(86400)
        f.recorder.tick()
        XCTAssertNil(f.store.activeDay)
        XCTAssertFalse(f.store.providerCounters().isEmpty)
        f.sink.isAvailable = true
        f.recorder.tick()
        XCTAssertEqual(f.sink.events("provider_refresh_daily").count, 1)
    }

    func testLocalFailureDetailsNeverEnterImmediateOrDailyTelemetry() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.recorder.startDiagnostics()
        AppDiagnostics.failure(
            .accountSwitch,
            error: NSError(domain: "PRIVATE_ERROR_DOMAIN", code: 314,
                           userInfo: [NSLocalizedDescriptionKey: "PRIVATE_ERROR_DESCRIPTION"]),
            providerID: "claude@profile-private",
            localContext: "PRIVATE_LOCAL_CONTEXT"
        )
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.sink.events("feature_operation_result").count, 1)
        XCTAssertEqual(f.store.featureCounters().values.reduce(0) { $0 + $1.count }, 1)
        f.clock.value = f.clock.value.addingTimeInterval(86400)
        f.recorder.tick()
        XCTAssertEqual(f.sink.events("feature_operation_daily").count, 1)
        for name in ["feature_operation_result", "feature_operation_daily"] {
            let event = try XCTUnwrap(f.sink.events(name).first)
            XCTAssertEqual(event["provider_id"] as? String, "claude")
            let json = String(decoding: try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
            for value in ["PRIVATE_ERROR_DOMAIN", "PRIVATE_ERROR_DESCRIPTION", "PRIVATE_LOCAL_CONTEXT", "profile-private", "error_code"] {
                XCTAssertFalse(json.contains(value), json)
            }
        }
    }

    func testFailureOnlyOperationsDoNotRetainSharedRecoveryState() {
        let f = Fixture()
        defer { f.cleanUp() }
        for operation in [DiagnosticOperation.iCloudIdentity, .localAPIRequest] {
            f.recorder.recordDiagnostic(DiagnosticEvent(operation, result: .failure, category: .permission))
            XCTAssertTrue(f.store.featureFailures.isEmpty)
            f.recorder.recordDiagnostic(DiagnosticEvent(operation, result: .success))
        }
        XCTAssertEqual(f.sink.events("feature_operation_result").compactMap { $0["result"] as? String }, ["failure", "failure"])
    }

    func testForcedAccountSelectionAndClaimRefreshAreNotManual() async {
        let f = Fixture()
        defer { f.cleanUp() }
        let runtime = Runtime()
        let store = WidgetDataStore(registry: WidgetRegistry.from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: f.defaults, storageKey: "snapshots"), defaults: f.defaults)
        store.onRefreshOutcome = { id, outcome, category, trigger, degraded in
            f.recorder.record(providerID: id, outcome: outcome, category: category, trigger: trigger, degraded: degraded)
        }
        await store.refreshAfterAccountSelection(providerID: "claude", maxAttempts: 1)
        await store.refreshAfterClaim(providerID: "claude", maxAttempts: 1)
        await store.refresh(providerID: "claude", force: true, trigger: .manual)
        f.clock.value = f.clock.value.addingTimeInterval(86400)
        f.recorder.tick()
        let rollup = f.sink.events("provider_refresh_daily").first
        XCTAssertEqual(rollup?["manual_refresh_count"] as? Int, 1)
        XCTAssertEqual(rollup?["trigger_counts"] as? [String: Int], ["account_change": 1, "reset_claim": 1, "manual": 1])
    }

    private final class Runtime: ProviderRuntime {
        let provider = MockData.claude
        let widgetDescriptors: [WidgetDescriptor] = []
        func hasLocalCredentials() async -> Bool { true }
        func refresh() async -> ProviderSnapshot {
            ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        }
    }
}
