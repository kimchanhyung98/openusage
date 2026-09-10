import Foundation
import PostHog

/// PostHog 프로젝트의 build-time 설정.
/// project token은 client-side write-only 키 — commit 안전, `OPENUSAGE_POSTHOG_TOKEN` 환경 override 지원. host는 region 종속 — US token은 EU host에 ingest 불가.
enum TelemetryConfig {
    /// "실제 token 미설정" sentinel — 해석된 token이 이 값이면 sink는 inert(설정·네트워크 없음). 값 변경 금지.
    static let placeholderToken = "phc_REPLACE_ME"

    /// 빌드에 포함되는 project token — commit 안전한 client write-only 키; 로컬 테스트는 `OPENUSAGE_POSTHOG_TOKEN` 사용.
    private static let bakedToken = "phc_tRD4fSrpb2bgA3xYLqCkLsZ9YSGQckuKNB5BBnRm7DCL"

    static var token: String {
        let env = ProcessInfo.processInfo.environment["OPENUSAGE_POSTHOG_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty { return env }
        if buildChannel == "development" { return placeholderToken }
        return bakedToken
    }

    static var buildChannel: String {
        #if DEBUG
        return "development"
        #else
        if AppInfo.version.contains("dev") { return "development" }
        return AppInfo.version.contains("beta") ? "beta" : "stable"
        #endif
    }

    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// US 리전 기본값 — EU 프로젝트 토큰일 때만 EU 리전 host로 변경.
    static let host = "https://us.i.posthog.com"
}

/// telemetry 전송 seam — PostHog에서 추상화해 recorder의 daily-rollup/dedup 로직을 fake sink로 unit-test 가능.
@MainActor
protocol TelemetrySink: AnyObject {
    var isAvailable: Bool { get }
    func capture(_ event: String, _ properties: [String: Any])
    /// 사용자 공유 선택을 runtime에 SDK로 미러링.
    func setEnabled(_ enabled: Bool)
    func flush()
}

extension TelemetrySink {
    var isAvailable: Bool { true }
}

/// 익명 opt-in 전송 — 동의가 없으면 SDK 자체를 시작하지 않음.
@MainActor
final class PostHogTelemetrySink: TelemetrySink {
    nonisolated static func errorAutocaptureEnabled(telemetryEnabled: Bool) -> Bool { telemetryEnabled }

    private let token: String
    private let host: String
    private let storage: TelemetrySDKStorage
    private let sessionConfiguration: () -> URLSessionConfiguration
    private let flushInterval: TimeInterval
    private let consentID: () -> String
    private let crashConsentStartedAt: () -> Date
    private var mustDiscardPending: Bool
    private var sdk: PostHogSDK?
    private var transport: TelemetryTransport?
    private var enabled = false

    var isAvailable: Bool { enabled && sdk != nil }

    init(
        enabled: Bool,
        token: String = TelemetryConfig.token,
        host: String = TelemetryConfig.host,
        crashConsentStartedAt: @escaping () -> Date = Date.init,
        consentID: @escaping () -> String = { UUID().uuidString },
        sessionConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral },
        flushInterval: TimeInterval = 30
    ) {
        self.token = token
        self.host = host
        self.storage = TelemetrySDKStorage(token: token)
        self.consentID = consentID
        self.crashConsentStartedAt = crashConsentStartedAt
        self.mustDiscardPending = !enabled
        self.sessionConfiguration = sessionConfiguration
        self.flushInterval = flushInterval
        guard isConfigured else {
            AppLog.info(.config, "telemetry inert: no PostHog project token configured")
            return
        }
        if enabled { setEnabled(true) }
        else { discardPendingEvents() }
    }

