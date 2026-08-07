import XCTest
@testable import OpenUsage

/// The static shell wrapper: pins the Shared Runtime Home, strips auth environment overrides, and
/// never encodes which account is selected.
final class AccountShellInstallerTests: XCTestCase {
    func testZshClaudeWrapperPinsTheSharedHomeAndStripsAuthOverrides() throws {
        let home = try makeHome()

        try AccountShellInstaller.install(family: "claude", shell: .zsh, homeDirectory: home)

        let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertTrue(zshrc.contains("CLAUDE_CONFIG_DIR='\(resolvedHome.appendingPathComponent(".claude").path)'"))
        for variable in AccountSignInLauncher.claudeAuthEnvironmentRemovals {
            XCTAssertTrue(zshrc.contains("-u \(variable)"), "missing removal for \(variable)")
        }
        XCTAssertTrue(zshrc.contains("command claude"))
        XCTAssertFalse(zshrc.contains("cli_auth_credentials_store"))
    }

    func testZshCodexWrapperForcesTheFileCredentialStore() throws {
        let home = try makeHome()

        try AccountShellInstaller.install(family: "codex", shell: .zsh, homeDirectory: home)

        let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertTrue(zshrc.contains("CODEX_HOME='\(resolvedHome.appendingPathComponent(".codex").path)'"))
        XCTAssertTrue(zshrc.contains("command codex -c 'cli_auth_credentials_store=\"file\"'"))
        for variable in AccountSignInLauncher.codexAuthEnvironmentRemovals {
            XCTAssertTrue(zshrc.contains("-u \(variable)"), "missing removal for \(variable)")
        }
    }

    func testInstallWritesThroughAnRcFileSymlink() throws {
        let home = try makeHome()
        let dotfiles = home.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("zshrc")
        try Data("# my dotfiles\n".utf8).write(to: real)
        let link = home.appendingPathComponent(".zshrc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try AccountShellInstaller.install(family: "claude", shell: .zsh, homeDirectory: home)

        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink,
                       "the dotfiles symlink must survive the install")
        let contents = try String(contentsOf: real, encoding: .utf8)
        XCTAssertTrue(contents.contains("# my dotfiles"), "existing dotfile content is preserved")
        XCTAssertTrue(contents.contains(">>> OpenUsage claude account switching >>>"),
                      "the marker block lands in the real file behind the link")
    }

    func testFishWrapperLandsInTheUserConfigFile() throws {
        let home = try makeHome()

        try AccountShellInstaller.install(family: "claude", shell: .fish, homeDirectory: home)

        let config = try String(
            contentsOf: home.appendingPathComponent(".config/fish/config.fish"),
            encoding: .utf8
        )
        XCTAssertTrue(config.contains("function claude"))
        XCTAssertTrue(config.contains("CLAUDE_CONFIG_DIR="))
        XCTAssertTrue(config.contains("$argv"))
    }

    func testReinstallReplacesTheMarkerBlockAndPreservesOtherContent() throws {
        let home = try makeHome()
        let zshrcURL = home.appendingPathComponent(".zshrc")
        try Data("# my prompt setup\nexport EDITOR=vim\n".utf8).write(to: zshrcURL)

        try AccountShellInstaller.install(family: "claude", shell: .zsh, homeDirectory: home)
        try AccountShellInstaller.install(family: "claude", shell: .zsh, homeDirectory: home)

        let zshrc = try String(contentsOf: zshrcURL, encoding: .utf8)
        XCTAssertTrue(zshrc.contains("# my prompt setup"))
        XCTAssertTrue(zshrc.contains("export EDITOR=vim"))
        XCTAssertEqual(
            zshrc.components(separatedBy: "# >>> OpenUsage claude account switching >>>").count - 1,
            1
        )
    }

    func testFamiliesInstallSideBySide() throws {
        let home = try makeHome()

        try AccountShellInstaller.install(family: "claude", shell: .zsh, homeDirectory: home)
        try AccountShellInstaller.install(family: "codex", shell: .zsh, homeDirectory: home)

        let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        XCTAssertTrue(zshrc.contains("function claude"))
        XCTAssertTrue(zshrc.contains("function codex"))
    }

    func testInvalidExistingProfileIsNeverOverwritten() throws {
        let home = try makeHome()
        let zshrcURL = home.appendingPathComponent(".zshrc")
        let original = Data([0xFF, 0xFE, 0xFD])
        try original.write(to: zshrcURL)

        XCTAssertThrowsError(
            try AccountShellInstaller.install(family: "claude", shell: .zsh, homeDirectory: home)
        )
        XCTAssertEqual(try Data(contentsOf: zshrcURL), original)
    }

    func testOnlyZshAndFishAreSupported() {
        XCTAssertNotNil(AccountShellProfile(rawValue: "zsh"))
        XCTAssertNotNil(AccountShellProfile(rawValue: "fish"))
        XCTAssertNil(AccountShellProfile(rawValue: "bash"))
        XCTAssertNil(AccountShellProfile(rawValue: "sh"))
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AccountShellInstaller.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
}
