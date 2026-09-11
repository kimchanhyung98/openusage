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

/// 프로바이더·기능 결과를 일일 집계하며 제한된 실패·복구만 즉시 전달.
/// 계정별 값은 family로 합산하고 수집 날짜·버전별 집계 경계 유지.
/// 공유 OFF 동안 집계·전송 중단, 기존 미전송 집계 폐기.
@MainActor
final class TelemetryRecorder {
    private let sink: TelemetrySink
    private let store: TelemetryStore
    private let snapshot: @MainActor () -> TelemetryConfigSnapshot
    private let now: () -> Date
    private let heartbeatSleep: @Sendable () async throws -> Void
    private let appVersion: String
    private let buildChannel: String
    private var diagnosticsStarted = false
    private var diagnosticObserver: UUID?

    init(
        sink: TelemetrySink,
        store: TelemetryStore,
        snapshot: @escaping @MainActor () -> TelemetryConfigSnapshot,
        now: @escaping () -> Date = Date.init,
        heartbeatSleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(60)) },
        appVersion: String = AppInfo.version,
        buildChannel: String = TelemetryConfig.buildChannel
    ) {
        self.sink = sink
        self.store = store
        self.snapshot = snapshot
        self.now = now
        self.heartbeatSleep = heartbeatSleep
        self.appVersion = appVersion
        self.buildChannel = buildChannel
        if !store.enabled { store.discardPendingCounters() }
    }

    var isEnabled: Bool { store.enabled }

    /// 사용자의 공유 선택을 beta-wipe에도 살아남는 store에 persist하고 SDK에 반영 — 미변경 시 no-op
    func setEnabled(_ enabled: Bool) {
        guard store.enabled != enabled else { return }
        store.enabled = enabled
        if enabled {
            store.consentStartedAt = now()
            store.consentID = UUID().uuidString
        }
        if !enabled { store.discardPendingCounters() }
        sink.setEnabled(enabled)
        updateDiagnosticSubscription()
        if enabled { tick() }
        AppLog.info(.config, "telemetry \(enabled ? "enabled" : "disabled") by user")
    }

    /// refresh 시작과 독립 heartbeat에서 호출 — 전일 집계 전송 후 현지 날짜별 활성 이벤트 1회 기록.
    func tick() {
        guard store.enabled, sink.isAvailable else { return }
        let today = Self.dayString(now())
        flushStaleCounters(today: today)
        flushStaleFeatureCounters(today: today)
        if store.activeDay != today {
            store.activeDay = today
            emitDailyActive()
        }
    }

    /// provider refresh 결과 1건 기록 — `.refreshed`/`.failed`만 집계, cache hit·skip·backoff는 timer 잡음이라 제외
    func record(providerID: String, outcome: WidgetDataStore.RefreshOutcome, category: ErrorCategory?, trigger: RefreshTrigger, degraded: Bool = false) {
        guard store.enabled else { return }
        guard outcome == .refreshed || outcome == .failed else { return }

        guard let family = TelemetryPrivacy.providerFamily(providerID) else { return }
        let today = Self.dayString(now())
        flushStaleCounters(today: today)
        var counters = store.providerCounters()
        let fresh = ProviderDailyCounter(
            day: today, providerID: family, appVersion: appVersion, buildChannel: buildChannel
        )
        var counter = counters[fresh.storageKey] ?? fresh
        switch outcome {
        case .refreshed:
            counter.success += 1
        case .failed:
            counter.failure += 1
            counter.errors[(category ?? .other).rawValue, default: 0] += 1
        default:
            break
        }
        if trigger == .manual { counter.manual += 1 }
        var triggers = counter.triggers ?? [:]
        triggers[trigger.rawValue, default: 0] += 1
        counter.triggers = triggers
        if degraded { counter.degraded = (counter.degraded ?? 0) + 1 }
        counters[counter.storageKey] = counter
        store.setProviderCounters(counters)
        recordDiagnostic(DiagnosticEvent(
            .providerRefresh, result: outcome == .failed ? .failure : (degraded ? .degraded : .success),
            category: category, providerID: family
        ))
    }

    func flush() {
        guard store.enabled else { return }
        sink.flush()
    }

    func runHeartbeat() async {
        while !Task.isCancelled {
            tick()
            do { try await heartbeatSleep() }
            catch { return }
        }
    }

    func startDiagnostics() {
        diagnosticsStarted = true
        updateDiagnosticSubscription()
    }

    func stopDiagnostics() {
        diagnosticsStarted = false
        updateDiagnosticSubscription()
    }

    private func updateDiagnosticSubscription() {
        if let diagnosticObserver { AppDiagnostics.removeObserver(diagnosticObserver) }
        diagnosticObserver = nil
        guard diagnosticsStarted, store.enabled else { return }
        diagnosticObserver = AppDiagnostics.observe { [weak self] event, subscription in
            Task { @MainActor in
                guard AppDiagnostics.isCurrent(subscription) else { return }
                self?.recordDiagnostic(event)
            }
        }
    }

    func recordDiagnostic(_ event: DiagnosticEvent) {
        guard store.enabled else { return }
        let today = Self.dayString(now())
        flushStaleFeatureCounters(today: today)
        var failures = store.featureFailures
        var event = event
        let unexpected = event.category != .notLoggedIn && event.category != .notAvailable
        if event.operation.tracksRecovery, event.result == .success, failures.remove(event.stateKey) != nil {
            event = DiagnosticEvent(event.operation, result: .recovered, providerID: event.provider)
        } else if event.operation.tracksRecovery, unexpected, event.result == .failure || event.result == .degraded {
            failures.insert(event.stateKey)
        }
        store.featureFailures = failures
        var counters = store.featureCounters()
        let fresh = FeatureDailyCounter(day: today, appVersion: appVersion, buildChannel: buildChannel, event: event)
        var counter = counters[fresh.storageKey] ?? fresh
        counter.count += 1
        let immediate = (event.result == .failure || event.result == .degraded || event.result == .recovered) && unexpected
        if immediate, !counter.reported, sink.isAvailable, store.allowImmediateDiagnostic(day: today) {
            emitFeature(counter, name: "feature_operation_result")
            counter.reported = true
        }
        counters[counter.storageKey] = counter
        store.setFeatureCounters(counters)
    }

    private func flushStaleFeatureCounters(today: String) {
        guard sink.isAvailable else { return }
        var counters = store.featureCounters()
        var changed = false
        for (key, counter) in counters where counter.day != today {
            emitFeature(counter, name: "feature_operation_daily")
            counters[key] = nil
            changed = true
        }
        if changed { store.setFeatureCounters(counters) }
    }

    private func emitFeature(_ counter: FeatureDailyCounter, name: String) {
        var properties: [String: Any] = [
            "schema_version": 2, "day": counter.day, "app_version": counter.appVersion,
            "build_channel": counter.buildChannel, "feature": counter.event.operation.feature,
            "operation": counter.event.operation.rawValue, "result": counter.event.result.rawValue,
            "error_category": counter.event.category?.rawValue ?? "none", "count": counter.count,
        ]
        if let provider = counter.event.provider { properties["provider_id"] = provider }
        sink.capture(name, properties)
        sink.flush()
    }

    // MARK: - Internals

    /// `today` 외 날짜에 속한 provider counter 전부 방출 후 제거
    private func flushStaleCounters(today: String) {
        guard sink.isAvailable else { return }
        var counters = store.providerCounters()
        var changed = false
        for (key, counter) in counters where counter.day != today {
            emitProviderRollup(providerID: counter.providerID ?? "unknown", counter: counter)
            counters[key] = nil
            changed = true
        }
        if changed { store.setProviderCounters(counters) }
    }

    private func emitDailyActive() {
        let config = snapshot()
        sink.capture("app_daily_active", [
            "install_id": store.installID,
            "app_version": appVersion,
            "build_channel": buildChannel,
            "schema_version": 2,
            "day": Self.dayString(now()),
            "os_version": TelemetryConfig.osVersion,
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
            "day": counter.day,
            "schema_version": 2,
            "app_version": counter.appVersion ?? "legacy",
            "build_channel": counter.buildChannel ?? "unknown",
            "success_count": counter.success,
            "failure_count": counter.failure,
            "error_categories": counter.errors,
            "manual_refresh_count": counter.manual,
            "trigger_counts": counter.triggers ?? [:],
            "trigger_classification": counter.triggers == nil ? "legacy" : "explicit",
            "degraded_count": counter.degraded ?? 0
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
