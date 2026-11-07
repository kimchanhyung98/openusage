import XCTest
@testable import Egasu

final class TelemetrySinkTests: XCTestCase {
    func testTokenOverridesUseTheFirstNonemptyValue() {
        for empty in ["", " \n\t"] {
            XCTAssertEqual(TelemetryConfig.token(environment: [
                "EGASU_POSTHOG_TOKEN": empty,
                "OPENUSAGE_POSTHOG_TOKEN": " legacy-token \n"
            ]), "legacy-token")
        }
        XCTAssertEqual(TelemetryConfig.token(environment: [
            "EGASU_POSTHOG_TOKEN": " new-token \n",
            "OPENUSAGE_POSTHOG_TOKEN": "legacy-token"
        ]), "new-token")
        XCTAssertEqual(TelemetryConfig.token(environment: [
            "OPENUSAGE_POSTHOG_TOKEN": "legacy-token"
        ]), "legacy-token")
        #if DEBUG
        XCTAssertEqual(TelemetryConfig.token(environment: [
            "EGASU_POSTHOG_TOKEN": " \n",
            "OPENUSAGE_POSTHOG_TOKEN": ""
        ]), TelemetryConfig.placeholderToken)
        #endif
    }

    func testErrorAutocaptureFollowsTheSharingChoice() {
        XCTAssertTrue(
            PostHogTelemetrySink.errorAutocaptureEnabled(telemetryEnabled: true),
            "crash autocapture must be on when telemetry is enabled"
        )
        XCTAssertFalse(
            PostHogTelemetrySink.errorAutocaptureEnabled(telemetryEnabled: false),
            "crash autocapture must be off when the user has opted out of telemetry"
        )
    }
}
