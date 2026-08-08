import Foundation

/// 여러 provider가 공유하는 동작 없는 파싱 유틸 — 새 provider가 JSON/숫자/percent 처리를 복사하지 않고 재사용.
enum ProviderParse {
    /// raw response data에서 top-level JSON object 디코드.
    /// 빈 body는 조용한 `nil`; 파싱 실패한 비어 있지 않은 body는 boundary에서 로그; 유효하지만 object가 아닌 payload는 로그 없이 `nil`.
    static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            AppLog.warn(.http, "response body is not valid JSON (\(data.count) bytes): \(error.localizedDescription)")
            return nil
        }
    }

    /// 관대한 숫자 읽기 — JSON 숫자와 숫자 문자열 허용, boolean·non-finite 거부.
    /// `JSONSerialization`이 boolean을 `NSNumber`로 브리지하므로 `true`/`false`가 `1`/`0`이 되지 않도록 CF 타입 검사 필수.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let doubleValue = number.doubleValue
            return doubleValue.isFinite ? doubleValue : nil
        }
        if let string = value as? String {
            let doubleValue = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            return doubleValue?.isFinite == true ? doubleValue : nil
        }
        return nil
    }

    /// `JSONSerialization` 출력용 관대한 boolean 읽기 — `Bool`, 숫자 `NSNumber`, "true"/"1"/"false"/"0"(대소문자 무관) 허용.
    /// 그 외에는 `nil` — 부재·비인식 필드가 명시적 false와 구분되도록 함.
    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// 백분율의 0...100 clamp — non-finite 입력은 0 처리.
    static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    /// 정수 cents의 달러 변환 — 나누기 전 반올림으로 float drift 방지.
    static func centsToDollars(_ cents: Double) -> Double {
        cents.rounded() / 100
    }

    /// JSON 텍스트에서 `T` 디코드, hex 인코딩 JSON blob으로 fallback — 일부 provider는 자격 증명 파일을 hex(`0x` prefix 허용)로 저장.
    static func decodeJSONWithHexFallback<T: Decodable>(_ text: String, as type: T.Type) -> T? {
        if let decoded = decodeJSON(text, as: type) { return decoded }

        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else {
            return nil
        }

        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }
        return decodeJSON(decoded, as: type)
    }

    private static func decodeJSON<T: Decodable>(_ text: String, as type: T.Type) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// JWT payload(가운데 segment)의 JSON object 디코드 — base64url을 표준 base64로 변환·패딩 후 디코드.
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    /// `go-keyring-base64:` prefix 값 unwrap — Go 도구(`gh`, `agy`)의 macOS Keychain 저장 방식.
    /// prefix 없는 값은 trim만 해 반환; 빈 결과는 `nil`.
    static func unwrapGoKeyring(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            let encoded = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.nilIfEmpty
    }
}

extension String {
    /// `application/x-www-form-urlencoded` 값 1개의 percent-encode.
    /// RFC 3986 unreserved ASCII만 통과; 공백은 `%20`이라 literal `+`가 form-space와 구분됨.
    var urlFormEncoded: String {
        var encoded = ""
        encoded.reserveCapacity(utf8.count)

        for byte in utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    /// 빈 문자열이면 `nil`, 아니면 자기 자신 — ""를 "없음"으로 다루기 위함.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    /// 끝의 slash 제거 — base URL과 path 결합용.
    var trimmingTrailingSlashes: String {
        var copy = self
        while copy.hasSuffix("/") {
            copy.removeLast()
        }
        return copy
    }

    /// provider plan 이름의 title-case — `isSeparator`로 분할, 각 단어 첫 글자 대문자화, 단일 공백으로 재결합.
    /// `lowercasingTail`이 true면 나머지를 소문자화("PRO PLAN" → "Pro Plan"), 아니면 보존("pro_plus" → "Pro Plus").
    func titleCased(separator isSeparator: (Character) -> Bool, lowercasingTail: Bool = false) -> String {
        split(whereSeparator: isSeparator)
            .map { word in
                let head = word.prefix(1).uppercased()
                let tail = lowercasingTail ? word.dropFirst().lowercased() : String(word.dropFirst())
                return head + tail
            }
            .joined(separator: " ")
    }
}
