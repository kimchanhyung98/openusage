import SwiftUI

/// popover의 page tray와 grouped card가 base를 칠하는 방식.
/// `.opaque`가 기본(windowless `ShareCardView` export 포함); 값은 `PopoverTransparencyStore.surfaceTreatment`가 공급.
enum PopoverSurfaceTreatment: Equatable, Sendable {
    /// 불투명 tray·card base의 solid panel.
    case opaque
    /// page base를 비워 behind-window vibrancy backdrop이 비침; card는 가독성을 위해 frosted `.regularMaterial`로 교체.
    /// Increase Transparency·party·drunk가 공유.
    case translucent
}

private struct PopoverSurfaceTreatmentKey: EnvironmentKey {
    static let defaultValue: PopoverSurfaceTreatment = .opaque
}

extension EnvironmentValues {
    var popoverSurfaceTreatment: PopoverSurfaceTreatment {
        get { self[PopoverSurfaceTreatmentKey.self] }
        set { self[PopoverSurfaceTreatmentKey.self] = newValue }
    }
}
