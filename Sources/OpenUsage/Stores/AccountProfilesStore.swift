import Foundation
import Observation

/// Claude/Codex account switching의 managed account record. `id`는 snapshot·workspace의 stable handle,
/// `label`은 사용자가 정한 family 내 유일 이름, `identityKey`는 현재 인증이 증명한 가변 provider binding.
public struct AccountProfile: Codable, Equatable, Sendable, Identifiable {
    /// 등록 시 발급되는 stable id(신규는 UUID, 이관 profile은 기존 id 유지) — Keychain snapshot과
    /// Sign-In Workspace의 handle.
    public var id: String
    /// 소속 provider family(`claude`/`codex`) — 불변.
    public var family: String
    /// 표시 이름(Settings·dashboard selector·CLI) — 자유 rename, identity 입력이 아님.
    /// family 내 유일 — 두 행이 한 account로 읽히지 않도록.
    public var label: String
    /// provider가 증명한 현재 account identity(Claude: account+org UUID, Codex: ChatGPT account id) —
    /// 직접 편집 불가; 검증된 재로그인만 교체 가능하며 switch transaction은 snapshot과 일치하는지 확인.
    public var identityKey: String
    public var createdAt: Date
    /// 제거는 tombstone — 공유 runtime home은 삭제하지 않고, archived profile은 모든 picker·preferred
    /// selection에서 제외.
    public var isArchived: Bool

    init(
        id: String,
        family: String,
        label: String,
        identityKey: String,
        createdAt: Date,
        isArchived: Bool = false
    ) {
        self.id = id
        self.family = family
        self.label = label
        self.identityKey = identityKey
        self.createdAt = createdAt
        self.isArchived = isArchived
    }
}

public enum AccountProfileError: Error, Equatable {
    case unknownFamily(String)
    case invalidLabel
    case duplicateLabel(String)
    case accountLimitReached(Int)
    case profileNotFound(String)
    case ambiguousReference(String)
    case removeSelectedProfile
    case registryUnreadable
}

extension AccountProfileError {
    /// 사용자 노출 한 줄 메시지 — Settings sheet와 `openusage account` CLI 공용.
    public var userMessage: String {
        switch self {
        case .unknownFamily(let family):
            return "Unknown tool: \(family) (expected claude or codex)"
        case .invalidLabel:
            return "Invalid account name."
        case .duplicateLabel(let label):
            return "An account named '\(label)' already exists. Choose a different name."
        case .accountLimitReached(let limit):
            return "All \(limit) account slots are in use. Remove an account first."
        case .profileNotFound(let reference):
            return "No account matches '\(reference)'."
        case .ambiguousReference(let reference):
            return "'\(reference)' matches multiple accounts. Use its id from 'openusage account list --json'."
        case .removeSelectedProfile:
            return "This account is currently selected. Select another account before removing it."
        case .registryUnreadable:
            return "OpenUsage couldn't read the saved account list. It was left unchanged. Restart OpenUsage and check the log before trying again."
        }
    }
}

struct AccountIdentityReplacement: Codable, Equatable, Sendable {
    var profileID: String
    var previousIdentityKey: String
    var replacementIdentityKey: String
    var replacesSharedAuthentication: Bool
}

enum AccountIdentityReplacementError: LocalizedError {
    case pendingTransaction
    case invalidTransaction

    var errorDescription: String? {
        switch self {
        case .pendingTransaction:
            "Another account sign-in update is still being recovered. Try again after the next refresh."
        case .invalidTransaction:
            "The saved account sign-in update could not be recovered. Check the app log and try again."
        }
    }
}

/// managed account registry(`openusage.accountProfiles.v2`) — 공유 defaults domain이라 앱과 read-only
/// `openusage account` CLI가 같은 상태 공유(CLI는 launch마다 fresh read, 앱은 panel open 시 `reloadFromDefaults()`).
/// profile metadata만 보유 — credential은 각 profile의 Keychain snapshot, 카드 identity는 `ProviderAccountsStore`.
@MainActor
@Observable
public final class AccountProfilesStore {
    public static let storageKey = "openusage.accountProfiles.v2"
    static let identityReplacementKey = "openusage.accountIdentityReplacement.v1"
    public static let maxProfilesPerFamily = 10
    nonisolated static let maxLabelLength = 60

    nonisolated public static let supportedFamilies = ["claude", "codex"]

