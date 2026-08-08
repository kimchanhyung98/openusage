import Foundation

/// 어떤 source(LS, Cloud Code models, Cloud Code buckets)든 반환한 모델 하나의 quota — pooling 전 normalize된 형태.
/// `remainingFraction`은 0…1(1 = full), quota 정보 없는 모델은 소진(0 remaining)으로 취급.
struct AntigravityModelConfig: Sendable, Equatable {
    var label: String
    var modelID: String?
    var remainingFraction: Double
    var resetTime: Date?
}

/// Antigravity quota 응답을 앱의 metric vocabulary로 변환.
/// authoritative source는 `RetrieveUserQuotaSummary` RPC(`parseQuotaSummary`): 두 pool(Gemini = "Session"/"Weekly", Claude = GPT-OSS 포함 모든 비Gemini), 각각 rolling 5시간 + weekly window — 최대 4개 meter.
/// 해당 RPC 없는 빌드는 legacy per-model endpoint로 fallback — 세분화 모델을 pool별 최저 remaining fraction의 5h meter 2개("Session", "Claude")로 축약, 5h 전용이라 weekly meter는 "No data".
enum AntigravityUsageMapper {
    /// meter로 노출 금지인 internal/중복 모델 ID. 모델 ID(LS `modelOrAlias.model`, Cloud Code `model`/key) 기준 매칭 — Cloud Code 경로는 `isInternal`도 제외.
    static let modelBlacklist: Set<String> = [
        "MODEL_CHAT_20706", "MODEL_CHAT_23310",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH", "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE", "MODEL_GOOGLE_GEMINI_2_5_PRO",
        "MODEL_PLACEHOLDER_M19", "MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M12"
    ]

    // MARK: - Quota summary (the authoritative source)

    /// `RetrieveUserQuotaSummary`가 보고하는 pool bucket 4개 — **정확한 `bucketId`로만** 매칭.
    /// 미래의 bucket(예: `gemini-image-5h`)이 조용히 pool에 합류하면 안 되고, pool identity를 `displayName`/`window`에서 추론 금지.
    static let summaryBuckets: [(bucketID: String, label: String, periodMs: Int)] = [
        ("gemini-5h", AntigravityMetric.sessionLabel, MetricPeriod.sessionMs),
        ("gemini-weekly", AntigravityMetric.weeklyLabel, MetricPeriod.weekMs),
        ("3p-5h", AntigravityMetric.claudeLabel, MetricPeriod.sessionMs),
        ("3p-weekly", AntigravityMetric.claudeWeeklyLabel, MetricPeriod.weekMs)
    ]

    /// `RetrieveUserQuotaSummary` → 최대 4개 pool meter (Session, Weekly, Claude, Claude Weekly 순). LS envelope(`{"response": {"groups": …}}`)와 bare 원격 payload(`{"groups": …}`) 모두 허용.
    /// nil은 "summary 아님"(decode 불가 body / `groups` 부재) — 호출자가 legacy endpoint로 fallback 가능. non-nil은 비어 있어도 authoritative: legacy 경로는 quota 부재를 "fully used"로 지어내므로 파싱된 summary가 흘러가면 안 됨.
    /// bucket은 관대하게 decode(잘못된 bucket 하나가 envelope를 무효화하지 않음) — `remainingFraction`이 없거나 못 쓰는 bucket은 0%/100% 조작 대신 line을 drop("No data" 행).
    static func parseQuotaSummary(_ data: Data) -> [MetricLine]? {
        guard let envelope = try? JSONDecoder().decode(QuotaSummaryEnvelope.self, from: data),
              let groups = envelope.response?.groups ?? envelope.groups
        else {
            // 호출자는 2xx body만 파싱 — decode 불가는 schema drift이므로 크게 알림.
            AppLog.warn(LogTag.plugin("antigravity"), "quota summary response has no decodable groups; treating as not-a-summary")
            return nil
        }

        var pooled: [String: (fraction: Double, resetTime: Date?)] = [:]
        for bucket in groups.flatMap({ $0.buckets ?? [] }) {
            guard let id = bucket.bucketId, summaryBuckets.contains(where: { $0.bucketID == id }) else {
                AppLog.warn(LogTag.plugin("antigravity"), "quota summary: skipping unrecognized bucket id '\(bucket.bucketId ?? "<absent>")'")
                continue
            }
            guard pooled[id] == nil else { continue } // 중복 bucket id — 첫 항목 승리
            guard let fraction = bucket.remainingFraction, fraction.isFinite else {
                AppLog.warn(LogTag.plugin("antigravity"), "quota summary: bucket '\(id)' has no usable remainingFraction; dropping its line")
                continue
            }
            pooled[id] = (fraction, bucket.resetTime.flatMap { OpenUsageISO8601.date(from: $0) })
        }

        return summaryBuckets.compactMap { spec in
            guard let entry = pooled[spec.bucketID] else { return nil }
            return line(pool: spec.label, fraction: entry.fraction, resetTime: entry.resetTime, periodMs: spec.periodMs)
        }
    }

