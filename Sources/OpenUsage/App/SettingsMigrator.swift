import Foundation

/// 스키마 버전 `version - 1` → `version` 단일 migration step — `UserDefaults` 도메인에 대한 순수 변환.
/// 중단된 업그레이드가 다음 런치에 같은 step을 재실행할 수 있으므로 멱등 유지 필수.
struct SettingsMigration: Sendable {
    /// 이 step이 생성하는 스키마 버전. 앱 marketing 버전과 독립 — 설정의 shape 변경 시에만 증가.
    let version: Int
    /// `defaults`에 변경 적용. throw 시 cascade 중단 — 마지막 성공 버전 유지, 다음 런치에 재시도.
    let migrate: @Sendable (UserDefaults) throws -> Void
}

/// settings 스키마: 현재 버전과 그에 도달하는 순서형 migration.
/// 설정 shape 변경 시 여기만 수정 — `SettingsMigration` 추가 + `current` 증가; engine(`SettingsMigrator`)은 불변.
enum SettingsSchema {
    /// 현재 스키마 버전. 아래 최고 migration `version`과 동일 유지 필수. 앱 버전 아님 — migration 추가 시에만 증가.
    static let current = 3

    /// v2 migration 출시 시점의 provider ID, 영구 동결. migration은 시점 고정 변환 — 이 목록 수정 금지.
    static let v2ProviderIDs = [
        "antigravity", "claude", "codex", "copilot", "cursor", "devin", "grok", "openrouter", "zai"
    ]

    /// 순서형 migration 목록 (v1은 baseline이라 변환 불요).
    /// storage key는 의도적으로 string literal — 동결된 변환이라 store의 key 상수 rename과 무관하게 동작 필수.
    static let migrations: [SettingsMigration] = [
        // v2: 전체 설치를 enabled-list 모드로 통일 (동작 보존 변환) + known-provider set seed —
        // 기존 provider가 "new"로 재활성화되지 않도록.
        SettingsMigration(version: 2) { defaults in
            if defaults.stringArray(forKey: "openusage.enabledProviders.v1") == nil {
                let disabled = Set(defaults.stringArray(forKey: "openusage.disabledProviders.v1") ?? [])
                let enabled = v2ProviderIDs.filter { !disabled.contains($0) }
                defaults.set(enabled, forKey: "openusage.enabledProviders.v1")
                defaults.removeObject(forKey: "openusage.disabledProviders.v1")
            }
            if defaults.stringArray(forKey: "openusage.knownProviders.v1") == nil {
                defaults.set(v2ProviderIDs, forKey: "openusage.knownProviders.v1")
            }
        },
        // v3: 신규 Reset Watch는 기존 layout에서도 On Demand 소속 + Rate Limit Resets 직전 순서로 시작.
        SettingsMigration(version: 3) { defaults in
            let layoutKey = "openusage.layout.v1"
            let expandedKey = "openusage.layout.v1.expandedMetrics"
            let expandOnEnableKey = "openusage.layout.v1.expandOnEnable"
            let orderKey = "openusage.layout.v1.metricOrderByProvider"
            let hasInitializedLayout = defaults.data(forKey: layoutKey) != nil
                || defaults.stringArray(forKey: expandedKey) != nil
                || defaults.stringArray(forKey: expandOnEnableKey) != nil
                || defaults.data(forKey: orderKey) != nil
            guard hasInitializedLayout else { return }

            let resetWatchID = "codex.resetWatch"
            let savedExpanded = defaults.stringArray(forKey: expandedKey) ?? []
            let familiesWithBareEntry = Set(savedExpanded.compactMap { id -> String? in
                let providerID = ProviderAccountID.providerID(ofMetric: id)
                guard !ProviderAccountID.isAccountCard(providerID) else { return nil }
                return ProviderAccountID.family(of: providerID)
            })
            var seenExpanded = Set<String>()
            var expanded = savedExpanded.compactMap { id -> String? in
                let providerID = ProviderAccountID.providerID(ofMetric: id)
                let family = ProviderAccountID.family(of: providerID)
                guard !ProviderAccountID.isAccountCard(providerID) || !familiesWithBareEntry.contains(family) else {
                    return nil
                }
                let canonicalID = ProviderAccountID.canonicalMetricID(id)
                return seenExpanded.insert(canonicalID).inserted ? canonicalID : nil
            }
            if !expanded.contains(resetWatchID) {
                expanded.append(resetWatchID)
            }
            if expanded != savedExpanded {
                defaults.set(expanded, forKey: expandedKey)
            }

            guard let encodedOrder = defaults.data(forKey: orderKey) else { return }
            do {
                var order = try JSONDecoder().decode([String: [String]].self, from: encodedOrder)
                let codexKeys = order.keys.filter { ProviderAccountID.family(of: $0) == "codex" }
                let sourceKey = order["codex"] == nil ? codexKeys.sorted().first : "codex"
                guard let sourceKey, let savedCodex = order[sourceKey] else { return }
                var seen = Set<String>()
                var codex = savedCodex
                    .map(ProviderAccountID.canonicalMetricID)
                    .filter { seen.insert($0).inserted && $0 != resetWatchID }
                if let anchor = codex.firstIndex(of: "codex.rateLimitResets") {
                    codex.insert(resetWatchID, at: anchor)
                } else {
                    codex.append(contentsOf: [resetWatchID, "codex.rateLimitResets"])
                }
                for key in codexKeys where key != "codex" {
                    order.removeValue(forKey: key)
                }
                order["codex"] = codex
                defaults.set(try JSONEncoder().encode(order), forKey: orderKey)
            } catch {
                AppLog.warn(.config, "Reset Watch layout order migration skipped unreadable saved order: \(error.localizedDescription)")
            }
        }
    ]
}

