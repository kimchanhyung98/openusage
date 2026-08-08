import AppKit
import SwiftUI

/// Text 스타일 menu-bar strip(`MenuBarContent`)을 `MenuBarExtra` 라벨용 template `NSImage`로 렌더링.
/// black-on-clear라 macOS가 light/dark에 맞게 틴트.
/// 이미지는 `label:` view builder 밖에서 빌드 필요 — inline `ImageRenderer`는 불명확한 오류 유발.
@MainActor
enum MenuBarStripRenderer {
    /// (content, style) 기준 마지막 렌더의 memoize.
    /// 같은 `NSImage` 인스턴스 반환으로 SwiftUI가 status-item 갱신을 건너뛰고 `ImageRenderer` 실행을 실제 시각 변화로 한정.
    private static var lastRender: (content: MenuBarContent, style: MenuBarStyle, image: NSImage?)?

    /// 지정 content·style의 strip 이미지 — 해당 스타일에서 렌더할 것이 없으면 `nil`(호출자는 앱 아이콘 fallback).
    /// memoize: 같은 입력은 이전에 렌더된 인스턴스 반환.
    static func image(for content: MenuBarContent, style: MenuBarStyle) -> NSImage? {
        if let lastRender, lastRender.content == content, lastRender.style == style {
            AppLog.debug(.menubar, "strip cache hit")
            return lastRender.image
        }
        AppLog.debug(.menubar, "strip cache miss (rendering)")
        let image: NSImage?
        switch style {
        case .text: image = textImage(for: content)
        case .bars: image = barsImage(for: content)
        }
        lastRender = (content, style, image)
        return image
    }

    /// 고정 metric strip — 고정된 metric이 없거나 데이터가 아직 없으면 `nil`(앱 아이콘 fallback).
    /// 렌더는 보이는 픽셀로 trim — 투명 여백이 남으면 status item이 artwork보다 넓어져 이웃 항목과의 간격이 과대해짐.
    static func textImage(for content: MenuBarContent) -> NSImage? {
        guard !content.isEmpty else { return nil }
        let renderer = ImageRenderer(content: MenuBarTextStrip(content: content))
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / renderer.scale, height: CGFloat(cgImage.height) / renderer.scale)
        )
        image.isTemplate = true
        image.accessibilityDescription = content.accessibilityText
        return image
    }

    /// 렌더된 strip의 완전 투명 여백 crop — 보이는 픽셀이 없으면 `nil`(호출자는 untrimmed 렌더 유지).
    nonisolated static func trimmedToVisibleContent(_ image: CGImage) -> CGImage? {
        guard let bounds = visibleBounds(of: image) else { return nil }
        return image.cropping(to: bounds)
    }

    /// non-zero alpha 픽셀의 bounding box(pixel 좌표, top-left 원점 — `CGImage.cropping(to:)`와 일치); 완전 투명이면 `nil`.
    nonisolated static func visibleBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &alpha, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// compact Bars glyph(≤4개 bounded-metric bar) — 고정 metric에 fill이 없으면 `nil`.
    static func barsImage(for content: MenuBarContent) -> NSImage? {
        let fractions = content.bars.map(\.fraction)
        guard !fractions.isEmpty else { return nil }
        let renderer = ImageRenderer(content: MenuBarBars(fractions: fractions, side: 18))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = content.accessibilityText
        return image
    }

    /// screen-share 프라이버시 대체 이미지 — `MenuBarPrivacyStore.concealUsage` 동안 사용량 대신 wordmark 표시.
    /// 공유·녹화 화면에 token 수나 지출이 절대 실리지 않는 것이 계약; deterministic이라 1회 렌더, `ImageRenderer` 전체 실패 시에만 `nil`.
    static let privacyImage: NSImage? = {
        let renderer = ImageRenderer(content: MenuBarPrivacyLabel())
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / renderer.scale, height: CGFloat(cgImage.height) / renderer.scale)
        )
        image.isTemplate = true
        image.accessibilityDescription = "OpenUsage, usage hidden while the screen is shared"
        return image
    }()

    /// 브랜드 mark 로드 실패 시 최후의 아이콘.
    static let fallbackIcon: NSImage = {
        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: "OpenUsage"
        ) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

/// 프라이버시 은닉 중 strip 대신 그려지는 브랜드 gauge mark + wordmark.
/// 단일 metric Text strip과 같은 template 처리·glyph box·글자 크기라 교체 시 menu bar 리듬이 유지됨.
private struct MenuBarPrivacyLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            // `MenuBarIcon`과 같은 mark·inset, strip의 glyph box 크기에 맞춰 provider-glyph 스케일 유지.
            if let mark = ProviderMarks.mark(for: "openusage") {
                ProviderIconShape(pathData: mark.path, inset: 0.08)
                    .fill(Color.black)
                    .frame(width: 16, height: 16)
            }
            Text("OpenUsage")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }
}

private struct MenuBarTextStrip: View {
    let content: MenuBarContent

    var body: some View {
        HStack(spacing: 11) {
            ForEach(content.groups, id: \.providerID) { group in
                HStack(spacing: 4) {
                    glyph(group.icon)
                    metricsView(group.metrics)
                }
            }
        }
        .foregroundStyle(.black)
        .monospacedDigit()
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }

