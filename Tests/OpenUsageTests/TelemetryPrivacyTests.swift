import XCTest
@testable import OpenUsage

final class TelemetryPrivacyTests: XCTestCase {
    @MainActor
    func testAllCurrentProviderMetricsPassTheAllowlist() {
        for runtime in ProviderCatalog.make() {
            XCTAssertEqual(TelemetryPrivacy.providerFamily(runtime.provider.id), runtime.provider.id)
            for descriptor in runtime.widgetDescriptors {
                XCTAssertEqual(TelemetryPrivacy.metricID(descriptor.id), descriptor.id)
            }
        }
    }

    func testCrashMustBelongToTheCurrentConsentEvenWhenTheClockMovesBackwards() {
        let since = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(PostHogTelemetrySink.crashBelongsToConsent(properties: ["openusage_consent_id": "current"], timestamp: since, consentID: "current", since: since))
        XCTAssertFalse(PostHogTelemetrySink.crashBelongsToConsent(properties: ["openusage_consent_id": "old"], timestamp: since.addingTimeInterval(500), consentID: "current", since: since))
        XCTAssertFalse(PostHogTelemetrySink.crashBelongsToConsent(properties: ["openusage_consent_id": "current"], timestamp: since.addingTimeInterval(-1), consentID: "current", since: since))
        XCTAssertFalse(PostHogTelemetrySink.crashBelongsToConsent(properties: [:], timestamp: since, consentID: "current", since: since))
    }

    func testNativeCrashUsesSecondPrecisionWithinTheCurrentConsent() {
        let since = Date(timeIntervalSince1970: 1000.5)
        let timestamp = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(PostHogTelemetrySink.crashBelongsToConsent(properties: ["openusage_consent_id": "current"], timestamp: timestamp, consentID: "current", since: since))
        XCTAssertFalse(PostHogTelemetrySink.crashBelongsToConsent(properties: ["openusage_consent_id": "old"], timestamp: timestamp, consentID: "current", since: since))
        XCTAssertFalse(PostHogTelemetrySink.crashBelongsToConsent(properties: ["openusage_consent_id": "current"], timestamp: timestamp.addingTimeInterval(-1), consentID: "current", since: since))
    }

    func testCrashRedactionRetainsSymbolicationAddressesAndUUIDOnly() throws {
        let uuid = UUID().uuidString
        let properties = try XCTUnwrap(TelemetryPrivacy.properties(for: "$exception", source: [
            "account": "private@example.com", "$exception_steps": [["message": "OPAQUE_PRIVATE_VALUE"]],
            "$exception_list": [[
                "type": "NSInvalidArgumentException", "value": "private@example.com at /Users/private/file",
                "stacktrace": ["frames": [[
                    "instruction_addr": "0x1234", "image_addr": "0x1000", "in_app": true,
                    "function": "OPAQUE_PRIVATE_VALUE", "abs_path": "/Users/private/file",
                ]]],
                "mechanism": ["type": "nsexception", "handled": false, "data": "OPAQUE_PRIVATE_VALUE"],
            ]],
            "$debug_images": [["debug_id": uuid, "image_addr": "0x1000", "code_file": "/Users/private/OpenUsage", "arch": "arm64"]],
        ]))
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: properties), as: UTF8.self)
        XCTAssertTrue(encoded.contains(uuid))
        XCTAssertTrue(encoded.contains("0x1234"))
        XCTAssertTrue(encoded.contains("NSInvalidArgumentException"))
        for value in ["private@example.com", "OPAQUE_PRIVATE_VALUE", "/Users/private"] {
            XCTAssertFalse(encoded.contains(value), value)
        }
    }

    func testUnknownEventAndFreeFormCrashTypeAreNotForwarded() throws {
        XCTAssertNil(TelemetryPrivacy.properties(for: "private@example.com", source: [:]))
        let properties = try XCTUnwrap(TelemetryPrivacy.properties(for: "$exception", source: [
            "$exception_list": [["type": "private@example.com", "value": "secret"]],
        ]))
        XCTAssertEqual((properties["$exception_list"] as? [[String: Any]])?.first?["type"] as? String, "NativeException")
    }

    func testVersionAllowsBetaDevelopmentBuildsButRejectsFreeText() {
        let properties = TelemetryPrivacy.properties(for: "app_daily_active", source: [
            "app_version": "0.11.2-beta.1-dev", "os_version": "private@example.com",
        ])
        XCTAssertEqual(properties?["app_version"] as? String, "0.11.2-beta.1-dev")
        XCTAssertNil(properties?["os_version"])
    }

    func testUnresolvedAccountMetricStillCollapsesWithoutRegistryLookup() throws {
        let properties = try XCTUnwrap(TelemetryPrivacy.properties(for: "app_daily_active", source: [
            "enabled_providers": ["claude@profile-A", "claude@profile-B", "unknown@example.com"],
            "enabled_metric_ids": ["claude@profile-A.weekly", "claude@profile-B.weekly", "private@example.com"],
        ]))
        XCTAssertEqual(properties["enabled_providers"] as? [String], ["claude"])
        XCTAssertEqual(properties["enabled_metric_ids"] as? [String], ["claude.weekly"])
    }
}
