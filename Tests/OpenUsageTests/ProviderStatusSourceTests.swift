import XCTest
@testable import OpenUsage

final class ProviderStatusSourceTests: XCTestCase {
    func testCatalogPinsOfficialComponentEndpointsAndRelevantComponents() throws {
        let expectations: [(
            family: String,
            endpoint: String,
            vocabulary: ComponentStatusVocabulary,
            selectors: [ProviderStatusComponentSelector]
        )] = [
            (
                "claude",
                "https://status.claude.com/api/v2/components.json",
                .atlassian,
                [
                    .init(id: "k8w3r06qmzrp", exactName: "Claude API (api.anthropic.com)"),
                    .init(id: "yyzkbfz2thpt", exactName: "Claude Code"),
                ]
            ),
            (
                "codex",
                "https://status.openai.com/api/v2/components.json",
                .incidentIO,
                [
                    .init(id: "01JVCV8YSWZFRSM1G5CVP253SK", exactName: "Codex Web"),
                    .init(id: "01KMKFAMWKNQ84Z1766MV08ZDE", exactName: "CLI"),
                ]
            ),
            (
                "cursor",
                "https://status.cursor.com/api/v2/components.json",
                .atlassian,
                [
                    .init(id: "rflc60xp5jp2", exactName: "IDE"),
                    .init(id: "jh0714rgjgt4", exactName: "cursor.com"),
                ]
            ),
            (
                "copilot",
                "https://www.githubstatus.com/api/v2/components.json",
                .atlassian,
                [.init(id: "pjmpxvq2cmr2", exactName: "Copilot")]
            ),
        ]

        XCTAssertEqual(ProviderStatusSourceCatalog.supportedFamilyIDs, Set(expectations.map(\.family)))
        for expectation in expectations {
            let source = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: expectation.family))
            XCTAssertEqual(source.familyID, expectation.family)
            XCTAssertEqual(source.endpointURL.absoluteString, expectation.endpoint)
            XCTAssertEqual(source.vocabulary, expectation.vocabulary)
            XCTAssertEqual(source.components, expectation.selectors)
        }
    }

    @MainActor
    func testCatalogExplicitlyCoversEveryProviderFamily() {
        let supported: Set<String> = ["claude", "codex", "copilot", "cursor"]
        let explicitlyUnsupported: Set<String> = [
            "antigravity", "devin", "grok", "kimi", "kiro", "opencode", "openrouter", "zai",
        ]
        let installed = Set(ProviderCatalog.make().map { ProviderAccountID.family(of: $0.provider.id) })

        XCTAssertEqual(ProviderStatusSourceCatalog.supportedFamilyIDs, supported)
        XCTAssertEqual(supported.union(explicitlyUnsupported), installed)
        XCTAssertTrue(supported.isDisjoint(with: explicitlyUnsupported))
    }

    func testClaudeRelevantOutageBecomesServiceIssue() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: Data(#"{"components":[{"id":"k8w3r06qmzrp","name":"Claude API (api.anthropic.com)","status":"partial_outage"},{"id":"yyzkbfz2thpt","name":"Claude Code","status":"operational"}]}"#.utf8)
        )

        let status = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "claude"))
            .decode(response, checkedAt: checkedAt)

        XCTAssertEqual(
            status,
            .disrupted(ProviderServiceIssue(
                severity: .partial,
                componentName: "Claude API (api.anthropic.com)",
                checkedAt: checkedAt
            ))
        )
    }

    func testIncidentIOFullOutageMapsToMajorSeverity() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let response = jsonResponse(
            #"{"components":[{"id":"01JVCV8YSWZFRSM1G5CVP253SK","name":"Codex Web","status":"operational"},{"id":"01KMKFAMWKNQ84Z1766MV08ZDE","name":"CLI","status":"full_outage"}]}"#
        )

        let status = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "codex@work"))
            .decode(response, checkedAt: checkedAt)

        XCTAssertEqual(
            status,
            .disrupted(ProviderServiceIssue(
                severity: .major,
                componentName: "CLI",
                checkedAt: checkedAt
            ))
        )
    }

    func testAtlassianOutageVocabularyMapsEveryDisplayedSeverity() throws {
        let source = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "copilot"))
        let cases: [(raw: String, severity: ServiceIssueSeverity)] = [
            ("degraded_performance", .degraded),
            ("partial_outage", .partial),
            ("major_outage", .major),
        ]

        for item in cases {
            let response = jsonResponse(
                #"{"components":[{"id":"pjmpxvq2cmr2","name":"Copilot","status":"\#(item.raw)"}]}"#
            )
            let status = try source.decode(response, checkedAt: .distantPast)

            XCTAssertEqual(status.issue?.severity, item.severity)
        }
    }

    func testWorstRelevantSeverityWins() throws {
        let response = jsonResponse(
            #"{"components":[{"id":"rflc60xp5jp2","name":"IDE","status":"degraded_performance"},{"id":"jh0714rgjgt4","name":"cursor.com","status":"major_outage"}]}"#
        )

        let status = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "cursor"))
            .decode(response, checkedAt: .distantPast)

        XCTAssertEqual(status.issue?.severity, .major)
        XCTAssertEqual(status.issue?.componentName, "cursor.com")
    }

    func testCatalogOrderBreaksTiesAtTheSameSeverity() throws {
        let response = jsonResponse(
            #"{"components":[{"id":"rflc60xp5jp2","name":"IDE","status":"partial_outage"},{"id":"jh0714rgjgt4","name":"cursor.com","status":"partial_outage"}]}"#
        )

        let status = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "cursor"))
            .decode(response, checkedAt: .distantPast)

        XCTAssertEqual(status.issue?.severity, .partial)
        XCTAssertEqual(status.issue?.componentName, "IDE")
    }

    func testUnrelatedOutageAndMalformedComponentAreIgnored() throws {
        let response = jsonResponse(
            #"{"components":[{"id":"other","name":"Unrelated","status":"major_outage"},{"id":17,"name":false},{"id":"pjmpxvq2cmr2","name":"Copilot","status":"operational"}]}"#
        )

        let status = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "copilot"))
            .decode(response, checkedAt: .distantPast)

        XCTAssertEqual(status, .operational)
    }

    func testRelevantComponentNameDriftFailsClosed() throws {
        let response = jsonResponse(
            #"{"components":[{"id":"pjmpxvq2cmr2","name":"Renamed Copilot","status":"major_outage"}]}"#
        )

        XCTAssertThrowsError(
            try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "copilot"))
                .decode(response, checkedAt: .distantPast)
        ) { error in
            XCTAssertEqual(error as? ProviderStatusSourceError, .scopeMismatch)
        }
    }

    func testMalformedUnknownMissingAndDuplicateRelevantComponentsFailClosed() throws {
        let source = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "copilot"))
        let cases: [(response: HTTPResponse, expected: ProviderStatusSourceError)] = [
            (jsonResponse(#"{"components":}"#), .invalidPayload),
            (
                jsonResponse(
                    #"{"components":[{"id":"pjmpxvq2cmr2","name":"Copilot","status":"mystery"}]}"#
                ),
                .scopeMismatch
            ),
            (jsonResponse(#"{"components":[]}"#), .scopeMismatch),
            (
                jsonResponse(
                    #"{"components":[{"id":"pjmpxvq2cmr2","name":"Copilot","status":"operational"},{"id":"pjmpxvq2cmr2","name":"Copilot","status":"major_outage"}]}"#
                ),
                .scopeMismatch
            ),
        ]

        for item in cases {
            XCTAssertThrowsError(try source.decode(item.response, checkedAt: .distantPast)) { error in
                XCTAssertEqual(error as? ProviderStatusSourceError, item.expected)
            }
        }
    }

    func testRelevantDisruptionWinsOverAnotherUnresolvedSelector() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let response = jsonResponse(
            #"{"components":[{"id":"k8w3r06qmzrp","name":"Claude API (api.anthropic.com)","status":"partial_outage"}]}"#
        )

        let status = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "claude"))
            .decode(response, checkedAt: checkedAt)

        XCTAssertEqual(status.issue?.componentName, "Claude API (api.anthropic.com)")
    }

    func testMaintenanceIsSuccessfulButDoesNotClaimOperational() throws {
        let response = jsonResponse(
            #"{"components":[{"id":"rflc60xp5jp2","name":"IDE","status":"under_maintenance"},{"id":"jh0714rgjgt4","name":"cursor.com","status":"operational"}]}"#
        )

        let status = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "cursor"))
            .decode(response, checkedAt: .distantPast)

        XCTAssertEqual(status, .unknown)
    }

    func testIncidentIOMaintenanceIsSuccessfulButDoesNotClaimOperational() throws {
        let response = jsonResponse(
            #"{"components":[{"id":"01JVCV8YSWZFRSM1G5CVP253SK","name":"Codex Web","status":"under_maintenance"},{"id":"01KMKFAMWKNQ84Z1766MV08ZDE","name":"CLI","status":"operational"}]}"#
        )

        let status = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "codex"))
            .decode(response, checkedAt: .distantPast)

        XCTAssertEqual(status, .unknown)
    }

    func testSourceRejectsUnsafeOrUntrustworthyResponses() throws {
        let source = try XCTUnwrap(ProviderStatusSourceCatalog.source(for: "copilot"))
        let validBody = Data(#"{"components":[]}"#.utf8)

        XCTAssertThrowsError(try source.decode(
            HTTPResponse(statusCode: 429, headers: ["retry-after": "120"], body: validBody),
            checkedAt: .distantPast
        )) { error in
            XCTAssertEqual(error as? ProviderStatusSourceError, .httpStatus(429, retryAfter: "120"))
        }
        XCTAssertThrowsError(try source.decode(
            HTTPResponse(statusCode: 200, headers: ["content-type": "text/html"], body: validBody),
            checkedAt: .distantPast
        )) { error in
            XCTAssertEqual(error as? ProviderStatusSourceError, .invalidContentType)
        }
        XCTAssertThrowsError(try source.decode(
            HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(repeating: 0, count: ProviderStatusSource.maximumBodySize + 1)
            ),
            checkedAt: .distantPast
        )) { error in
            XCTAssertEqual(error as? ProviderStatusSourceError, .bodyTooLarge)
        }
    }

    private func jsonResponse(_ json: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data(json.utf8)
        )
    }
}
