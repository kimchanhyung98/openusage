import Foundation

/// 원격으로 보낼 작업명은 고정 enum만 허용 — 함수명·계정·입력 문자열로 생성 금지.
enum DiagnosticOperation: String, Codable, CaseIterable, Sendable {
    case providerRefresh = "provider_refresh"
    case historyScan = "history_scan"
    case credentialRefresh = "credential_refresh"
    case credentialSave = "credential_save"
    case accountAdd = "account_add"
    case accountSwitch = "account_switch"
    case accountSignIn = "account_sign_in"
    case accountRemove = "account_remove"
    case accountReconcile = "account_reconcile"
    case accountBinding = "account_binding"
    case iCloudRead = "icloud_read"
    case iCloudWrite = "icloud_write"
    case iCloudDelete = "icloud_delete"
    case iCloudIdentity = "icloud_identity"
    case tokscaleCheck = "tokscale_check"
    case tokscaleInstall = "tokscale_install"
    case tokscaleLogin = "tokscale_login"
    case tokscaleSubmit = "tokscale_submit"
    case resetWatchFetch = "reset_watch_fetch"
    case resetVoteFetch = "reset_vote_fetch"
    case resetClaim = "reset_claim"
    case postClaimRefresh = "post_claim_refresh"
    case notificationAuthorization = "notification_authorization"
    case notificationDelivery = "notification_delivery"
    case pricingLiteLLM = "pricing_litellm"
    case pricingModelsDev = "pricing_models_dev"
    case pricingSupplement = "pricing_supplement"
    case pricingCache = "pricing_cache"
    case resetCreditFetch = "reset_credit_fetch"
    case cursorPlan = "cursor_plan"
    case cursorCredits = "cursor_credits"
    case cursorBalance = "cursor_balance"
    case cursorSummary = "cursor_summary"
    case cursorFallback = "cursor_fallback"
    case providerStatus = "provider_status"
    case updateCheck = "update_check"
    case shareScreenshot = "share_screenshot"
    case shellInstall = "shell_install"
    case cliInstall = "cli_install"
    case cliRemove = "cli_remove"
    case localAPIListen = "local_api_listen"
    case localAPIRequest = "local_api_request"

    /// 계정별 성공을 다른 계정의 복구로 오인하지 않도록, 계정 비종속 작업만 복구 추적.
    var tracksRecovery: Bool {
        switch self {
        case .providerRefresh, .historyScan, .credentialRefresh, .credentialSave,
             .accountAdd, .accountSwitch, .accountSignIn, .accountRemove, .accountReconcile, .accountBinding,
             .resetClaim, .postClaimRefresh, .resetCreditFetch,
             .cursorPlan, .cursorCredits, .cursorBalance, .cursorSummary, .cursorFallback,
             .iCloudIdentity, .localAPIRequest:
            false
        case .iCloudRead, .iCloudWrite, .iCloudDelete,
             .tokscaleCheck, .tokscaleInstall, .tokscaleLogin, .tokscaleSubmit,
             .resetWatchFetch, .resetVoteFetch, .notificationAuthorization, .notificationDelivery,
             .pricingLiteLLM, .pricingModelsDev, .pricingSupplement, .pricingCache,
             .providerStatus, .updateCheck, .shareScreenshot, .shellInstall, .cliInstall, .cliRemove,
             .localAPIListen:
            true
        }
    }

    var feature: String {
        switch self {
        case .providerRefresh, .historyScan, .resetCreditFetch, .cursorPlan, .cursorCredits, .cursorBalance, .cursorSummary, .cursorFallback: "usage"
        case .credentialRefresh, .credentialSave: "authentication"
        case .accountAdd, .accountSwitch, .accountSignIn, .accountRemove, .accountReconcile, .accountBinding: "accounts"
        case .iCloudRead, .iCloudWrite, .iCloudDelete, .iCloudIdentity: "icloud"
        case .tokscaleCheck, .tokscaleInstall, .tokscaleLogin, .tokscaleSubmit: "tokscale"
        case .resetWatchFetch, .resetVoteFetch: "reset_watch"
        case .resetClaim, .postClaimRefresh: "reset_claim"
        case .notificationAuthorization, .notificationDelivery: "notifications"
        case .pricingLiteLLM, .pricingModelsDev, .pricingSupplement, .pricingCache: "pricing"
        case .providerStatus: "provider_status"
        case .updateCheck: "updates"
        case .shareScreenshot: "screenshot"
        case .shellInstall, .cliInstall, .cliRemove: "integration"
        case .localAPIListen, .localAPIRequest: "local_api"
        }
    }
}

