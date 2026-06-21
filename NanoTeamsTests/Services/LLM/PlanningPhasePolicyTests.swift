import XCTest

@testable import NanoTeams

/// Corner / boundary coverage for the pure planning-phase policy extracted from
/// `LLMExecutionService+StepFlowControl.applyPlanningPhase`. Pure value-in/value-out,
/// so every decision is exercised directly — no delegate, task, or session.
final class PlanningPhasePolicyTests: XCTestCase {

    private func tool(_ name: String) -> ToolSchema {
        ToolSchema(name: name, description: "", parameters: JSONSchema(type: "object"))
    }

    // MARK: - isFirstIteration

    func testIsFirstIteration_allConditions() {
        XCTAssertTrue(PlanningPhasePolicy.isFirstIteration(
            scratchpadIsNil: true, hasNoRecentCalls: true, revisionCommentIsNil: true))
        XCTAssertFalse(PlanningPhasePolicy.isFirstIteration(
            scratchpadIsNil: false, hasNoRecentCalls: true, revisionCommentIsNil: true),
            "a recorded plan ⇒ not first iteration")
        XCTAssertFalse(PlanningPhasePolicy.isFirstIteration(
            scratchpadIsNil: true, hasNoRecentCalls: false, revisionCommentIsNil: true),
            "a prior tool call ⇒ not first iteration")
        XCTAssertFalse(PlanningPhasePolicy.isFirstIteration(
            scratchpadIsNil: true, hasNoRecentCalls: true, revisionCommentIsNil: false),
            "a revision in flight ⇒ never first iteration")
    }

    // MARK: - shouldEnterPlanning truth table

    func testShouldEnterPlanning_allTrue_enters() {
        XCTAssertTrue(PlanningPhasePolicy.shouldEnterPlanning(
            isFirstIteration: true, usePlanningPhase: true, hasScratchpadTool: true))
    }

    func testShouldEnterPlanning_eachGateFalse_blocks() {
        XCTAssertFalse(PlanningPhasePolicy.shouldEnterPlanning(
            isFirstIteration: false, usePlanningPhase: true, hasScratchpadTool: true),
            "not first iteration")
        XCTAssertFalse(PlanningPhasePolicy.shouldEnterPlanning(
            isFirstIteration: true, usePlanningPhase: false, hasScratchpadTool: true),
            "role opted out of planning")
        XCTAssertFalse(PlanningPhasePolicy.shouldEnterPlanning(
            isFirstIteration: true, usePlanningPhase: true, hasScratchpadTool: false),
            "no update_scratchpad in the tool set")
    }

    // MARK: - hasScratchpadTool / planningTools

    func testHasScratchpadTool_presenceMatrix() {
        XCTAssertFalse(PlanningPhasePolicy.hasScratchpadTool(in: []))
        XCTAssertFalse(PlanningPhasePolicy.hasScratchpadTool(in: [tool("read_file"), tool("write_file")]))
        XCTAssertTrue(PlanningPhasePolicy.hasScratchpadTool(in: [tool("read_file"), tool(ToolNames.updateScratchpad)]))
    }

    func testPlanningTools_filtersToScratchpadOnly() {
        let mixed = [tool("read_file"), tool(ToolNames.updateScratchpad), tool("write_file")]
        XCTAssertEqual(PlanningPhasePolicy.planningTools(from: mixed).map(\.name), [ToolNames.updateScratchpad])
    }

    func testPlanningTools_emptyInput_returnsEmpty() {
        XCTAssertTrue(PlanningPhasePolicy.planningTools(from: []).isEmpty)
    }

    func testPlanningTools_noScratchpad_returnsEmpty() {
        XCTAssertTrue(PlanningPhasePolicy.planningTools(from: [tool("read_file")]).isEmpty)
    }

    // MARK: - basePlanningPrompt

    func testBasePlanningPrompt_carriesRoleNameMarkerAndScratchpad() {
        let prompt = PlanningPhasePolicy.basePlanningPrompt(roleName: "Tech Lead")
        XCTAssertTrue(prompt.contains("Tech Lead"))
        XCTAssertTrue(prompt.contains(PlanningPhasePolicy.planningPhaseMarker))
        XCTAssertTrue(prompt.contains("update_scratchpad"))
    }

    func testBasePlanningPrompt_omitsInlineToolCallExample() {
        let prompt = PlanningPhasePolicy.basePlanningPrompt(roleName: "X")
        XCTAssertFalse(prompt.contains("<|call|>"), "no Harmony example (buildToolSchemaSection adds the only one)")
        XCTAssertFalse(prompt.contains("## Tool Calling"))
    }

    // MARK: - isPlanningSystemPrompt (marker SSOT)

    func testIsPlanningSystemPrompt_markerDetection() {
        XCTAssertFalse(PlanningPhasePolicy.isPlanningSystemPrompt(nil))
        XCTAssertFalse(PlanningPhasePolicy.isPlanningSystemPrompt(""))
        XCTAssertFalse(PlanningPhasePolicy.isPlanningSystemPrompt("You are a normal role."))
        XCTAssertTrue(PlanningPhasePolicy.isPlanningSystemPrompt("...\n## PLANNING PHASE\n..."))
    }

    /// Round-trip: the base prompt the policy emits must be recognized as a planning
    /// prompt by the policy's own detector — pins the two against drift.
    func testIsPlanningSystemPrompt_recognizesItsOwnBasePrompt() {
        XCTAssertTrue(PlanningPhasePolicy.isPlanningSystemPrompt(
            PlanningPhasePolicy.basePlanningPrompt(roleName: "Anyone")))
    }

    // MARK: - shouldRestorePlanningPrompt

    func testShouldRestorePlanningPrompt_requiresBothConditions() {
        XCTAssertTrue(PlanningPhasePolicy.shouldRestorePlanningPrompt(
            hasSavedPrompt: true, systemContainsPlanningPhase: true))
        XCTAssertFalse(PlanningPhasePolicy.shouldRestorePlanningPrompt(
            hasSavedPrompt: false, systemContainsPlanningPhase: true), "nothing stashed to restore")
        XCTAssertFalse(PlanningPhasePolicy.shouldRestorePlanningPrompt(
            hasSavedPrompt: true, systemContainsPlanningPhase: false), "live prompt already swapped back")
        XCTAssertFalse(PlanningPhasePolicy.shouldRestorePlanningPrompt(
            hasSavedPrompt: false, systemContainsPlanningPhase: false))
    }
}
