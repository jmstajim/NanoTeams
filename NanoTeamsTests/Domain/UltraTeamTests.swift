import XCTest
@testable import NanoTeams

/// User-path: the Ultra Team is a general CHANGE pipeline whose argument happens before the
/// code and whose check after it is factual, on WHATEVER stack the work folder holds. Seven
/// waves, two internally parallel — planner, brief critic, two architects, spec + regression
/// critics, engineer, diff reviewer, verifier.
///
/// Four properties carry the design and are pinned here because each fails SILENTLY:
///
/// - **One writer.** `workFolderRoot` is one tree shared by every role, so two roles holding
///   file-mutating tools would overwrite each other's work. This is why the divergence lives at
///   the design level and not at the implementation level, and a second writer would undo that
///   decision without breaking anything visible until two branches raced. Since 2026-09-12 the
///   TOOLSET no longer enforces it — every role holds `bash` — so the pin covers the file
///   writers and says so, and the invariant rests on the approval gate and nine prompts.
/// - **Every role measures.** All nine hold `analyze_image`, both Xcode runners and `bash`.
///   Four reading reviewers found zero defects in 16 min 05 s in MeditationApp task 48 run 1;
///   four build and test calls found everything in 13.8 s. The runners vanish with the Xcode
///   scheme, which is why the shell is in the floor beside them.
/// - **One asker.** Only the planner holds `ask_supervisor`, so the pipeline ASKS the human
///   exactly once. The engine cannot restore it elsewhere: `shouldAutoInjectAskSupervisor`
///   requires an EMPTY `producesArtifacts`, and every role here produces one.
/// - **Isolated branches.** No role holds `ask_teammate` or `request_team_meeting`. A branch that
///   can read a sibling's reasoning mid-flight is no longer independent, and independence is the
///   only reason running the pair in parallel beats running one role twice.
@MainActor
final class UltraTeamTests: XCTestCase {

    private func makeTeam() -> Team { TeamTemplateFactory.ultraTeam() }

    private func role(_ systemRoleID: String, in team: Team) throws -> TeamRoleDefinition {
        try XCTUnwrap(team.roles.first { $0.systemRoleID == systemRoleID },
                      "Ultra Team has no role '\(systemRoleID)'")
    }

    /// Wave number of every role: 1 for a role whose only input is the Supervisor Task,
    /// otherwise one past the LATEST of its suppliers. This is what the engine's readiness
    /// rule produces, computed here so the tests below can talk about "before" and
    /// "in parallel with" as facts about the graph rather than about intentions.
    private func waves(in team: Team) -> [String: Int] {
        let producers = Dictionary(
            team.nonSupervisorRoles.flatMap { role in
                role.dependencies.producesArtifacts.map { ($0, role.systemRoleID ?? role.id) }
            }, uniquingKeysWith: { first, _ in first })
        var waveOf: [String: Int] = [:]
        func wave(_ key: String, _ seen: Set<String> = []) -> Int {
            if let known = waveOf[key] { return known }
            guard !seen.contains(key),
                  let role = team.nonSupervisorRoles.first(where: { ($0.systemRoleID ?? $0.id) == key })
            else { return 0 }
            let upstream = role.dependencies.requiredArtifacts.compactMap { producers[$0] }
            let value = 1 + (upstream.map { wave($0, seen.union([key])) }.max() ?? 0)
            waveOf[key] = value
            return value
        }
        for role in team.nonSupervisorRoles { _ = wave(role.systemRoleID ?? role.id) }
        return waveOf
    }

    // MARK: - Registration (this one runs FIRST)

    /// `buildTeam` assembles the roster with `roleIDs.compactMap { SystemTemplates.roles[id] }`
    /// and then reads the chair by direct index, `roles[coordinatorIndex].id`. One id missing
    /// from `SystemTemplates.roles` therefore does not fail loudly — it SILENTLY shortens the
    /// array, and the index read goes out of bounds inside `Team.defaultTeams`, which runs
    /// during the bootstrap of every fresh work folder. That is a crash on launch.
    ///
    /// A missing ARTIFACT name is quieter and worse: `artifactNames.compactMap` drops it, the
    /// roles keep requiring an artifact the team does not define, and the run dies with
    /// "Execution stalled: roles […] blocked. Check artifact dependencies in Team Editor" —
    /// the app blaming the user for our omission.
    func testUltraTeamRosterAndArtifactsMatchTheirDeclaredIDs() throws {
        let team = makeTeam()
        let declaredRoleIDs = try XCTUnwrap(SystemTemplates.teamRoleIDs["ultra"])
        XCTAssertEqual(team.roles.count, declaredRoleIDs.count + 1,
                       "every declared id must resolve to a template, plus the Supervisor")
        XCTAssertEqual(team.nonSupervisorRoles.compactMap(\.systemRoleID), declaredRoleIDs,
                       "order matters: the chair is read by INDEX")

        let defined = Set(team.artifacts.map(\.name))
        for role in team.roles {
            for name in role.dependencies.requiredArtifacts + role.dependencies.producesArtifacts {
                XCTAssertTrue(defined.contains(name),
                              "\(role.name) depends on '\(name)', which the team does not define")
            }
        }
    }

