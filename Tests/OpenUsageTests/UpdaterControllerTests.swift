import AppKit
import Sparkle
import XCTest
@testable import OpenUsage

@MainActor
final class UpdaterPresentationControllerTests: XCTestCase {
    func testBringToFrontUsesReliableActivationAfterChangingPolicy() {
        var policy = NSApplication.ActivationPolicy.accessory
        var active = false
        var events: [String] = []
        let presentationController = UpdaterPresentationController(
            activationPolicy: { policy },
            isActive: { active },
            setActivationPolicy: { newPolicy in
                events.append("policy:\(newPolicy.rawValue)")
                policy = newPolicy
                return true
            },
            activate: { ignoringOtherApps in
                events.append("activate:\(ignoringOtherApps)")
                active = true
            }
        )

        presentationController.bringToFront(reason: "test")

        XCTAssertEqual(policy, .regular)
        XCTAssertTrue(active)
        XCTAssertEqual(events, ["policy:\(NSApplication.ActivationPolicy.regular.rawValue)", "activate:true"])
    }

    func testReturnToMenuBarRestoresAccessoryPolicy() {
        var policy = NSApplication.ActivationPolicy.regular
        let presentationController = UpdaterPresentationController(
            activationPolicy: { policy },
            isActive: { true },
            setActivationPolicy: { newPolicy in
                policy = newPolicy
                return true
            },
            activate: { _ in XCTFail("Finishing must not reactivate the app") }
        )

        presentationController.returnToMenuBar()

        XCTAssertEqual(policy, .accessory)
    }
}

@MainActor
final class UpdaterUserDriverDelegateTests: XCTestCase {
    func testFinishingUpdateSessionRestoresPresentationAndClearsIndicator() {
        let delegate = UpdaterUserDriverDelegate()
        var sessionFinished = false
        var resolved = false
        delegate.onUpdateSessionFinished = { sessionFinished = true }
        delegate.onUpdateResolved = { resolved = true }

        delegate.standardUserDriverWillFinishUpdateSession()

        XCTAssertTrue(sessionFinished)
        XCTAssertTrue(resolved)
    }
}

@MainActor
final class UpdaterCycleDiagnosticsTests: XCTestCase {
    func testWrappedDownloadNetworkFailuresKeepOriginalLocalContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousSink = AppLog.sink
        AppLog.sink = LogFile(directory: root, fileName: "diagnostics.log")
        AppLog.sink.open()
        AppLog.reloadLevel(.info)
        defer {
            AppLog.sink = previousSink
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: root)
        }
        let diagnostics = DiagnosticEventRecorder()
        for code in [URLError.notConnectedToInternet, .timedOut] {
            for depth in 1...2 {
                var error: Error = URLError(code, userInfo: [
                    NSURLErrorFailingURLErrorKey: URL(string: "https://example.invalid/PRIVATE_URL")!
                ]) as NSError
                for _ in 0..<depth { error = downloadError(underlying: error) }
                UpdaterController.recordUpdateCycle(error: error)
            }
        }

        XCTAssertEqual(diagnostics.events, Array(repeating:
            DiagnosticEvent(.updateCheck, result: .failure, category: .network), count: 4))
        let lines = try String(contentsOf: root.appendingPathComponent("diagnostics.log"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.allSatisfy { $0.contains("error_domain=SUSparkleErrorDomain error_code=2001") })
        XCTAssertTrue(lines.allSatisfy { $0.contains("context=Update check or download failed") })
        XCTAssertFalse(lines.joined().contains("PRIVATE_"))
    }

    func testOnlyKnownDownloadWrappersAreUnwrapped() {
        let network = URLError(.timedOut)
        let cases: [(Error, ErrorCategory)] = [
            (network, .network),
            (NSError(domain: "OtherDomain", code: 2001, userInfo: [NSUnderlyingErrorKey: network]), .other),
            (NSError(domain: SUSparkleErrorDomain, code: 9999, userInfo: [NSUnderlyingErrorKey: network]), .other),
            (downloadError(underlying: CocoaError(.fileReadNoPermission)), .other),
            (NSError(domain: SUSparkleErrorDomain, code: 2001), .other),
            (downloadError(underlying: downloadError(underlying: downloadError(underlying: network))), .other),
            (NSError(domain: "OtherDomain", code: 9999), .other)
        ]
        let diagnostics = DiagnosticEventRecorder()

        for (error, _) in cases { UpdaterController.recordUpdateCycle(error: error) }

        XCTAssertEqual(diagnostics.events, cases.map {
            DiagnosticEvent(.updateCheck, result: .failure, category: $0.1)
        })
        XCTAssertEqual(ErrorCategory.classify(downloadError(underlying: network)), .other)
    }

    func testSuccessNoUpdateAndCancellationKeepExistingResults() {
        let diagnostics = DiagnosticEventRecorder()
        UpdaterController.recordUpdateCycle(error: nil)
        UpdaterController.recordUpdateCycle(error:
            NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        UpdaterController.recordUpdateCycle(error:
            NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        UpdaterController.recordUpdateCycle(error: URLError(.cancelled))

        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.updateCheck, result: .success),
            DiagnosticEvent(.updateCheck, result: .success),
            DiagnosticEvent(.updateCheck, result: .cancelled),
            DiagnosticEvent(.updateCheck, result: .cancelled)
        ])
    }

    private func downloadError(underlying: Error) -> NSError {
        NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue), userInfo: [
            NSLocalizedDescriptionKey: "PRIVATE_DOWNLOAD_DESCRIPTION",
            NSUnderlyingErrorKey: underlying
        ])
    }
}
