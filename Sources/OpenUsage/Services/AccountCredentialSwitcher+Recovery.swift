import Foundation

extension AccountCredentialSwitcher {
    @MainActor private static var isRecoveringSwitch = false

    func hasPendingSwitch() throws -> Bool {
        try switchJournal.hasPending()
    }

    /// shared 인증의 원본·목표로 증명되는 중단만 복구 — 외부 로그인·다른 선택은 보존.
    @MainActor
    @discardableResult
    func recoverInterruptedSwitch(
        in store: AccountProfilesStore, allowInteraction: Bool = false
    ) throws -> Bool {
        guard !store.isAuthenticationMutationInProgress else { throw AccountAuthenticationMutationError.busy }
        guard !Self.isRecoveringSwitch else { throw AccountSwitchJournal.Error.pendingTransition }
        Self.isRecoveringSwitch = true
        defer { Self.isRecoveringSwitch = false }
        guard try hasPendingSwitch() else { return false }
        let context = try SwitchRecoveryContext(store: store)
        guard let plan = try prepareSwitchRecovery(context, allowInteraction: allowInteraction) else { return false }
        AccountCredentialMutationLock.acquire(family: plan.transaction.family)
        defer { AccountCredentialMutationLock.release(family: plan.transaction.family) }
        _ = try performSwitchRecovery(plan, allowInteraction: allowInteraction)
        try commitSwitchRecovery(plan, in: store)
        try finishSwitchRecovery(plan, allowInteraction: allowInteraction)
        return plan.changesAuthentication
    }

    /// 시작 시 secret·파일 접근은 background 실행 — 각 대기 뒤 선택·binding 세대 재검증.
    @MainActor
    @discardableResult
    func recoverInterruptedSwitchAfterStartup(
        in store: AccountProfilesStore, allowInteraction: Bool = false, mutation: UUID? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()
        if mutation == nil, store.isAuthenticationMutationInProgress { return false }
        guard try await loadOffMainActor({ try hasPendingSwitch() }) else { return false }
        try Task.checkCancellation()
        if mutation == nil, store.isAuthenticationMutationInProgress { return false }
        guard !Self.isRecoveringSwitch else { throw AccountSwitchJournal.Error.pendingTransition }
        Self.isRecoveringSwitch = true
        defer { Self.isRecoveringSwitch = false }
        let token = try mutation ?? store.beginAuthenticationMutation()
        defer { if mutation == nil { store.endAuthenticationMutation(token, notifyRefresh: false) } }
        let context = try SwitchRecoveryContext(store: store)
        let authenticationContext = store.authenticationContext()
        let prepared = try await loadOffMainActor {
            try prepareSwitchRecovery(context, allowInteraction: allowInteraction)
        }
        try Task.checkCancellation()
        try context.validate(in: store)
        guard let plan = prepared else { return false }
        try store.beginApplyingAuthentication(token, context: authenticationContext)
        let codexRevision = try await loadOffMainActor {
            try performSwitchRecovery(plan, allowInteraction: allowInteraction)
        }
        try store.finishAuthenticationMutation(token) {
            try context.validate(in: store)
            try store.validateAuthenticationContext(authenticationContext)
            if let codexRevision {
                guard try AccountCredentialMutationLock.withUnchangedRevisionIfAvailable(codexRevision, {
                    try commitSwitchRecovery(plan, in: store)
                }) else { throw Error.switchRecoveryFailed }
            } else {
                try commitSwitchRecovery(plan, in: store)
            }
        }
        try await loadOffMainActor {
            try finishSwitchRecovery(plan, allowInteraction: allowInteraction)
        }
        return plan.changesAuthentication
    }

    private struct SwitchRecoveryContext: Sendable {
        struct Binding: Equatable, Sendable {
            var family: String
            var identityKey: String
        }

        var revision: Int
        var profiles: [AccountProfile]
        var preferred: [String: String]

        @MainActor
        init(store: AccountProfilesStore) throws {
            guard !store.hasUnreadableRegistry else { throw AccountProfileError.registryUnreadable }
            revision = store.authenticationRevision
            profiles = store.profiles.filter { !$0.isArchived }
            preferred = Dictionary(uniqueKeysWithValues: AccountProfilesStore.supportedFamilies.compactMap { family in
                store.preferredProfileID(family: family).map { (family, $0) }
            })
        }

        private var bindings: [String: Binding] {
            Dictionary(uniqueKeysWithValues: profiles.map {
                ($0.id, Binding(family: $0.family, identityKey: $0.identityKey))
            })
        }

        @MainActor
        func validate(in store: AccountProfilesStore) throws {
            let current = try Self(store: store)
            guard current.revision == revision, current.preferred == preferred, current.bindings == bindings else {
                throw Error.switchRecoveryFailed
            }
        }
    }

    private struct SwitchRecoveryPlan: Sendable {
        enum Action: Sendable {
            case committed
            case cancel
            case restore
            case apply(AccountProfile, AccountCredentialVault.Entry)
        }

        var transaction: AccountSwitchTransition
        var observed: AccountCredentialArtifacts.Snapshot?
        var action: Action

        var changesAuthentication: Bool {
            switch action {
            case .committed, .cancel: false
            case .restore, .apply: true
            }
        }
    }

