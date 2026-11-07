import Foundation

/// SDK의 큐·재시도와 독립적인 동의 경계 — 철회한 세션의 요청은 재활성화 후에도 재개 금지.
final class TelemetryTransport: @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private var enabled = true
    private var tasks: [UUID: URLSessionDataTask] = [:]
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        session = URLSessionHTTPClient.makeCookieFreeSession(configuration: configuration)
        TelemetryURLProtocol.register(self)
    }

    var isEnabled: Bool { lock.withLock { enabled } }

    func revoke() {
        let pending = lock.withLock {
            enabled = false
            let pending = Array(tasks.values)
            tasks.removeAll()
            return pending
        }
        TelemetryURLProtocol.unregister(id)
        pending.forEach { $0.cancel() }
        session.invalidateAndCancel()
        AppLog.info(.config, "telemetry transport revoked; pending requests cancelled")
    }

    func send(
        _ request: URLRequest,
        completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return nil }
        var outbound = request
        outbound.setValue(nil, forHTTPHeaderField: TelemetryURLProtocol.sessionHeader)
        let taskID = UUID()
        let endpoint = request.url?.path.hasPrefix("/batch") == true ? "batch" : "configuration"
        let task = session.dataTask(with: outbound) { [weak self] data, response, error in
            guard let self else { return }
            let allowed = self.lock.withLock {
                self.tasks[taskID] = nil
                return self.enabled
            }
            guard allowed else {
                completion(nil, nil, URLError(.cancelled))
                return
            }
            if let error {
                AppLog.warn(.config, "telemetry \(endpoint) transport failed (code=\((error as NSError).code)); SDK retry policy applies")
            } else if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) || http.statusCode == 304 {
                    AppLog.info(.config, "telemetry \(endpoint) HTTP response (status=\(http.statusCode))")
                } else {
                    AppLog.warn(.config, "telemetry \(endpoint) transport rejected (status=\(http.statusCode)); SDK retry policy applies")
                }
            }
            completion(data, response, error)
        }
        tasks[taskID] = task
        // revoke와 같은 lock 아래에서 시작 — 철회 완료 후 새 요청 시작 금지.
        task.resume()
        return taskID
    }

    func cancel(_ taskID: UUID) {
        let task = lock.withLock { tasks.removeValue(forKey: taskID) }
        task?.cancel()
    }
}

/// SDK 전용 session에만 설치 — provider HTTP와 CLI 통신에는 적용되지 않음.
final class TelemetryURLProtocol: URLProtocol, @unchecked Sendable {
    static let sessionHeader = "X-OpenUsage-Telemetry-Session"
    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var transports: [String: TelemetryTransport] = [:]
    private var transport: TelemetryTransport?
    private var taskID: UUID?

    static func register(_ transport: TelemetryTransport) {
        registryLock.withLock { transports[transport.id] = transport }
    }

    static func unregister(_ id: String) {
        registryLock.withLock { transports[id] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: sessionHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.sessionHeader),
              let transport = Self.registryLock.withLock({ Self.transports[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        self.transport = transport
        taskID = transport.send(request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if let data { self.client?.urlProtocol(self, didLoad: data) }
                self.client?.urlProtocolDidFinishLoading(self)
            } else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            }
        }
        if taskID == nil { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    }

    override func stopLoading() {
        if let taskID { transport?.cancel(taskID) }
    }
}
