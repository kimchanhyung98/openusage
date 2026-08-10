import Foundation

/// launch 시 live `ProviderRuntime`들로 구성되는 provider·widget 읽기 전용 catalog
/// 구성 후 불변 — lookup이 매 render마다 호출되므로 조회 map을 생성 시 1회 precompute (선형 scan 회피)
struct WidgetRegistry: Sendable {
    let providers: [Provider]
    let descriptors: [WidgetDescriptor]

    private let descriptorsByID: [String: WidgetDescriptor]
    private let providersByID: [String: Provider]
    /// provider별 descriptor 목록 — 원본 `descriptors` 순서 보존 (UI metric 순서가 의존하는 sequence)
    private let descriptorsByProvider: [String: [WidgetDescriptor]]
    /// family별 canonical metric id — 저장 layout의 key 공간, 카드 중복 제거 후 첫 등장 순서 보존
    private let canonicalMetricIDsByFamily: [String: [String]]

    init(providers: [Provider], descriptors: [WidgetDescriptor]) {
        self.providers = providers
        self.descriptors = descriptors
        self.descriptorsByID = Dictionary(
            descriptors.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.providersByID = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var byProvider: [String: [WidgetDescriptor]] = [:]
        var canonicalByFamily: [String: [String]] = [:]
        var seenCanonical = Set<String>()
        for descriptor in descriptors {
            byProvider[descriptor.providerID, default: []].append(descriptor)
            let canonicalID = ProviderAccountID.canonicalMetricID(descriptor.id)
            if seenCanonical.insert(canonicalID).inserted {
                canonicalByFamily[ProviderAccountID.family(of: descriptor.providerID), default: []].append(canonicalID)
            }
        }
        self.descriptorsByProvider = byProvider
        self.canonicalMetricIDsByFamily = canonicalByFamily
    }

    func descriptor(id: String) -> WidgetDescriptor? { descriptorsByID[id] }
    func provider(id: String) -> Provider? { providersByID[id] }
    func descriptors(for providerID: String) -> [WidgetDescriptor] {
        descriptorsByProvider[providerID] ?? []
    }

    /// family가 지원하는 canonical metric id — bare 카드가 없어도(추가 계정 카드만 있는 registry) 동일 목록
    func canonicalMetricIDs(family: String) -> [String] {
        canonicalMetricIDsByFamily[family] ?? []
    }

    /// canonical id를 지원하는 descriptor 존재 여부 — 저장된 layout 항목의 유효성 gate
    func hasCanonicalMetric(_ canonicalID: String) -> Bool {
        let family = ProviderAccountID.family(of: ProviderAccountID.providerID(ofMetric: canonicalID))
        return canonicalMetricIDsByFamily[family]?.contains(canonicalID) ?? false
    }

    /// 설치된 provider로 필터링한 저장 순서 + 신규 provider는 canonical registry 순서로 append
    /// 계정 card(`claude@ab12cd34`)는 family 그룹 바로 뒤에 삽입 — dashboard·local API·one-shot CLI 공용
    func orderedProviderIDs(savedOrder: [String]) -> [String] {
        let defaults = providers.map(\.id)
        let known = Set(defaults)
        let saved = savedOrder.filter { known.contains($0) }
        let savedIDs = Set(saved)
        var result = saved
        for id in defaults where !savedIDs.contains(id) {
            let family = ProviderAccountID.family(of: id)
            if ProviderAccountID.isAccountCard(id),
               let anchor = result.lastIndex(where: { ProviderAccountID.family(of: $0) == family }) {
                result.insert(id, at: result.index(after: anchor))
            } else {
                result.append(id)
            }
        }
        return result
    }

    var limitDescriptorsByProvider: [String: [WidgetDescriptor]] {
        descriptorsByProvider.mapValues { $0.filter { !$0.limitResources.isEmpty } }
    }

    var historyDescriptorsByProvider: [String: UsageHistoryDescriptor] {
        descriptorsByProvider.compactMapValues { descriptors in
            descriptors.compactMap(\.historyResource).first
        }
    }

    @MainActor
    static func from(_ runtimes: [ProviderRuntime]) -> WidgetRegistry {
        let providers = runtimes.map(\.provider)
        let metrics = runtimes.flatMap(\.widgetDescriptors)
        return WidgetRegistry(providers: providers, descriptors: metrics)
    }
}
