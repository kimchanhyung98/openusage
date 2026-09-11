import Foundation
import XCTest
@testable import OpenUsage
@testable import PostHog

@MainActor
final class TelemetrySDKIntegrationTests: XCTestCase {
    private func makeSink(
        enabled: Bool = false, token: String, consentStart: @escaping () -> Date = Date.init
    ) -> PostHogTelemetrySink {
        PostHogTelemetrySink(
            enabled: enabled, token: token, host: "https://telemetry-fixture.invalid",
            crashConsentStartedAt: consentStart,
            sessionConfiguration: {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [TelemetryFixtureURLProtocol.self]
                return config
            },
            flushInterval: 0.1
        )
    }

    func testReenableUsesThePersistedConsentBoundaryForCrashFiltering() async throws {
        TelemetryFixtureURLProtocol.reset()
        var consentStart = Date().addingTimeInterval(-3600)
        let sink = makeSink(
            enabled: true, token: "phc_fixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            consentStart: { consentStart }
        )
        defer { sink.setEnabled(false) }
        sink.setEnabled(false)
        consentStart = Date().addingTimeInterval(3600)
        sink.setEnabled(true)
        sink.capture("$exception", ["$exception_list": [["type": "SIGABRT"]]])
        sink.capture("provider_refresh_daily", ["provider_id": "claude", "success_count": 1])
        sink.flush()
        try await waitForBatch()

        let events = try TelemetryFixtureURLProtocol.events()
        XCTAssertEqual(events.compactMap { $0["event"] as? String }, ["provider_refresh_daily"])
    }

    func testDisabledInitializationDoesNotStartSDKNetworking() async throws {
        TelemetryFixtureURLProtocol.reset()
        let sink = makeSink(token: "phc_fixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        sink.capture("app_daily_active", [:])
        sink.flush()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(TelemetryFixtureURLProtocol.requests.isEmpty)
        XCTAssertFalse(sink.isAvailable)
    }

    func testOptOutDropsQueuedEventsAndReenableDoesNotReplayThem() async throws {
        TelemetryFixtureURLProtocol.reset()
        let token = "phc_fixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sink = makeSink(enabled: true, token: token)
        defer { sink.setEnabled(false) }
        sink.capture("provider_refresh_daily", ["provider_id": "claude", "success_count": 77])
        sink.setEnabled(false)
        sink.flush()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(TelemetryFixtureURLProtocol.batches.isEmpty)

        sink.setEnabled(true)
        sink.capture("provider_refresh_daily", ["provider_id": "claude", "success_count": 1])
        sink.flush()
        try await waitForBatch()
        let events = try TelemetryFixtureURLProtocol.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual((events.first?["properties"] as? [String: Any])?["success_count"] as? Int, 1)
        XCTAssertTrue(TelemetryFixtureURLProtocol.requests.allSatisfy {
            $0.headers[TelemetryURLProtocol.sessionHeader] == nil
        })
    }

    func testActualSDKPayloadDropsAccountIDsAndUnexpectedNestedProperties() async throws {
        TelemetryFixtureURLProtocol.reset()
        let sink = makeSink(enabled: true, token: "phc_fixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        defer { sink.setEnabled(false) }
        sink.capture("provider_refresh_daily", [
            "provider_id": "claude@profile-private", "success_count": 1,
            "app_version": "0.7.99", "build_channel": "beta", "day": "2026-09-01",
            "error_categories": ["network": 1, "private@example.com": 4],
            "error_message": "OPAQUE_PRIVATE_VALUE", "nested": ["token": "OPAQUE_PRIVATE_VALUE"],
        ])
        sink.flush()
        try await waitForBatch()
        let events = try TelemetryFixtureURLProtocol.events()
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        XCTAssertEqual(properties["provider_id"] as? String, "claude")
        XCTAssertEqual(properties["error_categories"] as? [String: Int], ["network": 1])
        XCTAssertEqual(properties["app_version"] as? String, "0.7.99")
        XCTAssertEqual(properties["build_channel"] as? String, "beta")
        XCTAssertEqual(properties["day"] as? String, "2026-09-01")
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: events), as: UTF8.self)
        for forbidden in ["profile-private", "private@example.com", "OPAQUE_PRIVATE_VALUE"] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }

