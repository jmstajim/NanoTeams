import XCTest

@testable import NanoTeams

@MainActor
final class StoreConfigurationTests: XCTestCase {

    // MARK: - Test Subject

    var config: StoreConfiguration!
    private var storage: InMemoryConfigurationStorage!

    // MARK: - Test Lifecycle

    // Order-dependence used to be the hazard here: the provider decides which defaults
    // `llmBaseURLString` / `llmModelName` fall back to, so an earlier suite leaving
    // `llmProvider` = ollama in the shared domain made `testInit_withNoStoredValues_usesDefaults`
    // pass alone and fail in a full run. A fresh per-test store removes the coupling entirely
    // rather than clearing keys around it.

    override func setUp() async throws {
        try await super.setUp()
        // A per-PROCESS store, so this suite no longer save/clear/restores the SHARED defaults
        // domain around every test. That dance existed only because parallel XCTest workers see
        // one domain (several host processes, one bundle identifier) — and while it ran, every
        // other worker's reads saw the cleared keys. `DEBTS.md` D-4.
        storage = InMemoryConfigurationStorage()
        config = StoreConfiguration(storage: storage)
    }

    override func tearDown() async throws {
        config = nil
        storage = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInit_withNoStoredValues_usesDefaults() {
        XCTAssertEqual(config.llmBaseURLString, AppDefaults.llmBaseURL)
        XCTAssertEqual(config.llmModelName, AppDefaults.llmModel)
    }

    var freshConfigWithStoredValues: StoreConfiguration!

    func testInit_withStoredValues_loadsFromUserDefaults() {
        // Set up stored values
        storage.set("http://custom:8080", forKey: UserDefaultsKeys.llmBaseURL)
        storage.set("custom-model", forKey: UserDefaultsKeys.llmModel)

        // Create fresh instance to test initialization with pre-populated UserDefaults
        freshConfigWithStoredValues = StoreConfiguration(storage: storage)

        XCTAssertEqual(freshConfigWithStoredValues.llmBaseURLString, "http://custom:8080")
        XCTAssertEqual(freshConfigWithStoredValues.llmModelName, "custom-model")
    }

    // MARK: - LLM Base URL Tests

    func testLLMBaseURLString_persistsToUserDefaults() {
        config.llmBaseURLString = "http://newhost:9999"

        let stored = storage.string(forKey: UserDefaultsKeys.llmBaseURL)
        XCTAssertEqual(stored, "http://newhost:9999")
    }

    func testLLMBaseURL_aliasReadsFromLLMBaseURLString() {
        config.llmBaseURLString = "http://alias-test:1234"

        XCTAssertEqual(config.llmBaseURL, "http://alias-test:1234")
    }

    func testLLMBaseURL_aliasWritesToLLMBaseURLString() {
        config.llmBaseURL = "http://via-alias:5678"

        XCTAssertEqual(config.llmBaseURLString, "http://via-alias:5678")
        let stored = storage.string(forKey: UserDefaultsKeys.llmBaseURL)
        XCTAssertEqual(stored, "http://via-alias:5678")
    }

    // MARK: - LLM Model Name Tests

    func testLLMModelName_persistsToUserDefaults() {
        config.llmModelName = "gpt-4-turbo"

        let stored = storage.string(forKey: UserDefaultsKeys.llmModel)
        XCTAssertEqual(stored, "gpt-4-turbo")
    }

    func testLLMModelName_acceptsEmptyString() {
        config.llmModelName = ""

        XCTAssertEqual(config.llmModelName, "")
        let stored = storage.string(forKey: UserDefaultsKeys.llmModel)
        XCTAssertEqual(stored, "")
    }

    // MARK: - Persistence Round-Trip Tests

    var freshConfigAllPropertiesPersistAndReload: StoreConfiguration!

    func testRoundTrip_allPropertiesPersistAndReload() {
        // Set values on shared config
        config.llmBaseURLString = "http://roundtrip:7777"
        config.llmModelName = "roundtrip-model"

        // Create fresh instance - should load from UserDefaults
        freshConfigAllPropertiesPersistAndReload = StoreConfiguration(storage: storage)

        XCTAssertEqual(freshConfigAllPropertiesPersistAndReload.llmBaseURLString, "http://roundtrip:7777")
        XCTAssertEqual(freshConfigAllPropertiesPersistAndReload.llmModelName, "roundtrip-model")
    }

    // MARK: - Observable Tests

    func testConfiguration_isObservable() {
        // Verify StoreConfiguration uses @Observable (properties are readable)
        XCTAssertNotNil(config.llmBaseURLString)
        XCTAssertNotNil(config.llmModelName)
        XCTAssertFalse(config.debugModeEnabled)
        XCTAssertTrue(config.enterSendsMessage)
    }

    // MARK: - Debug Mode Enabled Tests

    func testDebugModeEnabled_defaultsToFalse() {
        XCTAssertFalse(config.debugModeEnabled)
    }

    func testDebugModeEnabled_persistsToUserDefaults() {
        config.debugModeEnabled = true

        let stored = storage.bool(forKey: UserDefaultsKeys.debugModeEnabled)
        XCTAssertTrue(stored)
    }

    var freshConfigDebugModeLoads: StoreConfiguration!

    func testDebugModeEnabled_loadsFromUserDefaults() {
        storage.set(true, forKey: UserDefaultsKeys.debugModeEnabled)

        freshConfigDebugModeLoads = StoreConfiguration(storage: storage)

        XCTAssertTrue(freshConfigDebugModeLoads.debugModeEnabled)
    }

    // MARK: - Enter Sends Message Tests

    func testEnterSendsMessage_defaultsToTrue() {
        XCTAssertTrue(config.enterSendsMessage)
    }

    func testEnterSendsMessage_persistsToUserDefaults() {
        config.enterSendsMessage = true

        let stored = storage.bool(forKey: UserDefaultsKeys.enterSendsMessage)
        XCTAssertTrue(stored)
    }

    var freshConfigEnterSendsLoads: StoreConfiguration!

    func testEnterSendsMessage_loadsFromUserDefaults() {
        storage.set(true, forKey: UserDefaultsKeys.enterSendsMessage)

        freshConfigEnterSendsLoads = StoreConfiguration(storage: storage)

        XCTAssertTrue(freshConfigEnterSendsLoads.enterSendsMessage)
    }

    // MARK: - UI Preferences Round Trip Tests

    var freshConfigUIPreferencesRoundTrip: StoreConfiguration!

    func testRoundTrip_uiPreferencesPersistAndReload() {
        config.debugModeEnabled = true
        config.enterSendsMessage = true

        freshConfigUIPreferencesRoundTrip = StoreConfiguration(storage: storage)

        XCTAssertTrue(freshConfigUIPreferencesRoundTrip.debugModeEnabled)
        XCTAssertTrue(freshConfigUIPreferencesRoundTrip.enterSendsMessage)
    }

    // MARK: - Sidebar Task Filter Tests

    func testSidebarTaskFilter_defaultsToAll() {
        XCTAssertEqual(config.sidebarTaskFilter, .all)
    }

    func testSidebarTaskFilter_persistsToUserDefaults() {
        config.sidebarTaskFilter = .running

        let stored = storage.string(forKey: UserDefaultsKeys.sidebarTaskFilter)
        XCTAssertEqual(stored, TaskFilter.running.rawValue)
    }

    var freshConfigSidebarFilterLoads: StoreConfiguration!

    func testSidebarTaskFilter_loadsFromUserDefaults() {
        storage.set(TaskFilter.done.rawValue, forKey: UserDefaultsKeys.sidebarTaskFilter)

        freshConfigSidebarFilterLoads = StoreConfiguration(storage: storage)

        XCTAssertEqual(freshConfigSidebarFilterLoads.sidebarTaskFilter, .done)
    }

    var freshConfigSidebarFilterInvalid: StoreConfiguration!

    func testSidebarTaskFilter_invalidStoredValue_defaultsToAll() {
        storage.set("bogus", forKey: UserDefaultsKeys.sidebarTaskFilter)

        freshConfigSidebarFilterInvalid = StoreConfiguration(storage: storage)

        XCTAssertEqual(freshConfigSidebarFilterInvalid.sidebarTaskFilter, .all)
    }

    func testResetToDefaults_clearsSidebarTaskFilter() {
        config.sidebarTaskFilter = .done

        config.resetToDefaults()

        XCTAssertEqual(config.sidebarTaskFilter, .all)
    }

    // MARK: - Embed Files In Prompt Tests

    func testEmbedFilesInPrompt_defaultsToFalse() {
        XCTAssertFalse(config.embedFilesInPrompt)
    }

    func testEmbedFilesInPrompt_persistsToUserDefaults() {
        config.embedFilesInPrompt = true

        let stored = storage.bool(forKey: UserDefaultsKeys.quickCaptureEmbedFiles)
        XCTAssertTrue(stored)
    }

    var freshConfigEmbedFilesLoads: StoreConfiguration!

    func testEmbedFilesInPrompt_loadsFromUserDefaults() {
        storage.set(true, forKey: UserDefaultsKeys.quickCaptureEmbedFiles)

        freshConfigEmbedFilesLoads = StoreConfiguration(storage: storage)

        XCTAssertTrue(freshConfigEmbedFilesLoads.embedFilesInPrompt)
    }

    func testResetToDefaults_clearsEmbedFilesInPrompt() {
        config.embedFilesInPrompt = true

        config.resetToDefaults()

        XCTAssertFalse(config.embedFilesInPrompt)
    }
}
