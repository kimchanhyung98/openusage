import Foundation

/// Settings 계정 badge·전환 토글 뒤의 로컬 준비 상태 점검.
/// Ready = OpenUsage Keychain snapshot이 profile 자신의 identity를 여전히 증명하는 사용 가능 credential 보유 — switch 트랜잭션의 전제 조건을 동일한 reader로 검사.
/// provider 네트워크 호출·shared-home read·타 앱 item의 prompt 위험 Keychain probe 없음.
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

    func state(for profile: AccountProfile) -> State {
        let switcher = AccountCredentialSwitcher(
            keychain: keychain,
            environment: environment,
            homeDirectory: homeDirectory()
        )
        guard let entry = try? switcher.loadSnapshot(for: profile),
              let (identityKey, label) = switcher.identity(of: entry, family: profile.family),
              identityKey == profile.identityKey
        else {
            return .needsSignIn
        }
        return .ready(identityKey: identityKey, label: label)
    }
}
