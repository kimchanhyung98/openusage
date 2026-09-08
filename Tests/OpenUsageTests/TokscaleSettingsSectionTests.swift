import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class TokscaleSettingsSectionTests: XCTestCase {
    func testRenderingDisclosureAtPanelWidthDoesNotStartWork() throws {
        let suite = "OpenUsageTests.Tokscale.SettingsRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TokscaleSyncStore(defaults: defaults)
        let export = ProcessInfo.processInfo.environment["OPENUSAGE_TOKSCALE_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }
        for density in DensitySetting.allCases {
            defaults.set(density.rawValue, forKey: DensitySetting.key)
            for appearance in [ColorScheme.light, .dark] {
                let view = TokscaleSettingsSection(store: store)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(width: PanelHeightController.panelWidth)
                    .background(appearance == .light ? Color.white : Color.black)
                    .environment(\.colorScheme, appearance)
                    .defaultAppStorage(defaults)
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(
                    contentRect: .init(x: 0, y: 0, width: PanelHeightController.panelWidth, height: 1000),
                    styleMask: .borderless, backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                window.setContentSize(hosting.fittingSize)
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                window.close()
                XCTAssertEqual(bitmap.pixelsWide % Int(PanelHeightController.panelWidth), 0)
                XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
                XCTAssertEqual(store.phase, .idle)
                XCTAssertFalse(store.isRunning)
                XCTAssertTrue(store.output.isEmpty)
                if let export {
                    try png.write(to: export.appendingPathComponent("tokscale-\(density.rawValue)-\(appearance).png"))
                }
            }
        }
    }
}
