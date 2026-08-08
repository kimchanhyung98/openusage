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

        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(string: "Created by ", attributes: base))
        credits.append(link("Robin Ebers", "https://itsbyrob.in/x", base: base))
        credits.append(NSAttributedString(string: "\nMaintained also by ", attributes: base))
        credits.append(link("Mert", "https://github.com/validatedev", base: base))
        credits.append(NSAttributedString(string: " & ", attributes: base))
        credits.append(link("David", "https://github.com/davidarny", base: base))
        credits.append(NSAttributedString(string: "\n\nOpen source on ", attributes: base))
        credits.append(link("GitHub", "https://github.com/robinebers/openusage", base: base))
        return credits
    }

    private static func link(_ text: String, _ urlString: String, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = base
        if let url = URL(string: urlString) {
            attributes[.link] = url
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}
