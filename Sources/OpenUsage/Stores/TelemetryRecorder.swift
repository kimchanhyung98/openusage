import Foundation

/// `app_daily_active`에 실리는 하루 1회 configuration snapshot — 모든 값은 안정적 ID·enum
struct TelemetryConfigSnapshot: Sendable {
    let enabledProviders: [String]
    let enabledMetricIDs: [String]
    let pinnedMetricIDs: [String]
    let expandedMetricIDs: [String]
    let menuBarStyle: String

    /// telemetry 익명성 계약 — 계정 card id(`claude@ab12cd34`)는 identity 파생·개수는 per-user라
    /// 보고되는 모든 id를 family로 collapse
    static func collapsingAccountCards(
        enabledProviders: [String],
        enabledMetricIDs: [String],
        pinnedMetricIDs: [String],
        expandedMetricIDs: [String],
        menuBarStyle: String,
        providerIDForMetric: (String) -> String?
    ) -> TelemetryConfigSnapshot {
        func dedupe(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }
        }
        func familyMetricID(_ metricID: String) -> String {
            guard let providerID = providerIDForMetric(metricID),
                  ProviderAccountID.isAccountCard(providerID),
                  metricID.hasPrefix("\(providerID).")
            else { return metricID }
            return "\(ProviderAccountID.family(of: providerID))\(metricID.dropFirst(providerID.count))"
        }
        return TelemetryConfigSnapshot(
            enabledProviders: dedupe(enabledProviders.map(ProviderAccountID.family(of:))),
            enabledMetricIDs: dedupe(enabledMetricIDs.map(familyMetricID)),
            pinnedMetricIDs: dedupe(pinnedMetricIDs.map(familyMetricID)),
            expandedMetricIDs: dedupe(expandedMetricIDs.map(familyMetricID)),
            menuBarStyle: menuBarStyle
        )
    }
}

/// raw refresh 결과를 일일 rollup event 2종으로 변환 — 하루 1 event 강제로 5분 timer의 pipeline flood 방지
/// `app_daily_active`는 local day당 1회 (DAU + config snapshot), `provider_refresh_daily`는 provider·일 단위 누적 후 날짜 변경 시 방출
/// telemetry off 동안 모든 작업 생략 — opt-out은 no-op sink가 아닌 hard stop
@MainActor
final class TelemetryRecorder {
    private let sink: TelemetrySink
    private let store: TelemetryStore
    private let snapshot: @MainActor () -> TelemetryConfigSnapshot
    private let now: () -> Date

    init(
        sink: TelemetrySink,
        store: TelemetryStore,
        snapshot: @escaping @MainActor () -> TelemetryConfigSnapshot,
        now: @escaping () -> Date = Date.init
    ) {
        self.sink = sink
        self.store = store
        self.snapshot = snapshot
        self.now = now
    }

    var isEnabled: Bool { store.enabled }

    /// 사용자의 공유 선택을 beta-wipe에도 살아남는 store에 persist하고 SDK에 반영 — 미변경 시 no-op
    func setEnabled(_ enabled: Bool) {
        guard store.enabled != enabled else { return }
        store.enabled = enabled
        sink.setEnabled(enabled)
        AppLog.info(.config, "telemetry \(enabled ? "enabled" : "disabled") by user")
    }

    /// 매 refresh pass 실행 — 전일 counter flush 후 local day당 1회 `app_daily_active` 방출
    func tick() {
        guard store.enabled else { return }
        let today = Self.dayString(now())
        flushStaleCounters(today: today)
        if store.activeDay != today {
            store.activeDay = today
            emitDailyActive()
        }
    }

    /// provider refresh 결과 1건 기록 — `.refreshed`/`.failed`만 집계, cache hit·skip·backoff는 timer 잡음이라 제외
    func record(providerID: String, outcome: WidgetDataStore.RefreshOutcome, category: ErrorCategory?, manual: Bool) {
        guard store.enabled else { return }
        guard outcome == .refreshed || outcome == .failed else { return }

        let today = Self.dayString(now())
        var counters = store.providerCounters()
        // 전일 counter는 자체 event로 rollover 후 오늘분 누적
        if let existing = counters[providerID], existing.day != today {
            emitProviderRollup(providerID: providerID, counter: existing)
            counters[providerID] = nil
        }
        var counter = counters[providerID] ?? ProviderDailyCounter(day: today)
        switch outcome {
        case .refreshed:
            counter.success += 1
        case .failed:
            counter.failure += 1
            counter.errors[(category ?? .other).rawValue, default: 0] += 1
        default:
            break
        }
        if manual { counter.manual += 1 }
        counters[providerID] = counter
        store.setProviderCounters(counters)
    }

    func flush() {
        guard store.enabled else { return }
        sink.flush()
    }

    // MARK: - Internals

    /// `today` 외 날짜에 속한 provider counter 전부 방출 후 제거
    private func flushStaleCounters(today: String) {
        var counters = store.providerCounters()
        var changed = false
        for (providerID, counter) in counters where counter.day != today {
            emitProviderRollup(providerID: providerID, counter: counter)
            counters[providerID] = nil
            changed = true
        }
        if changed { store.setProviderCounters(counters) }
    }

    private func emitDailyActive() {
        let config = snapshot()
        sink.capture("app_daily_active", [
            "install_id": store.installID,
            "app_version": AppInfo.version,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "enabled_providers": config.enabledProviders,
            "enabled_metric_ids": config.enabledMetricIDs,
            "pinned_metric_ids": config.pinnedMetricIDs,
            "expanded_metric_ids": config.expandedMetricIDs,
            "menu_bar_style": config.menuBarStyle
        ])
        sink.flush()
    }

    private func emitProviderRollup(providerID: String, counter: ProviderDailyCounter) {
        sink.capture("provider_refresh_daily", Self.providerRollupProperties(providerID: providerID, counter: counter))
        sink.flush()
    }

    private static func providerRollupProperties(providerID: String, counter: ProviderDailyCounter) -> [String: Any] {
        var properties: [String: Any] = [
            "provider_id": providerID,
            "success_count": counter.success,
            "failure_count": counter.failure,
            "error_categories": counter.errors,
            "manual_refresh_count": counter.manual
        ]

        for category in ErrorCategory.allCases {
            properties["\(category.rawValue)_failure_count"] = counter.errors[category.rawValue] ?? 0
        }

        let expectedFailureCount = [ErrorCategory.notLoggedIn, .notAvailable].reduce(0) { total, category in
            total + (counter.errors[category.rawValue] ?? 0)
        }
        properties["expected_failure_count"] = expectedFailureCount
        properties["unexpected_failure_count"] = max(0, counter.failure - expectedFailureCount)
        return properties
    }

    /// local calendar 기준 `yyyy-MM-dd` — 사용자 체감 하루와 일치 (UTC 아님), calendar는 테스트 주입 가능
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