    // MARK: - Identity

    func testUltraTeam_isABundledTemplate_andIsInThePicker() {
        XCTAssertTrue(Team.defaultTeams.map(\.templateID).contains("ultra"))
        XCTAssertTrue(TeamTemplateFactory.templateMetadata.map(\.id).contains("ultra"))
    }

    func testUltraTeam_isNotChatMode_andRequiresBothFinalArtifacts() {
        let team = makeTeam()
        XCTAssertFalse(team.isChatMode)
        XCTAssertEqual(Set(team.supervisorRequiredArtifacts),
                       ["Implementation Notes", "Diff Review", "Verification Report"],
                       "The human confirms the actual result NEXT TO the diff and the evidence it was built.")
    }

    func testUltraTeam_settings_manualAndFinalOnly() {
        let settings = makeTeam().settings
        XCTAssertEqual(settings.supervisorMode, .manual,
                       "Autonomous would answer the planner's questions with an LLM.")
        XCTAssertEqual(settings.defaultAcceptanceMode, .finalOnly,
                       "One confirmation, at the end — no intermediate acceptance cards.")
        XCTAssertTrue(settings.acceptanceCheckpoints.isEmpty)
    }

    // MARK: - Pipeline shape

    func testPipeline_fansOutToBothArchitects_fromTheBriefAlone() throws {
        let team = makeTeam()
        // The planner is excluded the way the engine excludes it — a role that has already run is
        // not a candidate. `findReadyRoles` itself only checks dependency satisfaction, so without
        // the exclusion the planner (whose input is still present) reads as ready forever.
        let planner = try role("changePlanner", in: team)
        let briefCritic = try role("briefCritic", in: team)
        let ready = ArtifactDependencyResolver.findReadyRoles(
            roles: team.nonSupervisorRoles,
            producedArtifacts: [SystemTemplates.supervisorTaskArtifactName,
                                "Change Brief", "Brief Critique"],
            excludeRoleIDs: [planner.id, briefCritic.id])
        let readyIDs = Set(try ready.map { id in
            try XCTUnwrap(team.roles.first { $0.id == id }?.systemRoleID)
        })
        XCTAssertEqual(readyIDs, ["solutionArchitect", "pragmaticArchitect"],
                       "The brief and its critique must release BOTH architects and nothing else.")
    }

    func testPipeline_nothingIsReadyBeforeTheBrief_exceptThePlanner() throws {
        let team = makeTeam()
        let ready = ArtifactDependencyResolver.findReadyRoles(
            roles: team.nonSupervisorRoles,
            producedArtifacts: [SystemTemplates.supervisorTaskArtifactName])
        let readyIDs = Set(try ready.map { id in
            try XCTUnwrap(team.roles.first { $0.id == id }?.systemRoleID)
        })
        XCTAssertEqual(readyIDs, ["changePlanner"],
                       "The pipeline opens with the interrogation, not with design.")
    }

    func testPipeline_criticsFanInOnBothApproaches() throws {
        for id in ["specCritic", "regressionCritic"] {
            let required = Set(try role(id, in: makeTeam()).dependencies.requiredArtifacts)
            XCTAssertTrue(required.isSuperset(of: ["Approach A", "Approach B"]),
                          "\(id) judges both approaches or it is not a comparison.")
        }
    }

    func testSpecCritic_receivesTheBriefItJudgesBy_andTheRegressionCriticDoesNot() throws {
        let team = makeTeam()
        XCTAssertEqual(Set(try role("specCritic", in: team).dependencies.requiredArtifacts),
                       ["Change Brief", "Approach A", "Approach B"],
                       """
                       The critique is a table over the acceptance criteria, and the criteria \
                       exist in one document. Reaching it by path makes that table depend on a \
                       read the model may skip.
                       """)
        XCTAssertFalse(
            Set(try role("regressionCritic", in: team).dependencies.requiredArtifacts)
                .contains("Change Brief"),
            "Damage to existing behaviour is judged against the repository, not against the brief.")
    }

