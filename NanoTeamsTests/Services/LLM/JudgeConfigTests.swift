import XCTest

@testable import NanoTeams

/// `JudgeConfig` override-application corners — the config half of the judge
/// pair's no-drift contract. Provider resolution must match
/// `buildEffectiveConfig` (`override.provider ?? base.provider`), including
/// the whitespace-trimming asymmetry: URL/model fields are trimmed (blank =
/// inherit), provider is a typed optional (nil = inherit).
final class JudgeConfigTests: XCTestCase {

    private var base: LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://global:1234",
            modelName: "global-model"
        )
    }

    // MARK: - applying(_:to:)

    func testApplying_nilOverride_returnsBaseUnchanged() {
        let result = JudgeConfig.applying(nil, to: base)
        XCTAssertEqual(result, base)
    }

    func testApplying_emptyOverride_returnsBaseUnchanged() {
        let result = JudgeConfig.applying(LLMOverride(), to: base)
        XCTAssertEqual(result, base)
    }

    func testApplying_providerOnlyOverride_changesOnlyProvider() {
        let result = JudgeConfig.applying(LLMOverride(provider: .ollama), to: base)
        XCTAssertEqual(result.provider, .ollama)
        XCTAssertEqual(result.baseURLString, "http://global:1234",
                       "URL must stay inherited — a provider pin alone must not touch the endpoint")
        XCTAssertEqual(result.modelName, "global-model")
    }

    func testApplying_whitespaceURL_ignoredButProviderStillApplied() {
        let override = LLMOverride(baseURLString: "   ", provider: .ollama)
        let result = JudgeConfig.applying(override, to: base)
        XCTAssertEqual(result.baseURLString, "http://global:1234",
                       "whitespace-only URL means inherit")
        XCTAssertEqual(result.provider, .ollama)
    }

    func testApplying_fullOverride_appliesAllThree() {
        let override = LLMOverride(
            baseURLString: "http://judge:11434",
            modelName: "gpt-oss:20b",
            provider: .ollama
        )
        let result = JudgeConfig.applying(override, to: base)
        XCTAssertEqual(result.provider, .ollama)
        XCTAssertEqual(result.baseURLString, "http://judge:11434")
        XCTAssertEqual(result.modelName, "gpt-oss:20b")
    }

    func testApplying_overrideWithoutProvider_inheritsBaseProvider() {
        let override = LLMOverride(baseURLString: "http://judge:9999")
        let result = JudgeConfig.applying(override, to: base)
        XCTAssertEqual(result.provider, .lmStudio,
                       "nil provider = inherit — the pre-provider behavior must survive")
    }

    // MARK: - forVerdict(_:override:)

    func testForVerdict_pinsTemperatureZero_andKeepsOverrideProvider() {
        let override = LLMOverride(
            baseURLString: "http://judge:11434", provider: .ollama)
        let result = JudgeConfig.forVerdict(base, override: override)
        XCTAssertEqual(result.temperature, 0,
                       "verdicts are strict JSON — inherited sampling variance has no business here")
        XCTAssertEqual(result.provider, .ollama)
        XCTAssertEqual(result.baseURLString, "http://judge:11434")
    }

    func testForVerdict_noOverride_pinsTemperatureOnBase() {
        let result = JudgeConfig.forVerdict(base, override: nil)
        XCTAssertEqual(result.temperature, 0)
        XCTAssertEqual(result.provider, base.provider)
        XCTAssertEqual(result.baseURLString, base.baseURLString)
    }
}
