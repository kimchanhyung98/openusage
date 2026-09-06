enum SoftLimitWindow: String, CaseIterable, Sendable {
    case fiveHours
    case weekly

    var label: String {
        switch self {
        case .fiveHours: "5 Hours"
        case .weekly: "Weekly"
        }
    }

    /// provider opt-in과 실제 metric duration의 이중 확인 — 이름만 같은 fallback·가변 window 제외.
    func matches(periodDurationMs: Int?) -> Bool {
        switch self {
        case .fiveHours: periodDurationMs == MetricPeriod.sessionMs
        case .weekly: periodDurationMs == MetricPeriod.weekMs
        }
    }
}

extension WidgetDescriptor {
    func supportingSoftLimit(_ window: SoftLimitWindow) -> WidgetDescriptor {
        var copy = self
        copy.softLimitWindow = window
        return copy
    }
}

extension WidgetData {
    var softLimitMarkerFraction: Double? {
        guard hasData, let limit, limit > 0, let softLimitUsedFraction else { return nil }
        return displayMode == .remaining ? 1 - softLimitUsedFraction : softLimitUsedFraction
    }

    func meterTooltip(for state: MeterState) -> String? {
        let lines = [state.tooltip, softLimitStatusText].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var softLimitStatusText: String? {
        guard hasData, let limit, limit > 0, let softLimitUsedFraction else { return nil }
        let percent = Int((softLimitUsedFraction * 100).rounded())
        return roundedAtDisplayPrecision(used) / limit >= softLimitUsedFraction
            ? "Soft limit reached at \(percent)% used"
            : "Soft limit at \(percent)% used"
    }
}