    func testEngineer_requiresTheCritiquesAndTheBrief_butNotTheApproaches() throws {
        let required = Set(try role("changeEngineer", in: makeTeam()).dependencies.requiredArtifacts)
        XCTAssertEqual(required, ["Change Brief", "Spec Critique", "Regression Critique"])
        XCTAssertFalse(required.contains("Approach A"))
        XCTAssertFalse(required.contains("Approach B"),
                       """
                       The approaches reach the engineer as PATHS, read on demand. Requiring them \
                       would inline two more whole bodies into the one request that already carries \
                       four — the required-artifacts turn is uncapped.
                       """)
    }

    func testVerifier_closesThePipeline_onTheNotesAndTheBrief() throws {
        let verifier = try role("changeVerifier", in: makeTeam())
        XCTAssertEqual(Set(verifier.dependencies.requiredArtifacts),
                       ["Change Brief", "Implementation Notes", "Diff Review"],
                       """
                       The run succeeds on three counts — it builds, the tests pass, the \
                       requirement is met — and the third is settled nowhere else: the spec \
                       critic judged DESIGNS against the criteria, before any code existed.
                       """)
        XCTAssertEqual(verifier.dependencies.producesArtifacts, ["Verification Report"])
    }

    /// The edge above and the contract that spends it are pinned together: an edge whose
    /// artifact no contract names is bytes on the wire, and a contract naming an input the
    /// role never receives is the defect this pair replaced.
    func testTheCriteriaContractTravelsWithTheEdgeThatDeliversThem() throws {
        let prompt = try XCTUnwrap(SystemTemplates.rolePrompts["changeVerifier"])
        XCTAssertTrue(prompt.contains("acceptance criteria"),
                      "The verifier receives the brief, so its contract must spend it.")
        let report = try XCTUnwrap(SystemTemplates.artifacts["Verification Report"])
        XCTAssertTrue(report.description.contains("acceptance criterion"),
                      "The report the Supervisor reads is where the verdict per criterion lands.")
    }

    func testEveryRoleProduces_soNoRoleIsAdvisoryOrObserver() {
        for role in makeTeam().nonSupervisorRoles {
            XCTAssertEqual(role.completionType, .producing,
                           "\(role.name) must be producing: the pipeline advances on artifacts.")
        }
    }

    // MARK: - One writer

    /// Read over `ToolHandlerRegistry.repositoryMutatingTools` — every file writer, every
    /// mutating Git tool and the shell — rather than over a hand-written list of three, because
    /// such a list stayed green for a role gaining `git_stash`. Stated as a PARTITION of that
    /// set, because since 2026-09-12 the shell is held by every role on purpose: the engineer
    /// holds the file writers on top of it, everyone else holds nothing on top of it, and
    /// nobody at all holds a mutating Git tool.
    ///
    /// **This pin covers less than its name once promised, and that is the honest reading.**
    /// `bash` can write any file the sandbox allows, so the toolset stopped being what keeps a
    /// single writer on the tree; what keeps it now is the approval gate plus nine prompts, and
    /// a prompt has no power to compel (playbook R3.1.5). Recorded in `KNOWN_ISSUES` rather
    /// than left for a reader to discover from a green test.
    func testOnlyTheEngineerHoldsTheFileWriters() {
        let mutating = ToolHandlerRegistry.repositoryMutatingTools
        XCTAssertTrue(mutating.isSuperset(of: [ToolNames.writeFile, ToolNames.editFile, ToolNames.deleteFile,
                                               ToolNames.gitStash, ToolNames.gitCommit, ToolNames.bash]),
                      "premise: the registry's set covers files, git and the shell")
        let writers: Set<String> = [ToolNames.writeFile, ToolNames.editFile, ToolNames.deleteFile]
        let shell = ToolHandlerRegistry.shellTools
        for role in makeTeam().nonSupervisorRoles {
            let held = Set(role.toolIDs).intersection(mutating)
            XCTAssertTrue(held.isDisjoint(with: ToolHandlerRegistry.gitWriteTools),
                          "\(role.name) can mutate the index or the branch")
            if role.systemRoleID == "changeEngineer" {
                XCTAssertEqual(held.subtracting(shell), writers,
                               "The engineer is the one role that writes FILES.")
            } else {
                XCTAssertTrue(held.subtracting(shell).isEmpty,
                              """
                              \(role.name) holds \(held.sorted()). The work folder is ONE tree shared \
                              by every role, so a second file writer can overwrite the engineer's work.
                              """)
            }
        }
    }

