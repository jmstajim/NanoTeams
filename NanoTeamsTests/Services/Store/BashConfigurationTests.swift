import XCTest

@testable import NanoTeams

/// Persistence + migration for the bash sandbox permissions and the judge LLM
/// override. The migration must be write-through (drop the legacy key) so it
/// can't resurrect a later-cleared override on the next launch.
@MainActor
final class BashConfigurationTests: XCTestCase {

    private var storage: InMemoryStorage!
    private var config: StoreConfiguration!

    override func setUp() {
        super.setUp()
        storage = InMemoryStorage()
        config = StoreConfiguration(storage: storage)
    }

    override func tearDown() {
        config = nil
        storage = nil
        super.tearDown()
    }

    // MARK: - Sandbox permissions

    func testSandboxPermissions_defaultMatchesPriorProfile() {
        XCTAssertEqual(config.bashSandboxPermissions, BashSandboxPermissions())
    }

    func testSandboxPermissions_roundTrip() {
        config.bashSandboxPermissions = BashSandboxPermissions(
            workFolderWrite: false, tempWrite: true, credentialRead: true, everythingElseWrite: true)
        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.bashSandboxPermissions))

        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.bashSandboxPermissions, config.bashSandboxPermissions)
    }

    // MARK: - Judge override

    func testJudgeOverride_roundTrip() {
        let override = LLMOverride(baseURLString: "http://127.0.0.1:9999", modelName: "judge")
        config.bashJudgeLLMOverride = override
        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.bashJudgeLLMOverride))

        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.bashJudgeLLMOverride, override)
    }

    func testJudgeOverride_setToNil_removesKey() {
        config.bashJudgeLLMOverride = LLMOverride(modelName: "x")
        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.bashJudgeLLMOverride))

        config.bashJudgeLLMOverride = nil
        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.bashJudgeLLMOverride))
    }

    // MARK: - Legacy bashJudgeModel migration

    func testLegacyJudgeModel_migratesIntoOverrideAndDropsLegacyKey() {
        let pre = InMemoryStorage()
        pre.set("qwen-judge", forKey: UserDefaultsKeys.bashJudgeModel)

        let migrated = StoreConfiguration(storage: pre)
        XCTAssertEqual(migrated.bashJudgeLLMOverride?.modelName, "qwen-judge")
        // Write-through: the new key is persisted and the legacy key is gone.
        XCTAssertNotNil(pre.data(forKey: UserDefaultsKeys.bashJudgeLLMOverride))
        XCTAssertNil(
            pre.string(forKey: UserDefaultsKeys.bashJudgeModel),
            "the legacy key must be dropped after migration")
    }

    /// The resurrection guard: after migrating then CLEARING the override, a fresh
    /// launch must NOT bring the old model back.
    func testLegacyJudgeModel_clearedOverride_doesNotResurrectOnReload() {
        let shared = InMemoryStorage()
        shared.set("qwen-judge", forKey: UserDefaultsKeys.bashJudgeModel)

        // First launch migrates (and drops the legacy key).
        let first = StoreConfiguration(storage: shared)
        XCTAssertEqual(first.bashJudgeLLMOverride?.modelName, "qwen-judge")

        // User clears the override.
        first.bashJudgeLLMOverride = nil
        XCTAssertNil(shared.data(forKey: UserDefaultsKeys.bashJudgeLLMOverride))

        // Next launch: the cleared state must stick.
        let second = StoreConfiguration(storage: shared)
        XCTAssertNil(second.bashJudgeLLMOverride, "a cleared judge override must not resurrect from the legacy key")
    }

    func testLegacyJudgeModel_whitespaceOnly_isIgnored() {
        let pre = InMemoryStorage()
        pre.set("   ", forKey: UserDefaultsKeys.bashJudgeModel)
        let c = StoreConfiguration(storage: pre)
        XCTAssertNil(c.bashJudgeLLMOverride)
    }

    // MARK: - Reset

    func testResetToDefaults_clearsBashOverrideAndPermissions() {
        config.bashSandboxPermissions = BashSandboxPermissions(everythingElseWrite: true)
        config.bashJudgeLLMOverride = LLMOverride(modelName: "x")

        config.resetToDefaults()

        XCTAssertEqual(config.bashSandboxPermissions, BashSandboxPermissions())
        XCTAssertNil(config.bashJudgeLLMOverride)
        // The judge override (optional) is removed; the non-optional permissions
        // value re-persists its default via didSet. Either way a reload is default.
        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.bashJudgeLLMOverride))
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.bashSandboxPermissions, BashSandboxPermissions())
        XCTAssertNil(fresh.bashJudgeLLMOverride)
    }

    // MARK: - sandboxEnabled / fallback round-trip

    func testBashSandboxEnabled_falsePersists_notRevertedToDefault() {
        // The init default is `true`; a stored `false` must survive a reload — reading
        // must distinguish "user turned it off" from "never set" (absent-vs-false).
        config.bashSandboxEnabled = false
        XCTAssertFalse(StoreConfiguration(storage: storage).bashSandboxEnabled)
    }

    func testBashAllowUnsandboxedFallback_roundTrip() {
        config.bashAllowUnsandboxedFallback = true
        XCTAssertTrue(StoreConfiguration(storage: storage).bashAllowUnsandboxedFallback)
        config.bashAllowUnsandboxedFallback = false
        XCTAssertFalse(StoreConfiguration(storage: storage).bashAllowUnsandboxedFallback)
    }

    // MARK: - mode / restriction / rules round-trip

    func testBashModeAndRestrictionLevel_roundTrip() {
        config.bashMode = .auto
        config.bashRestrictionLevel = .permissive
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.bashMode, .auto)
        XCTAssertEqual(fresh.bashRestrictionLevel, .permissive)
    }

    func testBashMode_defaultIsManual() {
        // A fresh config (nothing stored) defaults to the always-confirm `.manual`
        // mode — the safest interactive posture (every command pauses for approval).
        XCTAssertEqual(StoreConfiguration(storage: InMemoryStorage()).bashMode, .manual)
        XCTAssertEqual(BashConstants.defaultMode, .manual)
    }

    func testBashMode_storedValue_survivesNewDefault() {
        // A work folder that already stored a mode keeps it — the `.manual` default
        // never overrides a persisted choice (e.g. a user who explicitly set `.off`).
        let pre = InMemoryStorage()
        pre.set(BashExecutionMode.off.rawValue, forKey: UserDefaultsKeys.bashMode)
        XCTAssertEqual(StoreConfiguration(storage: pre).bashMode, .off)
    }

    func testBashMode_legacyStoredManual_loadsAsSemiAutomatic() {
        // An existing config persisted before the rename stored the raw value
        // "manual"; it must load as `.semiAutomatic` (zero behavior change), NOT the
        // always-confirm `.manual` that is now the fresh-config default.
        let pre = InMemoryStorage()
        pre.set("manual", forKey: UserDefaultsKeys.bashMode)
        XCTAssertEqual(StoreConfiguration(storage: pre).bashMode, .semiAutomatic)
    }

    func testBashMode_alwaysConfirmManual_roundTrips() {
        config.bashMode = .manual
        XCTAssertEqual(storage.string(forKey: UserDefaultsKeys.bashMode), "alwaysConfirm")
        XCTAssertEqual(StoreConfiguration(storage: storage).bashMode, .manual)
    }

    func testBashRules_roundTrip() {
        config.bashAllowRules = ["git status"]
        config.bashAskRules = ["npm"]
        config.bashDenyRules = ["rm -rf *"]
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.bashAllowRules, ["git status"])
        XCTAssertEqual(fresh.bashAskRules, ["npm"])
        XCTAssertEqual(fresh.bashDenyRules, ["rm -rf *"])
    }

    // MARK: - Policy assembly

    func testBashPolicy_assemblesAllComponents() {
        config.bashMode = .auto
        config.bashRestrictionLevel = .strict
        config.bashAllowRules = ["a"]
        config.bashAskRules = ["b"]
        config.bashDenyRules = ["c"]
        config.bashSandboxEnabled = false
        config.bashSandboxPermissions = BashSandboxPermissions(everythingElseWrite: true)
        config.bashAllowUnsandboxedFallback = true
        config.bashJudgeLLMOverride = LLMOverride(modelName: "j")

        let p = config.bashPolicy
        XCTAssertEqual(p.mode, .auto)
        XCTAssertEqual(p.restrictionLevel, .strict)
        XCTAssertEqual(p.allowRules, ["a"])
        XCTAssertEqual(p.askRules, ["b"])
        XCTAssertEqual(p.denyRules, ["c"])
        XCTAssertFalse(p.sandboxEnabled)
        XCTAssertEqual(p.sandboxPermissions, BashSandboxPermissions(everythingElseWrite: true))
        XCTAssertTrue(p.allowUnsandboxedFallback)
        XCTAssertEqual(p.judgeOverride?.modelName, "j")
    }

    // MARK: - Reset (runtime settings)

    func testResetToDefaults_clearsAllBashRuntimeSettings() {
        config.bashMode = .auto
        config.bashRestrictionLevel = .permissive
        config.bashAllowRules = ["x"]
        config.bashAskRules = ["y"]
        config.bashDenyRules = ["z"]
        config.bashSandboxEnabled = false
        config.bashAllowUnsandboxedFallback = true

        config.resetToDefaults()

        XCTAssertEqual(config.bashMode, BashConstants.defaultMode)
        XCTAssertEqual(config.bashRestrictionLevel, BashConstants.defaultRestrictionLevel)
        XCTAssertTrue(config.bashAllowRules.isEmpty)
        XCTAssertTrue(config.bashAskRules.isEmpty)
        XCTAssertTrue(config.bashDenyRules.isEmpty)
        XCTAssertEqual(config.bashSandboxEnabled, BashConstants.defaultSandboxEnabled)
        XCTAssertFalse(config.bashAllowUnsandboxedFallback)

        // A fresh load gets defaults too.
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.bashMode, BashConstants.defaultMode)
        XCTAssertTrue(fresh.bashDenyRules.isEmpty)
        XCTAssertEqual(fresh.bashSandboxEnabled, BashConstants.defaultSandboxEnabled)
        XCTAssertFalse(fresh.bashAllowUnsandboxedFallback)
    }
}

// File-scoped mirror of the helper used elsewhere (Swift `private` is file-scoped).
private final class InMemoryStorage: ConfigurationStorage {
    private var store: [String: Any] = [:]

    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
