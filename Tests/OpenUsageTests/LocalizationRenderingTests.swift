import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class LocalizationRenderingTests: XCTestCase {
    func testDashboardAndShareCardsRenderAllLanguagesAcrossDensitiesAndAppearances() throws {
        let suite = "OpenUsageTests.Localization.Rendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = ProcessInfo.processInfo.environment["OPENUSAGE_LOCALIZATION_SCREENSHOTS"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let export {
            try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        }

        for density in DensitySetting.allCases {
            defaults.set(density.rawValue, forKey: DensitySetting.key)
            for appearance in [ColorScheme.light, .dark] {
                var renderedBySurface: [String: [LanguageSetting: Raster]] = [:]
                for language in LanguageSetting.allCases {
                    try L10n.withLanguage(language) {
                        let rows = sampleRows()
                        let variant = "\(language.rawValue)-\(density.rawValue)-\(appearance)"
                        let dashboard = VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                WidgetRowView(data: row)
                            }
                        }
                        .padding(14)
                        .frame(width: 320)
                        .background(appearance == .light ? Color.white : Color.black)
                        .environment(\.colorScheme, appearance)
                        .environment(\.hoverTooltipsDisabled, true)
                        .defaultAppStorage(defaults)
                        let share = ShareCardView(
                            provider: MockData.codex, plan: "Plus", rows: rows, appearance: appearance
                        )
                        .defaultAppStorage(defaults)

                        renderedBySurface["dashboard", default: [:]][language] = try rasterize(
                            dashboard, width: 320, name: "dashboard-\(variant)", export: export
                        )
                        renderedBySurface["share", default: [:]][language] = try rasterize(
                            share, width: Int(ShareCardView.width), name: "share-\(variant)", export: export
                        )
                        for metric in TotalSpendMetric.allCases {
                            let total = TotalSpendShareCardView(
                                total: sampleTotal(), metric: metric, appearance: appearance
                            )
                            .defaultAppStorage(defaults)
                            let surface = "total-\(metric.rawValue)"
                            renderedBySurface[surface, default: [:]][language] = try rasterize(
                                total, width: Int(ShareCardView.width), name: "\(surface)-\(variant)", export: export
                            )
                        }
                    }
                }
                for (surface, renders) in renderedBySurface {
                    for (first, second) in [
                        (LanguageSetting.english, LanguageSetting.korean),
                        (.english, .japanese), (.korean, .japanese)
                    ] {
                        let firstRaster = try XCTUnwrap(renders[first])
                        let secondRaster = try XCTUnwrap(renders[second])
                        let context = "\(surface), \(density), \(appearance), \(first.rawValue)/\(second.rawValue)"
                        XCTAssertEqual(firstRaster.width, secondRaster.width, context)
                        XCTAssertTrue(visiblyDiffers(firstRaster, secondRaster), context)
                    }
                }
            }
        }
    }

    private func sampleRows() -> [WidgetData] {
        let icon = MockData.codex.icon
        var session = WidgetData(title: "Session", icon: icon, kind: .percent, used: 42, limit: 100)
        session.softLimitUsedFraction = 0.8
        let weekly = WidgetData(title: "Weekly", icon: icon, kind: .percent, used: 100, limit: 100)
        var spend = WidgetData(title: "Last 30 Days", icon: icon, kind: .dollars, used: 125.42, limit: nil)
        spend.isUsagePeriod = true
        spend.values = [
            MetricValue(number: 125.42, kind: .dollars),
            MetricValue(number: 1234567, kind: .count, label: "tokens")
        ]
        var resets = WidgetData(title: "Rate Limit Resets", icon: icon, kind: .count, used: 3, limit: nil)
        resets.values = [MetricValue(number: 3, kind: .count, label: "available")]
        resets.showsResetExpiries = true
        var trend = WidgetData(title: "Usage Trend", icon: icon, kind: .count, used: 0, limit: nil)
        trend.isChart = true
        trend.chartPoints = [200.0, 600, 300, 1200, 900, 1600, 800].enumerated().map { index, value in
            MetricChartPoint(value: value, label: "Day \(index + 1)", valueLabel: nil)
        }
        return [session, weekly, spend, resets, trend]
    }

    private func sampleTotal() -> TotalSpend {
        TotalSpend(period: .last30, slices: [
            TotalSpendSlice(
                provider: MockData.claude, title: "Claude", amountUSD: 125.42,
                tokenCount: 12_345_678, estimated: true
            ),
            TotalSpendSlice(
                provider: MockData.codex, title: "Codex", amountUSD: 78.64,
                tokenCount: 8_765_432, estimated: false
            )
        ])
    }

    private struct Raster {
        let width: Int
        let height: Int
        let pixels: Data
    }

    private func rasterize<Content: View>(
        _ view: Content, width: Int, name: String, export: URL?
    ) throws -> Raster {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: view), name)
        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image), name)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png), name)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0, name)
        XCTAssertEqual(bitmap.pixelsWide % width, 0, name)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0, name)
        XCTAssertNotNil(NSImage(data: png), name)
        if let export {
            try png.write(to: export.appendingPathComponent("\(name).png"))
        }

        let cgImage = try XCTUnwrap(bitmap.cgImage, name)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ), name)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let pixels = try XCTUnwrap(context.data, name)
        return Raster(
            width: cgImage.width, height: cgImage.height,
            pixels: Data(bytes: pixels, count: context.bytesPerRow * context.height)
        )
    }

    private func visiblyDiffers(_ first: Raster, _ second: Raster) -> Bool {
        if first.height != second.height { return true }
        // 같은 실행의 언어별 픽셀만 비교. 폰트·OS별 골든 이미지와 미세 양자화 오차는 제외.
        var changedChannels = 0
        for (left, right) in zip(first.pixels, second.pixels) where abs(Int(left) - Int(right)) > 32 {
            changedChannels += 1
            if changedChannels > 32 { return true }
        }
        return false
    }
}
