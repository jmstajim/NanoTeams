import XCTest
@testable import NanoTeams

/// `{stepEnding}` — the one sentence of `## Final reminder` that names how the step ends,
/// resolved per role at prompt-build time.
///
/// A template serving both completion types used to carry a literal ("Submit each
/// deliverable exactly once") that an advisory role could not act on, or an `if`-clause
/// the model re-judged on every turn. Three sentences, one chip: a producing role ends on
/// `create_artifact`; an advisory role on its `ask_supervisor` reply; an advisory role in a
/// team whose Ask Supervisor mode is Off has no tool to end on and is told so.
@MainActor
final class StepEndingChipTests: XCTestCase {

    private var faang: Team!
    private var questParty: Team!

    override func setUp() async throws {
        try await super.setUp()
        faang = Team.defaultTeams.first { $0.templateID == "faang" }
        questParty = Team.defaultTeams.first { $0.templateID == "questParty" }
    }

    override func tearDown() async throws {
        faang = nil
        questParty = nil
        try await super.tearDown()
    }

    // MARK: - The matrix

    func testStepEnding_matrix() {
        XCTAssertEqual(SystemTemplates.stepEnding(producing: true, canAskSupervisor: true), SystemTemplates.producingStepEnding)
        XCTAssertEqual(SystemTemplates.stepEnding(producing: true, canAskSupervisor: false), SystemTemplates.producingStepEnding,
                       "a producing role ends on create_artifact whatever else it holds")
        XCTAssertEqual(SystemTemplates.stepEnding(producing: false, canAskSupervisor: true), SystemTemplates.advisoryStepEnding)
        XCTAssertEqual(SystemTemplates.stepEnding(producing: false, canAskSupervisor: false), SystemTemplates.plainReplyStepEnding)
    }

    func testThreeSentences_areDistinct_andOnlyTheAdvisoryOneNamesATool() {
        let all = [SystemTemplates.producingStepEnding, SystemTemplates.advisoryStepEnding, SystemTemplates.plainReplyStepEnding]
        XCTAssertEqual(Set(all).count, 3)
        XCTAssertFalse(SystemTemplates.producingStepEnding.contains("create_artifact"),
                       "the tool is named by the closing user turn and the schema, not the reminder")
        XCTAssertTrue(SystemTemplates.advisoryStepEnding.contains("`ask_supervisor`"))
        XCTAssertFalse(SystemTemplates.plainReplyStepEnding.contains("ask_supervisor"),
                       "Off: the role has no ask_supervisor to be told about")
    }

    // MARK: - Rendered through the runtime builder

