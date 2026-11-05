import Foundation

struct ZAIActivityWindow: Sendable {
    let days: [String]

    init(now: Date, calendar inputCalendar: Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = inputCalendar.timeZone
        let today = calendar.startOfDay(for: now)
        days = (0...UsageHistoryWindow.previousDays).reversed().map { offset in
            DailyUsageAccumulator.dayKey(
                from: calendar.date(byAdding: .day, value: -offset, to: today)!, calendar: calendar
            )
        }
    }

    var startTime: String { days.first! + " 00:00:00" }
    var endTime: String { days.last! + " 23:59:59" }
}

/// 개인 Coding Plan의 일별 토큰만 집계 — 크레딧·구독료를 달러 비용으로 환산하지 않음.
enum ZAIActivityMapper {
    static func map(_ body: Data, window: ZAIActivityWindow) throws -> [MetricLine] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
              envelope.success != false, envelope.code == nil || envelope.code == 0 || envelope.code == 200,
              let data = envelope.data else { throw ZAIUsageError.invalidResponse }

        let allowedDays = Set(window.days)
        var byDay: [String: Int] = [:]
        var total = 0
        for entry in data.series {
            guard allowedDays.contains(entry.date), entry.totalTokens >= 0,
                  byDay[entry.date] == nil,
                  let next = UsageLogNumbers.sum(total, entry.totalTokens) else {
                throw ZAIUsageError.invalidResponse
            }
            byDay[entry.date] = entry.totalTokens
            total = next
        }
        let totals: [(TotalSpendPeriod, Int)] = [
            (.today, byDay[window.days.last!] ?? 0),
            (.yesterday, byDay[window.days[window.days.count - 2]] ?? 0),
            (.last30, total)
        ]
        return totals.map { period, tokens in
            .values(label: period.lineLabel, values: [MetricValue(number: Double(tokens), kind: .count, label: "tokens")])
        }
    }

    private struct Envelope: Decodable {
        let code: Int?
        let success: Bool?
        let data: Activity?
    }

    private struct Activity: Decodable {
        let series: [Day]
    }

    private struct Day: Decodable {
        let date: String
        let totalTokens: Int
    }
}
