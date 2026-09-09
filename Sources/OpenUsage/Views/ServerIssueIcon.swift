import SwiftUI

/// provider 상태 페이지의 확인된 장애를 나타내는 프로젝트 소유 단색 해골.
struct ServerIssueIcon: View {
    let issue: ProviderServiceIssue
    let providerName: String

    var body: some View {
        ServerIssueIconShape()
            .fill(Color(nsColor: .systemRed), style: FillStyle(eoFill: true))
            .frame(width: 10, height: 10)
            .frame(width: 14, height: 14)
            .fixedSize()
            .alignmentGuide(.firstTextBaseline) { dimensions in
                dimensions[.bottom] - 2
            }
            .accessibilityElement()
            .accessibilityLabel("Service Issue")
            .accessibilityValue(issue.accessibilityValue(providerName: providerName))
    }
}

struct ServerIssueIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 16
        let scaleY = rect.height / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scaleX, y: rect.minY + y * scaleY)
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: rect.minX + x * scaleX,
                y: rect.minY + y * scaleY,
                width: width * scaleX,
                height: height * scaleY
            )
        }

        var path = Path()
        path.move(to: point(8, 1))
        path.addCurve(
            to: point(1.5, 7.2),
            control1: point(4.2, 1),
            control2: point(1.5, 3.4)
        )
        path.addCurve(
            to: point(4.1, 11.4),
            control1: point(1.5, 9.1),
            control2: point(2.5, 10.6)
        )
        path.addLine(to: point(4.1, 14.7))
        path.addLine(to: point(6.2, 14.7))
        path.addLine(to: point(6.2, 13.1))
        path.addLine(to: point(7.2, 13.1))
        path.addLine(to: point(7.2, 14.7))
        path.addLine(to: point(8.8, 14.7))
        path.addLine(to: point(8.8, 13.1))
        path.addLine(to: point(9.8, 13.1))
        path.addLine(to: point(9.8, 14.7))
        path.addLine(to: point(11.9, 14.7))
        path.addLine(to: point(11.9, 11.4))
        path.addCurve(
            to: point(14.5, 7.2),
            control1: point(13.5, 10.6),
            control2: point(14.5, 9.1)
        )
        path.addCurve(
            to: point(8, 1),
            control1: point(14.5, 3.4),
            control2: point(11.8, 1)
        )
        path.closeSubpath()

        path.addEllipse(in: box(3.6, 5.1, 3.2, 3.3))
        path.addEllipse(in: box(9.2, 5.1, 3.2, 3.3))
        path.move(to: point(8, 8.2))
        path.addLine(to: point(6.8, 10.7))
        path.addLine(to: point(9.2, 10.7))
        path.closeSubpath()
        return path
    }
}