enum DiagnosticResult: String, Codable, CaseIterable, Sendable {
    case success, failure, degraded, recovered, cancelled
    case bindingChanged = "binding_changed"
}

struct DiagnosticEvent: Codable, Sendable, Equatable {
    let operation: DiagnosticOperation
    let result: DiagnosticResult
    let category: ErrorCategory?
    let provider: String?

    init(_ operation: DiagnosticOperation, result: DiagnosticResult, category: ErrorCategory? = nil, providerID: String? = nil) {
        self.operation = operation
        self.result = result
        self.category = category
        self.provider = providerID.flatMap(TelemetryPrivacy.providerFamily)
    }

    var stateKey: String { [operation.rawValue, provider ?? "app"].joined(separator: "|") }
    var counterKey: String { [stateKey, result.rawValue, category?.rawValue ?? "none"].joined(separator: "|") }
}

/// 동의를 소유한 recorder가 구독한 동안만 전달 — 메시지·오류 객체는 콜백에 포함하지 않음.
enum AppDiagnostics {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var observer: (UUID, @Sendable (DiagnosticEvent, UUID) -> Void)?

    @discardableResult
    static func observe(_ handler: @escaping @Sendable (DiagnosticEvent, UUID) -> Void) -> UUID {
        lock.withLock {
            let id = UUID()
            observer = (id, handler)
            return id
        }
    }

    static func removeObserver(_ id: UUID) {
        lock.withLock { if observer?.0 == id { observer = nil } }
    }

    static func isCurrent(_ id: UUID) -> Bool { lock.withLock { observer?.0 == id } }

    /// 로컬 맥락·오류 코드와 익명 이벤트를 각각 한 번 기록 — 원문 오류 설명은 전달하지 않음.
    static func record(
        _ operation: DiagnosticOperation,
        result: DiagnosticResult,
        category: ErrorCategory? = nil,
        providerID: String? = nil,
        error: Error? = nil,
        localContext: String? = nil
    ) {
        let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            || (error as? CocoaError)?.code == .userCancelled
        let event = DiagnosticEvent(
            operation,
            result: cancelled ? .cancelled : result,
            category: cancelled ? nil : (category ?? error.map(ErrorCategory.classify)),
            providerID: providerID
        )
        log(event, error: error, context: localContext)
        let subscriber = lock.withLock { observer }
        if let subscriber { subscriber.1(event, subscriber.0) }
    }

    static func failure(
        _ operation: DiagnosticOperation,
        error: Error,
        providerID: String? = nil,
        localContext: String? = nil
    ) {
        record(operation, result: .failure, providerID: providerID, error: error, localContext: localContext)
    }

    private static func log(_ event: DiagnosticEvent, error: Error?, context: String?) {
        guard event.result == .failure || event.result == .degraded else { return }
        var message = "operation=\(event.operation.rawValue) result=\(event.result.rawValue) category=\(event.category?.rawValue ?? "other")"
        if let context { message += " context=\(context)" }
        if let error {
            let error = error as NSError
            message += " error_domain=\(error.domain) error_code=\(error.code)"
        }
        let tag: String
        if let provider = event.provider {
            tag = event.operation.feature == "authentication" ? LogTag.auth(provider) : LogTag.plugin(provider)
        } else {
            switch event.operation.feature {
            case "local_api": tag = LogTag.localAPI.rawValue
            case "accounts", "integration": tag = LogTag.config.rawValue
            default: tag = event.operation.feature
            }
        }
        if event.category == .notLoggedIn || event.category == .notAvailable {
            AppLog.info(tag, message)
        } else if event.result == .degraded {
            AppLog.warn(tag, message)
        } else {
            AppLog.error(tag, message)
        }
    }
}

struct FeatureDailyCounter: Codable, Sendable, Equatable {
    let day: String
    let appVersion: String
    let buildChannel: String
    let event: DiagnosticEvent
    var count = 0
    var reported = false

    var storageKey: String { [day, appVersion, buildChannel, event.counterKey].joined(separator: "|") }
}
