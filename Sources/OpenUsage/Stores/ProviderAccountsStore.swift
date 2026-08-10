import CryptoKit
import Foundation
import Observation

/// account-first model의 card-id 헬퍼. family의 default home을 처음 점유한 account가 bare family id
/// (`claude`, `codex`)를 영구 record id로 보유 — 기존 설치가 아무것도 안 하고 migration되는 근거.
/// 이후 같은 family의 account는 identity key에서 `family@<hash8>` 발급.
enum ProviderAccountID {
    static let families: Set<String> = ["claude", "codex"]

    /// `claude@ab12cd34` — account identity key에서 파생한 stable·비가역 id.
    static func make(family: String, identityKey: String) -> String {
        "\(family)@\(hash8(identityKey))"
    }

    /// card id를 구성하는 8-hex identity digest — 다른 identity 파생 id(iCloud remote-only pseudo provider)에도 공개.
    static func hash8(_ identityKey: String) -> String {
        let digest = SHA256.hash(data: Data(identityKey.lowercased().utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// card id의 family — `claude@ab12cd34` → `claude`, bare id는 자기 자신.
    static func family(of cardID: String) -> String {
        cardID.firstIndex(of: "@").map { String(cardID[..<$0]) } ?? cardID
    }

    /// extra account 카드 id(`claude@ab12cd34`) 여부 — bare provider id와 구분.
    static func isAccountCard(_ cardID: String) -> Bool {
        cardID.contains("@")
    }

    /// 카드 제목 — account family 카드는 계정과 무관하게 provider 이름 고정, 계정 이름은 selector가 표시.
    /// 카드 제목을 그리는 모든 표면(헤더·우클릭 메뉴·공유 이미지·메뉴 바)의 단일 규칙.
    static func cardTitle(providerID: String, fallback: String) -> String {
        let family = family(of: providerID)
        return families.contains(family) ? family.capitalized : fallback
    }

    /// metric id의 provider 부분 — `claude@profile-x.trend` → `claude@profile-x`. card id에는 `.`이 없음.
    static func providerID(ofMetric metricID: String) -> String {
        metricID.firstIndex(of: ".").map { String(metricID[..<$0]) } ?? metricID
    }

    /// metric id를 family 기준으로 축약 — `claude@profile-x.trend` → `claude.trend`.
    /// layout 설정(활성 metric·순서·caret 소속·pin)의 유일한 저장 key: 한 family의 카드는 설정 1벌을 공유하고,
    /// 카드별 id는 렌더 시점에만 존재.
    static func canonicalMetricID(_ metricID: String) -> String {
        guard let dot = metricID.firstIndex(of: "."), metricID[..<dot].contains("@") else { return metricID }
        return family(of: String(metricID[..<dot])) + metricID[dot...]
    }
}

/// account가 로그인돼 있는 한 곳. "Default"는 source의 badge(`holdsDefaultSource`)일 뿐 key가 아님 —
/// id·정렬 순서를 결정하지 않으며, swap은 source edge만 재연결(카드는 이동하지 않음).
struct ProviderAccountSource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// 이 머신의 provider 표준 home(`~/.claude`, `~/.codex`, env override).
        case defaultHome
        /// custom Claude config dir(default 옆에 유지되는 `CLAUDE_CONFIG_DIR` home).
        case configDir
        /// 등록된 launch-profile home(`AccountProfilesStore` managed home).
        case managedProfile
    }

    var kind: Kind
    /// source가 관찰된 canonical home 경로.
    var anchor: String?
    var holdsDefaultSource: Bool
    /// `configDir` 전용 — source의 keychain item 이름을 만드는 hash의 원본 literal(Claude Code는
    /// `CLAUDE_CONFIG_DIR`을 입력된 그대로 hash — `~/x`와 절대경로 표기는 별개).
    var keychainLiteral: String?

    init(kind: Kind, anchor: String?, holdsDefaultSource: Bool, keychainLiteral: String? = nil) {
        self.kind = kind
        self.anchor = anchor
        self.holdsDefaultSource = holdsDefaultSource
        self.keychainLiteral = keychainLiteral
    }
}

/// account-first model이 보는 account — 불투명 identity key, 생성 시 발급된 stable record id, 현재 연결된 source들.
struct ProviderAccountRecord: Codable, Equatable, Sendable {
    /// 처음 관찰될 때 발급되는 stable id — 재파생 금지. family default home에서 처음 관찰된 account는 bare family id.
    var id: String
    var family: String
    var identityKey: String
    var label: String?
    var sources: [ProviderAccountSource]
    /// 향후 "Remove Account…"가 설정 — tombstone된 account는 rescan으로 부활하지 않음.
    var removedTombstone: Bool = false

