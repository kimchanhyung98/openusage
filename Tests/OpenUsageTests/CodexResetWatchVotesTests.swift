import Foundation
import XCTest
@testable import OpenUsage

final class CodexResetWatchVotesTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let episode = "2096692394435752258"

    func testSameEpisodeUsesVoteRatioWithoutReplacingAIChance() async throws {
        let http = VotesHTTPClient([status(), votes()])
        let store = CodexResetWatchStore(http: http, now: { Self.now })
        let result = await store.currentResult()
        let watch = try XCTUnwrap(result.watch)
        XCTAssertEqual(watch.chancePercent, 45)
        XCTAssertEqual(watch.communityYesPercent, 79)
        XCTAssertFalse(result.refreshFailed)

        _ = await store.currentResult()
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        let request = requests[1]
        XCTAssertEqual(request.url.absoluteString, "https://codex-resets.com/api/watch/votes")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.timeout, 4)
        XCTAssertEqual(request.headers["Cache-Control"], "no-cache")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertEqual(request.headers["User-Agent"], "OpenUsage")
        XCTAssertNil(request.body)
        XCTAssertTrue(Set(request.headers.keys).isDisjoint(with: ["Authorization", "Cookie", "ChatGPT-Account-Id"]))
    }

    func testInvalidVotesAndFailuresLeaveForecastAvailable() async {
        for response in [
            votes(episode: "different"), votes(yes: "0", no: "0"),
            votes(yes: "-1"), votes(no: "-1"), votes(yes: "true"),
            votes(yes: "1.5"), votes(yes: "9007199254740992"),
            votes(yes: "9223372036854775807", no: "9223372036854775807"),
            HTTPResponse(statusCode: 503, headers: [:], body: Data()),
            HTTPResponse(statusCode: 429, headers: ["retry-after": "60"], body: Data()),
            HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        ] {
            let store = CodexResetWatchStore(http: VotesHTTPClient([status(), response]), now: { Self.now })
            let result = await store.currentResult()
            XCTAssertEqual(result.watch?.chancePercent, 45)
            XCTAssertNil(result.watch?.communityYesPercent)
            XCTAssertFalse(result.refreshFailed)
        }
        let store = CodexResetWatchStore(http: VotesHTTPClient([status()]), now: { Self.now })
        let result = await store.currentResult()
        XCTAssertEqual(result.watch?.chancePercent, 45)
        XCTAssertFalse(result.refreshFailed)
    }

    func testZeroAndUnanimousYesVotesAreValid() async {
        for (yes, no, expected) in [("0", "10", 0.0), ("10", "0", 100.0)] {
            let store = CodexResetWatchStore(
                http: VotesHTTPClient([status(), votes(yes: yes, no: no)]), now: { Self.now }
            )
            let result = await store.currentResult()
            XCTAssertEqual(result.watch?.communityYesPercent, expected)
        }
    }

    func testStatusRevalidationRefreshesVotesAndClearsFailedVoteValue() async {
        let notModified = HTTPResponse(statusCode: 304, headers: [:], body: Data())
        let http = VotesHTTPClient([
            status(cacheControl: "max-age=0"), votes(), notModified, votes(yes: "1", no: "1"),
            notModified, votes(episode: "different")
        ])
        let store = CodexResetWatchStore(http: http, now: { Self.now })
        let first = await store.currentResult()
        let second = await store.currentResult()
        let third = await store.currentResult()
        XCTAssertEqual(first.watch?.communityYesPercent, 79)
        XCTAssertEqual(second.watch?.communityYesPercent, 50)
        XCTAssertNil(third.watch?.communityYesPercent)
        XCTAssertEqual(third.watch?.chancePercent, 45)
        XCTAssertFalse(third.refreshFailed)
        let requests = await http.requests
        XCTAssertEqual(requests[2].headers["If-None-Match"], "watch-v1")
        XCTAssertNil(requests[3].headers["If-None-Match"])
    }

    func testManualRevalidationRefreshesVotesEvenWhenForecastIsUnchangedAndFresh() async {
        let http = VotesHTTPClient([
            status(), votes(), HTTPResponse(statusCode: 304, headers: [:], body: Data()), votes(yes: "1", no: "1")
        ])
        let store = CodexResetWatchStore(http: http, now: { Self.now })
        _ = await store.currentResult()
        let updated = await store.currentResult(force: true)
        XCTAssertEqual(updated.watch?.chancePercent, 45)
        XCTAssertEqual(updated.watch?.communityYesPercent, 50)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
    }

    func testNewEpisodeDoesNotReusePreviousVotes() async {
        let http = VotesHTTPClient([
            status(cacheControl: "max-age=0"), votes(),
            status(episode: "123", cacheControl: "max-age=0"), votes()
        ])
        let store = CodexResetWatchStore(http: http, now: { Self.now })
        _ = await store.currentResult()
        let result = await store.currentResult()
        XCTAssertEqual(result.watch?.episodeID, "123")
        XCTAssertNil(result.watch?.communityYesPercent)
    }

    func testAbsentOrExpiredWatchDoesNotRequestVotes() async {
        for body in [
            #"{"data":{"active_watch":null}}"#,
            #"{"data":{"active_watch":{"reset_chance_percent":45,"expires_at":"2000-01-01T00:00:00Z","source":{"url":"https://x.com/a/status/123"}}}}"#
        ] {
            let http = VotesHTTPClient([HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))])
            let store = CodexResetWatchStore(http: http, now: { Self.now })
            let result = await store.currentResult()
            XCTAssertNil(result.watch)
            let requests = await http.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testOnlyRecognizedSourcePostURLSuppliesEpisodeIdentity() {
        XCTAssertEqual(CodexResetWatchVotes.episodeID(from: "https://x.com/name/status/123?s=20"), "123")
        XCTAssertEqual(CodexResetWatchVotes.episodeID(from: "https://twitter.com/name/status/456"), "456")
        for source in ["https://example.com/name/status/123", "https://x.com/name", "https://x.com/name/status/abc"] {
            XCTAssertNil(CodexResetWatchVotes.episodeID(from: source))
        }
    }

    func testForcedReadRevalidatesFreshCacheWithoutDiscardingETag() async {
        let http = VotesHTTPClient([status(), votes(), status(chance: 60), votes()])
        let store = CodexResetWatchStore(http: http, now: { Self.now })
        _ = await store.currentResult()
        let updated = await store.currentResult(force: true)
        XCTAssertEqual(updated.watch?.chancePercent, 60)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[2].headers["If-None-Match"], "watch-v1")
    }

    func testForcedReadStillHonorsRateLimitAndFailureBackoff() async {
        for status in [429, 503] {
            let http = VotesHTTPClient([
                HTTPResponse(statusCode: status, headers: ["retry-after": "60"], body: Data())
            ])
            let store = CodexResetWatchStore(http: http, now: { Self.now })
            _ = await store.currentResult(force: true)
            let result = await store.currentResult(force: true)
            XCTAssertTrue(result.refreshFailed)
            let requests = await http.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testAutomaticReadJoinsForcedRefreshInsteadOfReturningOldFreshCache() async {
        let http = VotesHTTPClient([status(), votes(), status(chance: 60), votes()], delay: .milliseconds(100))
        let store = CodexResetWatchStore(http: http, now: { Self.now })
        _ = await store.currentResult()
        let manual = Task { await store.currentResult(force: true) }
        for _ in 0..<1000 {
            if await http.requests.count == 3 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let automatic = await store.currentResult()
        let manualResult = await manual.value
        XCTAssertEqual(automatic.watch?.chancePercent, 60)
        XCTAssertEqual(manualResult, automatic)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
    }

    func testVoteBackoffSkipsOnlyVotesAndResumesOnNextRefreshAfterDeadline() async {
        let retryDate = DateFormatter()
        retryDate.locale = Locale(identifier: "en_US_POSIX")
        retryDate.timeZone = TimeZone(secondsFromGMT: 0)
        retryDate.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        let cases: [(Int, String?, TimeInterval)] = [
            (429, "60", 60),
            (429, retryDate.string(from: Self.now.addingTimeInterval(120)), 120),
            (429, "900", 900),
            (429, nil, 300),
            (429, "invalid", 300),
            (503, nil, 60),
            (503, "120", 120)
        ]
        for (statusCode, retryAfter, delay) in cases {
            let clock = VoteRetryClock(Self.now)
            let failure = HTTPResponse(
                statusCode: statusCode, headers: retryAfter.map { ["retry-after": $0] } ?? [:], body: Data()
            )
            let http = VoteRetryHTTPClient(
                statuses: [status(), status(chance: 60), status(chance: 65), status(chance: 70), status(chance: 75)],
                votes: [failure, votes(), votes(yes: "1", no: "1")]
            )
            let store = CodexResetWatchStore(http: http, now: clock.read)
            let first = await store.currentResult(force: true)
            let immediate = await store.currentResult(force: true)
            XCTAssertEqual(first.watch?.chancePercent, 45)
            XCTAssertEqual(immediate.watch?.chancePercent, 60)
            XCTAssertNil(immediate.watch?.communityYesPercent)
            XCTAssertFalse(immediate.refreshFailed)
            clock.advance(by: delay - 1)
            let waiting = await store.currentResult(force: true)
            XCTAssertEqual(waiting.watch?.chancePercent, 65)
            XCTAssertNil(waiting.watch?.communityYesPercent)
            let countDuringWait = await http.voteCount
            XCTAssertEqual(countDuringWait, 1, "\(statusCode), Retry-After: \(retryAfter ?? "absent")")

            clock.advance(by: 1)
            let recovered = await store.currentResult(force: true)
            XCTAssertEqual(recovered.watch?.chancePercent, 70)
            XCTAssertEqual(recovered.watch?.communityYesPercent, 79)
            XCTAssertFalse(recovered.refreshFailed)
            let subsequent = await store.currentResult(force: true)
            XCTAssertEqual(subsequent.watch?.communityYesPercent, 50)
            let finalVoteCount = await http.voteCount
            XCTAssertEqual(finalVoteCount, 3)
        }
    }

    func testVoteCooldownSurvivesUnchangedAndNewForecastWithoutBlockingEither() async {
        let clock = VoteRetryClock(Self.now)
        let http = VoteRetryHTTPClient(
            statuses: [status(), HTTPResponse(statusCode: 304, headers: [:], body: Data()), status(episode: "123", chance: 60), status(episode: "123", chance: 65)],
            votes: [HTTPResponse(statusCode: 429, headers: ["retry-after": "60"], body: Data()), votes(episode: "123")]
        )
        let store = CodexResetWatchStore(http: http, now: clock.read)
        _ = await store.currentResult(force: true)
        let unchanged = await store.currentResult(force: true)
        let nextEpisode = await store.currentResult(force: true)
        XCTAssertEqual(unchanged.watch?.chancePercent, 45)
        XCTAssertEqual(nextEpisode.watch?.chancePercent, 60)
        XCTAssertEqual(nextEpisode.watch?.episodeID, "123")
        XCTAssertNil(nextEpisode.watch?.communityYesPercent)
        let count = await http.voteCount
        XCTAssertEqual(count, 1)
        clock.advance(by: 60)
        let recovered = await store.currentResult()
        XCTAssertEqual(recovered.watch?.chancePercent, 65)
        XCTAssertEqual(recovered.watch?.communityYesPercent, 79)
    }

    func testNetworkAndInvalidVoteFailuresUseIndependentOneMinuteBackoff() async {
        let failures: [HTTPResponse?] = [nil, HTTPResponse(statusCode: 200, headers: [:], body: Data("invalid".utf8))]
        for failure in failures {
            let clock = VoteRetryClock(Self.now)
            let http = VoteRetryHTTPClient(
                statuses: [status(), status(chance: 60), status(chance: 65)], votes: [failure, votes()]
            )
            let store = CodexResetWatchStore(http: http, now: clock.read)
            _ = await store.currentResult(force: true)
            let waiting = await store.currentResult(force: true)
            XCTAssertEqual(waiting.watch?.chancePercent, 60)
            XCTAssertFalse(waiting.refreshFailed)
            let count = await http.voteCount
            XCTAssertEqual(count, 1)
            clock.advance(by: 60)
            let recovered = await store.currentResult(force: true)
            XCTAssertEqual(recovered.watch?.communityYesPercent, 79)
        }
    }

    private func status(episode: String = episode, cacheControl: String = "max-age=60", chance: Int = 45) -> HTTPResponse {
        let body = """
        {"data":{"active_watch":{"reset_chance_percent":\(chance),
        "expires_at":"\(OpenUsageISO8601.string(from: Self.now.addingTimeInterval(3600)))",
        "source":{"url":"https://x.com/thsottiaux/status/\(episode)"}}}}
        """
        return HTTPResponse(statusCode: 200, headers: ["cache-control": cacheControl, "etag": "watch-v1"], body: Data(body.utf8))
    }

    private func votes(episode: String = episode, yes: String = "11316", no: String = "2980") -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data("""
        {"episode_id":"\(episode)","yes":\(yes),"no":\(no)}
        """.utf8))
    }
}

