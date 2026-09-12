import XCTest

@testable import NanoTeams

/// Tail coverage for the "completion + resolution" cluster:
///
/// - `LLMExecutionService+StepCompletion` — the `revisionComment` gate on
///   `checkArtifactCompleteness` (the thing that stops premature auto-completion on
///   artifacts left over from a prior execution), every guard arm of that check, the
///   whitespace-note arm of `completeStep`, the post-completion teardown, and the
///   build-diagnostics branch of `finalizeStepCompletion`.
/// - `LLMExecutionService+ToolResolution` — the instance `toolSchemas` shims (delegate
///   plumbing + the nil-delegate guard), the role-not-in-team fallback, the
///   `conclude_meeting` / `create_artifact` auto-injections, the legacy delegation
///   strip, the "no usable delegation target" runtime defense, and the
///   `preflightCheck` wrapper (invalid-URL keeps the override, transport falls back).
/// - `LLMExecutionService+ConversationManagement` — the three `buildChatMessages`
///   guards, the Autovisor memory composition, and every arm of
///   `persistWireTranscript` / `appendLLMMessage` / `appendOrReplaceRetryNotice` /
///   `saveLLMConversation`.
/// - `LLMExecutionService+BashGate` — the under-Autovisor no-human denial, the
///   malformed-args pass-through, mixed batches, and `isUnderAutovisor` itself.
/// - `SupervisorAutoAnswerService` — the real generation path (nobody drove it before:
///   every existing test fails early on a bad index or an unreachable host).
/// - `DelegatedSupervisorAnswerService` — the stream-failure banner, the empty-answer
///   placeholder, and `extractQuestion`'s malformed-args fallback.
///
/// Every test method is `async` per the documented Xcode 26.3 abort gotcha
/// (`@MainActor` class + sync method + constructing a `@MainActor` class ⇒ `abort()`).
@MainActor
final class StepCompletionAndToolResolutionTests: XCTestCase {

