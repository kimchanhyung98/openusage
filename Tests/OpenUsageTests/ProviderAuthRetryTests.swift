import XCTest
@testable import OpenUsage

final class ProviderAuthRetryTests: XCTestCase {
    private enum SampleError: Error, Equatable {
        case authExpired
        case requestFailed(Int)
    }

    private func requireSuccess(status: Int) throws {
        let response = HTTPResponse(statusCode: status, headers: [:], body: Data())
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: SampleError.authExpired,
            requestFailed: { SampleError.requestFailed($0) }
        )
    }

    func testSuccessStatusesDoNotThrow() throws {
        for status in [200, 201, 204, 299] {
            try requireSuccess(status: status)
        }
    }

    func testUnauthorizedAndForbiddenThrowAuthExpired() {
        for status in [401, 403] {
            XCTAssertThrowsError(try requireSuccess(status: status)) { error in
                XCTAssertEqual(error as? SampleError, .authExpired)
            }
        }
    }

    func testOtherNon2xxThrowRequestFailedWithStatus() {
        for status in [400, 404, 429, 500, 503] {
            XCTAssertThrowsError(try requireSuccess(status: status)) { error in
                XCTAssertEqual(error as? SampleError, .requestFailed(status))
            }
        }
    }
}
