import XCTest
@testable import OpenUsage

@MainActor
final class LayoutStoreTests: XCTestCase {
    func testRemoveClearsDragStateAndAllowsRepeatedRemoval() {
        let store = makeStore("RepeatedRemoval")
        let first = PlacedWidget(id: UUID(), descriptorID: DefaultLayout.metricIDs[0])
        let second = PlacedWidget(id: UUID(), descriptorID: DefaultLayout.metricIDs[1])
        store.placed = [first, second]
        store.draggingID = first.id

        store.remove(first.id)

        XCTAssertNil(store.draggingID)
        XCTAssertEqual(store.placed, [second])

        store.remove(second.id)

        XCTAssertTrue(store.placed.isEmpty)
    }

    // MARK: - Undo (#603)

    func testUndoRestoresRemovedMetricToSamePosition() {
        let store = makeStore("UndoRestoresPosition")
        // 순서 고정과 이웃 metric 확보를 위해 Claude 전체 set 활성화
        for id in ["claude.session", "claude.weekly", "claude.extra", "claude.today"] {
            store.setMetricEnabled(id, true)
        }
        let orderBefore = store.orderedSupportedMetrics(for: "claude").map(\.id)
        let enabledBefore = store.placed.filter { $0.descriptorID.hasPrefix("claude.") }.map(\.descriptorID)

        store.setMetricEnabled("claude.weekly", false)
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(store.canUndo)

        XCTAssertTrue(store.undo())

        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), orderBefore)
        XCTAssertEqual(
            store.placed.filter { $0.descriptorID.hasPrefix("claude.") }.map(\.descriptorID),
            enabledBefore
        )
    }

    func testUndoReversesEnable() {
        let store = makeStore("UndoEnable")
        // cursor.credits는 DefaultLayout.metricIDs에 없어 mock에서 비활성 시작
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        store.setMetricEnabled("cursor.credits", true)
        XCTAssertTrue(store.isMetricEnabled("cursor.credits"))
        XCTAssertTrue(store.canUndo)

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"), "undo turns an enabled metric back off")
    }

    func testUndoReversesMetricReorder() {
        let store = makeStore("UndoReorderMetric")
        for id in ["claude.session", "claude.weekly", "claude.extra", "claude.today"] {
            store.setMetricEnabled(id, true)
        }
        let orderBefore = store.orderedSupportedMetrics(for: "claude").map(\.id)

        XCTAssertTrue(store.reorderMetric(dragged: "claude.today", target: "claude.session", in: "claude"))
        XCTAssertNotEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), orderBefore)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), orderBefore,
                       "undo restores the exact prior metric order")
    }

    func testUndoReversesProviderReorder() {
        let store = makeStore("UndoReorderProvider")
        let orderBefore = store.customizeGroups.map(\.provider.id)

        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))
        XCTAssertNotEqual(store.customizeGroups.map(\.provider.id), orderBefore)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.customizeGroups.map(\.provider.id), orderBefore,
                       "undo restores the exact prior provider order")
    }

    func testUndoReversesPinAndUnpin() {
        let store = makeStore("UndoPin")
        // cursor.usage는 기본 활성이지만 mock에 cursor 기본 pin이 없어 unpinned 시작
        XCTAssertTrue(store.isMetricEnabled("cursor.usage"))
        XCTAssertFalse(store.isPinned("cursor.usage"))

        store.setPinned(true, for: "cursor.usage")
        XCTAssertTrue(store.isPinned("cursor.usage"))
        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isPinned("cursor.usage"), "undo reverses a pin")

        XCTAssertTrue(store.isPinned("claude.weekly"))
        store.setPinned(false, for: "claude.weekly")
        XCTAssertFalse(store.isPinned("claude.weekly"))
        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isPinned("claude.weekly"), "undo reverses an unpin")
    }

    func testUndoReversesExpandedMove() {
        let store = makeStore("UndoExpandedMove")
        // claude.session은 DefaultLayout.expandedMetricIDs에 없어 기본 above the fold
        XCTAssertFalse(store.expandedMetricIDs.contains("claude.session"))

        XCTAssertTrue(moveMetric("claude.session", expanded: true, in: store))
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.session"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.expandedMetricIDs.contains("claude.session"), "undo moves the metric back above the caret")
    }

    func testUndoDoesNotRestoreProviderCardCaretState() {
        // provider card 펼침은 transient view state — snapshot이 expandedProviderIDs를 잘못 담던 회귀 방지
        let store = makeStore("UndoLeavesProviderCaret")
        XCTAssertFalse(store.isProviderExpanded("codex"))

        XCTAssertTrue(store.setProviderExpanded(true, for: "codex"))
        XCTAssertTrue(store.isProviderExpanded("codex"))
        store.setMetricEnabled("cursor.credits", true)
        XCTAssertTrue(store.canUndo)

        // step 기록 후 card를 접고 undo
        XCTAssertTrue(store.setProviderExpanded(false, for: "codex"))
        XCTAssertFalse(store.isProviderExpanded("codex"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))
        XCTAssertFalse(store.isProviderExpanded("codex"), "undo must not restore provider card caret state")
    }

    func testUndoWalksBackMultipleMixedSteps() {
        let store = makeStore("UndoMultiStep")
        store.setMetricEnabled("cursor.credits", true)
        store.setPinned(true, for: "cursor.usage")
        store.setMetricEnabled("claude.session", false)

        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isPinned("cursor.usage"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isPinned("cursor.usage"))
        XCTAssertTrue(store.isMetricEnabled("cursor.credits"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testUndoIsNotItselfRecorded() {
        // undo 자체가 step으로 기록되면 ⌘Z가 무한 왕복 — 미기록 보장
        let store = makeStore("UndoNotRecorded")
        store.setMetricEnabled("cursor.credits", true)
        XCTAssertTrue(store.canUndo)

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.canUndo, "undo leaves nothing new to undo")
    }

    func testUndoStackIsCappedAtMaxDepth() {
        let store = makeStore("UndoMaxDepth")
        // pin 토글 반복으로 cap 초과 step 생성
        store.setMetricEnabled("claude.weekly", true)
        var pinned = false
        for _ in 0..<(LayoutUndoHistory.maxDepth + 10) {
            pinned.toggle()
            store.setPinned(pinned, for: "claude.weekly")
        }
        var steps = 0
        while store.undo() { steps += 1 }
        XCTAssertEqual(steps, LayoutUndoHistory.maxDepth)
    }

    func testNoOpActionDoesNotRecordUndoStep() {
        let store = makeStore("UndoNoOp")
        store.setMetricEnabled("cursor.credits", true)  // 실제 step 1건
        // 이미 켜진 metric 재활성화·self-target reorder는 no-op — step 미기록
        store.setMetricEnabled("cursor.credits", true)
        store.reorderMetric(dragged: "claude.weekly", target: "claude.weekly", in: "claude")

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.canUndo)
    }

    func testUndoWithEmptyHistoryIsNoOp() {
        let store = makeStore("UndoEmpty")
        let before = store.placed.map(\.descriptorID)

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
        XCTAssertEqual(store.placed.map(\.descriptorID), before)
    }

    func testResetToDefaultClearsUndoHistory() {
        let store = makeStore("UndoResetAllClears")
        store.setMetricEnabled("claude.weekly", true)
        store.setMetricEnabled("claude.weekly", false)
        XCTAssertTrue(store.canUndo)

        store.resetToDefault()

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testResetProviderClearsUndoHistory() {
        let store = makeStore("UndoResetProviderClears")
        store.setMetricEnabled("cursor.credits", true)
        store.setMetricEnabled("cursor.requests", true)
        XCTAssertTrue(store.canUndo)

        store.resetProvider("claude")

        // snapshot은 whole-layout 단위 — reset은 전체 stack 폐기
        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testDirectRemoveDoesNotRecordUndo() {
        // 저수준 `remove(_:)`는 user-facing seam이 아니어서 undo stack 미기록
        let store = makeStore("UndoDirectRemove")
        store.placed = [PlacedWidget(descriptorID: "claude.weekly")]
        guard let widget = store.placed.first(where: { $0.descriptorID == "claude.weekly" }) else {
            return XCTFail("metric was not placed")
        }

        store.remove(widget.id)

        XCTAssertFalse(store.canUndo)
    }

    func testSavedEmptyLayoutDoesNotRestoreDefaults() {
        let defaults = makeDefaults("EmptyLayout")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")

        for widget in store.placed {
            store.remove(widget.id)
        }

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.placed.isEmpty)
    }

    func testUnreadableStoredLayoutIsNotMistakenForFreshInstall() {
        let defaults = makeDefaults("UnreadableExistingLayout")
        defaults.set(Data("not valid layout data".utf8), forKey: "layout")

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultExpandedMetricIDs: ["claude.weekly"]
        )

        XCTAssertFalse(
            store.expandedMetricIDs.contains("claude.weekly"),
            "present but damaged data is still an existing layout, so fresh-only defaults must stay off"
        )
    }

    func testUnreadableSeedMarkerKeepsExistingUserBaseline() {
        let defaults = makeDefaults("UnreadableSeedMarker")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        defaults.set(Data("not valid seeded-default data".utf8), forKey: "layout.seededDefaults")

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"]
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.session"])
    }

    func testExistingLayoutAutoSeedsOnlyDefaultsAddedAfterBaseline() {
        let defaults = makeDefaults("SeedNewDefault")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"]
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.session", "claude.today"])
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"), "baseline defaults the user already removed stay off")
    }

    func testDisablingAutoSeededDefaultDoesNotReAddOnReload() {
        let defaults = makeDefaults("SeedOnce")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"]
        )
        guard let seeded = store.placed.first(where: { $0.descriptorID == "claude.today" }) else {
            return XCTFail("new default was not seeded")
        }

        store.remove(seeded.id)

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"]
        )
        XCTAssertEqual(reloaded.placed.map(\.descriptorID), ["claude.session"])
    }

    func testFreshLayoutTreatsCurrentDefaultsAsAlreadySeeded() {
        let defaults = makeDefaults("FreshSeeded")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: []
        )
        guard let today = store.placed.first(where: { $0.descriptorID == "claude.today" }) else {
            return XCTFail("fresh store did not include all current defaults")
        }

        store.remove(today.id)

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: []
        )
        XCTAssertEqual(reloaded.placed.map(\.descriptorID), ["claude.session"])
    }

    func testAutoSeedingIgnoresUnknownDefaultIDs() {
        let defaults = makeDefaults("UnknownSeed")
        saveStored([PlacedWidget](), forKey: "layout", in: defaults)

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["missing.metric", "claude.session"],
            migrationBaselineMetricIDs: []
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.session"])
    }

    func testExistingLayoutEnablesDefaultExpandedOptionalBelowCaret() {
        let defaults = makeDefaults("LegacyEnableExpanded")
        saveStored([PlacedWidget(descriptorID: "cursor.usage")], forKey: "layout", in: defaults)
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage"],
            migrationBaselineMetricIDs: ["cursor.usage"],
            defaultExpandedMetricIDs: ["cursor.requests"]
        )

        XCTAssertFalse(store.isMetricEnabled("cursor.requests"))
        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.requests"))

        store.setMetricEnabled("cursor.requests", true)

        XCTAssertTrue(store.isMetricEnabled("cursor.requests"))
        XCTAssertTrue(store.expandedMetricIDs.contains("cursor.requests"))
    }

    func testNewlySeededDefaultExpandedMetricEntersBelowCaretForExistingLayout() {
        let defaults = makeDefaults("SeedNewExpanded")
        // 신규 metric 출시 이전의 기존 layout + 그 metric을 모르는 저장된 expanded set fixture
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        defaults.set(["claude.weekly"], forKey: "layout.expandedMetrics")

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: ["claude.today"]
        )

        // 신규 default는 migration으로 auto-enable + caret 아래 배치, 기존 metric은 always-shown 유지
        XCTAssertTrue(store.isMetricEnabled("claude.today"))
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.today"))
        XCTAssertFalse(store.expandedMetricIDs.contains("claude.session"))

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: ["claude.today"]
        )
        XCTAssertTrue(reloaded.expandedMetricIDs.contains("claude.today"))
    }

    func testMigrationPersistKeepsLegacyOptionalMetricExpandOnEnableAfterReload() {
        let defaults = makeDefaults("SeedExpandedKeepsFallback")
        // legacy layout fixture — expanded 기능 이전이라 저장된 expanded set 없음
        saveStored([PlacedWidget(descriptorID: "cursor.usage")], forKey: "layout", in: defaults)

        let args: (UserDefaults) -> LayoutStore = { d in
            LayoutStore(
                registry: .mock,
                defaults: d,
                storageKey: "layout",
                defaultMetricIDs: ["cursor.usage", "claude.today"],
                migrationBaselineMetricIDs: ["cursor.usage"],
                // claude.today는 신규 default, cursor.requests는 미활성 optional default-expanded metric
                defaultExpandedMetricIDs: ["claude.today", "cursor.requests"]
            )
        }

        // 첫 launch에서 migration 수행·expanded set 저장
        _ = args(defaults)

        // 회귀 방지: migration 저장이 on-enable queue를 비워 legacy optional metric의 caret 아래 진입이 깨지던 문제
        let reloaded = args(defaults)
        XCTAssertFalse(reloaded.expandedMetricIDs.contains("cursor.requests"))
        reloaded.setMetricEnabled("cursor.requests", true)
        XCTAssertTrue(reloaded.expandedMetricIDs.contains("cursor.requests"))
    }

    func testConsumedExpandOnEnableStaysConsumedAcrossRelaunch() {
        let defaults = makeDefaults("ExpandOnEnablePersists")
        saveStored([PlacedWidget(descriptorID: "cursor.usage")], forKey: "layout", in: defaults)

        let args: (UserDefaults) -> LayoutStore = { d in
            LayoutStore(
                registry: .mock,
                defaults: d,
                storageKey: "layout",
                defaultMetricIDs: ["cursor.usage"],
                migrationBaselineMetricIDs: ["cursor.usage"],
                defaultExpandedMetricIDs: ["cursor.requests"]
            )
        }

        // 비활성 optional metric을 divider 위로 drag — expand-on-enable default 소비
        let store = args(defaults)
        XCTAssertTrue(store.reorderMetric(dragged: "cursor.requests", target: "cursor.usage", in: "cursor"))
        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.requests"))

        // 회귀 방지: launch마다 queue 재계산으로 소비된 entry가 부활하던 문제
        let reloaded = args(defaults)
        reloaded.setMetricEnabled("cursor.requests", true)
        XCTAssertTrue(reloaded.isMetricEnabled("cursor.requests"))
        XCTAssertFalse(reloaded.expandedMetricIDs.contains("cursor.requests"))
    }

    func testExplicitDividerMoveOverridesDefaultExpandedOnEnable() {
        let defaults = makeDefaults("LegacyEnableExpandedOverride")
        saveStored([PlacedWidget(descriptorID: "cursor.usage")], forKey: "layout", in: defaults)
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage"],
            migrationBaselineMetricIDs: ["cursor.usage"],
            defaultExpandedMetricIDs: ["cursor.requests"]
        )
        let divider = "cursor::expanded-divider"

        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.usage",
            "cursor.requests",
            divider,
            "cursor.credits",
            "cursor.today"
        ], dragged: "cursor.requests", dividerID: divider, in: "cursor"))
        store.setMetricEnabled("cursor.requests", true)

        XCTAssertTrue(store.isMetricEnabled("cursor.requests"))
        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.requests"))

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage"],
            migrationBaselineMetricIDs: ["cursor.usage"],
            defaultExpandedMetricIDs: ["cursor.requests"]
        )
        reloaded.setMetricEnabled("cursor.requests", true)
        XCTAssertFalse(reloaded.expandedMetricIDs.contains("cursor.requests"))
    }

    func testPrimaryDividerReorderDoesNotConsumeHiddenDefaultExpandedOnEnable() {
        let defaults = makeDefaults("LegacyPrimaryReorderKeepsFallback")
        saveStored([
            PlacedWidget(descriptorID: "cursor.usage"),
            PlacedWidget(descriptorID: "cursor.today")
        ], forKey: "layout", in: defaults)
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            migrationBaselineMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: ["cursor.requests"]
        )
        let divider = "cursor::expanded-divider"

        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.today",
            "cursor.usage",
            divider
        ], dragged: "cursor.today", dividerID: divider, in: "cursor"))
        store.setMetricEnabled("cursor.requests", true)

        XCTAssertTrue(store.expandedMetricIDs.contains("cursor.requests"))
    }

    func testCustomizeReorderDoesNotConsumeUnmovedDisabledExpandOnEnable() {
        let defaults = makeDefaults("CustomizePrimaryReorderKeepsUnmovedFallback")
        saveStored([
            PlacedWidget(descriptorID: "cursor.usage"),
            PlacedWidget(descriptorID: "cursor.today")
        ], forKey: "layout", in: defaults)
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            migrationBaselineMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: ["cursor.requests"]
        )
        let divider = "cursor::expanded-divider"

        // Customize는 primary만 reorder해도 full metric list 전달 — drag 대상이 아닌 cursor.requests의 below-caret default 유지
        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.today",
            "cursor.usage",
            "cursor.requests",
            divider
        ], dragged: "cursor.today", dividerID: divider, in: "cursor"))
        store.setMetricEnabled("cursor.requests", true)

        XCTAssertTrue(store.expandedMetricIDs.contains("cursor.requests"))
    }

    func testAddAndResetCancelDragState() {
        let store = makeStore("CancelDrag")
        let first = store.placed[0]

        store.draggingID = first.id
        store.remove(first.id)
        XCTAssertNil(store.draggingID)

        store.draggingID = UUID()
        store.add(first.descriptorID)
        XCTAssertNil(store.draggingID)

        store.draggingID = UUID()
        store.resetToDefault()
        XCTAssertNil(store.draggingID)
    }

    func testAddAndRemoveTogglePlacement() {
        let store = makeStore("Toggle")
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        store.add("cursor.credits")
        XCTAssertTrue(store.isMetricEnabled("cursor.credits"))

        guard let widget = store.placed.first(where: { $0.descriptorID == "cursor.credits" }) else {
            return XCTFail("missing widget")
        }
        store.remove(widget.id)
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))
    }

    func testTogglingMetricDoesNotChangeCustomizeOrder() {
        let store = makeStore("ToggleKeepsOrder")
        let before = store.orderedSupportedMetrics(for: "cursor").map(\.id)
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        store.setMetricEnabled("cursor.credits", true)
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), before)

        store.setMetricEnabled("cursor.credits", false)
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), before)
    }

    func testFreshCustomizeOrderFollowsProviderDeclarations() {
        let registry = WidgetRegistry.from([
            ClaudeProvider(),
            CodexProvider(),
            DevinProvider(),
            GrokProvider(),
            CursorProvider()
        ])
        let store = LayoutStore(registry: registry, defaults: makeDefaults("FreshCustomizeOrder"), storageKey: "layout")

        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), [
            "claude.session", "claude.weekly", "claude.fable", "claude.trend", "claude.extra",
            "claude.sonnet", "claude.today", "claude.yesterday", "claude.last30"
        ])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "codex").map(\.id), [
            "codex.session", "codex.weekly", "codex.trend", "codex.rateLimitResets",
            "codex.spark", "codex.sparkWeekly", "codex.credits",
            "codex.today", "codex.yesterday", "codex.last30"
        ])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "devin").map(\.id), [
            "devin.daily", "devin.weekly", "devin.extra"
        ])
        XCTAssertEqual(store.orderedSupportedMetrics(for: "grok").map(\.id), [
            "grok.weekly", "grok.payAsYouGo",
            "grok.trend", "grok.today", "grok.yesterday", "grok.last30"
        ])
        // Cursor spend tile + usage trend 활성 — live meter 뒤에 선언 순서로 배치
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), [
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.onDemand", "cursor.requests",
            "cursor.credits", "cursor.trend", "cursor.today", "cursor.yesterday", "cursor.last30"
        ])
    }

    func testFreshDefaultLayoutMatchesRecommendedMetricSections() {
        let registry = WidgetRegistry.from([
            ClaudeProvider(),
            CodexProvider(),
            DevinProvider(),
            GrokProvider(),
            CursorProvider()
        ])
        let store = LayoutStore(registry: registry, defaults: makeDefaults("RecommendedDefaults"), storageKey: "layout")

        XCTAssertEqual(Set(store.placed.map(\.descriptorID)), Set([
            "claude.session", "claude.weekly", "claude.fable", "claude.trend",
            "claude.today", "claude.yesterday",
            "codex.session", "codex.weekly", "codex.trend", "codex.rateLimitResets",
            "codex.today", "codex.yesterday",
            "devin.daily", "devin.weekly", "devin.extra",
            "grok.weekly", "grok.trend",
            "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",
            // Cursor spend tile + usage trend는 기본 layout에서 활성
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend",
            "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30"
        ]))
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))
        XCTAssertFalse(store.isMetricEnabled("claude.sonnet"))
        XCTAssertFalse(store.isMetricEnabled("claude.last30"))
        XCTAssertFalse(store.isMetricEnabled("codex.spark"))
        XCTAssertFalse(store.isMetricEnabled("codex.sparkWeekly"))
        XCTAssertFalse(store.isMetricEnabled("codex.credits"))
        XCTAssertFalse(store.isMetricEnabled("codex.last30"))
        XCTAssertFalse(store.isMetricEnabled("cursor.requests"))
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        let primaryByProvider = Dictionary(uniqueKeysWithValues: store.customizeGroups.map {
            ($0.provider.id, $0.alwaysShownMetrics.map(\.id))
        })
        let expandedByProvider = Dictionary(uniqueKeysWithValues: store.customizeGroups.map {
            ($0.provider.id, $0.expandedMetrics.map(\.id))
        })

        XCTAssertEqual(primaryByProvider["claude"], ["claude.session", "claude.weekly", "claude.fable"])
        XCTAssertEqual(expandedByProvider["claude"], [
            "claude.trend", "claude.extra", "claude.sonnet",
            "claude.today", "claude.yesterday", "claude.last30"
        ])
        XCTAssertEqual(primaryByProvider["codex"], ["codex.session", "codex.weekly"])
        XCTAssertEqual(expandedByProvider["codex"], [
            "codex.trend", "codex.rateLimitResets", "codex.spark", "codex.sparkWeekly",
            "codex.credits", "codex.today", "codex.yesterday", "codex.last30"
        ])
        XCTAssertEqual(primaryByProvider["devin"], ["devin.daily", "devin.weekly"])
        XCTAssertEqual(expandedByProvider["devin"], ["devin.extra"])
        XCTAssertEqual(primaryByProvider["grok"], ["grok.weekly", "grok.trend"])
        XCTAssertEqual(expandedByProvider["grok"], [
            "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30"
        ])
        // Cursor는 trend가 primary, today/yesterday/last30은 caret 아래 배치
        XCTAssertEqual(primaryByProvider["cursor"], ["cursor.usage", "cursor.auto", "cursor.api", "cursor.trend"])
        XCTAssertEqual(expandedByProvider["cursor"], [
            "cursor.onDemand", "cursor.requests", "cursor.credits",
            "cursor.today", "cursor.yesterday", "cursor.last30"
        ])
    }

    func testSavedCustomizationWinsOverChangedForkDefaults() throws {
        let defaults = makeDefaults("SavedCustomization")
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([
            PlacedWidget(descriptorID: "claude.session"),
            PlacedWidget(descriptorID: "claude.weekly")
        ])
        persistence.saveMetricOrder(["claude": ["claude.weekly", "claude.session"]])
        persistence.saveSeededDefaults(Set(DefaultLayout.metricIDs))
        persistence.savePins([])
        persistence.saveExpandedMetrics(["claude.weekly"])

        let store = LayoutStore(
            registry: WidgetRegistry.from([ClaudeProvider()]),
            defaults: defaults,
            storageKey: "layout"
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.weekly", "claude.session"])
        XCTAssertEqual(Array(store.orderedSupportedMetrics(for: "claude").map(\.id).prefix(2)), [
            "claude.weekly", "claude.session"
        ])
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)
        XCTAssertEqual(store.expandedMetricIDs, ["claude.weekly"])
    }

    func testMetricOrderPersistsWhileMetricIsDisabled() {
        let defaults = makeDefaults("DisabledMetricOrder")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: []
        )
        let original = store.orderedSupportedMetrics(for: "claude").map(\.id)
        guard let first = original.first else { return XCTFail("missing Claude metrics") }
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        store.reorderMetric(dragged: "claude.extra", target: first, in: "claude")

        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: []
        )
        XCTAssertEqual(reloaded.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")

        reloaded.setMetricEnabled("claude.extra", true)
        XCTAssertEqual(reloaded.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")
    }

    func testFreshStoreSeedsDefaultPins() {
        let store = makeStore("SeedPins")
        let expected = Set(DefaultLayout.pinnedMetricIDs.filter { MockData.descriptor($0) != nil })

        XCTAssertFalse(expected.isEmpty, "fixture registry should know some default-pinned metrics")
        XCTAssertEqual(store.pinnedMetricIDs, expected)
    }

    func testUnpinningEverythingPersistsAndIsNotReseeded() {
        let defaults = makeDefaults("UnpinAll")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(store.pinnedMetricIDs.isEmpty)

        for id in store.pinnedMetricIDs { store.setPinned(false, for: id) }
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.pinnedMetricIDs.isEmpty, "an explicitly emptied pin set must not be reseeded")
    }

    func testResetToDefaultRestoresDefaultPins() {
        let store = makeStore("ResetPins")
        for id in store.pinnedMetricIDs { store.setPinned(false, for: id) }
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)

        store.resetToDefault()

        let expected = Set(DefaultLayout.pinnedMetricIDs.filter { MockData.descriptor($0) != nil })
        XCTAssertEqual(store.pinnedMetricIDs, expected)
    }

    func testProviderReorderPreservesAnAbsentAccountCardSlot() {
        let defaults = makeDefaults("ReorderAbsentAccountCard")
        let storageKey = "layout"
        let hidden = "claude@hidden"
        LayoutPersistence(defaults: defaults, storageKey: storageKey).saveProviderOrder([
            "claude", hidden, "cursor",
        ])
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: storageKey)

        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))

        XCTAssertEqual(Array(store.providerOrder.prefix(3)), ["cursor", hidden, "claude"])
        XCTAssertEqual(
            LayoutPersistence(defaults: defaults, storageKey: storageKey).loadProviderOrder()?.contains(hidden),
            true,
            "the absent card keeps its slot for the launch it returns on"
        )
    }

    func testAnAccountCardInheritsTheProvidersSavedLayout() {
        // 카드 전용 설정은 없음 — 새 카드는 사용자가 family에 남긴 선택을 그대로 렌더
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let work = Provider(id: "claude@work", displayName: "Claude — Work", icon: .providerMark("claude"))
        func descriptor(_ id: String, _ provider: Provider) -> WidgetDescriptor {
            WidgetDescriptor(
                id: id,
                providerID: provider.id,
                metricLabel: id,
                sample: WidgetData(title: id, icon: provider.icon, kind: .percent, used: 0, limit: 100)
            )
        }
        let registry = WidgetRegistry(
            providers: [claude, work],
            descriptors: [
                descriptor("claude.session", claude),
                descriptor("claude.sonnet", claude),
                descriptor("claude@work.session", work),
                descriptor("claude@work.sonnet", work),
            ]
        )
        let defaults = makeDefaults("AccountCardSeeding")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        defaults.set(["claude.session", "claude.sonnet"], forKey: "layout.seededDefaults")

        let store = LayoutStore(
            registry: registry,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: ["claude.sonnet"]
        )

        XCTAssertTrue(store.isMetricEnabled("claude@work.session"))
        XCTAssertFalse(
            store.isMetricEnabled("claude.sonnet"),
            "the family's own disabled default stays exactly as the user left it"
        )
        XCTAssertFalse(
            store.isMetricEnabled("claude@work.sonnet"),
            "the card follows the family's choice instead of re-seeding its own copy"
        )
        XCTAssertEqual(
            store.defaultExpandedOnEnableIDs,
            ["claude.sonnet"],
            "the caret split stays a single family entry"
        )
    }

    func testResetToDefaultRestoresProviderOrderAndMarksDefaultsSeeded() {
        let defaults = makeDefaults("ResetSeeded")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: []
        )
        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))

        store.resetToDefault()
        XCTAssertEqual(store.customizeGroups.map(\.provider.id), MockData.providers.map(\.id))
        guard let today = store.placed.first(where: { $0.descriptorID == "claude.today" }) else {
            return XCTFail("reset did not restore current defaults")
        }

        store.remove(today.id)

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: []
        )
        XCTAssertEqual(reloaded.placed.map(\.descriptorID), ["claude.session"])
    }

    // MARK: - On Demand membership

    func testDividerDragMovesMetricBelowDividerAndPersists() {
        let defaults = makeDefaults("ExpandMove")
        // hermetic fixture — DefaultLayout seeding과 무관하게 caret 아래를 비운 상태로 시작
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout", defaultExpandedMetricIDs: [])
        guard let first = store.orderedSupportedMetrics(for: "claude").map(\.id).first else {
            return XCTFail("missing Claude metrics")
        }
        XCTAssertFalse(store.expandedMetricIDs.contains(first))

        XCTAssertTrue(moveMetric(first, expanded: true, in: store))
        XCTAssertTrue(store.expandedMetricIDs.contains(first))

        let group = store.customizeGroups.first { $0.provider.id == "claude" }
        XCTAssertEqual(group?.expandedMetrics.map(\.id).first, first)
        XCTAssertFalse(group?.alwaysShownMetrics.map(\.id).contains(first) ?? true)

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.expandedMetricIDs.contains(first))
    }

    func testDividerDragIsNoOpWhenAlreadyInSection() {
        let store = LayoutStore(registry: .mock, defaults: makeDefaults("ExpandNoOp"), storageKey: "layout", defaultExpandedMetricIDs: [])
        guard let id = store.orderedSupportedMetrics(for: "claude").map(\.id).first else {
            return XCTFail("missing Claude metrics")
        }
        XCTAssertFalse(moveMetric(id, expanded: false, in: store), "already always-shown")
        XCTAssertTrue(moveMetric(id, expanded: true, in: store))
        XCTAssertFalse(moveMetric(id, expanded: true, in: store), "already expanded")
    }

    func testDraggingMetricOntoExpandedRowTucksItAway() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DragAcross"),
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: []
        )
        let ids = store.orderedSupportedMetrics(for: "cursor").map(\.id)
        guard ids.count >= 2, let dragged = ids.first, let target = ids.last else {
            return XCTFail("need at least two Cursor metrics")
        }
        XCTAssertTrue(moveMetric(target, expanded: true, in: store))
        XCTAssertFalse(store.expandedMetricIDs.contains(dragged))

        XCTAssertTrue(store.reorderMetric(dragged: dragged, target: target, in: "cursor"))

        XCTAssertTrue(store.expandedMetricIDs.contains(dragged), "dropping onto an expanded row moves the dragged row across")
        let expanded = store.customizeGroups.first { $0.provider.id == "cursor" }?.expandedMetrics.map(\.id) ?? []
        XCTAssertTrue(expanded.contains(dragged) && expanded.contains(target))
    }

    func testDraggingExpandedMetricOntoAlwaysShownRowBringsItBack() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DragBack"),
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: []
        )
        let ids = store.orderedSupportedMetrics(for: "cursor").map(\.id)
        guard ids.count >= 2, let target = ids.first, let dragged = ids.last else {
            return XCTFail("need at least two Cursor metrics")
        }
        XCTAssertTrue(moveMetric(dragged, expanded: true, in: store))

        XCTAssertTrue(store.reorderMetric(dragged: dragged, target: target, in: "cursor"))
        XCTAssertFalse(store.expandedMetricIDs.contains(dragged), "dropping onto an always-shown row brings the dragged row back")
    }

    func testApplyingDividerOrderMovesMetricBelowFold() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DividerDown"),
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: []
        )
        let divider = "cursor::expanded-divider"

        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.usage",
            divider,
            "cursor.requests",
            "cursor.credits",
            "cursor.today"
        ], dragged: "cursor.requests", dividerID: divider, in: "cursor"))

        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.usage"))
        XCTAssertTrue(store.expandedMetricIDs.contains("cursor.requests"))
    }

    func testApplyingDividerOrderMovesMetricAboveFold() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DividerUp"),
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: []
        )
        let divider = "cursor::expanded-divider"
        XCTAssertTrue(moveMetric("cursor.requests", expanded: true, in: store))

        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.usage",
            "cursor.requests",
            divider,
            "cursor.credits",
            "cursor.today"
        ], dragged: "cursor.requests", dividerID: divider, in: "cursor"))

        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.requests"))
    }

    func testApplyingVisibleDividerOrderKeepsDisabledMetricsInPlace() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("VisibleDividerKeepsDisabled"),
            storageKey: "layout",
            defaultMetricIDs: ["cursor.usage", "cursor.today"],
            defaultExpandedMetricIDs: ["cursor.requests", "cursor.today"]
        )
        let divider = "cursor::expanded-divider"

        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))
        XCTAssertFalse(store.isMetricEnabled("cursor.requests"))
        XCTAssertTrue(store.applyMetricDividerOrder([
            "cursor.usage",
            "cursor.today",
            divider
        ], dragged: "cursor.today", dividerID: divider, in: "cursor"))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), [
            "cursor.usage", "cursor.credits", "cursor.today", "cursor.requests"
        ])
        XCTAssertFalse(store.expandedMetricIDs.contains("cursor.today"))
        XCTAssertTrue(store.expandedMetricIDs.contains("cursor.requests"))
    }

    func testDisabledMetricKeepsExpandedMembership() {
        let defaults = makeDefaults("DisabledExpanded")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: []
        )
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        XCTAssertTrue(moveMetric("claude.extra", expanded: true, in: store))
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.extra"))
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            defaultExpandedMetricIDs: []
        )
        XCTAssertTrue(reloaded.expandedMetricIDs.contains("claude.extra"))
    }

    func testFreshLayoutSeedsDefaultExpanded() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("FreshExpanded"),
            storageKey: "layout",
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.weekly"))
    }

    func testExistingLayoutDoesNotSeedExpanded() {
        let defaults = makeDefaults("ExistingNoExpand")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        XCTAssertFalse(store.expandedMetricIDs.contains("claude.weekly"), "an existing layout keeps every metric always-shown")
    }

    func testResetRestoresDefaultExpanded() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("ResetExpand"),
            storageKey: "layout",
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        XCTAssertTrue(moveMetric("claude.weekly", expanded: false, in: store))
        XCTAssertFalse(store.expandedMetricIDs.contains("claude.weekly"))

        store.resetToDefault()
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.weekly"))
    }

    func testUnknownPersistedExpandedIDsAreRetainedAsInvisibleTombstones() {
        let defaults = makeDefaults("InvalidExpand")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        defaults.set(["claude.session", "missing.metric"], forKey: "layout.expandedMetrics")

        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.expandedMetricIDs.contains("claude.session"))
        XCTAssertTrue(
            store.expandedMetricIDs.contains("missing.metric"),
            "unknown state stays persisted so a temporarily absent account card can recover it"
        )
    }

    func testDisplayGroupsPartitionEnabledMetrics() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DisplayPartition"),
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            defaultExpandedMetricIDs: []
        )
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))

        XCTAssertTrue(moveMetric("claude.weekly", expanded: true, in: store))

        let group = store.displayGroups.first { $0.provider.id == "claude" }
        XCTAssertEqual(group?.alwaysShownWidgets.compactMap { store.descriptor(for: $0)?.id }, ["claude.session"])
        XCTAssertEqual(group?.expandedWidgets.compactMap { store.descriptor(for: $0)?.id }, ["claude.weekly"])
        XCTAssertEqual(group?.hasExpandedMetrics, true)
    }

    func testProviderWithOnlyExpandedMetricsStillShowsRows() {
        // session + weekly만 활성 후 둘 다 expand — provider 전체가 expanded가 되는 fixture
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("AllExpanded"),
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            defaultExpandedMetricIDs: []
        )
        XCTAssertTrue(moveMetric("claude.session", expanded: true, in: store))
        XCTAssertTrue(moveMetric("claude.weekly", expanded: true, in: store))

        let group = store.displayGroups.first { $0.provider.id == "claude" }
        XCTAssertNotNil(group)
        XCTAssertFalse(group?.alwaysShownWidgets.isEmpty ?? true, "all-expanded metrics are promoted so the card is never empty")
        XCTAssertTrue(group?.expandedWidgets.isEmpty ?? false)
    }

    func testProviderExpandedStatePersistsAcrossReload() {
        let defaults = makeDefaults("ProviderExpanded")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.setProviderExpanded(true, for: "codex"))
        XCTAssertTrue(store.isProviderExpanded("codex"))

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.isProviderExpanded("codex"))
    }

    func testProviderExpandedStateCanCollapseAndPersists() {
        let defaults = makeDefaults("ProviderCollapsed")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.setProviderExpanded(true, for: "codex"))
        XCTAssertTrue(store.setProviderExpanded(false, for: "codex"))

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(reloaded.isProviderExpanded("codex"))
    }

    func testInvalidPersistedExpandedProviderIDsAreDropped() {
        let defaults = makeDefaults("InvalidProviderExpanded")
        defaults.set(["codex", "missing"], forKey: "layout.expandedProviders")

        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.isProviderExpanded("codex"))
        XCTAssertFalse(store.isProviderExpanded("missing"))
    }

    func testResetClearsProviderExpandedState() {
        let store = LayoutStore(registry: .mock, defaults: makeDefaults("ResetProviderExpanded"), storageKey: "layout")
        XCTAssertTrue(store.setProviderExpanded(true, for: "codex"))

        store.resetToDefault()

        XCTAssertFalse(store.isProviderExpanded("codex"))
    }

    func testResetProviderRestoresOneProviderAndLeavesOthersAndOrderUntouched() {
        let defaults = makeDefaults("ResetOneProvider")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "codex.session"],
            migrationBaselineMetricIDs: [],
            defaultPinnedMetricIDs: ["claude.session", "codex.session"],
            defaultExpandedMetricIDs: []
        )

        // per-provider reset의 provider 순서 보존 확인용 사전 reorder
        store.reorderProvider(dragged: "cursor", target: "claude")
        let orderBefore = store.customizeGroups.map(\.provider.id)

        // reset이 복원할 모든 차원에서 Claude를 default와 다르게 변경
        store.setMetricEnabled("claude.weekly", true)
        store.setPinned(true, for: "claude.weekly")
        store.setProviderExpanded(true, for: "claude")
        store.reorderMetric(dragged: "claude.extra", target: "claude.session", in: "claude")

        // Claude reset이 건드리면 안 되는 Codex도 변경
        store.setMetricEnabled("codex.weekly", true)
        store.setPinned(true, for: "codex.weekly")

        store.resetProvider("claude")

        // Claude: enabled set·metric 순서·pin·expanded 상태 모두 default 복원
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(store.isPinned("claude.session"))
        XCTAssertFalse(store.isPinned("claude.weekly"))
        XCTAssertFalse(store.isProviderExpanded("claude"))
        XCTAssertEqual(
            store.orderedSupportedMetrics(for: "claude").map(\.id),
            MockData.descriptors(for: "claude").map(\.id)
        )

        // Codex는 영향 없음
        XCTAssertTrue(store.isMetricEnabled("codex.weekly"))
        XCTAssertTrue(store.isPinned("codex.weekly"))

        // provider 순서 유지 — contents-only reset
        XCTAssertEqual(store.customizeGroups.map(\.provider.id), orderBefore)
    }

    func testResetProviderIsNoOpForUnknownProvider() {
        let store = makeStore("ResetUnknownProvider")
        let before = store.placed.map(\.descriptorID)
        store.resetProvider("nope")
        XCTAssertEqual(store.placed.map(\.descriptorID), before)
    }

    // MARK: - Customize master/detail (L1 list + L2 detail)

    func testCustomizeProviderRowsIncludesAllProvidersRegardlessOfEnablement() {
        // Codex 비활성 시에도 L1 목록에 registry 순서대로 표시(greyed)
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("RowsIncludeDisabled"),
            storageKey: "layout",
            isProviderEnabled: { id in id != "codex" }
        )
        XCTAssertEqual(store.customizeProviderRows.map(\.id), MockData.providers.map(\.id))
        let codex = store.customizeProviderRows.first { $0.id == "codex" }
        XCTAssertNotNil(codex, "disabled provider stays visible in L1")
        XCTAssertFalse(codex?.isEnabled ?? true, "disabled provider row reports isEnabled false")
        XCTAssertTrue(store.customizeProviderRows.first { $0.id == "claude" }?.isEnabled ?? false)
    }

    func testCustomizeProviderRowsCarriesMetricCounts() {
        let store = makeStore("RowCounts")
        for row in store.customizeProviderRows {
            XCTAssertEqual(row.metricCount, MockData.descriptors(for: row.id).count)
        }
    }

    func testCustomizeDetailReturnsMetricsEvenWhenDisabled() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DetailWhenDisabled"),
            storageKey: "layout",
            isProviderEnabled: { id in id != "codex" }
        )
        // customizeGroups는 disabled provider 제외, customizeDetail은 포함
        XCTAssertNil(store.customizeGroups.first { $0.provider.id == "codex" })
        let detail = store.customizeDetail(for: "codex")
        XCTAssertNotNil(detail, "disabled provider still has a detail to render dimmed")
        XCTAssertEqual(detail?.metrics.map(\.id), store.orderedSupportedMetrics(for: "codex").map(\.id))
    }

    func testCustomizeDetailSplitsAcrossDivider() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DetailSplit"),
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            defaultExpandedMetricIDs: ["claude.weekly"]
        )
        let detail = store.customizeDetail(for: "claude")
        XCTAssertEqual(detail?.expandedMetrics.map(\.id), ["claude.weekly"])
        XCTAssertEqual(detail?.alwaysShownMetrics.map(\.id), ["claude.session", "claude.extra", "claude.today"])
    }

    func testCustomizeDetailIsNilForUnknownProvider() {
        let store = makeStore("DetailUnknown")
        XCTAssertNil(store.customizeDetail(for: "nope"))
    }

    func testMetricCountMatchesRegistryDescriptors() {
        let store = makeStore("MetricCount")
        for id in MockData.providers.map(\.id) {
            XCTAssertEqual(store.metricCount(for: id), MockData.descriptors(for: id).count)
        }
        XCTAssertEqual(store.metricCount(for: "missing"), 0)
    }

    func testCustomizeProviderIDClearsWhenLeavingCustomize() {
        let store = makeStore("RouteClears")
        store.screen = .customize
        store.customizeProviderID = "claude"
        XCTAssertEqual(store.customizeProviderID, "claude")

        store.screen = .dashboard
        XCTAssertNil(store.customizeProviderID, "leaving Customize resets the L2 selection back to the list")

        // Settings 직접 이동 시에도 L2 선택 해제
        store.screen = .customize
        store.customizeProviderID = "codex"
        store.screen = .settings
        XCTAssertNil(store.customizeProviderID)
    }

    // MARK: - Share confirmation

    /// auto-clear task 취소로 popover 재오픈 시 stale confirmation 재등장 방지
    func testClearShareConfirmationHidesPillAndCancelsTimer() {
        let store = makeStore("ShareConfirmationClear")
        XCTAssertFalse(store.shareConfirmation)

        store.presentShareConfirmation()
        XCTAssertTrue(store.shareConfirmation, "present sets the confirmation the pill reads")

        store.clearShareConfirmation()
        XCTAssertFalse(store.shareConfirmation, "clear hides the pill immediately")
    }

    /// dashboard·Customize drag와 동일한 divider-reorder 경로로 metric 이동
    private func moveMetric(_ descriptorID: String, expanded: Bool, in store: LayoutStore) -> Bool {
        guard store.expandedMetricIDs.contains(descriptorID) != expanded,
              let providerID = descriptorID.split(separator: ".", maxSplits: 1).first.map(String.init)
        else { return false }
        let dividerID = "\(providerID)::test-expanded-divider"
        let current = store.metricOrderWithDivider(for: providerID, dividerID: dividerID)
        guard let reordered = LayoutStore.reordered(current, dragged: descriptorID, target: dividerID) else {
            return false
        }
        return store.applyMetricDividerOrder(
            reordered,
            dragged: descriptorID,
            dividerID: dividerID,
            in: providerID
        )
    }

    private func makeStore(_ name: String) -> LayoutStore {
        LayoutStore(registry: .mock, defaults: makeDefaults(name), storageKey: "layout")
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.LayoutStore.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}