    private let fm = FileManager.default
    private var tempDir: URL!
    private var service: LLMExecutionService!
    /// A second service that NEVER gets a delegate — drives the `guard let delegate`
    /// arms without in-body construction of a `@MainActor` class.
    private var detachedService: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        detachedService = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        delegate.workFolderURL = tempDir
        service.attach(delegate: delegate)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        service = nil
        detachedService = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeRole(
        id: String,
        name: String,
        toolIDs: [String] = [],
        produces: [String] = [],
        requires: [String] = [],
        systemRoleID: String? = nil,
        allowedDelegationTeamIDs: [NTMSID] = [],
        allowDelegationToGeneratedTeams: Bool = false
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: name,
            prompt: "guidance for \(name)",
            toolIDs: toolIDs,
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requires, producesArtifacts: produces),
            allowedDelegationTeamIDs: allowedDelegationTeamIDs,
            allowDelegationToGeneratedTeams: allowDelegationToGeneratedTeams,
            isSystemRole: systemRoleID != nil,
            systemRoleID: systemRoleID
        )
    }

    private func makeSupervisorRole(requires: [String] = []) -> TeamRoleDefinition {
        makeRole(
            id: "sup", name: "Supervisor", requires: requires, systemRoleID: "supervisor")
    }

    private func makeTeam(
        id: NTMSID? = nil,
        name: String = "T",
        roles: [TeamRoleDefinition],
        settings: TeamSettings = TeamSettings(),
        templateID: String? = nil
    ) -> Team {
        Team(
            id: id,
            name: name,
            templateID: templateID,
            roles: roles,
            artifacts: [],
            settings: settings,
            graphLayout: TeamGraphLayout()
        )
    }

    /// Installs a snapshot on the mock delegate with the given teams (first is active).
    private func installSnapshot(
        teams: [Team],
        selectedScheme: String? = nil,
        autovisorMemory: String = "",
        autovisorEnabled: Bool = false,
        autovisorTaskID: Int? = nil
    ) {
        let projection = WorkFolderProjection(
            state: WorkFolderState(
                name: "WF",
                activeTeamID: teams.first?.id,
                autovisorTaskID: autovisorTaskID),
            settings: ProjectSettings(
                selectedScheme: selectedScheme,
                autovisorMemory: autovisorMemory,
                autovisorEnabled: autovisorEnabled),
            teams: teams
        )
        delegate.snapshot = WorkFolderContext(
            projection: projection,
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: nil,
            activeTask: nil
        )
    }

    /// A one-step task whose step id is `stepID`, registered as a LIVE execution.
    @discardableResult
    private func installLiveTask(
        taskID: Int = 0,
        stepID: String = "swe",
        role: Role = .softwareEngineer,
        expectedArtifacts: [String] = [],
        artifacts: [Artifact] = [],
        revisionComment: String? = nil,
        teamID: NTMSID? = nil
    ) -> NTMSTask {
        var step = StepExecution(
            id: stepID,
            role: role,
            title: "Step",
            expectedArtifacts: expectedArtifacts,
            status: .running,
            artifacts: artifacts,
            revisionComment: revisionComment
        )
        step.status = .running
        var run = Run(id: 0, steps: [step])
        run.teamID = teamID
        let task = NTMSTask(
            id: taskID, title: "Task", supervisorTask: "Goal", runs: [run],
            preferredTeamID: teamID)
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        return task
    }

    /// The live copy of the step the mock delegate holds — mutations land there.
    private func currentStep(stepID: String = "swe") -> StepExecution? {
        delegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID })
    }

    // MARK: - checkArtifactCompleteness: the revisionComment gate

    func testCheckArtifactCompleteness_revisionCommentSet_returnsNil_evenWithEveryArtifactPresent() async {
        installLiveTask(
            expectedArtifacts: ["Product Requirements"],
            artifacts: [Artifact(name: "Product Requirements")],
            revisionComment: "Please redo the acceptance criteria")

        let result = service.checkArtifactCompleteness(stepID: "swe", taskID: 0)

        XCTAssertNil(
            result,
            "A step in revision must NOT auto-complete off artifacts written by the PRIOR "
                + "execution — that is exactly the premature completion the gate exists to stop.")
    }

    /// Differential partner to the test above: identical state, gate cleared ⇒ completes.
    /// Without this pair a `return nil` bug anywhere upstream would also satisfy the gate test.
    func testCheckArtifactCompleteness_revisionCommentCleared_thenCompletes() async {
        installLiveTask(
            expectedArtifacts: ["Product Requirements"],
            artifacts: [Artifact(name: "Product Requirements")],
            revisionComment: nil)

        let result = service.checkArtifactCompleteness(stepID: "swe", taskID: 0)

        guard case .completed = result else {
            return XCTFail("Expected .completed once the revision gate is clear, got \(String(describing: result))")
        }
    }

    func testCheckArtifactCompleteness_emptyRevisionComment_isStillAGate() async {
        // `revisionComment` is checked for nil-ness, not emptiness — an empty string is
        // still "in revision". Pinned so a future `isEmpty` refactor is a conscious choice.
        installLiveTask(
            expectedArtifacts: ["Plan"],
            artifacts: [Artifact(name: "Plan")],
            revisionComment: "")

        XCTAssertNil(service.checkArtifactCompleteness(stepID: "swe", taskID: 0))
    }

    // MARK: - checkArtifactCompleteness: guard arms

    func testCheckArtifactCompleteness_executionNotLive_returnsNil() async {
        installLiveTask(
            expectedArtifacts: ["Plan"], artifacts: [Artifact(name: "Plan")])
        // Tear the execution down — the post-teardown write barrier must swallow the check.
        service.clearRunningTask(stepID: "swe", taskID: 0)

        XCTAssertNil(service.checkArtifactCompleteness(stepID: "swe", taskID: 0))
    }

    func testCheckArtifactCompleteness_taskNotLoaded_returnsNil() async {
        installLiveTask(expectedArtifacts: ["Plan"], artifacts: [Artifact(name: "Plan")])
        delegate.taskToMutate = nil

        XCTAssertNil(service.checkArtifactCompleteness(stepID: "swe", taskID: 0))
    }

    func testCheckArtifactCompleteness_taskWithNoRuns_returnsNil() async {
        service._testRegisterStepTask(stepID: "swe", taskID: 0)
        delegate.taskToMutate = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [])

        XCTAssertNil(service.checkArtifactCompleteness(stepID: "swe", taskID: 0))
    }

    func testCheckArtifactCompleteness_stepOnlyInAnEarlierRun_returnsNil() async {
        // The check reads `runs.indices.last` only — a step that lives in an older run is
        // invisible to it (and must be: acceptance/completion always target the newest run).
        let oldStep = StepExecution(
            id: "swe", role: .softwareEngineer, title: "Old",
            expectedArtifacts: ["Plan"], status: .done,
            artifacts: [Artifact(name: "Plan")])
        let oldRun = Run(id: 0, steps: [oldStep])
        let newRun = Run(id: 1, steps: [])
        delegate.taskToMutate = NTMSTask(
            id: 0, title: "T", supervisorTask: "G", runs: [oldRun, newRun])
        service._testRegisterStepTask(stepID: "swe", taskID: 0)

        XCTAssertNil(service.checkArtifactCompleteness(stepID: "swe", taskID: 0))
    }

    // MARK: - completeStep: note handling + teardown

    func testCompleteStepWithWarning_whitespaceOnlyWarning_appendsNoMessage() async {
        installLiveTask()

        await service.completeStepWithWarning(stepID: "swe", taskID: 0, warning: "   \n\t  ")

        let step = currentStep()
        XCTAssertEqual(step?.status, .done, "The step still completes")
        XCTAssertTrue(
            step?.messages.isEmpty ?? false,
            "A whitespace-only note is trimmed to empty and must not become a bare `LLM warning: ` line")
    }

    func testCompleteStepFailure_usesTheSharedLLMErrorNotePrefix() async {
        // `ActivityFeedBuilder` reverse-extracts the reason from this exact prefix, so a
        // drifting literal would silently blank the failed-step bubble.
        installLiveTask()

        await service.completeStepFailure(stepID: "swe", taskID: 0, errorMessage: "  boom  ")

        let step = currentStep()
        XCTAssertEqual(step?.status, .failed)
        XCTAssertEqual(step?.messages.count, 1)
        XCTAssertEqual(
            step?.messages.first?.content,
            "\(StepExecution.llmErrorNotePrefix): boom",
            "Prefix must be the shared constant and the reason must be trimmed")
    }

    func testCompleteStepFailure_noteIsAttributedToTheStepsOwnRole() async {
        installLiveTask(role: .codeReviewer)

        await service.completeStepFailure(stepID: "swe", taskID: 0, errorMessage: "nope")

        XCTAssertEqual(currentStep()?.messages.first?.role, .codeReviewer)
    }

    func testCompleteStep_tearsDownExecutionState_soASecondCompletionCannotOverwriteTheTerminalStatus() async {
        installLiveTask()

        await service.completeStepSuccess(stepID: "swe", taskID: 0)
        XCTAssertEqual(currentStep()?.status, .done)
        XCTAssertFalse(
            service._testHasExecutionState(stepID: "swe", taskID: 0),
            "completeStep must clearRunningTask — otherwise a late catch-handler write still lands")

        // A late failure arm from the cancelled task must now be swallowed by the barrier.
        await service.completeStepFailure(stepID: "swe", taskID: 0, errorMessage: "late")

        XCTAssertEqual(
            currentStep()?.status, .done,
            "A post-teardown completion must not rewrite the terminal status")
        XCTAssertTrue(
            currentStep()?.messages.isEmpty ?? false,
            "…nor append its note")
    }

    func testCompleteStepNeedsAcceptance_recordsNoNote() async {
        installLiveTask()

        await service.completeStepNeedsAcceptance(stepID: "swe", taskID: 0)

        XCTAssertEqual(currentStep()?.status, .needsApproval)
        XCTAssertTrue(currentStep()?.messages.isEmpty ?? false)
    }

    /// The engine no longer attaches an artifact of its own on completion. The
    /// "Build Diagnostics" machinery that did was removed on 2026-09-11: its writer had
    /// been dead since `cfbcf550`, and the stub that replaced it wrote the same
    /// `errorCount: 0, issues: []` bytes whatever the step had done — including a step
    /// that never ran a build. Completion now carries exactly what the ROLE submitted.
    func testCompleteStepSuccess_attachesNoEngineAuthoredArtifact() async {
        let role = makeRole(
            id: "swe", name: "Engineer",
            produces: ["Build Diagnostics", "Engineering Notes"])
        let team = makeTeam(roles: [makeSupervisorRole(requires: ["Engineering Notes"]), role])
        installSnapshot(teams: [team])
        installLiveTask(teamID: team.id)

        await service.completeStepSuccess(stepID: "swe", taskID: 0)

        let step = currentStep()
        XCTAssertEqual(step?.status, .done)
        XCTAssertTrue(step?.artifacts.isEmpty ?? false,
                      "declaring a name the engine used to fill in must now attach nothing")
    }

    // MARK: - toolSchemas instance shims

    func testToolSchemas_withoutDelegate_returnsEmpty() async {
        let team = makeTeam(roles: [makeSupervisorRole(), makeRole(
            id: "swe", name: "Engineer", toolIDs: [ToolNames.readFile])])

        XCTAssertTrue(
            detachedService.toolSchemas(for: .custom(id: "swe"), team: team, humanPresent: true).isEmpty,
            "No delegate ⇒ no resolution environment ⇒ no tools (never a silent default)")
    }

    func testToolSchemasForDefinition_withoutDelegate_returnsEmpty() async {
        let role = makeRole(id: "swe", name: "Engineer", toolIDs: [ToolNames.readFile])

        XCTAssertTrue(detachedService.toolSchemas(forDefinition: role, team: nil, humanPresent: true).isEmpty)
    }

    func testToolSchemas_visionAvailabilityComesFromTheDelegatesVisionConfig() async {
        let role = makeRole(
            id: "swe", name: "Engineer",
            toolIDs: [ToolNames.readFile, ToolNames.analyzeImage])
        let team = makeTeam(roles: [makeSupervisorRole(), role])
        installSnapshot(teams: [team])

        delegate.visionLLMConfig = nil
        let withoutVision = Set(service.toolSchemas(forDefinition: role, team: team, humanPresent: true).map(\.name))
        XCTAssertFalse(
            withoutVision.contains(ToolNames.analyzeImage),
            "Vision not configured ⇒ analyze_image is never advertised")

        delegate.visionLLMConfig = LLMConfig(
            provider: .lmStudio, baseURLString: "http://vision:1234", modelName: "vlm")
        let withVision = Set(service.toolSchemas(forDefinition: role, team: team, humanPresent: true).map(\.name))
        XCTAssertTrue(
            withVision.contains(ToolNames.analyzeImage),
            "The instance shim must read `delegate.visionLLMConfig`, not a hardcoded default")
        XCTAssertTrue(withVision.contains(ToolNames.readFile))
    }

    func testToolSchemas_xcodeAvailabilityComesFromTheSnapshotsSelectedScheme() async {
        let role = makeRole(
            id: "swe", name: "Engineer",
            toolIDs: [ToolNames.readFile, ToolNames.runXcodebuild, ToolNames.runXcodetests])
        let team = makeTeam(roles: [makeSupervisorRole(), role])

        installSnapshot(teams: [team], selectedScheme: nil)
        let noScheme = Set(service.toolSchemas(forDefinition: role, team: team, humanPresent: true).map(\.name))
        XCTAssertFalse(noScheme.contains(ToolNames.runXcodebuild))
        XCTAssertFalse(noScheme.contains(ToolNames.runXcodetests))

        installSnapshot(teams: [team], selectedScheme: "NanoTeams")
        let withScheme = Set(service.toolSchemas(forDefinition: role, team: team, humanPresent: true).map(\.name))
        XCTAssertTrue(withScheme.contains(ToolNames.runXcodebuild))
        XCTAssertTrue(withScheme.contains(ToolNames.runXcodetests))
    }

    // MARK: - resolveToolSchemas: role-not-in-team fallback

    func testResolveToolSchemas_roleMissingFromTeam_fallsBackToTheCustomRoleDefaults() async {
        let team = makeTeam(roles: [makeSupervisorRole(), makeRole(id: "pm", name: "PM")])

        let names = Set(
            LLMExecutionService.resolveToolSchemas(
                for: .custom(id: "ghost_role_xyz"), team: team,
                approval: .available
            ).map(\.name))

        XCTAssertFalse(names.isEmpty, "The fallback must still yield a workable toolset")
        XCTAssertTrue(
            names.isSubset(of: SystemTemplates.fallbackCustomRoleToolIDs),
            "An unknown role gets exactly the custom-role fallback IDs (minus availability filters); "
                + "got extras: \(names.subtracting(SystemTemplates.fallbackCustomRoleToolIDs))")
        XCTAssertFalse(
            names.contains(ToolNames.createArtifact),
            "There is no role definition on the fallback path, so no per-role auto-injection can fire")
        XCTAssertFalse(names.contains(ToolNames.concludeMeeting))
    }

    func testResolveToolSchemas_roleMissingFromTeam_withNilTeam_stillResolves() async {
        let names = Set(
            LLMExecutionService.resolveToolSchemas(
                for: .custom(id: "ghost_role_xyz"), team: nil,
                approval: .available
            ).map(\.name))

        XCTAssertTrue(names.isSubset(of: SystemTemplates.fallbackCustomRoleToolIDs))
    }

    // MARK: - resolveToolSchemas: conclude_meeting is meeting-only (retired step 6)

    /// `conclude_meeting` never reaches a STEP schema — not for the team's coordinator, not
    /// for another meeting starter, not through a legacy `toolIDs` entry. It is granted only
    /// inside the coordinator's meeting turns (`MeetingCoordinator.speakerTools`); until
    /// 2026-09-06 step 6 injected it into steps, where no meeting is ever active.
    func testResolveToolSchemas_stepSchemaNeverCarriesConcludeMeeting() async {
        let coordinator = makeRole(
            id: "pm", name: "PM", toolIDs: [ToolNames.requestTeamMeeting])
        let other = makeRole(
            id: "tl", name: "Tech Lead", toolIDs: [ToolNames.requestTeamMeeting])
        let legacy = makeRole(
            id: "cr", name: "Reviewer",
            toolIDs: [ToolNames.requestTeamMeeting, ToolNames.concludeMeeting])
        let team = makeTeam(
            roles: [makeSupervisorRole(), coordinator, other, legacy],
            settings: TeamSettings(meetingCoordinatorRoleID: "pm"))

        for role in [coordinator, other, legacy] {
            let names = Set(
                LLMExecutionService.resolveToolSchemas(forDefinition: role, team: team, approval: .available).map(\.name))
            XCTAssertFalse(names.contains(ToolNames.concludeMeeting),
                           "\(role.name): a step schema must never carry conclude_meeting")
            XCTAssertTrue(names.contains(ToolNames.requestTeamMeeting), "\(role.name) keeps its own tools")
        }
    }

    /// The meeting turn is where the coordinator — and only the coordinator — gets it.
    func testSpeakerTools_grantsConcludeMeetingToTheCoordinatorOnly() {
        let base = LLMExecutionService.resolveToolSchemas(
            forDefinition: makeRole(id: "pm", name: "PM", toolIDs: [ToolNames.readFile, ToolNames.requestTeamMeeting]),
            team: makeTeam(roles: [makeSupervisorRole()]),
            approval: .available)

        let coordinatorTools = Set(MeetingCoordinator.speakerTools(base: base, isCoordinator: true).map(\.name))
        let participantTools = Set(MeetingCoordinator.speakerTools(base: base, isCoordinator: false).map(\.name))

        XCTAssertTrue(coordinatorTools.contains(ToolNames.concludeMeeting))
        XCTAssertFalse(participantTools.contains(ToolNames.concludeMeeting))
        XCTAssertFalse(coordinatorTools.contains(ToolNames.requestTeamMeeting),
                       "meeting-excluded tools stay excluded for the coordinator too")
        XCTAssertTrue(coordinatorTools.contains(ToolNames.readFile))
        XCTAssertEqual(
            MeetingCoordinator.speakerTools(base: base, isCoordinator: true)
                .filter { $0.name == ToolNames.concludeMeeting }.count, 1,
            "granted once, even if a base schema somehow already carried it")
    }

    // MARK: - resolveToolSchemas: meetings switched off (step 3.0c)

    /// `meetingsEnabled == false` withholds BOTH tools that convene a meeting from every
    /// role's step schema — `request_changes` too, because its vote IS a meeting.
    func testResolveToolSchemas_meetingsOff_withholdsRequestTeamMeetingAndRequestChanges() async {
        let role = makeRole(
            id: "pm", name: "PM",
            toolIDs: [ToolNames.readFile, ToolNames.requestTeamMeeting, ToolNames.requestChanges])
        // A second role, so the "on" team actually has somebody to invite.
        let partner = makeRole(id: "tl", name: "TL", toolIDs: [ToolNames.readFile])
        let off = makeTeam(
            roles: [makeSupervisorRole(), role, partner],
            settings: TeamSettings(meetingsEnabled: false))
        let on = makeTeam(roles: [makeSupervisorRole(), role, partner])

        let offNames = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: off, approval: .available).map(\.name))
        let onNames = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: on, approval: .available).map(\.name))
        let noTeam = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: nil, approval: .available).map(\.name))

        XCTAssertFalse(offNames.contains(ToolNames.requestTeamMeeting))
        XCTAssertFalse(offNames.contains(ToolNames.requestChanges))
        XCTAssertTrue(offNames.contains(ToolNames.readFile), "only the meeting tools go")
        XCTAssertTrue(onNames.contains(ToolNames.requestTeamMeeting))
        XCTAssertTrue(onNames.contains(ToolNames.requestChanges))
        XCTAssertTrue(noTeam.contains(ToolNames.requestTeamMeeting), "no team ⇒ no setting ⇒ no strip")
    }

    /// A single-role team has nobody to invite, so both meeting tools leave the schema
    /// with the switch ON — the same step 3.0c, through `Team.canHoldMeetings`; the
    /// Supervisor in the roster is the human and does not count. A second role brings
    /// the tools back. Until 2026-09-07 every single-role bundled team shipped
    /// `request_team_meeting` to a role whose only possible reply was "No valid
    /// participants".
    func testResolveToolSchemas_singleRoleTeam_withholdsMeetingToolsUntilASecondRoleExists() async {
        let role = makeRole(
            id: "pm", name: "PM",
            toolIDs: [ToolNames.readFile, ToolNames.requestTeamMeeting, ToolNames.requestChanges])
        let solo = makeTeam(roles: [makeSupervisorRole(), role])
        let pair = makeTeam(roles: [makeSupervisorRole(), role, makeRole(id: "tl", name: "TL", toolIDs: [ToolNames.readFile])])

        let soloNames = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: solo, approval: .available).map(\.name))
        let pairNames = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: pair, approval: .available).map(\.name))

        XCTAssertFalse(soloNames.contains(ToolNames.requestTeamMeeting), "the Supervisor is not a partner")
        XCTAssertFalse(soloNames.contains(ToolNames.requestChanges))
        XCTAssertTrue(soloNames.contains(ToolNames.readFile))
        XCTAssertTrue(pairNames.contains(ToolNames.requestTeamMeeting))
        XCTAssertTrue(pairNames.contains(ToolNames.requestChanges))
    }

    /// `ask_teammate` falls under the SAME partner rule (`Team.hasTeammatePartner`): a
    /// single-role team has no consultable teammate — the Supervisor is never one — so
    /// step 3.0c withholds the tool; a second non-Supervisor role brings it back; no team
    /// at all means no roster and therefore no strip. Until 2026-09-07 the tool stayed on
    /// such a role, and its only addressee was an LLM answering AS the Supervisor through
    /// the `supervisorCanBeInvited` seat.
    func testResolveToolSchemas_singleRoleTeam_withholdsAskTeammate_untilASecondRoleExists() async {
        let role = makeRole(id: "pm", name: "PM", toolIDs: [ToolNames.readFile, ToolNames.askTeammate])
        let solo = makeTeam(roles: [makeSupervisorRole(), role])
        let alone = makeTeam(roles: [role])
        let pair = makeTeam(roles: [makeSupervisorRole(), role, makeRole(id: "tl", name: "TL", toolIDs: [ToolNames.readFile])])

        let soloNames = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: solo, approval: .available).map(\.name))
        let aloneNames = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: alone, approval: .available).map(\.name))
        let pairNames = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: pair, approval: .available).map(\.name))
        let noTeam = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: nil, approval: .available).map(\.name))

        XCTAssertFalse(soloNames.contains(ToolNames.askTeammate), "the Supervisor is not a partner")
        XCTAssertTrue(soloNames.contains(ToolNames.readFile), "only ask_teammate goes")
        XCTAssertFalse(aloneNames.contains(ToolNames.askTeammate), "no Supervisor in the roster changes nothing")
        XCTAssertTrue(pairNames.contains(ToolNames.askTeammate))
        XCTAssertTrue(noTeam.contains(ToolNames.askTeammate), "no team ⇒ no roster ⇒ no strip")
    }

    /// The meetings switch is NOT the partner rule: `meetingsEnabled == false` on a
    /// two-role team withholds the tools that convene a meeting and leaves `ask_teammate`
    /// alone — switching meetings off does not take consultations with it.
    func testResolveToolSchemas_meetingsOff_leavesAskTeammateAlone() async {
        let role = makeRole(
            id: "pm", name: "PM",
            toolIDs: [ToolNames.readFile, ToolNames.askTeammate, ToolNames.requestTeamMeeting, ToolNames.requestChanges])
        let partner = makeRole(id: "tl", name: "TL", toolIDs: [ToolNames.readFile])
        let off = makeTeam(
            roles: [makeSupervisorRole(), role, partner],
            settings: TeamSettings(meetingsEnabled: false))

        let offNames = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: off, approval: .available).map(\.name))

        XCTAssertTrue(offNames.contains(ToolNames.askTeammate), "a partner exists; the switch is about meetings")
        XCTAssertFalse(offNames.contains(ToolNames.requestTeamMeeting))
        XCTAssertFalse(offNames.contains(ToolNames.requestChanges))
        XCTAssertTrue(offNames.contains(ToolNames.readFile))
    }

    // MARK: - resolveToolSchemas: Ask Supervisor mode Off (steps 4 / 8b)

    /// Off closes BOTH routes to `ask_supervisor`: the advisory auto-injection (step 4) and
    /// an explicit `toolIDs` entry (step 8b). Manual and autonomous are untouched.
    ///
    /// The questionnaire rides the SAME strip, over `ToolNames.supervisorAskTools` rather than
    /// the one name: Off means nobody is there to answer, and a form parks a step exactly as a
    /// plain question does. A strip that named only `ask_supervisor` would leave the one tool
    /// whose park nobody could clear.
    ///
    /// RED: strip only `tn.askSupervisor` at either site → the `planner` row's Off assertion
    /// fails on `ask_supervisor_form`.
    func testResolveToolSchemas_askSupervisorOff_withholdsBothAskToolsOnBothRoutes() async {
        let advisory = makeRole(id: "qm", name: "Quest Master", requires: ["Supervisor Task"])
        let explicit = makeRole(
            id: "pm", name: "PM", toolIDs: [ToolNames.readFile, ToolNames.askSupervisor],
            produces: ["PRD"])
        let planner = makeRole(
            id: "planner", name: "Planner",
            toolIDs: [ToolNames.readFile, ToolNames.askSupervisor, ToolNames.askSupervisorForm],
            produces: ["Brief"])
        let roles = [makeSupervisorRole(), advisory, explicit, planner]
        let off = makeTeam(roles: roles, settings: TeamSettings(supervisorMode: .off))
        let manual = makeTeam(roles: roles, settings: TeamSettings(supervisorMode: .manual))

        for role in [advisory, explicit, planner] {
            let offNames = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: off, approval: .available).map(\.name))
            let manualNames = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: manual, approval: .available).map(\.name))
            XCTAssertTrue(offNames.isDisjoint(with: ToolNames.supervisorAskTools),
                          "\(role.name): Off withholds every tool that parks on the Supervisor")
            XCTAssertTrue(manualNames.contains(ToolNames.askSupervisor), "\(role.name): manual keeps it")
        }
        let plannerManual = Set(LLMExecutionService.resolveToolSchemas(forDefinition: planner, team: manual, approval: .available).map(\.name))
        XCTAssertTrue(plannerManual.contains(ToolNames.askSupervisorForm),
                      "manual keeps the questionnaire the role was granted")
    }

    // MARK: - resolveToolSchemas: the ask PAIR reaches the schema (steps 4 + 4-bis)

    /// An advisory role that spells NO toolset gets BOTH supervisor-ask tools.
    ///
    /// Two steps together: step 4 injects the plain ask for a role nobody wrote a toolset for
    /// — every custom role the New Team sheet creates as advisory, every generated team's chat
    /// role — and step 4-bis pairs the questionnaire onto it. While nothing paired, the
    /// questionnaire was a privilege of roles with a STORED toolset, which inverts what it is
    /// for: one interruption settling several decisions, and the roles that interrupt on
    /// nearly every turn are exactly these.
    ///
    /// Each ships exactly ONCE — both arms guard on `allowedTools` membership.
    ///
    /// RED: drop the plain⇒form arm of step 4-bis → the intersection is one tool and the role
    /// can only ever ask one question at a time.
    func testResolveToolSchemas_advisoryRoleWithNoToolset_getsBothAskTools() async {
        let advisory = makeRole(id: "qm", name: "Quest Master", requires: ["Supervisor Task"])
        let team = makeTeam(
            roles: [makeSupervisorRole(), advisory],
            settings: TeamSettings(supervisorMode: .manual))

        let schemas = LLMExecutionService.resolveToolSchemas(forDefinition: advisory, team: team, approval: .available)
        let names = schemas.map(\.name)

        XCTAssertEqual(Set(names).intersection(ToolNames.supervisorAskTools), ToolNames.supervisorAskTools,
                       "a role that may interrupt the human may interrupt them with a questionnaire")
        for tool in ToolNames.supervisorAskTools {
            XCTAssertEqual(names.filter { $0 == tool }.count, 1, "\(tool) ships exactly once")
        }
    }

    /// The half-stored shape: the role lists the plain ask and not the form. Step 4-bis
    /// completes the pair and does not duplicate what is already there.
    ///
    /// This is every work folder upgraded from before 2026-09-10 whose role is advisory —
    /// the reconcile rewrites a SYSTEM role's toolset from the bundle, but a custom one keeps
    /// what the user checked.
    ///
    /// RED: append without the membership guard → `ask_supervisor` ships twice and the
    /// provider sees a duplicate function name.
    func testResolveToolSchemas_advisoryRoleHoldingOnlyThePlainAsk_gainsTheFormOnce() async {
        let advisory = makeRole(
            id: "assistant", name: "Assistant",
            toolIDs: [ToolNames.readFile, ToolNames.askSupervisor],
            requires: ["Supervisor Task"])
        let team = makeTeam(
            roles: [makeSupervisorRole(), advisory],
            settings: TeamSettings(supervisorMode: .manual))

        let names = LLMExecutionService.resolveToolSchemas(forDefinition: advisory, team: team, approval: .available).map(\.name)

        XCTAssertEqual(names.filter { $0 == ToolNames.askSupervisor }.count, 1,
                       "the stored entry is not doubled by the injection")
        XCTAssertEqual(names.filter { $0 == ToolNames.askSupervisorForm }.count, 1,
                       "the missing half is filled in")
    }

    /// The gate is unchanged: a PRODUCING role that lists neither tool still gets neither.
    /// Step 4 reads `shouldAutoInjectAskSupervisor`, and widening what it injects must not
    /// widen WHOM it injects for — otherwise the Ultra Team's "one asker" rule dissolves,
    /// since every role there produces an artifact.
    ///
    /// RED: drop the `shouldAutoInjectAskSupervisor` gate → eight more Ultra Team roles can
    /// stop the pipeline to ask the human something.
    func testResolveToolSchemas_producingRoleListingNeither_stillGetsNeither() async {
        let producer = makeRole(id: "arch", name: "Architect", toolIDs: [ToolNames.readFile],
                                produces: ["Approach A"])
        let team = makeTeam(
            roles: [makeSupervisorRole(), producer],
            settings: TeamSettings(supervisorMode: .manual))

        let names = Set(LLMExecutionService.resolveToolSchemas(forDefinition: producer, team: team, approval: .available).map(\.name))

        XCTAssertTrue(names.isDisjoint(with: ToolNames.supervisorAskTools),
                      "a producing role asks only if its toolset says so")
        XCTAssertTrue(names.contains(ToolNames.createArtifact), "sanity: step 5 still ran")
    }

    // MARK: - resolveToolSchemas: the questionnaire is a companion (step 4-bis)

    /// A role granted only `ask_supervisor_form` gets the plain ask beside it.
    ///
    /// The form is a COMPANION, never a replacement, and until now that was advice: nothing
    /// stopped the role editor from checking the form alone. Three texts then contradict the
    /// schema at once — `SystemTemplates.stepEnding` tells the role it has no way to ask
    /// (`canAskSupervisor` reads `ask_supervisor`), `LoopRecoveryPolicy.escalationChannel`
    /// names no channel, and the teammate-consultation note stays silent — while the schema
    /// offers a tool that parks the step. Pairing at the resolver makes the invariant
    /// structural, so those three keep reading one name and stay right.
    ///
    /// The lesser capability is the one added: a role that may send a questionnaire may
    /// certainly ask one question, and auto-injection already grants `ask_supervisor` to
    /// roles that never listed it (step 4).
    ///
    /// RED: drop the pairing → `escalationChannel` over the resolved names returns nil for a
    /// role whose schema can park the step.
    func testResolveToolSchemas_formWithoutPlainAsk_getsThePlainAskPairedIn() async {
        let formOnly = makeRole(
            id: "planner", name: "Planner",
            toolIDs: [ToolNames.readFile, ToolNames.askSupervisorForm],
            produces: ["Brief"])
        let team = makeTeam(
            roles: [makeSupervisorRole(), formOnly],
            settings: TeamSettings(supervisorMode: .manual))

        let names = Set(LLMExecutionService.resolveToolSchemas(forDefinition: formOnly, team: team, approval: .available).map(\.name))

        XCTAssertTrue(names.contains(ToolNames.askSupervisorForm), "the granted tool survives")
        XCTAssertTrue(names.contains(ToolNames.askSupervisor),
                      "the form's escalation channel ships beside it")
        XCTAssertEqual(LoopRecoveryPolicy.escalationChannel(in: names), ToolNames.askSupervisor,
                       "a role that can park has a channel every correction text can name")
    }

    /// The mirror arm, and the one the app's OWN generator needs: a PRODUCING role whose
    /// stored toolset names `ask_supervisor` and nothing else gains the questionnaire.
    ///
    /// Step 4 cannot reach this role — `shouldAutoInjectAskSupervisor` requires an empty
    /// `producesArtifacts`, so every generated pipeline role, every imported team's worker and
    /// every role hand-ticked in the Tools tab falls outside it. `TeamGenerationService`
    /// teaches the model exactly one escalation name, so the toolsets it writes are all this
    /// shape; without the plain⇒form arm they would be the only roles in the app that can
    /// interrupt the human but never with more than one question.
    ///
    /// RED: drop the plain⇒form arm → the form is missing and "every role that holds
    /// `ask_supervisor` holds the form" is true of bundled templates only.
    func testResolveToolSchemas_producingRoleHoldingOnlyThePlainAsk_gainsTheForm() async {
        let producer = makeRole(
            id: "swe", name: "Software Engineer",
            toolIDs: [ToolNames.readFile, ToolNames.askSupervisor],
            produces: ["Engineering Notes"])
        let team = makeTeam(
            roles: [makeSupervisorRole(), producer],
            settings: TeamSettings(supervisorMode: .manual))

        let names = LLMExecutionService.resolveToolSchemas(forDefinition: producer, team: team, approval: .available).map(\.name)

        XCTAssertEqual(names.filter { $0 == ToolNames.askSupervisorForm }.count, 1,
                       "the questionnaire pairs onto a stored plain ask, producing role or not")
        XCTAssertEqual(names.filter { $0 == ToolNames.askSupervisor }.count, 1,
                       "the stored entry is not doubled")
    }

    /// Pairing never MANUFACTURES an asker. A producing role that holds neither name still
    /// holds neither after both arms run — the arms complete a pair, they do not open one.
    ///
    /// This is what keeps the Ultra Team's "the planner is the only asker" rule intact: its
    /// eight other roles all produce artifacts and list no ask tool.
    ///
    /// RED: pair unconditionally (e.g. inject the form whenever the mode allows) → eight more
    /// Ultra Team roles can stop the pipeline to ask the human something.
    func testResolveToolSchemas_producingRoleListingNeither_gainsNeitherFromPairing() async {
        let producer = makeRole(id: "verifier", name: "Verifier", toolIDs: [ToolNames.readFile],
                                produces: ["Verification Report"])
        let team = makeTeam(
            roles: [makeSupervisorRole(), producer],
            settings: TeamSettings(supervisorMode: .manual))

        let names = Set(LLMExecutionService.resolveToolSchemas(forDefinition: producer, team: team, approval: .available).map(\.name))

        XCTAssertTrue(names.isDisjoint(with: ToolNames.supervisorAskTools),
                      "an empty pair stays empty")
    }

    /// Pairing is subordinate to the mode: a role granted the questionnaire alone ships
    /// neither tool under Off, so the heal cannot re-open the route the mode closed.
    ///
    /// Moving the pairing after the strips was measured and reds NOTHING (mutation
    /// `s4_pairing_after_the_strips`, 2026-09-10): the Off strip removes the FORM too, so a
    /// later pairing finds nothing to pair. The order is therefore a readability choice, not
    /// an invariant, and this test does not pretend to pin it.
    ///
    /// RED: strip only `tn.askSupervisor` at 8b → the granted questionnaire ships to a team
    /// that has nobody to answer it.
    func testResolveToolSchemas_formWithoutPlainAsk_underOff_shipsNeither() async {
        let formOnly = makeRole(
            id: "planner", name: "Planner",
            toolIDs: [ToolNames.readFile, ToolNames.askSupervisorForm],
            produces: ["Brief"])
        let team = makeTeam(
            roles: [makeSupervisorRole(), formOnly],
            settings: TeamSettings(supervisorMode: .off))

        let names = Set(LLMExecutionService.resolveToolSchemas(forDefinition: formOnly, team: team, approval: .available).map(\.name))

        XCTAssertTrue(names.isDisjoint(with: ToolNames.supervisorAskTools),
                      "Off closes the route the pairing would otherwise re-open")
        XCTAssertTrue(names.contains(ToolNames.readFile), "sanity: the rest of the toolset stands")
    }

    // MARK: - resolveToolSchemas: create_artifact auto-injection (step 5)

    func testResolveToolSchemas_producingRole_getsCreateArtifactWithItsDeliverablesInlined() async {
        let producer = makeRole(
            id: "pm", name: "PM", toolIDs: [ToolNames.readFile],
            produces: ["Product Requirements"])
        let team = makeTeam(roles: [makeSupervisorRole(requires: ["Product Requirements"]), producer])

        let schemas = LLMExecutionService.resolveToolSchemas(forDefinition: producer, team: team, approval: .available)
        let createArtifact = schemas.first(where: { $0.name == ToolNames.createArtifact })

        XCTAssertNotNil(createArtifact, "A producing role always gets create_artifact")
        XCTAssertEqual(
            createArtifact?.parameters.properties?["name"]?.enumValues, ["Product Requirements"],
            "The schema is built per-role so the deliverable names constrain `name` at the decision point")
        XCTAssertFalse(
            createArtifact?.description.contains("Product Requirements") ?? true,
            "the description does not repeat the enum — `## Deliverables` and the closing turn carry the "
                + "names in prose (R3.4.2)")
    }

    /// A stored `toolIDs` that already carries `create_artifact` (a generated or hand-edited
    /// toolset) gets the per-role schema too: until 2026-09-06 step 5 skipped such a role and
    /// left it the static schema, whose `name` has no enum and whose description promised the
    /// names were "appended here" — the R3.1.4 stop-condition contract without the contract.
    func testResolveToolSchemas_storedCreateArtifact_isReplacedByThePerRoleSchema() async {
        let producer = makeRole(
            id: "pm", name: "PM", toolIDs: [ToolNames.readFile, ToolNames.createArtifact],
            produces: ["Product Requirements"])
        let team = makeTeam(roles: [makeSupervisorRole(requires: ["Product Requirements"]), producer])

        let schemas = LLMExecutionService.resolveToolSchemas(forDefinition: producer, team: team, approval: .available)
        let createArtifacts = schemas.filter { $0.name == ToolNames.createArtifact }

        XCTAssertEqual(createArtifacts.count, 1, "replaced in place, never duplicated")
        XCTAssertEqual(createArtifacts.first?.parameters.properties?["name"]?.enumValues,
                       ["Product Requirements"])
    }

    // MARK: - resolveToolSchemas: manager-only tools never reach a team role (step 3.0b)

    /// The ten management tools define the Autovisor; their signals mean nothing on any other
    /// role's step loop, and `set_work_folder_context` rewrites what every role of every task
    /// reads. A generated or hand-edited `toolIDs` carrying them is stripped structurally —
    /// the mirror of step 8, which strips `ask_supervisor` from the manager.
    func testResolveToolSchemas_managerOnlyTools_areStrippedFromATeamRole_andKeptOnTheManager() async {
        let planted = [ToolNames.controlTask, ToolNames.waitForEvents, ToolNames.setWorkFolderContext]
        let role = makeRole(
            id: "swe", name: "SWE", toolIDs: [ToolNames.readFile] + planted, produces: ["Notes"])
        let team = makeTeam(roles: [makeSupervisorRole(requires: ["Notes"]), role])
        let names = Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: team, approval: .available).map(\.name))
        for tool in planted {
            XCTAssertFalse(names.contains(tool), "\(tool) is the manager's alone")
        }
        XCTAssertTrue(names.contains(ToolNames.readFile))

        let manager = makeRole(
            id: "mgr", name: "Autovisor", toolIDs: AutovisorConstants.managerDefaultToolIDs,
            systemRoleID: AutovisorConstants.managerRoleSystemID)
        let managerTeam = makeTeam(
            roles: [makeSupervisorRole(), manager], templateID: AutovisorConstants.teamTemplateID)
        let managerNames = Set(
            LLMExecutionService.resolveToolSchemas(forDefinition: manager, team: managerTeam, approval: .available).map(\.name))
        for tool in AutovisorConstants.managerMandatoryToolIDs {
            XCTAssertTrue(managerNames.contains(tool), "the manager keeps \(tool)")
        }
    }

    func testResolveToolSchemas_supervisorRole_neverGetsCreateArtifact() async {
        // The Supervisor is the human — even with declared outputs it must not be handed
        // the artifact tool.
        var supervisor = makeSupervisorRole()
        supervisor.dependencies = RoleDependencies(producesArtifacts: ["Supervisor Task"])
        let team = makeTeam(roles: [supervisor, makeRole(id: "pm", name: "PM")])

        let names = Set(
            LLMExecutionService.resolveToolSchemas(forDefinition: supervisor, team: team, approval: .available).map(\.name))

        XCTAssertFalse(names.contains(ToolNames.createArtifact))
    }

    func testResolveToolSchemas_advisoryRole_getsAskSupervisorButNotCreateArtifact() async {
        let advisory = makeRole(
            id: "assistant", name: "Assistant", toolIDs: [ToolNames.readFile],
            requires: ["Supervisor Task"])
        let team = makeTeam(roles: [makeSupervisorRole(), advisory])

        let names = Set(
            LLMExecutionService.resolveToolSchemas(forDefinition: advisory, team: team, approval: .available).map(\.name))

        XCTAssertTrue(names.contains(ToolNames.askSupervisor), "Non-producing roles escalate")
        XCTAssertFalse(names.contains(ToolNames.createArtifact))
    }

    // MARK: - resolveToolSchemas: delegation strip + runtime defense (steps 3.0 / 7)

    func testResolveToolSchemas_legacyDelegationToolIDsAreStripped_whenDelegationIsNotConfigured() async {
        // A hand-edited / pre-migration `toolIDs` must not bypass the settings gate.
        let role = makeRole(
            id: "agent", name: "Agent",
            toolIDs: [
                ToolNames.readFile, ToolNames.delegateToTeam, ToolNames.cancelDelegation,
                ToolNames.resumeDelegation, ToolNames.forwardToTeam, "list_teams",
            ])
        let team = makeTeam(roles: [makeSupervisorRole(), role])

        let names = Set(
            LLMExecutionService.resolveToolSchemas(forDefinition: role, team: team, approval: .available).map(\.name))

        XCTAssertFalse(names.contains(ToolNames.delegateToTeam))
        XCTAssertFalse(names.contains(ToolNames.cancelDelegation))
        XCTAssertFalse(names.contains(ToolNames.resumeDelegation))
        XCTAssertFalse(names.contains(ToolNames.forwardToTeam))
        XCTAssertFalse(names.contains("list_teams"), "The removed discovery tool never ships")
        XCTAssertTrue(names.contains(ToolNames.readFile), "…and the rest of the toolset survives")
    }

    func testResolveToolSchemas_whitelistedTeamIsChatMode_skipsTheWholeDelegationPack() async {
        // `delegationEnabled` only checks that a whitelist exists. Chat-mode teams are not
        // valid targets, so with no other target the pack would be uncallable — skip it
        // rather than hand the model a tool that always returns DELEGATION_DENIED.
        let chatTeam = makeTeam(
            id: "chat-team", name: "Coding Assistant",
            roles: [makeSupervisorRole(), makeRole(id: "ca", name: "Coding Assistant")])
        XCTAssertTrue(chatTeam.isChatMode, "Precondition: no supervisor deliverables ⇒ chat mode")

        let delegator = makeRole(
            id: "agent", name: "Agent", toolIDs: [ToolNames.readFile],
            allowedDelegationTeamIDs: [chatTeam.id],
            allowDelegationToGeneratedTeams: false)
        let ownTeam = makeTeam(id: "own", name: "Own", roles: [makeSupervisorRole(), delegator])
        XCTAssertTrue(
            ownTeam.delegationEnabled(for: delegator),
            "Precondition: the role IS configured for delegation — the guard under test is downstream")

        let names = Set(
            LLMExecutionService.resolveToolSchemas(
                forDefinition: delegator, team: ownTeam, allTeams: [ownTeam, chatTeam],
                approval: .available
            ).map(\.name))

        XCTAssertFalse(names.contains(ToolNames.delegateToTeam))
        XCTAssertFalse(names.contains(ToolNames.cancelDelegation))
        XCTAssertFalse(names.contains(ToolNames.resumeDelegation))
        XCTAssertFalse(names.contains(ToolNames.forwardToTeam))
    }

    func testResolveToolSchemas_usableWhitelistedTeam_injectsTheFullFourToolPack() async {
        let targetTeam = makeTeam(
            id: "eng-team", name: "Engineering",
            roles: [makeSupervisorRole(requires: ["Release Notes"]),
                    makeRole(id: "tl", name: "Tech Lead", produces: ["Release Notes"])])
        XCTAssertFalse(targetTeam.isChatMode, "Precondition: a real delegation target")

        let delegator = makeRole(
            id: "agent", name: "Agent", toolIDs: [ToolNames.readFile],
            allowedDelegationTeamIDs: [targetTeam.id])
        let ownTeam = makeTeam(id: "own", name: "Own", roles: [makeSupervisorRole(), delegator])

        let names = Set(
            LLMExecutionService.resolveToolSchemas(
                forDefinition: delegator, team: ownTeam, allTeams: [ownTeam, targetTeam],
                approval: .available
            ).map(\.name))

        XCTAssertTrue(names.contains(ToolNames.delegateToTeam))
        XCTAssertTrue(
            names.isSuperset(of: [
                ToolNames.cancelDelegation, ToolNames.resumeDelegation, ToolNames.forwardToTeam,
            ]),
            "The pause-and-decide companions are mandatory as a unit")
    }

    func testResolveToolSchemas_subordinateRole_neverGetsDelegation_evenWithAWhitelist() async {
        let targetTeam = makeTeam(
            id: "eng-team", name: "Engineering",
            roles: [makeSupervisorRole(requires: ["Release Notes"]),
                    makeRole(id: "tl", name: "Tech Lead", produces: ["Release Notes"])])
        let subordinate = makeRole(
            id: "agent", name: "Agent", allowedDelegationTeamIDs: [targetTeam.id])
        var settings = TeamSettings()
        settings.hierarchy.reportsTo = ["agent": "sup"]
        let ownTeam = makeTeam(
            id: "own", name: "Own", roles: [makeSupervisorRole(), subordinate], settings: settings)

        let names = Set(
            LLMExecutionService.resolveToolSchemas(
                forDefinition: subordinate, team: ownTeam, allTeams: [ownTeam, targetTeam],
                approval: .available
            ).map(\.name))

        XCTAssertFalse(
            names.contains(ToolNames.delegateToTeam),
            "Peer-with-Supervisor is a structural precondition — a `reportsTo` entry disqualifies")
    }

    // MARK: - preflightCheck (the service-bound wrapper)

    func testPreflightCheck_invalidOverrideURL_keepsTheOverride_andPostsTheValidationMessage() async {
        installLiveTask()
        let session = StubPreflightSession()
        let override = LLMConfig(
            provider: .lmStudio, baseURLString: "", modelName: "override-m")
        let global = LLMConfig(
            provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "global-m")

        let result = await LLMExecutionService.preflightCheck(
            effectiveConfig: override, globalConfig: global,
            stepID: "swe", taskID: 0, service: service,
            session: session, resolver: StubLLMTokenResolver())

        XCTAssertEqual(
            result.modelName, "override-m",
            "A malformed override URL is a misconfiguration to SURFACE, not to silently paper over")
        XCTAssertNil(session.capturedRequest, "A URL that won't parse never reaches the network")

        let systemNotes = currentStep()?.llmConversation.filter { $0.role == .system } ?? []
        XCTAssertEqual(systemNotes.count, 1, "The wrapper routes the note through appendLLMMessage")
        XCTAssertTrue(systemNotes.first?.content.contains("invalid") ?? false)
    }

    func testPreflightCheck_transportFailure_fallsBackToGlobal_andExplainsWhy() async {
        installLiveTask()
        let session = StubPreflightSession()
        session.errorToThrow = URLError(.cannotConnectToHost)
        let override = LLMConfig(
            provider: .lmStudio, baseURLString: "http://override:9999", modelName: "override-m")
        let global = LLMConfig(
            provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "global-m")

        let result = await LLMExecutionService.preflightCheck(
            effectiveConfig: override, globalConfig: global,
            stepID: "swe", taskID: 0, service: service,
            session: session, resolver: StubLLMTokenResolver())

        XCTAssertEqual(
            result.modelName, "global-m",
            "A momentarily unreachable override server must not wedge the step")
        let systemNotes = currentStep()?.llmConversation.filter { $0.role == .system } ?? []
        XCTAssertEqual(systemNotes.count, 1)
        XCTAssertTrue(systemNotes.first?.content.contains("unavailable") ?? false)
    }

    func testPreflightDecision_nonHTTPResponse_fallsBackToGlobal() async {
        // A response that is not an `HTTPURLResponse` has no status to judge — the decision
        // must land on the transport arm, not crash or optimistically keep the override.
        let session = StubPreflightSession()
        session.returnsNonHTTPResponse = true
        let override = LLMConfig(
            provider: .lmStudio, baseURLString: "http://override:9999", modelName: "override-m")
        let global = LLMConfig(
            provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "global-m")
        let collector = PreflightMessageCollector()

        let result = await LLMExecutionService.preflightDecision(
            effectiveConfig: override, globalConfig: global,
            session: session, resolver: StubLLMTokenResolver(),
            appendSystemMessage: { await collector.add($0) })

        XCTAssertEqual(result.modelName, "global-m")
        let messages = await collector.messages
        XCTAssertEqual(messages.count, 1)
    }

    // MARK: - buildChatMessages guards

    func testBuildChatMessages_withoutDelegate_returnsEmpty() async {
        let task = NTMSTask(
            id: 0, title: "T", supervisorTask: "G",
            runs: [Run(id: 0, steps: [
                StepExecution(id: "swe", role: .softwareEngineer, title: "S"),
            ])])

        let messages = detachedService.buildChatMessages(
            for: task, stepID: "swe", tools: [], supervisorMode: .manual)

        XCTAssertTrue(messages.isEmpty)
    }

    func testBuildChatMessages_taskWithNoRuns_returnsEmpty() async {
        installSnapshot(teams: [makeTeam(roles: [makeSupervisorRole()])])
        let task = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [])

        XCTAssertTrue(
            service.buildChatMessages(
                for: task, stepID: "swe", tools: [], supervisorMode: .manual).isEmpty)
    }

    func testBuildChatMessages_unknownStepID_returnsEmpty() async {
        installSnapshot(teams: [makeTeam(roles: [makeSupervisorRole()])])
        let task = NTMSTask(
            id: 0, title: "T", supervisorTask: "G",
            runs: [Run(id: 0, steps: [
                StepExecution(id: "swe", role: .softwareEngineer, title: "S"),
            ])])

        XCTAssertTrue(
            service.buildChatMessages(
                for: task, stepID: "nope", tools: [], supervisorMode: .manual).isEmpty)
    }

    // MARK: - buildChatMessages: Autovisor standing-memory composition

    func testBuildChatMessages_autovisorTeam_appendsStandingMemoryToTheGlobalContext() async {
        let manager = makeRole(
            id: "autovisor", name: "Autovisor", toolIDs: [ToolNames.updateScratchpad],
            requires: ["Supervisor Task"])
        let team = makeTeam(
            id: "autovisor-team", name: "Autovisor",
            roles: [makeSupervisorRole(), manager],
            templateID: AutovisorConstants.teamTemplateID)
        installSnapshot(teams: [team], autovisorMemory: "MEMORY-SENTINEL-42")
        delegate.globalLLMContext = "GLOBAL-CTX-SENTINEL"

        let task = installLiveTask(stepID: "autovisor", role: .custom(id: "autovisor"), teamID: team.id)
        let messages = service.buildChatMessages(
            for: task, stepID: "autovisor", tools: [], supervisorMode: .autonomous)

        let system = messages.first(where: { $0.role == .system })?.content ?? ""
        XCTAssertTrue(
            system.contains("GLOBAL-CTX-SENTINEL"),
            "The plain global context must survive the Autovisor composition")
        XCTAssertTrue(
            system.contains("MEMORY-SENTINEL-42"),
            "The manager's standing memory is its only cross-run state — it must ride every fresh run")
    }

    func testBuildChatMessages_nonAutovisorTeam_doesNotLeakTheStandingMemory() async {
        let role = makeRole(id: "swe", name: "Engineer", requires: ["Supervisor Task"])
        let team = makeTeam(id: "plain", name: "Plain", roles: [makeSupervisorRole(), role])
        installSnapshot(teams: [team], autovisorMemory: "MEMORY-SENTINEL-42")
        delegate.globalLLMContext = "GLOBAL-CTX-SENTINEL"

        let task = installLiveTask(stepID: "swe", teamID: team.id)
        let messages = service.buildChatMessages(
            for: task, stepID: "swe", tools: [], supervisorMode: .manual)

        let system = messages.first(where: { $0.role == .system })?.content ?? ""
        XCTAssertTrue(system.contains("GLOBAL-CTX-SENTINEL"))
        XCTAssertFalse(
            system.contains("MEMORY-SENTINEL-42"),
            "Only the manager sees its memory — leaking it into every role's prompt is a real cost")
    }

    func testBuildChatMessages_autovisorTeamWithBlankMemory_leavesGlobalContextUntouched() async {
        let manager = makeRole(id: "autovisor", name: "Autovisor", requires: ["Supervisor Task"])
        let team = makeTeam(
            id: "autovisor-team", name: "Autovisor",
            roles: [makeSupervisorRole(), manager],
            templateID: AutovisorConstants.teamTemplateID)
        installSnapshot(teams: [team], autovisorMemory: "   \n  ")
        delegate.globalLLMContext = "GLOBAL-CTX-SENTINEL"

        let task = installLiveTask(stepID: "autovisor", role: .custom(id: "autovisor"), teamID: team.id)
        let messages = service.buildChatMessages(
            for: task, stepID: "autovisor", tools: [], supervisorMode: .autonomous)

        let system = messages.first(where: { $0.role == .system })?.content ?? ""
        XCTAssertTrue(system.contains("GLOBAL-CTX-SENTINEL"))
        XCTAssertFalse(
            system.contains("Current Memory"),
            "A whitespace-only memory must not ship an empty `## Current Memory` header")
    }

    // MARK: - persistWireTranscript

    func testPersistWireTranscript_emptyMessages_isANoOp_andLeavesTheDeliveryFlagArmed() async {
        var task = installLiveTask()
        task.runs[0].steps[0].supervisorAnswer = "Do it"
        task.runs[0].steps[0].supervisorAnswerPendingDelivery = true
        delegate.taskToMutate = task

        await service.persistWireTranscript(stepID: "swe", taskID: 0, messages: [])

        XCTAssertTrue(currentStep()?.wireTranscript.isEmpty ?? false)
        XCTAssertTrue(
            currentStep()?.supervisorAnswerPendingDelivery ?? false,
            "Nothing was persisted, so the answer has NOT reached the wire — spending the flag "
                + "here would swallow the answer on the next re-entry")
    }

    func testPersistWireTranscript_storesTheTranscript_andConsumesTheDeliveryFlag() async {
        var task = installLiveTask()
        task.runs[0].steps[0].supervisorAnswer = "Do it"
        task.runs[0].steps[0].supervisorAnswerPendingDelivery = true
        delegate.taskToMutate = task

        let wire = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "u"),
            ChatMessage(role: .assistant, content: "a"),
        ]
        await service.persistWireTranscript(stepID: "swe", taskID: 0, messages: wire)

        XCTAssertEqual(currentStep()?.wireTranscript.count, 3)
        XCTAssertEqual(currentStep()?.wireTranscript, wire, "Byte-faithful, not re-synthesized")
        XCTAssertFalse(
            currentStep()?.supervisorAnswerPendingDelivery ?? true,
            "The stored transcript already carries the answer — the flag is consumed in the SAME mutation")
    }

    func testPersistWireTranscript_afterTeardown_isANoOp() async {
        installLiveTask()
        service.clearRunningTask(stepID: "swe", taskID: 0)

        await service.persistWireTranscript(
            stepID: "swe", taskID: 0, messages: [ChatMessage(role: .user, content: "late")])

        XCTAssertTrue(
            currentStep()?.wireTranscript.isEmpty ?? false,
            "A late write from a cancelled task must be dropped by the execution barrier")
    }

    // MARK: - appendLLMMessage

    func testAppendLLMMessage_emptyContentAndNoThinking_appendsNothing() async {
        installLiveTask()

        await service.appendLLMMessage(stepID: "swe", taskID: 0, role: .assistant, content: "")

        XCTAssertTrue(currentStep()?.llmConversation.isEmpty ?? false)
    }

    func testAppendLLMMessage_contentThatCleansToEmpty_appendsNothing() async {
        // A reply that was nothing but model-internal tokens leaves no bubble behind.
        installLiveTask()

        await service.appendLLMMessage(
            stepID: "swe", taskID: 0, role: .assistant, content: "<|channel|>final")

        XCTAssertTrue(
            currentStep()?.llmConversation.isEmpty ?? false,
            "Emptiness is judged AFTER Harmony cleaning, not before")
    }

    func testAppendLLMMessage_stripsHarmonyTokensFromContentAndThinking() async {
        installLiveTask()

        await service.appendLLMMessage(
            stepID: "swe", taskID: 0, role: .assistant,
            content: "<|channel|>final Answer body",
            thinking: "<|channel|>commentary Reasoning body")

        let msg = currentStep()?.llmConversation.first
        XCTAssertEqual(msg?.content, "Answer body")
        XCTAssertEqual(msg?.thinking, "Reasoning body")
    }

    func testAppendLLMMessage_thinkingOnly_isStillPersisted() async {
        installLiveTask()

        await service.appendLLMMessage(
            stepID: "swe", taskID: 0, role: .assistant, content: "", thinking: "just reasoning")

        XCTAssertEqual(currentStep()?.llmConversation.count, 1)
        XCTAssertEqual(currentStep()?.llmConversation.first?.content, "")
        XCTAssertEqual(currentStep()?.llmConversation.first?.thinking, "just reasoning")
    }

    func testAppendLLMMessage_carriesSourceAttribution() async {
        installLiveTask()

        await service.appendLLMMessage(
            stepID: "swe", taskID: 0, role: .user, content: MessageSourceContext.supervisorMessagePrefix + "Do X",
            sourceRole: .supervisor, sourceContext: .supervisorMessage)

        let msg = currentStep()?.llmConversation.first
        XCTAssertEqual(msg?.sourceRole, .supervisor)
        XCTAssertEqual(msg?.sourceContext, .supervisorMessage)
    }

    func testAppendLLMMessage_afterTeardown_isANoOp() async {
        installLiveTask()
        service.clearRunningTask(stepID: "swe", taskID: 0)

        await service.appendLLMMessage(
            stepID: "swe", taskID: 0, role: .system, content: "late note")

        XCTAssertTrue(currentStep()?.llmConversation.isEmpty ?? false)
    }

    // MARK: - appendOrReplaceRetryNotice

    func testAppendOrReplaceRetryNotice_collapsesABurstIntoOneLiveBubble() async {
        installLiveTask()

        await service.appendOrReplaceRetryNotice(
            stepID: "swe", taskID: 0, content: "Retrying in 10s… (1/3)")
        await service.appendOrReplaceRetryNotice(
            stepID: "swe", taskID: 0, content: "Retrying in 10s… (2/3)")
        await service.appendOrReplaceRetryNotice(
            stepID: "swe", taskID: 0, content: "Retrying in 10s… (3/3)")

        let conv = currentStep()?.llmConversation ?? []
        XCTAssertEqual(conv.count, 1, "A retry burst is ONE live-updating note, not N bubbles")
        XCTAssertEqual(conv.first?.content, "Retrying in 10s… (3/3)")
        XCTAssertEqual(conv.first?.sourceContext, .serverError)
    }

    func testAppendOrReplaceRetryNotice_afterTeardown_isANoOp() async {
        installLiveTask()
        service.clearRunningTask(stepID: "swe", taskID: 0)

        await service.appendOrReplaceRetryNotice(stepID: "swe", taskID: 0, content: "late")

        XCTAssertTrue(currentStep()?.llmConversation.isEmpty ?? false)
    }

    // MARK: - saveLLMConversation

    func testSaveLLMConversation_replacesTheDisplayRecord_withStrictlyIncreasingTimestamps() async {
        var task = installLiveTask()
        task.runs[0].steps[0].llmConversation = [
            LLMMessage(role: .assistant, content: "stale entry"),
        ]
        delegate.taskToMutate = task

        await service.saveLLMConversation(
            stepID: "swe", taskID: 0,
            messages: [
                ChatMessage(role: .system, content: "sys"),
                ChatMessage(role: .user, content: "u"),
                ChatMessage(role: .assistant, content: "a"),
            ])

        let conv = currentStep()?.llmConversation ?? []
        XCTAssertEqual(conv.count, 3, "The save is a whole-array REPLACE, not an append")
        XCTAssertEqual(conv.map(\.content), ["sys", "u", "a"])
        XCTAssertEqual(conv.map(\.role), [.system, .user, .assistant])
        let stamps = conv.map(\.createdAt)
        XCTAssertEqual(
            stamps, stamps.sorted(),
            "The per-index offset must keep the feed's ordering stable")
        XCTAssertEqual(
            Set(stamps).count, stamps.count,
            "…and strictly so — two identical stamps make the feed order arbitrary")
    }

    func testSaveLLMConversation_nilContent_becomesEmptyStringNotACrash() async {
        installLiveTask()

        await service.saveLLMConversation(
            stepID: "swe", taskID: 0,
            messages: [ChatMessage(role: .assistant, content: nil)])

        XCTAssertEqual(currentStep()?.llmConversation.count, 1)
        XCTAssertEqual(currentStep()?.llmConversation.first?.content, "")
    }

    func testSaveLLMConversation_afterTeardown_isANoOp() async {
        var task = installLiveTask()
        task.runs[0].steps[0].llmConversation = [LLMMessage(role: .assistant, content: "keep me")]
        delegate.taskToMutate = task
        service.clearRunningTask(stepID: "swe", taskID: 0)

        await service.saveLLMConversation(
            stepID: "swe", taskID: 0, messages: [ChatMessage(role: .user, content: "late")])

        XCTAssertEqual(
            currentStep()?.llmConversation.first?.content, "keep me",
            "A destructive whole-array replace from a dead execution would erase the real record")
    }

    // MARK: - BashGate: under-Autovisor / malformed args / mixed batches

    private func autovisorSnapshot(managerTaskID: Int) {
        let team = makeTeam(roles: [makeSupervisorRole()])
        installSnapshot(
            teams: [team], autovisorEnabled: true, autovisorTaskID: managerTaskID)
    }

    private func bashCall(_ command: String, providerID: String) -> StepToolCall {
        StepToolCall(
            providerID: providerID, name: ToolNames.bash,
            argumentsJSON: "{\"command\":\"\(command)\"}")
    }

    private func errorCode(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any]
        else { return nil }
        return err["code"] as? String
    }

    func testIsUnderAutovisor_isFalseWithoutASnapshot() async {
        delegate.snapshot = nil
        let task = NTMSTask(id: 7, title: "T", supervisorTask: "G", runs: [])

        XCTAssertFalse(service.isUnderAutovisor(task: task))
    }

    func testIsUnderAutovisor_topLevelTaskUnderAnEnabledManager_isTrue() async {
        autovisorSnapshot(managerTaskID: 99)
        let task = NTMSTask(id: 7, title: "T", supervisorTask: "G", runs: [])

        XCTAssertTrue(service.isUnderAutovisor(task: task))
    }

    func testIsUnderAutovisor_theManagersOwnTask_isFalse() async {
        autovisorSnapshot(managerTaskID: 7)
        let task = NTMSTask(id: 7, title: "T", supervisorTask: "G", runs: [])

        XCTAssertFalse(
            service.isUnderAutovisor(task: task),
            "The manager does not supervise itself")
    }

    func testIsUnderAutovisor_delegationChild_isFalse() async {
        autovisorSnapshot(managerTaskID: 99)
        let task = NTMSTask(
            id: 7, title: "T", supervisorTask: "G", runs: [],
            parentTaskID: 1, parentRoleID: "pm", delegationDepth: 1)

        XCTAssertFalse(
            service.isUnderAutovisor(task: task),
            "Delegation children keep their own routing")
    }

    func testGateBashCalls_manualModeUnderAutovisor_refusesAsApprovalUnavailableInsteadOfHoldingForAHuman() async {
        // Manual bash mode but the folder's Supervisor is the Autovisor — nobody is at the
        // keyboard, so holding the command would wedge the run forever. Nobody decided
        // either, so the refusal carries its own code, not BASH_DENIED (in production the
        // resolver withholds `bash` for this cell; the gate is reached here directly).
        autovisorSnapshot(managerTaskID: 99)
        delegate.bashPolicy = BashPolicy(mode: .manual)
        let task = NTMSTask(id: 7, title: "T", supervisorTask: "G", runs: [])

        let results = await service.gateBashCalls(
            resolvedToolCalls: [bashCall("make install", providerID: "c1")],
            allowedToolNames: [ToolNames.bash],
            stepID: "swe", taskID: 7, supervisorMode: .manual, task: task,
            client: StubStreamingClient(), config: LLMConfig(), networkLogger: nil)

        XCTAssertEqual(results[0]?.isError, true)
        XCTAssertEqual(errorCode(results[0]?.outputJSON ?? ""), ToolErrorCode.approvalUnavailable.rawValue)
        XCTAssertTrue(
            results[0]?.outputJSON.contains("no human") ?? false,
            "The refusal must name the actual blocker so the MODEL knows why it was refused — "
                + "this envelope is model-only; the user never reads it")
        XCTAssertNil(service.pendingBashApproval(stepID: "swe", taskID: 7))
        XCTAssertTrue(delegate.bashApprovalBeganRequests.isEmpty, "Nothing may be held")
    }

    func testGateBashCalls_argumentsWithNoResolvableCommand_arePassedToTheHandler() async {
        // Even in `.off` mode (which denies EVERY command) an unresolvable arg set is left
        // alone — the handler owns the INVALID_ARGS reply, and the gate must not fabricate
        // a denial for a command it could not read.
        delegate.snapshot = nil
        delegate.bashPolicy = BashPolicy(mode: .off)
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "G", runs: [])
        let call = StepToolCall(providerID: "c1", name: ToolNames.bash, argumentsJSON: "{}")

        let results = await service.gateBashCalls(
            resolvedToolCalls: [call],
            allowedToolNames: [ToolNames.bash],
            stepID: "swe", taskID: 1, supervisorMode: .autonomous, task: task,
            client: StubStreamingClient(), config: LLMConfig(), networkLogger: nil)

        XCTAssertTrue(results.isEmpty)
    }

    func testGateBashCalls_undecodableArgumentsJSON_isPassedToTheHandler() async {
        delegate.snapshot = nil
        delegate.bashPolicy = BashPolicy(mode: .off)
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "G", runs: [])
        let call = StepToolCall(
            providerID: "c1", name: ToolNames.bash, argumentsJSON: "{not json")

        let results = await service.gateBashCalls(
            resolvedToolCalls: [call],
            allowedToolNames: [ToolNames.bash],
            stepID: "swe", taskID: 1, supervisorMode: .autonomous, task: task,
            client: StubStreamingClient(), config: LLMConfig(), networkLogger: nil)

        XCTAssertTrue(results.isEmpty)
    }

    func testGateBashCalls_mixedBatch_synthesizesOnlyForTheDeniedIndices() async {
        delegate.snapshot = nil
        delegate.bashPolicy = BashPolicy(
            mode: .semiAutomatic, allowRules: ["make"], denyRules: ["rm"])
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "G", runs: [])
        let calls = [
            bashCall("make build", providerID: "c0"),   // allow rule → runs
            bashCall("rm -rf /tmp/x", providerID: "c1"), // deny rule → synthetic
            bashCall("ls -la", providerID: "c2"),        // read-only → runs
        ]

        let results = await service.gateBashCalls(
            resolvedToolCalls: calls,
            allowedToolNames: [ToolNames.bash],
            stepID: "swe", taskID: 1, supervisorMode: .autonomous, task: task,
            client: StubStreamingClient(), config: LLMConfig(), networkLogger: nil)

        XCTAssertEqual(Set(results.keys), [1], "The sparse map must carry ONLY intercepted indices")
        XCTAssertEqual(results[1]?.isError, true)
        XCTAssertEqual(
            results[1]?.providerID, "c1",
            "Chain integrity: the synthetic result answers the call it replaced, never a sibling")
    }

    func testPendingBashApproval_isNilWhenNothingIsHeld() async {
        XCTAssertNil(service.pendingBashApproval(stepID: "swe", taskID: 0))
    }

    // MARK: - SupervisorAutoAnswerService: the real generation path

    private func autoAnswerTask(priorQuestion: String? = nil, brief: String = "Build a calculator")
        -> NTMSTask
    {
        var prior = StepExecution(id: "pm", role: .productManager, title: "PM", status: .done)
        prior.supervisorQuestion = priorQuestion
        let current = StepExecution(
            id: "swe", role: .softwareEngineer, title: "Engineer", status: .running)
        return NTMSTask(
            id: 0, title: "Calculator", supervisorTask: brief,
            runs: [Run(id: 0, steps: [prior, current])])
    }

    func testGenerateAnswer_returnsTheTrimmedStreamedDecision() async {
        let client = CapturingChatClient(chunks: ["  Use ", "SwiftUI.  "])

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "Which UI framework?",
            task: autoAnswerTask(), runIndex: 0, stepIndex: 1,
            client: client, config: LLMConfig(), artifactReader: { _ in nil })

        XCTAssertEqual(answer, "Use SwiftUI.")
    }

    func testGenerateAnswer_emptyStream_returnsTheFallback() async {
        let client = CapturingChatClient(chunks: [])

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "Which UI framework?",
            task: autoAnswerTask(), runIndex: 0, stepIndex: 1,
            client: client, config: LLMConfig(), artifactReader: { _ in nil })

        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    func testGenerateAnswer_whitespaceOnlyStream_returnsTheFallback() async {
        let client = CapturingChatClient(chunks: ["   ", "\n\t"])

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "Which UI framework?",
            task: autoAnswerTask(), runIndex: 0, stepIndex: 1,
            client: client, config: LLMConfig(), artifactReader: { _ in nil })

        XCTAssertEqual(
            answer, SupervisorAutoAnswerService.fallbackAnswer,
            "A blank reply must not be delivered to the blocked role as a decision")
    }

    func testGenerateAnswer_streamFailure_returnsTheFallback() async {
        let client = ThrowingChatClient()

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "Which UI framework?",
            task: autoAnswerTask(), runIndex: 0, stepIndex: 1,
            client: client, config: LLMConfig(), artifactReader: { _ in nil })

        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    func testGenerateAnswer_userTurnPutsTheQuestionAndOutputContractLast() async {
        // Chunks early, question + constraints at the END [Liu2024] — the context blob must
        // not sit between the question and the tail.
        let client = CapturingChatClient(chunks: ["ok"])

        _ = await SupervisorAutoAnswerService.generateAnswer(
            question: "Which UI framework?",
            task: autoAnswerTask(priorQuestion: "CTX-SENTINEL"),
            runIndex: 0, stepIndex: 1,
            client: client, config: LLMConfig(), artifactReader: { _ in nil })

        XCTAssertEqual(client.captured.count, 1)
        let messages = client.captured[0].messages
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.first?.content, SupervisorAutoAnswerService.systemPrompt)
        XCTAssertEqual(messages.count, 2, "One-shot: system + user, nothing else")

        let user = messages[1].content ?? ""
        XCTAssertTrue(user.contains("## Task\nCalculator"))
        XCTAssertTrue(user.contains("## Supervisor Task\nBuild a calculator"))
        XCTAssertTrue(user.contains("## Current role\n\(Role.softwareEngineer.displayName)"))
        guard let contextRange = user.range(of: "CTX-SENTINEL"),
              let questionRange = user.range(of: "## Question\nWhich UI framework?")
        else {
            return XCTFail("Both the pipeline context and the question must be present:\n\(user)")
        }
        XCTAssertTrue(
            contextRange.upperBound < questionRange.lowerBound,
            "The context blob must precede the question, never split it from the tail")
        XCTAssertTrue(
            user.hasSuffix("If information is missing, make a reasonable assumption and state it."),
            "The output contract is the last thing the model reads")
    }

    func testGenerateAnswer_blankSupervisorBrief_omitsTheBriefLineEntirely() async {
        let client = CapturingChatClient(chunks: ["ok"])

        _ = await SupervisorAutoAnswerService.generateAnswer(
            question: "Q?", task: autoAnswerTask(brief: "   \n  "),
            runIndex: 0, stepIndex: 1,
            client: client, config: LLMConfig(), artifactReader: { _ in nil })

        let user = client.captured[0].messages[1].content ?? ""
        XCTAssertFalse(
            user.contains("Supervisor Task:"),
            "An empty brief must not ship a bare `Supervisor Task:` label")
    }

    func testGenerateAnswer_firstStep_sendsNoContextSection() async {
        let client = CapturingChatClient(chunks: ["ok"])

        _ = await SupervisorAutoAnswerService.generateAnswer(
            question: "Q?", task: autoAnswerTask(priorQuestion: "CTX-SENTINEL"),
            runIndex: 0, stepIndex: 0,
            client: client, config: LLMConfig(), artifactReader: { _ in nil })

        let user = client.captured[0].messages[1].content ?? ""
        XCTAssertFalse(user.contains("## Prior Steps"), "Step 0 has no prior steps to summarize")
        XCTAssertFalse(user.contains("CTX-SENTINEL"))
    }

    func testGenerateAnswer_oversizedPipelineContext_isTruncatedAtTheArtifactCap() async {
        let filler = String(repeating: "a", count: ArtifactConstants.maxDescriptionChars + 500)
        let client = CapturingChatClient(chunks: ["ok"])

        _ = await SupervisorAutoAnswerService.generateAnswer(
            question: "Q?",
            task: autoAnswerTask(priorQuestion: filler + "TAIL-SENTINEL"),
            runIndex: 0, stepIndex: 1,
            client: client, config: LLMConfig(), artifactReader: { _ in nil })

        let user = client.captured[0].messages[1].content ?? ""
        XCTAssertFalse(
            user.contains("TAIL-SENTINEL"),
            "The context blob is capped at ArtifactConstants.maxDescriptionChars")
        XCTAssertTrue(user.contains("(earlier context truncated)"), "…and the cut is marked, not silent")
        XCTAssertTrue(user.contains("## Question\nQ?"), "The question always survives the cut")
    }

    func testGenerateAnswer_advertisesNoTools() async {
        // A one-shot side call must never hand the model a toolset it cannot use.
        let client = CapturingChatClient(chunks: ["ok"])

        _ = await SupervisorAutoAnswerService.generateAnswer(
            question: "Q?", task: autoAnswerTask(), runIndex: 0, stepIndex: 1,
            client: client, config: LLMConfig(), artifactReader: { _ in nil })

        XCTAssertTrue(client.captured[0].tools.isEmpty)
    }

    // MARK: - DelegatedSupervisorAnswerService: failure + degenerate answers

    private func delegationFixture(
        parentSeed: [LLMMessage] = [LLMMessage(role: .system, content: "You are PM.")]
    ) -> (delegate: DelegatedSupervisorAnswerServiceTests.MultiTaskDelegateStub, team: Team) {
        let stub = DelegatedSupervisorAnswerServiceTests.MultiTaskDelegateStub()
        let pm = makeRole(id: "pm", name: "PM")
        let team = makeTeam(id: "parent-team", name: "Parent Team", roles: [makeSupervisorRole(), pm])
        stub.workFolderProjection = WorkFolderProjection(
            state: WorkFolderState(name: "WF", activeTeamID: team.id),
            settings: ProjectSettings(),
            teams: [team])

        var parentStep = StepExecution(id: "pm", role: .productManager, title: "PM", status: .running)
        parentStep.llmConversation = parentSeed
        stub.tasks[1] = NTMSTask(
            id: 1, title: "Parent", supervisorTask: "Build",
            runs: [Run(id: 0, steps: [parentStep])],
            preferredTeamID: team.id)

        var childStep = StepExecution(
            id: "engineer", role: .softwareEngineer, title: "Engineer",
            status: .needsSupervisorInput)
        childStep.needsSupervisorInput = true
        childStep.supervisorQuestion = "Should we support negatives?"
        stub.tasks[2] = NTMSTask(
            id: 2, title: "Child", supervisorTask: "Implement",
            runs: [Run(id: 0, steps: [childStep])],
            parentTaskID: 1, parentRoleID: "pm", delegationDepth: 1)

        return (stub, team)
    }

    func testHandleChildQuestion_streamFailure_surfacesTheCauseAndAborts() async {
        // A bare `return nil` here swallowed 401 / model-unloaded / transport failures and the
        // caller reported a generic "Failed to answer" with no diagnostic.
        let (stub, team) = delegationFixture()

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm",
            parentTeam: team, targetTeamName: "Engineering",
            client: ThrowingChatClient(), globalConfig: stub.globalLLMConfig, delegate: stub)

        XCTAssertFalse(success)
        XCTAssertEqual(stub.lastErrorMessages.count, 1)
        XCTAssertTrue(
            stub.lastErrorMessages.first?.contains("pm") ?? false,
            "The banner must name the role whose exchange failed")
        XCTAssertTrue(stub.answerSupervisorCalls.isEmpty, "Nothing may be delivered to the child")
    }

    func testHandleChildQuestion_emptyAnswer_deliversAnExplicitPlaceholder() async {
        let (stub, team) = delegationFixture()
        let client = DelegatedSupervisorAnswerServiceTests.ScriptedLLMClient()
        client.script = [.init(content: "", toolCalls: [])]

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm",
            parentTeam: team, targetTeamName: "Engineering",
            client: client, globalConfig: stub.globalLLMConfig, delegate: stub)

        XCTAssertTrue(success)
        XCTAssertEqual(stub.answerSupervisorCalls.count, 1)
        XCTAssertEqual(
            stub.answerSupervisorCalls.first?.answer, "(no answer provided)",
            "An empty body must reach the child as an explicit non-answer, never as \"\"")
    }

    func testHandleChildQuestion_parentStepMissing_returnsFalseWithoutDelivering() async {
        let (stub, team) = delegationFixture()
        // The parent's run exists but carries no step with the delegating role's id.
        stub.tasks[1] = NTMSTask(
            id: 1, title: "Parent", supervisorTask: "Build",
            runs: [Run(id: 0, steps: [])], preferredTeamID: team.id)
        let client = DelegatedSupervisorAnswerServiceTests.ScriptedLLMClient()
        client.script = [.init(content: "irrelevant", toolCalls: [])]

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm",
            parentTeam: team, targetTeamName: "Engineering",
            client: client, globalConfig: stub.globalLLMConfig, delegate: stub)

        XCTAssertFalse(success)
        XCTAssertTrue(client.captures.isEmpty, "No step ⇒ no LLM call at all")
        XCTAssertTrue(stub.answerSupervisorCalls.isEmpty)
    }

    func testHandleChildQuestion_whitespaceOnlyChildQuestion_returnsFalse() async {
        let (stub, team) = delegationFixture()
        var child = stub.tasks[2]!
        child.runs[0].steps[0].supervisorQuestion = "   \n  "
        stub.tasks[2] = child
        let client = DelegatedSupervisorAnswerServiceTests.ScriptedLLMClient()

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm",
            parentTeam: team, targetTeamName: "Engineering",
            client: client, globalConfig: stub.globalLLMConfig, delegate: stub)

        XCTAssertFalse(success)
        XCTAssertTrue(client.captures.isEmpty)
    }

    func testHandleChildQuestion_topOfChainEscalationWithMalformedArgs_recordsTheOriginalQuestion() async {
        // `extractQuestion` returns nil on unparseable args — the original question is the
        // documented fallback payload, so the ancillary log is never blank.
        let (stub, team) = delegationFixture()
        let client = DelegatedSupervisorAnswerServiceTests.ScriptedLLMClient()
        client.script = [
            .init(
                content: "",
                toolCalls: [(name: ToolNames.askSupervisor, argumentsJSON: "{not json")]),
        ]

        let success = await DelegatedSupervisorAnswerService.handleChildQuestion(
            childTID: 2, parentTaskID: 1, parentRoleID: "pm",
            parentTeam: team, targetTeamName: "Engineering",
            client: client, globalConfig: stub.globalLLMConfig, delegate: stub)

        XCTAssertFalse(success, "A top-of-chain escalation aborts the delegation")
        let parentStep = stub.tasks[1]?.runs.last?.steps.first(where: { $0.id == "pm" })
        XCTAssertEqual(
            parentStep?.ancillaryQuestion, "Should we support negatives?",
            "Malformed escalation args fall back to the question that was being answered")
        XCTAssertEqual(stub.lastInfoMessages.count, 1)
        XCTAssertTrue(stub.answerSupervisorCalls.isEmpty)
    }

    // MARK: - resolveToolSchemas: the approval-gated families (B3, 2026-09-07)

    private func shellAndComputerUseRole() -> TeamRoleDefinition {
        makeRole(
            id: "swe", name: "SWE",
            toolIDs: [ToolNames.readFile, ToolNames.bash, ToolNames.bashOutput]
                + Array(ToolHandlerRegistry.computerUseTools),
            produces: ["Engineering Notes"])
    }

    private func names(approval: ToolApprovalAvailability) -> Set<String> {
        let role = shellAndComputerUseRole()
        let team = makeTeam(roles: [makeSupervisorRole(requires: ["Engineering Notes"]), role])
        return Set(LLMExecutionService.resolveToolSchemas(forDefinition: role, team: team, approval: approval).map(\.name))
    }

    /// Manual with no human: every command would wait for a human, so the tool is withheld —
    /// the 2026-09-07 audit's `bash` cost a model turn per refusal while advertised.
    func testResolve_bashManualWithNoHuman_withholdsBothShellTools() {
        let n = names(approval: ToolApprovalAvailability(bashMode: .manual, computerUseMode: .auto, humanPresent: false))
        XCTAssertFalse(n.contains(ToolNames.bash))
        XCTAssertFalse(n.contains(ToolNames.bashOutput))
        XCTAssertTrue(n.contains(ToolNames.readFile), "only the shell family is withheld")
    }

    func testResolve_bashManualWithAHuman_keepsTheShellTools() {
        let n = names(approval: ToolApprovalAvailability(bashMode: .manual, computerUseMode: .auto, humanPresent: true))
        XCTAssertTrue(n.contains(ToolNames.bash))
        XCTAssertTrue(n.contains(ToolNames.bashOutput))
    }

    /// Semi-automatic keeps the tool with no human: its read-only commands run, and the gate
    /// refuses the rest per command — a per-tool strip cannot say that.
    func testResolve_bashSemiAutomaticWithNoHuman_keepsTheShellTools() {
        let n = names(approval: ToolApprovalAvailability(bashMode: .semiAutomatic, computerUseMode: .auto, humanPresent: false))
        XCTAssertTrue(n.contains(ToolNames.bash))
        XCTAssertTrue(n.contains(ToolNames.bashOutput))
    }

    func testResolve_bashAuto_keepsTheShellTools_whoeverIsPresent() {
        for present in [true, false] {
            let n = names(approval: ToolApprovalAvailability(bashMode: .auto, computerUseMode: .auto, humanPresent: present))
            XCTAssertTrue(n.contains(ToolNames.bash), "present=\(present)")
        }
    }

    /// Off used to be caught only at runtime (`.bashDisabled`); the schema now withholds it
    /// like the computer-use family's Off always did.
    func testResolve_bashOff_withholdsBothShellTools_whoeverIsPresent() {
        for present in [true, false] {
            let n = names(approval: ToolApprovalAvailability(bashMode: .off, computerUseMode: .auto, humanPresent: present))
            XCTAssertFalse(n.contains(ToolNames.bash), "present=\(present)")
            XCTAssertFalse(n.contains(ToolNames.bashOutput), "present=\(present)")
        }
    }

    func testResolve_computerUseManualWithNoHuman_withholdsAllFive() {
        let n = names(approval: ToolApprovalAvailability(bashMode: .auto, computerUseMode: .manual, humanPresent: false))
        XCTAssertTrue(n.isDisjoint(with: ToolHandlerRegistry.computerUseTools), "got \(n.intersection(ToolHandlerRegistry.computerUseTools))")
    }

    /// Semi-automatic with no human: the read-only tier (capture, scroll) ships, the mutating
    /// trio does not — the family's granularity is per tool, so the strip can say exactly that.
    func testResolve_computerUseSemiAutomaticWithNoHuman_keepsTheReadOnlyTier_withholdsTheTrio() {
        let n = names(approval: ToolApprovalAvailability(bashMode: .auto, computerUseMode: .semiAutomatic, humanPresent: false))
        XCTAssertTrue(n.contains(ToolNames.screenCapture))
        XCTAssertTrue(n.contains(ToolNames.uiScroll))
        XCTAssertTrue(n.isDisjoint(with: ToolHandlerRegistry.computerUseMutatingTools),
                      "got \(n.intersection(ToolHandlerRegistry.computerUseMutatingTools))")
    }

    func testResolve_computerUseSemiAutomaticWithAHuman_keepsAllFive() {
        let n = names(approval: ToolApprovalAvailability(bashMode: .auto, computerUseMode: .semiAutomatic, humanPresent: true))
        XCTAssertTrue(ToolHandlerRegistry.computerUseTools.isSubset(of: n))
    }

    func testResolve_computerUseAuto_keepsAllFive_whoeverIsPresent() {
        for present in [true, false] {
            let n = names(approval: ToolApprovalAvailability(bashMode: .auto, computerUseMode: .auto, humanPresent: present))
            XCTAssertTrue(ToolHandlerRegistry.computerUseTools.isSubset(of: n), "present=\(present)")
        }
    }

    func testResolve_computerUseOff_withholdsAllFive_whoeverIsPresent() {
        for present in [true, false] {
            let n = names(approval: ToolApprovalAvailability(bashMode: .auto, computerUseMode: .off, humanPresent: present))
            XCTAssertTrue(n.isDisjoint(with: ToolHandlerRegistry.computerUseTools), "present=\(present)")
        }
    }

    /// The Autovisor-supervised reading is the same cell as autonomous: `ApprovalPresence`
    /// says no human, and the resolver reads only the pair — pinned through `forTeam`.
    func testResolve_underAutovisor_readsAsNoHuman() {
        var team = makeTeam(roles: [makeSupervisorRole(requires: ["Engineering Notes"]), shellAndComputerUseRole()])
        team.settings.supervisorMode = .manual
        var activation = AutovisorActivation.default
        activation.onTaskNeedsSupervisor = true
        let approval = ToolApprovalAvailability.forTeam(
            bashMode: .manual, computerUseMode: .manual, team: team,
            workFolderSettings: ProjectSettings(autovisorEnabled: true, autovisorActivation: activation))
        let n = names(approval: approval)
        XCTAssertFalse(n.contains(ToolNames.bash))
        XCTAssertTrue(n.isDisjoint(with: ToolHandlerRegistry.computerUseTools))
    }

}

