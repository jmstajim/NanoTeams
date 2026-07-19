import XCTest

@testable import NanoTeams

/// Pins the predicate that decides whether `analyze_image` stays in role
/// toolsets. Regression: when the user picked "Use global: <model>" in the
/// vision picker (which stores `visionModelName = ""`), `isVisionConfigured`
/// returned `false` and the tool was silently dropped, even though
/// `visionEnabled = true` and the global model was perfectly callable.
@MainActor
final class VisionConfigurationTests: XCTestCase {

    private var storage: InMemoryStorage!
    private var config: StoreConfiguration!

    override func setUp() {
        super.setUp()
        storage = InMemoryStorage()
        config = StoreConfiguration(storage: storage)
        config.llmModelName = ""
        config.visionEnabled = false
        config.visionModelName = ""
        config.visionBaseURLString = ""
    }

    override func tearDown() {
        config = nil
        storage = nil
        super.tearDown()
    }

    // MARK: - isVisionConfigured

    func testDisabled_overridesEverything() {
        config.visionEnabled = false
        config.visionModelName = "qwen-vl"
        config.llmModelName = "google/gemma-4"
        XCTAssertFalse(config.isVisionConfigured)
        XCTAssertNil(config.visionLLMConfig)
    }

    func testEnabled_butBothModelsEmpty_isNotConfigured() {
        config.visionEnabled = true
        config.visionModelName = ""
        config.llmModelName = ""
        XCTAssertFalse(config.isVisionConfigured)
        XCTAssertNil(config.visionLLMConfig)
    }

    /// Use global model: `visionModelName` is empty, but the global model
    /// is set. Pre-fix this returned `false` and broke vision.
    func testEnabled_visionEmpty_globalSet_isConfigured() {
        config.visionEnabled = true
        config.visionModelName = ""
        config.llmModelName = "google/gemma-4-26b-a4b"
        XCTAssertTrue(config.isVisionConfigured)
        let cfg = config.visionLLMConfig
        XCTAssertEqual(cfg?.modelName, "google/gemma-4-26b-a4b")
    }

    func testEnabled_visionOverride_takesPrecedence() {
        config.visionEnabled = true
        config.visionModelName = "qwen-vl"
        config.llmModelName = "google/gemma-4"
        XCTAssertTrue(config.isVisionConfigured)
        XCTAssertEqual(config.visionLLMConfig?.modelName, "qwen-vl")
    }

    func testEnabled_visionOverride_globalEmpty_stillConfigured() {
        config.visionEnabled = true
        config.visionModelName = "qwen-vl"
        config.llmModelName = ""
        XCTAssertTrue(config.isVisionConfigured)
        XCTAssertEqual(config.visionLLMConfig?.modelName, "qwen-vl")
    }

    func testEnabled_globalWhitespaceOnly_isNotConfigured() {
        config.visionEnabled = true
        config.visionModelName = ""
        config.llmModelName = "   \n  "
        XCTAssertFalse(config.isVisionConfigured)
        XCTAssertNil(config.visionLLMConfig)
    }

    /// I3: regression — pre-fix the override branch matched on `!isEmpty`
    /// directly, so a whitespace-only `visionModelName` reported `true`
    /// while the global-fallback branch (which trimmed) reported `false`.
    /// Both branches must trim symmetrically.
    func testEnabled_visionWhitespaceOnly_globalEmpty_isNotConfigured() {
        config.visionEnabled = true
        config.visionModelName = "   \n  "
        config.llmModelName = ""
        XCTAssertFalse(
            config.isVisionConfigured,
            "Whitespace-only vision model name must not be treated as a real value"
        )
        XCTAssertNil(config.visionLLMConfig)
    }

    /// I3: when whitespace-only override falls through, the global model
    /// (if real) wins. Order of trim/fallback must work.
    func testEnabled_visionWhitespace_globalSet_fallsBackToGlobal() {
        config.visionEnabled = true
        config.visionModelName = "   "
        config.llmModelName = "google/gemma-4-26b-a4b"
        config.llmBaseURLString = "http://127.0.0.1:1234"
        XCTAssertTrue(config.isVisionConfigured)
        XCTAssertEqual(config.visionLLMConfig?.modelName, "google/gemma-4-26b-a4b")
    }

    // MARK: - I3: empty baseURLString must filter at schema-time

    /// Pre-fix `visionLLMConfig` returned a `LLMConfig` with empty
    /// `baseURLString` whenever both URL fields were empty — request-time
    /// failure with a generic transport error instead of clean schema-time
    /// filtering.
    func testEnabled_modelSet_butBothURLsEmpty_returnsNil() {
        config.visionEnabled = true
        config.visionModelName = "qwen-vl"
        config.visionBaseURLString = ""
        config.llmBaseURLString = ""
        XCTAssertNil(
            config.visionLLMConfig,
            "Empty base URL on both override and global must return nil so the schema filter drops analyze_image"
        )
    }

    func testEnabled_modelSet_visionURLWhitespaceOnly_globalEmpty_returnsNil() {
        config.visionEnabled = true
        config.visionModelName = "qwen-vl"
        config.visionBaseURLString = "   "
        config.llmBaseURLString = ""
        XCTAssertNil(config.visionLLMConfig)
    }

    func testEnabled_modelSet_visionURLEmpty_globalSet_inheritsGlobalURL() {
        config.visionEnabled = true
        config.visionModelName = "qwen-vl"
        config.visionBaseURLString = ""
        config.llmBaseURLString = "http://10.0.0.1:1234"
        XCTAssertNotNil(config.visionLLMConfig)
        XCTAssertEqual(config.visionLLMConfig?.baseURLString, "http://10.0.0.1:1234")
    }

