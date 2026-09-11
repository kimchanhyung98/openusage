import Foundation

extension AppContainer {
    func accountStatus(for profile: AccountProfile, localState: AccountSignInProbe.State) -> AccountStatus {
        let mapping = Dictionary(uniqueKeysWithValues: dataStore.knownProviderIDs.compactMap { cardID in
            accountProfileID(for: cardID).map { (cardID, $0) }
        })
        let cardID = AccountUsageCardPlanner.statusCardID(for: profile, profileIDsByCard: mapping)
        return dataStore.accountStatus(for: cardID, localState: localState)
    }

    /// 동일 provider 신원으로 재로그인한 경우도 새 credential 기준으로 해당 카드만 재확인.
    func refreshReauthenticatedAccounts(alreadyScheduledCardIDs: Set<String>) {
        let revisions = accountProfiles.authenticationRevisionsByProfileID
        let changedIDs = Set(revisions.compactMap { profileID, revision in
            observedAuthenticationRevisions[profileID] != revision ? profileID : nil
        })
        observedAuthenticationRevisions = revisions
        for cardID in dataStore.knownProviderIDs {
            guard let profileID = accountProfileID(for: cardID), changedIDs.contains(profileID) else { continue }
            dataStore.invalidateAuthentication(for: cardID)
            if enablement.isEnabled(cardID), !alreadyScheduledCardIDs.contains(cardID) {
                Task { await dataStore.refreshAfterAccountSelection(providerID: cardID) }
            }
        }
    }
}
