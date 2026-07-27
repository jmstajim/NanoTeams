import XCTest

@testable import NanoTeams

/// Pure decisions for the planning phase. The @MainActor wiring is pinned by
/// `ApplyPlanningPhaseWiringTests`.
final class PlanningPhasePolicyTests: XCTestCase {

    private func msg(_ role: MessageRole, _ content: String) -> ChatMessage {
        ChatMessage(role: role, content: content)
    }

    private func brief() -> ChatMessage {
        msg(.user, PlanningPhasePolicy.planningBrief(
            exploreToolNames: [ToolNames.search], expectedArtifacts: []))
    }

    private func tool(_ name: String) -> ToolSchema {
        ToolSchema(name: name, description: "", parameters: .object(properties: [:]))
    }

    // MARK: - Eligibility

    /// Each gate alone must be able to block, and all-true must enter.
    func testIsEligible_everyGateBlocksIndependently() {
        func eligible(
            scratchpadIsNil: Bool = true, revisionCommentIsNil: Bool = true,
            supervisorAnswerIsNil: Bool = true, usesPlanningPhase: Bool = true,
            hasScratchpadTool: Bool = true, isAutovisor: Bool = false
        ) -> Bool {
            PlanningPhasePolicy.isEligible(
                scratchpadIsNil: scratchpadIsNil,
                revisionCommentIsNil: revisionCommentIsNil,
                supervisorAnswerIsNil: supervisorAnswerIsNil,
                usesPlanningPhase: usesPlanningPhase,
                hasScratchpadTool: hasScratchpadTool,
                isAutovisor: isAutovisor)
        }

        XCTAssertTrue(eligible())
        XCTAssertFalse(eligible(scratchpadIsNil: false), "a recorded plan ends the phase")
        XCTAssertFalse(eligible(revisionCommentIsNil: false), "a revision re-enters, not starts")
        XCTAssertFalse(eligible(supervisorAnswerIsNil: false), "an answered question re-enters")
        XCTAssertFalse(eligible(usesPlanningPhase: false), "the role opted out")
        XCTAssertFalse(eligible(hasScratchpadTool: false), "no exit channel ⇒ no phase")
        XCTAssertFalse(eligible(isAutovisor: true), "the manager is gated structurally")
    }

    // MARK: - The decision table

    func testDecide_truthTable() {
        typealias D = PlanningPhasePolicy.Decision
        // (isEligible, wireCarriesBrief, scratchpadIsNil) → decision.
        let rows: [(Bool, Bool, Bool, D)] = [
            (true,  false, true,  .enterPlanning),
            (true,  true,  true,  .continuePlanning),
            (false, true,  false, .crossBoundary),
            (false, true,  true,  .closeWithoutRebuild),
            (false, false, true,  .execution),
            (false, false, false, .execution),
        ]
        for (eligible, hasBrief, scratchpadNil, expected) in rows {
            XCTAssertEqual(
                PlanningPhasePolicy.decide(
                    isEligible: eligible,
                    wireCarriesBrief: hasBrief,
                    scratchpadIsNil: scratchpadNil),
                expected,
                "(\(eligible), \(hasBrief), \(scratchpadNil))")
        }
    }

    /// `isEligible ⟹ scratchpadIsNil`, so an eligible step can never be asked to
    /// cross the boundary — documented here because the table above cannot show
    /// a row that is unreachable by construction.
    func testDecide_eligibleNeverCrossesTheBoundary() {
        for hasBrief in [true, false] {
            let decision = PlanningPhasePolicy.decide(
                isEligible: true, wireCarriesBrief: hasBrief, scratchpadIsNil: true)
            XCTAssertNotEqual(decision, .crossBoundary)
        }
    }

    // MARK: - Wire inspection

    func testBriefIndex_findsTheUserTurnOnly() {
        // A system message quoting the marker must not be mistaken for the brief.
        let wire = [msg(.system, "context: \(PlanningPhasePolicy.briefMarker) is a thing"),
                    msg(.user, "go"), brief()]
        XCTAssertEqual(PlanningPhasePolicy.briefIndex(in: wire), 2)
    }

    func testBriefIndex_nilWhenAbsent() {
        XCTAssertNil(PlanningPhasePolicy.briefIndex(in: [msg(.system, "s"), msg(.user, "u")]))
        XCTAssertNil(PlanningPhasePolicy.briefIndex(in: []))
    }

