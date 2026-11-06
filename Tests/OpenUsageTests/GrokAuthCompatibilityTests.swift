import XCTest
@testable import OpenUsage

@MainActor
final class GrokAuthCompatibilityTests: XCTestCase {
    func testUnsupportedAuthNeverReachesSubscriptionAPI() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("Unsupported credentials must not reach the subscription API")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"xai::api_key":{"key":"api","auth_mode":"api_key"}}"#
        ])
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, environment: FakeEnvironment()),
            usageClient: GrokUsageClient(httpClient: http),
            logUsageScanner: GrokLogUsageScanner(
                files: FakeFiles(), environment: FakeEnvironment(),
                homeDirectory: { URL(fileURLWithPath: "/fixture/grok-auth-compatibility") }
            ),
            pricing: { .empty }
        )

        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertFalse(hasCredentials)
        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertTrue(http.requests.isEmpty)
    }
}
