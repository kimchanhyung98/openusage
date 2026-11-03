import Foundation

/// 여러 provider와 local API가 공유하는 ISO-8601 날짜 파싱/포맷.
/// provider별 timestamp 변형(공백 구분, " UTC" suffix, 가변 fractional 자릿수)을 파싱 전 정규화.
enum OpenUsageISO8601 {
    static func string(from date: Date) -> String {
        formatter(fractionalSeconds: true).string(from: date)
    }

    static func date(from value: String) -> Date? {
        let normalized = normalizeTimestamp(value)
        return formatter(fractionalSeconds: true).date(from: normalized) ??
        formatter(fractionalSeconds: false).date(from: normalized)
    }

    /// JavaScript plugin `ctx.util.toIso`의 문자열 정규화와 정렬(Claude `resets_at` 등).
    private static func normalizeTimestamp(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        if s.contains(" "),
           let range = s.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, options: .regularExpression) {
            s.replaceSubrange(range, with: s[range].replacingOccurrences(of: " ", with: "T"))
        }
        if s.hasSuffix(" UTC") {
            s = String(s.dropLast(4)) + "Z"
        }

        if let match = s.range(of: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) {
            let matched = String(s[match])
            return normalizeFractionalISO(matched, assumeUTC: false)
        }
        if let match = s.range(of: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?$"#, options: .regularExpression) {
            let matched = String(s[match])
            return normalizeFractionalISO(matched, assumeUTC: true)
        }

        return s
    }

    private static func normalizeFractionalISO(_ value: String, assumeUTC: Bool) -> String {
        let pattern = #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges >= 2,
              let headRange = Range(match.range(at: 1), in: value)
        else {
            return assumeUTC && !value.hasSuffix("Z") ? value + "Z" : value
        }

        let head = String(value[headRange])
        var frac = ""
        if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
           let fracRange = Range(match.range(at: 2), in: value) {
            var digits = String(value[fracRange]).dropFirst()
            if digits.count > 3 {
                digits = digits.prefix(3)
            }
            while digits.count < 3 {
                digits.append("0")
            }
            frac = ".\(digits)"
        }

        var tz = "Z"
        if !assumeUTC, match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound,
           let tzRange = Range(match.range(at: 3), in: value) {
            tz = String(value[tzRange])
        }

        return head + frac + tz
    }

    // ISO8601DateFormatter는 생성 비용이 커 두 고정 구성을 1회 생성; 파싱/포맷은 thread-safe라 `nonisolated(unsafe)`로 불변 인스턴스 공유.
    private nonisolated(unsafe) static let fractionalFormatter = makeFormatter(fractionalSeconds: true)
    private nonisolated(unsafe) static let plainFormatter = makeFormatter(fractionalSeconds: false)

    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        fractionalSeconds ? fractionalFormatter : plainFormatter
    }

    private static func makeFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}
