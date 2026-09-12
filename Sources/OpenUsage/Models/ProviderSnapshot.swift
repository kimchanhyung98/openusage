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
    var authenticationIssue: ProviderAuthenticationIssue?
    /// 성공한 응답에 포함된 부분 실패 여부 — 이전 cache의 누락 필드는 nil.
    var isDegraded: Bool?
    /// 실제 quota 응답 시각 — 내부 last-good 재사용 시 제거, nil이면 자동 취소 판정 제외.
    var liveQuotaObservedAt: Date?

    init(
        providerID: String,
        displayName: String,
        plan: String? = nil,
        lines: [MetricLine],
        refreshedAt: Date = Date(),
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil,
        errorCategory: ErrorCategory? = nil,
        authenticationIssue: ProviderAuthenticationIssue? = nil,
        isDegraded: Bool? = nil,
        liveQuotaObservedAt: Date? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.plan = plan
        self.lines = lines
        self.refreshedAt = refreshedAt
        self.usageHistory = usageHistory
        self.warning = warning
        self.errorCategory = errorCategory
        self.authenticationIssue = authenticationIssue
        self.isDegraded = isDegraded
        self.liveQuotaObservedAt = liveQuotaObservedAt
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
        warning: String? = nil,
        authenticationIssue: ProviderAuthenticationIssue? = nil,
        isDegraded: Bool? = nil,
        liveQuotaObservedAt: Date? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: usageHistory,
            warning: warning,
            authenticationIssue: authenticationIssue,
            isDegraded: isDegraded,
            liveQuotaObservedAt: liveQuotaObservedAt
        )
    }

    /// 잡은 `Error`에서 오류 snapshot 생성 — badge text는 `localizedDescription`, category는 `CategorizedError`에서 파생(미분류는 `.other`).
    /// `Error` 보유 시 `error(provider:message:)`보다 우선 사용.
    static func error(provider: Provider, error: Error) -> ProviderSnapshot {
        Self.error(
            provider: provider,
            message: error.localizedDescription,
            category: (error as? CategorizedError)?.errorCategory ?? .other,
            authenticationIssue: ProviderAuthenticationIssue(error: error)
        )
    }

    static func error(
        provider: Provider,
        message: String,
        category: ErrorCategory? = nil,
        authenticationIssue: ProviderAuthenticationIssue? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.badge(label: MetricLine.errorBadgeLabel, text: message, colorHex: "#EF4444")],
            errorCategory: category,
            authenticationIssue: authenticationIssue
        )
    }
}
