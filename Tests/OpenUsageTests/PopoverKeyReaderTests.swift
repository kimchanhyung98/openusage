import XCTest
@testable import OpenUsage

final class PopoverKeyReaderTests: XCTestCase {
    /// window 대역 인스턴스 — `ObjectIdentifier`로 안정적 식별
    private final class WindowStub {}

    func testNilKeyWindowIsNotPopover() {
        let popover = WindowStub()
        XCTAssertFalse(
            PopoverKeyReader.keyTargetsPopover(
                eventWindowID: nil,
                popoverWindowID: ObjectIdentifier(popover)
            )
        )
    }

    func testMatchingWindowTargetsPopover() {
        let popover = WindowStub()
        XCTAssertTrue(
            PopoverKeyReader.keyTargetsPopover(
                eventWindowID: ObjectIdentifier(popover),
                popoverWindowID: ObjectIdentifier(popover)
            )
        )
    }

    func testDifferentWindowDoesNotTargetPopover() {
        let popover = WindowStub()
        let other = WindowStub()
        XCTAssertFalse(
            PopoverKeyReader.keyTargetsPopover(
                eventWindowID: ObjectIdentifier(other),
                popoverWindowID: ObjectIdentifier(popover)
            )
        )
    }
}
