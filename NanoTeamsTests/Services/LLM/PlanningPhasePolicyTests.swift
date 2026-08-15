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
        XCTAssertEqual(PlanningPhasePolicy.planningToolNames(in: tools, bashAdmitted: true),
                       [ToolNames.updateScratchpad, ToolNames.readFile])
        XCTAssertFalse(
            PlanningPhasePolicy.planningToolNames(in: tools, bashAdmitted: true)
                .contains(ToolNames.gitLog),
            "a tool the role does not have must never be offered")
    }

    /// The membership rule is the CRITERION, not a hand-kept list: a tool belongs iff it can
    /// neither put an unrecoverable turn on the wire nor mutate work-folder source. The Xcode
    /// runners satisfy both structurally — `ToolHandler.handle` is synchronous by signature,
    /// they emit no `ToolSignal`, and `build_diagnostics.json` is written at step COMPLETION,
    /// not in the tool loop. `git_commit` fails the second outright and no mechanism rescues it.
    ///
    /// `bash` satisfies the first structurally and the second only while the sandbox enforces
    /// it, which is what `bashAdmitted` carries — see the admission test below.
    ///
    /// RED: drop the `if bashAdmitted { insert }` → `bash` vanishes from the admitted set and the
    /// first assertion fails; make the insert unconditional → it appears in the withheld case and
    /// the second fails.
    func testPlanningToolNames_includesGitReadVisionXcodeAndBash() {
        let tools = [tool(ToolNames.gitDiff), tool(ToolNames.analyzeImage),
                     tool(ToolNames.runXcodebuild), tool(ToolNames.runXcodetests),
                     tool(ToolNames.gitCommit), tool(ToolNames.bash)]
        XCTAssertEqual(PlanningPhasePolicy.planningToolNames(in: tools, bashAdmitted: true),
                       [ToolNames.gitDiff, ToolNames.analyzeImage, ToolNames.runXcodebuild,
                        ToolNames.runXcodetests, ToolNames.bash])
        XCTAssertEqual(PlanningPhasePolicy.planningToolNames(in: tools, bashAdmitted: false),
                       [ToolNames.gitDiff, ToolNames.analyzeImage, ToolNames.runXcodebuild,
                        ToolNames.runXcodetests],
                       "with no enforcement available, bash must not be offered")
        XCTAssertFalse(
            PlanningPhasePolicy.planningToolNames(in: tools, bashAdmitted: true)
                .contains(ToolNames.gitCommit),
            "git-write mutates the repo — the discarded exploration transcript "
                + "would become load-bearing")
    }

    /// `bash_output` is never admitted, on either setting: its only producer is `bash` with
    /// `run_in_background`, which the handler refuses during the phase, so the ids it could
    /// address belong to other steps — and its `stop` action is an irreversible side effect
    /// whose only record dies at the boundary.
    ///
    /// RED: `planningTools.insert(ToolNames.bashOutput)` beside the bash insert → both rows fail.
    func testPlanningToolNames_neverAdmitsBashOutput() {
        let tools = [tool(ToolNames.bash), tool(ToolNames.bashOutput)]
        for admitted in [true, false] {
            XCTAssertFalse(
                PlanningPhasePolicy.planningToolNames(in: tools, bashAdmitted: admitted)
                    .contains(ToolNames.bashOutput),
                "bashAdmitted: \(admitted)")
        }
    }

    /// When the caller's admission test fails, `bash` must land in `withheldByPhase` — not
    /// merely be absent. That is what produces `plan_required` rather than the catch-all
    /// "not available for this role", and it is TRUE: after the boundary the same command runs
    /// under the user's own settings.
    ///
    /// RED: make the insert unconditional → `bash` moves to `allowed` and both assertions fail.
    func testAuthorization_bashNotAdmitted_isWithheldByThePhaseNotSilentlyAbsent() {
        let tools = [tool(ToolNames.updateScratchpad), tool(ToolNames.readFile),
                     tool(ToolNames.bash)]
        let auth = PlanningPhasePolicy.authorization(
            for: .continuePlanning, tools: tools, bashAdmitted: false)

        XCTAssertFalse(auth.allowed.contains(ToolNames.bash))
        XCTAssertTrue(auth.withheldByPhase.contains(ToolNames.bash))
    }

    /// `isPlanningPhase` is carried, never inferred. A role whose entire toolset already sits
    /// inside the planning set withholds NOTHING, so `!withheldByPhase.isEmpty` would read
    /// "not planning" and hand exactly that role an unnarrowed bash for the whole phase.
    ///
    /// RED: derive the flag as `!withheldByPhase.isEmpty` → `isPlanningPhase` reads false here,
    /// while the partition and unrestricted tests below stay green (which is exactly what makes
    /// the inference look safe).
    func testAuthorization_isPlanningPhase_isTrueEvenWhenNothingIsWithheld() {
        let tools = [tool(ToolNames.updateScratchpad), tool(ToolNames.readFile),
                     tool(ToolNames.gitLog), tool(ToolNames.bash)]
        let auth = PlanningPhasePolicy.authorization(
            for: .continuePlanning, tools: tools, bashAdmitted: true)

        XCTAssertTrue(auth.withheldByPhase.isEmpty, "fixture premise: this role withholds nothing")
        XCTAssertTrue(auth.isPlanningPhase)
    }

    /// Without a selected scheme, step 3.1 of `resolveToolSchemasCore` has already
    /// stripped the runners, so the intersection leaves them in NEITHER set. That
    /// is what keeps `classifyUnavailability` answering `.xcodeSchemeNotSelected`
    /// (a structural "stop") instead of `plan_required` (a temporal "retry"), and
    /// it keeps the brief from advertising a tool that cannot run.
    func testPlanningToolNames_withoutAScheme_xcodeIsNeitherAllowedNorWithheld() {
        let toolsWithoutScheme = [tool(ToolNames.updateScratchpad), tool(ToolNames.readFile)]
        let auth = PlanningPhasePolicy.authorization(
            for: .continuePlanning, tools: toolsWithoutScheme, bashAdmitted: true)

        XCTAssertFalse(auth.allowed.contains(ToolNames.runXcodebuild))
        XCTAssertFalse(auth.withheldByPhase.contains(ToolNames.runXcodebuild),
                       "the phase must never claim to withhold a tool a precondition removed")
    }

    func testAuthorization_partitionsTheToolsetDuringPlanning() {
        let tools = [tool(ToolNames.updateScratchpad), tool(ToolNames.search),
                     tool(ToolNames.writeFile)]
        let auth = PlanningPhasePolicy.authorization(
            for: .continuePlanning, tools: tools, bashAdmitted: true)

        XCTAssertEqual(auth.allowed, [ToolNames.updateScratchpad, ToolNames.search])
        XCTAssertEqual(auth.withheldByPhase, [ToolNames.writeFile])
        XCTAssertEqual(auth.allowed.union(auth.withheldByPhase), Set(tools.map(\.name)),
                       "the partition must be total — a tool in neither set is invisible")
    }

    func testAuthorization_isUnrestrictedOutsidePlanning() {
        let tools = [tool(ToolNames.updateScratchpad), tool(ToolNames.writeFile)]
        for decision in [PlanningPhasePolicy.Decision.crossBoundary,
                         .closeWithoutRebuild, .execution] {
            let auth = PlanningPhasePolicy.authorization(
                for: decision, tools: tools, bashAdmitted: true)
            XCTAssertEqual(auth.allowed, Set(tools.map(\.name)), "\(decision)")
            XCTAssertTrue(auth.withheldByPhase.isEmpty, "\(decision)")
            XCTAssertFalse(auth.isPlanningPhase, "\(decision)")
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

    /// Advertising `bash` without saying it cannot write would be advertise-then-reject for
    /// every write command. The annotation is what makes the admission honest.
    ///
    /// RED: delete the `if explore.contains(bash)` block → the brief carries no annotation and
    /// both assertions fail.
    func testPlanningBrief_annotatesBashAsReadOnly() {
        let brief = PlanningPhasePolicy.planningBrief(
            exploreToolNames: [ToolNames.bash, ToolNames.search], expectedArtifacts: [])
        XCTAssertTrue(brief.contains("read-only"))
        XCTAssertTrue(brief.contains("until your plan is recorded"))
    }

    /// A role without `bash` must get the brief it got before the annotation existed — byte for
    /// byte. Pins that the annotation is keyed on MEMBERSHIP and that the derived, sorted tool
    /// line is untouched.
    ///
    /// RED: emit the annotation unconditionally → the bash-less brief gains a "read-only" line.
    func testPlanningBrief_withoutBash_carriesNoAnnotationAndAnUnchangedToolLine() {
        let brief = PlanningPhasePolicy.planningBrief(
            exploreToolNames: [ToolNames.search, ToolNames.gitLog], expectedArtifacts: [])
        XCTAssertFalse(brief.contains("read-only"))
        XCTAssertTrue(brief.contains("These tools run right now: git_log, search.\n"))
    }

    /// The annotation lives on its OWN line: the tool line reads to a small model as a set of
    /// NAMES, and a parenthetical inside it is the shape those models copy into their arguments.
    ///
    /// RED: decorate the entry in-list (e.g. `"bash (read-only)"`) → sorting survives, but the
    /// list line carries a parenthesis and the name-only assertion fails.
    func testPlanningBrief_bashKeepsItsSortedPlaceAndTheListStaysNameOnly() {
        let brief = PlanningPhasePolicy.planningBrief(
            exploreToolNames: [ToolNames.search, ToolNames.bash, ToolNames.gitLog],
            expectedArtifacts: [])
        guard let line = brief.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("These tools run right now:") })
        else { return XCTFail("no tool line in:\n\(brief)") }

        XCTAssertFalse(line.contains("("), "the list must carry names only")
        XCTAssertLessThan(line.range(of: ToolNames.bash)!.lowerBound,
                          line.range(of: ToolNames.gitLog)!.lowerBound,
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

    /// The seed turn is the LAST instruction the role gets before it starts working,
    /// and — since the scratchpad acknowledgement left the wire — nothing speaks
    /// again after each `update_scratchpad`. So its direction has to survive being
    /// re-read after every completed step.
    ///
    /// "Execute step 1 of your plan" was true exactly once: from the second write
    /// onward the newest instruction on the wire pointed at work already done, and
    /// the gap was papered over by a per-write "Continue with the next step." turn
    /// appended to every role in the app. Identifying the next step by a PREDICATE
    /// the model can re-evaluate is what makes that turn unnecessary.
    ///
    /// The fixture keeps `notes` free of ordinals so the assertion scans the
    /// template, not the plan a role happened to write.
    ///
    /// RED: revert to "Execute step 1 of your plan, then call update_scratchpad …"
    /// → this fails.
    func testImplementationSeedTurn_identifiesTheNextStepByPredicate_notByOrdinal() {
        let seed = PlanningPhasePolicy.implementationSeedTurn(
            notes: "x", expectedArtifacts: [])
        XCTAssertFalse(seed.lowercased().contains("step 1"),
                       "an ordinal is true exactly once; after the first write it names finished work")
        XCTAssertTrue(seed.contains("struck through"),
                      "the next step must be identified by state the model can re-check; got: \(seed)")
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

    // The scratchpad acknowledgement moved to `ScratchpadNotePolicy` — the phase
    // is one of three writers, and the wording is display-only for all of them.
    // Its tests live in `ScratchpadNotePolicyTests`.
}
