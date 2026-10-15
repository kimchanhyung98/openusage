import Foundation

extension AccountCredentialImporter {
    /// profile workspace에서 실행된 Sign In Again 완결 — 검증된 credential이 해당 이름의 현재 provider binding 교체.
    /// stable profile id·label·선택 상태 유지. 활성 profile이면 Shared Runtime Home도 같은 트랜잭션에서 갱신.
    @discardableResult
    func completeReSignIn(
        profileID: String,
        in store: AccountProfilesStore,
        isActive: Bool
    ) throws -> AccountProfile {
        guard !store.isAuthenticationMutationInProgress else { throw AccountAuthenticationMutationError.busy }
        guard let profile = store.profile(id: profileID) else {
            throw AccountProfileError.profileNotFound(profileID)
        }
        try validatePendingReSignIn(profileID: profileID, in: store)
        return try AccountCredentialMutation.withLock {
            AccountCredentialMutationLock.acquire(family: profile.family)
            defer { AccountCredentialMutationLock.release(family: profile.family) }
            let credential = try requireWorkspaceCredential(for: profile)
            let recoveredSwitch = try switcher.recoverInterruptedSwitch(in: store, allowInteraction: true)
            _ = try recoverInterruptedIdentityReplacement(
                in: store, allowInteraction: true, preservingWorkspace: true
            )
            let isActive = recoveredSwitch ? store.preferredProfileID(family: profile.family) == profile.id : isActive
            let preparation = try prepareReSignIn(profile: profile, credential: credential, isActive: isActive)
            let transaction = try beginPreparedReSignIn(preparation, in: store)
            do {
                try applyPreparedReSignIn(preparation)
            } catch {
                try cancelReSignInIfRestored(error, transaction: transaction, in: store)
                throw (error as? ReSignInApplyFailure)?.underlying ?? error
            }
            return try store.commitIdentityReplacement(transaction)
        }
    }

    struct ReSignInPreparation: Sendable {
        var profile: AccountProfile
        var credential: ImportedCredential
        var previousSnapshot: AccountCredentialVault.Entry?
        var previousShared: AccountCredentialArtifacts.Snapshot?
        var appliedShared: AccountCredentialArtifacts.Snapshot?
        var isActive: Bool
    }

    struct ReSignInApplyFailure: Error {
        var underlying: any Error
        var restored: Bool
    }

