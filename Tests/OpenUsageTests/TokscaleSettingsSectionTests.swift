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

    func testFinishedAndFailedResultsRenderAndCollapseAcrossAppearancesAndDensities() async throws {
        let suite = "OpenUsageTests.Tokscale.ResultRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = ProcessInfo.processInfo.environment["OPENUSAGE_TOKSCALE_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }

        for result in renderedResults {
            for density in DensitySetting.allCases {
                defaults.set(density.rawValue, forKey: DensitySetting.key)
                for appearance in [ColorScheme.light, .dark] {
                    let store = TokscaleSyncStore(
                        defaults: defaults,
                        bunInstaller: StubFinishedBunInstaller(),
                        commandRunner: StubFinishedTokscaleRunner(result: result)
                    )
                    let outcome = result.exitCode == 0 ? "finished" : "failed"
                    let variant = "\(outcome)-\(density.rawValue)-\(appearance)"
                    let view = resultCard(store: store, defaults: defaults, appearance: appearance)
                    let idleHeight = try renderedSize(of: view).height

                    store.startSubmit()
                    try await waitForResult(store, phase: result.exitCode == 0 ? .submitFinished : .failed)
                    XCTAssertFalse(store.output.isEmpty)
                    let resultSize = try renderedSize(
                        of: view, export: export?.appendingPathComponent("tokscale-\(variant).png")
                    )
                    XCTAssertEqual(resultSize.width, PanelHeightController.panelWidth, accuracy: 0.5, variant)
                    XCTAssertGreaterThan(resultSize.height, idleHeight + 100, variant)
                    XCTAssertLessThan(resultSize.height, 400, variant)

                    store.dismissResult()
                    XCTAssertEqual(store.phase, .idle)
                    XCTAssertTrue(store.output.isEmpty)
                    XCTAssertNil(store.errorMessage)
                    XCTAssertNil(store.failure)
                    XCTAssertEqual(store.isSyncCoolingDown, result.exitCode == 0)
                    let dismissedSize = try renderedSize(
                        of: view, export: export?.appendingPathComponent("tokscale-\(variant)-dismissed.png")
                    )
                    XCTAssertEqual(dismissedSize.width, PanelHeightController.panelWidth, accuracy: 0.5, variant)
                    XCTAssertLessThan(dismissedSize.height, resultSize.height - 100, variant)
                    if result.exitCode == 0 {
                        XCTAssertGreaterThanOrEqual(dismissedSize.height, idleHeight, variant)
                        XCTAssertLessThanOrEqual(dismissedSize.height, idleHeight + 48, variant)
                    } else {
                        XCTAssertEqual(dismissedSize.height, idleHeight, accuracy: 0.5, variant)
                    }
                    await store.shutdown()
                }
            }
        }
    }

    func testDoneButtonDismissesResultsWhenHostExposesSwiftUIAccessibility() async throws {
        _ = try renderedSize(of: Button("Accessibility Control") {}) { hosting in
            guard accessibilityButton(named: "Accessibility Control", in: hosting) != nil else {
                throw XCTSkip("This test host does not expose accessibility children for a standalone SwiftUI button.")
            }
        }
        let suite = "OpenUsageTests.Tokscale.DoneButton.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for result in renderedResults {
            let store = TokscaleSyncStore(
                defaults: defaults,
                bunInstaller: StubFinishedBunInstaller(),
                commandRunner: StubFinishedTokscaleRunner(result: result)
            )
            let view = resultCard(store: store, defaults: defaults, appearance: .dark)
            _ = try renderedSize(of: view) { hosting in
                XCTAssertNil(accessibilityButton(named: "Done", in: hosting))
            }
            store.startSubmit()
            try await waitForResult(store, phase: result.exitCode == 0 ? .submitFinished : .failed)

            _ = try renderedSize(of: view) { hosting in
                let done = try XCTUnwrap(accessibilityButton(named: "Done", in: hosting))
                XCTAssertTrue(done.isAccessibilityEnabled())
                XCTAssertGreaterThan(done.accessibilityFrame().width, 0)
                let window = try XCTUnwrap(hosting.window)
                XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(done.accessibilityFrame()))
                let sync = try XCTUnwrap(accessibilityButton(named: "Sync", in: hosting))
                XCTAssertEqual(sync.isAccessibilityEnabled(), result.exitCode != 0)
                XCTAssertTrue(done.accessibilityPerformPress())
            }
            XCTAssertEqual(store.phase, .idle)
            XCTAssertTrue(store.output.isEmpty)
            XCTAssertNil(store.errorMessage)
            XCTAssertNil(store.failure)
            XCTAssertEqual(store.isSyncCoolingDown, result.exitCode == 0)
            _ = try renderedSize(of: view) { hosting in
                XCTAssertNil(accessibilityButton(named: "Done", in: hosting))
                let sync = try XCTUnwrap(accessibilityButton(named: "Sync", in: hosting))
                XCTAssertEqual(sync.isAccessibilityEnabled(), result.exitCode != 0)
            }
            await store.shutdown()
        }
    }

    private var renderedResults: [TokscaleCommandResult] {
        [
            TokscaleCommandResult(
                exitCode: 0,
                output: "Successfully submitted!\n\nSummary:\n\nView your profile: https://tokscale.ai/u/example\n"
            ),
            TokscaleCommandResult(exitCode: 1, output: "The submission could not finish. Try again later.\n"),
        ]
    }

    private func resultCard(store: TokscaleSyncStore, defaults: UserDefaults, appearance: ColorScheme) -> some View {
        TokscaleSettingsSection(store: store)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: PanelHeightController.panelWidth)
            .background(appearance == .light ? Color.white : Color.black)
            .environment(\.colorScheme, appearance)
            .defaultAppStorage(defaults)
    }

    private func waitForResult(_ store: TokscaleSyncStore, phase: TokscaleSyncPhase) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline && (store.phase != phase || store.isRunning) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.phase, phase)
        XCTAssertFalse(store.isRunning)
    }

    private func accessibilityButton(named name: String, in view: NSView) -> (any NSAccessibilityProtocol)? {
        accessibilityElements(in: view).first {
            $0.accessibilityRole() == .button && ($0.accessibilityLabel() == name || $0.accessibilityTitle() == name)
        }
    }

    private func accessibilityElements(in element: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
        [element] + (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
            .flatMap { accessibilityElements(in: $0) }
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

private actor StubFinishedBunInstaller: BunInstalling {
    func availability() async throws -> BunAvailability {
        .available(BunRuntime(
            bunURL: URL(fileURLWithPath: "/opt/bun/bin/bun"),
            bunxURL: URL(fileURLWithPath: "/opt/bun/bin/bunx"),
            executionPath: "/opt/bun/bin"
        ))
    }

    func install(onOutput: @escaping @Sendable (String) -> Void) async throws -> BunRuntime {
        BunRuntime(
            bunURL: URL(fileURLWithPath: "/opt/bun/bin/bun"),
            bunxURL: URL(fileURLWithPath: "/opt/bun/bin/bunx"),
            executionPath: "/opt/bun/bin"
        )
    }
}

private actor StubFinishedTokscaleRunner: TokscaleCommandRunning {
    let result: TokscaleCommandResult

    init(result: TokscaleCommandResult) {
        self.result = result
    }

    func run(
        _ command: TokscaleCommand,
        runtime: BunRuntime,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> TokscaleCommandResult {
        onOutput(result.output)
        return result
    }
}
