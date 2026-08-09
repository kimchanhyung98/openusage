import Foundation

/// Settings 계정 badge·전환 토글 뒤의 로컬 준비 상태 점검.
/// Ready = OpenUsage Keychain snapshot이 profile identity를 증명하는 사용 가능 credential 보유.
/// 선택된 Claude profile은 일반 터미널과 같은 Shared Runtime Home도 같은 identity로 로그인된 상태여야 함.
/// provider 네트워크 호출 없음. 선택된 Claude만 Shared Runtime Home의 공식 CLI 인증을 추가 확인.
struct AccountSignInProbe: Sendable {
    enum State: Equatable, Sendable {
        /// snapshot이 profile 계정을 증명하고 사용 가능한 credential 형태 보유.
        case ready(identityKey: String, label: String?)
        /// 증명 가능한 sign-in snapshot 부재 — "wrong account"가 아니라 단순 미준비.
        case needsSignIn
    }

    var environment: EnvironmentReading
    var keychain: KeychainAccessing
    var homeDirectory: @Sendable () -> URL

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.environment = environment
        self.keychain = keychain
        self.homeDirectory = homeDirectory
    }

    func state(for profile: AccountProfile, isSelected: Bool = false) -> State {
        let switcher = AccountCredentialSwitcher(
            keychain: keychain,
            environment: environment,
            homeDirectory: homeDirectory()
        )
        let snapshot: AccountCredentialVault.Entry?
        do {
            snapshot = try switcher.loadSnapshot(for: profile)
        } catch {
            AppLog.error(.auth, "account snapshot read failed during readiness probe: \(error.localizedDescription)")
            return .needsSignIn
        }
        guard let snapshot,
              let (identityKey, label) = switcher.identity(of: snapshot, family: profile.family),
              identityKey == profile.identityKey
        else {
            return .needsSignIn
        }
        if isSelected, profile.family == "claude" {
            let shared: AccountCredentialVault.Entry?
            do {
                shared = try switcher.readSharedClaudeAuthenticationForReadiness()
            } catch {
                AppLog.error(.auth, "shared Claude home read failed during readiness probe: \(error.localizedDescription)")
                return .needsSignIn
            }
            guard let shared,
                  switcher.identity(of: shared, family: profile.family)?.identityKey == profile.identityKey
            else {
                return .needsSignIn
            }
        }
        return .ready(identityKey: identityKey, label: label)
    }
}
