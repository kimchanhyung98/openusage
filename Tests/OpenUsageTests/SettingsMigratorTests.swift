import XCTest
@testable import OpenUsage

final class SettingsMigratorTests: XCTestCase {
    // MARK: - Fresh vs. legacy vs. existing

    func testFreshInstallStampsCurrentAndRunsNothing() {
        let (defaults, domain) = makeDefaults("Fresh")
        defer { defaults.removePersistentDomain(forName: domain) }

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )

        XCTAssertEqual(result, 3)
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 3)
        XCTAssertNil(ranVersions(defaults), "a fresh install must not run historical migrations")
    }

    func testLegacyInstallMigratesFromZeroAndKeepsSettings() {
        let (defaults, domain) = makeDefaults("Legacy")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("custom", forKey: "openusage.layout.v1")  // 기존 설정 존재, schema version 없음

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )

        XCTAssertEqual(result, 3)
        XCTAssertEqual(ranVersions(defaults), [1, 2, 3])
        XCTAssertEqual(defaults.string(forKey: "openusage.layout.v1"), "custom", "existing settings preserved")
    }

    // MARK: - Cascading

    func testCascadeRunsAllIntermediateStepsInOrder() {
        let (defaults, domain) = makeDefaults("Cascade")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(7, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain,
            current: 13, migrations: recording(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13)
        )

        XCTAssertEqual(result, 13)
        XCTAssertEqual(ranVersions(defaults), [8, 9, 10, 11, 12, 13], "only steps above the stored version, in order")
    }

    func testStepsApplyInAscendingOrderRegardlessOfDeclaration() {
        let (defaults, domain) = makeDefaults("Order")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0, forKey: SettingsMigrator.schemaVersionKey)

        SettingsMigrator.migrate(
            defaults: defaults, domainName: domain,
            current: 3, migrations: [recordingStep(3), recordingStep(1), recordingStep(2)]
        )

        XCTAssertEqual(ranVersions(defaults), [1, 2, 3])
    }

    func testSameVersionIsNoOp() {
        let (defaults, domain) = makeDefaults("Same")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(3, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )

        XCTAssertEqual(result, 3)
        XCTAssertNil(ranVersions(defaults))
    }

    func testDowngradeLeavesVersionUntouched() {
        let (defaults, domain) = makeDefaults("Downgrade")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(5, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )

        XCTAssertEqual(result, 5)
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 5)
        XCTAssertNil(ranVersions(defaults))
    }

    func testReachesCurrentEvenWhenTopVersionsHaveNoStep() {
        let (defaults, domain) = makeDefaults("Gap")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 5, migrations: recording(1, 2)
        )

        XCTAssertEqual(result, 5)
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 5)
        XCTAssertEqual(ranVersions(defaults), [1, 2])
    }

    // MARK: - Resilience

    func testFailureStopsCascadeAndResumesNextLaunch() {
        let (defaults, domain) = makeDefaults("Failure")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain,
            current: 3, migrations: [recordingStep(1), failingStep(2), recordingStep(3)]
        )

        XCTAssertEqual(result, 1, "stops at the last successful step")
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 1)
        XCTAssertEqual(ranVersions(defaults), [1], "the step after the failure does not run")

        // 다음 launch: v1 replay 없이 v2부터 재개
        let resumed = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )
        XCTAssertEqual(resumed, 3)
        XCTAssertEqual(ranVersions(defaults), [1, 2, 3], "resumes at v2; v1 not replayed")
    }

    // MARK: - Regression (the beta-update bug)

    func testMigrateNeverWipesExistingSettings() {
        let (defaults, domain) = makeDefaults("NoWipe")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "betaUpdatesEnabled")
        defaults.set("custom", forKey: "openusage.layout.v1")
        defaults.set(720.0, forKey: "openusage.panelHeight")
        defaults.set(SettingsSchema.current, forKey: SettingsMigrator.schemaVersionKey)

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)  // 실제 shipped schema

        XCTAssertTrue(defaults.bool(forKey: "betaUpdatesEnabled"), "Early Access opt-in must survive updates")
        XCTAssertEqual(defaults.string(forKey: "openusage.layout.v1"), "custom")
        XCTAssertEqual(defaults.double(forKey: "openusage.panelHeight"), 720.0)
    }

    func testLegacyInstallKeepsSettingsUnderShippedSchema() {
        let (defaults, domain) = makeDefaults("LegacyReal")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "betaUpdatesEnabled")

        let result = SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(result, SettingsSchema.current)
        XCTAssertTrue(defaults.bool(forKey: "betaUpdatesEnabled"))
    }

    // MARK: - v2: enabled-list unification + known-provider set

    @MainActor  // 검증용 ProviderEnablementStore가 main-actor
    func testV2ConvertsLegacyDisabledListToEnabledList() {
        let (defaults, domain) = makeDefaults("V2Legacy")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["devin", "grok"], forKey: "openusage.disabledProviders.v1")

        let result = SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(result, SettingsSchema.current)
        let enabled = Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? [])
        XCTAssertEqual(enabled, Set(SettingsSchema.v2ProviderIDs).subtracting(["devin", "grok"]))
        XCTAssertNil(defaults.stringArray(forKey: "openusage.disabledProviders.v1"), "legacy key removed")
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.knownProviders.v1") ?? []),
            Set(SettingsSchema.v2ProviderIDs)
        )

        let store = ProviderEnablementStore(defaults: defaults)
        XCTAssertNotNil(store.enabledIDs)
        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertFalse(store.isEnabled("devin"))
        XCTAssertFalse(store.isEnabled("grok"))
    }

    func testV2ConvertsAllOnLegacyInstall() {
        let (defaults, domain) = makeDefaults("V2AllOn")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set("custom", forKey: "openusage.layout.v1")  // 설정 존재 → fresh install 아님

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []),
            Set(SettingsSchema.v2ProviderIDs)
        )
    }

    func testV2LeavesExistingEnabledListAloneAndSeedsKnownSet() {
        let (defaults, domain) = makeDefaults("V2EnabledList")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["claude", "cursor"], forKey: "openusage.enabledProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []),
            ["claude", "cursor"]
        )
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.knownProviders.v1") ?? []),
            Set(SettingsSchema.v2ProviderIDs)
        )
    }

    func testV2IsIdempotent() {
        let (defaults, domain) = makeDefaults("V2Idempotent")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["codex"], forKey: "openusage.disabledProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)
        let enabledAfterFirst = defaults.stringArray(forKey: "openusage.enabledProviders.v1")
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)  // 중단된 upgrade 재현
        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(defaults.stringArray(forKey: "openusage.enabledProviders.v1"), enabledAfterFirst)
    }

    // MARK: - Schema integrity

    func testShippedSchemaIsConsistent() {
        let versions = SettingsSchema.migrations.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count, "migration versions must be unique")
        XCTAssertGreaterThanOrEqual(
            SettingsSchema.current, versions.max() ?? SettingsSchema.current,
            "bump SettingsSchema.current when you add a migration"
        )
        for version in versions {
            XCTAssertGreaterThanOrEqual(version, 1, "schema versions start at 1")
            XCTAssertLessThanOrEqual(version, SettingsSchema.current)
        }
    }

    // MARK: - Helpers

    private static let ranKey = "test.ran"

    private func makeDefaults(_ name: String) -> (UserDefaults, String) {
        let suite = "OpenUsageTests.SettingsMigrator.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func recordingStep(_ version: Int) -> SettingsMigration {
        SettingsMigration(version: version) { defaults in
            var ran = defaults.array(forKey: Self.ranKey) as? [Int] ?? []
            ran.append(version)
            defaults.set(ran, forKey: Self.ranKey)
        }
    }

    private func recording(_ versions: Int...) -> [SettingsMigration] {
        versions.map(recordingStep)
    }

    private func failingStep(_ version: Int) -> SettingsMigration {
        SettingsMigration(version: version) { _ in throw MigrationTestError.boom }
    }

    private func ranVersions(_ defaults: UserDefaults) -> [Int]? {
        defaults.array(forKey: Self.ranKey) as? [Int]
    }

    private enum MigrationTestError: Error { case boom }
}
