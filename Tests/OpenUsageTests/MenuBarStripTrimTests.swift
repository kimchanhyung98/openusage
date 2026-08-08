import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarStripTrimTests: XCTestCase {
    func testVisibleBoundsFindsOffCenterContent() throws {
        // fixture: 20x10 canvas의 top-left 쪽 3x2 불투명 block — 상하 반전 시 빈 pixel에 착지
        let image = try makeImage(width: 20, height: 10, opaqueRect: CGRect(x: 4, y: 1, width: 3, height: 2))

        let bounds = try XCTUnwrap(MenuBarStripRenderer.visibleBounds(of: image))
        XCTAssertEqual(bounds, CGRect(x: 4, y: 1, width: 3, height: 2))

        let trimmed = try XCTUnwrap(MenuBarStripRenderer.trimmedToVisibleContent(image))
        XCTAssertEqual(trimmed.width, 3)
        XCTAssertEqual(trimmed.height, 2)
        XCTAssertEqual(MenuBarStripRenderer.visibleBounds(of: trimmed), CGRect(x: 0, y: 0, width: 3, height: 2))
    }

    func testVisibleBoundsNilForFullyTransparentImage() throws {
        let image = try makeImage(width: 8, height: 8, opaqueRect: nil)
        XCTAssertNil(MenuBarStripRenderer.visibleBounds(of: image))
        XCTAssertNil(MenuBarStripRenderer.trimmedToVisibleContent(image))
    }

    func testTextImageHasNoTransparentMargins() throws {
        let content = MenuBarContent(
            groups: [
                MenuBarContent.Group(
                    providerID: "claude",
                    displayName: "Claude",
                    icon: .providerMark("claude"),
                    metrics: [
                        MenuBarContent.Metric(id: "claude.session", label: "Session", value: "99%",
                                              fraction: 0.01, isBounded: true, hasData: true),
                        MenuBarContent.Metric(id: "claude.weekly", label: "Weekly", value: "87%",
                                              fraction: 0.13, isBounded: true, hasData: true)
                    ]
                )
            ],
            bars: []
        )

        let image = try XCTUnwrap(MenuBarStripRenderer.textImage(for: content))
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bounds = try XCTUnwrap(MenuBarStripRenderer.visibleBounds(of: cgImage))

        XCTAssertEqual(bounds, CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, content.accessibilityText)
    }

    /// top-left origin 좌표로 받은 불투명 rect를 투명 canvas에 그림 (내부에서 bottom-left user space로 변환)
    private func makeImage(width: Int, height: Int, opaqueRect: CGRect?) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        if let rect = opaqueRect {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        return try XCTUnwrap(context.makeImage())
    }
}
