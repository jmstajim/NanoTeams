import XCTest

@testable import NanoTeams

@MainActor
final class StoreConfigurationTests: XCTestCase {

    // MARK: - Test Subject

    var config: StoreConfiguration!

    // MARK: - Test Lifecycle

    private var originalLLMBaseURL: String?
    private var originalLLMModel: String?
    private var originalThinkingExpanded: Bool?
    private var originalToolCallsExpanded: Bool?
    private var originalArtifactsExpanded: Bool?
    private var originalDebugModeEnabled: Bool?
    private var originalEnterSendsMessage: Bool?
    private var originalSidebarTaskFilter: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Store original UserDefaults values to restore after tests
        originalLLMBaseURL = UserDefaults.standard.string(forKey: UserDefaultsKeys.llmBaseURL)
        originalLLMModel = UserDefaults.standard.string(forKey: UserDefaultsKeys.llmModel)
        originalThinkingExpanded = UserDefaults.standard.object(forKey: UserDefaultsKeys.thinkingExpandedByDefault) as? Bool
        originalToolCallsExpanded = UserDefaults.standard.object(forKey: UserDefaultsKeys.toolCallsExpandedByDefault) as? Bool
        originalArtifactsExpanded = UserDefaults.standard.object(forKey: UserDefaultsKeys.artifactsExpandedByDefault) as? Bool
        originalDebugModeEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.debugModeEnabled) as? Bool
        originalEnterSendsMessage = UserDefaults.standard.object(forKey: UserDefaultsKeys.enterSendsMessage) as? Bool
        originalSidebarTaskFilter = UserDefaults.standard.string(forKey: UserDefaultsKeys.sidebarTaskFilter)

        // Clear UserDefaults for clean test state
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.llmBaseURL)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.llmModel)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.thinkingExpandedByDefault)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.toolCallsExpandedByDefault)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.artifactsExpandedByDefault)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.debugModeEnabled)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.enterSendsMessage)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.sidebarTaskFilter)

        // Initialize test subject with clean state
        config = StoreConfiguration()
    }

    override func tearDownWithError() throws {
        // Clean up test subject
//        config = nil

        // Restore original UserDefaults values
        if let original = originalLLMBaseURL {
            UserDefaults.standard.set(original, forKey: UserDefaultsKeys.llmBaseURL)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.llmBaseURL)
        }

        if let original = originalLLMModel {
            UserDefaults.standard.set(original, forKey: UserDefaultsKeys.llmModel)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.llmModel)
        }

        if let original = originalThinkingExpanded {
            UserDefaults.standard.set(original, forKey: UserDefaultsKeys.thinkingExpandedByDefault)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.thinkingExpandedByDefault)
        }

        if let original = originalToolCallsExpanded {
            UserDefaults.standard.set(original, forKey: UserDefaultsKeys.toolCallsExpandedByDefault)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.toolCallsExpandedByDefault)
        }

        if let original = originalArtifactsExpanded {
            UserDefaults.standard.set(original, forKey: UserDefaultsKeys.artifactsExpandedByDefault)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.artifactsExpandedByDefault)
        }

        if let original = originalDebugModeEnabled {
            UserDefaults.standard.set(original, forKey: UserDefaultsKeys.debugModeEnabled)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.debugModeEnabled)
        }

        if let original = originalEnterSendsMessage {
            UserDefaults.standard.set(original, forKey: UserDefaultsKeys.enterSendsMessage)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.enterSendsMessage)
        }

        if let original = originalSidebarTaskFilter {
            UserDefaults.standard.set(original, forKey: UserDefaultsKeys.sidebarTaskFilter)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.sidebarTaskFilter)
        }

        try super.tearDownWithError()
    }

    // MARK: - Initialization Tests

    func testInit_withNoStoredValues_usesDefaults() {
        XCTAssertEqual(config.llmBaseURLString, AppDefaults.llmBaseURL)
        XCTAssertEqual(config.llmModelName, AppDefaults.llmModel)
    }

    var freshConfigWithStoredValues: StoreConfiguration!

    func testInit_withStoredValues_loadsFromUserDefaults() {
        // Set up stored values
        UserDefaults.standard.set("http://custom:8080", forKey: UserDefaultsKeys.llmBaseURL)
        UserDefaults.standard.set("custom-model", forKey: UserDefaultsKeys.llmModel)

        // Create fresh instance to test initialization with pre-populated UserDefaults
        freshConfigWithStoredValues = StoreConfiguration()

        XCTAssertEqual(freshConfigWithStoredValues.llmBaseURLString, "http://custom:8080")
        XCTAssertEqual(freshConfigWithStoredValues.llmModelName, "custom-model")
    }

    // MARK: - LLM Base URL Tests

    func testLLMBaseURLString_persistsToUserDefaults() {
        config.llmBaseURLString = "http://newhost:9999"

        let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.llmBaseURL)
        XCTAssertEqual(stored, "http://newhost:9999")
    }

    func testLLMBaseURL_aliasReadsFromLLMBaseURLString() {
        config.llmBaseURLString = "http://alias-test:1234"

        XCTAssertEqual(config.llmBaseURL, "http://alias-test:1234")
    }

    func testLLMBaseURL_aliasWritesToLLMBaseURLString() {
        config.llmBaseURL = "http://via-alias:5678"

        XCTAssertEqual(config.llmBaseURLString, "http://via-alias:5678")
        let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.llmBaseURL)
        XCTAssertEqual(stored, "http://via-alias:5678")
    }

    // MARK: - LLM Model Name Tests

    func testLLMModelName_persistsToUserDefaults() {
        config.llmModelName = "gpt-4-turbo"

        let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.llmModel)
        XCTAssertEqual(stored, "gpt-4-turbo")
    }

    func testLLMModelName_acceptsEmptyString() {
        config.llmModelName = ""

        XCTAssertEqual(config.llmModelName, "")
        let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.llmModel)
        XCTAssertEqual(stored, "")
    }

    // MARK: - Persistence Round-Trip Tests

    var freshConfigAllPropertiesPersistAndReload: StoreConfiguration!

    func testRoundTrip_allPropertiesPersistAndReload() {
        // Set values on shared config
        config.llmBaseURLString = "http://roundtrip:7777"
        config.llmModelName = "roundtrip-model"

        // Create fresh instance - should load from UserDefaults
        freshConfigAllPropertiesPersistAndReload = StoreConfiguration()

        XCTAssertEqual(freshConfigAllPropertiesPersistAndReload.llmBaseURLString, "http://roundtrip:7777")
        XCTAssertEqual(freshConfigAllPropertiesPersistAndReload.llmModelName, "roundtrip-model")
    }

    // MARK: - Observable Tests

    func testConfiguration_isObservable() {
        // Verify StoreConfiguration uses @Observable (properties are readable)
        XCTAssertNotNil(config.llmBaseURLString)
        XCTAssertNotNil(config.llmModelName)
        XCTAssertFalse(config.thinkingExpandedByDefault)
        XCTAssertFalse(config.toolCallsExpandedByDefault)
        XCTAssertFalse(config.artifactsExpandedByDefault)
        XCTAssertFalse(config.debugModeEnabled)
        XCTAssertTrue(config.enterSendsMessage)
    }

    // MARK: - Thinking Expanded By Default Tests

    func testThinkingExpandedByDefault_defaultsToFalse() {
        XCTAssertFalse(config.thinkingExpandedByDefault)
    }

    func testThinkingExpandedByDefault_persistsToUserDefaults() {
        config.thinkingExpandedByDefault = true

        let stored = UserDefaults.standard.bool(forKey: UserDefaultsKeys.thinkingExpandedByDefault)
        XCTAssertTrue(stored)
    }

    var freshConfigThinkingLoads: StoreConfiguration!

    func testThinkingExpandedByDefault_loadsFromUserDefaults() {
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.thinkingExpandedByDefault)

        freshConfigThinkingLoads = StoreConfiguration()

        XCTAssertTrue(freshConfigThinkingLoads.thinkingExpandedByDefault)
    }

    // MARK: - Tool Calls Expanded By Default Tests

    func testToolCallsExpandedByDefault_defaultsToFalse() {
        XCTAssertFalse(config.toolCallsExpandedByDefault)
    }

    func testToolCallsExpandedByDefault_persistsToUserDefaults() {
        config.toolCallsExpandedByDefault = true

        let stored = UserDefaults.standard.bool(forKey: UserDefaultsKeys.toolCallsExpandedByDefault)
        XCTAssertTrue(stored)
    }

    var freshConfigToolCallsLoads: StoreConfiguration!

    func testToolCallsExpandedByDefault_loadsFromUserDefaults() {
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.toolCallsExpandedByDefault)

        freshConfigToolCallsLoads = StoreConfiguration()

        XCTAssertTrue(freshConfigToolCallsLoads.toolCallsExpandedByDefault)
    }

    // MARK: - Artifacts Expanded By Default Tests

    func testArtifactsExpandedByDefault_defaultsToFalse() {
        XCTAssertFalse(config.artifactsExpandedByDefault)
    }

    func testArtifactsExpandedByDefault_persistsToUserDefaults() {
        config.artifactsExpandedByDefault = true

        let stored = UserDefaults.standard.bool(forKey: UserDefaultsKeys.artifactsExpandedByDefault)
        XCTAssertTrue(stored)
    }

    var freshConfigArtifactsLoads: StoreConfiguration!

    func testArtifactsExpandedByDefault_loadsFromUserDefaults() {
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.artifactsExpandedByDefault)

        freshConfigArtifactsLoads = StoreConfiguration()

        XCTAssertTrue(freshConfigArtifactsLoads.artifactsExpandedByDefault)
    }

    // MARK: - Debug Mode Enabled Tests

    func testDebugModeEnabled_defaultsToFalse() {
        XCTAssertFalse(config.debugModeEnabled)
    }

    func testDebugModeEnabled_persistsToUserDefaults() {
        config.debugModeEnabled = true

        let stored = UserDefaults.standard.bool(forKey: UserDefaultsKeys.debugModeEnabled)
        XCTAssertTrue(stored)
    }

    var freshConfigDebugModeLoads: StoreConfiguration!

    func testDebugModeEnabled_loadsFromUserDefaults() {
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.debugModeEnabled)

        freshConfigDebugModeLoads = StoreConfiguration()

        XCTAssertTrue(freshConfigDebugModeLoads.debugModeEnabled)
    }

    // MARK: - Enter Sends Message Tests

    func testEnterSendsMessage_defaultsToTrue() {
        XCTAssertTrue(config.enterSendsMessage)
    }

    func testEnterSendsMessage_persistsToUserDefaults() {
        config.enterSendsMessage = true

        let stored = UserDefaults.standard.bool(forKey: UserDefaultsKeys.enterSendsMessage)
        XCTAssertTrue(stored)
    }

    var freshConfigEnterSendsLoads: StoreConfiguration!

    func testEnterSendsMessage_loadsFromUserDefaults() {
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.enterSendsMessage)

        freshConfigEnterSendsLoads = StoreConfiguration()

        XCTAssertTrue(freshConfigEnterSendsLoads.enterSendsMessage)
    }

    // MARK: - UI Preferences Round Trip Tests

    var freshConfigUIPreferencesRoundTrip: StoreConfiguration!

    func testRoundTrip_uiPreferencesPersistAndReload() {
        config.thinkingExpandedByDefault = true
        config.toolCallsExpandedByDefault = true
        config.artifactsExpandedByDefault = true
        config.debugModeEnabled = true
        config.enterSendsMessage = true

        freshConfigUIPreferencesRoundTrip = StoreConfiguration()

        XCTAssertTrue(freshConfigUIPreferencesRoundTrip.thinkingExpandedByDefault)
        XCTAssertTrue(freshConfigUIPreferencesRoundTrip.toolCallsExpandedByDefault)
        XCTAssertTrue(freshConfigUIPreferencesRoundTrip.artifactsExpandedByDefault)
        XCTAssertTrue(freshConfigUIPreferencesRoundTrip.debugModeEnabled)
        XCTAssertTrue(freshConfigUIPreferencesRoundTrip.enterSendsMessage)
    }

    // MARK: - Sidebar Task Filter Tests

    func testSidebarTaskFilter_defaultsToAll() {
        XCTAssertEqual(config.sidebarTaskFilter, .all)
    }

    func testSidebarTaskFilter_persistsToUserDefaults() {
        config.sidebarTaskFilter = .running

        let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.sidebarTaskFilter)
        XCTAssertEqual(stored, TaskFilter.running.rawValue)
    }

    var freshConfigSidebarFilterLoads: StoreConfiguration!

    func testSidebarTaskFilter_loadsFromUserDefaults() {
        UserDefaults.standard.set(TaskFilter.done.rawValue, forKey: UserDefaultsKeys.sidebarTaskFilter)

        freshConfigSidebarFilterLoads = StoreConfiguration()

        XCTAssertEqual(freshConfigSidebarFilterLoads.sidebarTaskFilter, .done)
    }

    var freshConfigSidebarFilterInvalid: StoreConfiguration!

    func testSidebarTaskFilter_invalidStoredValue_defaultsToAll() {
        UserDefaults.standard.set("bogus", forKey: UserDefaultsKeys.sidebarTaskFilter)

        freshConfigSidebarFilterInvalid = StoreConfiguration()

        XCTAssertEqual(freshConfigSidebarFilterInvalid.sidebarTaskFilter, .all)
    }

    func testResetToDefaults_clearsSidebarTaskFilter() {
        config.sidebarTaskFilter = .done

        config.resetToDefaults()

        XCTAssertEqual(config.sidebarTaskFilter, .all)
    }
}
