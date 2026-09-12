import Foundation

/// UI 반올림·캐시와 분리된 로컬 live quota 판정 입력.
struct SoftLimitObservation: Equatable, Sendable {
    let providerID: String
    let observedAt: Date
    let expiresAt: Date
    let usedFraction: Double

    static func project(
        snapshot: ProviderSnapshot,
        descriptors: [WidgetDescriptor],
        window: SoftLimitWindow,
        now: Date
    ) -> Self? {
        guard !snapshot.providerID.contains("@"),
              !snapshot.lines.contains(where: \.isError),
              let observedAt = snapshot.liveQuotaObservedAt,
              observedAt <= now,
              now < observedAt.addingTimeInterval(RefreshSetting.interval)
        else { return nil }

        var fractions: [Double] = []
        var expiresAt = observedAt.addingTimeInterval(RefreshSetting.interval)
        for descriptor in descriptors where descriptor.providerID == snapshot.providerID && descriptor.softLimitWindow == window {
            guard descriptor.limitResources.contains(where: { $0.kind == .consumption && !$0.estimated }),
                  let line = snapshot.line(label: descriptor.metricLabel),
                  case let .progress(_, used, limit, _, resetsAt, duration, _) = line,
                  window.matches(periodDurationMs: duration),
                  used.isFinite, used >= 0, limit.isFinite, limit > 0,
                  (used / limit).isFinite
            else { continue }
            if let resetsAt {
                guard resetsAt > now else { continue }
                expiresAt = min(expiresAt, resetsAt)
            }
            fractions.append(used / limit)
        }
        guard let usedFraction = fractions.max() else { return nil }
        return Self(providerID: snapshot.providerID, observedAt: observedAt, expiresAt: expiresAt, usedFraction: usedFraction)
    }
}
