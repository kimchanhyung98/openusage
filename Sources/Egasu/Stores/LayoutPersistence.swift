import Foundation

/// `LayoutStore`의 저장 담당 절반 — key 이름·encoding·UserDefaults 접근 소유
@MainActor
final class LayoutPersistence {
    private let defaults: UserDefaults
    private let keys: Keys

    init(defaults: UserDefaults, storageKey: String) {
        self.defaults = defaults
        self.keys = Keys(storageKey: storageKey)
    }

    /// 존재 여부는 decode 성공과 별개 — 손상된 데이터도 기존 layout이므로
    /// startup이 corruption을 신규 설치로 오인해 신규 전용 default를 적용하지 않도록 하는 규칙
    var hasStoredLayout: Bool { defaults.data(forKey: keys.placed) != nil }
    var hasStoredSeededDefaults: Bool { defaults.data(forKey: keys.seededDefaults) != nil }

    func loadPlaced() -> [PlacedWidget]? { decode([PlacedWidget].self, forKey: keys.placed) }
    func loadProviderOrder() -> [String]? { decode([String].self, forKey: keys.providerOrder) }
    func loadMetricOrder() -> [String: [String]]? {
        decode([String: [String]].self, forKey: keys.metricOrder)
    }
    func loadSeededDefaults() -> [String]? { decode([String].self, forKey: keys.seededDefaults) }

    func loadPins() -> [String]? { defaults.stringArray(forKey: keys.pins) }
    func loadExpandedMetrics() -> [String]? { defaults.stringArray(forKey: keys.expandedMetrics) }
    func loadExpandOnEnable() -> [String]? { defaults.stringArray(forKey: keys.expandOnEnable) }
    func loadExpandedProviders() -> [String]? { defaults.stringArray(forKey: keys.expandedProviders) }
    func loadMenuBarStyle() -> MenuBarStyle { defaults.enumValue(forKey: keys.menuBarStyle, default: .bars) }

    func savePlaced(_ value: [PlacedWidget]) { encode(value, forKey: keys.placed) }
    func saveProviderOrder(_ value: [String]) { encode(value, forKey: keys.providerOrder) }
    func saveMetricOrder(_ value: [String: [String]]) { encode(value, forKey: keys.metricOrder) }
    func saveSeededDefaults(_ value: Set<String>) {
        encode(Array(value).sorted(), forKey: keys.seededDefaults)
    }

    func savePins(_ value: Set<String>) { defaults.set(Array(value), forKey: keys.pins) }
    func saveExpandedMetrics(_ value: Set<String>) {
        defaults.set(Array(value), forKey: keys.expandedMetrics)
    }
    func saveExpandOnEnable(_ value: Set<String>) {
        defaults.set(Array(value), forKey: keys.expandOnEnable)
    }
    func saveExpandedProviders(_ value: Set<String>) {
        defaults.set(Array(value), forKey: keys.expandedProviders)
    }
    func saveMenuBarStyle(_ value: MenuBarStyle) {
        defaults.set(value.rawValue, forKey: keys.menuBarStyle)
    }

    /// encode 실패는 loud하게 기록 — 조용히 삼키면 layout 변경 유실이 무신호로 발생
    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            AppLog.warn(.config, "failed to persist layout '\(key)': \(error.localizedDescription)")
        }
    }

    /// 데이터 없음은 정상 첫 launch, 있는데 못 읽으면 로그 후 fallback — 손상된 저장 layout의 무음 은폐 방지
    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.warn(.config, "saved layout '\(key)' failed to decode; reseeding default: \(error.localizedDescription)")
            return nil
        }
    }

    private struct Keys {
        let placed: String
        let providerOrder: String
        let metricOrder: String
        let seededDefaults: String
        let pins: String
        let expandedMetrics: String
        let expandOnEnable: String
        let expandedProviders: String
        let menuBarStyle: String

        init(storageKey: String) {
            placed = storageKey
            providerOrder = "\(storageKey).providerOrder"
            metricOrder = "\(storageKey).metricOrderByProvider"
            seededDefaults = "\(storageKey).seededDefaults"
            pins = "\(storageKey).menuBarPins"
            expandedMetrics = "\(storageKey).expandedMetrics"
            expandOnEnable = "\(storageKey).expandOnEnable"
            expandedProviders = "\(storageKey).expandedProviders"
            menuBarStyle = "\(storageKey).menuBarStyle"
        }
    }
}
