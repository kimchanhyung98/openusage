import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class TokscaleSettingsSectionTests: XCTestCase {
    func testDeviceNameSheetUsesPlaceholderAndRestoresSavedNames() throws {
        let suite = "OpenUsageTests.Tokscale.DeviceNameRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = ProcessInfo.processInfo.environment["OPENUSAGE_TOKSCALE_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }

        func assertRenderedName(_ store: TokscaleSyncStore, expected: String, variant: String) throws {
            for appearance in [ColorScheme.light, .dark] {
                let view = TokscaleDeviceNameSheet(store: store)
                    .background(appearance == .light ? Color.white : Color.black)
                    .environment(\.colorScheme, appearance)
                    .defaultAppStorage(defaults)
                _ = try renderedSize(
                    of: view,
                    export: export?.appendingPathComponent("tokscale-device-name-\(variant)-\(appearance).png")
                ) { hosting in
                    let fields = editableTextFields(in: hosting)
                    XCTAssertEqual(fields.count, 1)
                    let field = try XCTUnwrap(fields.first)
                    XCTAssertEqual(field.stringValue, expected, "Unexpected input for \(variant).")
                    XCTAssertEqual(field.placeholderString, "Enter Device Name")
                }
            }
            XCTAssertEqual(store.phase, .idle)
            XCTAssertFalse(store.isRunning)
            XCTAssertTrue(store.output.isEmpty)
        }

        let store = TokscaleSyncStore(defaults: defaults)
        try assertRenderedName(store, expected: "", variant: "empty")
        try store.saveDeviceName("m1-max")
        try assertRenderedName(store, expected: "m1-max", variant: "saved")
        let reloadedStore = TokscaleSyncStore(defaults: defaults)
        try assertRenderedName(reloadedStore, expected: "m1-max", variant: "reloaded")
        try reloadedStore.saveDeviceName("studio-mac")
        try assertRenderedName(reloadedStore, expected: "studio-mac", variant: "updated")
        reloadedStore.clearDeviceName()
        try assertRenderedName(TokscaleSyncStore(defaults: defaults), expected: "", variant: "cleared")
    }

    private func editableTextFields(in view: NSView) -> [NSTextField] {
        var fields = view.subviews.flatMap { editableTextFields(in: $0) }
        if let field = view as? NSTextField, field.isEditable {
            fields.insert(field, at: 0)
        }
        return fields
    }

    func testSyncButtonInheritsDefaultSettingsControlSize() throws {
        let suite = "OpenUsageTests.Tokscale.ButtonRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TokscaleSyncStore(defaults: defaults)
        let export = ProcessInfo.processInfo.environment["OPENUSAGE_TOKSCALE_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }
        var cardHeights: [CGFloat] = []
        var buttonHeights: [CGFloat] = []
        for controlSize in [ControlSize.regular, .large] {
            cardHeights.append(try renderedSize(of:
                TokscaleSettingsSection(store: store)
                    .frame(width: PanelHeightController.panelWidth)
                    .controlSize(controlSize)
                    .defaultAppStorage(defaults)
            ).height)
            buttonHeights.append(try renderedSize(of: Button("Install…") {}.controlSize(controlSize)).height)
            if let export {
                let comparison = VStack(alignment: .leading, spacing: 12) {
                    TokscaleSettingsSection(store: store)
                    HStack {
                        Text("Terminal Helper")
                        Spacer()
                        Button("Install…") {}
                    }
                    .padding(12)
                    .cardSurface()
                }
                .padding(14)
                .frame(width: PanelHeightController.panelWidth)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
                .controlSize(controlSize)
                .defaultAppStorage(defaults)
                _ = try renderedSize(
                    of: comparison,
                    export: export.appendingPathComponent("tokscale-button-comparison-\(controlSize).png")
                )
            }
        }
        let expectedIncrease = buttonHeights[1] - buttonHeights[0]
        XCTAssertGreaterThan(expectedIncrease, 0)
        XCTAssertEqual(
            cardHeights[1] - cardHeights[0], expectedIncrease, accuracy: 0.5,
            "Sync should inherit the default settings button's regular-to-large size increase."
        )
        XCTAssertEqual(store.phase, .idle)
        XCTAssertFalse(store.isRunning)
    }

    private func renderedSize(
        of view: some View,
        export: URL? = nil,
        inspect: (NSView) throws -> Void = { _ in }
    ) throws -> NSSize {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: PanelHeightController.panelWidth, height: 1000),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        if let export {
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: export)
        }
        try inspect(hosting)
        return hosting.bounds.size
    }

    func testRenderingCompactCardAtPanelWidthDoesNotStartWork() throws {
        let suite = "OpenUsageTests.Tokscale.SettingsRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TokscaleSyncStore(defaults: defaults)
        let export = ProcessInfo.processInfo.environment["OPENUSAGE_TOKSCALE_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }
        let deviceNames: [String?] = [nil, String(repeating: "w", count: TokscaleDeviceName.maximumUTF8ByteCount)]
        var defaultHeights: [String: CGFloat] = [:]
        for deviceName in deviceNames {
            if let deviceName { try store.saveDeviceName(deviceName) }
            for density in DensitySetting.allCases {
                defaults.set(density.rawValue, forKey: DensitySetting.key)
                for appearance in [ColorScheme.light, .dark] {
                    let variant = "\(density.rawValue)-\(appearance)"
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
                    XCTAssertEqual(hosting.bounds.width, PanelHeightController.panelWidth, accuracy: 0.5)
                    XCTAssertGreaterThan(hosting.bounds.height, 0)
                    XCTAssertLessThanOrEqual(
                        hosting.bounds.height, 150,
                        "Idle Tokscale settings should stay compact for \(variant)."
                    )
                    if deviceName == nil {
                        defaultHeights[variant] = hosting.bounds.height
                    } else {
                        XCTAssertEqual(
                            hosting.bounds.height, try XCTUnwrap(defaultHeights[variant]), accuracy: 0.5,
                            "A long saved device name should not change the idle card height for \(variant)."
                        )
                    }
                    let expectedPixelSize = hosting.convertToBacking(hosting.bounds).size
                    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    window.close()
                    XCTAssertEqual(bitmap.pixelsWide, Int(expectedPixelSize.width.rounded()))
                    XCTAssertEqual(bitmap.pixelsHigh, Int(expectedPixelSize.height.rounded()))
                    XCTAssertEqual(store.phase, .idle)
                    XCTAssertFalse(store.isRunning)
                    XCTAssertTrue(store.output.isEmpty)
                    if let export {
                        let suffix = deviceName == nil ? "" : "-long-name"
                        try png.write(to: export.appendingPathComponent("tokscale-\(variant)\(suffix).png"))
                    }
                }
            }
        }
    }
}
