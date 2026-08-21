import XCTest

@testable import NanoTeams

/// The benchmark screen's own settings. The whole point of them is that they are SEPARATE from the
/// active LLM settings — measuring a model must not switch the app onto it — so these pin that
/// separation, the persistence round trip, and the clamp.
@MainActor
final class BenchmarkConfigurationTests: XCTestCase, @unchecked Sendable {

    private var storage: InMemoryStorage!
    private var config: StoreConfiguration!

    override func setUp() async throws {
        try await super.setUp()
        storage = InMemoryStorage()
        config = StoreConfiguration(storage: storage)
    }

    override func tearDown() async throws {
        config = nil
        storage = nil
        try await super.tearDown()
    }

    // MARK: - Target

    func testTarget_defaultsToNil_soTheScreenCanSeedItFromTheAppSettings() async {
        XCTAssertNil(config.benchmarkTarget)
    }

    func testTarget_persistsAndReloads() async {
        let target = BenchmarkTarget(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "qwen3.8")
        config.benchmarkTarget = target

        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertEqual(reloaded.benchmarkTarget, target)
    }

    /// RED: keep the stale blob when the target is cleared → the next launch resurrects a target
    /// the user deliberately removed.
    func testTarget_settingNilRemovesTheStoredValue() async {
        config.benchmarkTarget = BenchmarkTarget(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
        XCTAssertNotNil(storage.data(forKey: UserDefaultsKeys.benchmarkTarget))

        config.benchmarkTarget = nil
        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.benchmarkTarget))
        XCTAssertNil(StoreConfiguration(storage: storage).benchmarkTarget)
    }

    /// The separation is the feature. RED: write the app's active settings from the benchmark
    /// target → every comparison silently reconfigures the workspace it was run from.
    func testTarget_doesNotTouchTheActiveLLMSettings() async {
        let originalModel = config.llmModelName
        let originalURL = config.llmBaseURLString
        let originalProvider = config.llmProvider

        config.benchmarkTarget = BenchmarkTarget(
            provider: originalProvider == .ollama ? .lmStudio : .ollama,
            baseURLString: "http://192.168.1.9:9999",
            modelName: "some-other-model")

        XCTAssertEqual(config.llmModelName, originalModel)
        XCTAssertEqual(config.llmBaseURLString, originalURL)
        XCTAssertEqual(config.llmProvider, originalProvider)
    }

    // MARK: - Repeats

    // MARK: - The request a measurement sends

    /// `BenchmarkSweepSettings.benchmarkConfig(for:)` exists so the prompt preview, the Run button
    /// and the sweep all read ONE assembly of the request. Timeout and keep-alive are transport
    /// policy and come from settings; everything being compared comes from the target.
    /// RED: assemble the config in the sweep instead, or read the timeout from anywhere but
    /// `llmRequestTimeoutSeconds` → the sweep silently measures under different conditions than the
    /// Run button, producing rows that share a leaderboard group and nothing else.
    func testBenchmarkConfig_carriesTheTargetAndTheAppsTransportPolicy() async {
        config.llmRequestTimeoutSeconds = 123
        let target = BenchmarkTarget(
            provider: .ollama, baseURLString: "http://box:11434", modelName: "m")

        let wire = config.benchmarkConfig(for: target)

        XCTAssertEqual(wire.provider, .ollama)
        XCTAssertEqual(wire.baseURLString, "http://box:11434")
        XCTAssertEqual(wire.modelName, "m")
        XCTAssertEqual(wire.requestTimeoutSeconds, 123)
        XCTAssertEqual(wire.keepAliveSeconds, config.globalLLMConfig.keepAliveSeconds)
    }

    func testRepeats_defaultsToTheHouseValue() async {
        XCTAssertEqual(config.benchmarkRepeats, AppDefaults.benchmarkRepeats)
    }

    /// RED: trust the stored value → a hand-edited 0 makes every run fail with "no usable
    /// samples", and a huge one holds the machine for minutes with nothing to distinguish it from
    /// a hang.
    func testRepeats_isClampedToTheOfferedRange() async {
        config.benchmarkRepeats = 0
        XCTAssertEqual(config.benchmarkRepeats, AppDefaults.benchmarkRepeatsRange.lowerBound)

        config.benchmarkRepeats = 9999
        XCTAssertEqual(config.benchmarkRepeats, AppDefaults.benchmarkRepeatsRange.upperBound)
    }

    func testRepeats_persistsAndReloads() async {
        config.benchmarkRepeats = 7
        XCTAssertEqual(StoreConfiguration(storage: storage).benchmarkRepeats, 7)
    }

    // MARK: - Reset

    /// Both halves of the reset contract: the stored key AND the in-memory value.
    /// RED: drop either → Reset leaves the old value live until relaunch, or restores it on the
    /// next launch.
    func testResetToDefaults_clearsBoth() async {
        config.benchmarkRepeats = 12
        config.benchmarkTarget = BenchmarkTarget(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m")

        config.resetToDefaults()

        XCTAssertEqual(config.benchmarkRepeats, AppDefaults.benchmarkRepeats)
        XCTAssertNil(config.benchmarkTarget)
        XCTAssertNil(storage.data(forKey: UserDefaultsKeys.benchmarkTarget))
        XCTAssertNil(StoreConfiguration(storage: storage).benchmarkTarget)
    }
}

/// House pattern: `private` is file-scoped in Swift, so each test file owns its own storage stub.
private final class InMemoryStorage: ConfigurationStorage {
    private var store: [String: Any] = [:]

    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
