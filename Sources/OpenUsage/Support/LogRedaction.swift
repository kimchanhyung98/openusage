import Foundation

/// Tauri redaction 함수들의 충실한 port — pure, `Sendable`, I/O 없음.
/// `redactLogMessage`는 설계상 URL/body를 모름 — URL이나 응답 body를 로그하는 호출부는 `redactURL`/`bodyPreview` 선처리 필수.
/// 정규식은 Rust 패턴을 그대로 재현해 static `let`으로 1회 컴파일.
enum LogRedaction {
    // MARK: - Value masking

    /// 민감 값을 `first4...last4`로 마스킹, 안전하게 가리기에 짧으면 `[REDACTED]`. Rust `char` 의미론에 맞춘 문자 기반.
    static func redactValue(_ value: String) -> String {
        let chars = Array(value)
        if chars.count <= 12 {
            return "[REDACTED]"
        }
        let first4 = String(chars.prefix(4))
        let last4 = String(chars.suffix(4))
        return "\(first4)...\(last4)"
    }

    // MARK: - URL

    /// 민감 query-parameter 이름의 소문자 substring 매치 목록.
    /// 소문자화한 이름이 이들 중 하나를 포함하고 값이 비어 있지 않으면 redaction; 원래 이름 표기는 보존.
    private static let urlSensitiveParams = [
        "key", "api_key", "apikey", "token", "access_token", "secret", "password",
        "auth", "authorization", "bearer", "credential", "user", "user_id", "userid",
        "account_id", "accountid", "profilearn", "profile_arn", "email", "login"
    ]

    /// URL의 민감 query parameter redaction — query string만 대상, path는 그대로 둠.
    static func redactURL(_ url: String) -> String {
        guard let queryStart = url.firstIndex(of: "?") else { return url }
        let base = String(url[..<url.index(after: queryStart)]) // '?' 포함
        let query = String(url[url.index(after: queryStart)...])

        let redactedParams = query.split(separator: "&", omittingEmptySubsequences: false).map { rawParam -> String in
            let param = String(rawParam)
            guard let eqPos = param.firstIndex(of: "=") else { return param }
            let name = String(param[..<eqPos])
            let value = String(param[param.index(after: eqPos)...])
            let nameLower = name.lowercased()
            if !value.isEmpty, urlSensitiveParams.contains(where: { nameLower.contains($0) }) {
                return "\(name)=\(redactValue(value))"
            }
            return param
        }
        return base + redactedParams.joined(separator: "&")
    }

    // MARK: - Body

    /// body에서 값이 redaction되는 JSON key 목록.
    private static let jsonSensitiveKeys = [
        "name", "password", "token", "access_token", "refresh_token", "secret", "api_key",
        "apiKey", "authorization", "bearer", "credential", "session_token", "sessionToken",
        "auth_token", "authToken", "id_token", "idToken", "accessToken", "refreshToken",
        "user_id", "userId", "account_id", "accountId", "team_id", "teamId", "org_id", "orgId",
        "account_display_name", "accountDisplayName", "payment_id", "paymentId", "profile_arn",
        "profileArn", "email", "login", "analytics_tracking_id"
    ]

