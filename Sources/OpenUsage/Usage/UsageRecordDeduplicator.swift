import Foundation

enum UsageRecordDeduplicator {
    private struct Session: Hashable {
        let format: String
        let id: String
    }

    private enum Identity: Hashable {
        case response(provider: String, id: String)
        case entry(session: Session, kind: String, id: String, timestamp: Date?, provider: String?)
    }

    /// 응답 ID 또는 같은 세션 계보의 항목 ID·시각으로 사본 제거. 무관한 세션의 짧은 ID는 유지.
    static func records(_ records: [UsageRecord]) -> [UsageRecord] {
        var fileSessions: [Session: Session] = [:]
        for record in records {
            if let path = record.filePath, let id = record.sessionID {
                fileSessions[Session(format: record.formatID, id: path)] = Session(format: record.formatID, id: id)
            }
        }
        var parents: [Session: Session] = [:]
        for record in records {
            guard let id = record.sessionID, let parent = record.parentSession else { continue }
            let normalized = parent.hasPrefix("/")
                ? URL(fileURLWithPath: parent).resolvingSymlinksInPath().path : parent
            let reference = Session(format: record.formatID, id: normalized)
            parents[Session(format: record.formatID, id: id)] = fileSessions[reference] ?? reference
        }

        var roots: [Session: Session] = [:]
        func root(of session: Session) -> Session {
            if let cached = roots[session] { return cached }
            var visited: Set<Session> = []
            var current = session
            while let parent = parents[current] {
                guard visited.insert(current).inserted else {
                    // 손상된 계보는 서로 다른 세션을 합칠 근거로 사용하지 않음.
                    roots[session] = session
                    return session
                }
                current = parent
            }
            roots[session] = current
            return current
        }

        var indices: [Identity: Int] = [:]
        var result: [UsageRecord] = []
        result.reserveCapacity(records.count)
        for record in records {
            let identity: Identity?
            if let provider = record.providerID, let response = record.responseID {
                identity = .response(provider: provider, id: response)
            } else if let id = record.id {
                let session = Session(
                    format: record.formatID,
                    id: record.sessionID ?? record.filePath ?? record.sourceID
                )
                identity = .entry(
                    session: root(of: session), kind: record.kind, id: id,
                    timestamp: record.timestamp, provider: record.providerID
                )
            } else {
                identity = nil
            }
            if let identity, let index = indices[identity] {
                if prefers(record, over: result[index]) { result[index] = record }
                continue
            }
            if let identity { indices[identity] = result.count }
            result.append(record)
        }
        return result
    }

    private static func prefers(_ candidate: UsageRecord, over existing: UsageRecord) -> Bool {
        if candidate.issues.count != existing.issues.count { return candidate.issues.count < existing.issues.count }
        let candidateReported = candidate.costOrigin == .reported && candidate.recordedCostUSD != nil
            && (candidate.recordedCostUSD != 0 || !candidate.zeroCostIsUnknown)
        let existingReported = existing.costOrigin == .reported && existing.recordedCostUSD != nil
            && (existing.recordedCostUSD != 0 || !existing.zeroCostIsUnknown)
        if candidateReported != existingReported { return candidateReported }
        // OMP fork가 과거 비용만 0으로 바꾼 사본보다 원본의 기록된 비용 우선.
        let candidateHasCost = (candidate.recordedCostUSD ?? 0) > 0
        let existingHasCost = (existing.recordedCostUSD ?? 0) > 0
        if candidateHasCost != existingHasCost { return candidateHasCost }
        return candidate.totalTokens > existing.totalTokens
    }
}