    nonisolated public static func isSupportedFamily(_ family: String) -> Bool {
        supportedFamilies.contains(family)
    }

    struct Blob: Codable, Equatable {
        var profiles: [AccountProfile]
        var preferredByFamily: [String: String]
    }

    private enum RegistryValidationError: Error {
        case invalidProfile
        case profileLimitExceeded
    }

    private let defaults: UserDefaults

    public private(set) var profiles: [AccountProfile] = []
    public private(set) var hasUnreadableRegistry = false
    public private(set) var authenticationRevision = 0
    private var preferredByFamily: [String: String] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// 한 family의 active profile — 등록순(표시 순서).
    public func profiles(family: String) -> [AccountProfile] {
        profiles
            .filter { $0.family == family && !$0.isArchived }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func profile(id: String) -> AccountProfile? {
        profiles.first { $0.id == id && !$0.isArchived }
    }

    /// 새 세션이 인증에 사용할 profile id — 저장된 선택이 여전히 그 family의 active profile을 가리킬 때만.
    public func preferredProfileID(family: String) -> String? {
        guard let id = preferredByFamily[family],
              profiles.contains(where: { $0.id == id && $0.family == family && !$0.isArchived }) else {
            return nil
        }
        return id
    }

    public func preferredProfile(family: String) -> AccountProfile? {
        preferredProfileID(family: family).flatMap { id in profiles.first { $0.id == id } }
    }

    /// 선택 profile 기록 — active profile이 있는 family는 항상 선택 1개 유지(모든 account toggle off 불가).
    public func setPreferred(family: String, profileID: String?) {
        guard !hasUnreadableRegistry else {
            AppLog.error(.config, "refusing to change account selection while the registry is unavailable")
            return
        }
        if let profileID {
            guard profiles.contains(where: { $0.id == profileID && $0.family == family && !$0.isArchived }) else {
                return
            }
            guard preferredByFamily[family] != profileID else { return }
            preferredByFamily[family] = profileID
        } else {
            guard profiles(family: family).isEmpty else { return }
            guard preferredByFamily.removeValue(forKey: family) != nil else { return }
        }
        persist()
    }

    /// 증명된 provider account의 profile 등록 — family 내 `label`만 유일, provider identity 중복 허용.
    /// `id` 지정 시 sign-in flow가 공식 로그인 전에 발급한 workspace 유지; 생략하면 새 UUID 발급.
    @discardableResult
    public func add(family: String, label: String, identityKey: String, id: String? = nil) throws -> AccountProfile {
        try ensureRegistryWritable()
        guard Self.isSupportedFamily(family) else {
            throw AccountProfileError.unknownFamily(family)
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidLabel(trimmedLabel) else {
            throw AccountProfileError.invalidLabel
        }
        let normalizedIdentity = identityKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedIdentity.isEmpty else {
            throw AccountProfileError.profileNotFound(identityKey)
        }
        guard !hasActiveLabel(trimmedLabel, family: family, excludingProfileID: nil) else {
            throw AccountProfileError.duplicateLabel(trimmedLabel)
        }
        let activeCount = profiles.filter { $0.family == family && !$0.isArchived }.count
        guard activeCount < Self.maxProfilesPerFamily else {
            throw AccountProfileError.accountLimitReached(Self.maxProfilesPerFamily)
        }
        let resolvedID = id ?? UUID().uuidString
        guard Self.isValidID(resolvedID), !profiles.contains(where: { $0.id == resolvedID }) else {
            throw AccountProfileError.profileNotFound(resolvedID)
        }
        let profile = AccountProfile(
            id: resolvedID,
            family: family,
            label: trimmedLabel,
            identityKey: normalizedIdentity,
            createdAt: Date()
        )
        profiles.append(profile)
        selectFirstProfileIfNeeded(family: family)
        persist()
        return profile
    }

    /// profile rename — `label`만 변경; id·identity·snapshot·workspace·preferred selection 불변.
    public func rename(profileID: String, to label: String) throws {
        try ensureRegistryWritable()
        guard let index = profiles.firstIndex(where: { $0.id == profileID && !$0.isArchived }) else {
            throw AccountProfileError.profileNotFound(profileID)
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidLabel(trimmedLabel) else {
            throw AccountProfileError.invalidLabel
        }
        guard !hasActiveLabel(trimmedLabel, family: profiles[index].family, excludingProfileID: profileID) else {
            throw AccountProfileError.duplicateLabel(trimmedLabel)
        }
        guard profiles[index].label != trimmedLabel else { return }
        profiles[index].label = trimmedLabel
        persist()
    }

    /// 검증된 재로그인의 provider binding 교체 — stable id·label·생성 시각·선택 상태 불변.
    @discardableResult
    func replaceIdentity(profileID: String, with identityKey: String) throws -> AccountProfile {
        try ensureRegistryWritable()
        guard let index = profiles.firstIndex(where: { $0.id == profileID && !$0.isArchived }) else {
            throw AccountProfileError.profileNotFound(profileID)
        }
        let normalizedIdentity = identityKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedIdentity.isEmpty else {
            throw AccountProfileError.profileNotFound(identityKey)
        }
        guard profiles[index].identityKey != normalizedIdentity else { return profiles[index] }
        profiles[index].identityKey = normalizedIdentity
        persist()
        return profiles[index]
    }

    /// snapshot·workspace와 profile identity 사이의 crash recovery journal 시작.
    func beginIdentityReplacement(
        profileID: String,
        with identityKey: String,
        replacesSharedAuthentication: Bool
    ) throws -> AccountIdentityReplacement {
        try ensureRegistryWritable()
        guard let profile = profile(id: profileID) else {
            throw AccountProfileError.profileNotFound(profileID)
        }
        guard try pendingIdentityReplacement() == nil else {
            throw AccountIdentityReplacementError.pendingTransaction
        }
        let replacementIdentityKey = identityKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !replacementIdentityKey.isEmpty else {
            throw AccountProfileError.profileNotFound(identityKey)
        }
        let transaction = AccountIdentityReplacement(
            profileID: profile.id,
            previousIdentityKey: profile.identityKey,
            replacementIdentityKey: replacementIdentityKey,
            replacesSharedAuthentication: replacesSharedAuthentication
        )
        defaults.set(try JSONEncoder().encode(transaction), forKey: Self.identityReplacementKey)
        return transaction
    }

    func pendingIdentityReplacement() throws -> AccountIdentityReplacement? {
        guard let data = defaults.data(forKey: Self.identityReplacementKey) else { return nil }
        guard let transaction = try? JSONDecoder().decode(AccountIdentityReplacement.self, from: data) else {
            AppLog.error(.auth, "account identity replacement journal is unreadable")
            defaults.removeObject(forKey: Self.identityReplacementKey)
            throw AccountIdentityReplacementError.invalidTransaction
        }
        return transaction
    }

    @discardableResult
    func commitIdentityReplacement(_ transaction: AccountIdentityReplacement) throws -> AccountProfile {
        guard try pendingIdentityReplacement() == transaction else {
            throw AccountIdentityReplacementError.invalidTransaction
        }
        let profile = try replaceIdentity(
            profileID: transaction.profileID,
            with: transaction.replacementIdentityKey
        )
        defaults.removeObject(forKey: Self.identityReplacementKey)
        authenticationRevision &+= 1
        return profile
    }

    func cancelIdentityReplacement(_ transaction: AccountIdentityReplacement) throws {
        guard try pendingIdentityReplacement() == transaction else {
            throw AccountIdentityReplacementError.invalidTransaction
        }
        defaults.removeObject(forKey: Self.identityReplacementKey)
    }

    /// profile tombstone 처리 — 다른 active profile이 있는 동안 선택된 profile의 archive는 거부, switchable
    /// family에 어떤 행도 응답하지 않는 인증이 남을 수 없음. 호출자는 workspace·Keychain snapshot 제거를 먼저 수행.
    public func archive(profileID: String) throws {
        try validateArchive(profileID: profileID)
        let index = profiles.firstIndex(where: { $0.id == profileID && !$0.isArchived })!
        let family = profiles[index].family
        profiles[index].isArchived = true
        if preferredByFamily[family] == profileID {
            preferredByFamily.removeValue(forKey: family)
        }
        selectFirstProfileIfNeeded(family: family)
        persist()
    }

    func validateArchive(profileID: String) throws {
        try ensureRegistryWritable()
        guard let profile = profiles.first(where: { $0.id == profileID && !$0.isArchived }) else {
            throw AccountProfileError.profileNotFound(profileID)
        }
        if preferredProfileID(family: profile.family) == profileID,
           profiles(family: profile.family).count > 1 {
            throw AccountProfileError.removeSelectedProfile
        }
    }

    /// CLI/UI reference 해석 — profile id 또는 유일한 case-insensitive label 매치.
    public func resolve(reference: String, family: String) throws -> AccountProfile {
        let active = profiles(family: family)
        if let byID = active.first(where: { $0.id == reference }) { return byID }
        let folded = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = active.filter { $0.label.caseInsensitiveCompare(folded) == .orderedSame }
        if matches.count > 1 { throw AccountProfileError.ambiguousReference(reference) }
        guard let match = matches.first else { throw AccountProfileError.profileNotFound(reference) }
        return match
    }

    /// 공유 domain 재읽기 — 장수 앱이 panel open 시 호출, 타 process의 쓰기를 relaunch 없이 반영.
    public func reloadFromDefaults() {
        load()
    }

    private func hasActiveLabel(_ label: String, family: String, excludingProfileID: String?) -> Bool {
        profiles.contains {
            $0.family == family
                && !$0.isArchived
                && $0.id != excludingProfileID
                && $0.label.caseInsensitiveCompare(label) == .orderedSame
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            profiles = []
            preferredByFamily = [:]
            hasUnreadableRegistry = false
            return
        }
        do {
            let blob = try JSONDecoder().decode(Blob.self, from: data)
            var seenIDs = Set<String>()
            var seenLabels = Set<String>()
            var activeCounts: [String: Int] = [:]
            var sanitized: [AccountProfile] = []
            for var profile in blob.profiles {
                let label = profile.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let identityKey = profile.identityKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard Self.isSupportedFamily(profile.family),
                      Self.isValidID(profile.id),
                      Self.isValidLabel(label),
                      !identityKey.isEmpty,
                      seenIDs.insert(profile.id).inserted,
                      profile.isArchived || seenLabels.insert("\(profile.family)\u{1F}\(label.lowercased())").inserted
                else {
                    throw RegistryValidationError.invalidProfile
                }
                if !profile.isArchived {
                    guard activeCounts[profile.family, default: 0] < Self.maxProfilesPerFamily else {
                        throw RegistryValidationError.profileLimitExceeded
                    }
                    activeCounts[profile.family, default: 0] += 1
                }
                profile.label = label
                profile.identityKey = identityKey
                sanitized.append(profile)
            }
            profiles = sanitized
            hasUnreadableRegistry = false
            let validIDs = Set(profiles.filter { !$0.isArchived }.map(\.id))
            preferredByFamily = blob.preferredByFamily.filter { family, id in
                Self.isSupportedFamily(family) && validIDs.contains(id)
            }
            let storedPreferred = preferredByFamily
            for family in Self.supportedFamilies {
                selectFirstProfileIfNeeded(family: family)
            }
            if preferredByFamily != storedPreferred {
                persist()
            }
        } catch {
            AppLog.error(.config, "account-profile store was undecodable; preserving it and blocking account writes: \(error.localizedDescription)")
            profiles = []
            preferredByFamily = [:]
            hasUnreadableRegistry = true
        }
    }

    private func persist() {
        guard !hasUnreadableRegistry else {
            AppLog.error(.config, "refusing to overwrite an unavailable account registry")
            return
        }
        let blob = Blob(profiles: profiles, preferredByFamily: preferredByFamily)
        guard let data = try? JSONEncoder().encode(blob) else {
            AppLog.error(.config, "failed to encode account profiles; keeping previous persisted state")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func ensureRegistryWritable() throws {
        if hasUnreadableRegistry {
            throw AccountProfileError.registryUnreadable
        }
    }

    private func selectFirstProfileIfNeeded(family: String) {
        guard preferredProfileID(family: family) == nil,
              let firstProfile = profiles(family: family).first
        else {
            return
        }
        preferredByFamily[family] = firstProfile.id
    }

    nonisolated static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= maxLabelLength else { return false }
        guard !label.contains("/"), !label.contains("\\") else { return false }
        return !label.unicodeScalars.contains {
            $0.properties.generalCategory == .control
        }
    }

    nonisolated private static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        guard !id.contains("/"), !id.contains("\\") else { return false }
        return !id.unicodeScalars.contains {
            $0.properties.generalCategory == .control
        }
    }
}
