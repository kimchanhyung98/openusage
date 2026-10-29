import XCTest
@testable import OpenUsage

final class CopilotActiveAccountTests: XCTestCase {
    func testActiveHostTokenWinsOverInactiveNestedTokenRegardlessOfFieldOrder() {
        for indentation in ["  ", "    "] {
            let nested = """
            \(indentation)users:
            \(indentation)\(indentation)old-user:
            \(indentation)\(indentation)\(indentation)oauth_token: fixture-old-token
            """
            let activeFields = [
                "\(indentation)user: active-user\n\(indentation)oauth_token: fixture-active-token",
                "\(indentation)oauth_token: fixture-active-token\n\(indentation)user: active-user"
            ]
            for active in activeFields {
                for fields in [nested + "\n" + active, active + "\n" + nested] {
                    let keychain = CopilotAccountKeychain()
                    let store = makeStore(hosts: "github.com:\n" + fields, keychain: keychain)

                    XCTAssertEqual(store.loadToken()?.value, "fixture-active-token")
                    XCTAssertTrue(keychain.requestedAccounts.isEmpty)
                    XCTAssertEqual(keychain.serviceOnlyReads, 0)
                }
            }
        }
    }

    func testInactiveFileTokenDoesNotHideActiveAccountsKeychainToken() {
        let keychain = CopilotAccountKeychain(
            accounts: ["active-user": wrapped("fixture-active-token")],
            serviceOnlyValue: wrapped("fixture-old-token")
        )
        let store = makeStore(hosts: """
        github.com:
            users:
                old-user:
                    oauth_token: fixture-old-token
                active-user:
            user: active-user
        """, keychain: keychain)

        XCTAssertEqual(store.loadToken()?.value, "fixture-active-token")
        XCTAssertEqual(keychain.requestedAccounts, ["active-user"])
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
    }

    func testCommentsAndBlankLinesDoNotChangeActiveHostFieldSelection() {
        let keychain = CopilotAccountKeychain()
        let hosts = [
            "github.com:",
            "",
            "        # A comment is not a nested credential field.",
            "    ",
            "    users:",
            "        old-user:",
            "            oauth_token: fixture-old-token",
            "# The active fields still belong to github.com.",
            "    user: active-user",
            "    oauth_token: fixture-active-token"
        ].joined(separator: "\n")
        let store = makeStore(hosts: hosts, keychain: keychain)

        XCTAssertEqual(store.loadToken()?.value, "fixture-active-token")
        XCTAssertTrue(keychain.requestedAccounts.isEmpty)
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
    }

    func testEditorTokenStillWinsWhenGhHasAnotherActiveAccount() {
        let keychain = CopilotAccountKeychain(accounts: ["active-user": wrapped("fixture-gh-token")])
        let files = FakeFiles([
            CopilotAuthStore.editorAppsPath: #"{"github.com:editor":{"oauth_token":"fixture-editor-token"}}"#,
            CopilotAuthStore.ghHostsPath: """
            github.com:
                user: active-user
                oauth_token: fixture-gh-token
            """
        ])
        let store = CopilotAuthStore(files: files, keychain: keychain)

        XCTAssertEqual(store.loadToken()?.value, "fixture-editor-token")
        XCTAssertTrue(keychain.requestedAccounts.isEmpty)
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
    }

    func testMissingNamedKeychainItemUsesExplicitActiveAlias() {
        let keychain = CopilotAccountKeychain(
            accounts: ["": wrapped("fixture-active-token")],
            serviceOnlyValue: wrapped("fixture-old-token")
        )
        let store = makeStore(hosts: """
        github.com:
            user: active-user
        """, keychain: keychain)

        XCTAssertEqual(store.loadToken()?.value, "fixture-active-token")
        XCTAssertEqual(keychain.requestedAccounts, ["active-user", ""])
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
    }

    func testNestedTokensWithoutActiveUserUseExplicitKeychainAlias() {
        let keychain = CopilotAccountKeychain(
            accounts: ["": wrapped("fixture-active-token")],
            serviceOnlyValue: wrapped("fixture-old-token")
        )
        let store = makeStore(hosts: """
        github.com:
            users:
                old-user:
                    oauth_token: fixture-old-token
        """, keychain: keychain)

        XCTAssertEqual(store.loadToken()?.value, "fixture-active-token")
        XCTAssertEqual(keychain.requestedAccounts, [""])
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
    }

