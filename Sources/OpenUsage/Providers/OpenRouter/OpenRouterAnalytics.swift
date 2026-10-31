import Foundation

enum OpenRouterAnalyticsPeriod: String, CaseIterable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case last30 = "Last 30 Days"
    case week = "This Week"
    case month = "This Month"

    func interval(now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return DateInterval(start: today, end: now)
        case .yesterday:
            return DateInterval(start: calendar.date(byAdding: .day, value: -1, to: today)!, end: today)
        case .last30:
            let start = calendar.date(byAdding: .day, value: -UsageHistoryWindow.previousDays, to: today)!
            return DateInterval(start: start, end: now)
        case .week:
            return DateInterval(start: calendar.dateInterval(of: .weekOfYear, for: now)!.start, end: now)
        case .month:
            return DateInterval(start: calendar.dateInterval(of: .month, for: now)!.start, end: now)
        }
    }
}

enum OpenRouterAnalytics {
    struct Parsed: Sendable {
        let values: [MetricValue]
        let isPartial: Bool
    }

    static func parse(_ data: [String: Any]) throws -> Parsed {
        guard let metadata = data["metadata"] as? [String: Any],
              let truncated = metadata["truncated"] as? NSNumber,
              CFGetTypeID(truncated) == CFBooleanGetTypeID(), !truncated.boolValue,
              UsageLogNumbers.count(metadata["row_count"]) == 1,
              let rows = data["data"] as? [[String: Any]], rows.count == 1,
              let row = rows.first
        else {
            throw OpenRouterUsageError.invalidResponse
        }

        var values: [MetricValue] = []
        if let cost = ProviderParse.number(row["total_usage"]), cost >= 0 {
            values.append(MetricValue(number: cost, kind: .dollars))
        }
        if let tokens = UsageLogNumbers.count(row["tokens_total"]), tokens <= 9_007_199_254_740_991 {
            values.append(MetricValue(number: Double(tokens), kind: .count, label: "tokens"))
        }
        guard !values.isEmpty else { throw OpenRouterUsageError.invalidResponse }
        return Parsed(values: values, isPartial: values.count < 2)
    }
}
