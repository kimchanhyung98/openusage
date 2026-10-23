import AppKit

/// Footer 메뉴 "About OpenUsage" 항목용 표준 macOS About 패널 표시.
/// menu-bar accessory 특성상 앱을 먼저 activate하지 않으면 패널이 전면 앱 뒤에 열림.
enum AboutPanel {
    @MainActor
    static func present() {
        NSApp.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// 가운데 정렬 secondary 스타일 credits. 표준 패널은 `.link` attribute run을 클릭 가능하게 렌더링함.
    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let text = L10n.common("Fork maintained by %@\n\nOpen source on %@", "kimchanhyung98", "GitHub")
        let credits = NSMutableAttributedString(string: text, attributes: base)
        for (label, url) in [
            ("kimchanhyung98", "https://github.com/kimchanhyung98"),
            ("GitHub", "https://github.com/kimchanhyung98/openusage"),
        ] {
            credits.addAttribute(.link, value: url, range: (text as NSString).range(of: label))
        }
        return credits
    }
}
