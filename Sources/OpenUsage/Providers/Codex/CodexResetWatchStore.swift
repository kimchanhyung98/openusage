import Foundation

struct CodexResetWatch: Equatable, Sendable {
    let chancePercent: Double
    let deadline: Date
    var episodeID: String?
    var communityYesPercent: Double?
}

struct CodexResetWatchResult: Equatable, Sendable {
    var watch: CodexResetWatch?
    var refreshFailed = false
}

typealias CodexResetWatchLoading = @Sendable (_ force: Bool) async -> CodexResetWatchResult

/// 공개 Reset Watch 응답의 검증·ETag·backoff·single-flight 소유자.
actor CodexResetWatchStore {
    private static let fallbackFreshAge: TimeInterval = 60
    private static let maximumFreshAge: TimeInterval = 5 * 60
    private static let fallbackStaleAge: TimeInterval = 5 * 60
    private static let maximumStaleAge: TimeInterval = 5 * 60
    private static let failureRetryAge: TimeInterval = 60
    private static let rateLimitFallbackAge: TimeInterval = 5 * 60
    private static let maximumRetryAge: TimeInterval = 5 * 60

    private enum Representation: Sendable {
        case watch(CodexResetWatch)
        case absent
    }

    private struct CachePolicy: Sendable {
        let freshAge: TimeInterval
        let staleAge: TimeInterval
        var allowsStorage = true
        var requiresValidation = false

        static let fallback = CachePolicy(
            freshAge: CodexResetWatchStore.fallbackFreshAge,
            staleAge: CodexResetWatchStore.fallbackStaleAge
        )
    }

    private let http: any HTTPClient
    private let endpoint: URL
    private let votesEndpoint: URL
    private let now: @Sendable () -> Date

    private var representation: Representation?
    private var etag: String?
    private var freshUntil = Date.distantPast
    private var staleUntil = Date.distantPast
    private var retryNotBefore = Date.distantPast
    private var votesRetryNotBefore = Date.distantPast
    private var lastPolicy = CachePolicy.fallback
    private var refreshFailed = false
    private var refreshTask: Task<CodexResetWatchResult, Never>?

    init(
        http: any HTTPClient = URLSessionHTTPClient(sendsCookies: false),
        endpoint: URL = URL(string: "https://codex-resets.com/api/v1/status")!,
        votesEndpoint: URL = URL(string: "https://codex-resets.com/api/watch/votes")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.endpoint = endpoint
        self.votesEndpoint = votesEndpoint
        self.now = now
    }

    /// 현재 유효한 forecast — 외부 장애 시 마지막 유효 값 유지, provider refresh와 분리.
    func current() async -> CodexResetWatch? {
        await currentResult().watch
    }

    func currentResult(force: Bool = false) async -> CodexResetWatchResult {
        if let refreshTask { return await refreshTask.value }
        let readAt = now()
        if case .watch(let watch) = representation, readAt >= watch.deadline {
            representation = nil
            etag = nil
            freshUntil = .distantPast
            staleUntil = .distantPast
        }
        if !force, readAt < freshUntil {
            return result(watchIfUsable(at: readAt, validUntil: freshUntil))
        }
        if readAt < retryNotBefore {
            return result(watchIfUsable(at: readAt, validUntil: staleUntil))
        }

        if refreshTask == nil {
            refreshTask = Task { await self.refresh() }
        }
        guard let refreshTask else { return result(nil) }
        return await refreshTask.value
    }

    private func result(_ watch: CodexResetWatch?) -> CodexResetWatchResult {
        CodexResetWatchResult(watch: watch, refreshFailed: refreshFailed)
    }

    private func watchIfUsable(at date: Date, validUntil: Date) -> CodexResetWatch? {
        guard !lastPolicy.requiresValidation,
              date < validUntil, case .watch(let watch) = representation, date < watch.deadline else {
            return nil
        }
        return watch
    }

    private func refresh() async -> CodexResetWatchResult {
        defer { refreshTask = nil }

        var request = HTTPRequest(method: "GET", url: endpoint, timeout: 8)
        request.headers = [
            "Accept": "application/json",
            "User-Agent": "OpenUsage"
        ]
        if representation != nil, let etag {
            request.headers["If-None-Match"] = etag
        }

        do {
            let response = try await http.send(request)
            let receivedAt = now()
            switch response.statusCode {
            case 200:
                let decoded = await withCommunityVotes(try Self.decodeRepresentation(response.body, at: receivedAt))
                let policy = Self.cachePolicy(response.header("cache-control"), fallback: .fallback)
                representation = policy.allowsStorage ? decoded : nil
                etag = policy.allowsStorage ? response.header("etag") : nil
                lastPolicy = policy
                applyFreshness(policy, receivedAt: receivedAt, representation: decoded)
                retryNotBefore = .distantPast
                refreshFailed = false
                return result(watch(from: decoded, at: now()))
            case 304:
                guard let cached = representation else { throw FetchError.notModifiedWithoutCache }
                let representation = await withCommunityVotes(cached)
                self.representation = representation
                let policy = Self.cachePolicy(response.header("cache-control"), fallback: lastPolicy)
                if let responseETag = response.header("etag") { etag = responseETag }
                lastPolicy = policy
                applyFreshness(policy, receivedAt: receivedAt, representation: representation)
                if !policy.allowsStorage {
                    self.representation = nil
                    etag = nil
                }
                retryNotBefore = .distantPast
                refreshFailed = false
                return result(watch(from: representation, at: now()))
            case 429:
                let retrySeconds = Self.retryAfterSeconds(response, now: receivedAt)
                    ?? Self.rateLimitFallbackAge
                retryNotBefore = receivedAt.addingTimeInterval(retrySeconds)
                extendStaleUntilRetry()
                refreshFailed = true
                AppLog.warn(LogTag.plugin("codex"), "Reset Watch rate limited; retry deferred")
                return result(lastPolicy.requiresValidation ? nil : representation.flatMap { watch(from: $0, at: now()) })
            default:
                throw FetchError.httpStatus(response.statusCode)
            }
        } catch is CancellationError {
            return result(nil)
        } catch {
            let failedAt = now()
            retryNotBefore = failedAt.addingTimeInterval(Self.failureRetryAge)
            extendStaleUntilRetry()
            refreshFailed = true
            AppLog.warn(LogTag.plugin("codex"), "Reset Watch refresh failed: \(error.localizedDescription)")
            return result(lastPolicy.requiresValidation ? nil : representation.flatMap { watch(from: $0, at: now()) })
        }
    }

    private func watch(from representation: Representation, at date: Date) -> CodexResetWatch? {
        guard case .watch(let watch) = representation, date < watch.deadline else { return nil }
        return watch
    }

    private func withCommunityVotes(_ representation: Representation) async -> Representation {
        guard case .watch(var watch) = representation, watch.deadline > now() else { return representation }
        watch.communityYesPercent = nil
        guard now() >= votesRetryNotBefore else { return .watch(watch) }
        if let episodeID = watch.episodeID {
            let votes = await CodexResetWatchVotes.load(
                http: http, endpoint: votesEndpoint, episodeID: episodeID, now: now
            )
            watch.communityYesPercent = votes.percent
            votesRetryNotBefore = votes.retryNotBefore ?? .distantPast
        } else {
            AppLog.warn(LogTag.plugin("codex"), "Reset Watch community vote share unavailable: missing episode identity")
        }
        return .watch(watch)
    }

    private func extendStaleUntilRetry() {
        guard case .watch(let watch) = representation else { return }
        staleUntil = min(max(staleUntil, retryNotBefore), watch.deadline)
    }

    private func applyFreshness(
        _ policy: CachePolicy,
        receivedAt: Date,
        representation: Representation
    ) {
        guard policy.allowsStorage, !policy.requiresValidation else {
            freshUntil = .distantPast
            staleUntil = .distantPast
            return
        }
        var nextFresh = receivedAt.addingTimeInterval(policy.freshAge)
        var nextStale = nextFresh.addingTimeInterval(policy.staleAge)
        if case .watch(let watch) = representation {
            nextFresh = min(nextFresh, watch.deadline)
            nextStale = min(nextStale, watch.deadline)
        }
        freshUntil = nextFresh
        staleUntil = nextStale
    }

    private static func decodeRepresentation(_ body: Data, at date: Date) throws -> Representation {
        let payload = try JSONDecoder().decode(StatusPayload.self, from: body)
        guard let activeWatch = payload.data.activeWatch,
              let chance = activeWatch.resetChancePercent
        else {
            return .absent
        }
        guard (0...100).contains(chance) else { throw FetchError.invalidChance }
        guard let deadline = OpenUsageISO8601.date(from: activeWatch.expiresAt) else {
            throw FetchError.invalidDeadline
        }
        guard deadline > date else { return .absent }
        return .watch(CodexResetWatch(
            chancePercent: Double(chance), deadline: deadline,
            episodeID: activeWatch.source.flatMap { CodexResetWatchVotes.episodeID(from: $0.url) }
        ))
    }

    private static func cachePolicy(_ value: String?, fallback: CachePolicy) -> CachePolicy {
        guard let value else { return fallback }
        let names = Set(value.split(separator: ",").map {
            $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let directives = value.split(separator: ",").reduce(into: [String: TimeInterval]()) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            guard pair.count == 2,
                  let seconds = TimeInterval(pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))),
                  seconds.isFinite, seconds >= 0
            else { return }
            result[pair[0]] = seconds
        }
        let fresh = min(directives["max-age"] ?? fallback.freshAge, maximumFreshAge)
        let stale = min(directives["stale-while-revalidate"] ?? fallback.staleAge, maximumStaleAge)
        return CachePolicy(freshAge: fresh, staleAge: stale,
                           allowsStorage: !names.contains("no-store"),
                           requiresValidation: names.contains("no-cache"))
    }

    private static func retryAfterSeconds(_ response: HTTPResponse, now: Date) -> TimeInterval? {
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
            return min(seconds, maximumRetryAge)
        }
        guard let date = ResetWatchHTTPDateFormatter.date(from: raw) else { return nil }
        return min(max(0, date.timeIntervalSince(now)), maximumRetryAge)
    }
}