/// 버전드 cascading settings migration — 어떤 store보다 먼저 런치 시 1회 실행 필수 (fresh install 판별은 빈 도메인 기준).
/// 기존 설치는 초과분 migration을 오름차순 실행, step마다 버전 영속 (중단 시 재개); fresh는 `current` stamp만; legacy(키 부재)는 v0부터.
/// wipe 없음 — 설정은 업데이트를 넘어 유지.
enum SettingsMigrator {
    /// 적용된 스키마 버전의 기록 key (정수). 부재 = 미마이그레이션 — fresh 또는 legacy, 런타임 판별.
    static let schemaVersionKey = "openusage.settings.schemaVersion"

    /// 도메인을 `current`까지 migration. 결과 스키마 버전 반환 (로깅·테스트용).
    @discardableResult
    static func migrate(
        defaults: UserDefaults = .standard,
        domainName: String = Bundle.main.bundleIdentifier ?? "",
        current: Int = SettingsSchema.current,
        migrations: [SettingsMigration] = SettingsSchema.migrations
    ) -> Int {
        var version: Int
        if let stored = defaults.object(forKey: schemaVersionKey) as? Int {
            version = stored
        } else if isFreshInstall(defaults: defaults, domainName: domainName) {
            defaults.set(current, forKey: schemaVersionKey)
            AppLog.info(.config, "fresh install — settings schema stamped at v\(current)")
            return current
        } else {
            version = 0
            AppLog.info(.config, "legacy settings (no schema version) — migrating forward from v0")
        }

        // 이미 최신이거나 downgrade — 기록 버전 유지, 역방향 재적용 금지.
        guard version < current else { return version }

        for step in migrations.sorted(by: { $0.version < $1.version })
        where step.version > version && step.version <= current {
            do {
                try step.migrate(defaults)
            } catch {
                AppLog.warn(.config, "settings migration to v\(step.version) failed: \(error.localizedDescription) — will retry next launch")
                return version  // 마지막 성공 유지 — 다음 런치에 여기서 재개
            }
            version = step.version
            defaults.set(version, forKey: schemaVersionKey)  // step마다 영속 (재개 가능 cascade)
            AppLog.info(.config, "migrated settings to schema v\(version)")
        }

        // 최고 migration이 `current` 미만이어도 `current` 기록 — 매 런치 cascade 재평가 방지.
        if version < current {
            version = current
            defaults.set(current, forKey: schemaVersionKey)
        }
        return version
    }

    /// 진짜 첫 런치 판별: 빈 도메인 = fresh, 키 존재 + 스키마 버전 부재 = legacy. 빈 `domainName`(unbundled `swift run`)은 fresh 취급.
    /// `AppDelegate`가 `migrate()` 이전에 호출 필수 — schema stamp가 도메인을 non-empty로 변경.
    static func isFreshInstall(
        defaults: UserDefaults = .standard,
        domainName: String = Bundle.main.bundleIdentifier ?? ""
    ) -> Bool {
        guard !domainName.isEmpty else { return true }
        return (defaults.persistentDomain(forName: domainName) ?? [:]).isEmpty
    }
}
