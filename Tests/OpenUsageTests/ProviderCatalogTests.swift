import XCTest
@testable import OpenUsage

@MainActor
final class ProviderCatalogTests: XCTestCase {
    func testEstablishedProvidersLeadAlphabeticalTail() {
        let names = ProviderCatalog.make().map(\.provider.displayName)

        XCTAssertEqual(Array(names.prefix(3)), ["Claude", "Codex", "Cursor"])
        XCTAssertEqual(Array(names.dropFirst(3)), names.dropFirst(3).sorted())
    }
}
