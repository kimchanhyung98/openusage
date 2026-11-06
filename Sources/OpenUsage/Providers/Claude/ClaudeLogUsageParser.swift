import Foundation

extension ClaudeLogUsageScanner {
    // MARK: - Line parsing

    /// 세션 파일의 사용량 행 파싱. 날짜 범위는 집계 시 적용하여 파싱 캐시 재사용.
    static func parseFile(_ data: Data) -> [Entry] {
        let marker = Data(#""usage""#.utf8)
        var entries: [Entry] = []
        var rejected = false
        for line in JSONLScanning.lines(in: data) {
            guard line.range(of: marker) != nil else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                rejected = true
                continue
            }
            guard let message = object["message"] as? [String: Any],
                  message["usage"] is [String: Any] else { continue }
            let parsed = parseEntries(object)
            if parsed.isEmpty { rejected = true }
            entries.append(contentsOf: parsed)
        }
        if rejected {
            AppDiagnostics.record(.historyScan, result: .degraded, category: .decoding, providerID: "claude",
                                  localContext: "Claude usage records were skipped because their format is unsupported")
        }
        UsageLogNumbers.reportRejectedRows(entries.filter(\.invalidNumericValues).count, source: "claude")
        return entries
    }

    /// JSONL 한 행의 주 모델 사용량 해석. 손상 행만 제외하고 다음 행 계속 처리.
    static func parseLine(_ data: Data) -> Entry? {
        parseEntries(data).first
    }

    /// 최상위 사용량과 advisor·compaction만 별도 기록. 일반 iteration의 중복 집계 방지.
    private static func parseEntries(_ data: Data) -> [Entry] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return parseEntries(object)
    }

    private static func parseEntries(_ object: [String: Any]) -> [Entry] {
        guard !hasUnsupportedNullValue(object),
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let parsedUsage = tokenBreakdown(from: usage),
              isValidEntry(object, message: message)
        else { return [] }

        let model = (message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
        let cost = (object["costUSD"] as? NSNumber).flatMap { number -> Double? in
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            return number.doubleValue
        }
        let parent = Entry(
            timestamp: timestamp,
            tokens: parsedUsage.tokens,
            messageID: message["id"] as? String,
            requestID: object["requestId"] as? String,
            isSidechain: object["isSidechain"] as? Bool ?? false,
            hasSpeed: parsedUsage.hasSpeed,
            costUSD: cost,
            model: model,
            invalidNumericValues: !parsedUsage.valid || (object["costUSD"] != nil && cost == nil)
        )

        guard let iterations = usage["iterations"] as? [[String: Any]] else { return [parent] }

        var entries = [parent]
        var advisorIndex = 0
        var compactionIndex = 0
        for iteration in iterations {
            let model: String?
            let suffix: String
            switch iteration["type"] as? String {
            case "advisor_message":
                guard let advisorModel = iteration["model"] as? String, !advisorModel.isEmpty else { continue }
                model = advisorModel
                suffix = "advisor:\(advisorIndex)"
                advisorIndex += 1
            case "compaction":
                model = nil
                suffix = "compaction:\(compactionIndex)"
                compactionIndex += 1
            default:
                continue
            }
            guard let iterationUsage = tokenBreakdown(from: iteration)
            else { continue }

            entries.append(Entry(
                timestamp: parent.timestamp,
                tokens: iterationUsage.tokens,
                messageID: parent.messageID.map { "\($0):\(suffix)" },
                requestID: parent.requestID,
                isSidechain: parent.isSidechain,
                hasSpeed: iterationUsage.hasSpeed,
                costUSD: nil,
                model: model,
                invalidNumericValues: !iterationUsage.valid
            ))
        }
        return entries
    }

    /// `valid: false`는 숫자 손상. 합계에서 제외하고 진단하기 위해 0 토큰으로 반환.
    /// `nil`은 사용량 행이 아니거나 지원하지 않는 `speed` 형식으로, 집계에서 제외.
    private static func tokenBreakdown(
        from usage: [String: Any]
    ) -> (tokens: TokenBreakdown, hasSpeed: Bool, valid: Bool)? {
        guard usage["input_tokens"] != nil, usage["output_tokens"] != nil else { return nil }

        // 지원하지 않는 속도는 요금을 확정할 수 없어 해당 행 제외.
        let speed = usage["speed"] as? String
        if let speed, speed != "fast", speed != "standard" { return nil }
        let invalid = (TokenBreakdown(), speed != nil, false)

        // 캐시 쓰기는 5분·1시간 분리값 우선. 분리값이 없으면 이전 합계를 5분으로 처리.
        let cacheCreation = usage["cache_creation"] as? [String: Any]
        let rawCacheWrite5m = cacheCreation == nil
            ? usage["cache_creation_input_tokens"]
            : cacheCreation?["ephemeral_5m_input_tokens"]
        guard let cacheWrite5m = UsageLogNumbers.count(rawCacheWrite5m, missing: 0),
              let cacheWrite1h = UsageLogNumbers.count(cacheCreation?["ephemeral_1h_input_tokens"], missing: 0),
              let input = UsageLogNumbers.count(usage["input_tokens"]),
              let cacheRead = UsageLogNumbers.count(usage["cache_read_input_tokens"], missing: 0),
              let output = UsageLogNumbers.count(usage["output_tokens"]),
              UsageLogNumbers.sum(input, cacheWrite5m, cacheWrite1h, cacheRead, output) != nil
        else { return invalid }

        return (TokenBreakdown(
            input: input,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            cacheRead: cacheRead,
            output: output,
            isFast: speed == "fast"
        ), speed != nil, true)
    }

    /// 지원하지 않는 버전 형식과 비어 있는 ID·모델을 집계에서 제외.
    private static func isValidEntry(_ object: [String: Any], message: [String: Any]) -> Bool {
        if let version = object["version"] as? String, !isSemverPrefix(version) { return false }
        for value in [object["sessionId"], object["requestId"], message["id"], message["model"]] {
            if let text = value as? String, text.isEmpty { return false }
        }
        return true
    }

    /// 숫자 세 구간과 선택적 사전 출시 접미사 허용. "unknown" 같은 값은 제외.
    static func isSemverPrefix(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        func digits() -> Bool {
            let start = index
            while index < bytes.count, bytes[index].isASCIIDigit { index += 1 }
            return index > start
        }
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        return index < bytes.count && bytes[index].isASCIIDigit
    }

    /// 사용량 스키마 위치에서만 null 검사 — 도구 인자·본문의 같은 이름 필드는 검사 제외.
    static func hasUnsupportedNullField(_ line: Data.SubSequence) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return false }
        return hasUnsupportedNullValue(object)
    }

    private static func hasUnsupportedNullValue(_ object: [String: Any]) -> Bool {
        if ["cwd", "costUSD", "version", "sessionId", "requestId", "isApiErrorMessage"]
            .contains(where: { object[$0] is NSNull }) { return true }
        guard let message = object["message"] as? [String: Any] else { return false }
        if ["id", "model"].contains(where: { message[$0] is NSNull }) { return true }
        guard let usage = message["usage"] as? [String: Any] else { return false }
        let fields = ["speed", "cache_read_input_tokens", "cache_creation_input_tokens"]
        if fields.contains(where: { usage[$0] is NSNull }) { return true }
        for iteration in usage["iterations"] as? [[String: Any]] ?? [] {
            let type = iteration["type"] as? String
            guard type == "advisor_message" || type == "compaction" else { continue }
            if fields.contains(where: { iteration[$0] is NSNull }) { return true }
            if type == "advisor_message", iteration["model"] is NSNull { return true }
        }
        return false
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
}
