import XCTest

@testable import NanoTeams

/// `StoreConfiguration+ModelResolution` — how settings slots resolve to a
/// concrete (model, server) pair, and which of them still point at a model.
///
/// Two regressions motivate this:
/// - The Vision empty→global fallback was re-implemented by hand in
///   `MainLayoutView`'s model-switch hook and diverged on whitespace: it tested
///   the RAW value, so `"   "` read as a real model name there and as "inherit
///   the global model" in `visionLLMConfig`.
/// - The unload guard enumerated only global / Vision / embedding, so the three
///   `LLMOverride` slots (team generation, bash judge, computer-use judge) were
///   invisible — switching the global model unloaded a model they still used.
@MainActor
final class StoreConfigurationModelResolutionTests: XCTestCase {

    private var storage: InMemoryStorage!
    private var config: StoreConfiguration!

    private let base = "http://127.0.0.1:1234"

    override func setUp() {
        super.setUp()
        storage = InMemoryStorage()
        config = StoreConfiguration(storage: storage)
        config.llmBaseURLString = base
        config.llmModelName = "global-model"
        config.visionEnabled = false
        config.visionModelName = ""
        config.visionBaseURLString = ""
        config.teamGenLLMOverride = nil
        config.bashJudgeLLMOverride = nil
        config.computerUseJudgeLLMOverride = nil
    }

    override func tearDown() {
        config = nil
        storage = nil
        super.tearDown()
    }

    // MARK: - Vision fallback

    func testResolvedVisionModel_explicitValue_winsAndIsTrimmed() {
        XCTAssertEqual(config.resolvedVisionModel(for: "  qwen-vl  "), "qwen-vl")
    }

    func testResolvedVisionModel_empty_inheritsGlobal() {
        XCTAssertEqual(config.resolvedVisionModel(for: ""), "global-model")
    }

    /// The divergence that motivated the extraction: a whitespace-only field is
    /// "inherit", not a model literally named `"   "`. The hand-rolled copy in
    /// the view passed `"   "` straight to the switch, which trimmed it to empty
    /// and then bailed — so the vision model was silently never loaded.
    func testResolvedVisionModel_whitespaceOnly_inheritsGlobal() {
        XCTAssertEqual(config.resolvedVisionModel(for: "   "), "global-model")
    }

    func testResolvedVisionModel_bothBlank_isEmpty() {
        config.llmModelName = "   "
        XCTAssertEqual(config.resolvedVisionModel(for: ""), "")
    }

    func testResolvedVisionBaseURL_trimsBothBranchesSymmetrically() {
        config.visionBaseURLString = "  http://vision:9000  "
        XCTAssertEqual(config.resolvedVisionBaseURL, "http://vision:9000")

        config.visionBaseURLString = "   "
        XCTAssertEqual(config.resolvedVisionBaseURL, base,
                       "A whitespace-only override means inherit, not a blank server")
    }

    /// The extracted helpers must be exactly what the request path uses —
    /// otherwise the switch hook swaps a different model than Vision calls.
    func testVisionLLMConfig_agreesWithTheExtractedHelpers() {
        config.visionEnabled = true
        config.visionModelName = "   "

        let resolved = config.visionLLMConfig
        XCTAssertEqual(resolved?.modelName, config.resolvedVisionModel(for: config.visionModelName))
        XCTAssertEqual(resolved?.baseURLString, config.resolvedVisionBaseURL)
        XCTAssertEqual(resolved?.modelName, "global-model")
    }

    // MARK: - Slot references: the originally-covered three

    func testReferencesModel_globalSlot() {
        XCTAssertTrue(config.referencesModel("global-model", base: base))
    }

    func testReferencesModel_visionSlot() {
        config.visionEnabled = true
        config.visionModelName = "qwen-vl"
        XCTAssertTrue(config.referencesModel("qwen-vl", base: base))
    }

    /// Vision inheriting the global model still references it — this is the
    /// case the original guard was written for.
    func testReferencesModel_visionInheritingGlobal_referencesGlobalModel() {
        config.visionEnabled = true
        config.visionModelName = ""
        XCTAssertTrue(config.referencesModel("global-model", base: base))
    }

    func testReferencesModel_embeddingSlot() {
        let embed = config.effectiveEmbeddingConfig
        XCTAssertTrue(config.referencesModel(embed.modelName, base: embed.baseURLString))
    }

    // MARK: - Slot references: the three that were missed

    func testReferencesModel_teamGenerationOverride() {
        config.teamGenLLMOverride = LLMOverride(modelName: "teamgen-model")
        XCTAssertTrue(
            config.referencesModel("teamgen-model", base: base),
            "Switching the global model must not unload the team-generation model")
    }