    func testUnreadableNamedKeychainItemUsesExplicitActiveAlias() {
        let keychain = CopilotAccountKeychain(
            accounts: ["": wrapped("fixture-active-token")],
            serviceOnlyValue: wrapped("fixture-old-token"),
            unreadableAccounts: ["active-user"]
        )
        let store = makeStore(hosts: "github.com:\n    user: active-user", keychain: keychain)

        XCTAssertEqual(store.loadToken()?.value, "fixture-active-token")
        XCTAssertEqual(keychain.requestedAccounts, ["active-user", ""])
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
    }

    func testMissingGhConfigUsesExplicitKeychainAlias() {
        let keychain = CopilotAccountKeychain(
            accounts: ["": wrapped("fixture-active-token")],
            serviceOnlyValue: wrapped("fixture-old-token")
        )
        let store = CopilotAuthStore(files: FakeFiles(), keychain: keychain)

        XCTAssertEqual(store.loadToken()?.value, "fixture-active-token")
        XCTAssertEqual(keychain.requestedAccounts, [""])
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
    }

    func testMissingActiveCredentialsDoNotSelectAnotherKeychainAccount() {
        for hosts in ["github.com:\n    user: active-user", "github.com:\n    git_protocol: https"] {
            let keychain = CopilotAccountKeychain(
                accounts: ["old-user": wrapped("fixture-old-token")],
                serviceOnlyValue: wrapped("fixture-old-token")
            )
            let store = makeStore(hosts: hosts, keychain: keychain)

            XCTAssertNil(store.loadToken())
            XCTAssertFalse(keychain.requestedAccounts.contains("old-user"))
            XCTAssertEqual(keychain.serviceOnlyReads, 0)
        }
    }

    func testReloadUsesNewlyActivatedGhAccount() {
        let files = FakeFiles()
        let keychain = CopilotAccountKeychain()
        let store = CopilotAuthStore(files: files, keychain: keychain)
        for account in ["first", "second"] {
            files.files[CopilotAuthStore.ghHostsPath] = """
            github.com:
                users:
                    first:
                        oauth_token: fixture-first-token
                    second:
                        oauth_token: fixture-second-token
                user: \(account)
                oauth_token: fixture-\(account)-token
            """

            XCTAssertEqual(store.loadToken()?.value, "fixture-\(account)-token")
        }
        XCTAssertTrue(keychain.requestedAccounts.isEmpty)
        XCTAssertEqual(keychain.serviceOnlyReads, 0)
    }

    private func makeStore(hosts: String, keychain: CopilotAccountKeychain) -> CopilotAuthStore {
        CopilotAuthStore(files: FakeFiles([CopilotAuthStore.ghHostsPath: hosts]), keychain: keychain)
    }

    private func wrapped(_ token: String) -> String {
        "go-keyring-base64:" + Data(token.utf8).base64EncodedString()
    }
}

private final class CopilotAccountKeychain: KeychainAccessing, @unchecked Sendable {
    let accounts: [String: String]
    let serviceOnlyValue: String?
    let unreadableAccounts: Set<String>
    private(set) var requestedAccounts: [String] = []
    private(set) var serviceOnlyReads = 0

    init(accounts: [String: String] = [:], serviceOnlyValue: String? = nil, unreadableAccounts: Set<String> = []) {
        self.accounts = accounts
        self.serviceOnlyValue = serviceOnlyValue
        self.unreadableAccounts = unreadableAccounts
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        XCTAssertEqual(service, CopilotAuthStore.ghKeychainService)
        requestedAccounts.append(account)
        if unreadableAccounts.contains(account) { throw KeychainError.readFailed("fixture read failure") }
        return accounts[account]
    }

    func readGenericPassword(service: String) throws -> String? {
        XCTAssertEqual(service, CopilotAuthStore.ghKeychainService)
        serviceOnlyReads += 1
        return serviceOnlyValue
    }

    func writeGenericPassword(service: String, value: String) throws {
        XCTFail("Token discovery must not write authentication")
    }

    func deleteGenericPassword(service: String) throws {
        XCTFail("Token discovery must not delete authentication")
    }
}
