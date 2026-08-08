import Foundation

/// pricing source 1개(LiteLLM 또는 models.dev)의 평면 model-key → rates table — ccusage lookup semantics.
/// 정확 key 우선, 다음 boundary 인식 fuzzy — provider prefix·separator 변형·날짜 suffix 허용,
/// 숫자 version 혼동 금지 (`claude-sonnet-4`는 `claude-sonnet-4-5`와 매칭 불가).
struct PricingCatalog: Sendable, Equatable {
    var entries: [String: ModelRates]
    /// source 데이터 발행 시점 — log용 참고 정보.
    var retrievedAt: String?

    init(entries: [String: ModelRates] = [:], retrievedAt: String? = nil) {
        self.entries = entries
        self.retrievedAt = retrievedAt
    }

    func findExact(_ model: String) -> (key: String, rates: ModelRates)? {
        entries[model].map { (model, $0) }
    }

    /// 전체 entry 대상 fuzzy lookup — 최장 일치 key 우선, 동률은 사전순 최소로 결정성 확보. 정확 lookup miss 후에만 호출.
    func findFuzzy(_ model: String) -> (key: String, rates: ModelRates)? {
        let normalizedModel = Self.normalizedKey(model)
        var best: (key: String, rates: ModelRates)?
        for (key, rates) in entries {
            guard Self.keyMatches(candidate: key, model: model, normalizedModel: normalizedModel) else { continue }
            if let current = best {
                if key.count > current.key.count || (key.count == current.key.count && key < current.key) {
                    best = (key, rates)
                }
            } else {
                best = (key, rates)
            }
        }
        return best
    }

    /// 다른 catalog을 위에 merge — key별로 `other`의 entry 우선.
    func merging(_ other: PricingCatalog) -> PricingCatalog {
        var merged = entries
        merged.merge(other.entries) { _, new in new }
        return PricingCatalog(entries: merged, retrievedAt: other.retrievedAt ?? retrievedAt)
    }
}

// MARK: - Fuzzy matching (port of ccusage pricing.rs)

extension PricingCatalog {
    /// separator 변형 정규화 — `.`와 `@`를 `-`로 (`grok-4.3` → `grok-4-3`).
    static func normalizedKey(_ value: String) -> String {
        guard value.contains(".") || value.contains("@") else { return value }
        return value.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "@", with: "-")
    }

    /// 후보 key 매칭 — raw 또는 정규화 형태에서 어느 한쪽이 다른 쪽을 word boundary에서 포함하면 일치.
    static func keyMatches(candidate: String, model: String, normalizedModel: String) -> Bool {
        if containsKey(model, key: candidate) || containsKey(candidate, key: model) {
            return true
        }
        let normalizedCandidate = normalizedKey(candidate)
        return containsKey(normalizedModel, key: normalizedCandidate)
            || containsKey(normalizedCandidate, key: normalizedModel)
    }

    /// `value` 안 `key` 탐색 — 양끝이 비영숫자 boundary이고 suffix가 숫자 version을 잇지 않는 위치만 허용.
    static func containsKey(_ value: String, key: String) -> Bool {
        guard !key.isEmpty else { return false }
        let valueBytes = Array(value.utf8)
        let keyBytes = Array(key.utf8)
        guard keyBytes.count <= valueBytes.count else { return false }
        for start in 0...(valueBytes.count - keyBytes.count) {
            guard valueBytes[start..<(start + keyBytes.count)].elementsEqual(keyBytes) else { continue }
            let beforeOK = start == 0 || !valueBytes[start - 1].isASCIIAlphanumeric
            guard beforeOK else { continue }
            let suffix = Array(valueBytes[(start + keyBytes.count)...])
            if suffixAllowsMatch(key: keyBytes, suffix: suffix) {
                return true
            }
        }
        return false
    }

    private static func suffixAllowsMatch(key: [UInt8], suffix: [UInt8]) -> Bool {
        guard let separator = suffix.first else { return true }
        if separator.isASCIIAlphanumeric { return false }
        return !suffixStartsWithNumericModelVersion(key: key, suffix: suffix)
    }

    /// 숫자 key의 version 연속 suffix 거부 (`claude-sonnet-4` + `-5-...`) — 8자리 날짜 suffix(`-20250514`)는 허용.
    private static func suffixStartsWithNumericModelVersion(key: [UInt8], suffix: [UInt8]) -> Bool {
        let dateSuffixDigits = 8
        guard let last = key.last, last.isASCIIDigit else { return false }
        guard let separator = suffix.first, separator == UInt8(ascii: "-") || separator == UInt8(ascii: ".") else {
            return false
        }
        let rest = suffix.dropFirst()
        let digitCount = rest.prefix(while: \.isASCIIDigit).count
        guard digitCount > 0 else { return false }
        let afterDigits = rest.dropFirst(digitCount).first
        let isDateSuffix = digitCount == dateSuffixDigits && (afterDigits.map { !$0.isASCIIAlphanumeric } ?? true)
        return !isDateSuffix
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
    var isASCIIAlphanumeric: Bool {
        isASCIIDigit
            || (self >= UInt8(ascii: "a") && self <= UInt8(ascii: "z"))
            || (self >= UInt8(ascii: "A") && self <= UInt8(ascii: "Z"))
    }
}
