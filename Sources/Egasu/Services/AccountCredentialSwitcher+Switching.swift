import Foundation

extension AccountCredentialSwitcher {
    // MARK: - Switch transaction

    /// Settings 토글 트랜잭션 — target snapshot 검증, 떠나는 계정의 rotated credential 보존, target 인증만 적용, 적용 identity 검증, 실패 시 rollback.
    /// 선택 상태 갱신은 caller 몫 — 이 함수 반환 후에만.
    func switchAuthentication(to selected: AccountProfile, from current: AccountProfile?) throws {
        guard AccountProfilesStore.isSupportedFamily(selected.family) else {
            throw Error.unsupportedFamily(selected.family)
        }
        // 활성 profile 재선택 시 쓰기 1건도 발생 금지.
        guard current?.id != selected.id else { return }
        AccountCredentialMutationLock.acquire(family: selected.family)
        defer { AccountCredentialMutationLock.release(family: selected.family) }

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

        // 활성 credential은 적용 후 rotate됐을 수 있음 — 현재 profile의 snapshot·workspace에 보존, 단 shared home이 그 profile 계정임이 증명될 때만.
        let active = try readSharedAuthentication(family: selected.family)
        if let current,
           current.family == selected.family,
           let active,
           identity(of: active, family: current.family)?.identityKey == current.identityKey {
            var preserved = active
            if current.family == "codex",
               let snapshot = try loadSnapshot(for: current, allowInteraction: true),
               snapshot.codexStaleSharedCredentialFingerprints?.contains(CodexAuthStore.credentialFingerprint(active.credential)) == true,
               identity(of: snapshot, family: current.family)?.identityKey == current.identityKey {
                preserved = snapshot
            }
            try saveSnapshot(preserved, for: current)
            try writeWorkspaceAuthentication(preserved, for: current)
        }

        do {
            try applySharedAuthentication(target, family: selected.family)
            let applied = try readSharedAuthentication(family: selected.family)
            guard let applied,
                  identity(of: applied, family: selected.family)?.identityKey == selected.identityKey else {
                throw Error.switchVerificationFailed(selected.label)
            }
            if selected.family == "codex", target.codexStaleSharedCredentialFingerprints != nil {
                var synchronized = target
                synchronized.codexStaleSharedCredentialFingerprints = nil
                try saveSnapshot(synchronized, for: selected)
            }
        } catch {
            if let active {
                do {
                    try applySharedAuthentication(active, family: selected.family)
                } catch {
                    AppLog.error(.auth, "account switch rollback failed: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }
}
