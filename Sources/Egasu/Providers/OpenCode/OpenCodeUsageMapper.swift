import Foundation

/// Go plan window를 세 개의 cap meter로 변환 — 공표 cap이 달러 기반이라 `.dollars` progress meter 사용.
/// 로컬 spend는 이 머신만 집계해 실제 계정 사용량보다 적게만 나옴 — 카드가 cap과 함께 spend tile도 보여주는 이유.
enum OpenCodeUsageMapper {
    static let sessionCap: Double = 12   // rolling 5시간당
    static let weeklyCap: Double = 30    // UTC week당
    static let monthlyCap: Double = 60   // anchored month당

    static func meterLines(_ windows: OpenCodeGoWindows) -> [MetricLine] {
        [
            .progress(
                label: "Session", used: windows.sessionSpend, limit: sessionCap, format: .dollars,
                resetsAt: windows.sessionResetsAt, periodDurationMs: MetricPeriod.sessionMs
            ),
            .progress(
                label: "Weekly", used: windows.weeklySpend, limit: weeklyCap, format: .dollars,
                resetsAt: windows.weeklyResetsAt, periodDurationMs: MetricPeriod.weekMs
            ),
            .progress(
                label: "Monthly", used: windows.monthlySpend, limit: monthlyCap, format: .dollars,
                resetsAt: windows.monthlyResetsAt, periodDurationMs: windows.monthlyPeriodMs
            )
        ]
    }
}
