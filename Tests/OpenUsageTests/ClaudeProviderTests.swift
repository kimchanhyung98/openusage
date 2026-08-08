import XCTest
@testable import OpenUsage

final class ClaudeAuthStoreTests: XCTestCase {
    func testParsesHexEncodedCredentials() {
        let raw = #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro"}}"#
        let hex = raw.utf8.map { String(format: "%02x", $0) }.joined()

        let credentials = ClaudeAuthStore.parseCredentials(hex)

        XCTAssertEqual(credentials?.claudeAiOauth?.accessToken, "token")
        XCTAssertEqual(credentials?.claudeAiOauth?.subscriptionType, "pro")
    }

    func testCredentialDiagnosticsLabelIsTokenFreeWithSourceRefreshAndExpiredFlags() {
        // diagnostics에 source 종류·refresh 유무·만료 여부만 포함, token 값 노출 금지 (#738)
        let now = Date(timeIntervalSince1970: 1_000_000) // 밀리초 기준 1_000_000_000

        let fresh = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "ACCESS_SECRET", refreshToken: "REFRESH_SECRET", expiresAt: 2_000_000_000_000),
            source: .keychainCurrentUser(service: "Claude Code-credentials"),
            fullData: nil,
            inferenceOnly: false
        )
        XCTAssertEqual(fresh.diagnosticsLabel(now: now), "keychainCurrentUser refresh=yes expired=no")
        XCTAssertFalse(fresh.diagnosticsLabel(now: now).contains("SECRET")) // token 값 미노출

        // refresh token 없음 + 이미 만료된 access token: self-heal 불가능한 #738 형태
        let lockedOut = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "a", refreshToken: nil, expiresAt: 1),
            source: .file,
            fullData: nil,
            inferenceOnly: false
        )
        XCTAssertEqual(lockedOut.diagnosticsLabel(now: now), "file refresh=no expired=yes")

        // 빈 refresh token은 부재로 간주, expiry 누락은 fresh 가정 없이 unknown으로 보고
        let unknownExpiry = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "a", refreshToken: "", expiresAt: nil),
            source: .keychainLegacy(service: "svc"),
            fullData: nil,
            inferenceOnly: false
        )
        XCTAssertEqual(unknownExpiry.diagnosticsLabel(now: now), "keychainLegacy refresh=no expired=unknown")
    }

    func testPrefersCurrentUserKeychainCredentialsBeforeFile() {
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"pro"}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let hashedService = store.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"max"}}"#

        let credentials = store.loadCredentialCandidates().first

        XCTAssertTrue(hashedService.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(credentials?.oauth.accessToken, "keychain-token")
        XCTAssertEqual(credentials?.oauth.subscriptionType, "max")
    }

    func testPrefersKeychainOverFileEvenWhenFileTokenExpiresLater() {
        // #738 회귀: 파일 expiry가 더 늦어도 live source of truth인 keychain 우선, 파일은 fallback 후보로 유지
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","expiresAt":4102444800000,"subscriptionType":"pro"}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let hashedService = store.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-token","expiresAt":4070908800000,"subscriptionType":"max"}}"#

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "file-token"])
        XCTAssertEqual(store.loadCredentialCandidates().first?.oauth.accessToken, "keychain-token")
    }

    func testEnvironmentTokenIsInferenceOnly() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: FakeKeychain()
        )

        let credentials = store.loadCredentialCandidates().first

        XCTAssertEqual(credentials?.oauth.accessToken, "env-token")
        XCTAssertEqual(store.liveUsageAvailability(credentials!), .inferenceOnlyToken)
    }

    func testEnvTokenDoesNotShadowProfileScopedStoredLogin() {
        // inference-only인 CLAUDE_CODE_OAUTH_TOKEN이 usage 조회 가능한 stored login을 가리지 않아야 함
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials"] =
            #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"max","scopes":["user:inference","user:profile"]}}"#
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: keychain
        )

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "env-token"])
        // keychain login이 선두(live usage 조회 가능), env token은 inference-only fallback
        XCTAssertEqual(store.liveUsageAvailability(candidates[0]), .available)
        XCTAssertFalse(candidates[0].inferenceOnly)
        XCTAssertEqual(store.liveUsageAvailability(candidates[1]), .inferenceOnlyToken)
    }

    func testEnvTokenIsSoleCandidateWhenStoredLoginCannotReadUsage() {
        // user:profile 없는 stored login도 usage 조회 불가 → env token만 유일한 inference-only 후보
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials"] =
            #"{"claudeAiOauth":{"accessToken":"inference-login","subscriptionType":"max","scopes":["user:inference"]}}"#
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: keychain
        )

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["env-token"])
        XCTAssertEqual(store.liveUsageAvailability(candidates[0]), .inferenceOnlyToken)
    }

    func testEnvFallbackBorrowsMetadataFromThePreferredLiveCapableLogin() {
        // env fallback의 표시 metadata는 skip된 keychain login이 아니라 실제 선호된 file login에서 상속
        let files = FakeFiles([
            "/tmp/claude/.credentials.json":
                #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"max","scopes":["user:inference","user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude", "CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: files,
            keychain: keychain
        )
        keychain.currentUserValues[store.keychainServiceCandidates().first!] =
            #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"pro","scopes":["user:inference"]}}"#

        let candidates = store.loadCredentialCandidates()

        // user:profile 없는 keychain login 제외, file login 우선 + env token 후순위
        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["file-token", "env-token"])
        // env fallback은 선호된 file login의 plan을 차용
        XCTAssertEqual(candidates[1].oauth.subscriptionType, "max")
    }

    func testLiveUsageAvailabilityReflectsProfileScope() {
        let store = ClaudeAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: FakeKeychain())
        func state(_ scopes: [String]?, inferenceOnly: Bool = false) -> ClaudeCredentialState {
            ClaudeCredentialState(
                oauth: ClaudeOAuth(accessToken: "token", scopes: scopes),
                source: .keychainCurrentUser(service: "Claude Code-credentials"),
                fullData: nil,
                inferenceOnly: inferenceOnly
            )
        }

        // scopes 필드 이전의 구형 credential: 부재/빈 리스트는 "unknown, allow"
        XCTAssertEqual(store.liveUsageAvailability(state(nil)), .available)
        XCTAssertEqual(store.liveUsageAvailability(state([])), .available)
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference", "user:profile"])), .available)
        // user:profile 없는 token(예: `claude setup-token`)은 usage 조회 불가
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference"])), .missingProfileScope)
        // 명시적 env token은 설계상 inference-only: missing-scope 알림 없이 silent
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference"], inferenceOnly: true)), .inferenceOnlyToken)
    }

    func testMalformedCustomOAuthURLThrowsInsteadOfCrashing() {
        // 잘못된 custom OAuth URL은 system-boundary 입력: crash나 prod fallback 대신 oauthConfig()의 명시적 throw
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_CUSTOM_OAUTH_URL": "http://exa mple.com"]),
            files: FakeFiles(),
            keychain: FakeKeychain()
        )

        XCTAssertThrowsError(try store.oauthConfig()) { error in
            guard case ClaudeAuthError.invalidOAuthURL = error else {
                return XCTFail("expected ClaudeAuthError.invalidOAuthURL, got \(error)")
            }
        }

        // credential-load 경로는 file suffix만 필요 — 잘못된 URL이 keychain 후보 해석을 깨지 않아야 함
        XCTAssertEqual(store.keychainServiceCandidates(), ["Claude Code-custom-oauth-credentials"])
    }
}