    /// 카드 이름 — bare 카드는 family명, extra 카드는 account label 파생 "Claude — <org|email>",
    /// label 없으면 record id 폴백. 사용자 지정 이름은 없음 — 이름은 계정이 결정.
    var derivedDisplayName: String {
        guard ProviderAccountID.isAccountCard(id) else { return family.capitalized }
        guard let label = label?.nilIfEmpty else { return id }
        // label은 자체 "email (Org Name)" 형식 — 짧은 카드 title로 org 우선.
        if label.hasSuffix(")"), let open = label.lastIndex(of: "(") {
            let org = label[label.index(after: open)..<label.index(before: label.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            if !org.isEmpty { return "\(family.capitalized) — \(org)" }
        }
        return "\(family.capitalized) — \(label)"
    }

    /// THE name resolver — 카드 이름 표시는 전부 render 시점에 여기로 해석(직접 또는
    /// `AppContainer.displayName(for:)`); `Provider.displayName`은 derived 기본값만 보유.
    var resolvedDisplayName: String { derivedDisplayName }
}

/// account-first registry(`openusage.providerAccounts.v1`) — 매 launch에 default-home identity 읽기와
/// config-dir scan에서 reconcile. 시작부터 authoritative(drift할 병행 카드 모델 없음).
/// 등록하지 않은 config-dir 로그인은 record를 만들지 않음 — 표시는 Settings 등록 계정 한정.
@MainActor
@Observable
final class ProviderAccountsStore {
    static let storageKey = "openusage.providerAccounts.v1"

    private let defaults: UserDefaults
    private(set) var records: [ProviderAccountRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                self.records = try JSONDecoder().decode([ProviderAccountRecord].self, from: data)
            } catch {
                AppLog.error(.config, "provider-account records were undecodable; starting a fresh registry: \(error.localizedDescription)")
                self.records = []
            }
        } else {
            self.records = []
        }
    }

    /// 이번 launch에 관찰된 account 1건 — reconciliation이 record id를 배정(또는 재발견)하기 전 상태.
    /// (`@Observable` macro가 확장하는 `Observation` module과의 이름 충돌 회피용 명명.)
    struct AccountObservation {
        var family: String
        var identityKey: String
        var label: String?
        var sources: [ProviderAccountSource]
    }

