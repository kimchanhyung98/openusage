import XCTest
@testable import OpenUsage

@MainActor
final class UserFacingErrorsTests: XCTestCase {
    func testProviderErrorsKeepCanonicalTextWhileTranslatingPresentation() {
        let error = CodexUsageError.requestFailed(429)
        let snapshot = ProviderSnapshot.error(provider: CodexProvider.makeProvider(), error: error)

        XCTAssertEqual(snapshot.lines, [.badge(
            label: "Error", text: "Usage request failed (HTTP 429). Try again later.", colorHex: "#EF4444"
        )])
        XCTAssertEqual(snapshot.errorCategory, .rateLimited)
        XCTAssertEqual(L10n.withLanguage(.korean) { snapshot.errorPresentation?.localized },
                       "사용량 요청에 실패했습니다(HTTP 429). 잠시 후 다시 시도하세요.")
        XCTAssertEqual(L10n.withLanguage(.japanese) { snapshot.errorPresentation?.localized },
                       "使用量の取得に失敗しました（HTTP 429）。しばらくしてから、もう一度お試しください。")
        XCTAssertEqual(error.localizedDescription, "Usage request failed (HTTP 429). Try again later.")
    }

    func testUnknownDetailsAndUserNamesRemainVerbatim() {
        let detail = "Provider returned 50% of payload: %@ / 日本語 **name**"
        let error = NSError(domain: "Provider", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        XCTAssertEqual(L10n.withLanguage(.korean) { UserFacingErrors.message(error) }, detail)
        XCTAssertEqual(L10n.withLanguage(.japanese) { UserFacingErrors.message(KeychainError.readFailed(detail)) }, detail)
        let label = "계정 %@ **work**"
        XCTAssertEqual(L10n.withLanguage(.korean) { UserFacingErrors.message(AccountProfileError.duplicateLabel(label)) },
                       "'\(label)' 이름의 계정이 이미 있습니다. 다른 이름을 입력하세요.")
        XCTAssertEqual(AccountProfileError.duplicateLabel(label).userMessage,
                       "An account named '\(label)' already exists. Choose a different name.")
    }

    func testProcessOutputReadErrorTranslatesWithoutChangingDiagnostics() {
        let error = ProcessRunnerError.outputReadFailed
        let diagnostic = "Could not read output from the process."
        for (language, expected) in [
            (LanguageSetting.english, diagnostic),
            (.korean, "프로세스 출력을 읽을 수 없습니다."),
            (.japanese, "プロセスの出力を読み取れませんでした。")
        ] {
            L10n.withLanguage(language) {
                XCTAssertEqual(UserFacingErrors.message(error), expected)
                XCTAssertEqual(error.localizedDescription, diagnostic)
            }
        }
    }

    func testAccountImportAndRemovalErrorsTranslateWithoutChangingDiagnostics() {
        let cases: [(error: Error, korean: String, japanese: String)] = [
            (AccountCredentialImporter.ImportError.noSignIn(family: "claude"),
             "가져올 claude 로그인 정보를 찾지 못했습니다.",
             "インポートできるclaudeのログイン情報が見つかりませんでした。"),
            (AccountCredentialImporter.ImportError.identityUnreadable(family: "codex"),
             "현재 codex 로그인 정보로는 계정을 확인할 수 없어 가져올 수 없습니다.",
             "現在のcodexのログイン情報ではアカウントを特定できないため、インポートできません。"),
            (AccountCredentialImporter.ImportError.verificationFailed(family: "claude"),
             "가져온 claude 로그인 정보를 검증하지 못해 계정을 등록하지 않았습니다.",
             "インポートしたclaudeのログイン情報を検証できなかったため、アカウントは登録されませんでした。"),
            (AccountCredentialImporter.RemovalError.workspace,
             "이 계정의 로그인 작업 공간을 삭제하지 못했습니다. 계정과 저장된 인증 정보는 삭제하지 않았습니다. 다시 시도하세요.",
             "このアカウントのログイン用ワークスペースを削除できませんでした。アカウントと保存済み認証情報は削除していません。もう一度お試しください。"),
            (AccountCredentialImporter.RemovalError.snapshot,
             "키체인에 저장된 인증 정보를 삭제하지 못했습니다. 계정은 등록된 상태로 사용할 수 있으며, 삭제를 다시 시도할 수 있습니다.",
             "キーチェーンに保存された認証情報を削除できませんでした。アカウントは登録済みで使用可能な状態のため、削除を再試行できます。")
        ]
        for (error, korean, japanese) in cases {
            let diagnostic = error.localizedDescription
            XCTAssertEqual(L10n.withLanguage(.english) { UserFacingErrors.message(error) }, diagnostic)
            XCTAssertEqual(L10n.withLanguage(.korean) { UserFacingErrors.message(error) }, korean)
            XCTAssertEqual(L10n.withLanguage(.japanese) { UserFacingErrors.message(error) }, japanese)
            XCTAssertEqual(error.localizedDescription, diagnostic)
        }
    }

    func testCachedWarningPresentationSurvivesLanguageChangeAndLegacyCache() throws {
        let raw = ClaudeUsageMapper.rateLimitedWarning(retryAfterSeconds: 90)
        let snapshot = ProviderSnapshot(
            providerID: "claude", displayName: "Claude", lines: [], warning: raw,
            warningPresentation: [ClaudeUsageMapper.rateLimitedWarningPresentation(retryAfterSeconds: 90)]
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProviderSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.warning, raw)
        XCTAssertEqual(L10n.withLanguage(.english) { decoded.localizedWarning }, raw)
        XCTAssertEqual(L10n.withLanguage(.korean) { decoded.localizedWarning },
                       "Anthropic의 요청 한도로 사용량 업데이트가 제한되었습니다. 자동 및 수동 새로고침을 기다린 후 약 2분 뒤에 다시 시도합니다.")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "warningPresentation")
        let legacyDecoded = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(legacyDecoded.warning, raw)
        XCTAssertEqual(legacyDecoded.localizedWarning, raw)
    }

    func testRateLimitPresentationPreservesEnglishTimingBoundaries() {
        for seconds: Int? in [nil, 0, 1, 60, 61] {
            XCTAssertEqual(L10n.withLanguage(.english) {
                ClaudeUsageMapper.rateLimitedWarningPresentation(retryAfterSeconds: seconds).localized
            }, ClaudeUsageMapper.rateLimitedWarning(retryAfterSeconds: seconds))
        }
    }
}