    // MARK: - visionLLMConfig URL fallback

    func testURL_visionEmpty_inheritsGlobalURL() {
        config.visionEnabled = true
        config.visionModelName = ""
        config.llmModelName = "google/gemma-4"
        config.llmBaseURLString = "http://127.0.0.1:1234"
        config.visionBaseURLString = ""
        XCTAssertEqual(config.visionLLMConfig?.baseURLString, "http://127.0.0.1:1234")
    }

    func testURL_visionOverride_takesPrecedence() {
        config.visionEnabled = true
        config.visionModelName = "qwen-vl"
        config.llmBaseURLString = "http://127.0.0.1:1234"
        config.visionBaseURLString = "http://10.0.0.5:1234"
        XCTAssertEqual(config.visionLLMConfig?.baseURLString, "http://10.0.0.5:1234")
    }

    // MARK: - Schema-filter integration

    /// Pins the actual filter in `LLMExecutionService+ToolResolution.swift:170`
    /// (`if delegate.visionLLMConfig == nil { remove analyze_image }`). The
    /// table-driven tests above pin the predicate, but a regression here —
    /// e.g. swapping `visionLLMConfig` for a different gate, or reversing
    /// the polarity — would slip past those without this end-to-end test.
    // I7: `async` keeps these tests off the sync-method path that aborted on
    // Xcode 26.3 when constructing `@MainActor` types as locals. CLAUDE.md
    // "Common API pitfalls when writing tests" — sync `@MainActor` tests that
    // re-assign / construct `@MainActor` instances inline race the runtime
    // isolation check.
    func testToolSchemas_analyzeImageDropped_whenVisionLLMConfigIsNil() async throws {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        delegate.visionLLMConfig = nil
        service.attach(delegate: delegate)

        let role = TeamRoleDefinition(
            id: UUID().uuidString,
            name: "Vision User",
            prompt: "p",
            toolIDs: [ToolNames.readFile, ToolNames.analyzeImage],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        let team = Team(
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )

        let schemas = service.toolSchemas(for: .custom(id: "Vision User"), team: team)
        XCTAssertFalse(
            schemas.contains(where: { $0.name == ToolNames.analyzeImage }),
            "analyze_image must be filtered out when visionLLMConfig is nil"
        )
    }

    /// "Use global" case: `visionLLMConfig` is non-nil even though
    /// `visionModelName == ""`. The schema filter MUST keep `analyze_image`.
    /// Pre-fix this regressed because `visionLLMConfig` returned nil.
    func testToolSchemas_analyzeImageKept_whenUseGlobal() async throws {
        let service = LLMExecutionService(repository: NTMSRepository())
        let delegate = MockLLMExecutionDelegate()
        delegate.visionLLMConfig = LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://127.0.0.1:1234",
            modelName: "google/gemma-4-26b-a4b",
            temperature: 0.0
        )
        service.attach(delegate: delegate)

        let role = TeamRoleDefinition(
            id: UUID().uuidString,
            name: "Vision User",
            prompt: "p",
            toolIDs: [ToolNames.readFile, ToolNames.analyzeImage],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        let team = Team(
            name: "T", roles: [role], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )

        let schemas = service.toolSchemas(for: .custom(id: "Vision User"), team: team)
        XCTAssertTrue(
            schemas.contains(where: { $0.name == ToolNames.analyzeImage }),
            "analyze_image must stay in toolset when visionLLMConfig is set "
                + "(this is the regression: \"Use global\" → empty visionModelName "
                + "→ visionLLMConfig was nil → analyze_image silently dropped)"
        )
    }

    // MARK: - Default value (fresh install / reset)

    /// Vision is ON by default: a fresh install (no `visionEnabled` key in
    /// storage, no stored model) must come up enabled. `async` per I7 above —
    /// constructing `@MainActor` types inline in a sync test aborts on
    /// Xcode 26.3.
    func testDefault_freshStorage_visionEnabledIsTrue() async {
        let fresh = StoreConfiguration(storage: InMemoryStorage())
        XCTAssertTrue(fresh.visionEnabled)
    }

    /// An explicitly stored `false` (user toggled Vision off) must survive —
    /// the default only applies while the key is absent.
    func testDefault_storedFalse_wins() async {
        let seeded = InMemoryStorage()
        seeded.set(false, forKey: UserDefaultsKeys.visionEnabled)
        let cfg = StoreConfiguration(storage: seeded)
        XCTAssertFalse(cfg.visionEnabled)
    }

    func testDefault_storedTrue_wins() async {
        let seeded = InMemoryStorage()
        seeded.set(true, forKey: UserDefaultsKeys.visionEnabled)
        let cfg = StoreConfiguration(storage: seeded)
        XCTAssertTrue(cfg.visionEnabled)
    }

    /// Legacy upgrade path: an install with a configured vision model but no
    /// `visionEnabled` key yet (pre-toggle builds) must stay ON.
    func testDefault_legacyModelConfigured_noKey_staysEnabled() async {
        let seeded = InMemoryStorage()
        seeded.set("qwen-vl", forKey: UserDefaultsKeys.visionModelName)
        let cfg = StoreConfiguration(storage: seeded)
        XCTAssertTrue(cfg.visionEnabled)
    }

    /// `resetToDefaults()` must land on the same ON default. The `didSet`
    /// re-persists the assigned default immediately, so assert the RELOADED
    /// value — never key absence (see Грабли 2026-06-27).
    func testResetToDefaults_visionEnabledIsTrue() async {
        config.visionEnabled = false
        config.resetToDefaults()
        XCTAssertTrue(config.visionEnabled)
        let reloaded = StoreConfiguration(storage: storage)
        XCTAssertTrue(reloaded.visionEnabled)
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
