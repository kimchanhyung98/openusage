import Foundation

enum KimiAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case credentialsUnreadable
    case credentialsInvalid
    case unsupportedConfiguration
    case authExpired
    case refreshRejected
    case refreshResponseInvalid
    case credentialLockUnavailable
    case credentialLockCompromised
    case credentialSaveFailed

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Kimi. Run `kimi` to authenticate."
        case .credentialsUnreadable:
            "Kimi credentials could not be read. Check the credential file permissions."
        case .credentialsInvalid:
            "Kimi credentials are invalid. Run `kimi` to log in again."
        case .unsupportedConfiguration:
            "Custom Kimi API or OAuth hosts are not supported."
        case .authExpired, .refreshRejected:
            "Kimi session expired. Run `kimi` to log in again."
        case .refreshResponseInvalid:
            "Kimi returned an invalid token refresh response."
        case .credentialLockUnavailable:
            "Kimi credentials are busy. Try again shortly."
        case .credentialLockCompromised:
            "Kimi credential lock changed during refresh. Try again."
        case .credentialSaveFailed:
            "Refreshed Kimi credentials could not be saved."
        }
    }
}

enum KimiUsageError: Error, LocalizedError, Equatable {
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
            "Kimi quota data is unavailable for this account."
        }
    }
}