private enum ResetWatchHTTPDateFormatter {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}

private struct StatusPayload: Decodable {
    let data: DataPayload

    struct DataPayload: Decodable {
        let activeWatch: ActiveWatch?

        private enum CodingKeys: String, CodingKey {
            case activeWatch = "active_watch"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.activeWatch) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.activeWatch,
                    .init(codingPath: decoder.codingPath, debugDescription: "Missing active_watch")
                )
            }
            activeWatch = try container.decodeIfPresent(ActiveWatch.self, forKey: .activeWatch)
        }
    }

    struct ActiveWatch: Decodable {
        let resetChancePercent: Int?
        let expiresAt: String
        let source: Source?

        struct Source: Decodable {
            let url: String
        }

        private enum CodingKeys: String, CodingKey {
            case resetChancePercent = "reset_chance_percent"
            case expiresAt = "expires_at"
            case source
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.resetChancePercent) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.resetChancePercent,
                    .init(codingPath: decoder.codingPath, debugDescription: "Missing reset_chance_percent")
                )
            }
            resetChancePercent = try container.decodeIfPresent(Int.self, forKey: .resetChancePercent)
            expiresAt = try container.decode(String.self, forKey: .expiresAt)
            source = try? container.decodeIfPresent(Source.self, forKey: .source)
        }
    }
}

private enum FetchError: Error, LocalizedError {
    case httpStatus(Int)
    case notModifiedWithoutCache
    case invalidChance
    case invalidDeadline

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status): return "HTTP \(status)"
        case .notModifiedWithoutCache: return "HTTP 304 without cached Reset Watch data"
        case .invalidChance: return "Reset Watch chance was outside 0...100"
        case .invalidDeadline: return "Reset Watch deadline was invalid"
        }
    }
}
