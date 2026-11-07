import Foundation

enum UsageJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return value
    }

    static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func date(_ value: Any?, milliseconds: Bool = false) -> Date? {
        if let value = value as? String, let date = EgasuISO8601.date(from: value) { return date }
        guard let value = ProviderParse.number(value), value >= 0 else { return nil }
        let seconds = milliseconds ? value / 1000 : value
        guard seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func tokens(
        into record: inout UsageRecord, input: Any?, output: Any?, cacheRead: Any? = nil,
        cacheWrite: Any? = nil, cacheWrite1h: Any? = nil, total: Any? = nil
    ) {
        guard let input = UsageLogNumbers.count(input, missing: 0),
              let output = UsageLogNumbers.count(output, missing: 0),
              let read = UsageLogNumbers.count(cacheRead, missing: 0),
              let write = UsageLogNumbers.count(cacheWrite, missing: 0),
              let write1h = UsageLogNumbers.count(cacheWrite1h, missing: 0),
              let sum = UsageLogNumbers.sum(input, output, read, max(write, write1h)),
              let total = UsageLogNumbers.count(total, missing: sum) else {
            record.issues.insert(.invalidNumbers)
            return
        }
        record.tokens = TokenBreakdown(
            input: input, cacheWrite5m: max(write - write1h, 0), cacheWrite1h: write1h,
            cacheRead: read, output: output
        )
        record.totalTokens = total
    }

    static func cost(_ value: Any?, into record: inout UsageRecord) {
        guard let value else { return }
        guard let cost = ProviderParse.number(value), cost >= 0 else {
            record.issues.insert(.invalidNumbers)
            return
        }
        record.recordedCostUSD = cost
    }
}
