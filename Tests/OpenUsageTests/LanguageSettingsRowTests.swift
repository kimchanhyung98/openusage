import SwiftUI
import Vision
import XCTest
@testable import OpenUsage

@MainActor
final class LanguageSettingsRowTests: XCTestCase {
    func testPendingLanguageOffersVisibleRestartButton() async throws {
        let text = try await recognizedText(selection: .korean, activeLanguage: .english)
        XCTAssertTrue(text.contains("Restart Now"), text)
    }

    func testActiveLanguageDoesNotOfferRestart() async throws {
        let text = try await recognizedText(selection: .english, activeLanguage: .english)
        XCTAssertFalse(text.contains("Restart Now"), text)
        XCTAssertFalse(text.contains("Restart OpenUsage"), text)
    }

    func testRestartButtonRendersInEveryLanguageAndDensity() async throws {
        let labels: [LanguageSetting: String] = [.english: "Restart Now", .korean: "지금 다시 시작", .japanese: "今すぐ再起動"]
        for language in LanguageSetting.allCases {
            for density in DensitySetting.allCases {
                let selection: LanguageSetting = language == .english ? .korean : .english
                let text = try await recognizedText(selection: selection, activeLanguage: language, density: density)
                let expected = try XCTUnwrap(labels[language]).filter { !$0.isWhitespace }
                XCTAssertTrue(text.filter { !$0.isWhitespace }.contains(expected), "\(language)/\(density): \(text)")
            }
        }
    }

    private func recognizedText(
        selection: LanguageSetting, activeLanguage: LanguageSetting,
        density: DensitySetting = .compact
    ) async throws -> String {
        let suite = "LanguageSettingsRowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(density.rawValue, forKey: DensitySetting.key)
        let image = try L10n.withLanguage(activeLanguage) {
            let view = LanguageSettingsRow(selection: .constant(selection), activeLanguage: activeLanguage)
                .frame(width: 292)
                .padding(14)
                .background(Color.white)
                .environment(\.colorScheme, .light)
                .defaultAppStorage(defaults)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: .init(x: 0, y: 0, width: 320, height: 300),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let path = ProcessInfo.processInfo.environment["OPENUSAGE_LANGUAGE_RESTART_SCREENSHOTS"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(activeLanguage.rawValue)-\(density.rawValue)-light-\(selection.rawValue).png"))
            }
            return try XCTUnwrap(bitmap.cgImage)
        }
        return try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = [activeLanguage.locale.identifier, "en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}
