import Foundation
import XCTest
@testable import OpenUsage

enum MutationKeychainError: Error, Equatable {
    case gateTimedOut
    case injectedWrite
}

final class MutationKeychainGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Keychain operation started")
    private let semaphore = DispatchSemaphore(value: 0)

    func pause() throws {
        entered.fulfill()
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw MutationKeychainError.gateTimedOut
        }
    }

    func release() { semaphore.signal() }
}

final class GatedMutationKeychain: KeychainAccessing, @unchecked Sendable {
    enum Operation { case read, write, delete }

    struct Observation {
        var operation: Operation
        var service: String
        var value: String?
        var wasOnMainThread: Bool
        var mainActorProgressed: Bool
    }

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var gate: (Operation, String, MutationKeychainGate)?
    private var failingService: String?
    private var isRecording = false
    private var checksProgress = false
    private var recorded: [Observation] = []

    var observations: [Observation] { lock.withLock { recorded } }

    func hasRead(service: String) -> Bool {
        lock.withLock { recorded.contains { $0.operation == .read && $0.service == service } }
    }

    func gateNext(_ operation: Operation, service: String) -> MutationKeychainGate {
        let next = MutationKeychainGate()
        lock.withLock { gate = (operation, service, next) }
        return next
    }

    func failNextWrite(service: String) { lock.withLock { failingService = service } }

    func startRecording(checkMainActorProgress: Bool = false) {
        lock.withLock {
            isRecording = true
            checksProgress = checkMainActorProgress
            recorded = []
        }
    }

    func stopRecording() { lock.withLock { isRecording = false } }

    func readGenericPassword(service: String) throws -> String? {
        let value = lock.withLock { values[service] }
        try observe(.read, service: service, value: value)
        return value
    }

    func writeGenericPassword(service: String, value: String) throws {
        try observe(.write, service: service, value: value)
        try lock.withLock {
            if failingService == service {
                failingService = nil
                throw MutationKeychainError.injectedWrite
            }
            values[service] = value
        }
    }

    func deleteGenericPassword(service: String) throws {
        try observe(.delete, service: service, value: nil)
        _ = lock.withLock { values.removeValue(forKey: service) }
    }

    private func observe(_ operation: Operation, service: String, value: String?) throws {
        let (recording, progressCheck, pendingGate) = lock.withLock {
            let matchingGate = gate.flatMap { $0.0 == operation && $0.1 == service ? $0.2 : nil }
            if matchingGate != nil { gate = nil }
            return (isRecording, checksProgress, matchingGate)
        }
        if recording {
            let progress = DispatchSemaphore(value: 0)
            if progressCheck { Task { @MainActor in progress.signal() } }
            let observation = Observation(
                operation: operation, service: service, value: value,
                wasOnMainThread: Thread.isMainThread,
                mainActorProgressed: !progressCheck || progress.wait(timeout: .now() + 0.5) == .success
            )
            lock.withLock { recorded.append(observation) }
        }
        try pendingGate?.pause()
    }
}

final class GatedMutationFileManager: FileManager, @unchecked Sendable {
    private struct PendingGate {
        var path: String
        var condition: @Sendable () -> Bool
        var gate: MutationKeychainGate
    }

    private let lock = NSLock()
    private var pending: PendingGate?
    private var pendingAttributes: PendingGate?

    func gateNextFileExists(
        atPath path: String, after condition: @escaping @Sendable () -> Bool
    ) -> MutationKeychainGate {
        let gate = MutationKeychainGate()
        lock.withLock { pending = PendingGate(path: path, condition: condition, gate: gate) }
        return gate
    }

    func gateNextAttributesOfItem(
        atPath path: String, after condition: @escaping @Sendable () -> Bool
    ) -> MutationKeychainGate {
        let gate = MutationKeychainGate()
        lock.withLock { pendingAttributes = PendingGate(path: path, condition: condition, gate: gate) }
        return gate
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let gate: MutationKeychainGate? = lock.withLock {
            guard let pendingAttributes, pendingAttributes.path == path, pendingAttributes.condition() else { return nil }
            self.pendingAttributes = nil
            return pendingAttributes.gate
        }
        try gate?.pause()
        return try super.attributesOfItem(atPath: path)
    }

    override func fileExists(atPath path: String) -> Bool {
        let gate: MutationKeychainGate? = lock.withLock {
            guard let pending, pending.path == path, pending.condition() else { return nil }
            self.pending = nil
            return pending.gate
        }
        do {
            try gate?.pause()
        } catch {
            XCTFail("Timed out waiting to resume the authentication file read")
        }
        return super.fileExists(atPath: path)
    }
}