    /// A wire that somehow carries two briefs cuts at the FIRST, so the array can
    /// only ever shrink — never grow into an oscillation.
    func testBriefIndex_returnsTheFirstOccurrence() {
        let wire = [msg(.system, "s"), brief(), msg(.assistant, "…"), brief()]
        XCTAssertEqual(PlanningPhasePolicy.briefIndex(in: wire), 1)
    }

    // MARK: - implementationWire

    /// Byte-exact prefix: this is what makes the boundary cheap instead of a
    /// cold prefill. Element equality covers `imageContent` and `toolCalls` too.
    func testImplementationWire_prefixIsByteIdentical() {
        let head = [msg(.system, "s"), msg(.user, "task")]
        let wire = head + [brief(), msg(.assistant, "read"), msg(.tool, "{}")]

        let rebuilt = PlanningPhasePolicy.implementationWire(from: wire, seedTurn: "seed")
        XCTAssertEqual(Array(rebuilt.dropLast()), head)
        XCTAssertEqual(rebuilt.count, head.count + 1)
        XCTAssertEqual(rebuilt.last?.role, .user)
        XCTAssertEqual(rebuilt.last?.content, "seed")
    }

    func testImplementationWire_withoutBrief_returnsInputUnchanged() {
        let wire = [msg(.system, "s"), msg(.user, "u")]
        XCTAssertEqual(PlanningPhasePolicy.implementationWire(from: wire, seedTurn: "seed"), wire)
    }

    func testImplementationWire_briefFirst_leavesOnlyTheSeed() {
        let wire = [brief(), msg(.assistant, "…")]
        let rebuilt = PlanningPhasePolicy.implementationWire(from: wire, seedTurn: "seed")
        XCTAssertEqual(rebuilt.count, 1)
        XCTAssertEqual(rebuilt.first?.content, "seed")
    }

    // MARK: - Authorization

    /// Intersected with the tools PASSED IN, which arrive already filtered by
    /// work-folder preconditions. Without that, a git-less folder would be told
    /// to call `git_log`, and `withheldByPhase` would blame the phase for a
    /// precondition.
    func testPlanningToolNames_intersectsWithTheGivenTools() {
        let tools = [tool(ToolNames.updateScratchpad), tool(ToolNames.readFile),
                     tool(ToolNames.writeFile)]
        XCTAssertEqual(PlanningPhasePolicy.planningToolNames(in: tools),
                       [ToolNames.updateScratchpad, ToolNames.readFile])
        XCTAssertFalse(PlanningPhasePolicy.planningToolNames(in: tools).contains(ToolNames.gitLog),
                       "a tool the role does not have must never be offered")
    }

    func testPlanningToolNames_includesGitReadAndVision() {
        let tools = [tool(ToolNames.gitDiff), tool(ToolNames.analyzeImage),
                     tool(ToolNames.gitCommit), tool(ToolNames.bash)]
        let names = PlanningPhasePolicy.planningToolNames(in: tools)
        XCTAssertEqual(names, [ToolNames.gitDiff, ToolNames.analyzeImage])
        XCTAssertFalse(names.contains(ToolNames.bash),
                       "bash can mutate, and its approval gate can park the step")
    }

    func testAuthorization_partitionsTheToolsetDuringPlanning() {
        let tools = [tool(ToolNames.updateScratchpad), tool(ToolNames.search),
                     tool(ToolNames.writeFile)]
        let auth = PlanningPhasePolicy.authorization(for: .continuePlanning, tools: tools)

        XCTAssertEqual(auth.allowed, [ToolNames.updateScratchpad, ToolNames.search])
        XCTAssertEqual(auth.withheldByPhase, [ToolNames.writeFile])
        XCTAssertEqual(auth.allowed.union(auth.withheldByPhase), Set(tools.map(\.name)),
                       "the partition must be total — a tool in neither set is invisible")
    }

    func testAuthorization_isUnrestrictedOutsidePlanning() {
        let tools = [tool(ToolNames.updateScratchpad), tool(ToolNames.writeFile)]
        for decision in [PlanningPhasePolicy.Decision.crossBoundary,
                         .closeWithoutRebuild, .execution] {
            let auth = PlanningPhasePolicy.authorization(for: decision, tools: tools)
            XCTAssertEqual(auth.allowed, Set(tools.map(\.name)), "\(decision)")
            XCTAssertTrue(auth.withheldByPhase.isEmpty, "\(decision)")
        }
    }

    // MARK: - Prompt text

