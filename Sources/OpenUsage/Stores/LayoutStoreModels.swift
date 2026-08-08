/// provider와 배치된(visible) widget을 Always Visible·On Demand로 분할한 묶음 — dashboard 그룹 리스트 구동
struct ProviderGroup: Identifiable {
    let provider: Provider
    let alwaysShownWidgets: [PlacedWidget]
    let expandedWidgets: [PlacedWidget]
    var id: String { provider.id }

    /// 표시 순서의 전체 visible widget (always-shown 먼저) — 분할이 무의미한 곳에서 사용
    var widgets: [PlacedWidget] { alwaysShownWidgets + expandedWidgets }
    var hasExpandedMetrics: Bool { !expandedWidgets.isEmpty }
}

/// provider와 지원 metric 전체를 custom 순서로 Always Visible·On Demand 분할 — Customize 화면과 메뉴바 pin 그룹 구동
struct ProviderMetrics: Identifiable {
    let provider: Provider
    let alwaysShownMetrics: [WidgetDescriptor]
    let expandedMetrics: [WidgetDescriptor]
    var id: String { provider.id }

    init(provider: Provider, alwaysShownMetrics: [WidgetDescriptor], expandedMetrics: [WidgetDescriptor]) {
        self.provider = provider
        self.alwaysShownMetrics = alwaysShownMetrics
        self.expandedMetrics = expandedMetrics
    }

    /// 분할하지 않는 호출자(테스트 등)용 convenience — 전부 always-shown 처리
    init(provider: Provider, metrics: [WidgetDescriptor]) {
        self.init(provider: provider, alwaysShownMetrics: metrics, expandedMetrics: [])
    }

    /// custom 순서의 지원 metric 전체 (always-shown 먼저)
    var metrics: [WidgetDescriptor] { alwaysShownMetrics + expandedMetrics }
}

/// Customize provider 리스트(L1)의 한 row — provider와 렌더링용 파생 값 묶음
/// `ProviderMetrics`와 달리 비활성 provider도 포함해 리스트에 계속 노출
struct ProviderRow: Identifiable {
    let provider: Provider
    let isEnabled: Bool
    let metricCount: Int
    var id: String { provider.id }
}

/// Customize 내 transient pill(`LayoutStore.customizationNotice`)의 tone — 초록 성공·주황 거부
enum CustomizationNoticeTone {
    case positive
    case notice
}

/// Customize pill `TransientNotice`가 나르는 message+tone 묶음 — 두 필드 동시 clear 보장
struct CustomizationNoticeContent {
    var message: String
    var tone: CustomizationNoticeTone
}
