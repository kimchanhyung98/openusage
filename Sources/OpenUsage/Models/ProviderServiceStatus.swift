import Foundation

enum ServiceIssueSeverity: Int, Comparable, Sendable {
    case degraded
    case partial
    case major

    static func < (lhs: ServiceIssueSeverity, rhs: ServiceIssueSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var reportPhrase: String {
        switch self {
        case .degraded: "degraded performance"
        case .partial: "a partial outage"
        case .major: "a major outage"
        }
    }
}

struct ProviderServiceIssue: Equatable, Sendable {
    let severity: ServiceIssueSeverity
    let componentName: String
    let checkedAt: Date

    func accessibilityValue(providerName: String) -> String {
        "\(providerName) reports \(severity.reportPhrase) for \(componentName)."
    }
}

enum ProviderServiceStatus: Equatable, Sendable {
    case unknown
    case operational
    case disrupted(ProviderServiceIssue)

    var issue: ProviderServiceIssue? {
        guard case .disrupted(let issue) = self else { return nil }
        return issue
    }
}
