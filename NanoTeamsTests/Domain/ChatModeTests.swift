import XCTest
@testable import NanoTeams

/// Tests for chat mode behavior across Domain types (Team, NTMSTask, Run, TaskSummary, StatusDisplay).
final class ChatModeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSupervisorRole(requiredArtifacts: [String] = []) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "supervisor",
            name: "Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requiredArtifacts,
                producesArtifacts: ["Supervisor Task"]
            ),
            isSystemRole: true,
            systemRoleID: "supervisor"
        )
    }

    private func makeWorkerRole(
        id: String,
        name: String,
        required: [String] = ["Supervisor Task"],
        produces: [String] = []
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: name,
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: required,
                producesArtifacts: produces
            )
        )
    }

    private func makeTeam(roles: [TeamRoleDefinition]) -> Team {
        Team(name: "Test", roles: roles, artifacts: [], settings: .default, graphLayout: TeamGraphLayout())
    }

    // MARK: - Team.isChatMode

    func testIsChatMode_trueWhenSupervisorHasNoRequiredArtifacts() {
        let team = makeTeam(roles: [
            makeSupervisorRole(requiredArtifacts: []),
            makeWorkerRole(id: "assistant", name: "Assistant"),
        ])
        XCTAssertTrue(team.isChatMode)
    }

    func testIsChatMode_falseWhenSupervisorRequiresArtifacts() {
        let team = makeTeam(roles: [
            makeSupervisorRole(requiredArtifacts: ["Release Notes"]),
            makeWorkerRole(id: "pm", name: "PM", produces: ["Release Notes"]),
        ])
        XCTAssertFalse(team.isChatMode)
    }

    func testIsChatMode_falseForEmptyTeam() {
        let team = makeTeam(roles: [])
        // Empty supervisorRequiredArtifacts but no roles — still isChatMode
        XCTAssertTrue(team.isChatMode)
    }

    func testIsChatMode_consistentWithRequiresSupervisorFinalReview() {
        let chatTeam = makeTeam(roles: [makeSupervisorRole(requiredArtifacts: [])])
        XCTAssertTrue(chatTeam.isChatMode)
        XCTAssertFalse(chatTeam.requiresSupervisorFinalReview)

        let taskTeam = makeTeam(roles: [makeSupervisorRole(requiredArtifacts: ["Output"])])
        XCTAssertFalse(taskTeam.isChatMode)
        XCTAssertTrue(taskTeam.requiresSupervisorFinalReview)
    }

    // MARK: - NTMSTask.derivedStatusFromActiveRun (chat mode)

    func testDerivedStatus_chatMode_doneReturnsRunning() {
        var task = NTMSTask(id: 0, title: "Chat", supervisorTask: "Help me", isChatMode: true)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .custom(id: "assistant"), title: "Chat", status: .done),
            ])
        ]

        // Chat mode: done steps → .running (not .needsSupervisorAcceptance)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatus_chatMode_closedReturnsDone() {
        var task = NTMSTask(id: 0, title: "Chat", supervisorTask: "Help me", isChatMode: true)
        task.closedAt = MonotonicClock.shared.now()
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .custom(id: "assistant"), title: "Chat", status: .done),
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    func testDerivedStatus_nonChatMode_doneReturnsNeedsSupervisorAcceptance() {
        var task = NTMSTask(id: 0, title: "Task", supervisorTask: "Build", isChatMode: false)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done),
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    func testDerivedStatus_chatMode_failedStillReturnsFailed() {
        var task = NTMSTask(id: 0, title: "Chat", supervisorTask: "Help", isChatMode: true)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .custom(id: "assistant"), title: "Chat", status: .failed),
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    func testDerivedStatus_chatMode_pausedStillReturnsPaused() {
        var task = NTMSTask(id: 0, title: "Chat", supervisorTask: "Help", isChatMode: true)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .custom(id: "assistant"), title: "Chat", status: .paused),
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    // MARK: - NTMSTask.isReadyForFinalAcceptance

    func testIsReadyForFinalAcceptance_chatMode_alwaysFalse() {
        var task = NTMSTask(id: 0, title: "Chat", supervisorTask: "Help", isChatMode: true)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .custom(id: "assistant"), title: "Chat", status: .done),
            ], roleStatuses: ["assistant": .done])
        ]

        XCTAssertFalse(task.isReadyForFinalAcceptance)
    }

    func testIsReadyForFinalAcceptance_nonChatMode_trueWhenAllComplete() {
        var task = NTMSTask(id: 0, title: "Task", supervisorTask: "Build", isChatMode: false)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done),
            ], roleStatuses: ["eng": .done])
        ]

        XCTAssertTrue(task.isReadyForFinalAcceptance)
    }

    // MARK: - NTMSTask.toSummary preserves isChatMode

    func testToSummary_preservesIsChatMode() {
        let task = NTMSTask(id: 0, title: "Chat", supervisorTask: "Help", isChatMode: true)
        let summary = task.toSummary()
        XCTAssertTrue(summary.isChatMode)
    }

    func testToSummary_chatMode_statusIsRunning() {
        var task = NTMSTask(id: 0, title: "Chat", supervisorTask: "Help", isChatMode: true)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .custom(id: "assistant"), title: "Chat", status: .done),
            ])
        ]
        let summary = task.toSummary()
        XCTAssertEqual(summary.status, .running, "Chat mode task summary should show .running, not .needsSupervisorAcceptance")
    }

    // MARK: - NTMSTask.isChatMode Codable

    func testIsChatMode_codableRoundTrip() throws {
        let task = NTMSTask(id: 0, title: "Chat", supervisorTask: "Help", isChatMode: true)
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(NTMSTask.self, from: data)
        XCTAssertTrue(decoded.isChatMode)
    }

    func testIsChatMode_decodesDefaultFalse() throws {
        // Simulate legacy JSON without isChatMode field
        let json = """
        {"id":0,"title":"Old","supervisorTask":"Goal","status":"running","createdAt":0,"updatedAt":0,"runs":[],"attachmentPaths":[]}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NTMSTask.self, from: data)
        XCTAssertFalse(decoded.isChatMode, "Legacy tasks without isChatMode should default to false")
    }

    // MARK: - TaskSummary.isChatMode Codable

    func testTaskSummary_codableRoundTrip() throws {
        let summary = TaskSummary(id: 0, title: "Chat", status: .running, isChatMode: true)
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(TaskSummary.self, from: data)
        XCTAssertTrue(decoded.isChatMode)
    }

    func testTaskSummary_decodesDefaultFalse() throws {
        let json = """
        {"id":0,"title":"Old","status":"running","updatedAt":0}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TaskSummary.self, from: data)
        XCTAssertFalse(decoded.isChatMode)
    }

    // MARK: - Run.finishableAdvisoryRoles (chat mode)

    func testFinishableAdvisoryRoles_chatMode_returnsEmpty() {
        let defs = [makeWorkerRole(id: "advisor", name: "Advisor")]
        let run = Run(id: 0, steps: [], roleStatuses: ["advisor": .working])

        let result = run.finishableAdvisoryRoles(definitions: defs, isChatMode: true)
        XCTAssertTrue(result.isEmpty, "Chat mode should suppress finishable advisory roles")
    }

    func testFinishableAdvisoryRoles_nonChatMode_returnsWorkingAdvisory() {
        let defs = [makeWorkerRole(id: "advisor", name: "Advisor")]
        let run = Run(id: 0, steps: [], roleStatuses: ["advisor": .working])

        let result = run.finishableAdvisoryRoles(definitions: defs, isChatMode: false)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].roleID, "advisor")
    }

    // MARK: - TeamRoleDefinition.shouldAutoInjectAskSupervisor

    func testShouldAutoInject_advisoryRole_true() {
        let role = makeWorkerRole(id: "advisor", name: "Advisor", required: ["Goal"], produces: [])
        XCTAssertTrue(role.shouldAutoInjectAskSupervisor)
    }

    func testShouldAutoInject_producingRole_false() {
        let role = makeWorkerRole(id: "pm", name: "PM", required: ["Goal"], produces: ["Requirements"])
        XCTAssertFalse(role.shouldAutoInjectAskSupervisor)
    }

    func testShouldAutoInject_observerRole_false() {
        // Observer: no inputs, no outputs, not supervisor
        let role = TeamRoleDefinition(
            id: "observer",
            name: "Observer",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )
        XCTAssertTrue(role.isObserver)
        XCTAssertFalse(role.shouldAutoInjectAskSupervisor)
    }

    func testShouldAutoInject_supervisorRole_false() {
        let role = makeSupervisorRole()
        XCTAssertFalse(role.shouldAutoInjectAskSupervisor)
    }

    // MARK: - StatusDisplayExtensions (chat mode overrides)

    func testTaskStatus_displayLabel_chatMode() {
        XCTAssertEqual(TaskStatus.running.displayLabel(isChatMode: true), "Chat")
        XCTAssertEqual(TaskStatus.needsSupervisorInput.displayLabel(isChatMode: true), "Chat")
        XCTAssertEqual(TaskStatus.paused.displayLabel(isChatMode: true), "Chat", "Paused chat tasks show Chat")
        XCTAssertEqual(TaskStatus.failed.displayLabel(isChatMode: true), "Failed", "Failed should not change in chat mode")
    }

    func testTaskStatus_displayLabel_nonChatMode() {
        XCTAssertEqual(TaskStatus.running.displayLabel(isChatMode: false), "Working")
        XCTAssertEqual(TaskStatus.needsSupervisorInput.displayLabel(isChatMode: false), "Needs Supervisor")
    }

    func testTaskStatus_systemImageName_chatMode() {
        let chatIcon = "bubble.left.and.bubble.right.fill"
        XCTAssertEqual(TaskStatus.running.systemImageName(isChatMode: true), chatIcon)
        XCTAssertEqual(TaskStatus.needsSupervisorInput.systemImageName(isChatMode: true), chatIcon)
        // Other statuses unchanged
        XCTAssertEqual(TaskStatus.paused.systemImageName(isChatMode: true), chatIcon)
    }

    func testTaskStatus_tintColor_chatMode_isNeutral() {
        let chatColor = TaskStatus.running.tintColor(isChatMode: true)
        // All chat-mode statuses should use neutral/tertiary color (not gold/info/warning)
        XCTAssertNotEqual(chatColor, TaskStatus.running.tintColor, "Chat mode running should differ from normal running color")
        XCTAssertNotEqual(
            TaskStatus.needsSupervisorInput.tintColor(isChatMode: true),
            TaskStatus.needsSupervisorInput.tintColor,
            "Chat mode needsSupervisorInput should differ from normal gold color"
        )
        XCTAssertNotEqual(
            TaskStatus.paused.tintColor(isChatMode: true),
            TaskStatus.paused.tintColor,
            "Chat mode paused should differ from normal warning color"
        )
        // All three should use the same chat color
        XCTAssertEqual(
            TaskStatus.paused.tintColor(isChatMode: true),
            chatColor,
            "Chat mode paused should use same color as chat mode running"
        )
    }

    func testTaskStatus_displayLabel_nonChatMode_pausedUnchanged() {
        XCTAssertEqual(TaskStatus.paused.displayLabel(isChatMode: false), "Paused",
                       "Non-chat paused should still show Paused")
    }

    func testTaskStatus_systemImageName_nonChatMode_pausedUnchanged() {
        XCTAssertEqual(TaskStatus.paused.systemImageName(isChatMode: false), "pause.circle.fill",
                       "Non-chat paused should keep pause icon")
    }

    // MARK: - Fallback Tool IDs

    func testFallbackToolIDs_allNonSupervisorRolesHaveAskSupervisor() {
        let askSupervisor = ToolNames.askSupervisor
        for (stepID, toolIDs) in SystemTemplates.fallbackToolIDs where stepID != "supervisor" {
            XCTAssertTrue(
                toolIDs.contains(askSupervisor),
                "Role '\(stepID)' should have ask_supervisor in fallback toolIDs"
            )
        }
    }

    func testFallbackToolIDs_supervisorDoesNotHaveAskSupervisor() {
        let askSupervisor = ToolNames.askSupervisor
        let supervisorTools = SystemTemplates.fallbackToolIDs["supervisor"] ?? []
        XCTAssertFalse(supervisorTools.contains(askSupervisor))
    }

    func testFallbackCustomRoleToolIDs_includesAskSupervisor() {
        XCTAssertTrue(SystemTemplates.fallbackCustomRoleToolIDs.contains(ToolNames.askSupervisor))
    }

    // MARK: - Built-in templates chat mode

    func testPersonalAssistantTemplate_isChatMode() {
        let templates = TeamTemplateFactory.allTemplates
        let assistant = templates.first { $0.templateID == "assistant" }
        XCTAssertNotNil(assistant, "Personal Assistant template should exist")
        XCTAssertTrue(assistant!.isChatMode, "Personal Assistant should be chat mode")
    }

    func testQuestPartyTemplate_isChatMode() {
        let templates = TeamTemplateFactory.allTemplates
        let quest = templates.first { $0.templateID == "questParty" }
        XCTAssertNotNil(quest)
        XCTAssertTrue(quest!.isChatMode, "Quest Party should be chat mode (no supervisor deliverables)")
    }

    func testFAANGTemplate_isNotChatMode() {
        let templates = TeamTemplateFactory.allTemplates
        let faang = templates.first { $0.templateID == "faang" }
        XCTAssertNotNil(faang)
        XCTAssertFalse(faang!.isChatMode, "FAANG should not be chat mode")
    }

    func testDiscussionClubTemplate_isNotChatMode() {
        let templates = TeamTemplateFactory.allTemplates
        let club = templates.first { $0.templateID == "discussionClub" }
        XCTAssertNotNil(club)
        XCTAssertFalse(club!.isChatMode, "Discussion Club should not be chat mode")
    }

    func testStartupTemplate_isNotChatMode() {
        let templates = TeamTemplateFactory.allTemplates
        let startup = templates.first { $0.templateID == "startup" }
        XCTAssertNotNil(startup)
        XCTAssertFalse(startup!.isChatMode, "Startup should not be chat mode")
    }
}
