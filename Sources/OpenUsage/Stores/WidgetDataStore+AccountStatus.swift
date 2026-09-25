import Foundation

extension WidgetDataStore {
    func accountStatus(for providerID: String?, localState: AccountSignInProbe.State?) -> AccountStatus {
        switch localState {
        case .needsSignIn: return .signInNeeded()
        case .readFailed(let message): return .refreshFailed(message)
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
            case .sessionExpired: return .sessionExpired(failure.message)
            case .signInNeeded: return .signInNeeded(failure.message)
            case nil:
                switch failure.category {
                case .notLoggedIn, .authExpired, .authInvalid: return .signInNeeded(failure.message)
                default: return .refreshFailed(failure.message)
                }
            }
        case .succeeded:
            let snapshot = localSnapshots[providerID]
            switch snapshot?.authenticationIssue {
            case .sessionExpired: return .sessionExpired(snapshot?.warning ?? "Sign in again to restore usage.")
            case .signInNeeded: return .signInNeeded(snapshot?.warning)
            case nil:
                if let warning = snapshot?.warning { return .refreshFailed(warning) }
                return .ready
            }
        case nil:
            return refreshingProviderIDs.contains(providerID) ? .checking : .notChecked
        }
    }
}
