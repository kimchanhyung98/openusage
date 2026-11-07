import XCTest
@testable import Egasu

final class GrokAuthStoreTests: XCTestCase {
    func testReadsTokenExpiryFromJWT() {
        let store = GrokAuthStore(now: { EgasuISO8601.date(from: "2026-02-02T00:00:00.000Z")! })
        let token = makeJWT(exp: 1_770_000_000)

        let expiry = store.tokenExpiresAt(token)

        XCTAssertEqual(expiry?.timeIntervalSince1970, 1_770_000_000)
    }

    func testLoadsAuthCandidatesFromGrokAuthFile() throws {
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh"}}"#
        ])
        let store = GrokAuthStore(files: files, environment: FakeEnvironment())

        let candidates = try store.loadAuthCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.token, "token")
        XCTAssertEqual(candidates.first?.entryKey, "https://auth.x.ai::client")
    }

    func testBillingCandidatesExcludeAPIKeysAndOtherIssuers() throws {
        let files = FakeFiles([GrokAuthStore.authPath: #"{"xai::api_key":{"key":"api","auth_mode":"api_key"},"https://other.example::client":{"key":"other","auth_mode":"oidc","oidc_issuer":"https://other.example"},"https://auth.x.ai::legacy":{"key":"legacy"},"external":{"key":"first-party","auth_mode":"external","oidc_issuer":"https://auth.x.ai"},"mismatch":{"key":"wrong","auth_mode":"api_key","oidc_issuer":"https://auth.x.ai"}}"#])
        let store = GrokAuthStore(files: files, environment: FakeEnvironment())

        let candidates = try store.loadAuthCandidates()

        XCTAssertEqual(Set(candidates.map(\.token)), ["legacy", "first-party"])
    }

    func testUnsupportedCredentialsDoNotProduceBillingCandidates() {
        let files = FakeFiles([GrokAuthStore.authPath: #"{"xai::api_key":{"key":"api","auth_mode":"api_key"}}"#])
        let store = GrokAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertThrowsError(try store.loadAuthCandidates()) { error in
            XCTAssertEqual(error as? GrokAuthError, .invalidAuth)
        }
    }

    func testAuthPathOverridesUseTheSelectedFileForSaving() throws {
        let original = #"{"https://auth.x.ai::client":{"key":"original","custom":"keep"}}"#
        let cases: [([String: String], String)] = [
            ([:], GrokAuthStore.authPath),
            (["GROK_HOME": "/fixture/grok"], "/fixture/grok/auth.json"),
            (["GROK_HOME": "/fixture/grok", "GROK_AUTH_PATH": "/fixture/selected.json"], "/fixture/selected.json"),
            (["GROK_HOME": "", "GROK_AUTH_PATH": ""], GrokAuthStore.authPath)
        ]
        for (environment, selectedPath) in cases {
            let files = FakeFiles([
                GrokAuthStore.authPath: original,
                "/fixture/grok/auth.json": original,
                "/fixture/selected.json": original
            ])
            let store = GrokAuthStore(files: files, environment: FakeEnvironment(environment))
            var state = try XCTUnwrap(store.loadAuthCandidates().first)
            XCTAssertEqual(state.authPath, selectedPath)
            state.entry.key = "rotated"

            try store.save(state)

            let selected = try XCTUnwrap(files.files[selectedPath])
            XCTAssertEqual(GrokAuthStore.parseAuth(selected)?[state.entryKey]?.key, "rotated")
            let object = try XCTUnwrap(GrokAuthStore.parseJSONObject(selected)?[state.entryKey] as? [String: Any])
            XCTAssertEqual(object["custom"] as? String, "keep")
            for (path, contents) in files.files where path != selectedPath {
                XCTAssertEqual(contents, original, path)
            }
        }
    }

    func testSaveRefusesToOverwriteACorruptAuthFile() throws {
        // 손상된 auth.json을 in-memory state로 조용히 재작성 금지(타 계정 entry 유실) — save()는 throw 후 file 보존
        let validJSON = #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        let files = FakeFiles([GrokAuthStore.authPath: validJSON])
        let store = GrokAuthStore(files: files, environment: FakeEnvironment(), now: { EgasuISO8601.date(from: "2026-02-02T00:00:00.000Z")! })
        var state = try XCTUnwrap(store.loadAuthCandidates().first)
        state.entry.key = "rotated-token"

        // disk의 file을 손상시킨 뒤 rotation 저장 시도
        let corrupt = "{ not valid json"
        files.files[GrokAuthStore.authPath] = corrupt

        XCTAssertThrowsError(try store.save(state))
        XCTAssertEqual(files.files[GrokAuthStore.authPath], corrupt, "corrupt file must be left untouched, not clobbered")
    }
}

private func makeJWT(exp: Int) -> String {
    let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
    let payload = base64URL(Data(#"{"exp":\#(exp)}"#.utf8))
    return "\(header).\(payload).signature"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