    private func prepareSwitchRecovery(
        _ context: SwitchRecoveryContext, allowInteraction: Bool
    ) throws -> SwitchRecoveryPlan? {
        guard let transaction = try switchJournal.load(allowInteraction: allowInteraction) else { return nil }
        AccountCredentialMutationLock.acquire(family: transaction.family)
        defer { AccountCredentialMutationLock.release(family: transaction.family) }
        let selectedID = context.preferred[transaction.family]
        if selectedID == transaction.targetProfileID {
            return SwitchRecoveryPlan(transaction: transaction, action: .committed)
        }
        let artifacts = credentialArtifacts
        guard selectedID == transaction.previousProfileID,
              try artifacts.canRestore(transaction.original, replacing: transaction.applied,
                                       allowInteraction: allowInteraction) else { throw Error.switchRecoveryFailed }
        let observed = try artifacts.capture(family: transaction.family, allowInteraction: allowInteraction)
        if try artifacts.matches(transaction.original, allowInteraction: allowInteraction) {
            return SwitchRecoveryPlan(transaction: transaction, observed: observed, action: .cancel)
        }
        guard let profile = context.profiles.first(where: {
            $0.id == transaction.targetProfileID && $0.family == transaction.family
                && $0.identityKey == transaction.targetIdentityKey
        }), let entry = try recoveryTarget(for: transaction, profile: profile, allowInteraction: allowInteraction) else {
            return SwitchRecoveryPlan(transaction: transaction, observed: observed, action: .restore)
        }
        return SwitchRecoveryPlan(transaction: transaction, observed: observed, action: .apply(profile, entry))
    }

    private func performSwitchRecovery(_ plan: SwitchRecoveryPlan, allowInteraction: Bool) throws -> UInt64? {
        try AccountCredentialMutation.withLock {
            let transaction = plan.transaction
            AccountCredentialMutationLock.acquire(family: transaction.family)
            defer { AccountCredentialMutationLock.release(family: transaction.family) }
            guard try switchJournal.load(allowInteraction: allowInteraction) == transaction else {
                throw AccountSwitchJournal.Error.recordChanged
            }
            if case .committed = plan.action { return nil }
            if case .apply(let profile, let expected) = plan.action {
                guard try recoveryTarget(for: transaction, profile: profile, allowInteraction: allowInteraction) == expected else {
                    throw Error.switchRecoveryFailed
                }
            }
            let artifacts = credentialArtifacts
            guard let observed = plan.observed,
                  try artifacts.matches(observed, allowInteraction: allowInteraction),
                  try artifacts.canRestore(transaction.original, replacing: transaction.applied,
                                           allowInteraction: allowInteraction) else { throw Error.switchRecoveryFailed }
            switch plan.action {
            case .committed:
                break
            case .cancel:
                guard try artifacts.matches(transaction.original, allowInteraction: allowInteraction) else {
                    throw Error.switchRecoveryFailed
                }
            case .restore:
                try artifacts.restore(transaction.original, replacing: transaction.applied, allowInteraction: allowInteraction)
            case .apply(_, let entry):
                try applySharedAuthentication(entry, family: transaction.family)
                guard try artifacts.matches(transaction.applied, allowInteraction: allowInteraction) else {
                    throw Error.switchRecoveryFailed
                }
            }
            return transaction.family == "codex" ? AccountCredentialMutationLock.revision : nil
        }
    }

    @MainActor
    private func commitSwitchRecovery(_ plan: SwitchRecoveryPlan, in store: AccountProfilesStore) throws {
        guard case .apply(let profile, _) = plan.action else { return }
        try store.setPreferredChecked(
            family: plan.transaction.family, profileID: profile.id,
            expectedIdentityKey: plan.transaction.targetIdentityKey
        )
        AppLog.info(.auth, "recovered an interrupted account switch")
    }

    private func finishSwitchRecovery(_ plan: SwitchRecoveryPlan, allowInteraction: Bool) throws {
        AccountCredentialMutationLock.acquire(family: plan.transaction.family)
        defer { AccountCredentialMutationLock.release(family: plan.transaction.family) }
        switch plan.action {
        case .committed, .apply:
            do {
                if case .apply(let profile, let target) = plan.action {
                    try clearSynchronizedCodexSnapshot(target, for: profile, allowInteraction: allowInteraction)
                }
                try switchJournal.clear(plan.transaction, allowInteraction: allowInteraction)
            } catch {
                AppLog.error(.auth, "account switch succeeded but recovery record cleanup failed: \(error.localizedDescription)")
            }
        case .cancel, .restore:
            try switchJournal.clear(plan.transaction, allowInteraction: allowInteraction)
        }
    }

    private func recoveryTarget(
        for transaction: AccountSwitchTransition, profile: AccountProfile, allowInteraction: Bool
    ) throws -> AccountCredentialVault.Entry? {
        let entry: AccountCredentialVault.Entry?
        do {
            entry = try loadSnapshot(for: profile, allowInteraction: allowInteraction)
        } catch AccountCredentialVaultError.missingEntry {
            return nil
        }
        guard let entry,
              identity(of: entry, family: profile.family)?.identityKey == transaction.targetIdentityKey,
              try entry.snapshotDigest() == transaction.targetSnapshotDigest else { return nil }
        return entry
    }
}
