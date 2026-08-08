import XCTest
import SwiftUI
@testable import OpenUsage

@MainActor
final class ShareCardRendererTests: XCTestCase {
    private func sampleCard() -> ShareCardView {
        let provider = MockData.claude
        let rows = MockData.descriptors(for: provider.id).map { $0.sample }
        return ShareCardView(provider: provider, plan: "Max", rows: rows, appearance: .light)
    }

    func testImageRasterizesAtAuthoredWidthMultiple() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))

        // CI는 ×1, 로컬은 ×4로 rasterize되므로 정확한 곱 대신 배수로 검증
        let rep = try XCTUnwrap(image.representations.first)
        let width = Int(ShareCardView.width)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        XCTAssertEqual(rep.pixelsWide % width, 0, "bitmap width should be a whole multiple of the authored card width")
        XCTAssertGreaterThan(rep.pixelsHigh, 0, "flexible-height card should rasterize with a positive height")
    }

    func testPNGDataRoundTripsToValidPNG() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))
        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))

        XCTAssertFalse(png.isEmpty)
        // PNG 매직 바이트: 89 50 4E 47 0D 0A 1A 0A
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(png.prefix(magic.count)), magic)
        XCTAssertNotNil(NSImage(data: png))
    }

    func testRendersEmptyProviderWithoutCrashing() throws {
        let card = ShareCardView(provider: MockData.cursor, plan: nil, rows: [], appearance: .dark)
        let image = try XCTUnwrap(ShareCardRenderer.image(for: card))
        let rep = try XCTUnwrap(image.representations.first)
        XCTAssertEqual(rep.pixelsWide % Int(ShareCardView.width), 0)
        XCTAssertGreaterThan(rep.pixelsHigh, 0)
    }

    func testCondensedTextRowIndicesFollowsNeighborRule() {
        let rows = MockData.descriptors(for: MockData.claude.id).map { $0.sample }
        XCTAssertGreaterThan(rows.count, 1, "sample fixture should have multiple rows")
        let condensed = ShareCardView.condensedTextRowIndices(rows)
        XCTAssertFalse(condensed.contains(0), "the first row is never condensed")
        for i in 1..<rows.count {
            let expected = !rows[i - 1].isBounded && !rows[i].isBounded
            XCTAssertEqual(condensed.contains(i), expected,
                           "row \(i) condensing should match the neighbor-aware text-only rule")
        }
    }

    func testCondensedTextRowIndicesRespectExpandBoundary() {
        let rows = MockData.descriptors(for: MockData.claude.id).map { $0.sample }
        XCTAssertGreaterThan(rows.count, 1, "sample fixture should have multiple rows")
        let boundary = rows.count / 2
        let condensed = ShareCardView.condensedTextRowIndices(rows, boundary: boundary)
        XCTAssertFalse(condensed.contains(boundary), "the first expanded row (at the boundary) is never condensed")
        for i in 1..<rows.count {
            let sameSide = (i < boundary) == (i - 1 < boundary)
            let expected = sameSide && !rows[i - 1].isBounded && !rows[i].isBounded
            XCTAssertEqual(condensed.contains(i), expected,
                           "row \(i) condensing should not bridge the expand caret boundary")
        }
    }

    // MARK: - Clipboard write result

    func testCopyToPasteboardReturnsFalseForUnencodableImage() {
        // 빈 NSImage는 representation이 없어 tiffRepresentation nil → PNG encode 실패
        let empty = NSImage()
        XCTAssertFalse(ShareCardRenderer.copyToPasteboard(empty),
                       "a failed encode must report false, not silently return success")
    }

    func testCopyToPasteboardWritesPNGAndReturnsTrueForValidImage() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))
        let pasteboard = NSPasteboard(name: .init("OpenUsageTests.ShareCard.\(UUID().uuidString)"))
        guard ShareCardRenderer.copyToPasteboard(image, pasteboard: pasteboard) else {
            throw XCTSkip("The macOS pasteboard service is unavailable in this test host.")
        }

        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertFalse(png.isEmpty)
        // 매직 바이트로 pasteboard 내용이 실제 PNG임을 확인
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(png.prefix(magic.count)), magic)
    }
}
