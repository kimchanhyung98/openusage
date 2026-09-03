import Foundation
import Observation

@MainActor
@Observable
final class SoftLimitSettingsStore {
    static let thresholdRange = 90...95
    static let defaultThresholdPercent = 95

    private let defaults: UserDefaults
    private static let enabledKey = "openusage.softLimit.enabled.v1"
    private static let windowKey = "openusage.softLimit.window.v1"
    private static let thresholdKey = "openusage.softLimit.thresholdPercent.v1"
    private var storedThresholdPercent: Int

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }

    var window: SoftLimitWindow {
        didSet { defaults.set(window.rawValue, forKey: Self.windowKey) }
    }

    var thresholdPercent: Int {
        get { storedThresholdPercent }
        set {
            let normalized = Self.normalizedThreshold(newValue)
            storedThresholdPercent = normalized
            defaults.set(normalized, forKey: Self.thresholdKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Self.enabledKey, default: false)
        self.window = defaults.enumValue(forKey: Self.windowKey, default: .weekly)
        self.storedThresholdPercent = Self.normalizedThreshold(
            defaults.object(forKey: Self.thresholdKey) as? Int ?? Self.defaultThresholdPercent
        )
    }

    func usedFraction(for candidate: SoftLimitWindow?, periodDurationMs: Int?) -> Double? {
        guard enabled, candidate == window, candidate?.matches(periodDurationMs: periodDurationMs) == true else {
            return nil
        }
        return Double(thresholdPercent) / 100
    }

    private static func normalizedThreshold(_ value: Int) -> Int {
        min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound)
    }
}