    /// The shell is in the floor deliberately, and the reason is that the Xcode runners are
    /// CONDITIONAL: step 3.1 of `resolveToolSchemasCore` removes both the moment no scheme is
    /// selected — every SwiftPM package, every folder not yet pointed at one, every repository
    /// that is not Swift at all. Without `bash` those nine roles would hold no build channel
    /// there while their contracts still told them to build, which is an unfulfillable
    /// directive rather than disobedience (playbook E7.7.6).
    ///
    /// It is not free, and holding the tool is not the same as holding the channel. Under
    /// `BashExecutionMode.manual` — the fresh install's default — every command waits for a human,
    /// and with no human `ApprovalGatedAvailability.forBash` withholds `bash` + `bash_output`
    /// outright. Under `.semiAutomatic` the tool ships but only `BashConstants.readOnlyPrograms`
    /// runs unattended, and no build program is in that set, so an unattended build is refused as
    /// `APPROVAL_UNAVAILABLE`. Only `.auto` restores a real build channel. `KNOWN_ISSUES`.
    func testEveryRoleHoldsTheShell() {
        for role in makeTeam().nonSupervisorRoles {
            XCTAssertTrue(role.toolIDs.contains(ToolNames.bash),
                          "\(role.name) has no build channel in a folder with no Xcode scheme")
            XCTAssertTrue(role.toolIDs.contains(ToolNames.bashOutput),
                          "\(role.name) could start a background command it cannot read back")
        }
    }

    func testVerifierHoldsTheRunners_andNoWriters() throws {
        let verifier = try role("changeVerifier", in: makeTeam())
        XCTAssertTrue(verifier.toolIDs.contains(ToolNames.runXcodebuild))
        XCTAssertTrue(verifier.toolIDs.contains(ToolNames.runXcodetests))
        XCTAssertFalse(verifier.toolIDs.contains(ToolNames.writeFile),
                       "A verifier that can fix what it finds is verifying itself.")
    }

    // MARK: - One asker

    func testOnlyThePlannerHoldsAskSupervisor() {
        for role in makeTeam().nonSupervisorRoles {
            let holds = !Set(role.toolIDs).isDisjoint(with: ToolNames.supervisorAskTools)
            XCTAssertEqual(holds, role.systemRoleID == "changePlanner",
                           "\(role.name): exactly one role interrupts the human, and it is the planner.")
        }
    }

    /// The planner holds BOTH parking tools, and its prompt teaches the one it should reach for.
    ///
    /// The questionnaire is what the single interruption is for: the pipeline stops the human
    /// once, and what it needs back is several decisions, each with the answers the planner
    /// already considers likely. `ask_supervisor` stays beside it for the follow-up on a
    /// contradiction — and because every escalation text names that tool and only that tool
    /// (`LoopRecoveryPolicy.escalationChannel`, `SystemTemplates.stepEnding`).
    ///
    /// RED: drop `askSupervisorForm` from the planner's `toolIDs` → the first assertion fails;
    /// rewrite the prompt back to a numbered list in one `ask_supervisor` call → the second.
    func testPlannerHoldsTheQuestionnaireAndItsPromptNamesIt() {
        guard let planner = makeTeam().nonSupervisorRoles.first(where: { $0.systemRoleID == "changePlanner" })
        else { return XCTFail("the Ultra team must carry the planner") }

        XCTAssertTrue(Set(planner.toolIDs).isSuperset(of: ToolNames.supervisorAskTools),
                      "the one asker holds both shapes of asking")
        XCTAssertTrue(planner.prompt.contains(ToolNames.askSupervisorForm),
                      "a tool the role holds and the prompt never names is a tool it will not use")
    }

    func testNoRoleCanHaveAskSupervisorAutoInjectedBack() {
        for role in makeTeam().nonSupervisorRoles {
            XCTAssertFalse(role.shouldAutoInjectAskSupervisor,
                           """
                           \(role.name) would receive `ask_supervisor` from the resolver regardless of \
                           its toolIDs. Auto-injection needs an EMPTY producesArtifacts — keep every \
                           Ultra role producing, or the one-asker rule stops holding.
                           """)
        }
    }

    // MARK: - Isolated branches, no delegation

