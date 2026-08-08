import SwiftUI

/// SectorMark 스타일의 도넛 섹터 — start/end fraction이 `animatableData`인 자체 Shape.
/// 섹터별 독립 뷰/fill 구조로 기간 전환 시 색상 고정 + 위치 morph 보장 (SectorMark는 위치 매칭으로 색 번짐).
/// fraction은 12시 방향 기준 시계방향 0...1.
struct RingSectorShape: Shape {
    var startFraction: Double
    var endFraction: Double
    /// 지름 대비 구멍 비율 (황금비 도넛).
    var innerRadiusRatio: CGFloat = 0.618
    /// 인접 섹터 간 간격의 외곽 림 기준 호 길이 (pt).
    var gapWidth: CGFloat = 1.6
    var cornerRadius: CGFloat = 3

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(startFraction, endFraction) }
        set {
            startFraction = newValue.first
            endFraction = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let outer = Double(min(rect.width, rect.height) / 2)
        let inner = outer * Double(innerRadiusRatio)
        let center = CGPoint(x: rect.midX, y: rect.midY)

        // 화면 y축이 아래로 증가 → 각도 증가가 시계방향 (링 진행 방향과 일치)
        let top = -Double.pi / 2
        let halfGap = Double(gapWidth) / outer / 2
        let a0 = top + startFraction * 2 * .pi + halfGap
        let a1 = top + endFraction * 2 * .pi - halfGap
        let width = a1 - a0
        guard width > 0.001 else { return Path() }

        // corner는 밴드 두께 절반 이하 + 슬라이스 반각 이내로 제한 — 한 변의 두 corner 호 교차 방지
        let s = sin(min(width / 2, .pi / 2))
        var corner = min(Double(cornerRadius), (outer - inner) / 2)
        corner = min(corner, outer * s / (1 + s))
        if s < 1 {
            corner = min(corner, inner * s / (1 - s))
        }

        if corner < 0.25 {
            return plainWedge(center: center, inner: inner, outer: outer, a0: a0, a1: a1)
        }
        return roundedWedge(center: center, inner: inner, outer: outer, a0: a0, a1: a1, corner: corner)
    }

    /// 퇴화 슬라이스(hairline·애니메이션 중 압축)용 corner 없는 단순 환형 wedge.
    private func plainWedge(center: CGPoint, inner: Double, outer: Double, a0: Double, a1: Double) -> Path {
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
        path.closeSubpath()
        return path
    }

    /// SectorMark 스타일 완전 wedge — 외곽 호, tangent corner 호 4개, radial edge 2개, 내곽 호.
    private func roundedWedge(center: CGPoint, inner: Double, outer: Double, a0: Double, a1: Double, corner: Double) -> Path {
        // beta: corner 원 중심이 림·edge 양쪽에 접하도록 하는 섹터 edge 기준 각 오프셋
        let betaOuter = asin(min(1, corner / (outer - corner)))
        let betaInner = asin(min(1, corner / (inner + corner)))

        func polar(_ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        func around(_ point: CGPoint, _ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(x: point.x + radius * cos(angle), y: point.y + radius * sin(angle))
        }

        var path = Path()
        // 외곽 림, 시계방향
        path.addArc(
            center: center, radius: outer,
            startAngle: .radians(a0 + betaOuter), endAngle: .radians(a1 - betaOuter), clockwise: false
        )
        // 외곽 corner → trailing edge 진입
        let trailingOuter = polar(outer - corner, a1 - betaOuter)
        path.addArc(
            center: trailingOuter, radius: corner,
            startAngle: .radians(a1 - betaOuter), endAngle: .radians(a1 + .pi / 2), clockwise: false
        )
        // trailing radial edge, 안쪽 방향
        let trailingInner = polar(inner + corner, a1 - betaInner)
        path.addLine(to: around(trailingInner, corner, a1 + .pi / 2))
        // trailing edge의 내곽 corner
        path.addArc(
            center: trailingInner, radius: corner,
            startAngle: .radians(a1 + .pi / 2), endAngle: .radians(a1 - betaInner + .pi), clockwise: false
        )
        // 내곽 림, 반시계방향 (leading edge 방향)
        path.addArc(
            center: center, radius: inner,
            startAngle: .radians(a1 - betaInner), endAngle: .radians(a0 + betaInner), clockwise: true
        )
        // leading edge의 내곽 corner
        let leadingInner = polar(inner + corner, a0 + betaInner)
        path.addArc(
            center: leadingInner, radius: corner,
            startAngle: .radians(a0 + betaInner + .pi), endAngle: .radians(a0 + 3 * .pi / 2), clockwise: false
        )
        // leading radial edge, 바깥 방향
        let leadingOuter = polar(outer - corner, a0 + betaOuter)
        path.addLine(to: around(leadingOuter, corner, a0 - .pi / 2))
        // 외곽 corner → 림 복귀
        path.addArc(
            center: leadingOuter, radius: corner,
            startAngle: .radians(a0 + 3 * .pi / 2), endAngle: .radians(a0 + betaOuter), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
