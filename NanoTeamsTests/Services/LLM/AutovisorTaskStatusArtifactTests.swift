import XCTest
@testable import NanoTeams

/// Pins the `task_status` artifact contract: each produced artifact is reported as
/// a `read_file`-able PATH, not an inlined (and size-capped, occasionally
/// `[unreadable]`) content snippet.
///
/// Artifacts are always persisted, so the path is a reliable reference; the manager
/// pulls the FULL artifact on demand via `read_file`. The path is
/// `.nanoteams/<relativePath>` (relativePath is stored relative to `.nanoteams/`),
/// which the sandbox permits (only `.nanoteams/internal/` is blocked).
@MainActor
final class AutovisorTaskStatusArtifactTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    /// Two artifacts on two roles of a top-level task (mirrors reported run #7).
    /// `task_status` reports each as a `.nanoteams/...` path — no content inlined,
    /// no `[unreadable]` sentinel (it never reads the file). Asserts on the DECODED
    /// envelope so the check is independent of JSON forward-slash escaping.
    func testHandleTaskStatus_exposesReadableArtifactPath_notInlinedContent() async throws {
        let planRel = "tasks/7/runs/0/roles/engineering_team_tech_lead/artifact_implementation_plan.md"
        let notesRel = "tasks/7/runs/0/roles/engineering_team_software_engineer/artifact_engineering_notes.md"

        let tlStep = StepExecution(
            id: "engineering_team_tech_lead", role: .codingAgent, title: "Tech Lead",
            status: .done,
            artifacts: [Artifact(name: "Implementation Plan", relativePath: planRel)]
        )
        let swStep = StepExecution(
            id: "engineering_team_software_engineer", role: .codingAgent, title: "Software Engineer",
            status: .running,
            artifacts: [Artifact(name: "Engineering Notes", relativePath: notesRel)]
        )
        let task = NTMSTask(id: 7, title: "Feature Expansion: Editing and Search",
                            supervisorTask: "...", runs: [Run(id: 0, steps: [tlStep, swStep])])
        mockDelegate.taskToMutate = task   // loadedTask(7) → autovisorLoadTask(7) → task

        let json = await service.handleTaskStatus(taskID: 7)
        XCTAssertFalse(json.contains("[unreadable"),
            "task_status hands back a path; it must never inline+fail-read content.")

        let artifacts = try Self.decodeArtifacts(from: json)
        let byName = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0.path) })
        XCTAssertEqual(byName["Implementation Plan"], ".nanoteams/\(planRel)",
            "Implementation Plan must be reported as a read_file-able .nanoteams/ path.")
        XCTAssertEqual(byName["Engineering Notes"], ".nanoteams/\(notesRel)",
            "Engineering Notes must be reported as a read_file-able .nanoteams/ path.")
    }

    /// An artifact with no persisted file (no relativePath) simply omits `path`
    /// rather than crashing or emitting a bogus reference.
    func testHandleTaskStatus_artifactWithoutPersistedFile_omitsPath() async throws {
        let step = StepExecution(
            id: "engineering_team_tech_lead", role: .codingAgent, title: "Tech Lead",
            status: .running,
            artifacts: [Artifact(name: "Draft", relativePath: nil)]
        )
        let task = NTMSTask(id: 8, title: "T", supervisorTask: "...",
                            runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task

        let json = await service.handleTaskStatus(taskID: 8)
        XCTAssertFalse(json.contains("[unreadable"), "No file → no unreadable sentinel.")

        let artifacts = try Self.decodeArtifacts(from: json)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?.name, "Draft", "Artifact name must still be reported.")
        XCTAssertNil(artifacts.first?.path, "An artifact with no persisted file must omit path.")
    }

    /// Two artifacts on a SINGLE step: a normal deliverable (readable `.nanoteams/tasks`
    /// path) and a Build-Diagnostics artifact persisted under `.nanoteams/internal/`
    /// (which `read_file` rejects via the sandbox). The internal one must OMIT `path` —
    /// a non-nil path is a promise of readability, so we never hand the manager a
    /// reference it can't read. Also exercises the inner per-step artifact loop at
    /// cardinality > 1.
    func testHandleTaskStatus_internalArtifactOmitsPath_andListsAllPerStep() async throws {
        let notesRel = "tasks/7/runs/0/roles/engineering_team_software_engineer/artifact_engineering_notes.md"
        let diagRel = "internal/tasks/7/runs/0/roles/engineering_team_software_engineer/build_diagnostics.json"
        let step = StepExecution(
            id: "engineering_team_software_engineer", role: .codingAgent, title: "Software Engineer",
            status: .done,
            artifacts: [
                Artifact(name: "Engineering Notes", relativePath: notesRel),
                Artifact(name: "Build Diagnostics", relativePath: diagRel)
            ]
        )
        let task = NTMSTask(id: 7, title: "T", supervisorTask: "...",
                            runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task

        let json = await service.handleTaskStatus(taskID: 7)
        let artifacts = try Self.decodeArtifacts(from: json)
        let notes = artifacts.first { $0.name == "Engineering Notes" }
        let diag = artifacts.first { $0.name == "Build Diagnostics" }

        XCTAssertEqual(artifacts.count, 2, "Both artifacts on the step must be listed (inner loop).")
        XCTAssertEqual(notes?.path, ".nanoteams/\(notesRel)",
            "A normal deliverable keeps its read_file-able path.")
        XCTAssertNotNil(diag, "Build Diagnostics must still be listed by name.")
        XCTAssertNil(diag?.path,
            "An internal (.nanoteams/internal/…) artifact must omit path — read_file can't read it.")
    }

    // MARK: - Timing / stuck contract

    /// A long-silent `.running` role surfaces the timing + stuck contract the manager
    /// prompt depends on by name: `idle_seconds` (present while running), `elapsed_seconds`,
    /// and a `stuck` row with `kind == "hang"` at both step and task level.
    func testHandleTaskStatus_hungRunningStep_reportsTimingAndHang() async throws {
        // createdAt well past the hang threshold relative to the handler's real `Date()`.
        let old = Date(timeIntervalSinceNow: -(AutovisorConstants.stuckHangSeconds + 120))
        let step = StepExecution(
            id: "engineering_team_software_engineer", role: .codingAgent, title: "SWE",
            status: .running, createdAt: old, updatedAt: old
        )
        let task = NTMSTask(id: 9, title: "T", supervisorTask: "...",
                            runs: [Run(id: 0, createdAt: old, steps: [step])])
        mockDelegate.taskToMutate = task   // streamLastActivityStub is empty → live signal nil → hang

        let json = await service.handleTaskStatus(taskID: 9)
        let status = try Self.decodeStatus(from: json)

        XCTAssertEqual(status.stuck?.kind, "hang", "task-level stuck verdict must be hang")
        XCTAssertNotNil(status.stuck?.detail, "the actionable diagnostic must round-trip to the wire row")
        let row = try XCTUnwrap(status.steps.first)
        XCTAssertEqual(row.stuck?.kind, "hang")
        XCTAssertNotNil(row.stuck?.detail)
        XCTAssertNotNil(row.idle_seconds, "idle_seconds present while running")
        XCTAssertGreaterThan(row.idle_seconds ?? 0, Int(AutovisorConstants.stuckHangSeconds))
        XCTAssertGreaterThanOrEqual(row.elapsed_seconds, Int(AutovisorConstants.stuckHangSeconds))
    }

    /// The hang threshold is read from `settings.autovisorTuning`, NOT the constant.
    /// A step idle ~120s is hung under a CONFIGURED 60s threshold but NOT under the
    /// 180s default — so a `hang` verdict here proves settings are consumed. (The
    /// sibling test above runs with a nil snapshot ⇒ `.default` ⇒ can't tell the two
    /// apart; this one pins the read-site at `LLMExecutionService+Autovisor.swift`.)
    func testHandleTaskStatus_usesConfiguredHangThreshold_notConstant() async throws {
        let old = Date(timeIntervalSinceNow: -120)   // idle ~120s: > configured 60, < default 180
        let step = StepExecution(
            id: "engineering_team_software_engineer", role: .codingAgent, title: "SWE",
            status: .running, createdAt: old, updatedAt: old
        )
        let task = NTMSTask(id: 11, title: "T", supervisorTask: "...",
                            runs: [Run(id: 0, createdAt: old, steps: [step])])
        mockDelegate.taskToMutate = task
        // Lower the hang threshold below the idle time; the constant default (180s)
        // is ABOVE it, so a `hang` verdict can only come from reading this value.
        mockDelegate.snapshot = Self.contextWithHangThreshold(60)

        let json = await service.handleTaskStatus(taskID: 11)
        let status = try Self.decodeStatus(from: json)

        XCTAssertEqual(status.stuck?.kind, "hang",
            "120s idle must read as hung under the configured 60s threshold (the 180s default would not)")
        XCTAssertEqual(status.steps.first?.stuck?.kind, "hang",
            "the step-level verdict must use the configured threshold too")
    }

    // MARK: - resumable contract

    /// The 2026-07-25 incident, pinned end to end. The app was closed mid-planning,
    /// so `StatusRecoveryService` left the step `.paused` with its role `.idle` and
    /// all 5 tool calls intact.
    ///
    /// Everything the manager's triage normally keys on is structurally absent here
    /// — `stuck`, `idle_seconds` and `running_tool` are all gated on `.running` — and
    /// `elapsed_seconds` counts the app's downtime, so it reads like hours of
    /// nothing. `resumable: true` is the one field that says what to DO, and its
    /// absence is what let the manager reach for the destructive `manage_role
    /// restart` instead of `control_task resume`.
    func testHandleTaskStatus_appQuitRecoveredStep_isResumable() async throws {
        let old = Date(timeIntervalSinceNow: -23_885)   // the incident's elapsed_seconds
        let calls = (1...5).map {
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\":\"f\($0).swift\"}",
                         resultJSON: "{\"ok\":true}")
        }
        let step = StepExecution(
            id: "startup_software_engineer", role: .softwareEngineer, title: "SWE",
            status: .paused, createdAt: old, updatedAt: old,
            messages: [StepMessage(role: .softwareEngineer, content: "researching")],
            toolCalls: calls
        )
        let run = Run(id: 0, createdAt: old, steps: [step],
                      roleStatuses: ["startup_software_engineer": .idle])
        mockDelegate.taskToMutate = NTMSTask(
            id: 10, title: "M3 — Player screen", supervisorTask: "...", runs: [run])

        let status = try Self.decodeStatus(from: await service.handleTaskStatus(taskID: 10))
        let row = try XCTUnwrap(status.steps.first)

        XCTAssertEqual(row.status, "paused")
        XCTAssertEqual(row.resumable, true,
            "the one actionable field on a paused step — without it the manager restarts and wipes the work")
        XCTAssertNil(row.stuck, "a paused step never carries a stuck verdict")
        XCTAssertNil(row.idle_seconds, "idle_seconds is gated on .running")
        XCTAssertNil(row.running_tool)
        XCTAssertEqual(row.elapsed_seconds, 23_885, accuracy: 5,
            "elapsed keeps counting through app downtime — which is exactly why it must not be the signal")
    }

    /// `resumable` is `true`-or-omitted, never `false`: an absent key must not read
    /// as a claim that resume would fail. A running step's payload is unchanged.
    func testHandleTaskStatus_runningStep_omitsResumable() async throws {
        let step = StepExecution(
            id: "startup_software_engineer", role: .softwareEngineer, title: "SWE",
            status: .running)
        let run = Run(id: 0, steps: [step], roleStatuses: ["startup_software_engineer": .working])
        mockDelegate.taskToMutate = NTMSTask(id: 12, title: "T", supervisorTask: "...", runs: [run])

        let json = await service.handleTaskStatus(taskID: 12)
        XCTAssertFalse(json.contains("resumable"),
            "omitted, not false — a running step's wire shape must be byte-identical to before")
        XCTAssertNil(try Self.decodeStatus(from: json).steps.first?.resumable)
    }

    // MARK: - roles_needing_acceptance contract

    /// `RoleExecutionStatus` is otherwise invisible to the manager, so `task_status`
    /// surfaces exactly which roles await acceptance — the manager accepts only those
    /// and `control_task close`s the rest. The listed ids correlate with `steps[].role_id`.
    func testHandleTaskStatus_exposesRolesNeedingAcceptance() async throws {
        let status = try await decodedStatus(
            steps: [
                StepExecution(id: "pm", role: .productManager, title: "PM", status: .needsApproval),
                StepExecution(id: "tl", role: .techLead, title: "TL", status: .done),
            ],
            roleStatuses: ["pm": .needsAcceptance, "tl": .done])
        XCTAssertEqual(status.roles_needing_acceptance, ["pm"],
            "only the .needsAcceptance role is listed; the .done role is not")
    }

    /// All roles complete (`.done`) → the field is omitted entirely (lean payload,
    /// the common finished-task case). This is the reported FAANG/finalOnly shape.
    func testHandleTaskStatus_allRolesDone_omitsRolesNeedingAcceptance() async throws {
        let status = try await decodedStatus(
            steps: [StepExecution(id: "pm", role: .productManager, title: "PM", status: .done)],
            roleStatuses: ["pm": .done])
        XCTAssertNil(status.roles_needing_acceptance,
            "no roles awaiting acceptance → field omitted from the wire payload")
    }

    /// Cardinality > 1: every `.needsAcceptance` role is listed, SORTED for a deterministic
    /// wire payload, and the `.done` role is excluded. Also pins correlation — each listed id
    /// is a real `steps[].role_id` the manager can act on.
    ///
    /// Five roles inserted in deliberately non-alphabetical order so ONLY an explicit `.sorted()`
    /// lands the result alphabetically — `Dictionary` key order is non-deterministic per process,
    /// so a 2-element list would coincidentally pass ~half the time even if the sort were removed.
    /// This reliably fails if `getPendingAcceptances(...).sorted()` loses its `.sorted()`.
    func testHandleTaskStatus_multipleRolesNeedingAcceptance_sortedAndCorrelated() async throws {
        let awaitingIDs = ["z_role", "a_role", "m_role", "t_role", "g_role"]
        var steps = awaitingIDs.map {
            StepExecution(id: $0, role: .softwareEngineer, title: $0, status: .needsApproval)
        }
        steps.append(StepExecution(id: "done_role", role: .softwareEngineer, title: "done", status: .done))
        var roleStatuses: [String: RoleExecutionStatus] = ["done_role": .done]
        for id in awaitingIDs { roleStatuses[id] = .needsAcceptance }

        let status = try await decodedStatus(steps: steps, roleStatuses: roleStatuses)
        XCTAssertEqual(status.roles_needing_acceptance,
                       ["a_role", "g_role", "m_role", "t_role", "z_role"],
            "all awaiting roles listed in sorted order; the .done role excluded")
        let stepIDs = Set(status.steps.map(\.role_id))
        for id in status.roles_needing_acceptance ?? [] {
            XCTAssertTrue(stepIDs.contains(id), "\(id) must appear in steps[].role_id")
        }
    }

    /// Degenerate: a task with no runs yields a valid envelope and simply omits the field
    /// (no crash, no spurious value).
    func testHandleTaskStatus_noRuns_omitsRolesNeedingAcceptance() async throws {
        let task = NTMSTask(id: 15, title: "T", supervisorTask: "...", runs: [])
        mockDelegate.taskToMutate = task

        let status = try Self.decodeStatus(from: await service.handleTaskStatus(taskID: 15))
        XCTAssertNil(status.roles_needing_acceptance)
        XCTAssertTrue(status.steps.isEmpty)
    }

    /// Corner: an orphan `.needsAcceptance` status with NO matching step is excluded. Every
    /// listed id must be actionable via `manage_role accept` (which resolves a STEP), so a
    /// status-only entry the manager couldn't act on must not be surfaced.
    func testHandleTaskStatus_orphanNeedsAcceptanceWithoutStep_excluded() async throws {
        let status = try await decodedStatus(
            steps: [StepExecution(id: "pm", role: .productManager, title: "PM", status: .done)],
            roleStatuses: ["pm": .done, "ghost": .needsAcceptance])
        XCTAssertNil(status.roles_needing_acceptance,
            "a .needsAcceptance status with no step row is un-actionable and must not be surfaced")
    }

    /// Corner: the field is strictly `.needsAcceptance`, NOT any incomplete status — a sibling
    /// at `.accepted` / `.failed` / `.revisionRequested` must be excluded.
    func testHandleTaskStatus_onlyNeedsAcceptance_excludesOtherIncompleteStatuses() async throws {
        let status = try await decodedStatus(
            steps: [
                StepExecution(id: "pm", role: .productManager, title: "PM", status: .needsApproval),
                StepExecution(id: "tl", role: .techLead, title: "TL", status: .done),
                StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .failed),
                StepExecution(id: "cr", role: .softwareEngineer, title: "CR", status: .done),
            ],
            roleStatuses: ["pm": .needsAcceptance, "tl": .accepted,
                           "swe": .failed, "cr": .revisionRequested])
        XCTAssertEqual(status.roles_needing_acceptance, ["pm"],
            "only .needsAcceptance is surfaced; .accepted/.failed/.revisionRequested are not")
    }

    /// Corner: the field is independent of task-level status — a gated `.needsAcceptance` role
    /// is surfaced even while a sibling is still running (the mid-pipeline acceptance-gate case
    /// the manager prompt relies on, where the task derives to .paused rather than Review).
    func testHandleTaskStatus_needsAcceptanceWhileSiblingRunning_stillListed() async throws {
        let status = try await decodedStatus(
            steps: [
                StepExecution(id: "pm", role: .productManager, title: "PM", status: .needsApproval),
                StepExecution(id: "tl", role: .techLead, title: "TL", status: .running),
            ],
            roleStatuses: ["pm": .needsAcceptance, "tl": .working])
        XCTAssertEqual(status.roles_needing_acceptance, ["pm"],
            "a gated role is surfaced regardless of task-level status (mid-pipeline gate)")
    }

    /// Corner: the field reads RoleExecutionStatus, NOT StepStatus — a `.needsAcceptance` role
    /// whose STEP is `.done` is still listed. This is the exact distinction the bug was about
    /// (a `.done` step does not mean "no acceptance needed").
    func testHandleTaskStatus_roleStatusDriven_notStepStatus() async throws {
        let status = try await decodedStatus(
            steps: [StepExecution(id: "pm", role: .productManager, title: "PM", status: .done)],
            roleStatuses: ["pm": .needsAcceptance])
        XCTAssertEqual(status.roles_needing_acceptance, ["pm"],
            "a .needsAcceptance role with a .done step must still be surfaced (role status drives it)")
    }

    /// Corner: the field is scoped to the CURRENT run (`runs.last`) — a `.needsAcceptance`
    /// role in an OLD run does not leak in once a fresh run has all roles `.done`.
    func testHandleTaskStatus_currentRunScoped_oldRunDoesNotLeak() async throws {
        let oldStep = StepExecution(id: "pm", role: .productManager, title: "PM", status: .needsApproval)
        let newStep = StepExecution(id: "pm", role: .productManager, title: "PM", status: .done)
        let task = NTMSTask(id: 20, title: "T", supervisorTask: "...", runs: [
            Run(id: 0, steps: [oldStep], roleStatuses: ["pm": .needsAcceptance]),  // historical
            Run(id: 1, steps: [newStep], roleStatuses: ["pm": .done]),             // current
        ])
        mockDelegate.taskToMutate = task

        let status = try Self.decodeStatus(from: await service.handleTaskStatus(taskID: 20))
        XCTAssertNil(status.roles_needing_acceptance,
            "only the latest run is reflected; the old run's .needsAcceptance must not leak")
    }

    // MARK: - list_tasks chat_mode

    func testHandleListTasks_reportsChatModePerTask() async throws {
        let index = TasksIndex(tasks: [
            TaskSummary(id: 1, title: "Chat", status: .running, isChatMode: true),
            TaskSummary(id: 2, title: "Pipe", status: .running, isChatMode: false),
        ])
        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "t"), settings: ProjectSettings(), teams: [])
        mockDelegate.snapshot = WorkFolderContext(
            projection: projection, tasksIndex: index, toolDefinitions: [])

        struct Row: Decodable { let id: Int; let chat_mode: Bool }
        struct Env: Decodable { struct D: Decodable { let tasks: [Row] }; let data: D }
        let rows = try JSONDecoder().decode(Env.self, from: Data(await service.handleListTasks().utf8)).data.tasks
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.chat_mode) })
        XCTAssertEqual(byID[1], true)
        XCTAssertEqual(byID[2], false)
    }

    // MARK: - chat_mode / role_kind wire fields

    func testHandleTaskStatus_chatModeTask_reportsChatModeTrue() async throws {
        let task = NTMSTask(id: 1, title: "Chat", supervisorTask: "...",
                            runs: [Run(id: 0, steps: [], roleStatuses: [:])], isChatMode: true)
        mockDelegate.taskToMutate = task
        let status = try Self.decodeStatus(from: await service.handleTaskStatus(taskID: 1))
        XCTAssertTrue(status.chat_mode)
    }

    func testHandleTaskStatus_nonChatTask_reportsChatModeFalse() async throws {
        let status = try await decodedStatus(steps: [], roleStatuses: [:])
        XCTAssertFalse(status.chat_mode)
    }

    func testHandleTaskStatus_exposesRoleKindPerStep() async throws {
        // Snapshot with a resolvable active team so `role_kind` can be populated.
        let advisory = TeamRoleDefinition(
            id: "adv", name: "Advisor", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Ctx"]))
        let team = Team(id: "kind-team", name: "Kind", roles: [advisory],
                        artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
        var projection = WorkFolderProjection(
            state: WorkFolderState(name: "t"), settings: ProjectSettings(), teams: [team])
        projection.setActiveTeam("kind-team")
        mockDelegate.snapshot = WorkFolderContext(
            projection: projection, tasksIndex: TasksIndex(), toolDefinitions: [])

        let step = StepExecution(id: "adv", role: .custom(id: "adv"), title: "Advisor", status: .running)
        mockDelegate.taskToMutate = NTMSTask(id: 1, title: "T", supervisorTask: "...",
                                             runs: [Run(id: 0, steps: [step], roleStatuses: ["adv": .working])])

        let status = try Self.decodeStatus(from: await service.handleTaskStatus(taskID: 1))
        XCTAssertEqual(status.steps.first?.role_kind, "advisory",
                       "role_kind must expose the resolved role's completion type")
    }

    func testHandleTaskStatus_duplicateRoleIDs_doesNotCrash() async throws {
        // Role ids are name-derived, so two same-named roles in one team collide on id.
        // The roleKindByID dict build must NOT trap (uniquingKeysWith, last-wins).
        let r1 = TeamRoleDefinition(id: "dup", name: "Dup", prompt: "", toolIDs: [], usePlanningPhase: false,
                                    dependencies: RoleDependencies(requiredArtifacts: ["Ctx"]))  // advisory
        let r2 = TeamRoleDefinition(id: "dup", name: "Dup", prompt: "", toolIDs: [], usePlanningPhase: false,
                                    dependencies: RoleDependencies(producesArtifacts: ["Out"]))   // producing
        let team = Team(id: "dup-team", name: "Dup", roles: [r1, r2],
                        artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
        var projection = WorkFolderProjection(
            state: WorkFolderState(name: "t"), settings: ProjectSettings(), teams: [team])
        projection.setActiveTeam("dup-team")
        mockDelegate.snapshot = WorkFolderContext(
            projection: projection, tasksIndex: TasksIndex(), toolDefinitions: [])
        mockDelegate.taskToMutate = NTMSTask(id: 1, title: "T", supervisorTask: "...",
            runs: [Run(id: 0, steps: [StepExecution(id: "dup", role: .custom(id: "dup"), title: "Dup", status: .running)],
                       roleStatuses: ["dup": .working])])

        // Reaching this assertion at all proves no fatalError trap fired.
        let status = try Self.decodeStatus(from: await service.handleTaskStatus(taskID: 1))
        XCTAssertEqual(status.steps.first?.role_kind, "advisory", "last-wins keeps the first role's kind")
    }

    func testHandleTaskStatus_unresolvableTeam_omitsRoleKind() async throws {
        // No snapshot → resolveTeam returns nil → role_kind is omitted (not "unknown").
        let status = try await decodedStatus(
            steps: [StepExecution(id: "r", role: .softwareEngineer, title: "R", status: .running)],
            roleStatuses: ["r": .working])
        XCTAssertNil(status.steps.first?.role_kind)
    }

    // MARK: - next-hint contract (Review with no per-role gate → control_task close)

    /// The 2026-08-11 incident's FIRST decision point: a Review task with
    /// `roles_needing_acceptance` omitted told the manager nothing, and it reached for
    /// `manage_role accept`. The envelope's `next` slot must carry the machine-copyable
    /// close command exactly here — and ONLY here (the four omit-tests below pin each
    /// guard of the condition individually).
    func testHandleTaskStatus_reviewNoPendingAcceptance_carriesCloseHint() async throws {
        let step = StepExecution(id: "r", role: .softwareEngineer, title: "R", status: .done)
        let task = NTMSTask(id: 42, title: "T", supervisorTask: "...",
                            runs: [Run(id: 0, steps: [step], roleStatuses: ["r": .done])])
        mockDelegate.taskToMutate = task

        let json = await service.handleTaskStatus(taskID: 42)
        let next = try XCTUnwrap(Self.decodeNext(from: json),
                                 "Review with nothing at a per-role gate must carry the close hint")
        XCTAssertEqual(next.suggested_cmd, ToolNames.controlTask)
        XCTAssertEqual(next.suggested_args?["task_id"], "42",
                       "task_id must be copyable verbatim — the model never computes")
        // Round-trip the action spelling through the REAL decoder so "close" can't
        // silently drift from what control_task actually parses.
        let action = try XCTUnwrap(next.suggested_args?["action"])
        XCTAssertEqual(try ControlVerb.parse(action: action, arg: nil).get(), .close,
                       "the suggested action must parse as control_task's close verb")
        XCTAssertNotNil(next.reason, "the hint explains WHY close is the move")
    }

    /// A genuine mid-pipeline gate: `roles_needing_acceptance` is non-empty, so per-role
    /// accept applies FIRST (prompt §Review) — the close hint must stay away, byte-level.
    func testHandleTaskStatus_reviewWithPendingAcceptance_omitsNext() async throws {
        let steps = [
            StepExecution(id: "pm", role: .custom(id: "pm"), title: "PM", status: .done),
            StepExecution(id: "tl", role: .custom(id: "tl"), title: "TL", status: .done),
        ]
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "...",
                            runs: [Run(id: 0, steps: steps,
                                       roleStatuses: ["pm": .needsAcceptance, "tl": .done])])
        mockDelegate.taskToMutate = task

        let json = await service.handleTaskStatus(taskID: 1)
        let status = try Self.decodeStatus(from: json)
        XCTAssertEqual(status.roles_needing_acceptance, ["pm"], "precondition: the gate is listed")
        XCTAssertNil(try Self.decodeNext(from: json))
        XCTAssertFalse(json.contains("\"next\""),
                       "omitted means ABSENT from the wire, not null — byte-shape pin")
    }

    func testHandleTaskStatus_runningTask_omitsNext() async throws {
        let step = StepExecution(id: "r", role: .softwareEngineer, title: "R", status: .running)
        mockDelegate.taskToMutate = NTMSTask(id: 1, title: "T", supervisorTask: "...",
                                             runs: [Run(id: 0, steps: [step], roleStatuses: ["r": .working])])
        let json = await service.handleTaskStatus(taskID: 1)
        XCTAssertNil(try Self.decodeNext(from: json), "a live run has nothing to close")
    }

    /// Chat tasks override Review to `.running` in `derivedStatusFromActiveRun` — the
    /// guard keys on the DERIVED status, so an all-done chat task never gets the hint
    /// (a chat task ends only when the manager decides the conversation is over).
    func testHandleTaskStatus_chatModeAllDone_omitsNext() async throws {
        let step = StepExecution(id: "a", role: .custom(id: "a"), title: "A", status: .done)
        mockDelegate.taskToMutate = NTMSTask(id: 1, title: "Chat", supervisorTask: "...",
                                             runs: [Run(id: 0, steps: [step], roleStatuses: ["a": .done])],
                                             isChatMode: true)
        let json = await service.handleTaskStatus(taskID: 1)
        XCTAssertNil(try Self.decodeNext(from: json), "chat never derives Review → never advises close")
    }

    func testHandleTaskStatus_closedTask_omitsNext() async throws {
        let step = StepExecution(id: "r", role: .softwareEngineer, title: "R", status: .done)
        mockDelegate.taskToMutate = NTMSTask(id: 1, title: "T", supervisorTask: "...",
                                             runs: [Run(id: 0, steps: [step], roleStatuses: ["r": .done])],
                                             closedAt: Date())
        let json = await service.handleTaskStatus(taskID: 1)
        XCTAssertNil(try Self.decodeNext(from: json), "a closed task derives .done — nothing left to close")
    }

    /// An ORPHAN `.needsAcceptance` status (no step row — roster edited mid-run): the
    /// wire field is step-intersected and reads empty, but a live gate still exists.
    /// The hint gates on `isReadyForFinalAcceptance` (the RAW role set), so it must
    /// stay silent — a `rolesNeedingAcceptance == nil` gate would advise closing over
    /// the orphan's unreviewed gate.
    func testHandleTaskStatus_orphanNeedsAcceptanceGate_omitsNext() async throws {
        let step = StepExecution(id: "r", role: .softwareEngineer, title: "R", status: .done)
        mockDelegate.taskToMutate = NTMSTask(id: 1, title: "T", supervisorTask: "...",
                                             runs: [Run(id: 0, steps: [step],
                                                        roleStatuses: ["r": .done, "ghost": .needsAcceptance])])
        let json = await service.handleTaskStatus(taskID: 1)
        let status = try Self.decodeStatus(from: json)
        XCTAssertNil(status.roles_needing_acceptance,
                     "precondition: the orphan is filtered from the wire field — that is why the hint cannot key on it")
        XCTAssertNil(try Self.decodeNext(from: json),
                     "a gate the payload cannot list is still a gate; no close hint")
    }

    // MARK: - Helpers

    /// Builds a single-run task from `steps`/`roleStatuses`, wires it into the mock, and returns
    /// the decoded `task_status` envelope — collapses the build/assign/decode boilerplate the
    /// `roles_needing_acceptance` corner tests share. (The no-runs and multi-run corners build
    /// their task inline, since their run shape differs.)
    private func decodedStatus(steps: [StepExecution],
                               roleStatuses: [String: RoleExecutionStatus]) async throws -> StatusDTO {
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "...",
                            runs: [Run(id: 0, steps: steps, roleStatuses: roleStatuses)])
        mockDelegate.taskToMutate = task
        return try Self.decodeStatus(from: await service.handleTaskStatus(taskID: 1))
    }

    /// A snapshot whose only meaningful field is a custom Autovisor hang threshold,
    /// so `handleTaskStatus`'s `delegate.snapshot?...autovisorTuning` read is exercised.
    private static func contextWithHangThreshold(_ seconds: TimeInterval) -> WorkFolderContext {
        let settings = ProjectSettings(autovisorTuning: AutovisorTuning(stuckHangSeconds: seconds))
        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "test"), settings: settings, teams: []
        )
        return WorkFolderContext(projection: projection, tasksIndex: TasksIndex(), toolDefinitions: [])
    }

    private struct ArtifactRowDTO: Decodable { let name: String; let path: String? }

    private struct StuckDTO: Decodable { let kind: String; let detail: String? }
    private struct StepRowDTO: Decodable {
        let role_id: String
        let status: String
        let resumable: Bool?
        let role_kind: String?
        let elapsed_seconds: Int
        let idle_seconds: Int?
        let running_tool: String?
        let stuck: StuckDTO?
    }
    private struct StatusDTO: Decodable {
        let chat_mode: Bool
        let steps: [StepRowDTO]
        let stuck: StuckDTO?
        let timed_out: Bool
        let roles_needing_acceptance: [String]?
    }

    private static func decodeStatus(from json: String) throws -> StatusDTO {
        struct Envelope: Decodable { let data: StatusDTO }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).data
    }

    private struct NextDTO: Decodable {
        let suggested_cmd: String?
        let suggested_args: [String: String]?
        let reason: String?
    }

    /// The envelope's top-level `next` slot; nil when the key is absent. THROWS on a
    /// malformed envelope — with a swallowing `try?`, every omit-test would pass
    /// vacuously against a broken payload (the anti-vacuum rule from the Грабли log).
    private static func decodeNext(from json: String) throws -> NextDTO? {
        struct Envelope: Decodable { let next: NextDTO? }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).next
    }

    /// Decodes the `data.artifacts` array out of a `makeSuccessEnvelope` JSON string
    /// (independent of forward-slash escaping in the raw JSON).
    private static func decodeArtifacts(from json: String) throws -> [ArtifactRowDTO] {
        struct Envelope: Decodable {
            struct DataBlock: Decodable { let artifacts: [ArtifactRowDTO] }
            let data: DataBlock
        }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).data.artifacts
    }
}
