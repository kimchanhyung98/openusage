import Foundation

/// bounded metric의 burn-rate pacing — 사용량과 window 경과율로 window 종료 시점 사용량 투영.
/// meter 심각도 색, amber 상태의 spare 마커·문구, hover tooltip, "Runs out in …" 투영에 사용.
/// 순수 로직(SwiftUI 없음)으로 단위 테스트 유지; view용 문자열은 `WidgetData`가 노출.
enum Pace {
    enum Status {
        case ahead     // quota 여유 ≥10%로 종료 예상 → 파랑
        case onTrack   // 마지막 10% 이내 착지 예상 → amber
        case behind    // reset 전 한도 초과 예상 → 빨강
    }

    /// 분류와 기간 종료 시점 투영 사용량(`used`/`limit`와 같은 단위). `projectedUsage`는 tooltip 상세에 사용.
    struct Result {
        let status: Status
        let projectedUsage: Double
    }

    /// burn-rate 투영이 유의미해지는 최소 경과 시간 — 수 초의 경과로 나누는 불안정 투영 방지.
    static func minimumElapsed(periodDuration: TimeInterval) -> TimeInterval {
        max(60, periodDuration * 0.01)
    }

    /// 전체 pace 평가 — 신호가 없으면 `nil`(window 미시작, 이미 reset, 안정 투영에 너무 이른 시점).
    static func evaluate(used: Double, limit: Double, resetsAt: Date, periodDuration: TimeInterval,
                         now: Date = Date()) -> Result? {
        guard limit > 0, periodDuration > 0 else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-periodDuration))
        guard elapsed >= minimumElapsed(periodDuration: periodDuration), now < resetsAt else { return nil }

        if used <= 0 { return Result(status: .ahead, projectedUsage: 0) }   // 지출 없음 → ahead
        let projected = used / elapsed * periodDuration
        if used >= limit { return Result(status: .behind, projectedUsage: projected) } // 한도 도달 → behind

        let status: Status
        if projected <= limit * 0.9 { status = .ahead }      // 투영 여유 ≥10%
        else if projected <= limit { status = .onTrack }     // 마지막 10% 이내 착지
        else { status = .behind }
        return Result(status: status, projectedUsage: projected)
    }

    /// quota 소진까지의 투영 초 — `behind`이면서 run-out이 window reset 전에 도달할 때만 값 반환.
    static func secondsToRunOut(used: Double, limit: Double, resetsAt: Date, periodDuration: TimeInterval,
                                now: Date = Date()) -> TimeInterval? {
        guard let result = evaluate(used: used, limit: limit, resetsAt: resetsAt,
                                    periodDuration: periodDuration, now: now),
              result.status == .behind else { return nil }
        let rate = result.projectedUsage / periodDuration   // 현재 burn rate 기준 초당 사용량
        guard rate > 0 else { return nil }
        let eta = (limit - used) / rate                      // 남은 quota 소진까지의 초
        let remaining = resetsAt.timeIntervalSince(now)
        guard eta > 0, eta < remaining else { return nil }
        return eta
    }
}
