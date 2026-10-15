import Foundation

extension AccountCredentialImporter {
    enum IdentityReplacementRecoveryOutcome: Sendable {
        case completed
        case cancelledUnapplied
        case restorePreviousIdentity
    }

    /// 중단된 identity 교체 journal을 snapshot 기준으로 완결하거나 쓰기 전 상태로 폐기.
    @discardableResult
    func recoverInterruptedIdentityReplacement(
        in store: AccountProfilesStore, allowInteraction: Bool = false, preservingWorkspace: Bool = false
    ) throws -> Bool {
        guard !store.isAuthenticationMutationInProgress else { throw AccountAuthenticationMutationError.busy }
        guard let transaction = try store.pendingIdentityReplacement() else { return false }
        guard let profile = store.profile(id: transaction.profileID) else {
            try store.cancelIdentityReplacement(transaction)
            return false
        }
        return try AccountCredentialMutation.withLock {
            AccountCredentialMutationLock.acquire(family: profile.family)
            defer { AccountCredentialMutationLock.release(family: profile.family) }
            let savedSnapshot = try switcher.loadSnapshot(for: profile, allowInteraction: allowInteraction)
            let outcome = try applyIdentityReplacementRecovery(
                transaction, profile: profile, savedSnapshot: savedSnapshot,
                allowInteraction: allowInteraction, preservingWorkspace: preservingWorkspace
            )
            return try finishIdentityReplacementRecovery(outcome, transaction: transaction, in: store)
        }
    }

    nonisolated func applyIdentityReplacementRecovery(
        _ transaction: AccountIdentityReplacement, profile: AccountProfile,
        savedSnapshot: AccountCredentialVault.Entry?, allowInteraction: Bool,
        preservingWorkspace: Bool
    ) throws -> IdentityReplacementRecoveryOutcome {
        if let expected = transaction.replacementSnapshotDigest {
            guard let savedSnapshot, try savedSnapshot.snapshotDigest() == expected else {
                try verifyUnappliedIdentityReplacement(
                    transaction, profile: profile, savedSnapshot: savedSnapshot, allowInteraction: allowInteraction
                )
                return .cancelledUnapplied
            }
        } else if transaction.previousIdentityKey == transaction.replacementIdentityKey {
            try verifyUnappliedIdentityReplacement(
                transaction, profile: profile, savedSnapshot: savedSnapshot, allowInteraction: allowInteraction
            )
            return .cancelledUnapplied
        }
        guard let snapshot = savedSnapshot,
              switcher.identity(of: snapshot, family: profile.family)?.identityKey == transaction.replacementIdentityKey
        else {
            if transaction.replacesSharedAuthentication, let savedSnapshot {
                try switcher.applySharedAuthentication(savedSnapshot, family: profile.family)
                if !preservingWorkspace { try switcher.writeWorkspaceAuthentication(savedSnapshot, for: profile) }
            }
            return .restorePreviousIdentity
        }
        if !preservingWorkspace { try switcher.writeWorkspaceAuthentication(snapshot, for: profile) }
        if transaction.replacesSharedAuthentication {
            try switcher.applySharedAuthentication(snapshot, family: profile.family)
            guard let applied = try switcher.readSharedAuthentication(family: profile.family),
                  switcher.identity(of: applied, family: profile.family)?.identityKey == transaction.replacementIdentityKey
            else {
                throw ImportError.verificationFailed(family: profile.family)
            }
        }
        return .completed
    }

    func finishIdentityReplacementRecovery(
        _ outcome: IdentityReplacementRecoveryOutcome, transaction: AccountIdentityReplacement,
        in store: AccountProfilesStore
    ) throws -> Bool {
        switch outcome {
        case .completed:
            _ = try store.commitIdentityReplacement(transaction)
            AppLog.info(.auth, "recovered an interrupted account identity replacement")
            return true
        case .restorePreviousIdentity:
            if store.profile(id: transaction.profileID)?.identityKey != transaction.previousIdentityKey {
                _ = try store.replaceIdentity(profileID: transaction.profileID, with: transaction.previousIdentityKey)
            }
        case .cancelledUnapplied:
            break
        }
        try store.cancelIdentityReplacement(transaction)
        return false
    }

    struct ReconciliationFailure: Error, Sendable {
        var families: [String]
        let message = "OpenUsage couldn't finish updating the saved sign-in. Check the app log and try again."
    }

    /// 실패 후 남은 복구 기록으로 오류 대상 판별 — 기록이 없으면 외부 Claude 로그인 경로.
    func reconciliationFailure(
        for error: any Error, in store: AccountProfilesStore
    ) async -> ReconciliationFailure {
        do {
            if let transition = try await loadOffMainActor({ [switcher] in
                try switcher.switchJournal.load()
            }) {
                return ReconciliationFailure(families: [transition.family])
            }
            if let transaction = try store.pendingIdentityReplacement(),
               let profile = store.profile(id: transaction.profileID) {
                return ReconciliationFailure(families: [profile.family])
            }
            if case AccountIdentityReplacementError.invalidTransaction = error {
                return ReconciliationFailure(families: AccountProfilesStore.supportedFamilies)
            }
            return ReconciliationFailure(families: ["claude"])
        } catch {
            AppLog.error(.auth, "account recovery error scope could not be read: \(error.localizedDescription)")
            return ReconciliationFailure(families: AccountProfilesStore.supportedFamilies)
        }
    }

    nonisolated private func verifyUnappliedIdentityReplacement(
        _ transaction: AccountIdentityReplacement, profile: AccountProfile,
        savedSnapshot: AccountCredentialVault.Entry?, allowInteraction: Bool
    ) throws {
        if transaction.replacesSharedAuthentication {
            let artifacts = switcher.credentialArtifacts
            let current = try artifacts.capture(family: profile.family, allowInteraction: allowInteraction)
            if let originalDigest = transaction.originalSharedAuthenticationDigest,
               try artifacts.authenticationDigest(of: current) == originalDigest {
                return
            }
            guard let savedSnapshot,
                  switcher.identity(of: savedSnapshot, family: profile.family)?.identityKey
                    == transaction.previousIdentityKey else {
                throw AccountIdentityReplacementError.invalidTransaction
            }
            let restored = try artifacts.applying(savedSnapshot, to: current)
            guard try artifacts.matches(restored, allowInteraction: allowInteraction) else {
                AppLog.error(.auth, "account identity replacement has an incomplete shared-authentication rollback")
                throw AccountIdentityReplacementError.invalidTransaction
            }
        }
    }
}
