import XCTest

@testable import NanoTeams

/// The "Parallel Roles" setting through the full recipe: default, persistence, the
/// fail-open read, and the reset that has to remove the stored key AND put the live value
/// back (removing only the key leaves the old value in memory until relaunch, which reads
/// as "reset did nothing").
@MainActor
final class RoleConcurrencySettingTests: XCTestCase {

    private var storage: RoleConcurrencyInMemoryStorage!
    private var config: StoreConfiguration!

    override func setUp() async throws {
        try await super.setUp()
        storage = RoleConcurrencyInMemoryStorage()
        config = StoreConfiguration(storage: storage)
    }

    override func tearDown() async throws {
        config = nil
        storage = nil
        try await super.tearDown()
    }

    // MARK: - The value

    /// `nil` and not a sentinel number. The point of enforcement must not do arithmetic on a
    /// figure nobody can defend — and nothing in either provider reports how many requests it
    /// will serve at once, so there is no honest number to put here.
    func testProviderLimited_imposesNoCap() {
        XCTAssertNil(RoleConcurrencyMode.providerLimited.maxConcurrentRoles)
    }

    func testSingle_capsAtOne() {
        XCTAssertEqual(RoleConcurrencyMode.single.maxConcurrentRoles, 1)
    }

    func testEveryMode_hasADisplayNameAndAnExplanation() {
        for mode in RoleConcurrencyMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode) has no display name")
            XCTAssertFalse(mode.explanation.isEmpty, "\(mode) has no explanation")
            XCTAssertNotEqual(mode.displayName, mode.rawValue,
                              "\(mode) is showing its rawValue, not a written label")
        }
    }

    // MARK: - Defaults

    /// The default is exactly today's behaviour, so the setting adds a choice without moving
    /// anyone's runs — and no existing test has to change.
    func testDefault_isProviderLimited() {
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.roleConcurrencyMode))
        XCTAssertEqual(config.roleConcurrencyMode, .providerLimited)
        XCTAssertNil(config.roleConcurrencyMode.maxConcurrentRoles)
    }

    // MARK: - Persistence

    func testPersists() {
        config.roleConcurrencyMode = .single
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.roleConcurrencyMode) as? String, "single")
        XCTAssertEqual(StoreConfiguration(storage: storage).roleConcurrencyMode, .single)
    }

    /// Fails OPEN. A value this build cannot parse (a downgrade, a hand-edited plist) must
    /// not silently serialize every run to one role at a time.
    func testUnknownRawValue_fallsBackToProviderLimited() {
        storage.set("as-many-as-possible-please", forKey: UserDefaultsKeys.roleConcurrencyMode)
        XCTAssertEqual(StoreConfiguration(storage: storage).roleConcurrencyMode, .providerLimited)
    }

    func testNonStringStoredValue_fallsBackToProviderLimited() {
        storage.set(3, forKey: UserDefaultsKeys.roleConcurrencyMode)
        XCTAssertEqual(StoreConfiguration(storage: storage).roleConcurrencyMode, .providerLimited)
    }

    // MARK: - Reset

    func testResetToDefaults_removesTheKeyAndRestoresTheValue() {
        config.roleConcurrencyMode = .single
        config.resetToDefaults()

        XCTAssertEqual(config.roleConcurrencyMode, .providerLimited)
        XCTAssertEqual(
            storage.object(forKey: UserDefaultsKeys.roleConcurrencyMode) as? String,
            "providerLimited",
            "the reseed writes the default back through `didSet`")
    }

    // MARK: - Key convention

    func testKey_followsTheVersionedNamingConvention() {
        XCTAssertEqual(
            UserDefaultsKeys.roleConcurrencyMode, "NanoTeams.llm.roleConcurrencyMode.v1")
    }
}

/// File-private double, matching every other `Services/Store` suite.
private final class RoleConcurrencyInMemoryStorage: ConfigurationStorage {
    private var store: [String: Any] = [:]

    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
