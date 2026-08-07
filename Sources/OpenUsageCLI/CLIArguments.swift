import Foundation

struct CLIArguments: Equatable, Sendable {
    var providerID: String?
    var force = false
    var showHelp = false
    var showVersion = false
    var account: AccountCommand?

    static func parse(_ arguments: [String]) throws -> CLIArguments {
        // The `account` namespace is reserved: as the first token it switches grammars entirely.
        if arguments.first == "account" {
            return CLIArguments(account: try AccountCommand.parse(Array(arguments.dropFirst())))
        }
        var parsed = CLIArguments()
        for argument in arguments {
            switch argument {
            case "--force": parsed.force = true
            case "-h", "--help": parsed.showHelp = true
            case "-v", "--version": parsed.showVersion = true
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.usage("Unknown option: \(argument)")
                }
                guard parsed.providerID == nil else {
                    throw CLIError.usage("Only one provider can be requested at a time.")
                }
                parsed.providerID = argument.lowercased()
            }
        }
        return parsed
    }
}

enum CLIError: Error, Equatable {
    case usage(String)
    case appDefaultsUnavailable
}
