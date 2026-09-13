import Foundation
import Observation

@MainActor
@Observable
final class SoftLimitSettingsStore {
    static let thresholdRange = 1...100
    static let defaultThresholdPercent = 90

    private let defaults: UserDefaults
    private static let enabledKey = "openusage.softLimit.cancellationEnabled.v2"
    private static let windowKey = "openusage.softLimit.window.v1"
    private static let thresholdKey = "openusage.softLimit.thresholdPercent.v1"
    private var storedThresholdPercent: Int
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled != oldValue { onChange?() }
        }
    }

    var window: SoftLimitWindow {
        didSet {
            defaults.set(window.rawValue, forKey: Self.windowKey)
            if window != oldValue { onChange?() }
        }
    }

    var thresholdPercent: Int {
        get { storedThresholdPercent }
        set {
            let normalized = Self.normalizedThreshold(newValue)
            let changed = storedThresholdPercent != normalized
            storedThresholdPercent = normalized
            defaults.set(normalized, forKey: Self.thresholdKey)
            if changed { onChange?() }
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

    func setThreshold(from text: String) -> Bool {
        guard let percent = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              Self.thresholdRange.contains(percent) else {
            AppLog.warn(.config, "Invalid Soft Limit threshold: expected a whole percentage from 1 to 100")
            return false
        }
        thresholdPercent = percent
        return true
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
