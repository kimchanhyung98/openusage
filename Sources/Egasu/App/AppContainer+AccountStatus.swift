import Foundation

extension AppContainer {
    func accountStatus(for profile: AccountProfile, localState: AccountSignInProbe.State?) -> AccountStatus {
        let mapping = Dictionary(uniqueKeysWithValues: dataStore.knownProviderIDs.compactMap { cardID in
            accountProfileID(for: cardID).map { (cardID, $0) }
        })
        let cardID = AccountUsageCardPlanner.statusCardID(for: profile, profileIDsByCard: mapping)
        return dataStore.accountStatus(for: cardID, localState: localState)
    }

    /// 동일 provider 신원으로 재로그인한 경우도 새 credential 기준으로 해당 카드만 재확인.
    @discardableResult
    func refreshReauthenticatedAccounts(alreadyScheduledCardIDs: Set<String>) -> [String: Task<Void, Never>] {
        let revisions = accountProfiles.authenticationRevisionsByProfileID
        let changedIDs = Set(revisions.compactMap { profileID, revision in
            observedAuthenticationRevisions[profileID] != revision ? profileID : nil
        })
        observedAuthenticationRevisions = revisions
        var refreshes: [String: Task<Void, Never>] = [:]
        for cardID in dataStore.knownProviderIDs {
            guard let profileID = accountProfileID(for: cardID), changedIDs.contains(profileID) else { continue }
            dataStore.invalidateAuthentication(for: cardID)
            if enablement.isEnabled(cardID), !alreadyScheduledCardIDs.contains(cardID) {
                refreshes[cardID] = accountSwitch.startRefresh(providerID: cardID) {
                    await self.dataStore.refreshAfterAccountSelection(providerID: cardID)
                }
            }
        }
        return refreshes
    }

    static func externalClaudeReconciliationMessage(for error: Error) -> String {
        if let error = error as? AccountCredentialSwitcher.Error,
           error == .switchRecoveryRequired || error == .selectionSaveFailed || error == .conflictingClaudeAuthentication {
            return error.localizedDescription
        }
        return "OpenUsage couldn't update the selected Claude sign-in. The saved account was left unchanged. Check the app log and try again."
    }

    static func applyExternalClaudeReconciliationError(
        _ message: String?, to dataStore: WidgetDataStore,
        accountSwitch: AccountSwitchCoordinator, startedAt generation: Int
    ) {
        guard let message, !accountSwitch.isSwitching, accountSwitch.generation == generation else { return }
        dataStore.setExternalProviderError(message, for: "claude", presentation: .init(message))
    }
}
