import Foundation

/// 계정과 무관한 고정 분류만 telemetry 경계를 통과하도록 제한.
enum TelemetryPrivacy {
    static let providerFamilies: Set<String> = [
        "antigravity", "claude", "codex", "copilot", "cursor", "devin", "grok",
        "kimi", "kiro", "opencode", "openrouter", "zai",
    ]
    private static let metricNames: Set<String> = [
        "session", "weekly", "monthly", "daily", "today", "week", "month", "trend", "extra",
        "fable", "sonnet", "credits", "balance", "webSearches", "premium", "orgCredits", "orgSpend",
        "chat", "completions", "payAsYouGo", "auto", "api", "plan", "resets", "resetWatch",
        "sonnetThinking", "gptOss", "geminiPro", "geminiFlash", "geminiWeekly", "claude", "claudeWeekly",
        "rateLimitResets", "spark", "sparkWeekly", "usage", "onDemand", "requests", "yesterday", "last30", "keyLimit",
    ]

    static func providerFamily(_ cardID: String) -> String? {
        let family = ProviderAccountID.family(of: cardID)
        return providerFamilies.contains(family) ? family : nil
    }

    static func metricID(_ id: String) -> String? {
        let canonical = ProviderAccountID.canonicalMetricID(id)
        let parts = canonical.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, providerFamilies.contains(String(parts[0])), metricNames.contains(String(parts[1])) else {
            return nil
        }
        return canonical
    }

    static func properties(for event: String, source: [String: Any]) -> [String: Any]? {
        var result: [String: Any] = ["$process_person_profile": false, "$geoip_disable": true]
        for key in ["app_version", "$app_version", "$app_build", "$lib_version", "os_version", "$os_version"] {
            if let value = source[key] as? String, safeVersion(value) { result[key] = value }
        }
        if let channel = source["build_channel"] as? String,
           ["development", "stable", "beta", "unknown"].contains(channel) { result["build_channel"] = channel }
        result["$lib"] = "posthog-ios"
        result["schema_version"] = 2
        if let day = source["day"] as? String,
           day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { result["day"] = day }
        switch event {
        case "app_daily_active":
            if let id = source["install_id"] as? String, UUID(uuidString: id) != nil { result["install_id"] = id }
            result["enabled_providers"] = unique((source["enabled_providers"] as? [String] ?? []).compactMap(providerFamily))
            for key in ["enabled_metric_ids", "pinned_metric_ids", "expanded_metric_ids"] {
                result[key] = unique((source[key] as? [String] ?? []).compactMap(metricID))
            }
            if let style = source["menu_bar_style"] as? String, ["text", "bars"].contains(style) {
                result["menu_bar_style"] = style
            }
        case "provider_refresh_daily":
            guard let id = source["provider_id"] as? String, let family = providerFamily(id) else { return nil }
            result["provider_id"] = family
            let keys = ["success_count", "failure_count", "manual_refresh_count", "degraded_count",
                        "expected_failure_count", "unexpected_failure_count"]
                + ErrorCategory.allCases.map { $0.rawValue + "_failure_count" }
            for key in keys {
                if let count = source[key] as? Int, count >= 0 { result[key] = count }
            }
            result["error_categories"] = counts(source["error_categories"], allowed: Set(ErrorCategory.allCases.map(\.rawValue)))
            result["trigger_counts"] = counts(source["trigger_counts"], allowed: Set(RefreshTrigger.allCases.map(\.rawValue)))
            if let value = source["trigger_classification"] as? String, ["legacy", "explicit"].contains(value) {
                result["trigger_classification"] = value
            }
        case "feature_operation_result", "feature_operation_daily":
            guard let rawOperation = source["operation"] as? String,
                  let operation = DiagnosticOperation(rawValue: rawOperation),
                  let rawResult = source["result"] as? String,
                  DiagnosticResult(rawValue: rawResult) != nil else { return nil }
            result["feature"] = operation.feature
            result["operation"] = rawOperation
            result["result"] = rawResult
            if let category = source["error_category"] as? String,
               category == "none" || ErrorCategory(rawValue: category) != nil { result["error_category"] = category }
            if let id = source["provider_id"] as? String, let family = providerFamily(id) { result["provider_id"] = family }
            if let count = source["count"] as? Int, count >= 0 { result["count"] = count }
        case "$exception":
            result["$exception_level"] = "fatal"
            result["$exception_list"] = (source["$exception_list"] as? [[String: Any]] ?? []).prefix(8).map(exception)
            result["$debug_images"] = (source["$debug_images"] as? [[String: Any]] ?? []).prefix(256).compactMap(debugImage)
        default:
            return nil
        }
        return result
    }

    private static func exception(_ source: [String: Any]) -> [String: Any] {
        let types: Set<String> = [
            "SIGILL", "SIGTRAP", "SIGABRT", "SIGBUS", "SIGSEGV", "SIGFPE", "SIGSYS",
            "EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC", "EXC_BREAKPOINT", "EXC_CRASH",
            "NSInvalidArgumentException", "NSRangeException", "NSInternalInconsistencyException",
            "FatalError", "AssertionFailure", "PreconditionFailure", "SwiftRuntimeError",
        ]
        let type = source["type"] as? String ?? ""
        var result: [String: Any] = ["type": types.contains(type) ? type : "NativeException", "value": "Crash details redacted"]
        if let stack = source["stacktrace"] as? [String: Any], let frames = stack["frames"] as? [[String: Any]] {
            result["stacktrace"] = ["type": "raw", "frames": frames.prefix(256).map { frame in
                var safe: [String: Any] = ["platform": "apple"]
                for key in ["instruction_addr", "image_addr", "symbol_addr"] {
                    if let value = address(frame[key]) { safe[key] = value }
                }
                if let inApp = frame["in_app"] as? Bool { safe["in_app"] = inApp }
                return safe
            }]
        }
        if let mechanism = source["mechanism"] as? [String: Any], let type = mechanism["type"] as? String,
           ["nsexception", "signal", "mach_exception", "generic"].contains(type) {
            result["mechanism"] = ["type": type, "handled": false, "synthetic": false]
        }
        return result
    }

    private static func debugImage(_ source: [String: Any]) -> [String: Any]? {
        guard let id = source["debug_id"] as? String, UUID(uuidString: id) != nil,
              let imageAddress = address(source["image_addr"]) else { return nil }
        var result: [String: Any] = ["type": "macho", "debug_id": id, "image_addr": imageAddress, "code_file": "binary"]
        if let value = address(source["image_vmaddr"]) { result["image_vmaddr"] = value }
        if let size = source["image_size"] as? NSNumber { result["image_size"] = size.uint64Value }
        if let arch = source["arch"] as? String, ["arm64", "arm64e", "x86_64"].contains(arch) { result["arch"] = arch }
        return result
    }

    private static func address(_ source: Any?) -> String? {
        guard let value = source as? String,
              value.range(of: #"^0x[0-9a-fA-F]{1,16}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private static func counts(_ source: Any?, allowed: Set<String>) -> [String: Int] {
        (source as? [String: Int] ?? [:]).filter { allowed.contains($0.key) && $0.value >= 0 }
    }

    private static func safeVersion(_ value: String) -> Bool {
        value.count <= 64 && value.range(of: #"^(legacy|[0-9]+(?:\.[0-9]+){0,3}(?:-beta(?:\.[0-9]+)?)?(?:-dev(?:\.[0-9]+)?)?)$"#, options: .regularExpression) != nil
    }

    private static func unique(_ values: [String]) -> [String] { Array(Set(values)).sorted() }
}
