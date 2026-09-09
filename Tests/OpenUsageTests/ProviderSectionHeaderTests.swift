import XCTest
@testable import OpenUsage

@MainActor
final class ProviderSectionHeaderTests: XCTestCase {
    func testAnAccountCardIsTitledAfterItsProvider() {
        XCTAssertEqual(
            ProviderAccountID.cardTitle(providerID: "claude@abc12345", fallback: "Claude — Personal"),
            "Claude"
        )
        XCTAssertEqual(
            ProviderAccountID.cardTitle(providerID: "claude", fallback: "Claude"),
            "Claude"
        )
    }

    func testANonAccountProviderKeepsItsOwnTitle() {
        XCTAssertEqual(
            ProviderAccountID.cardTitle(providerID: "cursor", fallback: "Cursor"),
            "Cursor"
        )
    }

    func testMultipleAccountsKeepThePickerForOneSharedRuntimeCard() {
        XCTAssertTrue(
            ProviderSectionHeader.shouldShowAccountPicker(
                accountCount: 2,
                runtimeOptionCount: 1
            )
        )
    }

    func testDiscoveredAccountsAlsoGetThePicker() {
        XCTAssertTrue(
            ProviderSectionHeader.shouldShowAccountPicker(
                accountCount: 2,
                runtimeOptionCount: 2
            ),
            "a config-dir login is an account of the same card, so it belongs in the picker"
        )
    }

    func testASingleAccountShowsNoPicker() {
        XCTAssertFalse(
            ProviderSectionHeader.shouldShowAccountPicker(
                accountCount: 1,
                runtimeOptionCount: 1
            )
        )
    }

    func testIssueIndicatorsKeepUsageBeforeServiceAndServiceDuringRefresh() {
        let issue = ProviderServiceIssue(
            severity: .partial,
            componentName: "Claude API (api.anthropic.com)",
            checkedAt: .distantPast
        )

        XCTAssertEqual(
            ProviderSectionHeader.issueIndicatorKinds(
                hasWarning: false,
                serviceStatus: .unknown,
                refreshing: false
            ),
            []
        )
        XCTAssertEqual(
            ProviderSectionHeader.issueIndicatorKinds(
                hasWarning: true,
                serviceStatus: .operational,
                refreshing: false
            ),
            [.usage]
        )
        XCTAssertEqual(
            ProviderSectionHeader.issueIndicatorKinds(
                hasWarning: false,
                serviceStatus: .disrupted(issue),
                refreshing: false
            ),
            [.service]
        )
        XCTAssertEqual(
            ProviderSectionHeader.issueIndicatorKinds(
                hasWarning: true,
                serviceStatus: .disrupted(issue),
                refreshing: false
            ),
            [.usage, .service]
        )
        XCTAssertEqual(
            ProviderSectionHeader.issueIndicatorKinds(
                hasWarning: true,
                serviceStatus: .disrupted(issue),
                refreshing: true
            ),
            [.service]
        )
    }

    func testServerIssueIconPathHasVisibleBounds() {
        for size in [CGFloat(14), CGFloat(16)] {
            let path = ServerIssueIconShape().path(in: CGRect(x: 0, y: 0, width: size, height: size))

            XCTAssertFalse(path.isEmpty)
            XCTAssertGreaterThan(path.boundingRect.width, 0)
            XCTAssertGreaterThan(path.boundingRect.height, 0)
        }
    }

    func testServiceIssueAccessibilityValueNamesProviderSeverityAndComponent() {
        let issue = ProviderServiceIssue(
            severity: .partial,
            componentName: "Claude API (api.anthropic.com)",
            checkedAt: .distantPast
        )

        XCTAssertEqual(
            issue.accessibilityValue(providerName: "Claude"),
            "Claude reports a partial outage for Claude API (api.anthropic.com)."
        )
    }
}
