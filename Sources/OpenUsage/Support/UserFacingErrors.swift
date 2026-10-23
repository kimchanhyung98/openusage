import Foundation

/// 원문 데이터·로그 계약을 유지한 채 표시 시점에 선택 언어로 변환할 문구와 인자.
struct LocalizedMessage: Hashable, Sendable, Codable {
    let key: String
    var table: String = "Errors"
    var arguments: [String] = []
    private var isVerbatim = false

    init(_ key: String, _ arguments: [String] = [], table: String = "Errors") {
        self.key = key
        self.arguments = arguments
        self.table = table
    }

    static func verbatim(_ message: String) -> Self {
        var result = Self(message)
        result.isVerbatim = true
        return result
    }

    var localized: String {
        isVerbatim ? key : L10n.string(key, table: table, arguments: arguments)
    }
}

protocol UserPresentableError: Error {
    var presentationMessage: LocalizedMessage { get }
}

enum UserFacingErrors {
    static func presentation(_ error: Error) -> LocalizedMessage {
        (error as? UserPresentableError)?.presentationMessage ?? .verbatim(error.localizedDescription)
    }

    static func message(_ error: Error) -> String {
        presentation(error).localized
    }
}

extension KeychainError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .accessBusy:
            .init("Keychain is busy. Respond to the open Keychain dialog, then try again.")
        case .invalidData:
            .init("The saved Keychain data is invalid.")
        case .writeFailed(let message):
            message.isEmpty ? .init("Keychain write failed.") : .verbatim(message)
        case .readFailed(let message):
            message.isEmpty ? .init("Keychain read failed.") : .verbatim(message)
        case .deleteFailed(let message):
            message.isEmpty ? .init("Keychain delete failed.") : .verbatim(message)
        }
    }
}
