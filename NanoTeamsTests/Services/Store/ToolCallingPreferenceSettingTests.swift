import XCTest

@testable import NanoTeams

/// The "Tool calling" setting through the full recipe: default, persistence, the fail-open
/// read, and the reset that removes the stored key AND puts the live value back.
@MainActor
final class ToolCallingPreferenceSettingTests: XCTestCase {

    private var storage: InMemoryConfigurationStorage!
    private var config: StoreConfiguration!

    override func setUp() async throws {
        try await super.setUp()
        storage = InMemoryConfigurationStorage()
        config = StoreConfiguration(storage: storage)
    }

    override func tearDown() async throws {
        config = nil
        storage = nil
        try await super.tearDown()
    }

    func testDefault_isAuto() {
        XCTAssertEqual(config.toolCallingPreference, .auto)
        XCTAssertNil(storage.string(forKey: UserDefaultsKeys.toolCallingPreference), "the default is not pinned by a write")
    }

    func testAssignment_persistsTheRawValue_andSurvivesARelaunch() {
        config.toolCallingPreference = .native
        XCTAssertEqual(storage.string(forKey: UserDefaultsKeys.toolCallingPreference), "native")
        XCTAssertEqual(StoreConfiguration(storage: storage).toolCallingPreference, .native)
    }

    /// An unknown rawValue (a downgrade, a hand-edited plist) must not pin the install to
    /// either protocol.
    func testUnreadableStoredValue_failsOpenToAuto() {
        storage.set("harmony-v2", forKey: UserDefaultsKeys.toolCallingPreference)
        XCTAssertEqual(StoreConfiguration(storage: storage).toolCallingPreference, .auto)
    }

    /// `resetToDefaults` removes the key AND assigns the default, whose `didSet` persists it
    /// again — so what a relaunch reads is the default, not the value reset away.
    func testReset_restoresTheDefault_forTheLiveValueAndTheNextLaunch() {
        config.toolCallingPreference = .promptTaught
        config.resetToDefaults()
        XCTAssertEqual(config.toolCallingPreference, .auto)
        XCTAssertNotEqual(storage.string(forKey: UserDefaultsKeys.toolCallingPreference), "promptTaught")
        XCTAssertEqual(StoreConfiguration(storage: storage).toolCallingPreference, .auto)
    }

    /// The key follows the `NanoTeams.<area>.<name>.v1` convention every new key uses.
    func testKey_followsTheConvention() {
        XCTAssertEqual(UserDefaultsKeys.toolCallingPreference, "NanoTeams.llm.toolCallingPreference.v1")
    }

    /// The delegate surface the execution service reads — the orchestrator forwards this
    /// property, so a preference the user set is the one the resolver sees.
    func testGlobalLLMConfig_startsPromptTaught_theResolverStampsTheMode() {
        XCTAssertEqual(config.globalLLMConfig.toolCallingMode, .promptTaught,
                       "the config's mode is written only by the resolver, never by the settings")
    }
}
