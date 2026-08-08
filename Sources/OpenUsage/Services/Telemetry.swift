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
        return bakedToken
    }

    /// US 리전 기본값 — EU 프로젝트 토큰일 때만 EU 리전 host로 변경.
    static let host = "https://us.i.posthog.com"
}

/// telemetry 전송 seam — PostHog에서 추상화해 recorder의 daily-rollup/dedup 로직을 fake sink로 unit-test 가능.
@MainActor
protocol TelemetrySink: AnyObject {
    func capture(_ event: String, _ properties: [String: Any])
    /// 사용자 공유 선택을 runtime에 SDK로 미러링.
    func setEnabled(_ enabled: Bool)
    func flush()
}

/// 익명·opt-in PostHog sink — `identify()`/`group()`/`alias()` 미사용, `personProfiles = .never`.
/// ID·count·enum만 전송 — free-form 에러 메시지 전송 금지(`LogRedaction`은 네트워크 transport 미적용). 실제 token 미설정 시 inert — dev 빌드의 phone home 금지.
@MainActor
final class PostHogTelemetrySink: TelemetrySink {
    /// crash/uncaught-exception autocapture는 usage telemetry와 동일한 선택으로 gate — `PostHogSDK.shared` singleton 없이 unit-test 가능하도록 여기서 결정.
    /// 전송이 아닌 install 자체를 gate — 비활성 launch는 handler 미설치·crash report 미기록.
    nonisolated static func errorAutocaptureEnabled(telemetryEnabled: Bool) -> Bool { telemetryEnabled }

    private let configured: Bool

    init(enabled: Bool, token: String = TelemetryConfig.token, host: String = TelemetryConfig.host) {
        guard token.hasPrefix("phc_"), token != TelemetryConfig.placeholderToken else {
            configured = false
            AppLog.info(.config, "telemetry inert: no PostHog project token configured")
            return
        }
        configured = true

        let config = PostHogConfig(projectToken: token, host: host)
        // 완전 익명 — person profile·anonymous→identified merge 없음.
        config.personProfiles = .never
        // feature flag 미사용·자체 daily rollup 사용 — startup fetch와 autocapture 모두 생략.
        config.preloadFeatureFlags = false
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        // 이벤트 발생 전 사용자 선택 상태로 시작.
        config.optOut = !enabled
        // crash/uncaught-exception autocapture — 동일한 공유 선택으로 install 자체를 gate: opt-out launch는 handler 미설치·디스크 기록 없음, opt-in은 다음 launch부터 활성(`optOut`은 세션 내 전송 즉시 차단).
        // 이 flag만으로 불충분 — PostHog 프로젝트 설정의 server-side "Exception autocapture" 필요, SDK가 캐시에서 읽어 두 번째 launch부터 활성.
        // sessionReplay/surveys/captureElementInteractions/tracingHeaders 참조 금지 — macOS target에 부재.
        config.errorTrackingConfig.autoCapture = Self.errorAutocaptureEnabled(telemetryEnabled: enabled)
        PostHogSDK.shared.setup(config)

        // super property는 이후 모든 이벤트에 부착 (익명, non-PII).
        PostHogSDK.shared.register([
            "app_version": AppInfo.version,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ])
        AppLog.info(.config, "telemetry initialized (enabled=\(enabled))")
    }

    func capture(_ event: String, _ properties: [String: Any]) {
        guard configured else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    func setEnabled(_ enabled: Bool) {
        guard configured else { return }
        if enabled { PostHogSDK.shared.optIn() } else { PostHogSDK.shared.optOut() }
    }

    func flush() {
        guard configured else { return }
        PostHogSDK.shared.flush()
    }
}
