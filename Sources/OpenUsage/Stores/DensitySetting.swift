import AppKit

/// popover UI 밀도별 치수의 단일 출처.
enum DensitySetting: String, Hashable, Sendable, CaseIterable {
    case regular
    case compact

    static let key = "density"
    static let defaultValue: Self = .compact

    var label: String {
        switch self {
        case .regular: return "Default"
        case .compact: return "Compact"
        }
    }

    // MARK: - Typography

    var labelPointSize: CGFloat {
        let base = NSFont.preferredFont(forTextStyle: .headline).pointSize
        return self == .compact ? base - 1 : base
    }

    var supportingPointSize: CGFloat { self == .compact ? 11 : 12 }

    var headerPointSize: CGFloat { self == .compact ? 13 : 14 }

    var headerIconSize: CGFloat { self == .compact ? 14 : 16 }

    var planBadgePointSize: CGFloat { self == .compact ? 10 : 11 }

    // MARK: - Dimensions

    var barRowPadding: CGFloat { self == .compact ? 5 : 10 }

    var meterHeight: CGFloat { self == .compact ? 4 : 5 }

    var trendChartHeight: CGFloat { self == .compact ? 14 : 18 }

    var textRowPadding: CGFloat { self == .compact ? 4 : 6 }

    /// 텍스트 row가 텍스트 row 바로 아래 붙을 때의 상단 padding — 두 밀도 모두 적용되는 이웃 인지 규칙
    var condensedTextRowTopPadding: CGFloat { self == .compact ? 1 : 2 }

    var rowInnerSpacing: CGFloat { self == .compact ? 3 : 4 }

    var sectionSpacing: CGFloat { self == .compact ? 8 : 14 }

    var headerToCardSpacing: CGFloat { self == .compact ? 2 : 4 }

    var cardGutter: CGFloat { self == .compact ? 3 : 5 }

    var controlRowPadding: CGFloat { self == .compact ? 6 : 9 }

    var contentTopPadding: CGFloat { self == .compact ? 10 : 14 }

    /// 사전 측정 height seed용 Customize control row 추정 높이 (내용 ≈ 24pt + `controlRowPadding` × 2)
    var estimatedMetricRowHeight: CGFloat { self == .compact ? 36 : 42 }

    var expandedGridSpacing: CGFloat { self == .compact ? 4 : 6 }
}
