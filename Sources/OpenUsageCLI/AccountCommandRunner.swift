import Foundation
import OpenUsage

/// 공유 profile registry에 대한 read-only `openusage account` 명령 실행 — 앱과 같은 UserDefaults domain이라 Settings 전환과 항상 일치.
/// CLI는 credential·Keychain·shell setup에 접근 금지.
@MainActor
struct AccountCommandRunner {
    private let store: AccountProfilesStore

    init(defaults: UserDefaults) {
        self.store = AccountProfilesStore(defaults: defaults)
    }

    func run(_ command: AccountCommand) throws -> Int32 {
        guard !store.hasUnreadableRegistry else {
            throw AccountProfileError.registryUnreadable
        }
        switch command {
        case .list(let family, let json):
            return try list(family: family, json: json)
        case .current(let family):
            return current(family: family)
        }
    }

    private func list(family: String?, json: Bool) throws -> Int32 {
        let families = family.map { [$0] } ?? AccountProfilesStore.supportedFamilies
        if json {
            struct Row: Codable {
                var id: String
                var family: String
                var label: String
                var selected: Bool
            }
            let rows = families.flatMap { family in
                store.profiles(family: family).map { profile in
                    Row(
                        id: profile.id,
                        family: profile.family,
                        label: profile.label,
                        selected: store.preferredProfileID(family: family) == profile.id
                    )
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(rows))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        }

        var printedAny = false
        for family in families {
            let profiles = store.profiles(family: family)
            guard !profiles.isEmpty else { continue }
            printedAny = true
            print("\(family):")
            let selectedID = store.preferredProfileID(family: family)
            for profile in profiles {
                let marker = profile.id == selectedID ? "*" : " "
                print("  \(marker) \(profile.label)")
            }
        }
        if !printedAny {
            print("No managed accounts. Add one in OpenUsage Settings.")
        }
        return 0
    }

    private func current(family: String?) -> Int32 {
        guard let family else {
            for family in AccountProfilesStore.supportedFamilies {
                print("\(family): \(store.preferredProfile(family: family)?.label ?? "-")")
            }
            return 0
        }
        // script 친화 출력 — stdout에 label만, 선택 계정 없으면 무출력.
        if let profile = store.preferredProfile(family: family) {
            print(profile.label)
        }
        return 0
    }
}

/// store 에러의 사용자용 한 줄 메시지 (exit 2 — 시스템이 아닌 요청 오류).
func accountErrorMessage(_ error: AccountProfileError) -> String {
    error.userMessage
}