final class ClaudeUsageMapperTests: XCTestCase {
    func testMapsUsageWindowsExtraUsageAndPlan() throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("""
            {
              "five_hour": { "utilization": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day": { "utilization": 20, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day_sonnet": { "utilization": 5, "resets_at": "2099-01-01T00:00:00.000Z" },
              "extra_usage": { "is_enabled": true, "used_credits": 500, "monthly_limit": 1000 }
            }
            """.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "max", rateLimitTier: "claude_max_subscription_20x")
        )

        XCTAssertEqual(mapped.plan, "Max 20x")
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 10)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.periodDurationMs, ClaudeUsageMapper.weeklyPeriodMs)
        XCTAssertEqual(progress(mapped.lines, "Sonnet")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Extra usage spent")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Extra usage spent")?.limit, 10)
    }

    func testMapsFableScopedWeeklyLimitFromLimitsArray() throws {
        // 모델별 weekly 한도가 `limits[]`의 `weekly_scoped` 행으로 이동, 레거시 `seven_day_<model>` 키는 null 반환
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("""
            {
              "five_hour": { "utilization": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day": { "utilization": 20, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day_sonnet": null,
              "limits": [
                { "kind": "session", "group": "session", "percent": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
                { "kind": "weekly_all", "group": "weekly", "percent": 20, "resets_at": "2099-01-08T00:00:00.000Z" },
                { "kind": "weekly_scoped", "group": "weekly", "percent": 7,
                  "resets_at": "2099-01-08T00:00:00.000Z",
                  "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null } }
              ]
            }
            """.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "max")
        )

        XCTAssertEqual(progress(mapped.lines, "Fable")?.used, 7)
        XCTAssertEqual(progress(mapped.lines, "Fable")?.limit, 100)
        XCTAssertEqual(progress(mapped.lines, "Fable")?.periodDurationMs, ClaudeUsageMapper.weeklyPeriodMs)
    }

    func testUncappedExtraUsageIsAnUnboundedValuesRow() throws {
        // `monthly_limit` 부재: 상한 없는 지출 → `.text`가 아닌 unbounded `.values` 행 (`MetricFormatter`로 포맷)
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"extra_usage":{"is_enabled":true,"used_credits":123456}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "max")
        )

        guard case .values(_, let values, _, _, _, _)? = mapped.lines.first(where: { $0.label == "Extra usage spent" }) else {
            return XCTFail("Expected an Extra usage spent .values line")
        }
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.kind, .dollars)
        XCTAssertEqual(try XCTUnwrap(values.first?.number), 1234.56, accuracy: 0.0001)
        XCTAssertNil(progress(mapped.lines, "Extra usage spent"))
    }

    func testMapsResetsAtFromMicrosecondTimestampWithoutTimezone() throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":0,"resets_at":"2099-06-01T12:00:00.123456"}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "pro")
        )

        let resetsAt = try XCTUnwrap(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(OpenUsageISO8601.string(from: resetsAt), "2099-06-01T12:00:00.123Z")
    }

    func testMapsResetsAtFromUnixEpochNumber() throws {
        let epochSeconds = 2_099_010_100.0
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":0,"resets_at":2099010100}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "pro")
        )

        let resetsAt = try XCTUnwrap(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince1970, epochSeconds, accuracy: 1)
    }

    func testRateLimitRetryAfterBadge() {
        let mapped = ClaudeUsageMapper.rateLimitedUsage(
            credentials: ClaudeOAuth(subscriptionType: "pro"),
            retryAfterSeconds: 600
        )

        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(badge(mapped.lines, "Status"), "Rate limited, retry in ~10m")
        XCTAssertEqual(text(mapped.lines, "Note"), "Live usage rate limited - retry in ~10m")
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let text, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return text
    }

    private func text(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .text(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }
}

