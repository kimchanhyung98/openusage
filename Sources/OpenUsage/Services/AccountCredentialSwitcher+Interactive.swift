import Foundation

extension AccountCredentialSwitcher {
    struct SwitchPreparation: Sendable {
        var targetProfile: AccountProfile
        var target: AccountCredentialVault.Entry
        var shared: AccountCredentialVault.Entry?
        var preservedProfile: AccountProfile?
        var previousPreservedSnapshot: AccountCredentialVault.Entry?
        var transition: AccountSwitchTransition
    }

    /// 승인 대기는 background에서 수행, 인증 적용 시작 뒤에는 선택 확정까지 완결.
    @MainActor
    func switchAuthentication(to selected: AccountProfile, in store: AccountProfilesStore) async throws {
        try Task.checkCancellation()
        let mutation = try store.beginAuthenticationMutation()
        defer { store.endAuthenticationMutation(mutation) }
        guard let initialTarget = store.profile(id: selected.id),
              initialTarget.family == selected.family,
              initialTarget.identityKey == selected.identityKey else {
            throw AccountAuthenticationMutationError.changed
        }
        let current = store.preferredProfile(family: initialTarget.family)
        guard current?.id != initialTarget.id else { return }
        _ = try await recoverInterruptedSwitchAfterStartup(
            in: store, allowInteraction: true, mutation: mutation
        )
        try Task.checkCancellation()
        guard try store.pendingIdentityReplacement() == nil else {
            throw AccountIdentityReplacementError.pendingTransaction
        }
        guard let target = store.profile(id: selected.id),
              target.family == selected.family, target.identityKey == selected.identityKey else {
            throw AccountAuthenticationMutationError.changed
        }
        let recoveredCurrent = store.preferredProfile(family: target.family)
        guard recoveredCurrent?.id != target.id else { return }
        let context = store.authenticationContext()
        let preparation = try await loadOffMainActor {
            try prepareSwitch(to: target, from: recoveredCurrent)
        }
        try Task.checkCancellation()
        try store.beginApplyingAuthentication(mutation, context: context)
        try await loadOffMainActor {
            try applyPreparedSwitch(preparation, recordsTransition: true)
        }
        try store.finishAuthenticationMutation(mutation) {
            try store.validateAuthenticationContext(context)
            try store.setPreferredChecked(
                family: target.family, profileID: target.id, expectedIdentityKey: target.identityKey
            )
        }
        try await loadOffMainActor {
            clearCommittedSwitch(
                preparation.transition, target: preparation.target, profile: target, allowInteraction: true
            )
        }
    }

    func prepareSwitch(to selected: AccountProfile, from current: AccountProfile?) throws -> SwitchPreparation {
        guard AccountProfilesStore.isSupportedFamily(selected.family) else {
            throw Error.unsupportedFamily(selected.family)
        }
        let target: AccountCredentialVault.Entry
        do {
            guard let snapshot = try loadSnapshot(for: selected, allowInteraction: true) else {
                throw Error.missingSnapshot(selected.label)
            }
            target = snapshot
        } catch AccountCredentialVaultError.missingEntry {
            throw Error.missingSnapshot(selected.label)
        }
        guard identity(of: target, family: selected.family)?.identityKey == selected.identityKey else {
            throw Error.snapshotIdentityMismatch(selected.label)
        }
        let shared = try readSharedAuthentication(family: selected.family)
        let preservedProfile = current.flatMap { profile -> AccountProfile? in
            guard profile.family == selected.family, let shared,
                  identity(of: shared, family: profile.family)?.identityKey == profile.identityKey else { return nil }
            return profile
        }
        let previousPreservedSnapshot = try preservedProfile.flatMap {
            try loadSnapshot(for: $0, allowInteraction: true)
        }
        let original = try credentialArtifacts.capture(family: selected.family, allowInteraction: true)
        let applied = try credentialArtifacts.applying(target, to: original)
        let transition = AccountSwitchTransition(
            family: selected.family, previousProfileID: current?.id,
            targetProfileID: selected.id, targetIdentityKey: selected.identityKey,
            targetSnapshotDigest: try target.snapshotDigest(), original: original, applied: applied
        )
        return SwitchPreparation(
            targetProfile: selected, target: target, shared: shared,
            preservedProfile: preservedProfile, previousPreservedSnapshot: previousPreservedSnapshot,
            transition: transition
        )
    }

    func applyPreparedSwitch(_ preparation: SwitchPreparation, recordsTransition: Bool = false) throws {
        try AccountCredentialMutation.withLock {
            let selected = preparation.targetProfile
            let transition = preparation.transition
            let artifacts = credentialArtifacts
            AccountCredentialMutationLock.acquire(family: selected.family)
            defer { AccountCredentialMutationLock.release(family: selected.family) }
            if recordsTransition {
                guard try switchJournal.load(allowInteraction: true) == nil else {
                    throw Error.switchRecoveryFailed
                }
            }
            guard try loadSnapshot(for: selected, allowInteraction: true) == preparation.target,
                  try readSharedAuthentication(family: selected.family) == preparation.shared,
                  try artifacts.matches(transition.original, allowInteraction: true) else {
                throw AccountAuthenticationMutationError.changed
            }
            if let current = preparation.preservedProfile {
                guard try loadSnapshot(for: current, allowInteraction: true)
                        == preparation.previousPreservedSnapshot else {
                    throw AccountAuthenticationMutationError.changed
                }
            }
            if let current = preparation.preservedProfile, let active = preparation.shared {
                var preserved = active
                if current.family == "codex",
                   let snapshot = preparation.previousPreservedSnapshot,
                   snapshot.codexStaleSharedCredentialFingerprints?.contains(CodexAuthStore.credentialFingerprint(active.credential)) == true,
                   identity(of: snapshot, family: current.family)?.identityKey == current.identityKey {
                    preserved = snapshot
                }
                try saveSnapshot(preserved, for: current, allowInteraction: true)
                try writeWorkspaceAuthentication(preserved, for: current)
            }
            guard try artifacts.matches(transition.original, allowInteraction: true) else {
                throw Error.sharedAuthenticationChanged
            }
            if recordsTransition {
                try switchJournal.save(transition, allowInteraction: true)
            }
            do {
                guard try artifacts.matches(transition.original, allowInteraction: true) else {
                    throw Error.sharedAuthenticationChanged
                }
                try applySharedAuthentication(preparation.target, family: selected.family)
                guard try artifacts.matches(transition.applied, allowInteraction: true) else {
                    throw Error.switchVerificationFailed(selected.label)
                }
                if !recordsTransition {
                    try clearSynchronizedCodexSnapshot(preparation.target, for: selected, allowInteraction: true)
                }
            } catch {
                do {
                    try artifacts.restore(transition.original, replacing: transition.applied, allowInteraction: true)
                    if recordsTransition {
                        try switchJournal.clear(transition, allowInteraction: true)
                    }
                } catch {
                    AppLog.error(.auth, "account switch rollback failed; recovery record retained: \(error.localizedDescription)")
                }
                throw error
            }
        }
    }
}
