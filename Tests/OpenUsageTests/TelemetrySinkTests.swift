import XCTest
@testable import OpenUsage

final class TelemetrySinkTests: XCTestCase {
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
