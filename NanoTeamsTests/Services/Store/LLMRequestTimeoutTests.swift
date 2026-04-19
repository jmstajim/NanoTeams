import XCTest

@testable import NanoTeams

@MainActor
final class LLMRequestTimeoutTests: XCTestCase {

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

    // MARK: - Default

    func testDefault_matchesConstant() {
        XCTAssertEqual(config.llmRequestTimeoutSeconds, LLMConstants.defaultLLMRequestTimeoutSeconds)
    }

    func testDefault_whenKeyNotStored_usesConstant() {
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.llmRequestTimeoutSeconds))
        XCTAssertEqual(config.llmRequestTimeoutSeconds, LLMConstants.defaultLLMRequestTimeoutSeconds)
    }

    // MARK: - Persistence

    func testSet_persistsToStorage() {
        config.llmRequestTimeoutSeconds = 600
        XCTAssertEqual(storage.object(forKey: UserDefaultsKeys.llmRequestTimeoutSeconds) as? Int, 600)
    }

    func testSet_zero_persistsAsZeroMeaningInfinite() {
        config.llmRequestTimeoutSeconds = 0
        XCTAssertEqual(storage.object(forKey: UserDefaultsKeys.llmRequestTimeoutSeconds) as? Int, 0)
        XCTAssertEqual(config.llmRequestTimeoutSeconds, 0)
    }

    func testLoad_fromStorage() {
        storage.set(120, forKey: UserDefaultsKeys.llmRequestTimeoutSeconds)
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.llmRequestTimeoutSeconds, 120)
    }

    // MARK: - Clamping

    func testSet_negative_clampsToZero() {
        config.llmRequestTimeoutSeconds = -5
        XCTAssertEqual(config.llmRequestTimeoutSeconds, 0)
    }

    // MARK: - Reset

    func testResetToDefaults_restoresDefaultAndClearsStorage() {
        config.llmRequestTimeoutSeconds = 999
        config.resetToDefaults()
        XCTAssertEqual(config.llmRequestTimeoutSeconds, LLMConstants.defaultLLMRequestTimeoutSeconds)
    }

    // MARK: - LLMConfig integration

    func testGlobalLLMConfig_carriesCurrentTimeout() {
        config.llmRequestTimeoutSeconds = 450
        XCTAssertEqual(config.globalLLMConfig.requestTimeoutSeconds, 450)
    }

    func testGlobalLLMConfig_afterReset_carriesDefault() {
        config.llmRequestTimeoutSeconds = 123
        config.resetToDefaults()
        XCTAssertEqual(config.globalLLMConfig.requestTimeoutSeconds, LLMConstants.defaultLLMRequestTimeoutSeconds)
    }

    // MARK: - LLMConfig direct init

    func testLLMConfig_defaultInit_usesDefaultConstant() {
        let cfg = LLMConfig()
        XCTAssertEqual(cfg.requestTimeoutSeconds, LLMConstants.defaultLLMRequestTimeoutSeconds)
    }

    func testLLMConfig_explicitZero_preservesZero() {
        let cfg = LLMConfig(requestTimeoutSeconds: 0)
        XCTAssertEqual(cfg.requestTimeoutSeconds, 0)
    }

    func testLLMConfig_explicitValue_preservesValue() {
        let cfg = LLMConfig(requestTimeoutSeconds: 900)
        XCTAssertEqual(cfg.requestTimeoutSeconds, 900)
    }
}

// MARK: - Test Helpers

private final class InMemoryStorage: ConfigurationStorage {
    private var store: [String: Any] = [:]

    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
