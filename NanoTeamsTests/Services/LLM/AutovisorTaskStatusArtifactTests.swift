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

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() {
        mockDelegate = nil
        service = nil
        super.tearDown()
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

    // MARK: - Helpers

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
        let elapsed_seconds: Int
        let idle_seconds: Int?
        let running_tool: String?
        let stuck: StuckDTO?
    }
    private struct StatusDTO: Decodable {
        let steps: [StepRowDTO]
        let stuck: StuckDTO?
        let timed_out: Bool
    }

    private static func decodeStatus(from json: String) throws -> StatusDTO {
        struct Envelope: Decodable { let data: StatusDTO }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).data
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
