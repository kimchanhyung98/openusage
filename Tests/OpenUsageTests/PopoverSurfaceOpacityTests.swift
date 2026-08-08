import XCTest
import AppKit
@testable import OpenUsage

final class PopoverSurfaceOpacityTests: XCTestCase {
    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    func testTraySurfaceIsFullyOpaqueInBothAppearances() {
        assertOpaque(Theme.trayNSColor, label: "tray")
    }

    // card는 불투명 tray 위에 `.fill.quaternary`를 합성한 구조라 tray가 불투명하면 자동 보장 — 별도 NSColor 없음

    private func assertOpaque(_ color: NSColor, label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        for name in appearances {
            guard let appearance = NSAppearance(named: name) else {
                XCTFail("missing appearance \(name.rawValue)", file: file, line: line)
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                guard let resolved = color.usingColorSpace(.sRGB) else {
                    XCTFail("could not resolve \(label) color in \(name.rawValue)", file: file, line: line)
                    return
                }
                XCTAssertEqual(resolved.alphaComponent, 1, accuracy: 0.0001,
                               "\(label) surface must be fully opaque in \(name.rawValue)",
                               file: file, line: line)
            }
        }
    }
}
