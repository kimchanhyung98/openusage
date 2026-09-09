import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class ProviderSectionHeaderRenderingTests: XCTestCase {
    private let accountName = "Personal Account With A Very Long Name"
    private let warning = "Re-login for live usage."
    private let issue = ProviderServiceIssue(severity: .partial, componentName: "Claude Code", checkedAt: .distantPast)

    func testShortAccountLabelsKeepTheChevronCloseToTheText() throws {
        let suite = "OpenUsageTests.AccountSpacing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = ProcessInfo.processInfo.environment["OPENUSAGE_STATUS_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }
        var measurements: [String] = []
        for title in ["Account 1", "Account 2"] {
            let view = ProviderSectionHeader(
                provider: MockData.claude,
                displayName: "Claude",
                plan: "Max 20x",
                accountOptions: [.init(id: "claude", title: title), .init(id: "claude@work", title: "Work")],
                selectedAccountID: "claude",
                onSelectAccount: { _ in },
                accountCount: 2
            )
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(width: PanelHeightController.panelWidth)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .defaultAppStorage(defaults)
            try withHosting(view) { hosting, _ in
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
                var runs: [ClosedRange<Int>] = []
                for x in Int(CGFloat(bitmap.pixelsWide) * 0.6)..<bitmap.pixelsWide {
                    let hasInk = (0..<bitmap.pixelsHigh).contains { y in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                        return color.alphaComponent > 0.5 && color.redComponent > 0.25
                            && color.greenComponent > 0.25 && color.blueComponent > 0.25
                    }
                    guard hasInk else { continue }
                    if let last = runs.last, last.upperBound == x - 1 {
                        runs[runs.count - 1] = last.lowerBound...x
                    } else {
                        runs.append(x...x)
                    }
                }
                XCTAssertGreaterThanOrEqual(runs.count, 2, title)
                // 오른쪽 계정 선택기의 마지막 두 ink run은 이름 끝과 화살표 — 글꼴·배율은 실제 렌더 기준.
                let chevron = try XCTUnwrap(runs.last)
                let label = try XCTUnwrap(runs.dropLast().last)
                let gap = CGFloat(chevron.lowerBound - label.upperBound - 1) / scale
                XCTAssertLessThanOrEqual(gap, 8, "Account label-to-chevron gap for \(title): \(gap)pt")
                measurements.append("\(title): \(gap)pt")
                if let export {
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: export.appendingPathComponent("account-spacing-\(title).png"))
                }
            }
        }
        if let export {
            try Data(measurements.joined(separator: "\n").utf8)
                .write(to: export.appendingPathComponent("account-spacing.txt"))
        }
    }

    func testHeaderRendersExpectedIssuePixelsAtPanelWidthAcrossAppearancesAndDensities() throws {
        let suite = "OpenUsageTests.StatusHeader.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = ProcessInfo.processInfo.environment["OPENUSAGE_STATUS_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }

        for density in DensitySetting.allCases {
            defaults.set(density.rawValue, forKey: DensitySetting.key)
            for appearance in [ColorScheme.light, .dark] {
                for refreshing in [false, true] {
                    for disrupted in [false, true] {
                        let variant = "\(density.rawValue)-\(appearance)-\(refreshing ? "refreshing" : "idle")-\(disrupted ? "issue" : "neutral")"
                        let view = header(refreshing: refreshing, disrupted: disrupted)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .frame(width: PanelHeightController.panelWidth)
                            .background(appearance == .light ? Color.white : Color.black)
                            .environment(\.colorScheme, appearance)
                            .defaultAppStorage(defaults)
                        try withHosting(view) { hosting, _ in
                            XCTAssertEqual(hosting.bounds.width, PanelHeightController.panelWidth, accuracy: 0.5, variant)
                            XCTAssertGreaterThan(hosting.bounds.height, 24, variant)
                            XCTAssertLessThanOrEqual(hosting.bounds.height, 52, variant)
                            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                            let counts = issuePixelCounts(in: bitmap)
                            XCTAssertEqual(counts.red > 4, disrupted, "Service issue pixels: \(variant)")
                            XCTAssertEqual(counts.orange > 4, !refreshing, "Usage warning pixels: \(variant)")
                            if let export {
                                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                                try png.write(to: export.appendingPathComponent("status-header-\(variant).png"))
                            }
                        }
                    }
                }
            }
        }
    }

    func testAccessibilityValuesWhenHostExposesSwiftUIAccessibility() throws {
        try withHosting(Text("Accessibility Control").accessibilityLabel("Accessibility Control")) { hosting, _ in
            guard !accessibilityElements(in: hosting).dropFirst().isEmpty else {
                throw XCTSkip("This test host does not expose accessibility children even for a standalone SwiftUI Text control.")
            }
        }
        try withHosting(header(refreshing: false, disrupted: true).frame(width: 276)) { hosting, window in
            let elements = accessibilityElements(in: hosting)
            let service = try XCTUnwrap(elements.first { $0.accessibilityLabel() == "Service Issue" })
            XCTAssertEqual(service.accessibilityValue() as? String, issue.accessibilityValue(providerName: "Claude"))
            let usage = try XCTUnwrap(elements.first { $0.accessibilityLabel() == "Usage Issue" })
            XCTAssertEqual(usage.accessibilityValue() as? String, warning)
            let picker = try XCTUnwrap(elements.first { $0.accessibilityLabel() == "Usage Account" })
            XCTAssertEqual(picker.accessibilityValue() as? String, accountName)
            XCTAssertGreaterThan(service.accessibilityFrame().width, 0)
            XCTAssertGreaterThan(picker.accessibilityFrame().width, 0)
            XCTAssertLessThanOrEqual(service.accessibilityFrame().maxX, picker.accessibilityFrame().minX)
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(picker.accessibilityFrame()))
        }
    }

    func testSeparateAccountTitlesKeepIssueIndicatorsVisibleAcrossAppearancesAndDensities() throws {
        let suite = "OpenUsageTests.SeparateStatusHeader.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = ProcessInfo.processInfo.environment["OPENUSAGE_STATUS_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }

        for density in DensitySetting.allCases {
            defaults.set(density.rawValue, forKey: DensitySetting.key)
            for appearance in [ColorScheme.light, .dark] {
                for refreshing in [false, true] {
                    let variant = "separate-\(density.rawValue)-\(appearance)-\(refreshing ? "refreshing" : "idle")"
                    let view = header(refreshing: refreshing, disrupted: true, mode: .separateCards)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .frame(width: PanelHeightController.panelWidth)
                        .background(appearance == .light ? Color.white : Color.black)
                        .environment(\.colorScheme, appearance)
                        .defaultAppStorage(defaults)
                    try withHosting(view) { hosting, _ in
                        XCTAssertEqual(hosting.bounds.width, PanelHeightController.panelWidth, accuracy: 0.5, variant)
                        XCTAssertLessThanOrEqual(hosting.bounds.height, 52, variant)
                        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                        let counts = issuePixelCounts(in: bitmap)
                        XCTAssertGreaterThan(counts.red, 4, "Service issue pixels: \(variant)")
                        XCTAssertEqual(counts.orange > 4, !refreshing, "Usage warning pixels: \(variant)")
                        if let export {
                            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            try png.write(to: export.appendingPathComponent("status-header-\(variant).png"))
                        }
                    }
                }
            }
        }
    }

    private func header(
        refreshing: Bool,
        disrupted: Bool,
        mode: AccountCardDisplayMode = .singleCard
    ) -> ProviderSectionHeader {
        ProviderSectionHeader(
            provider: MockData.claude,
            displayName: AccountCardPresentationPlanner.cardTitle(
                providerID: "claude", fallback: "Claude", mode: mode, accountName: accountName
            ),
            plan: "Max 20x",
            warning: warning,
            serviceStatus: disrupted ? .disrupted(issue) : .unknown,
            refreshing: refreshing,
            staleness: StalenessHint(label: "Outdated", tooltip: "Updated 20 minutes ago"),
            onCopyScreenshot: { true },
            accountOptions: mode == .singleCard
                ? [.init(id: "claude", title: accountName), .init(id: "claude@work", title: "Work")]
                : [],
            selectedAccountID: "claude",
            onSelectAccount: { _ in },
            accountCount: mode == .singleCard ? 2 : 0
        )
    }

    private func withHosting<Content: View>(
        _ view: Content,
        inspect: (NSHostingView<Content>, NSWindow) throws -> Void
    ) rethrows {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 320, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        try inspect(hosting, window)
    }

    private func issuePixelCounts(in bitmap: NSBitmapImageRep) -> (red: Int, orange: Int) {
        var red = 0
        var orange = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.65, color.greenComponent < 0.45, color.blueComponent < 0.55 { red += 1 }
                if color.redComponent > 0.7, color.greenComponent > 0.45,
                   color.greenComponent < 0.8, color.blueComponent < 0.35 { orange += 1 }
            }
        }
        return (red, orange)
    }

    private func accessibilityElements(in element: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
        [element] + (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
            .flatMap { accessibilityElements(in: $0) }
    }
}
