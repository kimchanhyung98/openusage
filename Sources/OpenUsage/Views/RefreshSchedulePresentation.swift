import Foundation

enum RefreshSchedulePresentation {
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let date: Date

        func text(at now: Date) -> String {
            let seconds = max(0, date.timeIntervalSince(now))
            let remaining = seconds >= 60 ? "\(Int(ceil(seconds / 60)))m" : "\(Int(ceil(seconds)))s"
            return "\(title) in \(remaining)"
        }
    }

    static func rows(
        general: Date?, claude: Date?, claudeRetry: Date?, resetWatch: Date?, codexTimer: Date?
    ) -> [Row] {
        [
            general.map { Row(id: "general", title: "General", date: $0) },
            claude.map { Row(id: "claude", title: "Claude", date: $0) },
            claudeRetry.map { Row(id: "claudeRetry", title: "Claude Retry", date: $0) },
            resetWatch.map { Row(id: "resetWatch", title: "Reset Watch", date: $0) },
            codexTimer.map { Row(id: "codexTimer", title: "Codex Timer", date: $0) }
        ].compactMap { $0 }
    }
}
