import Foundation

/// OpenUsage가 렌더링하는 Grok credits config 조각 — shared-pool 사용 percent와 적용 period.
/// `GET /v1/billing?format=credits`(proto-JSON) 응답에서 decode.
struct GrokCreditsConfig: Equatable, Sendable {
    /// `USAGE_PERIOD_TYPE_*` enum 이름 (`GrokCreditsConfigDecoder.weeklyPeriodType` 참고).
    var periodType: String
    /// 0...100 범위의 pool 사용률 — finite만 검증, 범위 clamp는 mapper 담당.
    var usedPercent: Double
    var periodStart: Date
    var periodEnd: Date
    /// credit 단위 pay-as-you-go cap — 비활성 시 0 (proto-JSON은 0일 때 필드 자체를 생략).
    var onDemandCap: Double

    var periodDurationMs: Int {
        Int((periodEnd.timeIntervalSince(periodStart) * 1000).rounded())
    }
}

/// `cli-chat-proxy.grok.com/v1/billing?format=credits` 응답(proto-JSON) decoder.
/// 응답은 proto3 메시지의 JSON 직렬화라 0 값 필드가 생략됨 — `creditUsagePercent` 부재는 schema 변화가 아닌 0.
enum GrokCreditsConfigDecoder {
    /// unified-billing 사용자가 이전된 shared weekly pool의 period type.
    static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"

    /// JSON 응답 body를 `GrokCreditsConfig`로 decode.
    /// config/period 누락, 비유한 percent, 잘못된 timestamp, 진행하지 않는 period는 `invalidResponse`.
    static func decode(responseBody: Data) throws -> GrokCreditsConfig {
        guard let body = ProviderParse.jsonObject(responseBody),
              let config = body["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let periodType = (period["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !periodType.isEmpty,
              let start = date(period["start"]),
              let end = date(period["end"]),
              end > start
        else {
            throw GrokUsageError.invalidResponse
        }

        // percent 부재는 proto-JSON의 0 생략이라 실제 0% — 존재하는데 비숫자·비유한이면 schema drift로 throw (0 clamp 금지)
        let percent: Double
        if let raw = config["creditUsagePercent"] {
            guard let number = ProviderParse.number(raw), number.isFinite else {
                throw GrokUsageError.invalidResponse
            }
            percent = number
        } else {
            percent = 0
        }

        // percent와 동일 — 부재는 0(비활성), 존재하는 비숫자 값은 drift로 throw
        let onDemandCap: Double
        if let capObject = config["onDemandCap"] {
            guard let object = capObject as? [String: Any] else {
                throw GrokUsageError.invalidResponse
            }
            guard let cap = ProviderParse.number(object["val"] ?? 0), cap.isFinite else {
                throw GrokUsageError.invalidResponse
            }
            onDemandCap = cap
        } else {
            onDemandCap = 0
        }

        return GrokCreditsConfig(
            periodType: periodType, usedPercent: percent,
            periodStart: start, periodEnd: end, onDemandCap: onDemandCap
        )
    }

    private static func date(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return OpenUsageISO8601.date(from: raw)
    }
}
