import Foundation

extension AccountCredentialSwitcher {
    /// 동기 caller도 같은 전환 기록 사용 — 선택 저장 실패 후 적용 인증·기록 보존.
    @MainActor
    func switchAuthentication(to selected: AccountProfile, in store: AccountProfilesStore) throws {
        guard store.preferredProfileID(family: selected.family) != selected.id else { return }
        _ = try recoverInterruptedSwitch(in: store, allowInteraction: true)
        let mutation = try store.beginAuthenticationMutation()
        defer { store.endAuthenticationMutation(mutation) }
        guard try store.pendingIdentityReplacement() == nil else {
            throw AccountIdentityReplacementError.pendingTransaction
        }
        guard let profile = store.profile(id: selected.id),
              profile.family == selected.family, profile.identityKey == selected.identityKey else {
            throw Error.snapshotIdentityMismatch(selected.label)
        }
        let current = store.preferredProfile(family: selected.family)
        guard current?.id != selected.id else { return }
        let context = store.authenticationContext()
        let preparation = try prepareSwitch(to: profile, from: current)
        try store.beginApplyingAuthentication(mutation, context: context)
        try applyPreparedSwitch(preparation, recordsTransition: true)
        try store.finishAuthenticationMutation(mutation) {
            try store.validateAuthenticationContext(context)
            try store.setPreferredChecked(
                family: selected.family, profileID: selected.id, expectedIdentityKey: selected.identityKey
            )
        }
        clearCommittedSwitch(preparation.transition, target: preparation.target, profile: profile)
    }

    /// 선택 저장을 소유하지 않는 인증 적용 경로 — 실패 시 usable 인증 유무와 무관하게 raw 원본 복원.
    func switchAuthentication(to selected: AccountProfile, from current: AccountProfile?) throws {
        guard AccountProfilesStore.isSupportedFamily(selected.family) else {
            throw Error.unsupportedFamily(selected.family)
        }
        guard current?.id != selected.id else { return }
        AccountCredentialMutationLock.acquire(family: selected.family)
        defer { AccountCredentialMutationLock.release(family: selected.family) }
        let preparation = try prepareSwitch(to: selected, from: current)
        try applyPreparedSwitch(preparation)
    }

    /// 선택 저장 뒤 같은 인증 세대의 동기화 표시만 정리 — 복구 중 새로 회전된 snapshot은 보존.
    func clearSynchronizedCodexSnapshot(
        _ target: AccountCredentialVault.Entry, for profile: AccountProfile, allowInteraction: Bool = true
    ) throws {
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        guard profile.family == "codex", target.codexStaleSharedCredentialFingerprints != nil,
              try loadSnapshot(for: profile, allowInteraction: allowInteraction) == target,
              let shared = try readSharedAuthentication(family: profile.family),
              shared.credential.utf8.elementsEqual(target.credential.utf8) else { return }
        var synchronized = target
        synchronized.codexStaleSharedCredentialFingerprints = nil
        try saveSnapshot(synchronized, for: profile, allowInteraction: allowInteraction)
    }

    func clearCommittedSwitch(
        _ transaction: AccountSwitchTransition, target: AccountCredentialVault.Entry, profile: AccountProfile,
        allowInteraction: Bool = true
    ) {
        do {
            try clearSynchronizedCodexSnapshot(target, for: profile, allowInteraction: allowInteraction)
            try switchJournal.clear(transaction, allowInteraction: allowInteraction)
        } catch {
            AppLog.error(.auth, "account switch succeeded but recovery record cleanup failed: \(error.localizedDescription)")
        }
    }
}