    /// provider의 고정 값들(라벨 없음) — 1개는 큰 숫자 하나, 2개는 좁은 두 줄 stack으로 위치 기반 읽기.
    @ViewBuilder
    private func metricsView(_ metrics: [MenuBarContent.Metric]) -> some View {
        if metrics.count <= 1 {
            Text(metrics.first?.value ?? "")
                .font(.system(size: 12, weight: .bold))
        } else {
            VStack(alignment: .trailing, spacing: -2) {
                ForEach(metrics, id: \.id) { metric in
                    Text(metric.value)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .fixedSize()
        }
    }

    /// glyph box 한 변 길이 — strip 높이를 채워 mark가 옆 metric 블록과 같은 스케일로 읽히도록 함.
    /// `ProviderIconShape`가 mark를 실제 bounding box로 정규화하므로 근소한 `inset`이면 모든 provider가 box를 균일하게 채움.
    private static let glyphSide: CGFloat = 16

    @ViewBuilder
    private func glyph(_ icon: IconSource) -> some View {
        if let mark = ProviderMarks.mark(for: icon.providerID) {
            ProviderIconShape(pathData: mark.path, inset: 0.04)
                .fill(Color.black)
                .frame(width: Self.glyphSide, height: Self.glyphSide)
        } else {
            Circle().fill(Color.black).frame(width: Self.glyphSide - 1, height: Self.glyphSide - 1)
        }
    }
}

/// compact 정사각형에 최대 4개의 가로 usage bar 렌더 — 원본 OpenUsage tray bar의 1:1 port.
/// track 0.16 / fill 1.0 / remainder 0.24 opacity, near-full 양자화로 97% bar도 보이는 꼬리 유지.
private struct MenuBarBars: View {
    let fractions: [Double]
    let side: CGFloat

    var body: some View {
        Canvas { context, size in
            draw(into: &context, size: size)
        }
        .frame(width: side, height: side)
    }

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        let n = max(1, min(4, fractions.count))
        let pad = max(1, (size.width * 0.08).rounded())
        let gap = max(1, (size.width * 0.03).rounded())
        let trackX = pad
        let trackW = size.width - 2 * pad

        let layoutN = CGFloat(max(2, n))
        let trackH = max(1, ((size.height - 2 * pad - (layoutN - 1) * gap) / layoutN).rounded(.down))
        let rx = max(1, (trackH / 3).rounded(.down))

        let totalBarsHeight = CGFloat(n) * trackH + CGFloat(n - 1) * gap
        let yOffset = pad + ((size.height - 2 * pad - totalBarsHeight) / 2).rounded(.down)

        for i in 0..<n {
            let y = yOffset + CGFloat(i) * (trackH + gap) + 1

            context.fill(
                bar(x: trackX, y: y, w: trackW, h: trackH, leading: rx, trailing: rx),
                with: .color(.black.opacity(0.16))
            )

            let fill = MenuBarBarGeometry.fill(trackW: trackW, fraction: i < fractions.count ? fractions[i] : 0)
            if fill.fillW > 0 {
                let trailing = fill.fillW >= trackW ? rx : max(0, (rx * 0.35).rounded(.down))
                context.fill(
                    bar(x: trackX, y: y, w: fill.fillW, h: trackH, leading: rx, trailing: trailing),
                    with: .color(.black)
                )
            }
            if fill.fillW > 0, fill.remainderW > 0, let dividerX = fill.dividerX {
                context.fill(
                    bar(x: trackX + dividerX, y: y, w: fill.remainderW, h: trackH,
                        leading: max(0, (rx * 0.2).rounded(.down)), trailing: rx),
                    with: .color(.black.opacity(0.24))
                )
            }
        }
    }

    private func bar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, leading: CGFloat, trailing: CGFloat) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: leading,
            bottomLeadingRadius: leading,
            bottomTrailingRadius: trailing,
            topTrailingRadius: trailing
        )
        .path(in: CGRect(x: x, y: y, width: w, height: h))
    }
}

/// Bars glyph의 순수 fill geometry — near-full 양자화와 최소 가시 remainder 규칙의 단위 테스트를 위해 분리.
enum MenuBarBarGeometry {
    struct Fill: Equatable {
        let fillW: CGFloat
        let remainderW: CGFloat
        let dividerX: CGFloat?
    }

    /// near-full(0.7–1.0) bar를 remainder 기준 15% 단위로 양자화 — 거의 가득 찬 bar가 100%로 읽히지 않도록 꼬리 유지.
    static func visualFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        let clamped = min(1, max(0, fraction))
        if clamped > 0.7, clamped < 1 {
            let remainder = 1 - clamped
            let quantized = min(1, (remainder / 0.15).rounded(.up) * 0.15)
            return max(0, 1 - quantized)
        }
        return clamped
    }

    static func fill(trackW: CGFloat, fraction: Double) -> Fill {
        guard fraction.isFinite, fraction > 0 else { return Fill(fillW: 0, remainderW: 0, dividerX: nil) }
        let visual = visualFraction(fraction)
        if visual >= 1 { return Fill(fillW: trackW, remainderW: 0, dividerX: nil) }
        let minVisible = max(4, (trackW * 0.2).rounded())
        let maxFillW = max(1, trackW - minVisible)
        let fillW = max(1, min(maxFillW, (trackW * CGFloat(visual)).rounded()))
        let trueRemainder = trackW - fillW
        let remainderW = min(trackW - 1, max(trueRemainder, minVisible))
        return Fill(fillW: fillW, remainderW: remainderW, dividerX: trackW - remainderW)
    }
}