    // MARK: - Response parsing (legacy per-model endpoints)

    /// LS `GetUserStatus` → plan 이름 + model config. body에 `userStatus` 없으면 nil.
    static func parseUserStatus(_ data: Data) -> (plan: String?, configs: [AntigravityModelConfig])? {
        guard let envelope = try? JSONDecoder().decode(LSUserStatusEnvelope.self, from: data),
              let status = envelope.userStatus
        else {
            return nil
        }
        // Windsurf에서 물려받은 `planInfo.planName`(유료 tier 전부 "Pro"로 표기)보다 Google 자체 `userTier` 우선.
        let plan = formatPlan(status.userTier?.name ?? status.planStatus?.planInfo?.planName)
        let configs = (status.cascadeModelConfigData?.clientModelConfigs ?? []).compactMap(config(fromLS:))
        return (plan, configs)
    }

    /// LS `GetCommandModelConfigs` fallback → model config만 (plan 없음). 부재 시 nil.
    static func parseCommandModelConfigs(_ data: Data) -> [AntigravityModelConfig]? {
        guard let envelope = try? JSONDecoder().decode(LSCommandConfigsEnvelope.self, from: data),
              let configs = envelope.clientModelConfigs
        else {
            return nil
        }
        return configs.compactMap(config(fromLS:))
    }

    /// Cloud Code `fetchAvailableModels` → model config (`isInternal`·빈 라벨 모델 제외).
    static func parseCloudCodeModels(_ data: Data) -> [AntigravityModelConfig] {
        guard let envelope = try? JSONDecoder().decode(CCModelsEnvelope.self, from: data),
              let models = envelope.models
        else {
            return []
        }
        return models.compactMap { key, model -> AntigravityModelConfig? in
            if model.isInternal == true { return nil }
            guard let label = (model.displayName?.nilIfEmpty) ?? (model.label?.nilIfEmpty) else { return nil }
            return config(label: label, modelID: model.model?.nilIfEmpty ?? key, quota: model.quotaInfo)
        }
    }

    /// Cloud Code `retrieveUserQuota` → raw model id(예: `gemini-3-pro-preview`)로 key된 bucket.
    static func parseQuotaBuckets(_ data: Data) -> [AntigravityModelConfig] {
        guard let envelope = try? JSONDecoder().decode(CCQuotaEnvelope.self, from: data),
              let buckets = envelope.buckets
        else {
            return []
        }
        return buckets.compactMap { bucket -> AntigravityModelConfig? in
            guard let id = bucket.modelId?.nilIfEmpty else { return nil }
            return AntigravityModelConfig(
                label: id,
                modelID: id,
                remainingFraction: bucket.remainingFraction ?? 0,
                resetTime: bucket.resetTime.flatMap { OpenUsageISO8601.date(from: $0) }
            )
        }
    }

