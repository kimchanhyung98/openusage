import Foundation

@MainActor
final class CopilotProvider: ProviderRuntime {
    /// Copilot credit usage를 실은 org slug를 caching하는 `UserDefaults` key — steady-state refresh는 모든 org 재탐색 대신 billing 호출 1회.
    static let billingOrgDefaultsKey = "copilot.billingOrg"

    let provider = Provider(
        id: "copilot",
        displayName: "Copilot",
        icon: .providerMark("copilot"),
        links: [
            .init(label: "Status", url: "https://www.githubstatus.com/"),
            .init(label: "Dashboard", url: "https://github.com/settings/billing")
        ]
    )

    let authStore: CopilotAuthStore
    let usageClient: CopilotUsageClient
    let orgBillingClient: CopilotOrgBillingClient
    let defaults: UserDefaults
    let now: @Sendable () -> Date

    init(
        authStore: CopilotAuthStore = CopilotAuthStore(),
        usageClient: CopilotUsageClient = CopilotUsageClient(),
        orgBillingClient: CopilotOrgBillingClient = CopilotOrgBillingClient(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.orgBillingClient = orgBillingClient
        self.defaults = defaults
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "copilot.premium", provider: provider, title: "Credits")
                .exportingLimit("premiumCredits", unit: "percent"),
            .values(id: "copilot.extra", provider: provider, title: "Extra Usage", selection: .kind(.count))
                .exportingLimit("extraUsage", unit: "count", source: .value(kind: .count)),
            .values(id: "copilot.orgCredits", provider: provider, title: "Org Credits", selection: .kind(.count))
                .exportingLimit("orgCredits", unit: "credits", source: .value(kind: .count, label: "credits")),
            .values(id: "copilot.orgSpend", provider: provider, title: "Org Spend", selection: .kind(.dollars), valueWord: "spent")
                .exportingLimit("orgSpend", unit: "usd", source: .value(kind: .dollars)),
            .percent(id: "copilot.chat", provider: provider, title: "Chat")
                .exportingLimit("chat", unit: "percent"),
            .percent(id: "copilot.completions", provider: provider, title: "Completions")
                .exportingLimit("completions", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // `refresh()`와 같은 source: 에디터 config, gh config, gh keychain 항목.
        await loadOffMainActor { [authStore] in authStore.loadToken() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        let token = await loadOffMainActor { [authStore] in authStore.loadToken() }
        guard let token else {
            return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.notLoggedIn)
        }

        do {
            let response = try await usageClient.fetchUsage(token: token.value)

            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.tokenInvalid)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.requestFailed(response.statusCode))
            }

            let mapped = try CopilotUsageMapper.map(response)

            // org 관리(token-based-billing) seat는 per-seat quota가 없어 실제 usage는 org billing에 존재. best-effort 조회 — org admin은 Org Credits/Org Spend, 그 외는 기존 plan 전용 카드 유지. mapper의 명시적 flag로만 gate — `lines` 빈 여부로 gate 금지 (issue #839).
            var lines = mapped.lines
            if mapped.isOrgManagedSeat {
                lines = await orgBillingLines(token: token.value)
            }

            return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: lines, refreshedAt: now())
        } catch let error as CopilotUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.connectionFailed)
        }
    }

    // MARK: - Org billing lookup

    /// org 관리 seat의 org 단위 Copilot billing line. cached org 우선, 다음 사용자의 모든 org를 probe해 Copilot credit usage를 실은 첫 org 기억.
    /// 아무것도 못 읽으면 `[]` — 일반 org member의 403은 *기대된* 결과(owner·billing manager만 org billing 읽기 가능)라 provider 오류 대신 plan 전용 카드로 강등.
    private func orgBillingLines(token: String) async -> [MetricLine] {
        if let cached = defaults.string(forKey: Self.billingOrgDefaultsKey) {
            do {
                if let lines = try await usageLines(org: cached, token: token) {
                    return lines
                }
                // cached org가 응답했지만 더 이상 Copilot usage 없음(org 탈퇴, billing 역할 상실, org의 Copilot 중단) — 잊고 처음부터 재탐색.
                defaults.removeObject(forKey: Self.billingOrgDefaultsKey)
            } catch {
                // 일시 실패 — 로그만 남기고 cached org는 다음 refresh를 위해 유지.
                AppLog.warn(LogTag.plugin("copilot"), "org billing lookup failed for the remembered org: \(error.localizedDescription)")
                return []
            }
        }

        let orgs: [String]
        do {
            let response = try await orgBillingClient.fetchUserOrgs(token: token)
            guard response.statusCode == 200 else {
                // 여기의 403은 token에 `read:org` 부재(에디터 플러그인 token 가능) — 기대된 상태, 오류 아님. 그 외도 진단 로그만, 카드 실패는 없음.
                AppLog.info(LogTag.plugin("copilot"), "org list HTTP \(response.statusCode); skipping org billing lookup")
                return []
            }
            orgs = CopilotOrgBillingMapper.orgLogins(response)
        } catch {
            AppLog.warn(LogTag.plugin("copilot"), "org list fetch failed: \(error.localizedDescription)")
            return []
        }

        for org in orgs {
            do {
                if let lines = try await usageLines(org: org, token: token) {
                    defaults.set(org, forKey: Self.billingOrgDefaultsKey)
                    return lines
                }
            } catch {
                // 한 org의 billing 장애가 다른 org의 usage를 가리면 안 됨 — 계속 probe.
                AppLog.warn(LogTag.plugin("copilot"), "org billing summary failed for one org; trying the next: \(error.localizedDescription)")
            }
        }
        return []
    }

    /// org 하나의 billing summary → metric line, 확정적으로 보여줄 게 없으면 nil(접근 불가 — 일반 member의 기대된 403 — 또는 summary에 Copilot credit usage 없음).
    /// 일시 실패(transport 오류, 429, 5xx)는 throw — 호출자가 짧은 장애를 stale org로 오인하지 않고 cached org 유지.
    private func usageLines(org: String, token: String) async throws -> [MetricLine]? {
        let response = try await orgBillingClient.fetchUsageSummary(org: org, token: token)
        guard response.statusCode == 200 else {
            AppLog.debug(LogTag.plugin("copilot"), "org billing summary for one org: HTTP \(response.statusCode)")
            if response.statusCode == 429 || response.statusCode >= 500 {
                throw CopilotUsageError.requestFailed(response.statusCode)
            }
            return nil
        }
        return CopilotOrgBillingMapper.usageLines(response)
    }
}