@MainActor
final class ClaudeProviderTests: XCTestCase {
    func testRefreshFetchesLiveUsageAndScansConfigDirLogs() async throws {
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        ))
        // 픽스처 라인에 costUSD 포함 → 타일은 계산이 아닌 전달된 달러 값
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T16:00:00.000Z", input: 100, output: 50, costUSD: 0.25
            )
        ])
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: home),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNotNil(snapshot.lines.first(where: { $0.label == "Session" }))
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        XCTAssertTrue(httpClient.requests.contains { $0.url.absoluteString == "https://api.anthropic.com/api/oauth/usage" })
    }

    func testInferenceOnlyScopeSurfacesReloginWarningAndSkipsUsageCallButKeepsSpendTiles() async throws {
        // `user:profile` scope 없는 credential: soft warning 표시 + usage 호출 skip, 로컬 spend 타일은 유지
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        ))
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T16:00:00.000Z", input: 100, output: 50, costUSD: 0.25
            )
        ])
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"max","rateLimitTier":"default_claude_max_5x","scopes":["user:inference"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: home),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        // hard error badge가 아닌 soft warning으로 missing scope 안내, live-usage 미터는 공백
        XCTAssertEqual(snapshot.warning, ClaudeUsageMapper.missingProfileScopeWarning)
        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertNil(snapshot.line(label: "Session"))
        // scope gate의 핵심: usage endpoint 미호출
        XCTAssertFalse(httpClient.requests.contains { $0.url.absoluteString.hasSuffix("/api/oauth/usage") })
        // 로컬 spend 타일은 영향 없이 로드
        XCTAssertNotNil(values(snapshot.lines, "Today"))
        XCTAssertEqual(snapshot.plan, "Max 5x")
    }

    func testLiveClaudeUsageReportsResetFields() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENUSAGE_LIVE_CLAUDE"] == "1")

        let store = ClaudeAuthStore()
        guard let state = store.loadCredentialCandidates().first else {
            throw XCTSkip("No Claude credentials on this machine")
        }

        let response = try await ClaudeUsageClient().fetchUsage(
            accessToken: state.oauth.accessToken ?? "",
            config: store.oauthConfig()
        )
        XCTAssertTrue((200..<300).contains(response.statusCode))
        let resetHeaders = response.headers.filter { $0.key.localizedCaseInsensitiveContains("reset") }
        print("LIVE response reset headers:", resetHeaders)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        for key in ["five_hour", "seven_day", "seven_day_sonnet"] {
            guard let window = body[key] as? [String: Any] else { continue }
            print("LIVE \(key)=", window)
        }

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: state.oauth
        )
        for label in ["Session", "Weekly", "Sonnet"] {
            let resetsAt = Self.progress(mapped.lines, label)?.resetsAt
            print("LIVE mapped \(label) resetsAt=", resetsAt as Any)
        }
    }

    func testRetriesOnceAfter401AndPersistsRefreshedCredentials() async {
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"stale-token","refreshToken":"refresh-1","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("fresh-token") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"access_token":"fresh-token","refresh_token":"refresh-2","expires_in":3600}"#.utf8)
            )
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.lines.first(where: { $0.label == "Session" }))
        let usageCalls = httpClient.requests.filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }
        XCTAssertEqual(usageCalls.count, 2)
        let saved = files.files["/tmp/claude/.credentials.json"] ?? ""
        XCTAssertTrue(saved.contains("fresh-token"))
        XCTAssertTrue(saved.contains("refresh-2"))
    }

    func testFallsBackToFileWhenKeychainTokenIsLockedOut() async {
        // #687: keychain의 revoked token 대신 파일의 fresh token으로 fall through해 복구
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"fresh-access","refreshToken":"fresh-refresh","expiresAt":4070908800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain,
            now: { now }
        )
        // keychain을 항상 먼저 probe → expiry 재정렬이 아닌 auth-failure fallback 검증
        let hashedService = authStore.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#

        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let authorization = request.headers["Authorization"] ?? ""
                guard authorization.contains("fresh-access") else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            // refresh endpoint: stale 후보만 도달, 해당 refresh token은 revoked
            return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        // file source에서 복구: plan·usage가 fresh token 반영, error badge 없음
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(Self.progress(snapshot.lines, "Session")?.used, 42)
        XCTAssertNil(badge(snapshot.lines, "Error"))
    }

    func testSurfacesAuthErrorWhenAllCredentialSourcesAreExpired() async {
        // keychain·file 모두 revoked인 상태는 조용한 복구 대신 auth error를 명확히 노출
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-stale","refreshToken":"file-refresh","expiresAt":4070908800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain,
            now: { now }
        )
        let hashedService = authStore.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-stale","refreshToken":"keychain-refresh","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#

        // 모든 usage 호출 401 + 모든 refresh revoked → 두 source 모두 사용 불가
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.sessionExpired.localizedDescription)
    }

    func testNoCredentialsReportsNotLoggedIn() async {
        func makeProvider(files: FakeFiles) -> ClaudeProvider {
            ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(),
                    files: files,
                    keychain: FakeKeychain()
                ),
                usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                pricing: { TestPricing.bundled }
            )
        }

        let noneAtAll = makeProvider(files: FakeFiles())
        let plainSnapshot = await noneAtAll.refresh()
        XCTAssertEqual(badge(plainSnapshot.lines, "Error"), ClaudeAuthError.notLoggedIn.localizedDescription)

        // 공백 accessToken은 store의 isEmpty 검사는 통과하지만 provider의 trim 필터에서 제거
        let corruptCLI = makeProvider(files: FakeFiles([
            "~/.claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"   "}}"#
        ]))
        let corruptSnapshot = await corruptCLI.refresh()
        XCTAssertEqual(badge(corruptSnapshot.lines, "Error"), ClaudeAuthError.notLoggedIn.localizedDescription)
    }

    func testRateLimitedResponseMapsToRetryBadgeNotError() async {
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 429,
            headers: ["retry-after": "600"],
            body: Data()
        ))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(badge(snapshot.lines, "Status")?.hasPrefix("Rate limited"), true)
        // badge/note 라인은 layout에서 켜져야 렌더 → rate-limit 상태가 provider header warning까지 도달 필요
        XCTAssertEqual(
            snapshot.warning,
            "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse. Retrying in ~10m."
        )
    }

    func testRateLimitServesLastGoodUsageThenBacksOff() async {
        // live fetch 성공 후 429: 캐시된 바 + staleness note 유지, cooldown 동안 live 호출 skip
        let t0 = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let clock = TestClock(t0)
        let usageCalls = CallCounter()
        let httpClient = RoutingHTTPClient { request in
            guard request.url.absoluteString.hasSuffix("/api/oauth/usage") else {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data())
            }
            if usageCalls.next() == 1 {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { clock.now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { clock.now },
            pricing: { TestPricing.bundled }
        )

        // 1) live fetch 성공·캐시, warning 없음
        let first = await provider.refresh()
        XCTAssertEqual(Self.progress(first.lines, "Session")?.used, 25)
        XCTAssertNil(first.warning)

        // 2) 429: bare "Status" badge 대신 캐시된 Session 바 + staleness note, header warning 동반
        let second = await provider.refresh()
        XCTAssertEqual(Self.progress(second.lines, "Session")?.used, 25)
        XCTAssertEqual(text(second.lines, "Note")?.contains("rate limited"), true)
        XCTAssertNil(badge(second.lines, "Status"))
        XCTAssertEqual(second.warning?.hasPrefix("Updates blocked by Anthropic"), true)

        // 3) cooldown 내에는 live 호출 자체를 skip, 캐시된 바와 warning 유지
        clock.set(t0.addingTimeInterval(60))
        let third = await provider.refresh()
        XCTAssertEqual(Self.progress(third.lines, "Session")?.used, 25)
        XCTAssertEqual(third.warning?.hasPrefix("Updates blocked by Anthropic"), true)
        XCTAssertEqual(httpClient.requests.filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }.count, 2)
    }

    func testRefreshSurfacesRequestFailureForNonOAuthRefreshErrorBody() async {
        // refresh가 non-OAuth 400(HTML proxy/WAF 페이지)을 반환하면 "token expired"가 아닌 request failure로 보고
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"stale-token","refreshToken":"refresh-1","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 400, headers: [:], body: Data("<html>Bad Gateway</html>".utf8))
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(badge(snapshot.lines, "Error"), ProviderUsageErrorText.requestFailed(statusCode: 400))
        XCTAssertNotEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.tokenExpired.localizedDescription)
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }

    private func text(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .text(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }

    private static func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ value: Date) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
}