    private var isConfigured: Bool {
        token != TelemetryConfig.placeholderToken
            && token.range(of: #"^phc_[A-Za-z0-9_]+$"#, options: .regularExpression) != nil
    }

    func capture(_ event: String, _ properties: [String: Any]) {
        guard isAvailable else { return }
        let properties = properties.merging([
            "app_version": AppInfo.version,
            "os_version": TelemetryConfig.osVersion,
            "build_channel": TelemetryConfig.buildChannel,
        ]) { current, _ in current }
        sdk?.capture(event, properties: properties)
        AppLog.debug(.config, "telemetry event submitted to SDK")
    }

    func setEnabled(_ enabled: Bool) {
        guard isConfigured, self.enabled != enabled else { return }
        if !enabled {
            self.enabled = false
            mustDiscardPending = true
            transport?.revoke()
            sdk?.optOut()
            sdk?.close()
            sdk = nil
            transport = nil
            discardPendingEvents()
            return
        }
        do {
            if mustDiscardPending { try storage.discardQueues() }
            try storage.prepare()
            mustDiscardPending = false
        }
        catch {
            AppLog.error(.config, "telemetry disabled: pending queue privacy migration failed")
            return
        }
        let transport = TelemetryTransport(configuration: sessionConfiguration())
        let config = PostHogConfig(projectToken: token, host: host)
        config.personProfiles = .never
        config.preloadFeatureFlags = false
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.optOut = false
        config.flushIntervalSeconds = flushInterval
        config.errorTrackingConfig.autoCapture = Self.errorAutocaptureEnabled(telemetryEnabled: true)
        let sdkSession = URLSessionConfiguration.ephemeral
        sdkSession.protocolClasses = [TelemetryURLProtocol.self]
        sdkSession.httpAdditionalHeaders = [TelemetryURLProtocol.sessionHeader: transport.id]
        config.urlSessionConfiguration = sdkSession
        let consentStart = crashConsentStartedAt()
        let consentID = consentID()
        config.setBeforeSend { event in
            guard transport.isEnabled,
                  event.event != "$exception" || Self.crashBelongsToConsent(properties: event.properties, timestamp: event.timestamp, consentID: consentID, since: consentStart) else { return nil }
            var source = event.properties
            if event.event == "$exception" {
                for key in ["app_version", "os_version", "build_channel"] {
                    source[key] = source["openusage_crash_" + key] ?? source[key]
                }
            }
            guard let properties = TelemetryPrivacy.properties(for: event.event, source: source) else { return nil }
            event.properties = properties
            return event
        }
        self.transport = transport
        self.enabled = true
        let sdk = PostHogSDK.with(config)
        // SDK의 과거 optOut 파일보다 앱의 전용 동의 저장소가 우선.
        sdk.optIn()
        // SDK super property는 호출자의 집계 버전을 덮어쓰므로 과거 등록값 제거.
        for key in ["app_version", "os_version", "build_channel"] { sdk.unregister(key) }
        // 크래시 시점의 동의 구간을 로컬 report에 stamp — beforeSend가 항상 제거.
        sdk.register([
            "openusage_consent_id": consentID,
            "openusage_crash_app_version": AppInfo.version,
            "openusage_crash_os_version": TelemetryConfig.osVersion,
            "openusage_crash_build_channel": TelemetryConfig.buildChannel,
        ])
        self.sdk = sdk
        AppLog.info(.config, "telemetry initialized; crash autocapture requested (remote configuration and debugger dependent)")
    }

    nonisolated static func crashBelongsToConsent(
        properties: [String: Any], timestamp: Date, consentID: String, since: Date
    ) -> Bool {
        // PLCrashReporter의 정수 초 크래시 시각에 맞춰 동의 시작도 같은 정밀도로 비교.
        let consentStart = Date(timeIntervalSince1970: since.timeIntervalSince1970.rounded(.down))
        return properties["openusage_consent_id"] as? String == consentID && timestamp >= consentStart
    }

    func flush() {
        guard isAvailable else { return }
        sdk?.flush()
    }

    private func discardPendingEvents() {
        do {
            try storage.discardQueues()
            AppLog.info(.config, "telemetry pending queues discarded")
        } catch {
            AppLog.error(.config, "telemetry queue cleanup failed; transport remains disabled")
        }
    }
}
