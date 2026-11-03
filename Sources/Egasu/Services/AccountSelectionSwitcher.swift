import Foundation

/// 공유 로그인과 선택 계정의 전환 경계 — Claude의 중단 기록을 외부 로그인 반영보다 먼저 복구.
@MainActor
struct AccountSelectionSwitcher {
    private let switcher: AccountCredentialSwitcher
    private let journal: AccountSwitchJournal

    init(
        switcher: AccountCredentialSwitcher = AccountCredentialSwitcher(),
        journal: AccountSwitchJournal? = nil
    ) {
        self.switcher = switcher
        self.journal = journal ?? switcher.switchJournal
    }

    func hasPendingSwitch() throws -> Bool {
        try journal.load() != nil
    }

    func switchAuthentication(to selected: AccountProfile, in store: AccountProfilesStore) async throws {
        guard store.profile(id: selected.id) == selected else {
            throw AccountProfileError.profileNotFound(selected.id)
        }
        if selected.family != "claude" {
            try switcher.switchAuthentication(to: selected, from: store.preferredProfile(family: selected.family))
            store.setPreferred(family: selected.family, profileID: selected.id)
            return
        }
        guard !store.hasUnreadableRegistry, try store.pendingIdentityReplacement() == nil else {
            throw AccountIdentityReplacementError.pendingTransaction
        }
        var previousRecord = try journal.load()
        if let record = previousRecord {
            let state = try await readSwitchState(in: store, expecting: record)
            if let profileID = selection(for: record, state: state, in: store) {
                try finish(record, selecting: profileID, in: store)
                previousRecord = nil
            }
        }
        guard let preferred = store.preferredProfile(family: "claude") else {
            throw AccountProfileError.profileNotFound(selected.id)
        }
        guard preferred.id != selected.id || previousRecord != nil else { return }
        let previous: AccountProfile
        if let record = previousRecord {
            guard let profile = store.profile(id: record.previousProfileID),
                  profile.family == "claude", profile.identityKey == record.previousIdentity else {
                throw AccountIdentityReplacementError.invalidTransaction
            }
            previous = profile
        } else {
            previous = preferred
        }
        guard let target = try switcher.loadSnapshot(for: selected, allowInteraction: true) else {
            throw AccountCredentialSwitcher.Error.missingSnapshot(selected.label)
        }
        guard switcher.identity(of: target, family: "claude")?.identityKey == selected.identityKey else {
            throw AccountCredentialSwitcher.Error.snapshotIdentityMismatch(selected.label)
        }

        let state = try await readSwitchState(in: store, expecting: previousRecord)
        let active = try switcher.readSharedAuthentication(family: "claude")
        let activeFingerprint = active.map { AccountSwitchJournal.fingerprint($0.credential) }
        let canPreservePrevious = previousRecord == nil
            && active.flatMap { switcher.identity(of: $0, family: "claude")?.identityKey } == previous.identityKey
        let record = AccountSwitchJournal.Record(
            previousProfileID: previous.id,
            previousIdentity: previous.identityKey,
            previousCredentialFingerprint: canPreservePrevious ? activeFingerprint
                : previousRecord?.previousCredentialFingerprint,
            previousStateFingerprint: previousRecord == nil
                ? try state.fingerprint() : previousRecord?.previousStateFingerprint,
            priorSelectionIDs: Array(Set((previousRecord?.priorSelectionIDs ?? []) + [preferred.id]))
                .filter { store.profile(id: $0)?.family == "claude" }.sorted(),
            selectedProfileID: selected.id,
            selectedIdentity: selected.identityKey,
            selectedCredentialFingerprint: AccountSwitchJournal.fingerprint(target.credential)
        )

        do {
            try journal.save(record, replacing: previousRecord)
            // 재시도 중 혼합된 공유 인증은 어느 계정의 저장 인증에도 반영하지 않음.
            try switcher.switchAuthentication(to: selected, from: previousRecord == nil ? previous : nil)
            let applied = try await readSwitchState(in: store, expecting: record)
            guard applied.matches(
                credentialFingerprint: record.selectedCredentialFingerprint,
                identity: record.selectedIdentity,
                requiresAllSources: true
            ) else {
                throw AccountCredentialSwitcher.Error.switchRecoveryRequired
            }
            try finish(record, selecting: selected.id, in: store)
        } catch {
            AppLog.error(.auth, "account selection switch failed; preserving recovery state: \(error.localizedDescription)")
            throw error
        }
    }