    /// CLAUDE.md §Prompt-audit: the instruction must name the channel the code
    /// actually detects. The boundary keys on `step.scratchpad`, which only a
    /// successful `update_scratchpad` (or the prose fallback) writes.
    func testPlanningBrief_namesTheChannelTheCodeDetects() {
        let brief = PlanningPhasePolicy.planningBrief(
            exploreToolNames: [ToolNames.readFile], expectedArtifacts: [])
        XCTAssertTrue(brief.contains(ToolNames.updateScratchpad))
        XCTAssertTrue(brief.hasPrefix(PlanningPhasePolicy.briefMarker))
    }

    /// With the system prompt untouched it still advertises the FULL catalog, so
    /// the brief is the only place that says what actually runs.
    func testPlanningBrief_listsTheExploreToolsSortedAndWithoutTheExitChannel() {
        let brief = PlanningPhasePolicy.planningBrief(
            exploreToolNames: [ToolNames.search, ToolNames.gitLog, ToolNames.updateScratchpad],
            expectedArtifacts: [])
        guard let line = brief.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("These tools run right now:") })
        else { return XCTFail("no tool line in:\n\(brief)") }

        XCTAssertTrue(line.contains(ToolNames.gitLog))
        XCTAssertTrue(line.contains(ToolNames.search))
        XCTAssertFalse(line.contains(ToolNames.updateScratchpad),
                       "the exit channel is described separately, not listed as exploration")
        XCTAssertLessThan(line.range(of: ToolNames.gitLog)!.lowerBound,
                          line.range(of: ToolNames.search)!.lowerBound,
                          "sorted — the prefix cache keys on exact bytes")
    }

    func testPlanningBrief_omitsToolLine_whenOnlyTheScratchpadIsAvailable() {
        let brief = PlanningPhasePolicy.planningBrief(
            exploreToolNames: [ToolNames.updateScratchpad], expectedArtifacts: [])
        XCTAssertFalse(brief.contains("These tools run right now"))
    }

    func testPlanningBrief_deliverableLine_followsExpectedArtifacts() {
        XCTAssertTrue(
            PlanningPhasePolicy.planningBrief(exploreToolNames: [], expectedArtifacts: ["Notes"])
                .contains("\"Notes\""))
        XCTAssertFalse(
            PlanningPhasePolicy.planningBrief(exploreToolNames: [], expectedArtifacts: [])
                .contains("must end with producing"))
    }

    /// The notes are the ONLY thing that survives the boundary — `PromptBuilder`
    /// never injects `step.scratchpad`.
    func testImplementationSeedTurn_carriesTheNotesVerbatim() {
        let seed = PlanningPhasePolicy.implementationSeedTurn(
            notes: "  Findings: Foo.swift\nPlan:\n1. Edit Foo  ", expectedArtifacts: ["Notes"])
        XCTAssertTrue(seed.hasPrefix(PlanningPhasePolicy.seedMarker))
        XCTAssertTrue(seed.contains("Findings: Foo.swift"))
        XCTAssertTrue(seed.contains("1. Edit Foo"))
        XCTAssertTrue(seed.contains("\"Notes\""))
    }

    func testImplementationSeedTurn_omitsSubmitLine_forNonProducingRoles() {
        let seed = PlanningPhasePolicy.implementationSeedTurn(notes: "plan", expectedArtifacts: [])
        XCTAssertFalse(seed.contains(ToolNames.createArtifact))
    }

    /// The markers are the phase's only identity. A brief that stops matching
    /// `wireCarriesBrief` would strand the step in the planning phase forever.
    func testMarkersRoundTripThroughTheirOwnBuilders() {
        XCTAssertTrue(PlanningPhasePolicy.wireCarriesBrief([brief()]))
        let seed = msg(.user, PlanningPhasePolicy.implementationSeedTurn(
            notes: "n", expectedArtifacts: []))
        XCTAssertFalse(PlanningPhasePolicy.wireCarriesBrief([seed]),
                       "the seed must NOT read as a brief, or the boundary would re-fire")
    }

    func testScratchpadAck_announcesTheTransitionOnlyDuringPlanning() {
        XCTAssertTrue(PlanningPhasePolicy.scratchpadAck(isPlanningWire: true)
            .contains("implementation phase"))
        XCTAssertFalse(PlanningPhasePolicy.scratchpadAck(isPlanningWire: false)
            .contains("implementation phase"),
                       "a role with no phase must not be told about a transition that never happened")
    }
}
