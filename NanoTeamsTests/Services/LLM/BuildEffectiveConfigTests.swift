//
//  BuildEffectiveConfigTests.swift
//  NanoTeamsTests
//
//  Tests for LLMExecutionService.buildEffectiveConfig() — static method that applies
//  per-role LLM overrides to the global config.
//

import XCTest
@testable import NanoTeams

@MainActor
final class BuildEffectiveConfigTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a global config with deterministic non-default values
    /// so tests can distinguish "came from global" vs "came from provider default".
    private func makeGlobalConfig(
        baseURLString: String? = nil,
        modelName: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = 0.7
    ) -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: baseURLString ?? "http://custom-global:9999",
            modelName: modelName ?? "global-model-v1",
            maxTokens: maxTokens ?? 4096,
            temperature: temperature
        )
    }

    // MARK: - 1. No Override

    func testNoOverride_returnsGlobalConfig() {
        let global = makeGlobalConfig()

        let result = LLMExecutionService.buildEffectiveConfig(
            globalConfig: global,
            roleOverride: nil
        )

        XCTAssertEqual(result.provider, global.provider)
        XCTAssertEqual(result.baseURLString, global.baseURLString)
        XCTAssertEqual(result.modelName, global.modelName)
        XCTAssertEqual(result.maxTokens, global.maxTokens)
        XCTAssertEqual(result.temperature, global.temperature)
    }

    func testEmptyOverride_returnsGlobalConfig() {
        let global = makeGlobalConfig()
        let emptyOverride = LLMOverride()
        XCTAssertTrue(emptyOverride.isEmpty, "Precondition: override with all nils should be empty")

        let result = LLMExecutionService.buildEffectiveConfig(
            globalConfig: global,
            roleOverride: emptyOverride
        )

        XCTAssertEqual(result.provider, global.provider)
        XCTAssertEqual(result.baseURLString, global.baseURLString)
        XCTAssertEqual(result.modelName, global.modelName)
        XCTAssertEqual(result.maxTokens, global.maxTokens)
        XCTAssertEqual(result.temperature, global.temperature)
    }

    // MARK: - 2. Model/BaseURL Override Only

    func testOverrideModelOnly_usesOverrideModelWithGlobalBaseURL() {
        let global = makeGlobalConfig()
        let override = LLMOverride(modelName: "special-model-v2")

        let result = LLMExecutionService.buildEffectiveConfig(
            globalConfig: global,
            roleOverride: override
        )

        XCTAssertEqual(result.provider, global.provider, "Provider should remain global")
        XCTAssertEqual(result.baseURLString, global.baseURLString, "BaseURL should remain global")
        XCTAssertEqual(result.modelName, "special-model-v2", "Model should come from override")
        XCTAssertEqual(result.maxTokens, global.maxTokens, "MaxTokens should remain global")
        XCTAssertEqual(result.temperature, global.temperature, "Temperature should remain global")
    }

    func testOverrideBaseURLOnly_usesOverrideBaseURLWithGlobalModel() {
        let global = makeGlobalConfig()
        let override = LLMOverride(baseURLString: "http://override-server:5555")

        let result = LLMExecutionService.buildEffectiveConfig(
            globalConfig: global,
            roleOverride: override
        )

        XCTAssertEqual(result.provider, global.provider, "Provider should remain global")
        XCTAssertEqual(result.baseURLString, "http://override-server:5555", "BaseURL should come from override")
        XCTAssertEqual(result.modelName, global.modelName, "Model should remain global")
    }

    // MARK: - 3. MaxTokens and Temperature

    func testOverrideMaxTokens_usesOverrideValue() {
        let global = makeGlobalConfig(maxTokens: 4096)
        let override = LLMOverride(maxTokens: 32768)

        let result = LLMExecutionService.buildEffectiveConfig(
            globalConfig: global,
            roleOverride: override
        )

        XCTAssertEqual(result.maxTokens, 32768, "MaxTokens should come from override")
    }

    func testOverrideTemperature_usesOverrideValue() {
        let global = makeGlobalConfig(temperature: 0.7)
        let override = LLMOverride(temperature: 0.2)

        let result = LLMExecutionService.buildEffectiveConfig(
            globalConfig: global,
            roleOverride: override
        )

        XCTAssertEqual(result.temperature, 0.2,
                       "Temperature should come from override")
    }

    func testTemperaturePreservedFromGlobal_whenOnlyModelOverridden() {
        let global = makeGlobalConfig(temperature: 0.3)
        let override = LLMOverride(modelName: "fast-model")

        let result = LLMExecutionService.buildEffectiveConfig(
            globalConfig: global,
            roleOverride: override
        )

        XCTAssertEqual(result.temperature, 0.3,
                       "Temperature should fall back to global when not overridden")
    }
}
