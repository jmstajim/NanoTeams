import XCTest

@testable import NanoTeams

/// The two settings behind automatic context compaction, through the full recipe: default,
/// persistence, clamping, and the reset that has to remove the stored key AND put the live
/// value back (a `resetToDefaults` that only did the first leaves the old value in memory
/// until relaunch).
@MainActor
final class AutoCompactSettingTests: XCTestCase {

    private var storage: CompactionInMemoryStorage!
    private var config: StoreConfiguration!

    override func setUp() async throws {
        try await super.setUp()
        storage = CompactionInMemoryStorage()
        config = StoreConfiguration(storage: storage)
    }

    override func tearDown() async throws {
        config = nil
        storage = nil
        try await super.tearDown()
    }

    // MARK: - Defaults

    /// On by default. The alternative to compacting is not "a longer conversation" — it is a
    /// silently truncated head or a refused request, both of which arrive with the
    /// conversation already past saving.
    func testAutoCompact_isOnByDefault() {
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.autoCompactEnabled))
        XCTAssertTrue(config.autoCompactEnabled)
    }

    func testBudgetPercent_defaultsToTheConstant() {
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.autoCompactBudgetPercent))
        XCTAssertEqual(config.autoCompactBudgetPercent, AppDefaults.autoCompactBudgetPercent)
        XCTAssertEqual(
            AppDefaults.autoCompactBudgetPercent, 85,
            "the mechanical ceiling: the epoch's summary request carries the whole wire, so "
                + "budget + one iteration's append + the summary must still fit the window. "
                + "Deliberately ABOVE playbook R2.5.4's quarter, which answers the other "
                + "question — how long a wire the model still reasons well over")
    }

    // MARK: - Persistence

    func testAutoCompact_persists() {
        config.autoCompactEnabled = false
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.autoCompactEnabled) as? Bool, false)
        XCTAssertFalse(StoreConfiguration(storage: storage).autoCompactEnabled)
    }

    func testBudgetPercent_persists() {
        config.autoCompactBudgetPercent = 40
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.autoCompactBudgetPercent) as? Int, 40)
        XCTAssertEqual(StoreConfiguration(storage: storage).autoCompactBudgetPercent, 40)
    }

    // MARK: - Clamping

    /// Below the floor the pinned head alone exceeds the budget on any real model, so every
    /// epoch would latch as exhausted on its first measurement.
    func testBudgetPercent_clampsToTheRange() {
        config.autoCompactBudgetPercent = 1
        XCTAssertEqual(
            config.autoCompactBudgetPercent,
            AppDefaults.autoCompactBudgetPercentRange.lowerBound)

        config.autoCompactBudgetPercent = 500
        XCTAssertEqual(
            config.autoCompactBudgetPercent,
            AppDefaults.autoCompactBudgetPercentRange.upperBound)

        config.autoCompactBudgetPercent = -10
        XCTAssertEqual(
            config.autoCompactBudgetPercent,
            AppDefaults.autoCompactBudgetPercentRange.lowerBound)
    }

    /// The clamp must reach STORAGE too — a stored out-of-range value would be read back
    /// verbatim on the next launch and bypass the clamp entirely.
    func testClampedValue_isWhatGetsStored() {
        config.autoCompactBudgetPercent = 500
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.autoCompactBudgetPercent) as? Int,
            AppDefaults.autoCompactBudgetPercentRange.upperBound)
    }

    // MARK: - Reset

    /// Both halves: the key is removed AND the live value goes back to the default. Removing
    /// only the key leaves the changed value in memory until the app relaunches, which reads
    /// as "reset did nothing".
    func testResetToDefaults_removesTheKeysAndRestoresTheValues() {
        config.autoCompactEnabled = false
        config.autoCompactBudgetPercent = 60
        config.resetToDefaults()

        XCTAssertTrue(config.autoCompactEnabled)
        XCTAssertEqual(config.autoCompactBudgetPercent, AppDefaults.autoCompactBudgetPercent)
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.autoCompactEnabled) as? Bool, true,
            "the reseed writes the default back through `didSet`")
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.autoCompactBudgetPercent) as? Int,
            AppDefaults.autoCompactBudgetPercent)
    }

    // MARK: - Key convention

    func testKeys_followTheVersionedNamingConvention() {
        XCTAssertEqual(
            UserDefaultsKeys.autoCompactEnabled, "NanoTeams.llm.autoCompactEnabled.v1")
        XCTAssertEqual(
            UserDefaultsKeys.autoCompactBudgetPercent,
            "NanoTeams.llm.autoCompactBudgetPercent.v1")
    }
}

/// File-private double, matching every other `Services/Store` suite — `private` in Swift is
/// file-scoped, so each one carries its own rather than sharing a name across the target.
private final class CompactionInMemoryStorage: ConfigurationStorage {
    private var store: [String: Any] = [:]

    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
