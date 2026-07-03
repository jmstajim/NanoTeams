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

    /// The swap replaces the base prompt's `## Deliverables` — the planning brief
    /// must restate the artifact names the plan targets, or the plan is made blind.
    func testBasePlanningPrompt_interpolatesExpectedArtifacts() {
        let prompt = PlanningPhasePolicy.basePlanningPrompt(
            roleName: "PM", expectedArtifacts: ["Product Requirements", "Research Report"])
        XCTAssertTrue(prompt.contains("\"Product Requirements\""))
        XCTAssertTrue(prompt.contains("\"Research Report\""))
    }

    func testBasePlanningPrompt_noArtifacts_omitsDeliverableLine() {
        let prompt = PlanningPhasePolicy.basePlanningPrompt(roleName: "PM")
        XCTAssertFalse(prompt.contains("must end with producing"))
    }

    /// Section shape: `## Role` header (not bare "You are X."), and the
    /// load-bearing only-tool instruction lives in the tail `## Final reminder`
    /// so `insertingGlobalGuidance` places user context ABOVE it.
    func testBasePlanningPrompt_sectionShape_roleHeaderAndTailReminder() {
        let prompt = PlanningPhasePolicy.basePlanningPrompt(roleName: "Tech Lead")
        XCTAssertTrue(prompt.hasPrefix("## Role\n"), "persona rendered as `## Role`, matching the house sectioning")
        XCTAssertFalse(prompt.contains("You are "))
        guard let fr = prompt.range(of: "## Final reminder") else {
            return XCTFail("planning prompt must end with a Final reminder section")
        }
        XCTAssertTrue(prompt[fr.upperBound...].contains("only tool available"),
                      "the critical only-tool constraint must occupy the tail slot")
    }

    /// Global guidance inserted via `TemplateResolver.insertingGlobalGuidance`
    /// lands BEFORE the planning `## Final reminder`, not after it.
    func testBasePlanningPrompt_globalGuidanceInsertsBeforeFinalReminder() {
        let combined = TemplateResolver.insertingGlobalGuidance(
            "Always answer in Russian.",
            into: PlanningPhasePolicy.basePlanningPrompt(roleName: "X")
        )
        guard let guidance = combined.range(of: "## Global guidance"),
              let fr = combined.range(of: "## Final reminder") else {
            return XCTFail("both sections must be present")
        }
        XCTAssertLessThan(guidance.lowerBound, fr.lowerBound,
                          "user context must not displace the tail reminder")
        XCTAssertTrue(combined.contains("Always answer in Russian."))
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
