import Foundation
import XCTest

final class ReleaseVersionScriptTests: XCTestCase {
    func testReleaseTagBecomesBundleVersion() throws {
        XCTAssertEqual(try version(for: "v0.9.5"), "0.9.5")
        XCTAssertEqual(try version(for: "v12.34.56-beta.1"), "12.34.56-beta.1")
    }

    func testRejectsTagsWithoutSemanticVersionPrefix() throws {
        for tag in [
            "0.9.5", "v0.9", "v0.9.5-beta..1", "v0.9.5-",
            "v0.6.29", "v0.5.0", "v0.10.0-rc.1", "v01.2.3", "v1.02.3",
            "v1.2.03", "v1.2.3-beta.01", "v1.2.3-beta.0"
        ] {
            XCTAssertThrowsError(try version(for: tag), "expected \(tag) to be rejected") { error in
                guard case VersionScriptError.rejectedTag = error else {
                    return XCTFail("expected a rejection for \(tag), got \(error)")
                }
            }
        }
    }

    func testDevelopmentVersionReadsTheGivenWorktreeNotTheWorkingDirectory() throws {
        // 전달받은 worktree와 현재 디렉터리 사용을 구분하기 위한 두 저장소.
        let target = try makeRepository(tag: "v9.9.9")
        let elsewhere = try makeRepository(tag: "v1.1.1")

        XCTAssertEqual(
            try developmentVersion(repositoryDirectory: target, workingDirectory: elsewhere),
            "9.9.9-dev"
        )
    }

    func testScratchRepositoryHelpersIgnoreInheritedHookGitEnvironment() throws {
        let cleanEnvironment = ["PATH": "/usr/bin:/bin"]
        let outside = try makeRepository(tag: "v1.1.1", environment: cleanEnvironment)
        let originalBranch = try runGit(["symbolic-ref", "HEAD"], in: outside, environment: cleanEnvironment)
        let originalRefs = try runGit(["show-ref"], in: outside, environment: cleanEnvironment)
        let index = outside.appendingPathComponent(".git/index")
        try runGit(["read-tree", "HEAD"], in: outside, environment: cleanEnvironment)
        let originalIndex = try Data(contentsOf: index)
        var hookEnvironment = cleanEnvironment
        hookEnvironment["GIT_DIR"] = outside.appendingPathComponent(".git").path
        hookEnvironment["GIT_COMMON_DIR"] = outside.appendingPathComponent(".git").path
        hookEnvironment["GIT_WORK_TREE"] = outside.path
        hookEnvironment["GIT_INDEX_FILE"] = index.path
        hookEnvironment["GIT_PREFIX"] = "hook/"
        hookEnvironment["GIT_AUTHOR_NAME"] = "Inherited Hook Author"
        hookEnvironment["GIT_AUTHOR_EMAIL"] = "hook@example.com"
        hookEnvironment["GIT_COMMITTER_NAME"] = "Inherited Hook Committer"
        hookEnvironment["GIT_COMMITTER_EMAIL"] = "hook@example.com"
        hookEnvironment["GIT_CONFIG_COUNT"] = "1"
        hookEnvironment["GIT_CONFIG_KEY_0"] = "user.name"
        hookEnvironment["GIT_CONFIG_VALUE_0"] = "Inherited Config Author"

        let target = try makeRepository(tag: "v9.9.9", environment: hookEnvironment)

        XCTAssertEqual(try callFunction(
            "openusage_development_version",
            arguments: [target.path],
            workingDirectory: outside,
            environment: hookEnvironment
        ), "9.9.9-dev")
        XCTAssertEqual(try runGit(
            ["log", "-1", "--format=%an|%ae|%cn|%ce"], in: target, environment: cleanEnvironment
        ), "OpenUsage Test|test@example.com|OpenUsage Test|test@example.com")
        XCTAssertEqual(try runGit(["symbolic-ref", "HEAD"], in: outside, environment: cleanEnvironment), originalBranch)
        XCTAssertEqual(try runGit(["show-ref"], in: outside, environment: cleanEnvironment), originalRefs)
        XCTAssertEqual(try Data(contentsOf: index), originalIndex)
    }

