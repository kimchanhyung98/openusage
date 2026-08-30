import Foundation

public struct UsageReadResult: Sendable {
    public let data: Data
    public let warnings: [String]
}

public enum UsageReaderError: LocalizedError, Sendable {
    case unknownProvider(String)
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let providerID):
            "Unknown provider: \(providerID)"
        case .refreshFailed(let message):
            "Refresh failed: \(message)"
        }
    }
}

/// 메뉴바 앱과 동일한 provider cache·refresh 엔진의 one-shot 접근 — timer·로컬 서버·status item·updater 등 장수명 서비스 미보유.
@MainActor
public struct UsageReader {
    private let defaults: UserDefaults
    private let providersOverride: [ProviderRuntime]?

    public init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
        self.providersOverride = nil
    }

    init(userDefaults: UserDefaults, providers: [ProviderRuntime]) {
        self.defaults = userDefaults
        self.providersOverride = providers
    }

    public func read(providerID requestedProviderID: String? = nil, force: Bool = false) async throws -> UsageReadResult {
        // launch 계정 pass(`ProviderAccountAssembly`) — 카드별 계정 해석으로 캐시 snapshot guard·stamp, 앱과 동일한 카드 집합 구성(family 매칭 일치).
        // snapshot 카드는 앱 전용 — one-shot CLI는 앱 생성 Keychain item 접근 금지. 테스트 provider 주입 시 skip.
        // login-shell 캡처를 먼저 warm — MainActor read는 캡처를 트리거하지 않으므로, snapshot 없는 CLI에서 identity와 usage가 다른 home을 읽는 분열 방지.
        if providersOverride == nil {
            await Task.detached(priority: .userInitiated) {
                _ = LoginShellEnvironment.shared.ensureCaptured()
            }.value
        }
        let accountAssembly = providersOverride == nil
            ? ProviderAccountAssembly.make(defaults: defaults, waitsForLoginShell: false)
            : ProviderAccountAssembly(identityKeysByCard: [:])
        let providers = providersOverride ?? ProviderCatalog.make(
            defaults: defaults,
            hasUnregisteredClaudeLogins: accountAssembly.hasUnregisteredClaudeLogins,
            defaultClaudeExtraLogRoots: accountAssembly.defaultClaudeExtraLogRoots,
            codexSharedAuthHome: accountAssembly.codexSharedAuthHome,
            claudeManagedSwitchActive: accountAssembly.claudeManagedSwitchActive
        )
        let registry = WidgetRegistry.from(providers)
        let knownIDs = Set(registry.providers.map(\.id))
        let enablement = ProviderEnablementStore(defaults: defaults)
        // 요청 id는 plain string 매칭으로 카드 지칭(정확한 카드 id 또는 family id) — 로컬 HTTP API(`LocalUsageAPI.State.matchingCardIDs`)와 동일, runtime 상태 비의존.
        let requestedToken = requestedProviderID?.lowercased()
        let matchedIDs: Set<String>? = requestedToken.map { token in
            knownIDs.filter { $0 == token || ProviderAccountID.family(of: $0) == token }
        }
        if let requestedToken, let matchedIDs, matchedIDs.isEmpty {
            throw UsageReaderError.unknownProvider(requestedToken)
        }

        let includesProvider: @MainActor (String) -> Bool = { id in
            matchedIDs?.contains(id) ?? enablement.isEnabled(id)
        }
        let cache = ProviderSnapshotCache(userDefaults: defaults, allowsPersistedFreshness: true)
        let allProviderIDs = registry.providers.map(\.id)
        // 앱이 launch에 적용하는 것과 동일한 계정 guard — 다른 계정 소유가 증명된 entry는 미제공, TTL-fresh여도 refresh 필요로 계산.
        let staleAccountStampIDs = Set(allProviderIDs.filter {
            cache.hasStaleAccountStamp(providerID: $0, currentIdentityKey: accountAssembly.identityKeysByCard[$0])
        })
        let cachedSnapshots = cache.loadSnapshots(providerIDs: allProviderIDs)
            .filter { providerID, _ in !staleAccountStampIDs.contains(providerID) }
        let savedOrder = LayoutPersistence(
            defaults: defaults,
            storageKey: "openusage.layout.v1"
        ).loadProviderOrder() ?? []
        let orderedIDs = registry.orderedProviderIDs(savedOrder: savedOrder)
        let enabledOrderedIDs = orderedIDs.filter(includesProvider)
        let needsRefresh = force || enabledOrderedIDs.contains {
            cache.snapshot(providerID: $0) == nil || staleAccountStampIDs.contains($0)
        }
        var snapshots = cachedSnapshots
        var warnings: [String] = []
        var errors: [String: String] = [:]

        if needsRefresh {
            LoginShellEnvironment.shared.prewarm()
            let dataStore = WidgetDataStore(
                registry: registry,
                providers: providers,
                cache: cache,
                defaults: defaults,
                isProviderEnabled: includesProvider,
                // CLI는 앱의 snapshot cache 공유 — 쓰기에 동일한 계정 stamp 필수, 미stamp claude/codex entry는 앱의 다음 launch에 폐기.
                providerIdentityKeys: accountAssembly.identityKeysByCard
            )
            if let matchedIDs {
                for providerID in orderedIDs.filter(matchedIDs.contains) {
                    _ = await dataStore.refresh(providerID: providerID, force: force)
                }
            } else {
                await dataStore.refreshAll(force: force)
            }
            if providersOverride == nil {
                await PersistentJSONLScanCaches.flushPendingWrites()
            }
            snapshots = dataStore.snapshots
            errors = dataStore.providerErrors
            warnings = orderedIDs
                .compactMap { id in errors[id].map { "\(id): \($0)" } }
        }

        // 신뢰된 로컬 CLI 출력 — persisted account registry의 계정 label 반영. 주입 provider 테스트에서는 보통 no-op.
        let accountTitles = ProviderAccountsStore(defaults: defaults).resolvedDisplayNamesByCardID
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: enabledOrderedIDs,
            knownIDs: knownIDs,
            snapshots: snapshots,
            limitDescriptors: registry.limitDescriptorsByProvider,
            errors: errors
        )
        .resolvingDisplayNames(accountTitles)
        let path = requestedToken.map { "/v1/limits/\($0)" } ?? "/v1/limits"
        let response = LocalUsageAPI.respond(method: "GET", path: path, state: state)
        guard let data = response.body else {
            // 사실상 unreachable — token은 위에서 검증, limits 라우트는 known token에 항상 body 생성. 무출력 대신 loud 실패.
            throw UsageReaderError.refreshFailed(warnings.first ?? "local read produced no data")
        }
        return UsageReadResult(data: data, warnings: warnings)
    }

}
