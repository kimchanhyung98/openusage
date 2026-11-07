import Foundation

enum UsageLogNumbers {
    /// 정수 문자열은 Double을 거치지 않아 큰 PID·token의 정밀도 유지. 소수·범위 초과·명시적 잘못된 값은 거부.
    static func count(_ value: Any?, missing: Int? = nil) -> Int? {
        guard let value else { return missing }
        let text: String
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            if ["f", "d"].contains(String(cString: number.objCType)), number.doubleValue > 9_007_199_254_740_991 {
                return nil
            }
            text = number.stringValue
        } else if let string = value as? String {
            text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }
        if let integer = Int(text) { return integer >= 0 ? integer : nil }
        let parts = text.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              let exponent = parts.count == 2 ? Int(parts[1]) : 0,
              let mantissa = parts.first
        else { return nil }
        let unsigned = mantissa.first == "+" || mantissa.first == "-" ? mantissa.dropFirst() : mantissa
        let decimal = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        guard decimal.count <= 2 else { return nil }
        let digits = decimal.joined()
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        var significant = String(digits.drop(while: { $0 == "0" }))
        if significant.isEmpty { return 0 }
        guard mantissa.first != "-" else { return nil }
        let scale = exponent.subtractingReportingOverflow(decimal.count == 2 ? decimal[1].count : 0)
        guard !scale.overflow else { return nil }
        if scale.partialValue >= 0 {
            let maxDigits = String(Int.max).count
            guard significant.count <= maxDigits, scale.partialValue <= maxDigits - significant.count else { return nil }
            significant += String(repeating: "0", count: scale.partialValue)
        } else {
            let trailingZeros = significant.reversed().prefix(while: { $0 == "0" }).count
            guard scale.partialValue >= -trailingZeros else { return nil }
            significant.removeLast(-scale.partialValue)
        }
        return Int(significant)
    }

    static func sum(_ counts: Int...) -> Int? {
        var sum = 0
        for count in counts {
            let next = sum.addingReportingOverflow(count)
            guard count >= 0, !next.overflow else { return nil }
            sum = next.partialValue
        }
        return sum
    }

    static func reportRejectedRows(_ count: Int, source: String) {
        guard count > 0 else { return }
        AppDiagnostics.record(
            .historyScan, result: .degraded, category: .decoding,
            providerID: TelemetryPrivacy.providerFamily(source),
            localContext: "source=\(source); invalid_numeric_rows=\(count)"
        )
    }
}
