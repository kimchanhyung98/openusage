import XCTest
@testable import OpenUsage

@MainActor
final class ProviderSectionHeaderTests: XCTestCase {
    func testManagedAccountCardHeaderKeepsTheProviderFamilyTitle() {
        let provider = Provider(
            id: "claude@abc12345",
            displayName: "Claude — Personal",
            icon: .providerMark("claude")
        )

        XCTAssertEqual(
            ProviderSectionHeader.headerTitle(
                for: provider,
                resolvedDisplayName: "Claude — Personal",
                usesManagedAccountTitle: true
            ),
            "Claude"
        )
    }

    func testDiscoveredAccountCardKeepsItsExistingTitle() {
        let provider = Provider(
            id: "claude@abc12345",
            displayName: "Claude — Personal",
            icon: .providerMark("claude")
        )

        XCTAssertEqual(
            ProviderSectionHeader.headerTitle(
                for: provider,
                resolvedDisplayName: "Claude — Work",
                usesManagedAccountTitle: false
            ),
            "Claude — Work"
        )
    }

    func testMultipleManagedProfilesKeepThePickerForOneSharedRuntimeCard() {
        XCTAssertTrue(
            ProviderSectionHeader.shouldShowAccountPicker(
                managedProfileCount: 2,
                runtimeOptionCount: 1
            )
        )
    }

    func testDiscoveredRuntimeOptionsDoNotShowAManagedPicker() {
        XCTAssertFalse(
            ProviderSectionHeader.shouldShowAccountPicker(
                managedProfileCount: 0,
                runtimeOptionCount: 2
            )
        )
    }
}
