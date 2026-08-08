import XCTest
@testable import OpenUsage

final class GrokAuthStoreTests: XCTestCase {
    func testReadsTokenExpiryFromJWT() {
        let store = GrokAuthStore(now: { OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")! })
        let token = makeJWT(exp: 1_770_000_000)

        let expiry = store.tokenExpiresAt(token)

        XCTAssertEqual(expiry?.timeIntervalSince1970, 1_770_000_000)
    }

    func testLoadsAuthCandidatesFromGrokAuthFile() throws {
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh"}}"#
        ])
        let store = GrokAuthStore(files: files)

        let candidates = try store.loadAuthCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.token, "token")
        XCTAssertEqual(candidates.first?.entryKey, "https://auth.x.ai::client")
    }

    func testSaveRefusesToOverwriteACorruptAuthFile() throws {
        // 손상된 auth.json을 in-memory state로 조용히 재작성 금지(타 계정 entry 유실) — save()는 throw 후 file 보존
        let validJSON = #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        let files = FakeFiles([GrokAuthStore.authPath: validJSON])
        let store = GrokAuthStore(files: files, now: { OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")! })
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
