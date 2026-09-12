import XCTest
@testable import OpenUsage

@MainActor
final class SoftLimitDescriptorTests: XCTestCase {
    func testDescriptorUsesExplicitWindowOptIn() {
        let provider = Provider(id: "fixture", displayName: "Fixture", icon: .providerMark("fixture"))

        let eligible = WidgetDescriptor
            .percent(id: "fixture.weekly", provider: provider, title: "Weekly")
            .supportingSoftLimit(.weekly)
        let unrelated = WidgetDescriptor
            .percent(id: "fixture.billing", provider: provider, title: "Billing")

        XCTAssertEqual(eligible.softLimitWindow, .weekly)
        XCTAssertNil(unrelated.softLimitWindow)
    }

    func testProvidersDeclareOnlyTheirFiveHourAndWeeklyQuotaRows() {
        XCTAssertEqual(windows(ClaudeProvider().widgetDescriptors), [
            "claude.session": .fiveHours,
            "claude.weekly": .weekly,
            "claude.fable": .weekly,
            "claude.sonnet": .weekly
        ])
        XCTAssertEqual(windows(CodexProvider().widgetDescriptors), [
            "codex.session": .fiveHours,
            "codex.weekly": .weekly,
            "codex.spark": .fiveHours,
            "codex.sparkWeekly": .weekly
        ])
        XCTAssertEqual(windows(AntigravityProvider().widgetDescriptors), [
            "antigravity.geminiPro": .fiveHours,
            "antigravity.geminiWeekly": .weekly,
            "antigravity.claude": .fiveHours,
            "antigravity.claudeWeekly": .weekly
        ])
        XCTAssertEqual(windows(KimiProvider().widgetDescriptors), [
            "kimi.session": .fiveHours,
            "kimi.weekly": .weekly
        ])
        XCTAssertEqual(windows(OpenCodeProvider().widgetDescriptors), [
            "opencode.session": .fiveHours,
            "opencode.weekly": .weekly
        ])
        XCTAssertEqual(windows(GrokProvider().widgetDescriptors), [
            "grok.weekly": .weekly
        ])
        XCTAssertEqual(windows(ZAIProvider().widgetDescriptors), [
            "zai.session": .fiveHours,
            "zai.weekly": .weekly
        ])
        XCTAssertTrue(windows(CursorProvider().widgetDescriptors).isEmpty)
        XCTAssertTrue(windows(CopilotProvider().widgetDescriptors).isEmpty)
        XCTAssertTrue(windows(DevinProvider().widgetDescriptors).isEmpty)
        XCTAssertTrue(windows(KiroProvider().widgetDescriptors).isEmpty)
        XCTAssertTrue(windows(OpenRouterProvider().widgetDescriptors).isEmpty)
    }

    private func windows(_ descriptors: [WidgetDescriptor]) -> [String: SoftLimitWindow] {
        Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
            descriptor.softLimitWindow.map { (descriptor.id, $0) }
        })
    }
}