    private func context(role: TeamRoleDefinition, team: Team, expectedArtifacts: [String]) -> PromptBuilder.Context {
        let step = StepExecution(id: role.id, role: Role.fromDefinition(role), title: role.name,
                                 expectedArtifacts: expectedArtifacts)
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "Do it", runs: [run])
        return PromptBuilder.Context(
            task: task, step: step, stepIndex: 0, run: run, workFolder: nil,
            artifactReader: { _ in nil }, activeTeam: team, roleDefinition: role)
    }

    private func systemPrompt(_ context: PromptBuilder.Context, tools: [ToolSchema]) -> String {
        PromptBuilder.buildChatMessages(context: context, tools: tools).first?.content ?? ""
    }

    private var askSupervisorSchema: ToolSchema {
        ToolHandlerRegistry.allSchemas.first { $0.name == ToolNames.askSupervisor }!
    }

    func testProducingRole_rendersTheProducingSentence() throws {
        let engineer = try XCTUnwrap(faang.roles.first { $0.systemRoleID == "softwareEngineer" })
        let prompt = systemPrompt(context(role: engineer, team: faang, expectedArtifacts: engineer.dependencies.producesArtifacts),
                                  tools: [askSupervisorSchema])
        XCTAssertTrue(prompt.contains(SystemTemplates.producingStepEnding))
        XCTAssertFalse(prompt.contains(SystemTemplates.advisoryStepEnding))
        XCTAssertFalse(prompt.contains("{stepEnding}"), "the chip resolved")
    }

    func testAdvisoryRoleHoldingAskSupervisor_rendersTheAdvisorySentence() throws {
        let questMaster = try XCTUnwrap(questParty.roles.first { $0.systemRoleID == "questMaster" })
        XCTAssertTrue(questMaster.isAdvisory, "fixture: the Quest Master is the advisory role of a producing template")
        let prompt = systemPrompt(context(role: questMaster, team: questParty, expectedArtifacts: []), tools: [askSupervisorSchema])
        XCTAssertTrue(prompt.contains(SystemTemplates.advisoryStepEnding))
        XCTAssertFalse(prompt.contains(SystemTemplates.producingStepEnding),
                       "the Quest Party template used to tell the Quest Master to submit deliverables it has none of")
    }

    /// The Quest Master's own guidance is written around the `ask_supervisor` loop (its
    /// `### ask_supervisor format` section) — bundled text the chip does not own. What the
    /// chip owns is the tail: under Off the `## Final reminder` names no tool.
    func testAdvisoryRoleWithoutAskSupervisor_rendersThePlainReplySentence() throws {
        let questMaster = try XCTUnwrap(questParty.roles.first { $0.systemRoleID == "questMaster" })
        let prompt = systemPrompt(context(role: questMaster, team: questParty, expectedArtifacts: []), tools: [])
        let tail = try XCTUnwrap(prompt.range(of: "## Final reminder").map { String(prompt[$0.lowerBound...]) })
        XCTAssertTrue(tail.contains(SystemTemplates.plainReplyStepEnding))
        XCTAssertFalse(tail.contains("ask_supervisor"), "Off: the reminder points at no tool the schema lacks")
        XCTAssertFalse(tail.contains(SystemTemplates.advisoryStepEnding))
    }

    /// No `roleDefinition` (a fixture shape): the step's own expected artifacts decide.
    func testWithoutARoleDefinition_theStepsExpectedArtifactsDecide() throws {
        let engineer = try XCTUnwrap(faang.roles.first { $0.systemRoleID == "softwareEngineer" })
        var ctx = context(role: engineer, team: faang, expectedArtifacts: ["Engineering Notes"])
        ctx = PromptBuilder.Context(
            task: ctx.task, step: ctx.step, stepIndex: 0, run: ctx.run, workFolder: nil,
            artifactReader: { _ in nil }, activeTeam: faang, roleDefinition: nil)
        XCTAssertTrue(systemPrompt(ctx, tools: []).contains(SystemTemplates.producingStepEnding))
    }

    // MARK: - The wire preview follows the team's Ask Supervisor mode

    private func preview(team: Team, roleID: String) throws -> String {
        let role = try XCTUnwrap(team.roles.first { $0.systemRoleID == roleID })
        let inputs = PromptBuilder.WirePreviewInputs(
            role: role, team: team, allTeams: [team], workFolder: nil,
            workFolderState: .defaultStorage, selectedScheme: nil,
            isVisionConfigured: false, approval: ToolApprovalAvailability(bash: .available, computerUse: .withheld(.switchedOff)),
            globalContext: AppDefaults.globalContext, isCoordinator: false,
            agentInstructions: nil)
        return try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)
    }

    func testPreview_advisoryRole_followsTheTeamsSupervisorMode() throws {
        XCTAssertTrue(try preview(team: questParty, roleID: "questMaster").contains(SystemTemplates.advisoryStepEnding))
        var off = questParty!
        off.settings.supervisorMode = .off
        let rendered = try preview(team: off, roleID: "questMaster")
        XCTAssertTrue(rendered.contains(SystemTemplates.plainReplyStepEnding),
                      "Off strips ask_supervisor from the schema, so the reminder must not name it")
        XCTAssertFalse(rendered.contains(SystemTemplates.advisoryStepEnding))
    }

    func testPreview_producingRole_isUnmovedBySupervisorMode() throws {
        var off = faang!
        off.settings.supervisorMode = .off
        XCTAssertTrue(try preview(team: off, roleID: "softwareEngineer").contains(SystemTemplates.producingStepEnding))
    }

    // MARK: - Every step template carries the chip or interpolates a constant

    func testEveryStepTemplate_endsOnAChipOrAConstant_notALiteral() {
        let chipped = [
            ("softwareTemplate", SystemTemplates.softwareTemplate),
            ("questPartyTemplate", SystemTemplates.questPartyTemplate),
            ("discussionTemplate", SystemTemplates.discussionTemplate),
            ("genericTemplate", SystemTemplates.genericTemplate),
        ]
        for (name, t) in chipped {
            XCTAssertTrue(t.contains("{stepEnding}"), "[\(name)] carries the chip")
            XCTAssertFalse(t.contains(SystemTemplates.producingStepEnding), "[\(name)] no literal beside the chip")
            XCTAssertFalse(t.contains("If Deliverables are listed above"), "[\(name)] no if-clause the model re-judges")
        }
        for (name, t) in [("assistantTemplate", SystemTemplates.assistantTemplate),
                          ("codingAssistantTemplate", SystemTemplates.codingAssistantTemplate)] {
            XCTAssertTrue(t.contains(SystemTemplates.advisoryStepEnding),
                          "[\(name)] chat-mode: the advisory constant is interpolated (Off is not offered there)")
            XCTAssertFalse(t.contains("{stepEnding}"))
        }
    }
}
