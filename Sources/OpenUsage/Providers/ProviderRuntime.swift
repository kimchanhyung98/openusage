import Foundation

enum ProviderRefreshContext {
    @TaskLocal static var isManual = false
}

/// 기기의 기존 credential을 읽고 provider API 응답을 UI용 `ProviderSnapshot`으로 정규화.
/// line 선택은 값의 형태 기준 — 상한 있는 값은 `.progress`, 무한 숫자는 `.values`, 상태는 `.badge`, 날짜별 추이는 `.chart`, `.text`는 로컬 API용 notice(위젯은 display text를 파싱하지 않음).
/// 실패 시 typed provider error로 `ProviderSnapshot.error(provider:error:)` 반환 — UI에 크게 표면화, telemetry는 안정적 non-PII 카테고리 보고. message-only factory는 typed error가 없을 때만.
@MainActor
protocol ProviderRuntime: AnyObject {
    var provider: Provider { get }
    var widgetDescriptors: [WidgetDescriptor] { get }

    func refresh() async -> ProviderSnapshot

    /// 이 provider의 credential이 기기에 이미 있는지 — 저렴한 로컬 전용 probe(file·keychain·SQLite, 네트워크 금지).
    /// fresh install 첫 launch에 `FirstRunSeeder`가 1회 사용. `refresh()`가 읽는 credential source를 그대로 미러링, blocking 로드는 `loadOffMainActor` 경유.
    func hasLocalCredentials() async -> Bool
}

/// blocking `Sendable` credential 로드를 MainActor 밖에서 실행.
/// auth store의 `security`·`sqlite3` CLI 읽기는 호출 스레드를 최대 ~5초씩 블록 — inline 호출 시 popover와 주기 refresh가 subprocess 시간 내내 정지(Cursor는 refresh당 수 회, 최대 ~25초). detached task로 대기를 background executor에 넘기고 즉시 await.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .utility, operation: load).value
}

/// 부재와 접근 실패를 구분하는 blocking credential 읽기의 throwing 대응판.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility, operation: load).value
}
