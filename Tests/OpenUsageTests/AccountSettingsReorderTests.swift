import CoreGraphics
import XCTest
@testable import OpenUsage

final class AccountSettingsReorderTests: XCTestCase {
    func testDragIDNamespacesFamilyAndProfile() {
        XCTAssertEqual(
            AccountSettingsReorder.dragID(family: "claude", profileID: "profile-1"),
            "settings-account:claude:profile-1"
        )
        XCTAssertNotEqual(
            AccountSettingsReorder.dragID(family: "claude", profileID: "shared"),
            AccountSettingsReorder.dragID(family: "codex", profileID: "shared")
        )
    }

    func testRowsAllowReorderingOnlyForMultipleProfiles() {
        XCTAssertFalse(AccountSettingsReorder.allowsReordering(profileCount: 0))
        XCTAssertFalse(AccountSettingsReorder.allowsReordering(profileCount: 1))
        XCTAssertTrue(AccountSettingsReorder.allowsReordering(profileCount: 2))
    }

    func testEdgeDirectionUsesViewportEdgesAndStopsOutsideOvershoot() {
        let viewport = CGRect(x: 0, y: 100, width: 320, height: 400)

        XCTAssertEqual(AccountSettingsReorder.direction(at: CGPoint(x: 40, y: 120), viewport: viewport), .up)
        XCTAssertNil(AccountSettingsReorder.direction(at: CGPoint(x: 40, y: 300), viewport: viewport))
        XCTAssertEqual(AccountSettingsReorder.direction(at: CGPoint(x: 40, y: 480), viewport: viewport), .down)
        XCTAssertNil(AccountSettingsReorder.direction(at: CGPoint(x: 40, y: 70), viewport: viewport))
        XCTAssertNil(AccountSettingsReorder.direction(at: CGPoint(x: 40, y: 530), viewport: viewport))
        XCTAssertNil(AccountSettingsReorder.direction(at: CGPoint(x: -30, y: 120), viewport: viewport))
        XCTAssertNil(AccountSettingsReorder.direction(at: CGPoint(x: 350, y: 480), viewport: viewport))
    }

    func testAdjacentTargetRespectsDirectionAndBounds() {
        let ids = ["one", "two", "three"]

        XCTAssertEqual(
            AccountSettingsReorder.adjacentTarget(draggedID: "two", direction: .up, orderedIDs: ids),
            "one"
        )
        XCTAssertEqual(
            AccountSettingsReorder.adjacentTarget(draggedID: "two", direction: .down, orderedIDs: ids),
            "three"
        )
        XCTAssertNil(AccountSettingsReorder.adjacentTarget(draggedID: "one", direction: .up, orderedIDs: ids))
        XCTAssertNil(AccountSettingsReorder.adjacentTarget(draggedID: "three", direction: .down, orderedIDs: ids))
        XCTAssertNil(AccountSettingsReorder.adjacentTarget(draggedID: "missing", direction: .down, orderedIDs: ids))
    }

    func testCancellationGateIgnoresSameGestureUntilItEnds() {
        var gate = AccountSettingsDragGate()

        XCTAssertTrue(gate.shouldHandle)
        gate.cancelUntilGestureEnds()
        XCTAssertFalse(gate.shouldHandle)
        XCTAssertFalse(gate.shouldHandle)

        gate.endGesture()
        XCTAssertTrue(gate.shouldHandle)
    }
}
