import Foundation
import OpenUsage

/// The `openusage account …` command grammar. The CLI is a read-only view of the registry —
/// adding, removing, re-signing, and switching accounts live in OpenUsage Settings, and a
/// confirmed switch applies to new terminal sessions automatically. Nothing here reads or copies
/// credentials, and no command starts a session from a Sign-In Workspace.
enum AccountCommand: Equatable, Sendable {
    case list(family: String?, json: Bool)
    case current(family: String?)

    static func parse(_ arguments: [String]) throws -> AccountCommand {
        guard let verb = arguments.first else {
            throw CLIError.usage("Missing account command. Expected one of: list, current.")
        }
        let rest = Array(arguments.dropFirst())
        switch verb {
        case "list":
            var family: String?
            var json = false
            for token in rest {
                if token == "--json" {
                    json = true
                } else if token.hasPrefix("-") {
                    throw CLIError.usage("Unknown option for account list: \(token)")
                } else {
                    guard family == nil else { throw CLIError.usage("Only one tool can be listed at a time.") }
                    family = try validateFamily(token)
                }
            }
            return .list(family: family, json: json)

        case "current":
            guard rest.count <= 1 else { throw CLIError.usage("Usage: openusage account current [claude|codex]") }
            return .current(family: try rest.first.map(validateFamily))

        default:
            throw CLIError.usage("Unknown account command: \(verb)")
        }
    }

    private static func validateFamily(_ token: String) throws -> String {
        let family = token.lowercased()
        guard AccountProfilesStore.isSupportedFamily(family) else {
            throw CLIError.usage("Unknown tool: \(token) (expected claude or codex)")
        }
        return family
    }
}