private final class VoteRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) { self.instant = instant }
    func read() -> Date { lock.withLock { instant } }
    func advance(by seconds: TimeInterval) { lock.withLock { instant.addTimeInterval(seconds) } }
}

private actor VoteRetryHTTPClient: HTTPClient {
    private var statuses: [HTTPResponse]
    private var votes: [HTTPResponse?]
    private(set) var voteCount = 0

    init(statuses: [HTTPResponse], votes: [HTTPResponse?]) {
        self.statuses = statuses
        self.votes = votes
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path == "/api/watch/votes" {
            voteCount += 1
            guard !votes.isEmpty else { throw URLError(.timedOut) }
            guard let response = votes.removeFirst() else { throw URLError(.timedOut) }
            return response
        }
        guard !statuses.isEmpty else { throw URLError(.timedOut) }
        return statuses.removeFirst()
    }
}

private actor VotesHTTPClient: HTTPClient {
    var requests: [HTTPRequest] = []
    private var responses: [HTTPResponse]
    private let delay: Duration

    init(_ responses: [HTTPResponse], delay: Duration = .zero) {
        self.responses = responses
        self.delay = delay
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.timedOut) }
        let response = responses.removeFirst()
        if delay > .zero { try await Task.sleep(for: delay) }
        return response
    }
}
