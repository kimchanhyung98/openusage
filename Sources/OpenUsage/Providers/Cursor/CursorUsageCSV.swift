import Foundation

/// Cursor CSV usage export의 파싱된 행 하나. `imputedCostDollars`는 로컬 산정 달러(server CSV tokens × 공유 모델 pricing) — 어떤 pricing source도 모델을 모르면 nil, 그 행은 tokens만 기여하고 그날 cost를 불완전으로 표시.
/// `../cursorcat/Sources/CursorCat/API/UsageCSV.swift`에서 이식, v1에서는 actual-cost/CostMode 경로 제외.
struct CursorUsageCSVRow: Sendable, Equatable {
    var date: Date
    var model: String
    var tokens: TokenBreakdown
    var imputedCostDollars: Double?
}

struct CursorUsageCSVParseResult: Sendable, Equatable {
    var rows: [CursorUsageCSVRow]
    var rejectedRowCount: Int
}

enum CursorUsageCSVError: Error, Equatable {
    case missingColumns([String])
    case malformedCSV
}

enum CursorUsageCSV {
    private enum Column {
        static let date = "Date"
        static let model = "Model"
        static let cacheWrite = "Input (w/ Cache Write)"
        static let input = "Input (w/o Cache Write)"
        static let cacheRead = "Cache Read"
        static let output = "Output Tokens"
        static let required = [date, model, cacheWrite, input, cacheRead, output]
    }

    // 날짜 파싱은 큰 export의 행마다 실행 — 고정 형식 parser 3개는 설정 후 stateless라 호출마다 대신 1회 생성. DateFormatter·ISO8601DateFormatter는 파싱에 thread-safe, `nonisolated(unsafe)`로 불변 인스턴스 공유.
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let plainDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 순수 boundary parser: Cursor의 export CSV 텍스트를 priced 행으로 매핑, 잘못된 행은 거부, export schema 자체가 못 쓰면 실패. 빈 숫자 셀은 유효한 0 — 비어 있지 않은 비정수·음수 token 수는 조용히 0이 되는 대신 그 행을 거부.
    /// Cursor CSV 행은 개별 요청이 아닌 집계라 long-context threshold·Max Mode uplift를 행 합계에 신뢰성 있게 적용 불가 — 행은 base 모델 API rate로 과금.
    static func parse(csv: String, pricing: ModelPricing) throws -> CursorUsageCSVParseResult {
        var rows: [CursorUsageCSVRow] = []
        var rejectedRowCount = 0
        var acceptedTokenCount = 0
        var missingColumns = Column.required
        var hasDuplicateColumns = false
        let summary = CursorCSVParser.forEachRecord(in: csv, header: { header in
            let available = Set(header)
            missingColumns = Column.required.filter { !available.contains($0) }
            hasDuplicateColumns = available.count != header.count
        }) { r in
            guard let dateStr = r[Column.date]?.trimmingCharacters(in: .whitespaces),
                  !dateStr.isEmpty,
                  let date = parseDate(dateStr),
                  let model = r[Column.model]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty,
                  let cacheWrite = parseIntValue(r[Column.cacheWrite]),
                  let input = parseIntValue(r[Column.input]),
                  let cacheRead = parseIntValue(r[Column.cacheRead]),
                  let output = parseIntValue(r[Column.output]),
                  let rowTokenCount = addingWithoutOverflow([cacheWrite, input, cacheRead, output])
            else {
                rejectedRowCount += 1
                return
            }
            let aggregate = acceptedTokenCount.addingReportingOverflow(rowTokenCount)
            guard !aggregate.overflow else {
                rejectedRowCount += 1
                return
            }
            acceptedTokenCount = aggregate.partialValue

            // CSV의 "Input (w/ Cache Write)" tokens는 prompt cache에 기록된 것 — Anthropic은 5분 cache-write rate, 다른 provider는 input rate로 과금(그들의 pricing entry는 cacheWrite == input).
            let tokens = TokenBreakdown(
                input: input,
                cacheWrite5m: cacheWrite,
                cacheRead: cacheRead,
                output: output
            )

            rows.append(CursorUsageCSVRow(
                date: date,
                model: model,
                tokens: tokens,
                imputedCostDollars: pricing.estimatedCostDollars(
                    model: model,
                    tokens: tokens,
                    applyLongContextRates: false
                )
            ))
        }
        guard summary.isStructurallyComplete, !hasDuplicateColumns else {
            throw CursorUsageCSVError.malformedCSV
        }
        guard missingColumns.isEmpty else { throw CursorUsageCSVError.missingColumns(missingColumns) }
        rejectedRowCount += summary.rejectedRecordCount
        return CursorUsageCSVParseResult(rows: rows, rejectedRowCount: rejectedRowCount)
    }

    private static func parseDate(_ raw: String) -> Date? {
        if let d = isoFractional.date(from: raw) { return d }
        if let d = iso.date(from: raw) { return d }
        return plainDateTime.date(from: raw)
    }

    private static func parseIntValue(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return 0 }

        let groups = normalized.split(separator: ",", omittingEmptySubsequences: false)
        if groups.count > 1 {
            guard let first = groups.first,
                  (1...3).contains(first.utf8.count),
                  isASCIIDigits(first),
                  groups.dropFirst().allSatisfy({ $0.utf8.count == 3 && isASCIIDigits($0) })
            else {
                return nil
            }
        } else if !isASCIIDigits(normalized[...]) {
            return nil
        }
        return Int(groups.joined())
    }

    private static func isASCIIDigits(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func addingWithoutOverflow(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
}
