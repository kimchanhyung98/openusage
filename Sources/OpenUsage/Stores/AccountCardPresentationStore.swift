import Foundation
import Observation

enum AccountCardDisplayMode: String, CaseIterable, Sendable {
    case singleCard
    case separateCards

    var label: String {
        switch self {
        case .singleCard: "Single Card"
        case .separateCards: "Separate Cards"
        }
    }
}

/// 공통 계정 카드 표시 모드·family별 stable profile 순서 — 인증·계정 registry·layout과 독립.
@MainActor
@Observable
final class AccountCardPresentationStore {
    static let storageKey = "openusage.accountCardPresentation.v1"
    static let displayModeKey = "openusage.accountCardDisplayMode.v1"

    private struct Settings: Codable, Equatable {
        var modesByFamily: [String: String] = [:]
        var profileOrderByFamily: [String: [String]] = [:]
    }

    private let defaults: UserDefaults
    private var settings = Settings()
    private var storedMode: String?
    private var hasInvalidModeType = false
    private var hasUnreadableSettings = false
    private(set) var errorMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.object(forKey: Self.storageKey) {
            do {
                guard let data = raw as? Data else { throw CocoaError(.coderReadCorrupt) }
                settings = try JSONDecoder().decode(Settings.self, from: data)
            } catch {
                hasUnreadableSettings = true
                AppLog.error(.config, "account-card presentation was unreadable; preserving it and blocking writes: \(error.localizedDescription)")
            }
        }
        if let raw = defaults.object(forKey: Self.displayModeKey) {
            storedMode = raw as? String
            hasInvalidModeType = storedMode == nil
        }
        updateErrorMessage()
        if hasUnsupportedMode {
            AppLog.error(.config, "account-card presentation contains an unsupported display mode; preserving the saved value")
        }
    }

    /// 구버전 family별 설정은 읽기 승계만 수행 — 명시적 공통 설정이 없을 때 Separate 선택 하나라도 유지.
    var mode: AccountCardDisplayMode {
        guard !hasInvalidModeType else { return .singleCard }
        if let storedMode { return AccountCardDisplayMode(rawValue: storedMode) ?? .singleCard }
        return AccountProfilesStore.supportedFamilies.contains {
            settings.modesByFamily[$0] == AccountCardDisplayMode.separateCards.rawValue
        } ? .separateCards : .singleCard
    }

    func setMode(_ mode: AccountCardDisplayMode) {
        guard !hasUnreadableSettings, self.mode != mode || hasUnsupportedMode else { return }
        // 구버전이 계정 순서를 저장해도 공통 모드가 소실되지 않도록 별도 key 사용.
        defaults.set(mode.rawValue, forKey: Self.displayModeKey)
        storedMode = mode.rawValue
        hasInvalidModeType = false
        updateErrorMessage()
    }

    func shouldShowDisplayMode(profiles: [AccountProfile], registryReadable: Bool) -> Bool {
        guard registryReadable else { return false }
        return AccountProfilesStore.supportedFamilies.contains { family in
            profiles.filter { $0.family == family && !$0.isArchived }.count >= 2
        }
    }

    func effectiveMode(
        for family: String,
        profiles: [AccountProfile],
        registryReadable: Bool
    ) -> AccountCardDisplayMode {
        guard registryReadable, AccountProfilesStore.isSupportedFamily(family),
              profiles.contains(where: { $0.family == family && !$0.isArchived }) else { return .singleCard }
        return mode
    }

    /// 읽기는 저장 순서를 정리하지 않음 — 일시적 registry·runtime 누락 뒤에도 기존 순서 복원.
    func orderedProfiles(_ profiles: [AccountProfile], family: String) -> [AccountProfile] {
        guard AccountProfilesStore.isSupportedFamily(family) else { return [] }
        let registered = profiles.enumerated()
            .filter { $0.element.family == family && !$0.element.isArchived }
            .sorted {
                if $0.element.createdAt == $1.element.createdAt { return $0.offset < $1.offset }
                return $0.element.createdAt < $1.element.createdAt
            }
            .map(\.element)
        let byID = Dictionary(uniqueKeysWithValues: registered.map { ($0.id, $0) })
        var seen = Set<String>()
        let saved = (settings.profileOrderByFamily[family] ?? []).compactMap { id -> AccountProfile? in
            guard let profile = byID[id], seen.insert(id).inserted else { return nil }
            return profile
        }
        return saved + registered.filter { !seen.contains($0.id) }
    }

    @discardableResult
    func reorder(dragged: String, target: String, family: String, profiles: [AccountProfile]) -> Bool {
        guard !hasUnreadableSettings else { return false }
        var ids = orderedProfiles(profiles, family: family).map(\.id)
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target) else { return false }
        ids.remove(at: from)
        ids.insert(dragged, at: to)
        var updated = settings
        updated.profileOrderByFamily[family] = ids
        return persist(updated)
    }

    private func persist(_ updated: Settings) -> Bool {
        guard !hasUnreadableSettings, updated != settings else { return false }
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: Self.storageKey)
            settings = updated
            updateErrorMessage()
            return true
        } catch {
            errorMessage = "OpenUsage couldn't save the account display settings. Try again and check the app log."
            AppLog.error(.config, "failed to encode account-card presentation: \(error.localizedDescription)")
            return false
        }
    }

    private var hasUnsupportedMode: Bool {
        if hasInvalidModeType { return true }
        if let storedMode { return AccountCardDisplayMode(rawValue: storedMode) == nil }
        return AccountProfilesStore.supportedFamilies.contains { family in
            settings.modesByFamily[family].map { AccountCardDisplayMode(rawValue: $0) == nil } ?? false
        }
    }

    private func updateErrorMessage() {
        if hasUnreadableSettings {
            errorMessage = "OpenUsage couldn't read the saved account display settings. They were left unchanged. Restart OpenUsage and check the log before trying again."
            return
        }
        errorMessage = hasUnsupportedMode
            ? "A saved account display mode isn't supported by this version. Choose Single Card or Separate Cards to update the display setting."
            : nil
    }
}
