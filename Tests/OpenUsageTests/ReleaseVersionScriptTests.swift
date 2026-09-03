import Foundation
import XCTest

final class ReleaseVersionScriptTests: XCTestCase {
    func testReleaseTagBecomesBundleVersion() throws {
        XCTAssertEqual(try version(for: "v0.9.5"), "0.9.5")
        XCTAssertEqual(try version(for: "v12.34.56-beta.1"), "12.34.56-beta.1")
    }

    func testRejectsTagsWithoutSemanticVersionPrefix() throws {
        for tag in ["0.9.5", "v0.9", "v0.9.5-beta..1", "v0.9.5-"] {
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
        guard let line = source.split(separator: "\n").first(where: { $0.contains("=~ ^v[0-9]") }),
              let afterOperator = line.components(separatedBy: "=~ ").last,
              let pattern = afterOperator.components(separatedBy: "]]").first
        else { return nil }

        return pattern.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Script invocation

    private func version(for tag: String) throws -> String {
        try callFunction("openusage_version_from_tag", arguments: [tag])
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
        workingDirectory: URL? = nil
    ) throws -> String {
        let output = Pipe()
        let errorOutput = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "source \"$1\" || exit 90; \(name) \"${@:2}\"",
            "release-version-test",
            Self.versionScript.path
        ] + arguments
        process.standardOutput = output
        process.standardError = errorOutput
        process.currentDirectoryURL = workingDirectory

        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let message = String(data: stderr, encoding: .utf8) ?? ""
        switch process.terminationStatus {
        case 0:
            let value = String(data: stdout, encoding: .utf8) ?? ""
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private func makeRepository(tag: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        try runGit(["init", "--quiet"], in: directory)
        try runGit([
            "-c", "user.name=OpenUsage Test",
            "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false",
            "commit", "--allow-empty", "--quiet", "--message", "seed"
        ], in: directory)
        if let tag {
            try runGit(["tag", tag], in: directory)
        }
        return directory
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VersionScriptError.scriptFailure(status: process.terminationStatus, stderr: "git \(arguments.joined(separator: " "))")
        }
    }

    private enum VersionScriptError: Error {
        case rejectedTag(String)
        case scriptFailure(status: Int32, stderr: String)
    }
}
