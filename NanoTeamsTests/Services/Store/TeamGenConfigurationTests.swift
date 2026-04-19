import XCTest

@testable import NanoTeams

@MainActor
final class TeamGenConfigurationTests: XCTestCase {

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

    // MARK: - Defaults

    func testDefaults_allNilOrEmpty() {
        XCTAssertNil(config.teamGenLLMOverride)
        XCTAssertEqual(config.teamGenSystemPrompt, "")
        XCTAssertNil(config.teamGenSystemPromptOrNil)
        XCTAssertNil(config.teamGenForcedSupervisorMode)
        XCTAssertNil(config.teamGenForcedAcceptanceMode)
    }

    // MARK: - LLM Override round-trip

    func testLLMOverride_setAndLoad() {
        let override = LLMOverride(
            baseURLString: "http://127.0.0.1:9999",
            modelName: "qwen2.5-coder-32b",
            maxTokens: 16_384,
            temperature: 0.3
        )
        config.teamGenLLMOverride = override

        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.teamGenLLMOverride))

        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.teamGenLLMOverride, override)
    }

    func testLLMOverride_emptyOverride_removesKey() {
        config.teamGenLLMOverride = LLMOverride(modelName: "x")
        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.teamGenLLMOverride))

        // Setting to an empty override should delete the stored key.
        config.teamGenLLMOverride = LLMOverride()
        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.teamGenLLMOverride))

        let fresh = StoreConfiguration(storage: storage)
        XCTAssertNil(fresh.teamGenLLMOverride)
    }

    func testLLMOverride_setToNil_removesKey() {
        config.teamGenLLMOverride = LLMOverride(modelName: "x")
        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.teamGenLLMOverride))

        config.teamGenLLMOverride = nil
        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.teamGenLLMOverride))
    }

    // MARK: - System Prompt round-trip

    func testSystemPrompt_setAndLoad() {
        config.teamGenSystemPrompt = "CUSTOM"
        XCTAssertEqual(storage.string(forKey: UserDefaultsKeys.teamGenSystemPrompt), "CUSTOM")

        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.teamGenSystemPrompt, "CUSTOM")
    }

    func testSystemPromptOrNil_emptyNormalizesToNil() {
        config.teamGenSystemPrompt = ""
        XCTAssertNil(config.teamGenSystemPromptOrNil)

        config.teamGenSystemPrompt = "   \n   \t"
        XCTAssertNil(config.teamGenSystemPromptOrNil, "Whitespace-only should be treated as empty")

        config.teamGenSystemPrompt = "hi"
        XCTAssertEqual(config.teamGenSystemPromptOrNil, "hi")
    }

    // MARK: - Forced Mode round-trips

    func testForcedSupervisorMode_setAndLoad() {
        config.teamGenForcedSupervisorMode = .autonomous
        XCTAssertEqual(
            storage.string(forKey: UserDefaultsKeys.teamGenForcedSupervisorMode),
            SupervisorMode.autonomous.rawValue
        )

        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.teamGenForcedSupervisorMode, .autonomous)
    }

    func testForcedSupervisorMode_setToNil_removesKey() {
        config.teamGenForcedSupervisorMode = .manual
        XCTAssertNotNil(storage.string(forKey: UserDefaultsKeys.teamGenForcedSupervisorMode))

        config.teamGenForcedSupervisorMode = nil
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.teamGenForcedSupervisorMode))
    }

    func testForcedAcceptanceMode_setAndLoad() {
        config.teamGenForcedAcceptanceMode = .afterEachArtifact
        XCTAssertEqual(
            storage.string(forKey: UserDefaultsKeys.teamGenForcedAcceptanceMode),
            AcceptanceMode.afterEachArtifact.rawValue
        )

        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.teamGenForcedAcceptanceMode, .afterEachArtifact)
    }

    func testForcedAcceptanceMode_setToNil_removesKey() {
        config.teamGenForcedAcceptanceMode = .finalOnly
        XCTAssertNotNil(storage.string(forKey: UserDefaultsKeys.teamGenForcedAcceptanceMode))

        config.teamGenForcedAcceptanceMode = nil
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.teamGenForcedAcceptanceMode))
    }

    // MARK: - Reset

    func testResetToDefaults_clearsAllTeamGenKeys() {
        config.teamGenLLMOverride = LLMOverride(modelName: "x")
        config.teamGenSystemPrompt = "CUSTOM"
        config.teamGenForcedSupervisorMode = .autonomous
        config.teamGenForcedAcceptanceMode = .finalOnly

        config.resetToDefaults()

        XCTAssertNil(config.teamGenLLMOverride)
        XCTAssertEqual(config.teamGenSystemPrompt, "")
        XCTAssertNil(config.teamGenForcedSupervisorMode)
        XCTAssertNil(config.teamGenForcedAcceptanceMode)

        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.teamGenLLMOverride))
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.teamGenSystemPrompt))
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.teamGenForcedSupervisorMode))
        XCTAssertNil(storage.object(forKey: UserDefaultsKeys.teamGenForcedAcceptanceMode))
    }
}

// Mirror of the helper used in `LLMRequestTimeoutTests.swift`. Swift's `private`
// keyword is file-scoped, so we duplicate the ~10-line class instead of sharing.
private final class InMemoryStorage: ConfigurationStorage {
    private var store: [String: Any] = [:]

    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