    /// 이번 launch의 관찰을 persist 집합에 merge — label·sources 갱신 또는 record 생성; family의 첫 account는
    /// bare family id, 이후는 `family@<hash8>`. record는 여기서 이동·소멸하지 않음 — 미관찰 account(로그아웃,
    /// identity 읽기 실패)는 그대로 유지. 단 같은 source가 다른 identity로 관찰되면 그 source edge만
    /// sibling record에서 제거 — 재로그인이 stale path-to-account 연결을 남기지 않도록.
    @discardableResult
    func reconcile(with observations: [AccountObservation]) -> [ProviderAccountRecord] {
        var updated = records
        var changed = false

        for observation in observations {
            let observedSourceKeys = Set(observation.sources.compactMap(Self.sourceKey))
            let index = updated.firstIndex {
                $0.family == observation.family && $0.identityKey == observation.identityKey
            }
            if let index {
                guard !updated[index].removedTombstone else { continue }
                var record = updated[index]
                record.label = observation.label ?? record.label
                record.sources = observation.sources
                if record != updated[index] {
                    updated[index] = record
                    changed = true
                }
            } else {
                updated.append(ProviderAccountRecord(
                    id: Self.availableID(for: observation, in: updated),
                    family: observation.family,
                    identityKey: observation.identityKey,
                    label: observation.label,
                    sources: observation.sources
                ))
                changed = true
            }

            // profile home은 다른 account로 재인증 가능 — 이번 launch에 관찰된 source edge만 이동.
            // 미관찰·읽기 실패 source는 유지 — 일시적 probe 실패가 마지막 account 연결을 지우지 않도록.
            if !observedSourceKeys.isEmpty {
                for index in updated.indices
                where updated[index].family == observation.family
                    && updated[index].identityKey != observation.identityKey
                    && !updated[index].removedTombstone
                {
                    let filtered = updated[index].sources.filter { source in
                        guard let key = Self.sourceKey(source) else { return true }
                        return !observedSourceKeys.contains(key)
                    }
                    if filtered != updated[index].sources {
                        updated[index].sources = filtered
                        changed = true
                    }
                }
            }

            // default badge는 family당 단독 — 이 관찰이 보유하면 sibling 전부에서 제거
            // (swap-out된 account는 더 이상 bare id에 응답하지 않음).
            if observation.sources.contains(where: \.holdsDefaultSource) {
                for index in updated.indices
                where updated[index].family == observation.family
                    && updated[index].identityKey != observation.identityKey
                    && updated[index].sources.contains(where: \.holdsDefaultSource)
                {
                    updated[index].sources = updated[index].sources.map { source in
                        var source = source
                        source.holdsDefaultSource = false
                        return source
                    }
                    changed = true
                }
            }
        }

        if changed {
            records = updated
            persist()
        }
        return records
    }

    /// source 매칭 key — anchor는 관찰 경계에서 canonical 경로, kind 포함이라 경로가 우연히 같은 default
    /// home과 managed profile이 서로의 edge를 이동시키지 못함. anchor 없는 future source kind는 매칭
    /// identity가 생길 때까지 불가침.
    private static func sourceKey(_ source: ProviderAccountSource) -> String? {
        guard let anchor = source.anchor?.nilIfEmpty else { return nil }
        return "\(source.kind.rawValue)\u{1F}\(anchor)"
    }

    /// card id의 resolved 카드 title — account record 없으면 nil(비계정 provider는 정적 `Provider.displayName` 유지).
    /// 단일 name resolver의 lookup 절반 — `ProviderAccountRecord.resolvedDisplayName` 참고.
    func resolvedDisplayName(cardID: String) -> String? {
        records.first { $0.id == cardID }?.resolvedDisplayName
    }

    /// 전 record의 card id → resolved title map — CLI/API boundary가 snapshot에 적용(`LocalUsageAPI.State.resolvingDisplayNames`).
    var resolvedDisplayNamesByCardID: [String: String] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.resolvedDisplayName) })
    }

    func defaultBadgeHolder(family: String) -> ProviderAccountRecord? {
        records.first { record in
            record.family == family
                && !record.removedTombstone
                && record.sources.contains(where: \.holdsDefaultSource)
        }
    }

    /// bare family id가 비어 있으면 그것(migration-killing 규칙: default home에서 처음 관찰된 account가 기존
    /// 카드 그 자체), 아니면 identity 파생 `family@<hash8>`. bare id는 default home 관찰 account만 획득 —
    /// 그 id의 runtime은 default home을 읽으므로 custom-config-dir account에 주면 기존 카드가 못 읽는 로그인을 가리킴.
    private static func availableID(for observation: AccountObservation, in records: [ProviderAccountRecord]) -> String {
        let observedAtDefaultHome = observation.sources.contains { $0.kind == .defaultHome }
        if observedAtDefaultHome, !records.contains(where: { $0.id == observation.family }) {
            return observation.family
        }
        let derived = ProviderAccountID.make(family: observation.family, identityKey: observation.identityKey)
        guard records.contains(where: { $0.id == derived }) else { return derived }
        // 한 family의 두 identity 간 hash-prefix 충돌 — 빌 때까지 salt.
        var attempt = 0
        while true {
            let salted = ProviderAccountID.make(
                family: observation.family,
                identityKey: "\(observation.identityKey)|\(attempt)"
            )
            if !records.contains(where: { $0.id == salted }) { return salted }
            attempt += 1
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else {
            AppLog.error(.config, "failed to encode provider-account records; keeping previous persisted state")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