    func testWorktreePreCommitUsesForeignRepositoryAndRejectsFailedChecks() throws {
        let repository = try makeRepository(tag: nil)
        let dependency = try makeRepository(tag: nil)
        try runGit(["config", "test.repository-marker", "dependency"], in: dependency)
        let worktree = repository.appendingPathComponent("linked-worktree")
        try runGit(["worktree", "add", "--quiet", "-b", "hook-check", worktree.path], in: repository)
        let hooks = worktree.appendingPathComponent(".husky")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        try FileManager.default.copyItem(at: Self.repositoryRoot.appendingPathComponent(".husky/pre-commit"), to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try runGit(["config", "core.hooksPath", ".husky"], in: repository)
        let makefile = worktree.appendingPathComponent("Makefile")
        try """
        check:
        \t@test "$$(git -C \"$(DEPENDENCY)\" config --local test.repository-marker)" = dependency

        """.write(to: makefile, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["DEPENDENCY"] = dependency.path
        let originalMain = try runGit(["rev-parse", "HEAD"], in: repository)
        let originalDependencyRefs = try runGit(["show-ref"], in: dependency)
        let originalDependencyConfig = try Data(contentsOf: dependency.appendingPathComponent(".git/config"))
        try runGit(["add", "Makefile", ".husky/pre-commit"], in: worktree)

        try runGit([
            "-c", "user.name=OpenUsage Test", "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "check foreign repository"
        ], in: worktree, environment: environment)

        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], in: repository), originalMain)
        XCTAssertEqual(try runGit(["show-ref"], in: dependency), originalDependencyRefs)
        XCTAssertEqual(try Data(contentsOf: dependency.appendingPathComponent(".git/config")), originalDependencyConfig)
        let checkedHead = try runGit(["rev-parse", "HEAD"], in: worktree)
        XCTAssertNotEqual(checkedHead, originalMain)
        try "check:\n\t@exit 42\n".write(to: makefile, atomically: true, encoding: .utf8)
        try runGit(["add", "Makefile"], in: worktree)
        let stagedFiles = try runGit(["ls-files", "--stage"], in: worktree)

