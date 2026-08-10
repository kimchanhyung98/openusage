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
}
