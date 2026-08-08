import XCTest
@testable import OpenUsage

final class PanelOutsideClickPolicyTests: XCTestCase {
    func testNormalOutsideClickDismisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.shouldKeepOpen(.init()))
    }

    func testEveryKeepOpenReasonKeepsPanelOpen() {
        let contexts: [PanelOutsideClickContext] = [
            .init(isMorphing: true),
            .init(hasAttachedSheet: true),
            .init(isOnStatusButton: true),
            .init(isPanelWindow: true),
            .init(isStatusItemWindow: true),
            .init(eventWindowTypeName: "NSMenuWindow"),
            .init(eventWindowTypeName: "_NSPopoverWindow"),
        ]

        for context in contexts {
            XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(context))
        }
    }

    func testPopoverWindowMatchIsCaseInsensitive() {
        XCTAssertTrue(
            PanelOutsideClickPolicy.shouldKeepOpen(.init(eventWindowTypeName: "myPOPOVERwindow"))
        )
    }

    func testInsidePanelKeepsOpenWithoutAnEventWindow() {
        XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(.init(isInsidePanel: true)))
    }

    func testInsidePanelStillKeepsOpenWhenAnotherReasonAlsoApplies() {
        XCTAssertTrue(PanelOutsideClickPolicy.shouldKeepOpen(.init(isMorphing: true, isInsidePanel: true)))
    }

    func testMenuWindowMatchIsCaseInsensitive() {
        XCTAssertTrue(
            PanelOutsideClickPolicy.shouldKeepOpen(.init(eventWindowTypeName: "privateMENUwindow"))
        )
    }

    func testUnrelatedWindowDismisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.shouldKeepOpen(.init(eventWindowTypeName: "NSWindow")))
    }

    // MARK: - Status-button hit test (issue #1008)

    /// menu bar보다 몇 pt 낮은 button frame (screen maxY 1000, frame 상단 996)
    private let buttonFrame = NSRect(x: 100, y: 972, width: 40, height: 24)
    private let screenTop: CGFloat = 1000

    func testClickAtTopOfScreenHitsStatusButton() {
        // #1008: 화면 최상단 커서는 mouseLocation.y가 screen maxY — button frame 위쪽이지만 macOS는 button으로 라우팅
        XCTAssertTrue(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 120, y: screenTop), buttonFrame: buttonFrame, screenTop: screenTop
        ))
    }

    func testClickAtTopOfScreenWithRealCapturedGeometryHits() {
        // 진단 log에서 그대로 가져온 실측 geometry
        XCTAssertTrue(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 4122.98046875, y: 1555),
            buttonFrame: NSRect(x: 4061, y: 1529, width: 242.5, height: 22),
            screenTop: 1555
        ))
    }

    func testClickInsideStatusButtonHits() {
        XCTAssertTrue(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 120, y: 984), buttonFrame: buttonFrame, screenTop: screenTop
        ))
    }

    func testClickInsideStatusButtonHitsWithoutAScreen() {
        XCTAssertTrue(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 120, y: buttonFrame.maxY), buttonFrame: buttonFrame, screenTop: nil
        ))
    }

    func testClickBesideStatusButtonMisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 99, y: 984), buttonFrame: buttonFrame, screenTop: screenTop
        ))
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 141, y: 984), buttonFrame: buttonFrame, screenTop: screenTop
        ))
    }

    func testClickInTopStripBesideStatusButtonMisses() {
        // 상방 확장은 수직만 적용 — 옆 status item 위 최상단 클릭은 dismiss
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 150, y: screenTop), buttonFrame: buttonFrame, screenTop: screenTop
        ))
    }

    func testClickBelowStatusButtonMisses() {
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            NSPoint(x: 120, y: 971), buttonFrame: buttonFrame, screenTop: screenTop
        ))
    }

    func testEmptyButtonFrameNeverHits() {
        XCTAssertFalse(PanelOutsideClickPolicy.pointHitsStatusButton(
            .zero, buttonFrame: .zero, screenTop: nil
        ))
    }
}
