import XCTest
@testable import OpenUsage

/// log 경로 suffix와 single-archive rotation·launch trim 검증 — 모든 file I/O는 test별 temp dir 한정
final class LogFileTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.LogFile.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    func testResolvedPathEndsWithExpectedSuffix() {
        XCTAssertTrue(
            LogFile.url.path.hasSuffix("Logs/OpenUsage/OpenUsage.log"),
            "unexpected log path: \(LogFile.url.path)"
        )
    }

    func testAdvertisedURLMatchesSharedSinkPath() {
        // 앱이 노출하는 `LogFile.url`과 shared sink의 실제 쓰기 경로 일치 — 두 경로 divergence 방지
        XCTAssertEqual(LogFile.url, LogFile.shared.fileURL)
    }

    func testAppendCreatesFileAndWritesLine() throws {
        let log = LogFile(directory: tempDir, fileName: "OpenUsage.log")
        log.open()
        log.append("2026-01-01T00:00:00Z [INFO] [config] hello")

        let fileURL = tempDir.appendingPathComponent("OpenUsage.log")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[config] hello"), contents)
        XCTAssertTrue(contents.hasSuffix("\n"))
    }

    func testRotationCreatesBackupWhenCapExceeded() throws {
        // 소형 cap fixture — 몇 줄로 rotation 유발
        let cap = 200
        let log = LogFile(directory: tempDir, fileName: "OpenUsage.log", maxBytes: cap)
        log.open()
        let line = String(repeating: "a", count: 80) // newline 포함 81 bytes
        log.append(line)
        log.append(line)
        log.append(line) // 243 > 200 → rotate 후 새 file에 기록

        let mainURL = tempDir.appendingPathComponent("OpenUsage.log")
        let archiveURL = tempDir.appendingPathComponent("OpenUsage.1.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path), "archive should exist after rotation")

        let archiveSize = (try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? Int) ?? 0
        let mainSize = (try FileManager.default.attributesOfItem(atPath: mainURL.path)[.size] as? Int) ?? 0
        XCTAssertEqual(archiveSize, 162, "archive holds the two pre-rotation lines")
        XCTAssertEqual(mainSize, 81, "fresh main file holds only the post-rotation line")
    }

    func testRotationKeepsOnlyOneArchive() throws {
        let cap = 200
        let log = LogFile(directory: tempDir, fileName: "OpenUsage.log", maxBytes: cap)
        log.open()
        let line = String(repeating: "b", count: 80)
        // rotation 2회 유발 — .1 archive 하나만 잔존
        for _ in 0..<10 { log.append(line) }

        let archiveURL = tempDir.appendingPathComponent("OpenUsage.1.log")
        let secondArchiveURL = tempDir.appendingPathComponent("OpenUsage.2.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondArchiveURL.path), "only one archive is retained")
    }

    func testLaunchTrimRotatesOversizeFileOnOpen() throws {
        let cap = 100
        let mainURL = tempDir.appendingPathComponent("OpenUsage.log")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // 이전 session이 남긴 초과 크기 file fixture
        try Data(repeating: 0x61, count: cap + 50).write(to: mainURL)

        let log = LogFile(directory: tempDir, fileName: "OpenUsage.log", maxBytes: cap)
        log.open()

        let archiveURL = tempDir.appendingPathComponent("OpenUsage.1.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path), "oversize file should be rotated on open")
        let mainSize = (try FileManager.default.attributesOfItem(atPath: mainURL.path)[.size] as? Int) ?? -1
        XCTAssertEqual(mainSize, 0, "fresh main file starts empty after launch trim")
    }
}