    func testNoRoleHoldsACrossBranchChannel() {
        let channels: Set<String> = [ToolNames.askTeammate, ToolNames.requestTeamMeeting]
        for role in makeTeam().nonSupervisorRoles {
            XCTAssertTrue(Set(role.toolIDs).isDisjoint(with: channels),
                          "\(role.name) could read a sibling branch mid-flight, which ends its independence.")
        }
    }

    func testNoRoleIsConfiguredForDelegation() {
        for role in makeTeam().nonSupervisorRoles {
            XCTAssertFalse(role.hasDelegationConfigured, "\(role.name)")
            XCTAssertFalse(role.toolIDs.contains(ToolNames.delegateToTeam), "\(role.name)")
        }
    }

    func testEveryRoleReportsToTheSupervisor() throws {
        let team = makeTeam()
        let supervisorID = try XCTUnwrap(team.roles.first(where: \.isSupervisor)?.id)
        for role in team.nonSupervisorRoles {
            XCTAssertEqual(team.settings.hierarchy.reportsTo[role.id], supervisorID, "\(role.name)")
        }
    }

    // MARK: - The lenses, and the order they must run in

    /// A lens earns its place only when a DIFFERENT source of truth settles it; otherwise it
    /// is a second opinion, and one role already holds that job (R3.1.1). Before code exists
    /// there are three: the brief, the brief-as-requirement, and the code. There were four —
    /// the compiler was the fourth, and it retired with the team's Swift binding on
    /// 2026-09-12 (`testTheRetiredFeasibilityCriticIsActuallyRetired`).
    func testBriefCriticGatesBothArchitects() throws {
        let team = makeTeam()
        for id in ["solutionArchitect", "pragmaticArchitect"] {
            XCTAssertTrue(
                try role(id, in: team).dependencies.requiredArtifacts.contains("Brief Critique"),
                "\(id) must read the critique of the brief — that is how the correction travels "
                    + "FORWARD instead of back through a vote")
        }
    }

    /// **The retirement that must not be half-done.** The Feasibility Critic compiled a
    /// throwaway `FeasibilityProbe.swift` between the designs and the critiques — the only lens
    /// that returned a FACT — and every part of that contract was a fact about Xcode, so it went
    /// with the rest of the Swift binding on 2026-09-12.
    ///
    /// Removing it from `SystemTemplates.roles` without listing its id in
    /// `retiredSystemRoleIDs` fails SILENTLY and in the worst direction: reconciliation is
    /// otherwise strictly additive, so every work folder created before the bump keeps a LIVE
    /// Feasibility Critic holding `write_file` + `delete_file` on the tree the engineer writes —
    /// a second writer, the exact failure the ONE WRITER rule exists for — while every pin in
    /// this file, which reads the FRESH template, stays green.
    func testTheRetiredFeasibilityCriticIsActuallyRetired() {
        XCTAssertNil(SystemTemplates.roles["feasibilityCritic"],
                     "the role left the bundle")
        XCTAssertTrue(SystemTemplates.retiredSystemRoleIDs.contains("feasibilityCritic"),
                      "…so reconciliation must DELETE it from a stored team, not append beside it")
        XCTAssertNil(SystemTemplates.artifacts["Feasibility Report"],
                     "the artifact it produced left with it")
        XCTAssertNil(SystemTemplates.rolePrompts["feasibilityCritic"])
        for role in makeTeam().nonSupervisorRoles {
            XCTAssertFalse(role.dependencies.requiredArtifacts.contains("Feasibility Report"),
                           "\(role.name) would wait forever on an artifact nobody produces")
        }
    }

    /// Sequential, not parallel, and forced rather than chosen: a `request_changes` from the
    /// Diff Reviewer convenes the CONSUMERS of the engineer's artifact, and
    /// `MeetingParticipantResolver.filterParticipants` never filters by execution status — a
    /// parallel verifier would be pulled into that vote in the middle of its own build.
    func testVerifierFollowsTheDiffReviewer_notParallel() throws {
        let team = makeTeam()
        let w = waves(in: team)
        XCTAssertGreaterThan(try XCTUnwrap(w["changeVerifier"]), try XCTUnwrap(w["diffReviewer"]))
        XCTAssertTrue(
            try role("changeVerifier", in: team).dependencies.requiredArtifacts.contains("Diff Review"))
    }

