import Foundation

enum RefreshSchedulePresentation {
    static func statusText(isUpdating: Bool, nextRefreshAt: Date?, now: Date) -> String {
        if isUpdating { return "Updating…" }
        guard let nextRefreshAt else { return "Refresh Now" }
        let seconds = Int(max(0, nextRefreshAt.timeIntervalSince(now)).rounded(.up))
        let remaining = seconds >= 60 ? "\(Int(ceil(Double(seconds) / 60)))m" : "\(seconds)s"
        return "Next update in \(remaining)"
    }
}
