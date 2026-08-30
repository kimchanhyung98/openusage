import Foundation

/// provider refresh 1회의 최신 정규화 출력.
struct ProviderSnapshot: Hashable, Sendable, Codable {
    let providerID: String
    /// refresh 시점의 provider 표시 이름 — 계정 label은 cache·iCloud에 영속하지 않고 신뢰된 로컬 CLI 복사본에만 적용.
    /// 앱 카드와 브라우저 HTTP 응답은 계정과 무관한 고정 provider 제목 사용.
    var displayName: String
    var plan: String?
    var lines: [MetricLine]
    var refreshedAt: Date
    /// spend row 구성용 raw 정규화 일별 history — 항상 이 Mac 소유.
    /// peer history는 in-memory 렌더 뷰에서만 결합, cache 미기록.
    var usageHistory: ProviderUsageHistory?
    /// 성공 snapshot에 실리는 non-blocking 알림 (예: scope 부족 시 재로그인 안내).
    /// refresh는 성공 상태 — provider header의 amber triangle로 표출, snapshot과 함께 cache, 해소 시 다음 refresh에서 제거.
    var warning: String?
    /// 오류 snapshot 전용 telemetry 분류 bucket (non-PII).
    /// 성공 시 항상 nil, 오류 snapshot은 cache되지 않아 미영속.
    var errorCategory: ErrorCategory?

    init(
        providerID: String,
        displayName: String,
        plan: String? = nil,
        lines: [MetricLine],
        refreshedAt: Date = Date(),
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil,
        errorCategory: ErrorCategory? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.plan = plan
        self.lines = lines
        self.refreshedAt = refreshedAt
        self.usageHistory = usageHistory
        self.warning = warning
        self.errorCategory = errorCategory
    }

    func line(label: String) -> MetricLine? {
        lines.first { $0.label == label }
    }

    /// `error(provider:message:)`의 성공 경로 대응 — provider에서 `providerID`/`displayName` 파생.
    /// `refreshedAt` 필수 — 각 호출이 자신의 `now()` 전달.
    static func make(
        provider: Provider,
        plan: String?,
        lines: [MetricLine],
        refreshedAt: Date,
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: usageHistory,
            warning: warning
        )
    }

    /// 잡은 `Error`에서 오류 snapshot 생성 — badge text는 `localizedDescription`, category는 `CategorizedError`에서 파생(미분류는 `.other`).
    /// `Error` 보유 시 `error(provider:message:)`보다 우선 사용.
    static func error(provider: Provider, error: Error) -> ProviderSnapshot {
        Self.error(
            provider: provider,
            message: error.localizedDescription,
            category: (error as? CategorizedError)?.errorCategory ?? .other
        )
    }

    static func error(provider: Provider, message: String, category: ErrorCategory? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.badge(label: MetricLine.errorBadgeLabel, text: message, colorHex: "#EF4444")],
            errorCategory: category
        )
    }
}
