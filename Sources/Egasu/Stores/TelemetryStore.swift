import Foundation

/// provider별 하루 누적 tally — restart에도 유지, 날짜 변경 시 `provider_refresh_daily` 1건으로 방출
struct ProviderDailyCounter: Codable, Sendable, Equatable {
    var day: String
    var success = 0
    var failure = 0
    var manual = 0
    /// 안정적 `ErrorCategory` raw value → count — message·PII 없음
    var errors: [String: Int] = [:]
    var providerID: String?
    var appVersion: String?
    var buildChannel: String?
    var triggers: [String: Int]?
    var degraded: Int?

    var storageKey: String {
        [day, providerID ?? "unknown", appVersion ?? "legacy", buildChannel ?? "unknown"].joined(separator: "|")
    }
}

/// 전용 `UserDefaults` suite(`<bundle id>.telemetry`)의 telemetry bookkeeping
/// 앱 설정 domain과 격리 — 설정 변경이 opt-out을 되돌리거나 install id를 재발급해 DAU를 부풀리는 일 방지
@MainActor
final class TelemetryStore {
    private let defaults: UserDefaults

    private static let installIDKey = "installID"
    private static let enabledKey = "enabled"
    private static let consentStartedAtKey = "consentStartedAt"
    private static let activeDayKey = "activeDay"
    private static let providerDaysKey = "providerDays"

    static var suiteName: String {
        let base = (Bundle.main.bundleIdentifier ?? "com.openusage.app") + ".telemetry"
        return TelemetryConfig.buildChannel == "development" ? base + ".development" : base
    }

    /// `defaults`는 테스트 주입용 — production은 전용 suite, 열기 실패 시에만 standard fallback
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    /// 안정적 익명 install id (random UUID) — 최초 읽기에 1회 발급 후 재사용
    var installID: String {
        if let existing = defaults.string(forKey: Self.installIDKey) { return existing }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: Self.installIDKey)
        return minted
    }

    /// telemetry on/off — personal fork는 opt-in 전까지 기본 off
    var enabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey, default: false) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var consentID: String {
        get {
            if let value = defaults.string(forKey: "consentID"), UUID(uuidString: value) != nil { return value }
            let value = UUID().uuidString
            defaults.set(value, forKey: "consentID")
            return value
        }
        set { defaults.set(newValue, forKey: "consentID") }
    }

    var consentStartedAt: Date {
        get {
            if let saved = defaults.object(forKey: Self.consentStartedAtKey) as? Date { return saved }
            let started = Date()
            defaults.set(started, forKey: Self.consentStartedAtKey)
            return started
        }
        set { defaults.set(newValue, forKey: Self.consentStartedAtKey) }
    }

    /// `app_daily_active`를 마지막으로 방출한 local day (`yyyy-MM-dd`), 없으면 nil
    var activeDay: String? {
        get { defaults.string(forKey: Self.activeDayKey) }
        set { defaults.set(newValue, forKey: Self.activeDayKey) }
    }

    func providerCounters() -> [String: ProviderDailyCounter] {
        guard let data = defaults.data(forKey: Self.providerDaysKey) else { return [:] }
        do {
            let stored = try JSONDecoder().decode([String: ProviderDailyCounter].self, from: data)
            var counters: [String: ProviderDailyCounter] = [:]
            for (key, value) in stored {
                guard let family = TelemetryPrivacy.providerFamily(value.providerID ?? key) else { continue }
                var counter = value
                counter.providerID = family
                counter.errors = counter.errors.filter { ErrorCategory(rawValue: $0.key) != nil }
                if var existing = counters[counter.storageKey] {
                    existing.success += counter.success
                    existing.failure += counter.failure
                    existing.manual += counter.manual
                    existing.degraded = (existing.degraded ?? 0) + (counter.degraded ?? 0)
                    for (category, count) in counter.errors { existing.errors[category, default: 0] += count }
                    if var triggers = existing.triggers, let added = counter.triggers {
                        for (trigger, count) in added { triggers[trigger, default: 0] += count }
                        existing.triggers = triggers
                    } else {
                        existing.triggers = nil
                    }
                    counters[counter.storageKey] = existing
                } else {
                    counters[counter.storageKey] = counter
                }
            }
            if counters != stored { setProviderCounters(counters) }
            return counters
        } catch {
            AppLog.error(.config, "telemetry counters could not be decoded; resetting invalid counters")
            defaults.removeObject(forKey: Self.providerDaysKey)
            return [:]
        }
    }

    func setProviderCounters(_ counters: [String: ProviderDailyCounter]) {
        guard let data = try? JSONEncoder().encode(counters) else {
            AppLog.error(.config, "failed to persist telemetry counters")
            return
        }
        defaults.set(data, forKey: Self.providerDaysKey)
    }
    func featureCounters() -> [String: FeatureDailyCounter] {
        guard let data = defaults.data(forKey: "featureDays.v2") else { return [:] }
        do { return try JSONDecoder().decode([String: FeatureDailyCounter].self, from: data) }
        catch {
            AppLog.error(.config, "telemetry feature counters could not be decoded; resetting invalid counters")
            defaults.removeObject(forKey: "featureDays.v2")
            return [:]
        }
    }

    func setFeatureCounters(_ counters: [String: FeatureDailyCounter]) {
        do { defaults.set(try JSONEncoder().encode(counters), forKey: "featureDays.v2") }
        catch { AppLog.error(.config, "failed to persist telemetry feature counters") }
    }

    var featureFailures: Set<String> {
        get { Set(defaults.stringArray(forKey: "featureFailures.v2") ?? []) }
        set { defaults.set(Array(newValue), forKey: "featureFailures.v2") }
    }

    func allowImmediateDiagnostic(day: String) -> Bool {
        if defaults.string(forKey: "diagnosticEmissionDay") != day {
            defaults.set(day, forKey: "diagnosticEmissionDay")
            defaults.set(0, forKey: "diagnosticEmissionCount")
        }
        let count = defaults.integer(forKey: "diagnosticEmissionCount")
        guard count < 30 else { return false }
        defaults.set(count + 1, forKey: "diagnosticEmissionCount")
        return true
    }

    func discardPendingCounters() {
        setProviderCounters([:])
        setFeatureCounters([:])
        featureFailures = []
    }

}