    /// Both architects hold the runners, so a MEASURED baseline (the tree before the change,
    /// paired with the tool call) is legitimate evidence — the rule forbids inventing results
    /// for code that does not exist, not measuring what does.
    func testSpecCriticDoesNotPenaliseAMeasuredBaseline() throws {
        let prompt = try XCTUnwrap(SystemTemplates.rolePrompts["specCritic"])
        XCTAssertFalse(prompt.contains("An approach that reports one is making it up"), prompt)
        XCTAssertTrue(prompt.contains("for code that does not exist"), prompt)
        XCTAssertTrue(prompt.contains("paired with the tool call that produced it"), prompt)
        XCTAssertTrue(prompt.contains("ranks ABOVE"), "the honest-Unverified rule stays")
    }

    /// A prompt carries what the model can act on. The incident that motivated a rule belongs
    /// in the Swift comment beside it, not on every user's wire as part of the fingerprint.
    func testNoUltraPromptNamesAnIncident() {
        for role in makeTeam().nonSupervisorRoles {
            let prompt = SystemTemplates.rolePrompts[role.systemRoleID ?? ""] ?? ""
            XCTAssertFalse(prompt.contains("MeditationApp"), "\(role.name)'s prompt narrates an incident")
            XCTAssertFalse(prompt.contains("task 48"), "\(role.name)'s prompt narrates an incident")
        }
    }

    /// The New Team picker's card and the team's own description must describe the same team.
    func testPickerCardDescribesAChangePipeline() throws {
        let card = try XCTUnwrap(TeamTemplateFactory.templateMetadata.first { $0.id == "ultra" })
        XCTAssertTrue(card.description.hasPrefix("Change pipeline"), card.description)
        XCTAssertFalse(card.description.contains("Feature"), card.description)
        XCTAssertTrue(makeTeam().description.contains("Change pipeline"))
    }

    /// The artifact description rides the wire beside the prompt (`PromptBuilder+TeamContext`),
    /// so the two contracts for the same item must agree: the engineer reports what it RAN
    /// and what came back, not a list for somebody else to run; the verifier quotes.
    func testArtifactDescriptionsAgreeWithThePromptsTheyAccompany() throws {
        let notes = try XCTUnwrap(SystemTemplates.artifacts["Implementation Notes"])
        XCTAssertTrue(notes.description.contains("the exact commands run and what each returned"), notes.description)
        XCTAssertFalse(notes.description.contains("another role must run"), notes.description)
        let report = try XCTUnwrap(SystemTemplates.artifacts["Verification Report"])
        XCTAssertTrue(report.description.contains("quoted from its source"), report.description)
    }

    // MARK: - Every role measures

    /// The wave's central trade. Four reading reviewers produced zero findings and one
    /// harmful artifact in 16 min 05 s; four build and test calls settled everything in
    /// 13.8 s. `analyze_image` costs nothing where no vision model is configured — the
    /// resolver strips it from the schema.
    func testEveryRoleHoldsVisionAndTheRunners() {
        for role in makeTeam().nonSupervisorRoles {
            for tool in [ToolNames.analyzeImage, ToolNames.runXcodebuild, ToolNames.runXcodetests,
                         ToolNames.bash] {
                XCTAssertTrue(role.toolIDs.contains(tool),
                              "\(role.name) is missing \(tool): a role asked about the state of the "
                                  + "build must be able to establish it instead of inferring it")
            }
        }
    }

