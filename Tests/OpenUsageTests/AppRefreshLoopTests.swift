import XCTest
@testable import OpenUsage

@MainActor
final class AppRefreshLoopTests: XCTestCase {
    func testCancellationDuringReconciliationDoesNotStartUsageOrStatus() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let entered = expectation(description: "Reconciliation started")
        let gate = Gate()
        let http = StatusHTTP()
        let status = ProviderStatusStore(http: http)
        let loop = AppRefreshLoop.start(
            dataStore: fixture.dataStore, providerStatus: status, telemetry: fixture.telemetry,
            enabledProviderIDs: { ["claude"] },
            reconcileAccounts: { entered.fulfill(); await gate.wait() }
        )
        await fulfillment(of: [entered], timeout: 2)
        loop.cancel()
        gate.open()
        await loop.value

        XCTAssertEqual(fixture.runtime.refreshCount, 0)
        let requests = await http.requestCount
        XCTAssertEqual(requests, 0)
        XCTAssertNil(fixture.dataStore.lastRefreshAt)
    }

    func testUsageAndStatusStartInParallelAndOwnerCancellationStopsStatus() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let usageStarted = expectation(description: "Usage started")
        let statusStarted = expectation(description: "Status started")
        let statusCancelled = expectation(description: "Status cancelled")
        let usageGate = Gate()
        fixture.runtime.onRefresh = { usageStarted.fulfill(); await usageGate.wait() }
        let http = StatusHTTP(
            blocks: true,
            onRequest: { statusStarted.fulfill() },
            onCancel: { statusCancelled.fulfill() }
        )
        let status = ProviderStatusStore(http: http)
        let loop = AppRefreshLoop.start(
            dataStore: fixture.dataStore, providerStatus: status, telemetry: fixture.telemetry,
            enabledProviderIDs: { ["claude", "claude@work"] }, reconcileAccounts: {}
        )
        await fulfillment(of: [usageStarted, statusStarted], timeout: 2)
        usageGate.open()
        loop.cancel()
        await fulfillment(of: [statusCancelled], timeout: 2)
        await loop.value

        let requests = await http.requestCount
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(status.status(for: "claude"), .unknown)
        XCTAssertNil(fixture.dataStore.errorMessage(for: "claude"))
    }

    func testEnablementWakeRechecksStatusFamiliesWithoutPollingDisabledOnes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let firstPass = expectation(description: "Initial pass")
        let secondPass = expectation(description: "Enablement pass")
        let requested = expectation(description: "Enabled status requested")
        let center = NotificationCenter()
        let wake = RefreshWakeSignal(center: center)
        let http = StatusHTTP(onRequest: { requested.fulfill() })
        let status = ProviderStatusStore(http: http)
        var enabled: [String] = []
        var passes = 0
        fixture.dataStore.onLocalHistoryChanged = { firstPass.fulfill() }
        let loop = AppRefreshLoop.start(
            dataStore: fixture.dataStore, providerStatus: status, telemetry: fixture.telemetry,
            enabledProviderIDs: { enabled },
            reconcileAccounts: {
                passes += 1
                if passes == 2 { secondPass.fulfill() }
            },
            wakeSignal: wake
        )
        await fulfillment(of: [firstPass], timeout: 2)
        let before = await http.requestCount
        XCTAssertEqual(before, 0)
        enabled = ["claude", "claude@work", "grok"]
        center.post(name: ProviderEnablementStore.didChangeNotification, object: nil)
        await fulfillment(of: [secondPass, requested], timeout: 2)
        loop.cancel()
        await loop.value

        let after = await http.requestCount
        XCTAssertEqual(after, 1)
        XCTAssertEqual(passes, 2)
    }

    func testStatusFailureDoesNotBecomeAUsageErrorOrChangeTheUsageSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let usageFinished = expectation(description: "Usage batch finished")
        let statusStarted = expectation(description: "Status requested")
        fixture.dataStore.onLocalHistoryChanged = { usageFinished.fulfill() }
        let http = StatusHTTP(onRequest: { statusStarted.fulfill() })
        let status = ProviderStatusStore(http: http)
        let loop = AppRefreshLoop.start(
            dataStore: fixture.dataStore, providerStatus: status, telemetry: fixture.telemetry,
            enabledProviderIDs: { ["claude"] }, reconcileAccounts: {}
        )
        await fulfillment(of: [usageFinished, statusStarted], timeout: 2)
        await status.refresh(providerIDs: ["claude"])
        loop.cancel()
        await loop.value

        XCTAssertEqual(status.status(for: "claude"), .unknown)
        XCTAssertTrue(fixture.dataStore.providerErrors.isEmpty)
        XCTAssertNotNil(fixture.dataStore.snapshots["claude"])
        XCTAssertNotNil(fixture.dataStore.lastRefreshAt)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)
        let requests = await http.requestCount
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    private final class Fixture {
        let suite = "OpenUsageTests.RefreshLoop.\(UUID().uuidString)"
        let defaults: UserDefaults
        let runtime = Runtime()
        let dataStore: WidgetDataStore
        let telemetry: TelemetryRecorder

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            dataStore = WidgetDataStore(
                registry: WidgetRegistry(providers: [runtime.provider], descriptors: []),
                providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults
            )
            telemetry = TelemetryRecorder(sink: Sink(), store: TelemetryStore(defaults: defaults), snapshot: {
                TelemetryConfigSnapshot(
                    enabledProviders: [], enabledMetricIDs: [], pinnedMetricIDs: [], expandedMetricIDs: [], menuBarStyle: "text"
                )
            })
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }

    @MainActor
    private final class Gate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class Runtime: ProviderRuntime {
        let provider = MockData.claude
        let widgetDescriptors: [WidgetDescriptor] = []
        var refreshCount = 0
        var onRefresh: @MainActor () async -> Void = {}
        func hasLocalCredentials() async -> Bool { false }
        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            await onRefresh()
            return ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        }
    }

    private actor StatusHTTP: HTTPClient {
        let blocks: Bool
        let onRequest: @Sendable () -> Void
        let onCancel: @Sendable () -> Void
        private(set) var requestCount = 0
        init(
            blocks: Bool = false,
            onRequest: @escaping @Sendable () -> Void = {},
            onCancel: @escaping @Sendable () -> Void = {}
        ) {
            self.blocks = blocks
            self.onRequest = onRequest
            self.onCancel = onCancel
        }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            requestCount += 1
            onRequest()
            if blocks {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { onCancel(); throw error }
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
    }

    private final class Sink: TelemetrySink {
        func capture(_ event: String, _ properties: [String: Any]) {}
        func setEnabled(_ enabled: Bool) {}
        func flush() {}
    }
}
