import Foundation

/// 카드 귀속·가격 계산 전의 사용 기록. 대화 본문·인증 정보는 보관하지 않음.
struct UsageRecord: Codable, Sendable, Equatable {
    enum Issue: String, Codable, Sendable, Hashable {
        case invalidNumbers
        case invalidMetadata
        case unresolvedMirror
        case unsupportedPricing
    }

    enum Granularity: String, Codable, Sendable {
        case request
        case aggregate
    }

    enum CostOrigin: String, Codable, Sendable {
        case reported
        case estimated
        case creditEquivalent
    }

    var sourceID: String
    var formatID: String
    var scope: UsageHistoryDescriptor.Scope = .machineLocal
    var granularity: Granularity = .request
    var filePath: String? = nil
    var sessionID: String? = nil
    var parentSession: String? = nil
    var mirroredSessionID: String? = nil
    var id: String? = nil
    var responseID: String? = nil
    var kind: String
    var timestamp: Date? = nil
    var intervalEnd: Date? = nil
    var providerID: String? = nil
    var model: String? = nil
    var responseModel: String? = nil
    var upstreamProvider: String? = nil
    var serviceTier: String? = nil
    var tokens: TokenBreakdown? = nil
    var totalTokens: Int = 0
    var reasoningTokens: Int? = nil
    var tokensEstimated = false
    var recordedCostUSD: Double? = nil
    var costOrigin: CostOrigin = .reported
    var zeroCostIsUnknown = false
    var issues: Set<Issue> = []

    var effectiveModel: String? { responseModel ?? model }

    func overlaps(since: Date) -> Bool {
        guard let timestamp else { return true }
        guard timestamp < since else { return true }
        guard granularity == .aggregate else { return false }
        return intervalEnd.map { $0 >= since } ?? true
    }
}

/// 수집 실패와 정상적인 빈 이력을 구분하고 미귀속 기록도 보존.
struct UsageCollection: Sendable {
    var records: [UsageRecord]
    var sources: [UsageSourceState] = []

    var readFailureCount: Int { sources.reduce(0) { $0 + $1.failedStores } }
}

struct UsageSourceState: Sendable {
    enum Status: Sendable {
        case absent
        case complete
        case partial
        case failed
    }

    var sourceID: String
    var providerID: String? = nil
    var scope: UsageHistoryDescriptor.Scope = .machineLocal
    var completedStores = 0
    var failedStores = 0

    var status: Status {
        if failedStores > 0 { return completedStores > 0 ? .partial : .failed }
        return completedStores > 0 ? .complete : .absent
    }
}

protocol UsageCollecting: Sendable {
    /// nil은 취소. 정상 빈 결과와 읽기 실패는 각각 records·readFailureCount로 반환.
    func collect(since: Date) async -> UsageCollection?
    func flushCache() async
}

extension UsageCollecting {
    func flushCache() async {}
}
