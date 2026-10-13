import XCTest
@testable import OpenUsage

final class RefreshSchedulePresentationTests: XCTestCase {
    func testRowsOmitNilGroupsAndKeepClaudeRetryAsSeparateRow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = RefreshSchedulePresentation.rows(
            general: now.addingTimeInterval(300), claude: now.addingTimeInterval(900),
            claudeRetry: now.addingTimeInterval(7200), resetWatch: nil, codexTimer: now.addingTimeInterval(60)
        )
        XCTAssertEqual(rows.map(\.id), ["general", "claude", "claudeRetry", "codexTimer"])
        XCTAssertEqual(rows.map { $0.text(at: now) }, [
            "General in 5m", "Claude in 15m", "Claude Retry in 120m", "Codex Timer in 1m"
        ])
        XCTAssertTrue(RefreshSchedulePresentation.rows(
            general: nil, claude: nil, claudeRetry: nil, resetWatch: nil, codexTimer: nil
        ).isEmpty)
    }
}
