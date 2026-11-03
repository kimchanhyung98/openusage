import Foundation

/// 로컬 usage 파일이 새로 unreadable해질 때만 로그 — 반복 refresh는 파일이 복구 후 다시 실패할 때까지 조용.
actor UsageLogReadFailureReporter {
    typealias Warning = @Sendable (Int) -> Void

    private var failingPaths: Set<String> = []
    private let warning: Warning?
    private let logTag: String
    private let provider: String?

    init(logTag: String, warning: Warning? = nil) {
        self.logTag = logTag
        self.provider = logTag.split(separator: ":").last.flatMap { TelemetryPrivacy.providerFamily(String($0)) }
        self.warning = warning
    }

    /// 새로 실패한 경로 반환 — 호출자가 요약 경고와 같은 edge-trigger 주기(새 실패당 1회)로 per-path 상세를 로그 가능.
    @discardableResult
    func update(checkedPaths: Set<String>, failingPaths nextFailingPaths: Set<String>) -> Set<String> {
        let previouslyFailed = !failingPaths.isEmpty
        let newlyFailing = nextFailingPaths.subtracting(failingPaths)
        // 기억된 실패는 같은 경로가 다시 검사되어 성공했을 때만 해제 — 다른 batch를 본 scan은 이전 실패에 대해 아무 말도 못 함.
        failingPaths.subtract(checkedPaths)
        failingPaths.formUnion(nextFailingPaths)
        if previouslyFailed, failingPaths.isEmpty {
            AppDiagnostics.record(.historyScan, result: .success, providerID: provider)
        }
        guard !newlyFailing.isEmpty else { return [] }
        let count = newlyFailing.count
        let noun = count == 1 ? "file" : "files"
        AppDiagnostics.record(.historyScan, result: .degraded, category: .storage, providerID: provider,
                              localContext: "source=\(logTag); Could not read \(count) local usage log \(noun); skipped for this refresh")
        warning?(count)
        return newlyFailing
    }
}
