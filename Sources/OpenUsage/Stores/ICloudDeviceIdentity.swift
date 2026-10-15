import Foundation

protocol ICloudDeviceIDStoring: Sendable {
    func readDeviceID() throws -> String?
    func writeDeviceID(_ deviceID: String) throws
}

struct KeychainICloudDeviceIDStore: ICloudDeviceIDStoring {
    private let service: String
    private let keychain: any KeychainAccessing

    init(
        keychain: any KeychainAccessing = SecurityKeychainAccessor(),
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.kimchanhyung98.openusage"
    ) {
        self.keychain = keychain
        self.service = "\(bundleIdentifier).icloud-sync-device-id.v1"
    }

    func readDeviceID() throws -> String? {
        try keychain.readAppOwnedPassword(service: service, forCurrentUser: true, allowInteraction: false)
    }

    func writeDeviceID(_ deviceID: String) throws {
        try keychain.writeAppOwnedPassword(
            service: service, value: deviceID, forCurrentUser: true, allowInteraction: false
        )
    }
}

enum ICloudDeviceIdentity {
    struct Resolution: Sendable {
        let id: String
        let error: (any Error)?
    }

    /// 응답 시간 제한이 없는 native Keychain 호출을 MainActor·cooperative executor 밖에서 실행.
    static func resolve(fallbackID: String, store: any ICloudDeviceIDStoring) async -> Resolution {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "OpenUsage.ICloudDeviceIdentity", qos: .utility).async {
                do {
                    if let stored = normalized(try store.readDeviceID()) {
                        continuation.resume(returning: Resolution(id: stored, error: nil))
                    } else {
                        try store.writeDeviceID(fallbackID)
                        continuation.resume(returning: Resolution(id: fallbackID, error: nil))
                    }
                } catch {
                    continuation.resume(returning: Resolution(id: fallbackID, error: error))
                }
            }
        }
    }

    static func normalized(_ value: String?) -> String? {
        guard let value, UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }
}
