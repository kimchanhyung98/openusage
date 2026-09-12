import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class SoftLimitSettingsSectionTests: XCTestCase {
    func testRendersEnabledAndDisabledSettingsInBothDensitiesAndAppearances() throws {
        let suite = "OpenUsageTests.SoftLimit.SettingsRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SoftLimitSettingsStore(defaults: defaults)
        let coordinator = SoftLimitCoordinator(settings: settings, adapters: [], isProviderEnabled: { _ in true })
        let export = ProcessInfo.processInfo.environment["OPENUSAGE_SOFT_LIMIT_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }
        for enabled in [false, true] {
            settings.enabled = enabled
            for density in DensitySetting.allCases {
                defaults.set(density.rawValue, forKey: DensitySetting.key)
                for appearance in [ColorScheme.light, .dark] {
                    let view = SoftLimitSettingsSection(settings: settings, coordinator: coordinator, providers: [MockData.codex, MockData.claude])
                        .padding(12)
                        .frame(width: 360)
                        .background(appearance == .light ? Color.white : Color.black)
                        .environment(\.colorScheme, appearance)
                        .defaultAppStorage(defaults)
                    let hosting = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 1000), styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = hosting
                    window.setContentSize(hosting.fittingSize)
                    hosting.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    window.close()
                    XCTAssertEqual(bitmap.pixelsWide % 360, 0)
                    XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
                    if let export {
                        try png.write(to: export.appendingPathComponent("soft-limit-\(enabled)-\(density.rawValue)-\(appearance).png"))
                    }
                }
            }
        }
    }
}
