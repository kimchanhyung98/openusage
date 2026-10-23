import Foundation

extension WidgetDataStore {
    func accountStatus(for providerID: String?, localState: AccountSignInProbe.State?) -> AccountStatus {
        switch localState {
        case .needsSignIn: return .signInNeeded()
        case .readFailed(let message):
            let knownStatus = refreshedAccountStatus(for: providerID)
            return knownStatus.canSwitch ? .refreshFailed(message) : knownStatus
        case .ready: break
        case nil:
            let knownStatus = refreshedAccountStatus(for: providerID)
            return knownStatus.canSwitch ? .checking : knownStatus
        }
        return refreshedAccountStatus(for: providerID)
    }

    private func refreshedAccountStatus(for providerID: String?) -> AccountStatus {
        guard let providerID else { return .notChecked }
        switch refreshResults[providerID] {
        case .failed(let failure):
            switch failure.authenticationIssue {
            case .sessionExpired: return .sessionExpired(failure.localizedMessage)
            case .signInNeeded: return .signInNeeded(failure.localizedMessage)
            case nil:
                switch failure.category {
                case .notLoggedIn, .authExpired, .authInvalid: return .signInNeeded(failure.localizedMessage)
                default: return .refreshFailed(failure.localizedMessage)
                }
            }
        case .succeeded:
            let snapshot = localSnapshots[providerID]
            switch snapshot?.authenticationIssue {
            case .sessionExpired: return .sessionExpired(snapshot?.localizedWarning ?? L10n.errors("Sign in again to restore usage."))
            case .signInNeeded: return .signInNeeded(snapshot?.localizedWarning)
            case nil:
                if let warning = snapshot?.localizedWarning { return .refreshFailed(warning) }
                return .ready
            }
        case nil:
            return refreshingProviderIDs.contains(providerID) ? .checking : .notChecked
        }
    }
}