    /// **The rule the whole 1.9.21 wave exists to hold, made mechanical.** Ultra Team is the
    /// general CHANGE pipeline: it runs on whatever the work folder holds, so nothing it ships on
    /// the wire may assume one stack. Prose cannot be trusted to stay neutral — this wave itself
    /// shipped two misses past a hand grep ("You hold the build and test runners", "a compile
    /// error is barely a finding"), both caught only by a second sweep.
    ///
    /// The population is the nine role prompts, their meeting guidance, and every artifact
    /// description the team carries — the artifact description rides the wire beside the prompt
    /// (`PromptBuilder+TeamContext`), so a neutral prompt next to an Xcode-flavoured description
    /// is not neutral.
    ///
    /// Two shapes are deliberately NOT in the needle list. `build` and `test` are the actions
    /// themselves and every stack has them; `git` is a tool the role holds unconditionally.
    /// What is banned is naming ONE ecosystem's compiler, IDE, platform or file type — including
    /// other stacks', so this does not become a Swift-shaped rule wearing a general name.
    func testNoUltraPromptNamesAStack() throws {
        let banned = ["swift", "xcode", "macos", "ios", "cocoa", "appkit", "swiftui",
                      "compiler", "compile", "runner", "deriveddata", "simulator", "scheme",
                      "gradle", "maven", "npm", "yarn", "cargo", "pytest", "webpack", "tsconfig",
                      ".swift", ".py", ".ts", ".go", ".rs"]
        var surfaces: [(String, String)] = []
        for role in makeTeam().nonSupervisorRoles {
            let id = try XCTUnwrap(role.systemRoleID)
            surfaces.append(("prompt[\(id)]", try XCTUnwrap(SystemTemplates.rolePrompts[id])))
            if let meeting = SystemTemplates.roleMeetingGuidance[id] {
                surfaces.append(("meetingGuidance[\(id)]", meeting))
            }
            for name in role.dependencies.requiredArtifacts + role.dependencies.producesArtifacts {
                guard let artifact = SystemTemplates.artifacts[name] else { continue }
                surfaces.append(("artifact[\(name)]", artifact.description))
            }
        }
        XCTAssertGreaterThanOrEqual(surfaces.count, 25, """
        anti-vacuum: \(surfaces.count) surfaces resolved for nine roles. Zero read surfaces is \
        indistinguishable from a clean sweep, which is how this pin would rot silently.
        """)

        for (label, body) in surfaces {
            let haystack = body.lowercased()
            for needle in banned {
                XCTAssertFalse(haystack.contains(needle), """
                \(label) names `\(needle)`. Ultra Team runs on whatever the work folder holds, so \
                nothing it puts on the wire may assume one stack — and a directive naming a tool \
                the resolver may have stripped is an unfulfillable directive, not disobedience \
                (playbook E7.7.6 / R5.2.4). Say the ACTION ("build the project", "run its tests"); \
                the toolset names the channel.
                """)
            }
        }
    }

    /// After the runners shipped to everyone, a prompt still promising read-only tools is
    /// false against the schema — the text/schema conflict `ToolUnavailabilityReason` exists
    /// to prevent one layer down (R1.8.5).
    func testNoUltraPromptStillClaimsReadOnlyTools() throws {
        for role in makeTeam().nonSupervisorRoles {
            let id = try XCTUnwrap(role.systemRoleID)
            let prompt = try XCTUnwrap(SystemTemplates.rolePrompts[id])
            XCTAssertFalse(prompt.lowercased().contains("read-only"),
                           "\(role.name) holds both runners; its prompt must not say otherwise")
        }
    }

    // MARK: - The return edge

    func testExactlyTheTwoCheckersHoldRequestChanges() {
        let expected: Set<String> = ["diffReviewer", "changeVerifier"]
        for role in makeTeam().nonSupervisorRoles {
            let holds = role.toolIDs.contains(ToolNames.requestChanges)
            XCTAssertEqual(holds, expected.contains(role.systemRoleID ?? ""),
                           "\(role.name): the return edge belongs to the roles that measure")
        }
    }

    /// The criterion the Brief Critic FAILED, and the reason it holds no return edge.
    ///
    /// A vote convenes the consumers of the TARGET's artifact, and
    /// `MeetingParticipantResolver` never filters by execution status. So a holder may only
    /// exist where every consumer of every legal target is already finished — otherwise the
    /// vote drags a working role out of its own step. A `request_changes` on the planner
    /// would have summoned five idle roles to vote on a brief none of them had read.
    ///
    /// Computed over the graph, not over the intended wave list: a dependency edit that
    /// silently creates the overlap fails here.
    func testNoRequestChangesHolderCanConveneAWorkingRole() throws {
        let team = makeTeam()
        let w = waves(in: team)
        let holders = team.nonSupervisorRoles.filter { $0.toolIDs.contains(ToolNames.requestChanges) }
        XCTAssertFalse(holders.isEmpty, "anti-vacuum: the team has a return edge at all")

        for holder in holders {
            let holderWave = try XCTUnwrap(w[holder.systemRoleID ?? ""])
            let needs = Set(holder.dependencies.requiredArtifacts)
            // Legal targets: direct suppliers only — the rule `validateChangeRequest` enforces.
            let targets = team.nonSupervisorRoles.filter {
                !Set($0.dependencies.producesArtifacts).isDisjoint(with: needs)
            }
            XCTAssertFalse(targets.isEmpty, "\(holder.name) has nobody it may legally ask")
            for target in targets {
                let supplies = Set(target.dependencies.producesArtifacts)
                let consumers = team.nonSupervisorRoles.filter {
                    $0.id != target.id && $0.id != holder.id
                        && !Set($0.dependencies.requiredArtifacts).isDisjoint(with: supplies)
                }
                for consumer in consumers {
                    XCTAssertNotEqual(
                        try XCTUnwrap(w[consumer.systemRoleID ?? ""]), holderWave,
                        "\(holder.name) → \(target.name) would convene \(consumer.name), which runs "
                            + "in the same wave — the vote would interrupt its step")
                }
            }
        }
    }