// MARK: - Private doubles

/// `NetworkSession` stub for the preflight probe. Records the request so a test can
/// prove a malformed URL never reached the network.
private final class StubPreflightSession: NetworkSession, @unchecked Sendable {
    var statusCode: Int = 200
    var errorToThrow: Error?
    var returnsNonHTTPResponse = false
    var capturedRequest: URLRequest?

    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request
        if let errorToThrow { throw errorToThrow }
        if returnsNonHTTPResponse {
            return (Data(), URLResponse(
                url: request.url!, mimeType: nil,
                expectedContentLength: 0, textEncodingName: nil))
        }
        return (Data(), HTTPURLResponse(
            url: request.url!, statusCode: statusCode,
            httpVersion: nil, headerFields: nil)!)
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw URLError(.unsupportedURL)
    }
}

/// Collects the system messages `preflightDecision` posts through its callback.
private actor PreflightMessageCollector {
    private(set) var messages: [String] = []
    func add(_ s: String) { messages.append(s) }
}

/// Deterministic `LLMClient` that yields fixed content deltas and records what it was sent.
private final class CapturingChatClient: LLMClient, @unchecked Sendable {
    let chunks: [String]
    var captured: [(messages: [ChatMessage], tools: [ToolSchema])] = []

    init(chunks: [String]) { self.chunks = chunks }

    func streamChat(
        config _: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        captured.append((messages, tools))
        let deltas = chunks
        return AsyncThrowingStream { continuation in
            for chunk in deltas {
                continuation.yield(StreamEvent(contentDelta: chunk))
            }
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

private struct StubStreamFailure: Error, LocalizedError {
    var errorDescription: String? { "stub stream failure" }
}

/// `LLMClient` whose stream always fails — drives the catch arms without touching the network.
private final class ThrowingChatClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: StubStreamFailure())
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

/// `LLMClient` that yields nothing — used where the gate must never reach the judge.
private final class StubStreamingClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }

}
