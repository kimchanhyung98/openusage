import XCTest
@testable import OpenUsage

final class LocalUsageAPITests: XCTestCase {
    private func makeState() -> LocalUsageAPI.State {
        let refreshedAt = OpenUsageISO8601.date(from: "2026-03-26T11:16:29.000Z")!
        let claude = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            plan: "Pro",
            lines: [
                .progress(label: "Session", used: 42, limit: 100, format: .percent,
                          resetsAt: OpenUsageISO8601.date(from: "2026-03-26T13:00:00.161Z"),
                          periodDurationMs: 18_000_000),
                .values(label: "Today", values: [
                    MetricValue(number: 5.17, kind: .dollars),
                    MetricValue(number: 9_200_000, kind: .count, label: "tokens")
                ])
            ],
            refreshedAt: refreshedAt
        )
        let cursor = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.progress(label: "Requests", used: 12, limit: 500, format: .count(suffix: "requests"))],
            refreshedAt: refreshedAt
        )
        return LocalUsageAPI.State(
            enabledOrderedIDs: ["cursor", "claude"],          // 사용자 순서, devin 비활성
            knownIDs: ["claude", "cursor", "devin"],
            snapshots: ["claude": claude, "cursor": cursor]
        )
    }

    private func json(_ data: Data?) throws -> Any {
        try JSONSerialization.jsonObject(with: XCTUnwrap(data))
    }

    func testCollectionReturnsEnabledProvidersInUserOrder() throws {
        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: makeState())

        XCTAssertEqual(response.status, 200)
        let array = try XCTUnwrap(try json(response.body) as? [[String: Any]])
        XCTAssertEqual(array.map { $0["providerId"] as? String }, ["cursor", "claude"])
        XCTAssertEqual(array[1]["plan"] as? String, "Pro")
        XCTAssertEqual(array[1]["fetchedAt"] as? String, "2026-03-26T11:16:29.000Z")
    }

    func testWireShapeMatchesDocumentedFormat() throws {
        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/claude", state: makeState())

        XCTAssertEqual(response.status, 200)
        let array = try XCTUnwrap(try json(response.body) as? [[String: Any]])
        let object = try XCTUnwrap(array.first)
        XCTAssertEqual(array.count, 1)
        let lines = try XCTUnwrap(object["lines"] as? [[String: Any]])

        let progress = try XCTUnwrap(lines.first { $0["type"] as? String == "progress" })
        XCTAssertEqual(progress["used"] as? Double, 42)
        XCTAssertEqual((progress["format"] as? [String: Any])?["kind"] as? String, "percent")
        XCTAssertEqual(progress["resetsAt"] as? String, "2026-03-26T13:00:00.161Z")
        XCTAssertEqual(progress["periodDurationMs"] as? Int, 18_000_000)
        XCTAssertTrue(progress.keys.contains("color"))        // 원본과 동일한 explicit null

        let text = try XCTUnwrap(lines.first { $0["type"] as? String == "text" })
        XCTAssertEqual(text["value"] as? String, "$5.17 · 9.2M tokens")
        XCTAssertTrue(text.keys.contains("subtitle"))
    }

    func testCountFormatCarriesSuffix() throws {
        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/cursor", state: makeState())
        let object = try XCTUnwrap((try json(response.body) as? [[String: Any]])?.first)
        let line = try XCTUnwrap((object["lines"] as? [[String: Any]])?.first)

        XCTAssertEqual((line["format"] as? [String: Any])?["kind"] as? String, "count")
        XCTAssertEqual((line["format"] as? [String: Any])?["suffix"] as? String, "requests")
    }

    func testSingleTokenStatusCodes() throws {
        let state = makeState()

        // known이지만 미fetch → 빈 배열의 200 ("no data yet"은 요소 0개)
        let pending = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/devin", state: state)
        XCTAssertEqual(pending.status, 200)
        XCTAssertEqual(try XCTUnwrap(try json(pending.body) as? [Any]).count, 0)

        // 어떤 card·family도 지칭하지 않는 token → 404 provider_not_found
        let unknown = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/nope", state: state)
        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual((try json(unknown.body) as? [String: Any])?["error"] as? String, "provider_not_found")

        let unknownLimits = LocalUsageAPI.respond(method: "GET", path: "/v1/limits/nope", state: state)
        XCTAssertEqual(unknownLimits.status, 404)
    }

    func testFamilyTokenMatchesEveryCardOfTheFamily() throws {
        // 매칭은 단순 문자열 비교 — 정확한 card id 또는 family id로 해당 family 전체 지칭
        var state = makeState()
        let refreshedAt = OpenUsageISO8601.date(from: "2026-03-26T11:16:29.000Z")!
        state.knownIDs.insert("claude@ab12cd34")
        state.snapshots["claude@ab12cd34"] = ProviderSnapshot(
            providerID: "claude@ab12cd34",
            displayName: "Claude",
            lines: [.progress(label: "Session", used: 7, limit: 100, format: .percent)],
            refreshedAt: refreshedAt
        )

        let family = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/claude", state: state)
        XCTAssertEqual(family.status, 200)
        let matched = try XCTUnwrap(try json(family.body) as? [[String: Any]])
        XCTAssertEqual(matched.compactMap { $0["providerId"] as? String }, ["claude", "claude@ab12cd34"])

        // 정확한 card id는 해당 card만 지칭
        let exact = LocalUsageAPI.respond(method: "GET", path: "/v1/usage/claude@ab12cd34", state: state)
        let single = try XCTUnwrap(try json(exact.body) as? [[String: Any]])
        XCTAssertEqual(single.compactMap { $0["providerId"] as? String }, ["claude@ab12cd34"])

        // limits envelope는 card id로 key — family token도 매칭 card 전부 포함
        let limits = LocalUsageAPI.respond(method: "GET", path: "/v1/limits/claude", state: state)
        XCTAssertEqual(limits.status, 200)
        let envelope = try XCTUnwrap(try json(limits.body) as? [String: Any])
        let providers = try XCTUnwrap(envelope["providers"] as? [String: Any])
        XCTAssertEqual(Set(providers.keys), ["claude", "claude@ab12cd34"])
    }

    @MainActor
    func testAccountNamesNeverReachTheBrowserReadableWire() throws {
        var state = makeState()
        // bare 카드는 조직명이 snapshot에 구워진 상태, extra 카드는 boundary에서 이메일 label로 해석되는 상태
        state.snapshots["claude"]?.displayName = "Claude — Acme Industries"
        state.knownIDs.insert("claude@ab12cd34")
        state.enabledOrderedIDs.append("claude@ab12cd34")
        state.snapshots["claude@ab12cd34"] = ProviderSnapshot(
            providerID: "claude@ab12cd34",
            displayName: "Claude",
            lines: [.progress(label: "Session", used: 7, limit: 100, format: .percent)],
            refreshedAt: OpenUsageISO8601.date(from: "2026-03-26T11:16:29.000Z")!
        )
        let resolved = state.resolvingDisplayNames(["claude@ab12cd34": "Claude — acme@example.com"])
        let server = LocalUsageServer(state: { resolved })

        let usage = server.route(head: "GET /v1/usage HTTP/1.1\r\nHost: localhost\r\n")
        let array = try XCTUnwrap(try json(usage.body) as? [[String: Any]])
        XCTAssertEqual(array.first { $0["providerId"] as? String == "claude" }?["displayName"] as? String, "Claude")
        XCTAssertEqual(array.first { $0["providerId"] as? String == "claude@ab12cd34" }?["displayName"] as? String, "Claude")
        XCTAssertEqual(
            array.first { $0["providerId"] as? String == "cursor" }?["displayName"] as? String,
            "Cursor",
            "providers without accounts keep their own name"
        )

        let limits = server.route(head: "GET /v1/limits HTTP/1.1\r\nHost: localhost\r\n")
        let envelope = try XCTUnwrap(try json(limits.body) as? [String: Any])
        let providers = try XCTUnwrap(envelope["providers"] as? [String: Any])
        XCTAssertEqual((providers["claude"] as? [String: Any])?["displayName"] as? String, "Claude")
        XCTAssertEqual((providers["claude@ab12cd34"] as? [String: Any])?["displayName"] as? String, "Claude")

        let familyUsage = server.route(head: "GET /v1/usage/claude HTTP/1.1\r\nHost: localhost\r\n")
        let familyArray = try XCTUnwrap(try json(familyUsage.body) as? [[String: Any]])
        XCTAssertEqual(familyArray.compactMap { $0["displayName"] as? String }, ["Claude", "Claude"])

        let familyLimits = server.route(head: "GET /v1/limits/claude HTTP/1.1\r\nHost: localhost\r\n")
        let familyEnvelope = try XCTUnwrap(try json(familyLimits.body) as? [String: Any])
        let familyProviders = try XCTUnwrap(familyEnvelope["providers"] as? [String: Any])
        XCTAssertEqual((familyProviders["claude"] as? [String: Any])?["displayName"] as? String, "Claude")
        XCTAssertEqual((familyProviders["claude@ab12cd34"] as? [String: Any])?["displayName"] as? String, "Claude")

        for body in [usage.body, limits.body, familyUsage.body, familyLimits.body] {
            let text = String(decoding: try XCTUnwrap(body), as: UTF8.self)
            XCTAssertFalse(text.contains("acme@example.com"), "account email reached the wire")
            XCTAssertFalse(text.contains("Acme Industries"), "organization name reached the wire")
        }
    }

    func testMethodAndRouteErrors() throws {
        let state = makeState()

        let post = LocalUsageAPI.respond(method: "POST", path: "/v1/usage", state: state)
        XCTAssertEqual(post.status, 405)
        XCTAssertEqual((try json(post.body) as? [String: Any])?["error"] as? String, "method_not_allowed")

        let preflight = LocalUsageAPI.respond(method: "OPTIONS", path: "/v1/usage", state: state)
        XCTAssertEqual(preflight.status, 204)

        let unknownRoute = LocalUsageAPI.respond(method: "GET", path: "/v2/everything", state: state)
        XCTAssertEqual(unknownRoute.status, 404)
        XCTAssertEqual((try json(unknownRoute.body) as? [String: Any])?["error"] as? String, "not_found")
    }
}

final class LocalUsageServerRequestLineTests: XCTestCase {
    func testParsesWellFormedRequestLine() {
        let (method, path) = LocalUsageServer.parseRequestLine("GET /v1/usage HTTP/1.1\r\nHost: localhost\r\n")
        XCTAssertEqual(method, "GET")
        XCTAssertEqual(path, "/v1/usage")
    }

    func testEmptyHeadDegradesToDefaultsInsteadOfCrashing() {
        // 빈 head에서 `head.split(...)[0]` force-index가 process를 trap시키던 회귀 방지 — ("", "/")로 degrade해 404 유도
        let (method, path) = LocalUsageServer.parseRequestLine("")
        XCTAssertEqual(method, "")
        XCTAssertEqual(path, "/")
    }

    func testRequestLineWithoutPathDefaultsPath() {
        let (method, path) = LocalUsageServer.parseRequestLine("GET\r\n")
        XCTAssertEqual(method, "GET")
        XCTAssertEqual(path, "/")
    }
}
