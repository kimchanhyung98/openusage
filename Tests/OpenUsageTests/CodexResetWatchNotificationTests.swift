import XCTest
@testable import OpenUsage

@MainActor
final class CodexResetWatchNotificationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private final class Recorder {
        var subtitles: [String] = []
    }

    private actor DeliveryGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private actor LoadProbe {
        private let result: CodexResetWatchResult
        private(set) var count = 0

        init(_ result: CodexResetWatchResult) { self.result = result }

        func load() -> CodexResetWatchResult {
            count += 1
            return result
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "CodexResetWatchNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func watch(
        _ eventID: String? = "watch:first",
        chance: Double = 75,
        scheduled: Bool = false,
        deadline: Date? = nil
    ) -> CodexResetWatch {
        CodexResetWatch(
            chancePercent: chance,
            deadline: deadline ?? base.addingTimeInterval(3600),
            isScheduled: scheduled,
            eventID: eventID
        )
    }

    private func makeEvaluator(
        defaults: UserDefaults,
        clock: Clock,
        recorder: Recorder,
        isEnabled: @escaping @MainActor () -> Bool = { true }
    ) -> CodexResetWatchNotificationEvaluator {
        CodexResetWatchNotificationEvaluator(
            defaults: defaults, isEnabled: isEnabled, now: { clock.date },
            post: { id, title, subtitle, _, isCurrent in
                guard isCurrent() else { return false }
                XCTAssertEqual(id, "codex.resetWatch")
                XCTAssertEqual(title, "Codex Reset Watch")
                recorder.subtitles.append(subtitle)
                return true
            }
        )
    }

    func testSettingDefaultsOffPersistsAndNotifiesOnlyOnChanges() {
        let defaults = makeDefaults()
        let settings = NotificationSettingsStore(defaults: defaults)
        var changes = 0
        settings.onCodexResetWatchChange = { changes += 1 }

        XCTAssertFalse(settings.codexResetWatch)
        XCTAssertFalse(settings.anyEnabled)
        settings.codexResetWatch = false
        XCTAssertEqual(changes, 0)

        settings.codexResetWatch = true
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(settings.anyEnabled)
        let restored = NotificationSettingsStore(defaults: defaults)
        XCTAssertTrue(restored.codexResetWatch)
        XCTAssertTrue(restored.anyEnabled)
        XCTAssertFalse(restored.underTenPercent)
        XCTAssertFalse(restored.healthyToClose)
        XCTAssertFalse(restored.closeToRunningOut)

        settings.codexResetWatch = true
        XCTAssertEqual(changes, 1)
        settings.codexResetWatch = false
        XCTAssertEqual(changes, 2)
        XCTAssertFalse(NotificationSettingsStore(defaults: defaults).anyEnabled)
    }

    func testDefaultOffDoesNotConsumeTheFirstEnabledEvent() async {
        let defaults = makeDefaults()
        let settings = NotificationSettingsStore(defaults: defaults)
        let recorder = Recorder()
        let evaluator = makeEvaluator(
            defaults: defaults, clock: Clock(base), recorder: recorder,
            isEnabled: { settings.codexResetWatch }
        )
        let result = CodexResetWatchResult(watch: watch())

        await evaluator.receive(result).value
        XCTAssertTrue(recorder.subtitles.isEmpty)
        settings.codexResetWatch = true
        evaluator.configurationDidChange()
        await evaluator.receive(result).value
        XCTAssertEqual(recorder.subtitles, ["Reset Forecast"])
    }

    func testWatchAndScheduledEventsEachDeliverOnceAcrossEditsAndRestart() async {
        let defaults = makeDefaults()
        let clock = Clock(base)
        let recorder = Recorder()
        let evaluator = makeEvaluator(defaults: defaults, clock: clock, recorder: recorder)
        let forecast = watch()
        let scheduled = watch("scheduled:first", chance: 99, scheduled: true)

        await evaluator.receive(CodexResetWatchResult(watch: forecast)).value
        var revised = forecast
        revised.communityYesPercent = 98
        await evaluator.receive(CodexResetWatchResult(watch: revised)).value
        await evaluator.receive(CodexResetWatchResult(watch: watch(chance: 90))).value
        await evaluator.receive(CodexResetWatchResult(watch: scheduled)).value
        await evaluator.receive(CodexResetWatchResult(watch: watch(
            "scheduled:first", chance: 99, scheduled: true,
            deadline: base.addingTimeInterval(7200)
        ))).value

        let restarted = makeEvaluator(defaults: defaults, clock: clock, recorder: recorder)
        await restarted.receive(CodexResetWatchResult(watch: forecast)).value
        await restarted.receive(CodexResetWatchResult(watch: scheduled)).value
        XCTAssertEqual(recorder.subtitles, ["Reset Forecast", "Scheduled Reset"])

        await restarted.receive(CodexResetWatchResult(watch: watch("watch:second"))).value
        XCTAssertEqual(recorder.subtitles, ["Reset Forecast", "Scheduled Reset", "Reset Forecast"])
    }

    func testScheduledEventWithoutATimeCanDeliver() async {
        let recorder = Recorder()
        let evaluator = makeEvaluator(defaults: makeDefaults(), clock: Clock(base), recorder: recorder)
        let scheduled = CodexResetWatch(
            chancePercent: 99, deadline: nil, isScheduled: true, eventID: "scheduled:unknown-time"
        )

        await evaluator.receive(CodexResetWatchResult(watch: scheduled)).value
        XCTAssertEqual(recorder.subtitles, ["Scheduled Reset"])
    }

    func testSourceAndObservationChangesKeepTheSameNotificationAcrossRestart() async {
        let defaults = makeDefaults()
        let clock = Clock(base)
        let recorder = Recorder()
        let evaluator = makeEvaluator(defaults: defaults, clock: clock, recorder: recorder)
        let observation = watch("watch-observed:first")
        await evaluator.receive(CodexResetWatchResult(watch: observation)).value

        var sourced = watch("watch:post")
        sourced.eventAliases = ["watch-observed:first"]
        await evaluator.receive(CodexResetWatchResult(watch: sourced)).value
        sourced.eventAliases = ["watch-observed:updated"]
        await evaluator.receive(CodexResetWatchResult(watch: sourced)).value

        let restarted = makeEvaluator(defaults: defaults, clock: clock, recorder: recorder)
        await restarted.receive(CodexResetWatchResult(watch: watch("watch-observed:updated"))).value
        await restarted.receive(CodexResetWatchResult(watch: observation)).value
        XCTAssertEqual(recorder.subtitles, ["Reset Forecast"])
    }

    func testRepeatedObservationCorrectionsKeepTheSourceIdentityAcrossRestart() async {
        let defaults = makeDefaults()
        let clock = Clock(base)
        let recorder = Recorder()
        let evaluator = makeEvaluator(defaults: defaults, clock: clock, recorder: recorder)
        var forecast = watch("watch:post")

        for index in 0..<150 {
            forecast.eventAliases = ["watch-observed:\(index)"]
            await evaluator.receive(CodexResetWatchResult(watch: forecast)).value
        }

        let restarted = makeEvaluator(defaults: defaults, clock: clock, recorder: recorder)
        forecast.eventAliases = ["watch-observed:latest"]
        await restarted.receive(CodexResetWatchResult(watch: forecast)).value
        await restarted.receive(CodexResetWatchResult(watch: watch("watch-observed:latest"))).value
        XCTAssertEqual(recorder.subtitles, ["Reset Forecast"])
    }

    func testFailedDeliveryRetriesOnTheNextPublicationAndThenDeduplicates() async {
        var attempts = 0
        var delivered = 0
        let evaluator = CodexResetWatchNotificationEvaluator(
            defaults: makeDefaults(), isEnabled: { true }, now: { self.base },
            post: { _, _, _, _, isCurrent in
                XCTAssertTrue(isCurrent())
                attempts += 1
                guard attempts > 1 else { return false }
                delivered += 1
                return true
            }
        )
        let result = CodexResetWatchResult(watch: watch())

        await evaluator.receive(result).value
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(delivered, 0)
        await evaluator.receive(result).value
        await evaluator.receive(result).value
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(delivered, 1)
    }

    func testInvalidAndUnavailableResultsNeverDeliverOrConsumeTheEvent() async {
        let recorder = Recorder()
        let evaluator = makeEvaluator(defaults: makeDefaults(), clock: Clock(base), recorder: recorder)
        let valid = watch()
        let cases: [(String, CodexResetWatchResult)] = [
            ("missing", CodexResetWatchResult()),
            ("failed", CodexResetWatchResult(watch: valid, refreshFailed: true)),
            ("cancelled", CodexResetWatchResult(watch: valid, refreshCancelled: true)),
            ("absent", CodexResetWatchResult(watch: valid, isAbsent: true)),
            ("expired", CodexResetWatchResult(watch: watch(deadline: base))),
            ("past", CodexResetWatchResult(watch: watch(deadline: base.addingTimeInterval(-1)))),
            ("past scheduled", CodexResetWatchResult(watch: watch(
                "scheduled:past", scheduled: true, deadline: base.addingTimeInterval(-1)
            ))),
            ("scheduled now", CodexResetWatchResult(watch: watch(
                "scheduled:now", scheduled: true, deadline: base
            ))),
            ("zero chance", CodexResetWatchResult(watch: watch(chance: 0))),
            ("missing identity", CodexResetWatchResult(watch: watch(nil))),
            ("empty identity", CodexResetWatchResult(watch: watch("")))
        ]

        for (name, result) in cases {
            await evaluator.receive(result).value
            XCTAssertTrue(recorder.subtitles.isEmpty, name)
        }
        await evaluator.receive(CodexResetWatchResult(watch: valid)).value
        XCTAssertEqual(recorder.subtitles, ["Reset Forecast"])
    }

    func testNewResultsDuringDeliveryInvalidateTheOldEventAndDeliverOnlyTheLatest() async {
        let gate = DeliveryGate()
        let started = expectation(description: "first delivery waiting")
        var attempts = 0
        var currentAfterWait: [Bool] = []
        var delivered: [String] = []
        let evaluator = CodexResetWatchNotificationEvaluator(
            defaults: makeDefaults(), isEnabled: { true }, now: { self.base },
            post: { _, _, subtitle, _, isCurrent in
                attempts += 1
                if attempts == 1 {
                    started.fulfill()
                    await gate.wait()
                }
                let current = isCurrent()
                currentAfterWait.append(current)
                guard current else { return false }
                delivered.append(subtitle)
                return true
            }
        )
        let task = evaluator.receive(CodexResetWatchResult(watch: watch()))
        await fulfillment(of: [started], timeout: 2)
        evaluator.receive(CodexResetWatchResult(watch: watch("watch:intermediate")))
        evaluator.receive(CodexResetWatchResult(watch: watch("scheduled:latest", scheduled: true)))
        await gate.open()
        await task.value

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(currentAfterWait, [false, true])
        XCTAssertEqual(delivered, ["Scheduled Reset"])
    }

    func testOffThenOnInvalidatesInFlightDeliveryEvenWhenTheEventIsUnchanged() async {
        let defaults = makeDefaults()
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.codexResetWatch = true
        let gate = DeliveryGate()
        let started = expectation(description: "delivery before settings change")
        var attempts = 0
        var currentAfterWait: [Bool] = []
        let evaluator = CodexResetWatchNotificationEvaluator(
            defaults: defaults, isEnabled: { settings.codexResetWatch }, now: { self.base },
            post: { _, _, _, _, isCurrent in
                attempts += 1
                if attempts == 1 {
                    started.fulfill()
                    await gate.wait()
                }
                let current = isCurrent()
                currentAfterWait.append(current)
                return current
            }
        )
        settings.onCodexResetWatchChange = { evaluator.configurationDidChange() }
        defer { settings.onCodexResetWatchChange = nil }
        let result = CodexResetWatchResult(watch: watch())
        let task = evaluator.receive(result)
        await fulfillment(of: [started], timeout: 2)

        settings.codexResetWatch = false
        settings.codexResetWatch = true
        evaluator.receive(result)
        await gate.open()
        await task.value
        await evaluator.receive(result).value

        XCTAssertEqual(currentAfterWait, [false, true])
        XCTAssertEqual(attempts, 2)
    }

    func testDisabledProviderSuppressesDeliveryAndInvalidatesAnInFlightRequest() async {
        let gate = DeliveryGate()
        let started = expectation(description: "delivery before provider disablement")
        var providerEnabled = false
        var attempts = 0
        var delivered = 0
        let evaluator = CodexResetWatchNotificationEvaluator(
            defaults: makeDefaults(), isEnabled: { providerEnabled }, now: { self.base },
            post: { _, _, _, _, isCurrent in
                attempts += 1
                if attempts == 1 {
                    started.fulfill()
                    await gate.wait()
                }
                guard isCurrent() else { return false }
                delivered += 1
                return true
            }
        )
        let result = CodexResetWatchResult(watch: watch())
        await evaluator.receive(result).value
        XCTAssertEqual(attempts, 0)

        providerEnabled = true
        evaluator.configurationDidChange()
        let task = evaluator.receive(result)
        await fulfillment(of: [started], timeout: 2)
        providerEnabled = false
        evaluator.configurationDidChange()
        await gate.open()
        await task.value
        XCTAssertEqual(delivered, 0)

        providerEnabled = true
        evaluator.configurationDidChange()
        await evaluator.receive(result).value
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(delivered, 1)
    }

    func testEventExpiringDuringDeliveryIsNotSubmitted() async {
        let clock = Clock(base)
        let deadline = base.addingTimeInterval(10)
        var submitted = false
        let evaluator = CodexResetWatchNotificationEvaluator(
            defaults: makeDefaults(), isEnabled: { true }, now: { clock.date },
            post: { _, _, _, _, isCurrent in
                XCTAssertTrue(isCurrent())
                clock.date = deadline
                guard isCurrent() else { return false }
                submitted = true
                return true
            }
        )

        await evaluator.receive(CodexResetWatchResult(watch: watch(deadline: deadline))).value
        XCTAssertFalse(submitted)
    }

    func testNotificationOptInLoadsHiddenWatchAndStopsWhenDisabled() async {
        let defaults = makeDefaults()
        let settings = NotificationSettingsStore(defaults: defaults)
        let enablement = ProviderEnablementStore(defaults: defaults)
        let recorder = Recorder()
        let loader = LoadProbe(CodexResetWatchResult(watch: watch()))
        let evaluator = makeEvaluator(
            defaults: defaults, clock: Clock(base), recorder: recorder,
            isEnabled: { settings.codexResetWatch && enablement.isEnabled("codex") }
        )
        let coordinator = CodexResetWatchCoordinator(
            load: { _ in await loader.load() },
            publish: { evaluator.receive($0) },
            wait: { _ in false }
        )
        settings.onCodexResetWatchChange = { [weak evaluator] in evaluator?.configurationDidChange() }
        enablement.onChange = { [weak evaluator] in evaluator?.configurationDidChange() }
        defer { coordinator.setActive(false) }
        let metricVisible = false
        coordinator.observeActivity {
            evaluator.configurationDidChange()
            let notificationsEnabled = evaluator.isEnabled()
            return metricVisible || notificationsEnabled
        }
        XCTAssertFalse(coordinator.isActive)

        settings.codexResetWatch = true
        let activated = await eventually { recorder.subtitles == ["Reset Forecast"] }
        XCTAssertTrue(activated)
        XCTAssertTrue(coordinator.isActive)
        let initialLoads = await loader.count
        XCTAssertEqual(initialLoads, 1)

        settings.codexResetWatch = false
        let stoppedBySetting = await eventually { !coordinator.isActive }
        XCTAssertTrue(stoppedBySetting)
        XCTAssertNil(coordinator.nextRefreshAt)
        await coordinator.refreshNow()
        let loadsWhileOff = await loader.count
        XCTAssertEqual(loadsWhileOff, 1)

        settings.codexResetWatch = true
        let reactivated = await eventually { await loader.count == 2 }
        XCTAssertTrue(reactivated)
        enablement.setEnabled(false, for: "codex")
        let stoppedByProvider = await eventually { !coordinator.isActive }
        XCTAssertTrue(stoppedByProvider)
        XCTAssertNil(coordinator.nextRefreshAt)
        await coordinator.refreshNow()
        let finalLoads = await loader.count
        XCTAssertEqual(finalLoads, 2)
        XCTAssertEqual(recorder.subtitles, ["Reset Forecast"])
    }

    func testNotificationTextFollowsLanguageForForecastAndScheduledReset() async {
        let cases: [(LanguageSetting, String, String, String, String, String)] = [
            (.english, "Codex Reset Watch", "Reset Forecast", "Scheduled Reset",
             "A new community forecast for a Codex reset is available.",
             "A community report lists an upcoming Codex reset."),
            (.korean, "Codex 초기화 예측", "초기화 예측", "초기화 예정",
             "Codex 초기화에 대한 새로운 커뮤니티 예측이 있습니다.",
             "커뮤니티에 Codex 초기화 예정 정보가 있습니다."),
            (.japanese, "Codexリセット予測", "リセット予測", "リセット予定",
             "Codexのリセットについて、コミュニティの新しい予測が公開されています。",
             "コミュニティからCodexのリセット予定が報告されています。")
        ]
        for (language, title, forecastSubtitle, scheduledSubtitle, forecastBody, scheduledBody) in cases {
            var messages: [[String]] = []
            let evaluator = CodexResetWatchNotificationEvaluator(
                defaults: makeDefaults(), isEnabled: { true }, now: { self.base },
                post: { id, title, subtitle, body, isCurrent in
                    guard isCurrent() else { return false }
                    messages.append([id, title, subtitle, body])
                    return true
                }
            )
            XCTAssertEqual(L10n.withLanguage(language) { CodexResetWatchNotificationEvaluator.settingLabel }, title)
            for scheduled in [false, true] {
                let delivery = L10n.withLanguage(language) {
                    evaluator.receive(CodexResetWatchResult(watch: watch(
                        scheduled ? "scheduled:localized" : "watch:localized", scheduled: scheduled
                    )))
                }
                await delivery.value
            }
            XCTAssertEqual(messages, [
                ["codex.resetWatch", title, forecastSubtitle, forecastBody],
                ["codex.resetWatch", title, scheduledSubtitle, scheduledBody]
            ])
        }
    }

    private func eventually(_ condition: @escaping @MainActor @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
}
