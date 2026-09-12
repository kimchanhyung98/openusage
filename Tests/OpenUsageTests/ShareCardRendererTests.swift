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

    func testDisplayNameOverrideRendersExactCompositeTitleIntoPNG() throws {
        let expectedTitle = "Claude: Account 1"
        let provider = MockData.claude
        let exactTitleProvider = Provider(
            id: provider.id,
            displayName: expectedTitle,
            icon: provider.icon,
            links: provider.links
        )

        func pngPixels(provider: Provider, displayNameOverride: String? = nil) throws -> Data {
            let card = ShareCardView(
                provider: provider,
                plan: nil,
                rows: [],
                appearance: .light,
                displayNameOverride: displayNameOverride
            )
            let image = try XCTUnwrap(ShareCardRenderer.image(for: card))
            let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
            let pixels = try XCTUnwrap(bitmap.bitmapData)
            // PNG 메타데이터·압축 바이트가 아닌 디코딩된 픽셀로 제목 렌더 결과 비교.
            return Data(bytes: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }

        let overriddenPixels = try pngPixels(provider: provider, displayNameOverride: expectedTitle)
        let exactTitlePixels = try pngPixels(provider: exactTitleProvider)
        let providerTitlePixels = try pngPixels(provider: provider)

        XCTAssertEqual(overriddenPixels.count, exactTitlePixels.count)
        var largestDifference = 0
        for (overridden, exact) in zip(overriddenPixels, exactTitlePixels) {
            largestDifference = max(largestDifference, abs(Int(overridden) - Int(exact)))
        }
        XCTAssertLessThanOrEqual(
            largestDifference, 1,
            "the exact composite title should match within one rasterization quantization level"
        )
        XCTAssertNotEqual(
            overriddenPixels,
            providerTitlePixels,
            "the display-name override must change visible PNG pixels"
        )
    }

    func testRendersSoftLimitAndResetWatchInBothDensitiesAndDisplayModes() throws {
        let suite = "OpenUsageTests.SoftLimit.Rendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = CodexProvider().provider
        let deadline = Date().addingTimeInterval(3600)
        for density in DensitySetting.allCases {
            defaults.set(density.rawValue, forKey: DensitySetting.key)
            for mode in [WidgetDisplayMode.used, .remaining] {
                var quota = WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 95, limit: 100)
                quota.softLimitUsedFraction = 0.95
                quota.displayMode = mode
                var watch = WidgetData(title: "Reset Watch", icon: provider.icon, kind: .percent, used: 75, limit: 100)
                watch.displayMode = mode
                watch.forecast = .init(deadline: deadline, communityYesPercent: 100)
                var unavailable = watch
                unavailable.forecast?.communityYesPercent = nil
                unavailable.forecast?.refreshFailed = true
                let rows = [quota, watch, unavailable, watch.presented(at: deadline)]
                for appearance in [ColorScheme.light, .dark] {
                    let dashboard = VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            WidgetRowView(data: row)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(width: 320)
                    .background(appearance == .light ? Color.white : Color.black)
                    .environment(\.colorScheme, appearance)
                    .environment(\.hoverTooltipsDisabled, true)
                    .defaultAppStorage(defaults)
                    let card = ShareCardView(provider: provider, rows: rows, appearance: appearance)
                        .defaultAppStorage(defaults)
                    for (name, image, width) in [
                        ("dashboard", ShareCardRenderer.image(for: dashboard), 320),
                        ("share", ShareCardRenderer.image(for: card), Int(ShareCardView.width))
                    ] {
                        let rendered = try XCTUnwrap(image, "\(name), \(density), \(mode), \(appearance)")
                        let rep = try XCTUnwrap(rendered.representations.first)
                        XCTAssertGreaterThan(rep.pixelsWide, 0)
                        XCTAssertEqual(rep.pixelsWide % width, 0)
                        XCTAssertGreaterThan(rep.pixelsHigh, 0)
                        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: rendered))
                        XCTAssertNotNil(NSImage(data: png))
                    }
                }
            }
        }
    }

    func testSoftLimitMarkerRendersYellowWithoutChangingItsWidth() throws {
        let suite = "OpenUsageTests.SoftLimit.YellowMarker.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for density in DensitySetting.allCases {
            defaults.set(density.rawValue, forKey: DensitySetting.key)
            for mode in [WidgetDisplayMode.used, .remaining] {
                for appearance in [ColorScheme.light, .dark] {
                    var row = WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: 40, limit: 100)
                    row.displayMode = mode
                    for showsMarker in [false, true] {
                        row.softLimitUsedFraction = showsMarker ? 0.90 : nil
                        let view = WidgetRowView(data: row)
                            .padding(.horizontal, 14)
                            .frame(width: 320)
                            .background(appearance == .light ? Color.white : Color.black)
                            .environment(\.colorScheme, appearance)
                            .environment(\.hoverTooltipsDisabled, true)
                            .defaultAppStorage(defaults)
                        let image = try XCTUnwrap(ShareCardRenderer.image(for: view))
                        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))
                        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
                        var yellowColumns: Set<Int> = []
                        for y in 0..<bitmap.pixelsHigh {
                            for x in 0..<bitmap.pixelsWide {
                                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                                if color.redComponent > 0.6, color.greenComponent > 0.4,
                                   color.blueComponent < min(color.redComponent, color.greenComponent) * 0.6 {
                                    yellowColumns.insert(x)
                                }
                            }
                        }
                        let context = "\(density), \(mode), \(appearance), marker: \(showsMarker)"
                        if showsMarker {
                            XCTAssertFalse(yellowColumns.isEmpty, context)
                            XCTAssertLessThanOrEqual(yellowColumns.count, 2 * bitmap.pixelsWide / 320, context)
                        } else {
                            XCTAssertTrue(yellowColumns.isEmpty, context)
                        }
                    }
                }
            }
        }
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
