import XCTest
@testable import OpenUsage

final class SecretCodeMatcherTests: XCTestCase {
    private let code = SecretCodeMatcher.sequence

    func testCompletesOnFinalTokenOnly() {
        var matcher = SecretCodeMatcher()
        for token in code.dropLast() {
            XCTAssertFalse(matcher.accept(token), "should not match before the final token")
        }
        XCTAssertTrue(matcher.accept(code.last!), "the final token completes the sequence")
    }

    func testExtraLeadingKeysStillMatch() {
        var matcher = SecretCodeMatcher()
        let stream: [SecretCodeKey] = [.up, .up] + code
        var matched = false
        for token in stream { matched = matcher.accept(token) }
        XCTAssertTrue(matched)
    }

    func testWrongKeyMidSequenceThenCleanEntryMatches() {
        var matcher = SecretCodeMatcher()
        _ = matcher.accept(.up)
        _ = matcher.accept(.up)
        _ = matcher.accept(.down)
        _ = matcher.accept(.left) // 오입력(.down 기대) — 진행 중단
        var matched = false
        for token in code { matched = matcher.accept(token) }
        XCTAssertTrue(matched, "a clean entry after a fumble still matches")
    }

    func testNoMatchForIncompleteSequence() {
        var matcher = SecretCodeMatcher()
        var matched = false
        for token in code.dropLast() { matched = matcher.accept(token) || matched }
        XCTAssertFalse(matched)
    }

    func testResetClearsPartialProgress() {
        var matcher = SecretCodeMatcher()
        _ = matcher.accept(.up)
        _ = matcher.accept(.up)
        matcher.reset()
        // reset 후에는 tail만으로 완성 불가
        var matched = false
        for token in code.dropFirst(2) { matched = matcher.accept(token) || matched }
        XCTAssertFalse(matched)
        matched = false
        for token in code { matched = matcher.accept(token) }
        XCTAssertTrue(matched)
    }

    func testReentryMatchesAgain() {
        var matcher = SecretCodeMatcher()
        for token in code { _ = matcher.accept(token) }
        var matched = false
        for token in code { matched = matcher.accept(token) }
        XCTAssertTrue(matched)
    }
}