    @discardableResult
    func recoverInterruptedSwitch(in store: AccountProfilesStore) throws -> Bool {
        guard let record = try journal.load() else { return false }
        let state = try switcher.readClaudeSwitchState()
        return try recover(record, state: state, in: store)
    }

    @discardableResult
    func recoverInterruptedSwitchAfterStartup(in store: AccountProfilesStore) async throws -> Bool {
        guard let record = try journal.load() else { return false }
        let state = try await readSwitchState(in: store, expecting: record)
        return try recover(record, state: state, in: store)
    }

    private func readSwitchState(
        in store: AccountProfilesStore,
        expecting record: AccountSwitchJournal.Record?
    ) async throws -> AccountSwitchJournal.SharedState {
        guard !store.hasUnreadableRegistry, try journal.load() == record else {
            throw AccountIdentityReplacementError.pendingTransaction
        }
        let profiles = store.profiles
        let preferred = store.preferredProfileID(family: "claude")
        let revision = store.authenticationRevision
        let identityReplacement = try store.pendingIdentityReplacement()
        let observer = switcher
        let state = try await loadOffMainActor { try observer.readClaudeSwitchState() }
        try Task.checkCancellation()
        guard !store.hasUnreadableRegistry,
              store.profiles == profiles,
              store.preferredProfileID(family: "claude") == preferred,
              store.authenticationRevision == revision,
              try store.pendingIdentityReplacement() == identityReplacement,
              try journal.load() == record
        else {
            throw AccountIdentityReplacementError.pendingTransaction
        }
        return state
    }

    private func recover(
        _ record: AccountSwitchJournal.Record,
        state: AccountSwitchJournal.SharedState,
        in store: AccountProfilesStore
    ) throws -> Bool {
        guard let profileID = selection(for: record, state: state, in: store) else {
            AppLog.error(.auth, "account switch recovery found an unknown credential generation; preserving saved accounts")
            throw AccountCredentialSwitcher.Error.switchRecoveryRequired
        }
        try finish(record, selecting: profileID, in: store)
        return true
    }

    private func selection(
        for record: AccountSwitchJournal.Record,
        state: AccountSwitchJournal.SharedState,
        in store: AccountProfilesStore
    ) -> String? {
        guard !store.hasUnreadableRegistry,
              let previous = store.profile(id: record.previousProfileID),
              previous.family == "claude", previous.identityKey == record.previousIdentity,
              let selected = store.profile(id: record.selectedProfileID),
              selected.family == "claude", selected.identityKey == record.selectedIdentity,
              let preferred = store.preferredProfileID(family: "claude"),
              ([previous.id, selected.id] + record.priorSelectionIDs).contains(preferred)
        else { return nil }
        if state.matches(
            credentialFingerprint: record.selectedCredentialFingerprint,
            identity: record.selectedIdentity,
            requiresAllSources: true
        ) {
            return selected.id
        }
        if let previousFingerprint = record.previousStateFingerprint,
           (try? state.fingerprint()) == previousFingerprint {
            return previous.id
        }
        if let previousFingerprint = record.previousCredentialFingerprint,
           state.matches(
            credentialFingerprint: previousFingerprint,
            identity: record.previousIdentity,
            requiresAllSources: true
           ) {
            return previous.id
        }
        return nil
    }

    private func finish(
        _ record: AccountSwitchJournal.Record,
        selecting profileID: String,
        in store: AccountProfilesStore
    ) throws {
        guard try journal.load() == record else { throw AccountIdentityReplacementError.pendingTransaction }
        try store.commitPreferredSelection(family: "claude", profileID: profileID)
        try journal.clear(record)
    }
}
