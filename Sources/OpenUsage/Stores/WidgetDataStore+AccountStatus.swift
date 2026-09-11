import Foundation

extension WidgetDataStore {
    func accountStatus(for providerID: String?, localState: AccountSignInProbe.State) -> AccountStatus {
        guard localState.isReady else { return .signInNeeded() }
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
