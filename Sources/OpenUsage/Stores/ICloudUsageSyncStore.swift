import Foundation
import Observation

struct UsageHistoryLoadResult: Sendable {
    var documents: [UsageHistoryDocument]
    var invalidFileMessages: [String]
}

protocol UsageHistoryFileStoring: Sendable {
    func loadDocuments() async throws -> UsageHistoryLoadResult
    func write(_ document: UsageHistoryDocument) async throws
    func delete(deviceID: String) async throws
}

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
        try keychain.readGenericPasswordForCurrentUser(service: service)
    }

    func writeDeviceID(_ deviceID: String) throws {
        try keychain.writeGenericPasswordForCurrentUser(service: service, value: deviceID)
    }
}

enum ICloudUsageSyncError: Error, LocalizedError {
    case unavailable
    case invalidDeviceID

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "iCloud Drive isn’t available. Check that this Mac is signed into iCloud and iCloud Drive is on."
        case .invalidDeviceID:
            "The saved iCloud sync device identifier is invalid."
        }
    }
}

/// OpenUsage iCloud Documents container의 app 전용 영역에 대한 coordinated 접근
actor ICloudUsageHistoryFileStore: UsageHistoryFileStoring {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        let directory = try historyDirectory(create: false)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return UsageHistoryLoadResult(documents: [], invalidFileMessages: [])
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        var documents: [UsageHistoryDocument] = []
        var errors: [String] = []
        for url in urls {
            do {
                let data = try coordinatedRead(url)
                let document = try decoder.decode(UsageHistoryDocument.self, from: data)
                try document.validate()
                documents.append(document)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                AppLog.warn(.config, "iCloud history ignored \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return UsageHistoryLoadResult(documents: documents, invalidFileMessages: errors)
    }

    func write(_ document: UsageHistoryDocument) async throws {
        try document.validate()
        let directory = try historyDirectory(create: true)
        let url = directory.appendingPathComponent(document.deviceID).appendingPathExtension("json")
        let data = try encoder.encode(document)
        try coordinatedWrite(data, to: url)
    }

    func delete(deviceID: String) async throws {
        guard UUID(uuidString: deviceID) != nil else {
            throw ICloudUsageSyncError.invalidDeviceID
        }
        let directory = try historyDirectory(create: false)
        let url = directory.appendingPathComponent(deviceID).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do { try FileManager.default.removeItem(at: coordinatedURL) }
            catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private func historyDirectory(create: Bool) throws -> URL {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw ICloudUsageSyncError.unavailable
        }
        let directory = container
            .appendingPathComponent("OpenUsage", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result?.get() ?? { throw CocoaError(.fileReadUnknown) }()
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try data.write(to: coordinatedURL, options: .atomic) }
            catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }
}

@MainActor
@Observable
final class ICloudUsageSyncStore {
    private static let enabledKey = "openusage.icloudSync.enabled.v1"
    private static let deviceIDKey = "openusage.icloudSync.deviceID.v1"
    private static let pendingDeletionDeviceIDKey = "openusage.icloudSync.pendingDeletionDeviceID.v1"

    private let defaults: UserDefaults
    private let fileStore: any UsageHistoryFileStoring
    private let identityError: String?
    private let dataStore: WidgetDataStore
    private let writeDebounce: Duration
    private let observesMetadataChanges: Bool
    private var writeTask: Task<Void, Never>?
    private var metadataQuery: NSMetadataQuery?
    private var notificationTokens: [NSObjectProtocol] = []
    private var syncActivityCount = 0
    private var enablementGeneration = 0

    let deviceID: String
    let deviceName: String
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            enablementGeneration &+= 1
            let generation = enablementGeneration
            let expectedEnabled = enabled
            if enabled {
                defaults.set(true, forKey: Self.enabledKey)
                clearCurrentPendingDeletionIfReenabled()
            } else {
                persistCurrentDeletionRequestForDisable()
                defaults.set(false, forKey: Self.enabledKey)
            }
            Task { await applyEnabledChange(expectedEnabled: expectedEnabled, generation: generation) }
        }
    }
    private(set) var isSyncing = false
    private var operationError: String?
    private(set) var deletionError: String?
    var serviceError: String? { deletionError ?? operationError ?? identityError }
    private(set) var invalidFileMessages: [String] = []
    private(set) var documents: [UsageHistoryDocument] = []

    init(
        dataStore: WidgetDataStore,
        defaults: UserDefaults = .standard,
        fileStore: any UsageHistoryFileStoring = ICloudUsageHistoryFileStore(),
        deviceIDStore: any ICloudDeviceIDStoring = KeychainICloudDeviceIDStore(),
        writeDebounce: Duration = .seconds(3),
        observesMetadataChanges: Bool = true
    ) {
        self.dataStore = dataStore
        self.defaults = defaults
        self.fileStore = fileStore
        self.writeDebounce = writeDebounce
        self.observesMetadataChanges = observesMetadataChanges
        let identity = Self.resolveDeviceID(defaults: defaults, store: deviceIDStore)
        self.deviceID = identity.id
        self.identityError = identity.error
        self.deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        dataStore.onLocalHistoryChanged = { [weak self] in self?.scheduleWrite() }
        if enabled {
            clearCurrentPendingDeletionIfReenabled()
            let generation = enablementGeneration
            Task { await applyEnabledChange(expectedEnabled: true, generation: generation) }
        } else if defaults.object(forKey: Self.pendingDeletionDeviceIDKey) != nil {
            let generation = enablementGeneration
            Task { await retryPendingDeletion(expectedEnabled: false, generation: generation) }
        }
    }

    private var pendingDeletionDeviceID: String? {
        defaults.string(forKey: Self.pendingDeletionDeviceIDKey)
    }

    private func clearPendingDeletion() {
        defaults.removeObject(forKey: Self.pendingDeletionDeviceIDKey)
        deletionError = nil
    }

    private func clearCurrentPendingDeletionIfReenabled() {
        guard Self.normalizedDeviceID(pendingDeletionDeviceID) == deviceID else { return }
        clearPendingDeletion()
    }

    private func persistCurrentDeletionRequestForDisable() {
        if let pendingDeviceID = Self.normalizedDeviceID(pendingDeletionDeviceID),
           pendingDeviceID != deviceID {
            return
        }
        defaults.set(deviceID, forKey: Self.pendingDeletionDeviceIDKey)
    }

    private func retryPendingDeletion(expectedEnabled: Bool, generation: Int) async {
        guard isCurrent(expectedEnabled: expectedEnabled, generation: generation) else { return }
        guard let persistedDeviceID = pendingDeletionDeviceID else {
            if defaults.object(forKey: Self.pendingDeletionDeviceIDKey) != nil {
                reportInvalidDeletionRequest()
            }
            return
        }
        guard let pendingDeviceID = Self.normalizedDeviceID(persistedDeviceID) else {
            reportInvalidDeletionRequest()
            return
        }
        await withSyncActivity {
            do {
                try await fileStore.delete(deviceID: pendingDeviceID)
                guard isCurrent(expectedEnabled: expectedEnabled, generation: generation),
                      pendingDeletionDeviceID == persistedDeviceID else {
                    if enabled {
                        await writeNow(generation: enablementGeneration)
                    }
                    return
                }
                if !expectedEnabled, pendingDeviceID != deviceID {
                    defaults.set(deviceID, forKey: Self.pendingDeletionDeviceIDKey)
                    deletionError = nil
                    await retryPendingDeletion(expectedEnabled: false, generation: generation)
                } else {
                    clearPendingDeletion()
                }
            } catch {
                guard isCurrent(expectedEnabled: expectedEnabled, generation: generation),
                      pendingDeletionDeviceID == persistedDeviceID else { return }
                reportDeletion(error, deviceID: pendingDeviceID)
            }
        }
    }

    var displayedDocuments: [UsageHistoryDocument] {
        documents.sorted { lhs, rhs in
            if lhs.deviceID == deviceID { return true }
            if rhs.deviceID == deviceID { return false }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func scheduleWrite() {
        guard enabled else { return }
        writeTask?.cancel()
        let generation = enablementGeneration
        writeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: writeDebounce)
            guard !Task.isCancelled else { return }
            await writeNow(generation: generation)
        }
    }

    private func applyEnabledChange(expectedEnabled: Bool, generation: Int) async {
        guard isCurrent(expectedEnabled: expectedEnabled, generation: generation) else { return }
        if expectedEnabled {
            startObserving()
            await retryPendingDeletion(expectedEnabled: true, generation: generation)
            guard isCurrent(expectedEnabled: true, generation: generation) else { return }
            await reload(generation: generation)
            await writeNow(generation: generation)
        } else {
            writeTask?.cancel()
            stopObserving()
            dataStore.clearPeerHistoryDocuments()
            documents = []
            invalidFileMessages = []
            operationError = nil
            await retryPendingDeletion(expectedEnabled: false, generation: generation)
        }
    }

    private func writeNow(generation: Int) async {
        guard isCurrent(expectedEnabled: true, generation: generation) else { return }
        await withSyncActivity {
            guard isCurrent(expectedEnabled: true, generation: generation) else { return }
            let document = dataStore.localHistoryDocument(
                deviceID: deviceID,
                deviceName: deviceName
            )
            do {
                try await fileStore.write(document)
            } catch {
                if isCurrent(expectedEnabled: true, generation: generation) {
                    report(error, context: "write")
                } else if !enabled {
                    persistCurrentDeletionRequestForDisable()
                    await retryPendingDeletion(expectedEnabled: false, generation: enablementGeneration)
                }
                return
            }
            guard isCurrent(expectedEnabled: true, generation: generation) else {
                if !enabled {
                    persistCurrentDeletionRequestForDisable()
                    await retryPendingDeletion(expectedEnabled: false, generation: enablementGeneration)
                }
                return
            }
            operationError = nil
            await reload(generation: generation)
        }
    }

    private func reload(generation: Int) async {
        guard isCurrent(expectedEnabled: true, generation: generation) else { return }
        let pendingAtStart = Self.normalizedDeviceID(pendingDeletionDeviceID)
        await withSyncActivity {
            do {
                let result = try await fileStore.loadDocuments()
                guard isCurrent(expectedEnabled: true, generation: generation) else { return }
                let excludedDeviceIDs = Set([
                    pendingAtStart,
                    Self.normalizedDeviceID(pendingDeletionDeviceID)
                ].compactMap { $0 })
                let visibleDocuments = result.documents.filter { document in
                    !excludedDeviceIDs.contains(document.deviceID.lowercased())
                }
                documents = UsageHistoryDocument.newestByDevice(visibleDocuments)
                invalidFileMessages = result.invalidFileMessages
                dataStore.setPeerHistoryDocuments(visibleDocuments, ownDeviceID: deviceID)
                operationError = result.invalidFileMessages.isEmpty
                    ? nil
                    : "Some synced usage data couldn’t be read. Check the log for details."
            } catch {
                if isCurrent(expectedEnabled: true, generation: generation) {
                    report(error, context: "read")
                }
            }
        }
    }

    private func withSyncActivity(_ operation: () async -> Void) async {
        syncActivityCount += 1
        isSyncing = true
        await operation()
        syncActivityCount -= 1
        isSyncing = syncActivityCount > 0
    }

    private func report(_ error: Error, context: String) {
        operationError = error.localizedDescription
        AppLog.warn(.config, "iCloud history \(context) failed: \(error.localizedDescription)")
    }

    private func reportDeletion(_ error: Error, deviceID: String) {
        deletionError = "OpenUsage couldn’t remove this Mac’s synced usage history from iCloud. "
            + "It will try again automatically."
        AppLog.warn(.config, "iCloud history delete failed for \(deviceID): \(error.localizedDescription)")
    }

    private func reportInvalidDeletionRequest() {
        deletionError = "OpenUsage couldn’t read the saved iCloud history deletion request."
        AppLog.error(.config, "iCloud history deletion request has an invalid device identifier")
    }

    private func isCurrent(expectedEnabled: Bool, generation: Int) -> Bool {
        enabled == expectedEnabled && enablementGeneration == generation
    }

    private static func resolveDeviceID(
        defaults: UserDefaults,
        store: any ICloudDeviceIDStoring
    ) -> (id: String, error: String?) {
        let saved = normalizedDeviceID(defaults.string(forKey: deviceIDKey))
        do {
            if let stored = normalizedDeviceID(try store.readDeviceID()) {
                defaults.set(stored, forKey: deviceIDKey)
                return (stored, nil)
            }

            let id = saved ?? UUID().uuidString.lowercased()
            try store.writeDeviceID(id)
            defaults.set(id, forKey: deviceIDKey)
            return (id, nil)
        } catch {
            let id = saved ?? UUID().uuidString.lowercased()
            defaults.set(id, forKey: deviceIDKey)
            let message = "OpenUsage couldn’t save this Mac’s sync identity in Keychain. "
                + "Sync may create a duplicate device if app preferences are reset."
            AppLog.warn(.keychain, "iCloud device identity failed: \(error.localizedDescription)")
            return (id, message)
        }
    }

    private static func normalizedDeviceID(_ value: String?) -> String? {
        guard let value, UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }

    private func startObserving() {
        guard observesMetadataChanges else { return }
        guard metadataQuery == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.json'", NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.metadataQuery?.enableUpdates()
                    await self.reload(generation: self.enablementGeneration)
                }
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    await self.reload(generation: self.enablementGeneration)
                }
            }
        ]
        metadataQuery = query
        query.start()
    }

    private func stopObserving() {
        metadataQuery?.stop()
        metadataQuery = nil
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens = []
    }
}