    /// 로그용 response body redaction — JWT, quoted api-key, devin-session, JSON key, 파일 경로 순의 5개 pass.
    /// 잘림 경계에 걸친 secret도 잡히도록 truncation 전 redaction 필수.
    static func redactBody(_ body: String) -> String {
        var result = body
        result = replaceAll(jwtRegex, in: result) { redactValue($0) }
        result = replaceAll(apiKeyQuotedRegex, in: result) { match in
            let key = match.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return redactValue(key)
        }
        result = replaceAll(devinRegex, in: result) { redactValue($0) }
        for key in jsonSensitiveKeys {
            // "key": "value" 또는 "key":"value" 매치 — capture group 1이 값.
            guard let regex = jsonKeyRegexCache[key] else { continue }
            result = replaceGroup1(regex, in: result) { value in
                "\"\(key)\": \"\(redactValue(value))\""
            }
        }
        result = pathRegex.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[PATH]"
        )
        return result
    }

    /// body redaction 후 Character-safe truncation과 byte 수 suffix 부가 — byte 수는 원본 body의 UTF-8 길이 기준.
    /// body를 로그해야 하는 provider는 반드시 이 경로 사용.
    static func bodyPreview(_ body: String, limit: Int = 500) -> String {
        let redacted = redactBody(body)
        guard redacted.utf8.count > limit else { return redacted }
        // UTF-8 safe truncation: 시작 byte offset이 limit 미만인 문자까지 포함(Rust `char_indices` 동작 재현).
        var truncated = ""
        var byteOffset = 0
        for character in redacted {
            if byteOffset >= limit { break }
            truncated.append(character)
            byteOffset += String(character).utf8.count
        }
        return "\(truncated)... (\(body.utf8.count) bytes total)"
    }

    // MARK: - Log message

    /// 자유형 로그 메시지용 경량 redaction — JWT, no-quote api-key, devin-session, `account=`, 파일 경로 순의 5개 pass.
    static func redactLogMessage(_ message: String) -> String {
        var result = message
        result = replaceAll(jwtRegex, in: result) { redactValue($0) }
        result = replaceAll(apiKeyBareRegex, in: result) { redactValue($0) }
        result = replaceAll(devinRegex, in: result) { redactValue($0) }
        result = replaceAccountEq(in: result)
        result = pathRegex.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[PATH]"
        )
        return result
    }

    // MARK: - Compiled patterns (EXACT Rust patterns, compiled once)

    private static let jwtRegex = makeRegex(#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)
    private static let apiKeyQuotedRegex = makeRegex(#"["']?(sk-|pk-|api_|key_|secret_)[A-Za-z0-9_-]{12,}["']?"#)
    private static let apiKeyBareRegex = makeRegex(#"(sk-|pk-|api_|key_|secret_)[A-Za-z0-9_-]{12,}"#)
    private static let devinRegex = makeRegex(#"devin-session-token\$[^\s"',}\]]+"#)
    private static let accountRegex = makeRegex(#"(account=)([^,\s]+)"#)
    private static let pathRegex = makeRegex(#"(/(?:Users|home|opt|private|var|tmp|Applications)/[^\s"')]+)"#)

    /// 민감 JSON key별 컴파일된 정규식(`"<key>":\s*"([^"]+)"`), 1회 생성.
    private static let jsonKeyRegexCache: [String: NSRegularExpression] = {
        var cache: [String: NSRegularExpression] = [:]
        for key in jsonSensitiveKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            cache[key] = makeRegex("\"\(escaped)\":\\s*\"([^\"]+)\"")
        }
        return cache
    }()

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        // 패턴은 static literal — 실패는 프로그래머 오류이므로 redaction의 조용한 비활성화 대신 크게 실패.
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            fatalError("LogRedaction: invalid regex pattern: \(pattern)")
        }
        return regex
    }

    // MARK: - Regex replacement helpers

    /// `regex`의 전체 매치를 `transform` 결과로 치환. 역순 순회로 앞선 range 유효성 유지.
    private static func replaceAll(
        _ regex: NSRegularExpression,
        in input: String,
        transform: (String) -> String
    ) -> String {
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard !matches.isEmpty else { return input }
        var result = input
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }

    /// capture group 1을 `transform`에 넘겨 전체 매치를 그 결과로 치환. 역순 순회로 range 유효성 유지.
    private static func replaceGroup1(
        _ regex: NSRegularExpression,
        in input: String,
        transform: (String) -> String
    ) -> String {
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard !matches.isEmpty else { return input }
        var result = input
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range, in: result),
                  let groupRange = Range(match.range(at: 1), in: result)
            else { continue }
            let value = String(result[groupRange])
            result.replaceSubrange(fullRange, with: transform(value))
        }
        return result
    }

    /// `account=<value>` pass — `account=` prefix는 유지하고 값(group 2)만 redaction.
    private static func replaceAccountEq(in input: String) -> String {
        let matches = accountRegex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard !matches.isEmpty else { return input }
        var result = input
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let fullRange = Range(match.range, in: result),
                  let prefixRange = Range(match.range(at: 1), in: result),
                  let valueRange = Range(match.range(at: 2), in: result)
            else { continue }
            let prefix = String(result[prefixRange])
            let value = String(result[valueRange])
            result.replaceSubrange(fullRange, with: "\(prefix)\(redactValue(value))")
        }
        return result
    }
}
