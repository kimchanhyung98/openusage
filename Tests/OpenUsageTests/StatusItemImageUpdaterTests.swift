import AppKit
import Observation
import XCTest
@testable import OpenUsage

/// 캡처가 시작되면 지연 병합을 우회해 즉시 privacy 이미지로 교체해야 한다.
@MainActor
final class StatusItemImageUpdaterTests: XCTestCase {
    private final class Recorder {
        var applied: [String] = []
        var renderCount = 0
    }

    private final class CaptureFlag {
        var isOn: Bool

        init(isOn: Bool) {
            self.isOn = isOn
        }
    }

    @Observable
    final class RenderState {
        var label = "strip"
    }

    @MainActor
    private final class DelayGate {
        private var continuations: [CheckedContinuation<Void, Never>] = []

        var pendingCount: Int { continuations.count }

        func wait() async {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func releaseAll() {
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    /// `setName`은 전역 registry라 같은 이름을 먼저 등록한 테스트가 있으면 실패 — 인스턴스 속성으로 표시.
    private func image(named name: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.accessibilityDescription = name
        return image
    }

    private func makeUpdater(
        privacy: MenuBarPrivacyStore,
        state: RenderState,
        recorder: Recorder,
        gate: DelayGate
    ) -> StatusItemImageUpdater {
        StatusItemImageUpdater(
            privacy: privacy,
            renderButtonImage: { [self] concealed in
                recorder.renderCount += 1
                return image(named: concealed ? "privacy" : state.label)
            },
            delay: { await gate.wait() },
            apply: { recorder.applied.append($0.accessibilityDescription ?? "?") }
        )
    }

    private func makePrivacyStore(
        _ name: String,
        capture: CaptureFlag,
        enabled: Bool = true
    ) -> MenuBarPrivacyStore {
        let suiteName = "OpenUsageTests.StatusItemImageUpdater.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(enabled, forKey: MenuBarPrivacyStore.key)
        return MenuBarPrivacyStore(
            defaults: defaults,
            probe: { capture.isOn },
            installChangeNotifications: { _ in }
        )
    }

    private func waitForPendingDelay(_ gate: DelayGate) async {
        for _ in 0..<100 where gate.pendingCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(gate.pendingCount, 1)
    }

    private func waitForAppliedCount(_ count: Int, recorder: Recorder) async {
        for _ in 0..<100 where recorder.applied.count < count {
            await Task.yield()
        }
        XCTAssertEqual(recorder.applied.count, count)
    }

    func testCaptureTransitionsApplyPostMutationStateAndRearmObservation() async {
        let capture = CaptureFlag(isOn: false)
        let privacy = makePrivacyStore("captureTransitions", capture: capture)
        let state = RenderState()
        let recorder = Recorder()
        let gate = DelayGate()
        let updater = makeUpdater(privacy: privacy, state: state, recorder: recorder, gate: gate)
        updater.update()
        recorder.applied.removeAll()

        capture.isOn = true
        privacy.refreshCaptureState()

        XCTAssertEqual(recorder.applied, ["privacy"])

        capture.isOn = false
        privacy.refreshCaptureState()

        XCTAssertEqual(recorder.applied, ["privacy", "strip"])
        recorder.applied.removeAll()

        state.label = "updated-strip"
        await waitForPendingDelay(gate)
        gate.releaseAll()
        await waitForAppliedCount(1, recorder: recorder)

        XCTAssertEqual(recorder.applied, ["updated-strip"])
    }

    func testCaptureStartCancelsAPendingOrdinaryRender() async {
        let capture = CaptureFlag(isOn: false)
        let privacy = makePrivacyStore("cancelPending", capture: capture)
        let state = RenderState()
        let recorder = Recorder()
        let gate = DelayGate()
        let updater = makeUpdater(privacy: privacy, state: state, recorder: recorder, gate: gate)
        updater.update()
        recorder.applied.removeAll()

        state.label = "stale-strip"
        await waitForPendingDelay(gate)
        capture.isOn = true
        privacy.refreshCaptureState()
        gate.releaseAll()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(recorder.applied, ["privacy"])
    }

    func testOrdinaryBurstRendersLatestStateOnceAfterTheDelay() async {
        let capture = CaptureFlag(isOn: false)
        let privacy = makePrivacyStore("ordinaryBurst", capture: capture)
        let state = RenderState()
        let recorder = Recorder()
        let gate = DelayGate()
        let updater = makeUpdater(privacy: privacy, state: state, recorder: recorder, gate: gate)
        updater.update()
        recorder.applied.removeAll()
        let initialRenderCount = recorder.renderCount

        state.label = "strip-1"
        state.label = "strip-2"
        state.label = "strip-3"
        await waitForPendingDelay(gate)

        XCTAssertTrue(recorder.applied.isEmpty)
        XCTAssertEqual(recorder.renderCount, initialRenderCount)

        gate.releaseAll()
        await waitForAppliedCount(1, recorder: recorder)

        XCTAssertEqual(recorder.applied, ["strip-3"])
        XCTAssertEqual(recorder.renderCount, initialRenderCount + 1)

        recorder.applied.removeAll()
        state.label = "strip-4"
        await waitForPendingDelay(gate)
        gate.releaseAll()
        await waitForAppliedCount(1, recorder: recorder)

        XCTAssertEqual(recorder.applied, ["strip-4"])
        XCTAssertEqual(recorder.renderCount, initialRenderCount + 2)
    }

    func testEnablingDuringCaptureAppliesPrivacyImmediately() {
        let capture = CaptureFlag(isOn: true)
        let privacy = makePrivacyStore("enableDuringCapture", capture: capture, enabled: false)
        let state = RenderState()
        let recorder = Recorder()
        let gate = DelayGate()
        let updater = makeUpdater(privacy: privacy, state: state, recorder: recorder, gate: gate)
        updater.update()
        recorder.applied.removeAll()

        privacy.hideUsageWhileScreenSharing = true
        privacy.hideUsageWhileScreenSharing = false

        XCTAssertEqual(recorder.applied, ["privacy", "strip"])
    }
}