    /// Cloud Code `loadCodeAssist` → plan 이름 (paid tier를 current tier보다 우선).
    static func parseLoadCodeAssistPlan(_ data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(CCLoadEnvelope.self, from: data) else { return nil }
        return formatPlan(envelope.paidTier?.name ?? envelope.currentTier?.name)
    }

    static func parseProject(_ data: Data) -> String? {
        (try? JSONDecoder().decode(CCLoadEnvelope.self, from: data))?.cloudaicompanionProject?.nilIfEmpty
    }

    // MARK: - Line building (legacy pooling)

    /// model config를 quota-pool meter 2개로 축약 — pool별 최저 fraction 유지, Gemini pool("Session")을 Claude보다 앞에 정렬. blacklist·빈 라벨 모델 제외.
    static func buildLines(_ configs: [AntigravityModelConfig]) -> [MetricLine] {
        var pooled: [String: (fraction: Double, resetTime: Date?)] = [:]
        for config in configs {
            let label = config.label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            if let id = config.modelID, modelBlacklist.contains(id) { continue }

            let pool = poolLabel(normalizeLabel(label))
            if let existing = pooled[pool] {
                // 최악값 승리 — 동률은 먼저 본 항목 유지.
                if config.remainingFraction < existing.fraction {
                    pooled[pool] = (config.remainingFraction, config.resetTime)
                }
            } else {
                pooled[pool] = (config.remainingFraction, config.resetTime)
            }
        }

        return pooled
            .sorted { sortKey($0.key) < sortKey($1.key) }
            .map { line(pool: $0.key, fraction: $0.value.fraction, resetTime: $0.value.resetTime, periodMs: MetricPeriod.sessionMs) }
    }

    static func line(pool: String, fraction: Double, resetTime: Date?, periodMs: Int) -> MetricLine {
        let clamped = max(0, min(1, fraction))
        let used = (1 - clamped) * 100
        return .progress(
            label: pool,
            used: used.rounded(), // 정수 percent 유지 — 새 window가 0으로 읽혀 "Not started" 동작
            limit: 100,
            format: .percent,
            resetsAt: resetTime,
            periodDurationMs: periodMs
        )
    }

    // MARK: - Pooling helpers (pure)