    func removeSignInWorkspaceAfterLogin(family: String, profileID: String) async throws {
        do {
            try await loadOffMainActor {
                try removeSignInWorkspace(family: family, profileID: profileID)
            }
        } catch {
            AppLog.error(.auth, "Sign-in workspace cleanup failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// 명시적 로그인 완료의 승인·적용·롤백 IO를 background에서 수행.
    func completeReSignInAfterLogin(profileID: String, in store: AccountProfilesStore) async throws -> AccountProfile {
        try Task.checkCancellation()
        let mutation = try store.beginAuthenticationMutation()
        defer { store.endAuthenticationMutation(mutation) }
        guard let profile = store.profile(id: profileID) else {
            throw AccountProfileError.profileNotFound(profileID)
        }
        try validatePendingReSignIn(profileID: profileID, in: store)
        let loginContext = store.authenticationContext()
        let credential = try await loadOffMainActor {
            try requireWorkspaceCredential(for: profile)
        }
        try Task.checkCancellation()
        try store.validateAuthenticationContext(loginContext)
        _ = try await switcher.recoverInterruptedSwitchAfterStartup(
            in: store, allowInteraction: true, mutation: mutation
        )
        _ = try await recoverIdentityReplacementInteractively(
            mutation: mutation, in: store, preservingWorkspace: true
        )
        try Task.checkCancellation()
        guard let profile = store.profile(id: profileID) else {
            throw AccountProfileError.profileNotFound(profileID)
        }
        let isActive = store.preferredProfileID(family: profile.family) == profile.id
        let context = store.authenticationContext()
        let preparation = try await loadOffMainActor {
            try prepareReSignIn(profile: profile, credential: credential, isActive: isActive)
        }
        try Task.checkCancellation()
        try store.validateAuthenticationContext(context)
        let transaction = try beginPreparedReSignIn(preparation, in: store)
        let applyingContext = store.authenticationContext()
        try store.beginApplyingAuthentication(mutation, context: applyingContext)
        do {
            try await loadOffMainActor { try applyPreparedReSignIn(preparation) }
        } catch {
            do {
                try store.finishAuthenticationMutation(mutation) {
                    try cancelReSignInIfRestored(error, transaction: transaction, in: store)
                }
            } catch {
                AppLog.error(.auth, "account re-sign-in journal cleanup failed: \(error.localizedDescription)")
            }
            throw (error as? ReSignInApplyFailure)?.underlying ?? error
        }
        return try store.finishAuthenticationMutation(mutation) {
            try store.validateAuthenticationContext(applyingContext)
            return try store.commitIdentityReplacement(transaction)
        }
    }

    func validatePendingReSignIn(profileID: String, in store: AccountProfilesStore) throws {
        if let transaction = try store.pendingIdentityReplacement(), transaction.profileID != profileID {
            throw AccountIdentityReplacementError.pendingTransaction
        }
    }

    nonisolated func requireWorkspaceCredential(for profile: AccountProfile) throws -> ImportedCredential {
        guard let credential = try readWorkspaceCredential(family: profile.family, profileID: profile.id) else {
            throw ImportError.noSignIn(family: profile.family)
        }
        return credential
    }

    nonisolated func prepareReSignIn(
        profile: AccountProfile, credential: ImportedCredential, isActive: Bool
    ) throws -> ReSignInPreparation {
        let previousShared = isActive ? try switcher.credentialArtifacts.capture(family: profile.family) : nil
        return try ReSignInPreparation(
            profile: profile, credential: credential,
            previousSnapshot: switcher.loadSnapshot(for: profile, allowInteraction: true),
            previousShared: previousShared,
            appliedShared: previousShared.map { try switcher.credentialArtifacts.applying(credential.entry, to: $0) },
            isActive: isActive
        )
    }

    func beginPreparedReSignIn(
        _ preparation: ReSignInPreparation, in store: AccountProfilesStore
    ) throws -> AccountIdentityReplacement {
        try store.beginIdentityReplacement(
            profileID: preparation.profile.id, with: preparation.credential.identityKey,
            replacesSharedAuthentication: preparation.isActive,
            replacementSnapshotDigest: preparation.credential.entry.snapshotDigest(),
            originalSharedAuthenticationDigest: preparation.previousShared.map {
                try switcher.credentialArtifacts.authenticationDigest(of: $0)
            }
        )
    }

    nonisolated func applyPreparedReSignIn(_ preparation: ReSignInPreparation) throws {
        try AccountCredentialMutation.withLock {
            let profile = preparation.profile
            AccountCredentialMutationLock.acquire(family: profile.family)
            defer { AccountCredentialMutationLock.release(family: profile.family) }
            guard try switcher.loadSnapshot(for: profile, allowInteraction: true) == preparation.previousSnapshot,
                  try readWorkspaceCredential(family: profile.family, profileID: profile.id)?.entry
                    == preparation.credential.entry else {
                throw AccountAuthenticationMutationError.changed
            }
            if let previousShared = preparation.previousShared {
                guard try switcher.credentialArtifacts.matches(previousShared) else {
                    throw AccountAuthenticationMutationError.changed
                }
            }
            var sharedApplyStarted = false
            do {
                try switcher.saveSnapshot(preparation.credential.entry, for: profile, allowInteraction: true)
                if preparation.isActive {
                    sharedApplyStarted = true
                    try switcher.applySharedAuthentication(preparation.credential.entry, family: profile.family)
                    guard let applied = try switcher.readSharedAuthentication(family: profile.family),
                          switcher.identity(of: applied, family: profile.family)?.identityKey
                            == preparation.credential.identityKey else {
                        throw ImportError.verificationFailed(family: profile.family)
                    }
                }
            } catch {
                let restored = rollbackCredentialTransaction(
                    profile: profile, previousSnapshot: preparation.previousSnapshot,
                    previousShared: sharedApplyStarted ? preparation.previousShared : nil,
                    appliedShared: sharedApplyStarted ? preparation.appliedShared : nil, allowInteraction: true,
                    context: "account re-sign-in"
                )
                throw ReSignInApplyFailure(underlying: error, restored: restored)
            }
        }
    }

    func cancelReSignInIfRestored(
        _ error: any Error, transaction: AccountIdentityReplacement, in store: AccountProfilesStore
    ) throws {
        if (error as? ReSignInApplyFailure)?.restored != false {
            try store.cancelIdentityReplacement(transaction)
        }
    }

    func recoverIdentityReplacementInteractively(
        mutation: UUID, in store: AccountProfilesStore, allowInteraction: Bool = true,
        preservingWorkspace: Bool = false
    ) async throws -> Bool {
        guard let transaction = try store.pendingIdentityReplacement() else { return false }
        guard let profile = store.profile(id: transaction.profileID) else {
            try store.cancelIdentityReplacement(transaction)
            return false
        }
        let context = store.authenticationContext()
        let preparation = try await loadOffMainActor {
            let snapshot = try switcher.loadSnapshot(for: profile, allowInteraction: allowInteraction)
            let shared = transaction.replacesSharedAuthentication
                ? try switcher.credentialArtifacts.capture(family: profile.family, allowInteraction: allowInteraction) : nil
            return (snapshot: snapshot, shared: shared)
        }
        try Task.checkCancellation()
        try store.beginApplyingAuthentication(mutation, context: context)
        let outcome = try await loadOffMainActor {
            try AccountCredentialMutation.withLock {
                AccountCredentialMutationLock.acquire(family: profile.family)
                defer { AccountCredentialMutationLock.release(family: profile.family) }
                guard try switcher.loadSnapshot(for: profile, allowInteraction: allowInteraction) == preparation.snapshot else {
                    throw AccountAuthenticationMutationError.changed
                }
                if let shared = preparation.shared {
                    guard try switcher.credentialArtifacts.matches(shared, allowInteraction: allowInteraction) else {
                        throw AccountAuthenticationMutationError.changed
                    }
                }
                return try applyIdentityReplacementRecovery(
                    transaction, profile: profile, savedSnapshot: preparation.snapshot,
                    allowInteraction: allowInteraction, preservingWorkspace: preservingWorkspace
                )
            }
        }
        return try store.finishAuthenticationMutation(mutation) {
            try store.validateAuthenticationContext(context)
            return try finishIdentityReplacementRecovery(outcome, transaction: transaction, in: store)
        }
    }
}
