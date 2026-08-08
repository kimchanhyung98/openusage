import Foundation

/// provider별 하루 누적 tally — restart에도 유지, 날짜 변경 시 `provider_refresh_daily` 1건으로 방출
struct ProviderDailyCounter: Codable, Sendable, Equatable {
    var day: String
    var success = 0
    var failure = 0
    var manual = 0
    /// 안정적 `ErrorCategory` raw value → count — message·PII 없음
    var errors: [String: Int] = [:]
}

/// 전용 `UserDefaults` suite(`<bundle id>.telemetry`)의 telemetry bookkeeping
/// 앱 설정 domain과 격리 — 설정 변경이 opt-out을 되돌리거나 install id를 재발급해 DAU를 부풀리는 일 방지
@MainActor
final class TelemetryStore {
    private let defaults: UserDefaults

    private static let installIDKey = "installID"
    private static let enabledKey = "enabled"
    private static let activeDayKey = "activeDay"
    private static let providerDaysKey = "providerDays"

    static var suiteName: String { (Bundle.main.bundleIdentifier ?? "com.openusage.app") + ".telemetry" }

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

    /// `app_daily_active`를 마지막으로 방출한 local day (`yyyy-MM-dd`), 없으면 nil
    var activeDay: String? {
        get { defaults.string(forKey: Self.activeDayKey) }
        set { defaults.set(newValue, forKey: Self.activeDayKey) }
    }

    func providerCounters() -> [String: ProviderDailyCounter] {
        guard let data = defaults.data(forKey: Self.providerDaysKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ProviderDailyCounter].self, from: data)) ?? [:]
    }

    func setProviderCounters(_ counters: [String: ProviderDailyCounter]) {
        guard let data = try? JSONEncoder().encode(counters) else {
            AppLog.warn(.config, "failed to persist telemetry counters")
            return
        }
        defaults.set(data, forKey: Self.providerDaysKey)
    }
}
