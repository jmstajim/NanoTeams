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
            modelName: "qwen2.5-coder-32b"
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

    // MARK: - Chat-model ledger isolation

    // Regression: 86b389a left a stray `removeObject(forKey: Keys.chatModelLedger)`
    // inside teamGenLLMOverride's didSet else-branch, so clearing the team-gen
    // override wiped the persisted chat-model ledger — after a relaunch every
    // orphaned model became permanently unreclaimable again.
    func testClearingLLMOverride_doesNotWipeTheChatModelLedger() {
        let entry = OwnedChatModel(
            modelName: "qwen3-8b",
            baseURLString: "http://127.0.0.1:1234",
            instanceID: "qwen3-8b"
        )
        config.chatModelLedger = [entry]
        config.teamGenLLMOverride = LLMOverride(modelName: "x")

        config.teamGenLLMOverride = nil

        XCTAssertNotNil(
            storage.data(forKey: UserDefaultsKeys.chatModelLedger),
            "Clearing the team-gen override must not touch the chat-model ledger key"
        )
        let fresh = StoreConfiguration(storage: storage)
        XCTAssertEqual(fresh.chatModelLedger, [entry])
    }

    func testSettingEmptyLLMOverride_doesNotWipeTheChatModelLedger() {
        let entry = OwnedChatModel(
            modelName: "qwen3-8b",
            baseURLString: "http://127.0.0.1:1234",
            instanceID: "qwen3-8b:2"
        )
        config.chatModelLedger = [entry]
        config.teamGenLLMOverride = LLMOverride(modelName: "x")

        // The other route into the same else-branch.
        config.teamGenLLMOverride = LLMOverride()

        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.chatModelLedger))
        XCTAssertEqual(StoreConfiguration(storage: storage).chatModelLedger, [entry])
    }

    // The ledger is operational bookkeeping (which LM Studio instances the app
    // owns), not a user preference — "Reset to Defaults" must not orphan
    // resident models by forgetting them.
    func testResetToDefaults_preservesTheChatModelLedger() {
        let entry = OwnedChatModel(
            modelName: "qwen3-8b",
            baseURLString: "http://127.0.0.1:1234",
            instanceID: "qwen3-8b"
        )
        config.chatModelLedger = [entry]

        config.resetToDefaults()

        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.chatModelLedger))
        XCTAssertEqual(config.chatModelLedger, [entry])
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
