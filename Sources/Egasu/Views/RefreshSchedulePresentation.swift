import Foundation

enum RefreshSchedulePresentation {
    static func statusText(isUpdating: Bool, nextRefreshAt: Date?, now: Date) -> String {
        if isUpdating { return L10n.dashboard("Updating…") }
        guard let nextRefreshAt else { return L10n.dashboard("Refresh Now") }
        let seconds = Int(max(0, nextRefreshAt.timeIntervalSince(now)).rounded(.up))
        let remaining = seconds >= 60
            ? L10n.dashboard("%dm", Int(ceil(Double(seconds) / 60)))
            : L10n.dashboard("%ds", seconds)
        return L10n.dashboard("Next update in %@", remaining)
    }
}
