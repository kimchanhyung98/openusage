import AppKit
import SwiftUI

/// `ShareCardView`를 PNG로 렌더해 clipboard에 복사.
/// `MenuBarStripRenderer`와 같은 `ImageRenderer` → `cgImage` → `NSImage` 경로(×4) 후 PNG 인코딩·pasteboard 기록.
@MainActor
enum ShareCardRenderer {
    /// off-screen 렌더 배율 — ×4로 popover 스케일 카드가 별도 대형 레이아웃 없이 crisp한 대형 PNG(360pt → 1440px)가 됨.
    static let scale: CGFloat = 4

    /// 카드의 `NSImage` 렌더 — `ImageRenderer`가 CGImage를 못 만들면 `nil`. point 크기는 카드 자연 크기, pixel 크기는 ×`scale`.
    static func image<Card: View>(for view: Card) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        )
    }

    /// `NSImage`의 PNG 인코딩 — bitmap 형성 실패 시 `nil`.
    static func pngData(from image: NSImage) -> Data? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 카드 PNG를 general pasteboard에 기록(기존 내용 대체). 인코딩·기록 실패 시 beep + 로그로 조용한 실패 방지.
    /// PNG가 실제로 pasteboard에 실렸을 때만 `true` — 호출자의 성공 확인 gate용.
    @discardableResult
    static func copyToPasteboard(_ image: NSImage, pasteboard: NSPasteboard = .general) -> Bool {
        guard let png = pngData(from: image) else {
            AppLog.error(.lifecycle, "share card: failed to encode PNG for clipboard")
            NSSound.beep()
            return false
        }
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else {
            AppLog.error(.lifecycle, "share card: pasteboard rejected the PNG")
            NSSound.beep()
            return false
        }
        return true
    }

    /// Share Screenshot 액션의 end-to-end 오케스트레이션: 표시 중인 row 해석 → 카드 빌드 → 렌더 → clipboard 복사.
    /// row는 대시보드 표시와 동일(always-shown + caret이 열린 경우 expanded)해 export가 화면과 일치.
    /// `displayName`은 live 카드 제목(세션 중 리네임 반영); `nil`이면 launch 시 baked된 이름 사용.
    @discardableResult
    static func share(
        group: ProviderGroup,
        dataStore: WidgetDataStore,
        layout: LayoutStore,
        appearance: ColorScheme,
        displayName: String? = nil
    ) -> Bool {
        let isExpanded = layout.isProviderExpanded(group.provider.id)
        let alwaysRows = group.alwaysShownWidgets.compactMap { widget -> WidgetData? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return dataStore.data(for: descriptor)
        }
        let expandedRows = group.expandedWidgets.compactMap { widget -> WidgetData? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return dataStore.data(for: descriptor)
        }
        let rows = isExpanded ? alwaysRows + expandedRows : alwaysRows
        let view = ShareCardView(
            provider: group.provider,
            plan: dataStore.plan(for: group.provider.id),
            rows: rows,
            appearance: appearance,
            expandBoundaryIndex: isExpanded ? alwaysRows.count : nil,
            displayNameOverride: displayName
        )
        return renderAndCopy(view, label: group.provider.id, layout: layout)
    }

    /// `share(group:…)`의 Total Spend 대응 — 선택된 period·metric의 aggregate ring 카드를 렌더해 clipboard 복사.
    /// `total`은 이미 집계된 값이라 export가 화면 ring과 어긋날 수 없음; pasteboard 기록 성공 여부 반환.
    @discardableResult
    static func shareTotalSpend(
        total: TotalSpend,
        metric: TotalSpendMetric,
        appearance: ColorScheme,
        layout: LayoutStore
    ) -> Bool {
        let projection = total.projection(for: metric)
        guard !projection.isEmpty else {
            NSSound.beep()
            return false
        }
        let view = TotalSpendShareCardView(total: total, metric: metric, appearance: appearance)
        return renderAndCopy(view, label: metric.title.lowercased(), layout: layout)
    }

    /// 두 share 액션이 공유하는 렌더→복사 파이프라인.
    /// 렌더 동안 저장된 density를 `.regular`로 교체 후 복원해 export가 popover density slider를 무시; 성공 시 "Copied to clipboard" pill 표시.
    /// 실패 시 beep + `label` 명시 로그로 조용한 실패 방지; pasteboard 기록 여부 반환.
    @discardableResult
    private static func renderAndCopy<Card: View>(_ view: Card, label: String, layout: LayoutStore) -> Bool {
        let densityKey = DensitySetting.key
        let savedDensity = UserDefaults.standard.string(forKey: densityKey)
        UserDefaults.standard.set(DensitySetting.regular.rawValue, forKey: densityKey)
        defer {
            if let savedDensity {
                UserDefaults.standard.set(savedDensity, forKey: densityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: densityKey)
            }
        }
        guard let image = image(for: view) else {
            AppLog.error(.lifecycle, "share card: ImageRenderer produced no image for \(label)")
            NSSound.beep()
            return false
        }
        guard copyToPasteboard(image) else { return false }
        layout.presentShareConfirmation()
        return true
    }
}