    func testRejectedBatchIsNotRetriedAfterOptOutOrRestart() async throws {
        TelemetryFixtureURLProtocol.reset(status: 503)
        let token = "phc_fixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sink = makeSink(enabled: true, token: token)
        sink.capture("provider_refresh_daily", ["provider_id": "codex", "failure_count": 77])
        sink.flush()
        try await waitForBatch()
        sink.setEnabled(false)
        let before = TelemetryFixtureURLProtocol.batches.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(TelemetryFixtureURLProtocol.batches.count, before)

        TelemetryFixtureURLProtocol.reset()
        let restarted = makeSink(enabled: true, token: token)
        defer { restarted.setEnabled(false) }
        restarted.capture("provider_refresh_daily", ["provider_id": "codex", "success_count": 1])
        restarted.flush()
        try await waitForBatch()
        let events = try TelemetryFixtureURLProtocol.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertNil((events.first?["properties"] as? [String: Any])?["failure_count"])
    }

    func testExceptionPayloadIsRedactedAtTheActualSDKBoundary() async throws {
        TelemetryFixtureURLProtocol.reset()
        let sink = makeSink(enabled: true, token: "phc_fixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        defer { sink.setEnabled(false) }
        let uuid = UUID().uuidString
        sink.capture("$exception", [
            "$exception_list": [["type": "SIGABRT", "value": "OPAQUE_PRIVATE_VALUE",
                "stacktrace": ["frames": [["instruction_addr": "0x1234", "function": "OPAQUE_PRIVATE_VALUE"]]]]],
            "$debug_images": [["debug_id": uuid, "image_addr": "0x1000", "code_file": "/Users/private/OpenUsage"]],
            "$exception_steps": [["message": "OPAQUE_PRIVATE_VALUE"]],
        ])
        sink.flush()
        try await waitForBatch()
        let events = try TelemetryFixtureURLProtocol.events()
        XCTAssertEqual(events.count, 1)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: events), as: UTF8.self)
        XCTAssertTrue(encoded.contains(uuid))
        XCTAssertTrue(encoded.contains("0x1234"))
        for forbidden in ["OPAQUE_PRIVATE_VALUE", "/Users/private", "openusage_consent_id", "openusage_crash_"] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }

    func testPrivacyMigrationRemovesOnlySDKQueuesAndRunsOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TelemetrySDKStorage(token: "phc_fixture", root: root)
        let queue = storage.project.appendingPathComponent("posthog.queueFolder.uuid")
        let legacyQueue = root.appendingPathComponent("posthog.queue.plist")
        let retained = root.appendingPathComponent("unrelated.json")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try Data("old-secret".utf8).write(to: queue.appendingPathComponent("event"))
        try Data("old-secret".utf8).write(to: legacyQueue)
        try Data("keep".utf8).write(to: retained)
        try storage.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyQueue.path))
        XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "keep")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: queue.appendingPathComponent("event"))
        try storage.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.path))
        try storage.discardQueues()
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }

    func testRevokedTransportCannotStartARequestUsingItsOldSession() async throws {
        TelemetryFixtureURLProtocol.reset()
        let upstream = URLSessionConfiguration.ephemeral
        upstream.protocolClasses = [TelemetryFixtureURLProtocol.self]
        let transport = TelemetryTransport(configuration: upstream)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TelemetryURLProtocol.self]
        config.httpAdditionalHeaders = [TelemetryURLProtocol.sessionHeader: transport.id]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        transport.revoke()
        do {
            _ = try await session.data(from: URL(string: "https://telemetry-fixture.invalid/batch")!)
            XCTFail("revoked transport must reject a queued request")
        } catch {
            XCTAssertTrue(TelemetryFixtureURLProtocol.requests.isEmpty)
        }
    }

    private func waitForBatch() async throws {
        for _ in 0..<100 {
            if !TelemetryFixtureURLProtocol.batches.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("SDK did not send a batch to the isolated fixture")
    }
}

private final class TelemetryFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let body: Data
        let headers: [String: String]
    }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [Request] = []
    private nonisolated(unsafe) static var status = 200
    static var requests: [Request] { lock.withLock { recorded } }
    static var batches: [Request] { requests.filter { $0.path == "/batch" || $0.path == "/batch/" } }
    static func reset(status: Int = 200) {
        lock.withLock { recorded = []; self.status = status }
    }
    static func events() throws -> [[String: Any]] {
        try batches.flatMap { request in
            let body = request.headers["Content-Encoding"] == "gzip" ? try request.body.gunzipped() : request.body
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            return json?["batch"] as? [[String: Any]] ?? []
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "telemetry-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let status = Self.lock.withLock {
            Self.recorded.append(Request(path: request.url!.path, body: body, headers: request.allHTTPHeaderFields ?? [:]))
            return Self.status
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"errorTracking":{"autocaptureExceptions":false},"status":1}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
