import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarStripMemoTests: XCTestCase {
    func testEqualContentReturnsSameImageInstance() throws {
        let first = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .text))
        let second = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .text))
        XCTAssertIdentical(first, second)
    }

    func testChangedValueRendersFreshImage() throws {
        let first = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .text))
        let changed = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "43%"), style: .text))
        XCTAssertNotIdentical(first, changed)
    }

    func testChangedStyleRendersFreshImage() throws {
        let content = makeContent(value: "42%")
        let text = try XCTUnwrap(MenuBarStripRenderer.image(for: content, style: .text))
        let bars = try XCTUnwrap(MenuBarStripRenderer.image(for: content, style: .bars))
        XCTAssertNotIdentical(text, bars)
    }

    private func makeContent(value: String) -> MenuBarContent {
        let metric = MenuBarContent.Metric(
            id: "claude.session", label: "Session", value: value,
            fraction: 0.42, isBounded: true, hasData: true
        )
        return MenuBarContent(
            groups: [MenuBarContent.Group(
                providerID: "claude",
                displayName: "Claude",
                icon: .providerMark("claude"),
                metrics: [metric]
            )],
            bars: [metric]
        )
    }
}