        XCTAssertThrowsError(try runGit([
            "-c", "user.name=OpenUsage Test", "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "reject failed check"
        ], in: worktree, environment: environment))
        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], in: worktree), checkedHead)
        XCTAssertEqual(try runGit(["ls-files", "--stage"], in: worktree), stagedFiles)
    }

    func testDevelopmentVersionFailsWhenTheNearestTagIsMalformed() throws {
        let repository = try makeRepository(tag: "v9.9")

        XCTAssertThrowsError(try developmentVersion(repositoryDirectory: repository)) { error in
            guard case VersionScriptError.rejectedTag = error else {
                return XCTFail("expected a rejection, got \(error)")
            }
        }
    }

    func testDevelopmentVersionFallsBackWhenTheWorktreeHasNoTags() throws {
        let repository = try makeRepository(tag: nil)

        XCTAssertEqual(try developmentVersion(repositoryDirectory: repository), "0.0.0-dev")
    }

    func testDevelopmentVersionRejectsAnUnusableRepository() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try developmentVersion(repositoryDirectory: missing)) { error in
            guard case VersionScriptError.scriptFailure = error else {
                return XCTFail("expected a Git failure, got \(error)")
            }
        }
    }

    func testDevelopmentVersionRejectsLegacyTags() throws {
        let repository = try makeRepository(tag: "v0.6.28")
        XCTAssertThrowsError(try developmentVersion(repositoryDirectory: repository)) { error in
            guard case VersionScriptError.rejectedTag = error else {
                return XCTFail("expected a legacy tag rejection, got \(error)")
            }
        }
    }

    func testReleaseTagMustExistAndMatchMainHistory() throws {
        let repository = try makeRepository(tag: "v0.9.5")
        try runGit(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repository)
        XCTAssertEqual(try verifiedReleaseVersion("v0.9.5", in: repository), "0.9.5")
        try runGit(["-c", "user.name=OpenUsage Test", "-c", "user.email=test@example.com",
                    "tag", "-a", "v0.9.6-beta.1", "-m", "beta"], in: repository)
        XCTAssertEqual(try verifiedReleaseVersion("v0.9.6-beta.1", in: repository), "0.9.6-beta.1")
        try runGit(["branch", "v0.9.7"], in: repository)
        XCTAssertThrowsError(try verifiedReleaseVersion("v0.9.7", in: repository)) { error in
            guard case VersionScriptError.scriptFailure(status: 2, stderr: _) = error else {
                return XCTFail("expected a missing tag failure, got \(error)")
            }
        }
        try runGit(["-c", "user.name=OpenUsage Test", "-c", "user.email=test@example.com",
                    "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "unmerged"], in: repository)
        XCTAssertThrowsError(try verifiedReleaseVersion("v0.9.5", in: repository)) { error in
            guard case VersionScriptError.scriptFailure(status: 2, stderr: _) = error else {
                return XCTFail("expected a mismatched HEAD failure, got \(error)")
            }
        }
        try runGit(["tag", "v0.9.8"], in: repository)
        XCTAssertThrowsError(try verifiedReleaseVersion("v0.9.8", in: repository)) { error in
            guard case VersionScriptError.scriptFailure(status: 2, stderr: _) = error else {
                return XCTFail("expected an off-main tag failure, got \(error)")
            }
        }
    }

    /// checkout된 트리 의존을 피하려고 workflow에 복제한 패턴과 원본의 불일치 감지.
    func testReleaseWorkflowTagPatternMatchesTheScript() throws {
        let script = try String(contentsOf: Self.versionScript, encoding: .utf8)
        let workflow = try String(contentsOf: Self.releaseWorkflow, encoding: .utf8)

        let pattern = try XCTUnwrap(
            Self.tagPattern(in: script),
            "no tag pattern found in script/version.sh"
        )
        XCTAssertEqual(
            Self.tagPattern(in: workflow),
            pattern,
            "the tag pattern in .github/workflows/release.yml drifted from script/version.sh"
        )
    }

    /// `[[ ... =~ <pattern> ]]` 한 줄에서 pattern 추출.
    private static func tagPattern(in source: String) -> String? {
        guard let line = source.split(separator: "\n").first(where: { $0.contains("=~ ^v") }),
              let afterOperator = line.components(separatedBy: "=~ ").last,
              let pattern = afterOperator.components(separatedBy: "]]").first
        else { return nil }

        return pattern.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Script invocation

    private func version(for tag: String) throws -> String {
        try callFunction("openusage_version_from_tag", arguments: [tag])
    }

    private func verifiedReleaseVersion(_ tag: String, in repository: URL) throws -> String {
        try callFunction("openusage_release_version", arguments: [repository.path, tag])
    }

    private func developmentVersion(
        repositoryDirectory: URL,
        workingDirectory: URL? = nil
    ) throws -> String {
        try callFunction(
            "openusage_development_version",
            arguments: [repositoryDirectory.path],
            workingDirectory: workingDirectory
        )
    }

    /// version.sh를 source해 함수 하나를 호출하고 script 실패와 입력 거부를 구분.
    private func callFunction(
        _ name: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "source \"$1\" || exit 90; \(name) \"${@:2}\"",
            "release-version-test",
            Self.versionScript.path
        ] + arguments
        process.standardOutput = output
        // 단일 pipe로 두 출력을 함께 비워 진단 출력 폭주에 의한 교착 방지.
        process.standardError = output
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.gitEnvironment(environment)

        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let message = String(data: stdout, encoding: .utf8) ?? ""
        switch process.terminationStatus {
        case 0:
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        case 1:
            throw VersionScriptError.rejectedTag(message)
        default:
            throw VersionScriptError.scriptFailure(status: process.terminationStatus, stderr: message)
        }
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let versionScript = repositoryRoot.appendingPathComponent("script/version.sh")

    private static let releaseWorkflow = repositoryRoot.appendingPathComponent(".github/workflows/release.yml")

    // MARK: - Scratch repositories

    /// 전역·system git 설정을 무시하고 태그 하나를 가진 임시 저장소 생성.
    private func makeRepository(
        tag: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        try runGit(["init", "--quiet"], in: directory, environment: environment)
        try runGit([
            "-c", "user.name=OpenUsage Test",
            "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false",
            "commit", "--allow-empty", "--quiet", "--message", "seed"
        ], in: directory, environment: environment)
        if let tag {
            try runGit(["tag", tag], in: directory, environment: environment)
        }
        return directory
    }

    @discardableResult
    private func runGit(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = Self.gitEnvironment(environment)
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw VersionScriptError.scriptFailure(status: process.terminationStatus, stderr: "git \(arguments.joined(separator: " ")): \(message)")
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// hook의 저장소 경로·index·작성자·주입 설정을 제거하고 나머지 환경은 유지.
    private static func gitEnvironment(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        return environment
    }

    private enum VersionScriptError: Error {
        case rejectedTag(String)
        case scriptFailure(status: Int32, stderr: String)
    }
}
