import Foundation

/// OpenCode provider의 typed failure — telemetry가 안정된 category로 그룹화 (`ErrorCategory.swift` 참고).
enum OpenCodeUsageError: Error, LocalizedError, Equatable {
    case notLoggedIn
    /// `auth.json`이 존재하나 읽기·parse 불가 — logout이 아닌 손상 storage.
    /// `detail`은 로그 파일용 원인, 사용자용 설명은 friendly하게 유지.
    case credentialsUnreadable(detail: String)
    /// 디스크에 database가 있으나 이번 refresh에서 하나도 읽지 못한 상태.
    /// 빈 scan으로 확정값처럼 보이는 $0 meter를 그리는 대신 크게 실패.
    case databaseUnreadable

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first."
        case .credentialsUnreadable:
            return "Couldn't read OpenCode's auth.json. Check its file permissions or log into OpenCode Go again."
        case .databaseUnreadable:
            return "Couldn't read OpenCode's local database. Quit OpenCode and refresh, or check the data directory's permissions."
        }
    }
}

/// OpenCode-hosted 사용량(Go 구독 + Zen pay-as-you-go gateway)을 로컬 SQLite 로그에서 추적.
/// cookie·network 불필요 (`OpenCodeUsageScanner` 참고) — 카드는 Go plan cap 달러 meter + local spend tile + usage trend 표시.
@MainActor
final class OpenCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: "opencode",
        displayName: "OpenCode",
        icon: .providerMark("opencode"),
        links: [
            .init(label: "Dashboard", url: "https://opencode.ai/auth")
        ]
    )

    let authStore: OpenCodeAuthStore
    let usageScanner: OpenCodeUsageScanner
    let now: @Sendable () -> Date

    /// hover 시 표기할 로컬 소스 이름 — 이 머신만 집계하므로 실제 계정 사용량보다 적게만 나옴.
    /// OpenCode가 메시지별 cost를 직접 기록한 측정값이라 "(estimated)" 미표기.
    private let sourceNote = "From your OpenCode logs"

    /// auth 읽기 실패 로그의 edge-trigger — 지속적으로 읽기 불가한 `auth.json`은 5분 refresh마다가 아닌 실행당 1회만 경고.
    private var loggedAuthReadFailure = false

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        usageScanner: OpenCodeUsageScanner = OpenCodeUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageScanner = usageScanner
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        // Go plan cap은 로컬 `opencode-go` spend에서 계산(Session/Weekly는 상단 노출, Monthly는 on demand)
        // 하단 spend tile + trend는 OpenCode-hosted(Go + Zen) 합산 spend
        [
            .boundedDollars(id: "opencode.session", provider: provider, title: "Session", limit: OpenCodeUsageMapper.sessionCap)
                .supportingSoftLimit(.fiveHours)
                .exportingLimit("session", unit: "usd", estimated: true),
            .boundedDollars(id: "opencode.weekly", provider: provider, title: "Weekly", limit: OpenCodeUsageMapper.weeklyCap)
                .supportingSoftLimit(.weekly)
                .exportingLimit("weekly", unit: "usd", estimated: true),
            .boundedDollars(id: "opencode.monthly", provider: provider, title: "Monthly", limit: OpenCodeUsageMapper.monthlyCap)
                .exportingLimit("monthly", unit: "usd", estimated: true),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: false,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // `refresh()`와 동일 소스(로컬 `opencode-go` auth key 또는 로컬 database의 hosted usage) — local 전용, main actor 밖 수행
        // 읽기 불가 auth.json도 OpenCode 흔적 — provider를 활성화해 `refresh()`가 실행 가능한 에러를 노출하게 함
        await loadOffMainActor { [authStore, usageScanner] in
            do {
                if try authStore.goAPIKey() != nil { return true }
            } catch {
                return true
            }
            return usageScanner.hasHostedUsage()
        }
    }

    func refresh() async -> ProviderSnapshot {
        // refresh 전체에 단일 시각 사용 — scan cutoff·tile·trend·snapshot timestamp가 자정 경계에 걸치지 않게 함
        let refreshedAt = now()

        // 읽기 불가 auth.json이 database를 읽을 수 있는 refresh를 막으면 안 됨(Zen 사용자 유지) — 단 아무것도 없을 때 "not logged in"과는 구분 유지
        var hasGoKey = false
        var authReadError: OpenCodeUsageError?
        do {
            hasGoKey = try await loadOffMainActor { [authStore] in try authStore.goAPIKey() != nil }
            loggedAuthReadFailure = false
        } catch let error as OpenCodeUsageError {
            authReadError = error
            if case .credentialsUnreadable(let detail) = error, !loggedAuthReadFailure {
                loggedAuthReadFailure = true
                AppLog.warn(LogTag.plugin("opencode"), "auth.json unreadable: \(detail)")
            }
        } catch {
            authReadError = .credentialsUnreadable(detail: error.localizedDescription)
        }

        let scan: OpenCodeUsageScan?
        do {
            scan = try await usageScanner.scan(now: refreshedAt, hasGoKey: hasGoKey)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        guard let scan else {
            // 디스크에 OpenCode database가 전혀 없는 경우
            if hasGoKey {
                // 첫 로컬 메시지 이전의 Go 신규 로그인 — key만으로 plan 확정, "No usage data" 대신 공표 cap을 $0으로 표시
                let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: nil, now: refreshedAt)
                return ProviderSnapshot.make(
                    provider: provider, plan: "Go",
                    lines: OpenCodeUsageMapper.meterLines(windows), refreshedAt: refreshedAt
                )
            }
            return ProviderSnapshot.error(
                provider: provider, error: authReadError ?? OpenCodeUsageError.notLoggedIn
            )
        }

        var lines: [MetricLine] = []
        if let windows = scan.goWindows {
            lines.append(contentsOf: OpenCodeUsageMapper.meterLines(windows))
        }
        SpendTileMapper.appendTokenUsage(
            scan.logScan.series, to: &lines, now: refreshedAt,
            estimated: false,
            unknownModelsByDay: scan.logScan.unknownModelsByDay,
            modelUsage: scan.logScan.modelUsage,
            modelSourceNote: sourceNote
        )
        SpendTileMapper.appendUsageTrend(scan.logScan.series, to: &lines, now: refreshedAt, note: sourceNote)
        MetricLine.appendNoDataIfNeeded(&lines)

        // `goWindows`는 현재 Go 신호(key 또는 최근 spend)일 때만 존재, stale anchor로는 생기지 않음 — plan badge의 정직한 근거
        let plan: String? = scan.goWindows != nil ? "Go" : nil
        return ProviderSnapshot.make(
            provider: provider,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: ProviderUsageHistory(
                series: scan.logScan.series,
                modelUsage: scan.logScan.modelUsage,
                unknownModelsByDay: scan.logScan.unknownModelsByDay
            )
        )
    }
}
