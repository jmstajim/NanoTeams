import XCTest

@testable import NanoTeams

/// Persistence corners for the computer-use settings in `StoreConfiguration`:
/// the Manual default (key absent), stored-value honoring (an explicit Off must
/// survive relaunch), unknown raw-value fallbacks (hand-edited defaults / a
/// downgrade from a build with more enum cases), and reset semantics.
@MainActor
final class ComputerUseConfigurationTests: XCTestCase {

    // File-private duplicate by house rule (`private` is file-scoped; every
    // Store suite carries its own copy).
    private final class InMemoryStorage: ConfigurationStorage, @unchecked Sendable {
        var store: [String: Any] = [:]
        func string(forKey key: String) -> String? { store[key] as? String }
        func bool(forKey key: String) -> Bool { (store[key] as? Bool) ?? false }
        func data(forKey key: String) -> Data? { store[key] as? Data }
        func object(forKey key: String) -> Any? { store[key] }
        func set(_ value: Any?, forKey key: String) {
            if let value { store[key] = value } else { store.removeValue(forKey: key) }
        }
        func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    }

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

    // MARK: - Approval mode

    func testMode_defaultsToManual_whenKeyAbsent() {
        XCTAssertEqual(config.computerUseMode, .manual)
        XCTAssertTrue(config.isComputerUseEnabled)
        XCTAssertEqual(config.computerUsePolicy.mode, .manual)
    }

    func testMode_storedOff_isHonoredAcrossRelaunch() {
        // The Manual default must never override a persisted explicit Off.
        config.computerUseMode = .off
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.computerUseMode, .off)
        XCTAssertFalse(fresh.isComputerUseEnabled)
    }

    func testMode_unknownRawValue_fallsBackToManual() {
        // Hand-edited defaults or a downgrade from a build that had more cases.
        storage.set("hyperdrive", forKey: UserDefaultsKeys.computerUseMode)
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.computerUseMode, .manual)
    }

    func testMode_resetToDefaults_returnsManual() {
        config.computerUseMode = .off
        config.resetToDefaults()
        XCTAssertEqual(config.computerUseMode, .manual)
        // And the reload path agrees (the didSet re-persisted the default).
        XCTAssertEqual(StoreConfiguration(storage: storage).computerUseMode, .manual)
    }

    // MARK: - Safety (restriction level)

    func testRestrictionLevel_storedOff_isHonoredAcrossRelaunch() {
        config.computerUseRestrictionLevel = .off
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.computerUseRestrictionLevel, .off)
        XCTAssertEqual(fresh.computerUsePolicy.restrictionLevel, .off)
    }

    func testRestrictionLevel_unknownRawValue_fallsBackToStandard() {
        storage.set("bananas", forKey: UserDefaultsKeys.computerUseRestrictionLevel)
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.computerUseRestrictionLevel, .standard)
    }

    func testRestrictionLevel_resetToDefaults_returnsStandard() {
        config.computerUseRestrictionLevel = .off
        config.resetToDefaults()
        XCTAssertEqual(config.computerUseRestrictionLevel, .standard)
    }
}