    /// The chair sits in EVERY meeting by construction, so a `request_changes` holder in that
    /// seat would judge its neighbours' cases as a matter of routine. `effectiveCoordinator`
    /// closes the requester/target case in the runtime for every team; this is Ultra's own
    /// second layer, and it is the one that also keeps the chair off the repair path.
    func testCoordinatorHoldsNoRequestChanges() throws {
        let team = makeTeam()
        let chairID = try XCTUnwrap(team.meetingCoordinatorID)
        let chair = try XCTUnwrap(team.roles.first { $0.id == chairID })
        XCTAssertEqual(chair.systemRoleID, "changePlanner")
        XCTAssertFalse(chair.toolIDs.contains(ToolNames.requestChanges))
        // The chair IS reachable as a target — the Change Verifier requires the brief, so the
        // planner is one of its direct suppliers, and a criterion that turned out to be
        // unsettleable is genuinely the brief's defect. That edge is deliberate and bounded:
        // it exists only in the LAST wave, when every consumer of the brief is already
        // `.done`, so no working role is dragged into the vote. Its price is a full
        // re-run and a second interruption of the human — which is the right trade when the
        // alternative is closing a run against a brief the team has proved wrong.
        //
        // What must NOT exist is such an edge from a holder that runs while a consumer of the
        // brief is still in flight; `testNoRequestChangesHolderCanConveneAWorkingRole` is the
        // pin for that, computed over the graph.
        let chairTargeters = team.nonSupervisorRoles.filter {
            $0.toolIDs.contains(ToolNames.requestChanges)
                && $0.dependencies.requiredArtifacts.contains(where: chair.dependencies.producesArtifacts.contains)
        }
        XCTAssertEqual(chairTargeters.compactMap(\.systemRoleID), ["changeVerifier"],
                       "only the last wave may send the brief back")
    }

    /// `.default` gives 3 change requests, 3 meetings and 2 amendments per step — one firing
    /// per checker, with no right to a second, so a build still red after the first repair met
    /// "Change request limit reached" and the run ended red with its repair channel spent. The
    /// guarantee this team exists for would have failed on a constant.
    ///
    /// Derived from the roster, so it moves WITH it: two `request_changes` holders × two rounds
    /// (found → repaired → rechecked → found again), and both target the engineer.
    func testUltraCarriesItsOwnRepairBudget() {
        let team = makeTeam()
        let limits = team.settings.limits
        let checkers = team.nonSupervisorRoles.filter { $0.toolIDs.contains(ToolNames.requestChanges) }
        XCTAssertEqual(limits.maxChangeRequestsPerRun, checkers.count * 2,
                       "every checker must be able to fire twice")
        XCTAssertEqual(limits.maxChangeRequestsPerRun, 4, "two checkers × two rounds")
        XCTAssertEqual(limits.maxAmendmentsPerStep, 4, "the engineer is the target of both of them")
        XCTAssertGreaterThan(limits.maxChangeRequestsPerRun, TeamLimits.default.maxChangeRequestsPerRun)
    }

    /// `maxChangeRequestsPerRun` and `maxMeetingsPerRun` are ONE budget wearing two names:
    /// every vote persists into `run.meetings` and is counted by `hasReachedMeetingLimit`.
    /// They may match only while no Ultra role can start an ordinary meeting — the moment one
    /// can, a discussion silently eats a repair, and the last checker is told "Meeting limit
    /// reached" about a tool it does not hold.
    func testUltraMeetingBudgetIsReservedForChangeRequestVotes() {
        let team = makeTeam()
        for role in team.nonSupervisorRoles {
            XCTAssertFalse(role.toolIDs.contains(ToolNames.requestTeamMeeting), role.name)
        }
        XCTAssertEqual(team.settings.limits.maxMeetingsPerRun,
                       team.settings.limits.maxChangeRequestsPerRun,
                       "the budgets coincide on purpose; the pin is what keeps the coincidence honest")
    }

    // MARK: - Planning phase

    func testOnlyTheEngineerRunsThePlanningPhase() {
        for role in makeTeam().nonSupervisorRoles {
            XCTAssertEqual(role.usePlanningPhase, role.systemRoleID == "changeEngineer",
                           """
                           \(role.name): the phase separates exploring the repo from writing to it, \
                           so it belongs to the one role that writes.
                           """)
        }
    }
}