    /// A judge override counts only while its judge would actually be
    /// consulted — the judge runs in Auto approval, and Safety=Off
    /// short-circuits to allow before it is ever called.
    func testReferencesModel_bashJudgeOverride_whenActive() {
        config.bashMode = .auto
        config.bashRestrictionLevel = .standard
        config.bashJudgeLLMOverride = LLMOverride(modelName: "judge-model")
        XCTAssertTrue(config.referencesModel("judge-model", base: base))
    }

    /// Manual approval still uses the judge model — the "Ask AI" advisory on
    /// the approval card runs it. Gating this slot on `.auto` (the first cut)
    /// unloaded a model Manual mode actively uses.
    func testReferencesModel_bashJudgeOverride_inManualApproval_isStillReferenced() {
        config.bashMode = .manual
        config.bashRestrictionLevel = .standard
        config.bashJudgeLLMOverride = LLMOverride(modelName: "judge-model")
        XCTAssertTrue(config.referencesModel("judge-model", base: base))
    }

    /// Bash off entirely does retire it — no path can reach the judge.
    func testReferencesModel_bashJudgeOverride_whenBashIsOff_isFalse() {
        config.bashMode = .off
        config.bashRestrictionLevel = .standard
        config.bashJudgeLLMOverride = LLMOverride(modelName: "judge-model")
        XCTAssertFalse(
            config.referencesModel("judge-model", base: base),
            "A judge that can never run must not pin its model in memory")
    }

    func testReferencesModel_bashJudgeOverride_whenSafetyOff_isFalse() {
        config.bashMode = .auto
        config.bashRestrictionLevel = .off
        config.bashJudgeLLMOverride = LLMOverride(modelName: "judge-model")
        XCTAssertFalse(config.referencesModel("judge-model", base: base))
    }

    func testReferencesModel_computerUseJudgeOverride_whenActive() {
        config.computerUseMode = .auto
        config.computerUseRestrictionLevel = .standard
        config.computerUseJudgeLLMOverride = LLMOverride(modelName: "cu-judge-model")
        XCTAssertTrue(config.referencesModel("cu-judge-model", base: base))
    }

    func testReferencesModel_computerUseJudgeOverride_whenDisabled_isFalse() {
        config.computerUseMode = .off
        config.computerUseJudgeLLMOverride = LLMOverride(modelName: "cu-judge-model")
        XCTAssertFalse(config.referencesModel("cu-judge-model", base: base))
    }

    /// Team generation has no on/off toggle, so a configured override is
    /// always a live slot.
    func testReferencesModel_teamGenOverride_hasNoEnablementGate() {
        config.teamGenLLMOverride = LLMOverride(modelName: "teamgen-model")
        XCTAssertTrue(config.referencesModel("teamgen-model", base: base))
    }

    /// A URL-only override inherits the global MODEL, but against its own
    /// server — so it references (otherBase, globalModel), not (base, ...).
    func testReferencesModel_urlOnlyOverride_inheritsModelOnItsOwnServer() {
        config.teamGenLLMOverride = LLMOverride(baseURLString: "http://other:5000")

        XCTAssertTrue(config.referencesModel("global-model", base: "http://other:5000"))
    }

    /// A model-only override inherits the global SERVER.
    func testReferencesModel_modelOnlyOverride_inheritsGlobalServer() {
        config.teamGenLLMOverride = LLMOverride(modelName: "teamgen-model")
        XCTAssertFalse(config.referencesModel("teamgen-model", base: "http://other:5000"))
    }

    // MARK: - Negative + folding

    func testReferencesModel_unknownModel_isFalse() {
        XCTAssertFalse(config.referencesModel("never-configured", base: base))
    }

    func testReferencesModel_sameModelOnADifferentServer_isFalse() {
        XCTAssertFalse(
            config.referencesModel("global-model", base: "http://elsewhere:1234"),
            "A model is only 'still referenced' on the server that serves it")
    }

    /// Model names fold case (a hand-typed override differing in case is the
    /// same model) and servers fold trailing slash / case.
    func testReferencesModel_foldsModelCaseAndURLShape() {
        XCTAssertTrue(config.referencesModel("GLOBAL-MODEL", base: "HTTP://127.0.0.1:1234/"))
    }

    func testReferencesModel_blankModel_isFalse() {
        XCTAssertFalse(config.referencesModel("   ", base: base))
    }

    /// An override struct with all fields unset is not a slot of its own — it
    /// just means "use the global config", which slot 1 already covers.
    func testReferencesModel_emptyOverride_addsNoSlot() {
        config.teamGenLLMOverride = LLMOverride()
        XCTAssertFalse(config.referencesModel("never-configured", base: base))
    }
}

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