    /// "Gemini 3 Pro (High)" → "Gemini 3 Pro" — 끝의 괄호 variant 제거.
    static func normalizeLabel(_ label: String) -> String {
        if let range = label.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
            return String(label[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return label.trimmingCharacters(in: .whitespaces)
    }

    static func poolLabel(_ normalizedLabel: String) -> String {
        // 2026-05-19 quota 병합 이후 Pro·Flash는 한 pool — 모든 Gemini 모델(Pro, Flash, Ultra, bare 이름)은 단일 "Session" meter, Claude·GPT-OSS 등 비Gemini는 다른 pool 공유.
        normalizedLabel.lowercased().contains("gemini") ? AntigravityMetric.sessionLabel : AntigravityMetric.claudeLabel
    }

    static func sortKey(_ poolLabel: String) -> String {
        // Gemini pool("Session")을 Claude보다 앞에 — 위젯 선언 순서와 일치.
        poolLabel == AntigravityMetric.sessionLabel ? "0_\(poolLabel)" : "1_\(poolLabel)"
    }

    /// raw plan/tier 문자열을 짧은 라벨로 normalize. LS는 "Google AI Pro"(prefix 제거 후 꼬리 유지), Cloud Code는 "Gemini Code Assist in Google One AI Pro"(tier 단어 추출).
    static func formatPlan(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        if let range = trimmed.range(of: "Google AI "), range.lowerBound == trimmed.startIndex {
            return String(trimmed[range.upperBound...]).titleCased(separator: \.isWhitespace)
        }
        for keyword in ["Ultra", "Pro", "Free"] where trimmed.lowercased().contains(keyword.lowercased()) {
            return keyword
        }
        return trimmed.titleCased(separator: \.isWhitespace)
    }

    private static func config(fromLS model: LSModelConfig) -> AntigravityModelConfig? {
        config(label: model.label, modelID: model.modelOrAlias?.model, quota: model.quotaInfo)
    }

    private static func config(label: String?, modelID: String?, quota: AntigravityQuotaInfo?) -> AntigravityModelConfig? {
        guard let label = label?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return nil }
        return AntigravityModelConfig(
            label: label,
            modelID: modelID,
            remainingFraction: quota?.remainingFraction ?? 0,
            resetTime: quota?.resetTime.flatMap { OpenUsageISO8601.date(from: $0) }
        )
    }
}

// MARK: - Wire types (the documented response shapes; validated only at this boundary)

/// `RetrieveUserQuotaSummary`의 두 envelope: LS는 `{"response": {...}}`로 감싸고, 원격 Cloud Code endpoint는 bare 반환.
/// 모든 필드 optional — 필드 존재를 가정한 third-party parser들이 이미 회귀한 전례(누락 `remainingFraction`을 "full"로 기본 처리).
private struct QuotaSummaryEnvelope: Decodable {
    let response: QuotaSummaryRoot?
    let groups: [QuotaSummaryGroup]?
}

private struct QuotaSummaryRoot: Decodable {
    let groups: [QuotaSummaryGroup]?
}

private struct QuotaSummaryGroup: Decodable {
    let buckets: [QuotaSummaryBucket]?
}

/// 포함된 배열을 절대 실패시키지 않는 bucket: 잘못된 element(객체 아님, 잘못된 타입 필드)는 summary 전체를 legacy fallback으로 던지는 대신 nil 필드로 decode. mapper가 못 쓰는 bucket만 경고와 함께 drop.
private struct QuotaSummaryBucket: Decodable {
    let bucketId: String?
    let remainingFraction: Double?
    let resetTime: String?

    private enum CodingKeys: String, CodingKey { case bucketId, remainingFraction, resetTime }

    init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        bucketId = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .bucketId)) ?? nil }
        remainingFraction = container.flatMap { (try? $0.decodeIfPresent(Double.self, forKey: .remainingFraction)) ?? nil }
        resetTime = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .resetTime)) ?? nil }
    }
}

private struct AntigravityQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}

private struct LSModelConfig: Decodable {
    let label: String?
    let modelOrAlias: ModelOrAlias?
    let quotaInfo: AntigravityQuotaInfo?

    struct ModelOrAlias: Decodable { let model: String? }
}

private struct LSUserStatusEnvelope: Decodable {
    let userStatus: UserStatus?

    struct UserStatus: Decodable {
        let userTier: Tier?
        let planStatus: PlanStatus?
        let cascadeModelConfigData: CascadeData?
    }
    struct Tier: Decodable { let name: String? }
    struct PlanStatus: Decodable { let planInfo: PlanInfo? }
    struct PlanInfo: Decodable { let planName: String? }
    struct CascadeData: Decodable { let clientModelConfigs: [LSModelConfig]? }
}

private struct LSCommandConfigsEnvelope: Decodable {
    let clientModelConfigs: [LSModelConfig]?
}

private struct CCModelsEnvelope: Decodable {
    let models: [String: CCModel]?

    struct CCModel: Decodable {
        let model: String?
        let displayName: String?
        let label: String?
        let isInternal: Bool?
        let quotaInfo: AntigravityQuotaInfo?
    }
}

private struct CCLoadEnvelope: Decodable {
    let cloudaicompanionProject: String?
    let currentTier: Tier?
    let paidTier: Tier?

    struct Tier: Decodable { let name: String? }
}

private struct CCQuotaEnvelope: Decodable {
    let buckets: [Bucket]?

    struct Bucket: Decodable {
        let modelId: String?
        let remainingFraction: Double?
        let resetTime: String?
    }
}
