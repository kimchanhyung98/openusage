import AppKit
import Observation
import XCTest
@testable import OpenUsage

/// conceal 전환 즉시 적용, 일반 렌더 병합·재무장, 예측 deadline 1회 재렌더 검증.
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
        private(set) var resumedCount = 0

        func wait() async {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
            resumedCount += 1
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

    private func rendered(
        _ name: String,
        nextInvalidation: Date? = nil
    ) -> StatusItemImageUpdater.RenderedButtonImage {
        StatusItemImageUpdater.RenderedButtonImage(image: image(named: name), nextInvalidation: nextInvalidation)
    }

    private func makeUpdater(
        privacy: MenuBarPrivacyStore,
        state: RenderState,
        recorder: Recorder,
        gate: DelayGate,
        nextInvalidation: @escaping (_ renderCount: Int) -> Date? = { _ in nil }
    ) -> StatusItemImageUpdater {
        StatusItemImageUpdater(
            privacy: privacy,
            renderButtonImage: { [self] concealed in
                recorder.renderCount += 1
                return rendered(
                    concealed ? "privacy" : state.label,
                    nextInvalidation: concealed ? nil : nextInvalidation(recorder.renderCount)
                )
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

    private func waitForResumedDelay(_ gate: DelayGate) async {
        for _ in 0..<100 where gate.resumedCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(gate.resumedCount, 1)
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
        await waitForResumedDelay(gate)

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

    // MARK: - Deadline

    func testDeadlineSchedulesOneTimeRender() async throws {
        let capture = CaptureFlag(isOn: false)
        let privacy = makePrivacyStore("deadlineOneTime", capture: capture)
        let state = RenderState()
        let recorder = Recorder()
        let gate = DelayGate()
        let updater = makeUpdater(privacy: privacy, state: state, recorder: recorder, gate: gate) { renderCount in
            renderCount == 1 ? Date().addingTimeInterval(0.02) : nil
        }

        updater.update()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.renderCount, 2)
        XCTAssertEqual(recorder.applied, ["strip", "strip"])
    }

    func testNewRenderCancelsSupersededDeadline() async throws {
        let capture = CaptureFlag(isOn: false)
        let privacy = makePrivacyStore("supersededDeadline", capture: capture)
        let state = RenderState()
        let recorder = Recorder()
        let gate = DelayGate()
        let updater = makeUpdater(privacy: privacy, state: state, recorder: recorder, gate: gate) { renderCount in
            renderCount == 1 ? Date().addingTimeInterval(0.02) : nil
        }

        updater.update()
        updater.update()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.renderCount, 2)
    }

    func testObservedRenderCancelsSupersededDeadline() async throws {
        let capture = CaptureFlag(isOn: false)
        let privacy = makePrivacyStore("observedRenderCancelsDeadline", capture: capture)
        let state = RenderState()
        let recorder = Recorder()
        let gate = DelayGate()
        let updater = makeUpdater(privacy: privacy, state: state, recorder: recorder, gate: gate) { renderCount in
            renderCount == 1 ? Date().addingTimeInterval(0.1) : nil
        }

        updater.update()
        state.label = "updated-strip"
        await waitForPendingDelay(gate)
        gate.releaseAll()
        await waitForAppliedCount(2, recorder: recorder)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(recorder.renderCount, 2)
        XCTAssertEqual(recorder.applied, ["strip", "updated-strip"])
    }

    func testCaptureStartCancelsPendingDeadline() async throws {
        let capture = CaptureFlag(isOn: false)
        let privacy = makePrivacyStore("captureCancelsDeadline", capture: capture)
        let state = RenderState()
        let recorder = Recorder()
        let gate = DelayGate()
        let updater = makeUpdater(privacy: privacy, state: state, recorder: recorder, gate: gate) { _ in
            Date().addingTimeInterval(0.02)
        }

        updater.update()
        capture.isOn = true
        privacy.refreshCaptureState()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.applied, ["strip", "privacy"])
        XCTAssertEqual(recorder.renderCount, 2)
    }

    func testDeadlineRenderKeepsOneObservationSubscription() async {
        let capture = CaptureFlag(isOn: false)
        let privacy = makePrivacyStore("deadlineObservation", capture: capture)
        let state = RenderState()
        let recorder = Recorder()
        let gate = DelayGate()
        let updater = makeUpdater(privacy: privacy, state: state, recorder: recorder, gate: gate)
        updater.update()
        updater.deadlineDidFire()

        XCTAssertEqual(recorder.renderCount, 2)
        XCTAssertEqual(recorder.applied, ["strip", "strip"])

        state.label = "after-deadline"
        await waitForPendingDelay(gate)
        gate.releaseAll()
        await waitForAppliedCount(3, recorder: recorder)

        XCTAssertEqual(recorder.renderCount, 3)
        XCTAssertEqual(recorder.applied.last, "after-deadline")
    }
}
