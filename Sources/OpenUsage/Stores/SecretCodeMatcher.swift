import Foundation

/// secret transparency code의 인식 key 1개 — 순수 token으로 AppKit 비의존, `NSEvent` 매핑은 `TooMuchTransparencyKeyReader` 담당
enum SecretCodeKey: Equatable, Sendable {
    case up, down, left, right, a, b
}

/// key token stream에서 secret code(↑ ↑ ↓ ↓ ← → ← → B A) 매칭 — 순수 값 타입, UI 없음
/// overlapping sliding window로 선행 잡음 key 허용, 완성 keystroke에서만 `true` 후 buffer 초기화 (재입력 toggle 지원)
struct SecretCodeMatcher {
    static let sequence: [SecretCodeKey] = [.up, .up, .down, .down, .left, .right, .left, .right, .b, .a]

    private let target: [SecretCodeKey]
    private var buffer: [SecretCodeKey] = []

    init(target: [SecretCodeKey] = SecretCodeMatcher.sequence) {
        self.target = target
    }

    /// token 1개 입력 — 이 token이 전체 sequence를 완성할 때만 `true`
    mutating func accept(_ token: SecretCodeKey) -> Bool {
        buffer.append(token)
        if buffer.count > target.count {
            buffer.removeFirst(buffer.count - target.count)
        }
        guard buffer == target else { return false }
        buffer.removeAll(keepingCapacity: true)
        return true
    }

    /// 부분 진행 폐기 — sequence 밖 key가 흐름을 끊을 때 사용
    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}
