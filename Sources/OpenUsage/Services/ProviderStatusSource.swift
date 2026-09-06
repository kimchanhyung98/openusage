import Foundation

enum ComponentStatusVocabulary: Equatable, Sendable {
    case atlassian
    case incidentIO

    fileprivate func decode(_ value: String) -> DecodedComponentStatus? {
        switch (self, value) {
        case (_, "operational"):
            .operational
        case (_, "under_maintenance"):
            .maintenance
        case (_, "degraded_performance"):
            .disrupted(.degraded)
        case (_, "partial_outage"):
            .disrupted(.partial)
        case (.atlassian, "major_outage"), (.incidentIO, "full_outage"):
            .disrupted(.major)
        default:
            nil
        }
    }
}

struct ProviderStatusComponentSelector: Equatable, Sendable {
    let id: String
    let exactName: String
}

struct ProviderStatusSource: Equatable, Sendable {
    static let maximumBodySize = 64 * 1024

    let familyID: String
    let endpointURL: URL
    let vocabulary: ComponentStatusVocabulary
    let components: [ProviderStatusComponentSelector]

    func decode(_ response: HTTPResponse, checkedAt: Date) throws -> ProviderServiceStatus {
        guard response.statusCode == 200 else {
            throw ProviderStatusSourceError.httpStatus(
                response.statusCode,
                retryAfter: response.header("retry-after")
            )
        }
        guard let contentType = response.header("content-type"),
              contentType.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "application/json"
        else {
            throw ProviderStatusSourceError.invalidContentType
        }
        guard response.body.count <= Self.maximumBodySize else {
            throw ProviderStatusSourceError.bodyTooLarge
        }

        let envelope: ProviderStatusWireEnvelope
        do {
            envelope = try JSONDecoder().decode(ProviderStatusWireEnvelope.self, from: response.body)
        } catch {
            throw ProviderStatusSourceError.invalidPayload
        }

        var bestIssue: (severity: ServiceIssueSeverity, componentName: String)?
        var hasMaintenance = false
        var hasUnresolvedSelector = false

        for selector in components {
            let matches = envelope.components.filter { $0.id == selector.id }
            guard matches.count == 1,
                  matches[0].name == selector.exactName,
                  let rawStatus = matches[0].status,
                  let componentStatus = vocabulary.decode(rawStatus)
            else {
                hasUnresolvedSelector = true
                continue
            }

            switch componentStatus {
            case .operational:
                break
            case .maintenance:
                hasMaintenance = true
            case .disrupted(let severity):
                if bestIssue == nil || severity > bestIssue!.severity {
                    bestIssue = (severity, selector.exactName)
                }
            }
        }

        if let bestIssue {
            return .disrupted(ProviderServiceIssue(
                severity: bestIssue.severity,
                componentName: bestIssue.componentName,
                checkedAt: checkedAt
            ))
        }
        if hasUnresolvedSelector {
            throw ProviderStatusSourceError.scopeMismatch
        }
        if hasMaintenance {
            return .unknown
        }
        return .operational
    }
}

enum ProviderStatusSourceCatalog {
    private static let sources: [String: ProviderStatusSource] = [
        "claude": ProviderStatusSource(
            familyID: "claude",
            endpointURL: URL(string: "https://status.claude.com/api/v2/components.json")!,
            vocabulary: .atlassian,
            components: [
                ProviderStatusComponentSelector(
                    id: "k8w3r06qmzrp",
                    exactName: "Claude API (api.anthropic.com)"
                ),
                ProviderStatusComponentSelector(id: "yyzkbfz2thpt", exactName: "Claude Code")
            ]
        ),
        "codex": ProviderStatusSource(
            familyID: "codex",
            endpointURL: URL(string: "https://status.openai.com/api/v2/components.json")!,
            vocabulary: .incidentIO,
            components: [
                ProviderStatusComponentSelector(
                    id: "01JVCV8YSWZFRSM1G5CVP253SK",
                    exactName: "Codex Web"
                ),
                ProviderStatusComponentSelector(
                    id: "01KMKFAMWKNQ84Z1766MV08ZDE",
                    exactName: "CLI"
                )
            ]
        ),
        "cursor": ProviderStatusSource(
            familyID: "cursor",
            endpointURL: URL(string: "https://status.cursor.com/api/v2/components.json")!,
            vocabulary: .atlassian,
            components: [
                ProviderStatusComponentSelector(id: "rflc60xp5jp2", exactName: "IDE"),
                ProviderStatusComponentSelector(id: "jh0714rgjgt4", exactName: "cursor.com")
            ]
        ),
        "copilot": ProviderStatusSource(
            familyID: "copilot",
            endpointURL: URL(string: "https://www.githubstatus.com/api/v2/components.json")!,
            vocabulary: .atlassian,
            components: [
                ProviderStatusComponentSelector(id: "pjmpxvq2cmr2", exactName: "Copilot")
            ]
        )
    ]

    static func source(for providerID: String) -> ProviderStatusSource? {
        sources[ProviderAccountID.family(of: providerID)]
    }

    static var supportedFamilyIDs: Set<String> {
        Set(sources.keys)
    }
}

enum ProviderStatusSourceError: Error, Equatable, Sendable {
    case httpStatus(Int, retryAfter: String?)
    case invalidContentType
    case bodyTooLarge
    case invalidPayload
    case scopeMismatch

    var category: String {
        switch self {
        case .httpStatus(let status, _): "http_\(status)"
        case .invalidContentType: "content_type"
        case .bodyTooLarge: "body_size"
        case .invalidPayload: "payload"
        case .scopeMismatch: "scope"
        }
    }
}

private enum DecodedComponentStatus {
    case operational
    case maintenance
    case disrupted(ServiceIssueSeverity)
}

private struct ProviderStatusWireEnvelope: Decodable {
    let components: [ProviderStatusWireComponent]
}

private struct ProviderStatusWireComponent: Decodable {
    let id: String?
    let name: String?
    let status: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil
            name = nil
            status = nil
            return
        }
        id = try? container.decode(String.self, forKey: .id)
        name = try? container.decode(String.self, forKey: .name)
        status = try? container.decode(String.self, forKey: .status)
    }
}
