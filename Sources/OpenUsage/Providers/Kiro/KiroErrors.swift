import Foundation

enum KiroAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case credentialsUnreadable
    case credentialsInvalid
    case missingProfile
    case authExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Kiro. Run `kiro-cli login` and try again."
        case .credentialsUnreadable:
            "Kiro credentials could not be read. Check the CLI database permissions."
        case .credentialsInvalid:
            "Kiro credentials are invalid. Run `kiro-cli login` and try again."
        case .missingProfile:
            "Kiro profile is unavailable. Run `kiro-cli login` and try again."
        case .authExpired:
            "Kiro session expired. Run `kiro-cli login` and try again."
        }
    }
}

enum KiroUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case requestFailed(Int)
    case invalidResponse
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            ProviderUsageErrorText.connectionFailed
        case .requestFailed(let status):
            ProviderUsageErrorText.requestFailed(statusCode: status)
        case .invalidResponse:
            ProviderUsageErrorText.invalidResponse
        case .quotaUnavailable:
            "Kiro credit usage is unavailable for this account."
        }
    }
}
