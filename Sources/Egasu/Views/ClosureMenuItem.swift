import AppKit

/// 선택 시 closure를 실행하는 `NSMenuItem`.
/// `keyEquivalent` 지정 시 ⌘ modifier 적용.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, systemSymbol: String? = nil, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
        if let systemSymbol {
            image = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}
