import XCTest

@testable import NanoTeams

// MARK: - File-scope fixtures / helpers
//
// Everything at file scope is `private` — this module is written into by many
// suites at once and a bare `StubClient` / `parseEnvelope` would collide.

private let deChildTID = 77
private let deParentTID = 3
private let deParentStepID = "coding_agent_step"
private let deChildStepID = "child_engineer"
private let deChildTeamName = "Engineering Team"

/// Parses a tool envelope JSON string into its top-level dictionary.
private func deParseEnvelope(_ json: String) throws -> [String: Any] {
    let any = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [])
    return try XCTUnwrap(any as? [String: Any], "envelope is not a JSON object: \(json)")
}

/// Unwraps the `data` object of a success envelope.
private func deParseData(_ json: String) throws -> [String: Any] {
    let dict = try deParseEnvelope(json)
    return try XCTUnwrap(dict["data"] as? [String: Any], "envelope carries no data object: \(json)")
}

/// Unwraps the `error.message` of a failure envelope.
private func deParseErrorMessage(_ json: String) throws -> String {
    let dict = try deParseEnvelope(json)
    let error = try XCTUnwrap(dict["error"] as? [String: Any], "envelope carries no error object: \(json)")
    return try XCTUnwrap(error["message"] as? String)
}

private func deStubConfig() -> LLMConfig {
    LLMConfig(
        provider: .lmStudio,
        baseURLString: "http://localhost",
        modelName: "stub",
        temperature: nil
    )
}

/// Never streams. Every awaiter branch these suites script is driven by
/// `MockLLMExecutionDelegate.scriptedAwaitOutcomes`; `.needsSupervisorInput`
/// (the one branch that would issue a request) is deliberately never scripted.
/// `callCount` exists so the "no delegate ⇒ canned answer" test can prove the
/// short-circuit happened BEFORE any network work.
private final class DENoopLLMClient: LLMClient, @unchecked Sendable {
    var callCount = 0
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        callCount += 1
        return AsyncThrowingStream { $0.finish() }
    }
    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}

/// A team whose Supervisor requires `requires` — `Team.supervisorRequiredArtifacts`
/// reads the Supervisor role's `requiredArtifacts`, and an EMPTY list is what makes
/// the team chat-mode (which `buildSuccessEnvelope` branches on).
private func deMakeTargetTeam(name: String = deChildTeamName, requires: [String]) -> Team {
    let supervisor = TeamRoleDefinition(
        id: "child_supervisor",
        name: "Supervisor",
        prompt: "",
        toolIDs: [],
        usePlanningPhase: false,
        dependencies: RoleDependencies(requiredArtifacts: requires),
        systemRoleID: "supervisor"
    )
    let worker = TeamRoleDefinition(
        id: deChildStepID,
        name: "Engineer",
        prompt: "p",
        toolIDs: [],
        usePlanningPhase: false,
        dependencies: RoleDependencies(producesArtifacts: requires)
    )
    return Team(
        id: "child-team-id",
        name: name,
        roles: [supervisor, worker],
        artifacts: [],
        settings: TeamSettings(),
        graphLayout: TeamGraphLayout()
    )
}

// MARK: - buildSuccessEnvelope
//
// The terminal-`.done` envelope is the ONLY channel through which a delegated
// team's work reaches the delegating role's LLM: the child task is hidden from
// the sidebar, and the parent role sees nothing but this JSON. Every shape below
// is therefore a wire contract — a dropped `content`, a silently-omitted
// `missing_artifacts` entry, or an artifact reported under the wrong producer all
// surface to the model as "the team did / didn't do the work".
@MainActor
final class DelegationSuccessEnvelopeTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NTDelegEnvelopes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        delegate.workFolderURL = tempDir
        service.attach(delegate: delegate)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        service?.cancelAllExecutions()
        service = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: Fixtures

    /// Writes an artifact payload where `ArtifactService.readContent` looks for it:
    /// `<workFolderRoot>/.nanoteams/<relativePath>`.
    private func writePayload(_ body: String, at relativePath: String) {
        let url = tempDir
            .appendingPathComponent(".nanoteams", isDirectory: true)
            .appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeArtifact(_ name: String, relativePath: String?) -> Artifact {
        Artifact(name: name, mimeType: "text/markdown", relativePath: relativePath)
    }

    private func makeRun(id: Int, steps: [StepExecution]) -> Run {
        Run(id: id, steps: steps)
    }

    private func makeStep(id: String, artifacts: [Artifact]) -> StepExecution {
        StepExecution(id: id, role: .softwareEngineer, title: "Engineer", artifacts: artifacts)
    }

    /// Installs the CHILD task in the mock's single `loadedTask` slot — that is the
    /// only task `buildSuccessEnvelope` reads.
    private func installChild(runs: [Run]) {
        var child = NTMSTask(id: deChildTID, title: "Delegated", supervisorTask: "brief")
        child.runs = runs
        delegate.taskToMutate = child
    }

    private func buildEnvelope(
        team: Team,
        isGeneratedFlow: Bool = false,
        warnings: [String] = []
    ) async -> String {
        await service.buildSuccessEnvelope(
            childTID: deChildTID,
            targetTeam: team,
            isGeneratedFlow: isGeneratedFlow,
            generationWarnings: warnings,
            delegate: delegate
        )
    }

    // MARK: Happy path

    func testSuccessEnvelope_producedRequiredArtifact_carriesContentAndProducingRoleID() async throws {
        let rel = "tasks/77/runs/0/roles/child_engineer/artifact_release_notes.md"
        writePayload("## Release Notes\nShipped the thing.", at: rel)
        installChild(runs: [
            makeRun(id: 0, steps: [
                makeStep(id: deChildStepID, artifacts: [makeArtifact("Release Notes", relativePath: rel)])
            ])
        ])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: ["Release Notes"]))

        let top = try deParseEnvelope(envelope)
        XCTAssertEqual(top["ok"] as? Bool, true,
                       "A completed delegation is a success — the parent role must not read it as a tool failure")

        let data = try deParseData(envelope)
        XCTAssertEqual(data["child_task_id"] as? Int, deChildTID)
        XCTAssertEqual(data["team"] as? String, deChildTeamName,
                       "The envelope must name the TARGET team — it is the parent role's only label for who did the work")
        XCTAssertEqual(data["generated"] as? Bool, false)

        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        let payload = try XCTUnwrap(
            artifacts["Release Notes"] as? [String: Any],
            "The required artifact must be keyed by its NAME — that is the identifier the parent role reasons about")
        XCTAssertEqual(payload["content"] as? String, "## Release Notes\nShipped the thing.",
                       "Artifact bodies ride the envelope in full; a dropped body silently hands the parent role an empty deliverable")
        XCTAssertEqual(payload["role_id"] as? String, deChildStepID,
                       "role_id must be the PRODUCING step's role id so the parent can attribute the work")

        let missing = try XCTUnwrap(data["missing_artifacts"] as? [String])
        XCTAssertTrue(missing.isEmpty)
    }

    func testSuccessEnvelope_missingRequiredArtifact_isListedInMissingArtifacts() async throws {
        let rel = "tasks/77/runs/0/roles/child_engineer/artifact_a.md"
        writePayload("A body", at: rel)
        installChild(runs: [
            makeRun(id: 0, steps: [
                makeStep(id: deChildStepID, artifacts: [makeArtifact("Alpha", relativePath: rel)])
            ])
        ])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: ["Alpha", "Beta"]))

        let data = try deParseData(envelope)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        XCTAssertEqual(Set(artifacts.keys), ["Alpha"],
                       "An unproduced required artifact must NOT appear with an empty body — that reads as 'delivered but blank'")
        XCTAssertEqual(data["missing_artifacts"] as? [String], ["Beta"],
                       "A required-but-unproduced artifact is the parent role's cue to re-delegate or replan")
    }

    /// A required name listed twice collapses upstream (`supervisorRequiredArtifacts`
    /// dedups), so `missing_artifacts` must not repeat it — a duplicated miss reads to
    /// the model as two separate deliverables gone astray.
    func testSuccessEnvelope_duplicatedRequiredName_isReportedMissingOnlyOnce() async throws {
        installChild(runs: [makeRun(id: 0, steps: [makeStep(id: deChildStepID, artifacts: [])])])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: ["Alpha", "Alpha"]))

        let data = try deParseData(envelope)
        XCTAssertEqual(data["missing_artifacts"] as? [String], ["Alpha"])
    }

    /// Non-chat teams return EXACTLY the Supervisor's required set. Everything else the
    /// child produced (scratch notes, intermediate specs) is deliberately withheld — it
    /// would ride the parent's context window on every subsequent turn.
    func testSuccessEnvelope_nonChatTeam_returnsOnlyTheRequiredArtifacts() async throws {
        let relA = "tasks/77/runs/0/roles/child_engineer/artifact_release.md"
        let relB = "tasks/77/runs/0/roles/child_engineer/artifact_scratch.md"
        writePayload("release", at: relA)
        writePayload("scratch", at: relB)
        installChild(runs: [
            makeRun(id: 0, steps: [
                makeStep(id: deChildStepID, artifacts: [
                    makeArtifact("Release Notes", relativePath: relA),
                    makeArtifact("Scratch Notes", relativePath: relB),
                ])
            ])
        ])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: ["Release Notes"]))

        let data = try deParseData(envelope)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        XCTAssertEqual(Set(artifacts.keys), ["Release Notes"],
                       "Non-required artifacts must not ride the envelope — they cost the parent's context on every later turn")
    }

    /// Chat-mode target (`supervisorRequiredArtifacts` empty) has no required set to
    /// filter by, so EVERYTHING produced is surfaced. Nothing can be "missing" when
    /// nothing was required.
    func testSuccessEnvelope_chatModeTargetTeam_returnsEveryProducedArtifact_andNoMissing() async throws {
        let relA = "tasks/77/runs/0/roles/child_engineer/artifact_a.md"
        let relB = "tasks/77/runs/0/roles/child_engineer/artifact_b.md"
        writePayload("body A", at: relA)
        writePayload("body B", at: relB)
        installChild(runs: [
            makeRun(id: 0, steps: [
                makeStep(id: deChildStepID, artifacts: [
                    makeArtifact("Zulu", relativePath: relA),
                    makeArtifact("Alpha", relativePath: relB),
                ])
            ])
        ])

        let team = deMakeTargetTeam(requires: [])
        XCTAssertTrue(team.isChatMode, "Precondition: an empty Supervisor requirement set IS chat mode")

        let envelope = await buildEnvelope(team: team)

        let data = try deParseData(envelope)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        XCTAssertEqual(Set(artifacts.keys), ["Zulu", "Alpha"])
        let missing = try XCTUnwrap(data["missing_artifacts"] as? [String])
        XCTAssertTrue(missing.isEmpty, "Nothing was required, so nothing can be missing")
    }

    // MARK: Content-read failure arms

    /// The artifact record exists but its file does not (deleted / never flushed). The
    /// KEY must still be present with an empty body: dropping the key would move the
    /// artifact into "never produced" territory, and the child DID produce it.
    func testSuccessEnvelope_artifactFileUnreadable_keepsTheKeyWithEmptyContent() async throws {
        installChild(runs: [
            makeRun(id: 0, steps: [
                makeStep(id: deChildStepID, artifacts: [
                    makeArtifact("Release Notes", relativePath: "tasks/77/runs/0/roles/child_engineer/gone.md")
                ])
            ])
        ])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: ["Release Notes"]))

        let data = try deParseData(envelope)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        let payload = try XCTUnwrap(artifacts["Release Notes"] as? [String: Any],
                                    "An unreadable payload must not demote a produced artifact to absent")
        XCTAssertEqual(payload["content"] as? String, "")
        let missing = try XCTUnwrap(data["missing_artifacts"] as? [String])
        XCTAssertTrue(missing.isEmpty,
                      "It was produced — `missing_artifacts` means 'never submitted', not 'body unreadable'")
    }

    /// Default-storage / no-folder mode: there is no root to resolve payloads against,
    /// so every body is empty while the artifact roster stays honest.
    func testSuccessEnvelope_noWorkFolderRoot_keepsTheKeyWithEmptyContent() async throws {
        delegate.workFolderURL = nil
        let rel = "tasks/77/runs/0/roles/child_engineer/artifact_release.md"
        writePayload("unreachable without a root", at: rel)
        installChild(runs: [
            makeRun(id: 0, steps: [
                makeStep(id: deChildStepID, artifacts: [makeArtifact("Release Notes", relativePath: rel)])
            ])
        ])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: ["Release Notes"]))

        let data = try deParseData(envelope)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        let payload = try XCTUnwrap(artifacts["Release Notes"] as? [String: Any])
        XCTAssertEqual(payload["content"] as? String, "")
    }

    /// An artifact record with no persisted path at all (`relativePath == nil`) —
    /// `ArtifactService.readContent` bails on it, and the envelope must still list it.
    func testSuccessEnvelope_artifactWithNoRelativePath_keepsTheKeyWithEmptyContent() async throws {
        installChild(runs: [
            makeRun(id: 0, steps: [
                makeStep(id: deChildStepID, artifacts: [makeArtifact("Release Notes", relativePath: nil)])
            ])
        ])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: ["Release Notes"]))

        let data = try deParseData(envelope)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        let payload = try XCTUnwrap(artifacts["Release Notes"] as? [String: Any])
        XCTAssertEqual(payload["content"] as? String, "")
    }

    // MARK: Flags / warnings

    func testSuccessEnvelope_generationWarnings_emptyOmitsTheKeyEntirely() async throws {
        installChild(runs: [makeRun(id: 0, steps: [makeStep(id: deChildStepID, artifacts: [])])])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: []), warnings: [])

        let data = try deParseData(envelope)
        XCTAssertNil(data["generation_warnings"],
                     "An empty warnings list must be omitted, not shipped as `[]` — every wire byte is prompt budget")
    }

    func testSuccessEnvelope_generationWarnings_nonEmptyRideTheEnvelope() async throws {
        installChild(runs: [makeRun(id: 0, steps: [makeStep(id: deChildStepID, artifacts: [])])])

        let envelope = await buildEnvelope(
            team: deMakeTargetTeam(requires: []),
            isGeneratedFlow: true,
            warnings: ["Dropped unknown tool 'list_teams'", "Ignored LLM-emitted Supervisor role"])

        let data = try deParseData(envelope)
        XCTAssertEqual(
            data["generation_warnings"] as? [String],
            ["Dropped unknown tool 'list_teams'", "Ignored LLM-emitted Supervisor role"],
            "Build warnings must reach the delegating role — they explain a team that is quietly less capable than asked for")
    }

    func testSuccessEnvelope_generatedFlag_roundTripsBothWays() async throws {
        installChild(runs: [makeRun(id: 0, steps: [makeStep(id: deChildStepID, artifacts: [])])])

        let generatedEnvelope = await buildEnvelope(team: deMakeTargetTeam(requires: []), isGeneratedFlow: true)
        let existingEnvelope = await buildEnvelope(team: deMakeTargetTeam(requires: []), isGeneratedFlow: false)

        let generatedData = try deParseData(generatedEnvelope)
        let existingData = try deParseData(existingEnvelope)
        XCTAssertEqual(generatedData["generated"] as? Bool, true)
        XCTAssertEqual(existingData["generated"] as? Bool, false,
                       "`generated` tells the parent whether the team is disposable — it must not be hardcoded")
    }

    // MARK: Degenerate child state

    /// The child task is no longer loadable (evicted / removed). Nothing can be
    /// collected, so the artifact map is empty. `missing_artifacts` is deliberately NOT
    /// asserted here — see `suspectedDefects`.
    func testSuccessEnvelope_childTaskUnloadable_returnsNoArtifacts() async throws {
        delegate.taskToMutate = nil  // loadedTask(childTID) → nil

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: ["Release Notes"]))

        let top = try deParseEnvelope(envelope)
        XCTAssertEqual(top["ok"] as? Bool, true)
        let data = try deParseData(envelope)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        XCTAssertTrue(artifacts.isEmpty,
                      "No loadable child ⇒ nothing to report; the envelope must not fabricate artifact entries")
        XCTAssertEqual(data["child_task_id"] as? Int, deChildTID,
                       "The id must still be echoed so the parent can name the child in a follow-up")
    }

    func testSuccessEnvelope_childHasNoRuns_returnsNoArtifacts() async throws {
        installChild(runs: [])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: []))

        let data = try deParseData(envelope)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        XCTAssertTrue(artifacts.isEmpty)
    }

    func testSuccessEnvelope_childRunHasNoSteps_returnsNoArtifacts() async throws {
        installChild(runs: [makeRun(id: 0, steps: [])])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: []))

        let data = try deParseData(envelope)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        XCTAssertTrue(artifacts.isEmpty)
    }

    /// Only the LATEST run counts. A restarted child that produced nothing this time
    /// round must not inherit the previous run's deliverable — the parent would accept
    /// stale work as fresh.
    func testSuccessEnvelope_readsOnlyTheLatestRun() async throws {
        let rel = "tasks/77/runs/0/roles/child_engineer/artifact_old.md"
        writePayload("stale body from run 0", at: rel)
        installChild(runs: [
            makeRun(id: 0, steps: [
                makeStep(id: deChildStepID, artifacts: [makeArtifact("Release Notes", relativePath: rel)])
            ]),
            makeRun(id: 1, steps: [makeStep(id: deChildStepID, artifacts: [])]),
        ])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: ["Release Notes"]))

        let data = try deParseData(envelope)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        XCTAssertTrue(artifacts.isEmpty, "Run 0's artifact must not leak into run 1's envelope")
        XCTAssertEqual(data["missing_artifacts"] as? [String], ["Release Notes"],
                       "The latest run produced nothing, so the requirement is honestly reported as missing")
    }

    /// Two steps of the same run submitted the same artifact name (a revision, or two
    /// producing roles overlapping). The envelope must name the MOST RECENT producer —
    /// attributing a revision to the superseded role sends the parent's follow-up to the
    /// wrong team member.
    func testSuccessEnvelope_sameArtifactFromTwoSteps_reportsTheMostRecentProducer() async throws {
        let relOld = "tasks/77/runs/0/roles/first/artifact_old.md"
        let relNew = "tasks/77/runs/0/roles/second/artifact_new.md"
        writePayload("first draft", at: relOld)
        writePayload("revised draft", at: relNew)

        let older = Artifact(
            name: "Release Notes", mimeType: "text/markdown",
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now(),
            relativePath: relOld)
        let newer = Artifact(
            name: "Release Notes", mimeType: "text/markdown",
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now(),
            relativePath: relNew)
        XCTAssertLessThan(older.updatedAt, newer.updatedAt,
                          "Precondition: the monotonic clock must order the two submissions")

        installChild(runs: [
            makeRun(id: 0, steps: [
                makeStep(id: "first", artifacts: [older]),
                makeStep(id: "second", artifacts: [newer]),
            ])
        ])

        let envelope = await buildEnvelope(team: deMakeTargetTeam(requires: ["Release Notes"]))

        let data = try deParseData(envelope)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        let payload = try XCTUnwrap(artifacts["Release Notes"] as? [String: Any])
        XCTAssertEqual(payload["content"] as? String, "revised draft")
        XCTAssertEqual(payload["role_id"] as? String, "second",
                       "The superseded producer must not be credited with the surviving revision")
    }
}

// MARK: - awaitDelegationCompletion → envelope wiring
//
// These drive the real awaiter loop so the envelope builders + `clearDelegationFields`
// are exercised through the code path production actually takes. Branch coverage that
// `DelegationFollowupHandlersTests` / `DelegationControlsReentryTests` /
// `DelegationReviewFixesTests` do not already own.
@MainActor
final class DelegationAwaiterEnvelopeWiringTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
        service._testRegisterStepTask(stepID: deParentStepID, taskID: deParentTID)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        service = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: Fixtures

    private func makeParentRoleDef() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: deParentStepID,
            name: "Coding Agent",
            prompt: "p",
            toolIDs: [ToolNames.delegateToTeam],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowDelegationToGeneratedTeams: true
        )
    }

    private func makeParentTeam() -> Team {
        Team(
            id: "parent-team-id",
            name: "Parent Team",
            roles: [makeParentRoleDef()],
            artifacts: [],
            settings: TeamSettings(),
            graphLayout: TeamGraphLayout()
        )
    }

    private func runAwaiter(targetTeam: Team, warnings: [String] = []) async -> String {
        await service.awaitDelegationCompletion(
            childTID: deChildTID,
            parentTID: deParentTID,
            stepID: deParentStepID,
            parentRoleDef: makeParentRoleDef(),
            parentTeam: makeParentTeam(),
            targetTeam: targetTeam,
            isGeneratedFlow: false,
            generationWarnings: warnings,
            client: DENoopLLMClient(),
            config: deStubConfig(),
            delegate: delegate
        )
    }

    /// Child task in the mock's single `loadedTask` slot, carrying one produced artifact.
    private func installChildWithArtifact(name: String, closedAt: Date? = nil, failed: Bool = false) {
        var child = NTMSTask(
            id: deChildTID, title: "Delegated", supervisorTask: "brief", closedAt: closedAt)
        child.runs = [Run(id: 0, steps: [
            StepExecution(
                id: deChildStepID, role: .softwareEngineer, title: "Engineer",
                status: failed ? .failed : .done,
                artifacts: [Artifact(name: name, mimeType: "text/markdown", relativePath: nil)])
        ])]
        delegate.taskToMutate = child
    }

    // MARK: Terminal outcomes

    func testAwaiter_terminalDone_returnsSuccessEnvelopeNamingTheTargetTeam() async throws {
        installChildWithArtifact(name: "Release Notes")
        delegate.scriptedAwaitOutcomes = [.terminal(.done)]

        let envelope = await runAwaiter(targetTeam: deMakeTargetTeam(requires: ["Release Notes"]))

        let top = try deParseEnvelope(envelope)
        XCTAssertEqual(top["ok"] as? Bool, true, "envelope=\(envelope)")
        let data = try deParseData(envelope)
        XCTAssertEqual(data["team"] as? String, deChildTeamName)
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        XCTAssertNotNil(artifacts["Release Notes"],
                        "The .done arm must route through buildSuccessEnvelope and collect the child's deliverable")
        XCTAssertTrue(delegate.stopEngineCalls.isEmpty,
                      "A cleanly finished child must not be force-stopped")
    }

    /// The `baselineErrorAtEntry` snapshot exists so a stale global error — set by the
    /// PARENT or another background task before the delegation started — is never quoted
    /// back as "the child failed because …". Pre-snapshot this misattributed unrelated
    /// errors on every failed delegation.
    func testAwaiter_terminalFailed_doesNotQuoteAPreExistingGlobalError() async throws {
        delegate.lastErrorPerTaskStub[deChildTID] = "unrelated parent-side error from ten minutes ago"
        delegate.scriptedAwaitOutcomes = [.terminal(.failed)]

        let envelope = await runAwaiter(targetTeam: deMakeTargetTeam(requires: ["Release Notes"]))

        let top = try deParseEnvelope(envelope)
        XCTAssertEqual(top["ok"] as? Bool, false)
        let message = try deParseErrorMessage(envelope)
        XCTAssertTrue(message.contains("unknown failure"),
                      "An error that predates the awaiter is not attributable; got: \(message)")
        XCTAssertFalse(message.contains("unrelated parent-side error"),
                       "A pre-existing global error must never be reported as the child's failure reason")
        XCTAssertTrue(message.contains("#\(deChildTID)"),
                      "The failure must name the child task so the parent can cancel / retry it; got: \(message)")
    }

    /// Every terminal exit clears the in-flight marker (or the next `delegate_to_team` on
    /// this role is rejected as "already delegating") while the append-only history
    /// survives for the graph's delegation-history layers.
    func testAwaiter_terminalFailed_clearsActiveMarkerButKeepsHistory() async throws {
        var parent = NTMSTask(id: deParentTID, title: "Parent", supervisorTask: "x")
        parent.runs = [Run(id: 0, steps: [
            StepExecution(
                id: deParentStepID, role: .codingAgent, title: "Coding Agent", status: .running,
                activeDelegationChildID: deChildTID,
                delegationChildIDs: [11, deChildTID])
        ])]
        delegate.taskToMutate = parent  // the PARENT — clearDelegationFields mutates it
        delegate.scriptedAwaitOutcomes = [.terminal(.failed)]

        _ = await runAwaiter(targetTeam: deMakeTargetTeam(requires: []))

        let parentStep = try XCTUnwrap(delegate.taskToMutate?.runs.last?.steps.first)
        XCTAssertNil(parentStep.activeDelegationChildID,
                     "A terminal delegation must release the in-flight marker — a stale one blocks pauseRun and every follow-up tool")
        XCTAssertEqual(parentStep.delegationChildIDs, [11, deChildTID],
                       "History is append-only and must survive terminal cleanup")
    }

    /// `.needsAcceptance` is not terminal by itself: the awaiter closes the child and
    /// loops. A SUCCESSFUL close must not also force-stop the engine (that is reserved
    /// for the close-failure abort arm pinned by `DelegationReviewFixesTests`).
    func testAwaiter_needsAcceptance_closesOnceThenSucceeds_withoutStoppingTheEngine() async throws {
        installChildWithArtifact(name: "Release Notes")
        delegate.closeTaskStub = true
        delegate.scriptedAwaitOutcomes = [.terminal(.needsAcceptance), .terminal(.done)]

        let envelope = await runAwaiter(targetTeam: deMakeTargetTeam(requires: ["Release Notes"]))

        XCTAssertEqual(delegate.closedTaskIDs, [deChildTID],
                       "The child must be auto-accepted exactly once")
        XCTAssertTrue(delegate.stopEngineCalls.isEmpty,
                      "A successful close must not additionally tear the engine down")
        let top = try deParseEnvelope(envelope)
        XCTAssertEqual(top["ok"] as? Bool, true)
    }

    // MARK: parentMessageQueued (Pause-and-Decide) corners

    /// The auto-detect interrupt path can deliver an all-whitespace diagnostic. The
    /// awaiter trims before building, so the key is omitted rather than shipping "   "
    /// as if it were Supervisor guidance.
    func testAwaiter_parentMessageQueued_whitespaceOnlyText_omitsSupervisorMessage() async throws {
        delegate.scriptedAwaitOutcomes = [.parentMessageQueued(text: "   \n\t ")]

        let envelope = await runAwaiter(targetTeam: deMakeTargetTeam(requires: []))

        let data = try deParseData(envelope)
        XCTAssertEqual(data["status"] as? String, "paused_by_supervisor")
        XCTAssertNil(data["supervisor_message"],
                     "Whitespace is not guidance — the trimmed-empty message must be omitted")
    }

    /// Race re-check: the child reached `closedAt` concurrently with the interrupt.
    /// Returning a paused envelope would send the parent role into `resume_delegation` on
    /// a closed task, which recreates the engine and starts a brand-new run.
    func testAwaiter_parentMessageQueued_childAlreadyClosed_returnsSuccessNotPaused() async throws {
        installChildWithArtifact(name: "Release Notes", closedAt: MonotonicClock.shared.now())
        delegate.scriptedAwaitOutcomes = [.parentMessageQueued(text: "stop, you are looping")]

        let envelope = await runAwaiter(targetTeam: deMakeTargetTeam(requires: ["Release Notes"]))

        XCTAssertEqual(delegate.pauseRunCalls, [deChildTID],
                       "The pause still happens first — the re-check reads state AFTER it")
        let data = try deParseData(envelope)
        XCTAssertNil(data["status"],
                     "A closed child must yield the terminal SUCCESS envelope, not `paused_by_supervisor`")
        let artifacts = try XCTUnwrap(data["artifacts"] as? [String: Any])
        XCTAssertNotNil(artifacts["Release Notes"],
                        "The success envelope must still carry the finished child's deliverable")
    }

    /// Same race, other terminal direction: the child derived `.failed` while the
    /// interrupt was in flight. The parent must be told it failed, not offered
    /// cancel / resume / forward on a dead child.
    func testAwaiter_parentMessageQueued_childFailedConcurrently_returnsCommandFailed() async throws {
        installChildWithArtifact(name: "Release Notes", failed: true)
        delegate.scriptedAwaitOutcomes = [.parentMessageQueued(text: "stop")]

        let envelope = await runAwaiter(targetTeam: deMakeTargetTeam(requires: ["Release Notes"]))

        let top = try deParseEnvelope(envelope)
        XCTAssertEqual(top["ok"] as? Bool, false)
        let message = try deParseErrorMessage(envelope)
        XCTAssertTrue(message.contains("failed concurrently with a Supervisor interrupt"),
                      "The parent needs the race named explicitly, not a generic failure; got: \(message)")
    }

    // MARK: Paused envelope — canonical tool names

    /// `next_actions` is free prose the model reads to pick its follow-up. If a
    /// delegation tool is ever renamed, this prose is the one place that would silently
    /// keep naming the dead tool — so it is pinned against the `ToolNames` constants
    /// rather than string literals.
    func testPausedEnvelope_nextActionsNamesTheThreeFollowUpToolsByCanonicalName() async throws {
        let envelope = service.buildPausedEnvelope(
            childTID: deChildTID,
            targetTeamName: deChildTeamName,
            supervisorMessage: "hold on")

        let data = try deParseData(envelope)
        let nextActions = try XCTUnwrap(data["next_actions"] as? String)
        for tool in [ToolNames.cancelDelegation, ToolNames.resumeDelegation, ToolNames.forwardToTeam] {
            XCTAssertTrue(
                nextActions.contains(tool),
                "next_actions must name `\(tool)` exactly as the runtime registers it — otherwise the model calls a tool that no longer exists. got: \(nextActions)")
        }
    }

    /// The keys the Coding Agent prompt branches on. A rename here is invisible at
    /// compile time and breaks every pause-and-decide flow at runtime.
    func testPausedEnvelope_carriesTheBranchKeys() async throws {
        let envelope = service.buildPausedEnvelope(
            childTID: deChildTID,
            targetTeamName: deChildTeamName,
            supervisorMessage: "hold on")

        let data = try deParseData(envelope)
        for key in ["status", "child_task_id", "team", "supervisor_message", "next_actions"] {
            XCTAssertNotNil(data[key], "paused envelope lost the `\(key)` key: \(envelope)")
        }
    }
}

// MARK: - Task-state mutations
//
// The leaf writers behind tool-call recording, the scratchpad, the auto-answer and the
// Supervisor park. `PostTeardownWriteBarrier*Tests` already own the "torn down ⇒
// dropped" arm for these; what follows is the LIVE behaviour — the exact persisted step
// shape each one leaves behind, plus the guard arms that silently no-op.
@MainActor
final class LLMExecutionServiceTaskStateMutationTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private let stepID = "startup_software_engineer"
    private let taskID = 7

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        service = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: Fixtures

    /// Installs a live task with one step and registers the execution so the
    /// `isExecutionLive` write barrier is open.
    @discardableResult
    private func arrangeLiveStep(
        status: StepStatus = .running,
        toolCalls: [StepToolCall] = [],
        runs: [Run]? = nil
    ) -> NTMSTask {
        let liveStep = StepExecution(
            id: stepID, role: .softwareEngineer, title: "Engineer",
            status: status, toolCalls: toolCalls)
        var task = NTMSTask(id: taskID, title: "T", supervisorTask: "G")
        task.runs = runs ?? [Run(id: 0, steps: [liveStep])]
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        return task
    }

    private func persistedStep() -> StepExecution? {
        delegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID })
    }

    // MARK: persistTokenUsage

    /// A stream that reported nothing is not a measurement — writing `0/0` would both
    /// burn a disk write per iteration and overwrite a real cumulative total with zero.
    func testPersistTokenUsage_zeroUsage_attemptsNoMutation() async {
        arrangeLiveStep()
        delegate.eventLog.removeAll()

        await service.persistTokenUsage(
            stepID: stepID, taskID: taskID, usage: TokenUsage(inputTokens: 0, outputTokens: 0))

        XCTAssertTrue(delegate.eventLog.isEmpty,
                      "An all-zero usage report must not reach mutateTask — got \(delegate.eventLog)")
        XCTAssertNil(persistedStep()?.tokenUsage)
    }

    /// The two-sided `||` guard matters: a stream that produced output but reported no
    /// prompt tokens still carries real information.
    func testPersistTokenUsage_outputTokensOnly_stillPersists() async {
        arrangeLiveStep()

        await service.persistTokenUsage(
            stepID: stepID, taskID: taskID, usage: TokenUsage(inputTokens: 0, outputTokens: 42))

        XCTAssertEqual(persistedStep()?.tokenUsage?.outputTokens, 42)
        XCTAssertEqual(persistedStep()?.tokenUsage?.inputTokens, 0)
    }

    /// The caller (`runStep`) accumulates and hands over a CUMULATIVE total, so this
    /// writer must REPLACE. Accumulating here instead would double-count every iteration
    /// — and `TokenUsage.accumulate` sitting next door makes that an easy "fix" to
    /// introduce.
    func testPersistTokenUsage_secondCall_replacesRatherThanAccumulates() async {
        arrangeLiveStep()

        await service.persistTokenUsage(
            stepID: stepID, taskID: taskID, usage: TokenUsage(inputTokens: 100, outputTokens: 10))
        await service.persistTokenUsage(
            stepID: stepID, taskID: taskID, usage: TokenUsage(inputTokens: 250, outputTokens: 30))

        XCTAssertEqual(persistedStep()?.tokenUsage?.inputTokens, 250,
                       "The writer receives a cumulative total and must overwrite, not add")
        XCTAssertEqual(persistedStep()?.tokenUsage?.outputTokens, 30)
    }

    /// A step that lives only in an OLDER run is not addressable — the writer scans
    /// `runs.last` only. It must no-op rather than write into whatever step happens to
    /// share an index.
    func testPersistTokenUsage_stepOnlyInAnOlderRun_leavesEveryRunUntouched() async {
        let old = Run(id: 0, steps: [
            StepExecution(id: stepID, role: .softwareEngineer, title: "Engineer", status: .done)
        ])
        let latest = Run(id: 1, steps: [
            StepExecution(id: "other_role", role: .techLead, title: "TL", status: .running)
        ])
        arrangeLiveStep(runs: [old, latest])

        await service.persistTokenUsage(
            stepID: stepID, taskID: taskID, usage: TokenUsage(inputTokens: 5, outputTokens: 5))

        XCTAssertNil(delegate.taskToMutate?.runs[0].steps[0].tokenUsage,
                     "The older run's step must not be written to — only the latest run is addressable")
        XCTAssertNil(delegate.taskToMutate?.runs[1].steps[0].tokenUsage,
                     "A same-index step of a DIFFERENT role must never absorb the write")
    }

    // MARK: appendToolCalls

    func testAppendToolCalls_emptyArray_attemptsNoMutation() async {
        arrangeLiveStep()
        delegate.eventLog.removeAll()

        await service.appendToolCalls(stepID: stepID, taskID: taskID, toolCalls: [])

        XCTAssertTrue(delegate.eventLog.isEmpty,
                      "An empty batch must not cost a disk write — got \(delegate.eventLog)")
    }

    /// The whole batch has to land in ONE mutation: a per-call mutateTask would make N
    /// disk writes per iteration and let a mid-batch failure persist a partial batch.
    func testAppendToolCalls_batch_landsInASingleMutation() async {
        arrangeLiveStep()
        delegate.eventLog.removeAll()

        await service.appendToolCalls(stepID: stepID, taskID: taskID, toolCalls: [
            StepToolCall(name: ToolNames.readFile, argumentsJSON: #"{"path":"a.swift"}"#),
            StepToolCall(name: ToolNames.listFiles, argumentsJSON: #"{"path":"."}"#),
        ])

        XCTAssertEqual(persistedStep()?.toolCalls.map(\.name), [ToolNames.readFile, ToolNames.listFiles],
                       "Order must be preserved — the model reads its own call log positionally")
        XCTAssertEqual(delegate.eventLog.filter { $0.hasPrefix("mutate-begin") }.count, 1,
                       "The batch must be one atomic mutation, not one per call — got \(delegate.eventLog)")
    }

    func testAppendToolCalls_stepMissingFromLatestRun_appendsNothing() async {
        arrangeLiveStep(runs: [Run(id: 0, steps: [
            StepExecution(id: "other_role", role: .techLead, title: "TL", status: .running)
        ])])

        await service.appendToolCalls(stepID: stepID, taskID: taskID, toolCalls: [
            StepToolCall(name: ToolNames.readFile, argumentsJSON: "{}")
        ])

        XCTAssertEqual(delegate.taskToMutate?.runs.last?.steps.first?.toolCalls.count, 0,
                       "An unresolvable stepID must not dump its calls onto a sibling step")
    }

    // MARK: updateToolCallResult

    /// The result carries the arguments the runtime ACTUALLY executed (post-salvage /
    /// post-normalisation), so the recorded call is rewritten to match. A card showing
    /// the raw malformed arguments beside a real result is a debugging trap.
    func testUpdateToolCallResult_writesResultErrorFlagAndNormalisedArguments() async throws {
        let callID = UUID()
        arrangeLiveStep(toolCalls: [
            StepToolCall(id: callID, name: ToolNames.readFile, argumentsJSON: #"{"path":"a.swift",}"#)
        ])

        await service.updateToolCallResult(
            stepID: stepID, taskID: taskID, toolCallID: callID,
            result: ToolExecutionResult(
                toolName: ToolNames.readFile,
                argumentsJSON: #"{"path":"a.swift"}"#,
                outputJSON: #"{"ok":false,"error":{"code":"FILE_NOT_FOUND"}}"#,
                isError: true))

        let call = try XCTUnwrap(persistedStep()?.toolCalls.first)
        XCTAssertEqual(call.resultJSON, #"{"ok":false,"error":{"code":"FILE_NOT_FOUND"}}"#)
        XCTAssertEqual(call.isError, true,
                       "The error flag drives the red card — a silently-green failure hides the loop the model is stuck in")
        XCTAssertEqual(call.argumentsJSON, #"{"path":"a.swift"}"#,
                       "The executed (repaired) arguments must replace the raw emission on the record")
    }

    func testUpdateToolCallResult_unknownToolCallID_leavesExistingCallsUntouched() async throws {
        let callID = UUID()
        arrangeLiveStep(toolCalls: [
            StepToolCall(
                id: callID, name: ToolNames.readFile, argumentsJSON: "{}",
                resultJSON: "original", isError: false)
        ])

        await service.updateToolCallResult(
            stepID: stepID, taskID: taskID, toolCallID: UUID(),  // hallucinated id
            result: ToolExecutionResult(
                toolName: ToolNames.readFile, argumentsJSON: "{}",
                outputJSON: "overwritten", isError: true))

        let call = try XCTUnwrap(persistedStep()?.toolCalls.first)
        XCTAssertEqual(call.resultJSON, "original",
                       "An unmatched call id must not overwrite an unrelated call's result")
        XCTAssertEqual(call.isError, false)
    }

    // MARK: updateScratchpad

    func testUpdateScratchpad_trimsSurroundingWhitespace() async {
        arrangeLiveStep()

        await service.updateScratchpad(
            stepID: stepID, taskID: taskID, content: "\n\n  plan: read then edit  \n")

        XCTAssertEqual(persistedStep()?.scratchpad, "plan: read then edit",
                       "The scratchpad rides the prompt; leading / trailing noise is pure token cost")
    }

    /// A whitespace-only write is the model clearing its notes. Storing `"   "` would
    /// leave a bodyless section in the prompt and read as "notes exist" to every consumer
    /// that checks for nil.
    func testUpdateScratchpad_whitespaceOnly_clearsToNil() async {
        arrangeLiveStep()
        await service.updateScratchpad(stepID: stepID, taskID: taskID, content: "something")
        XCTAssertNotNil(persistedStep()?.scratchpad, "Precondition: the note landed")

        await service.updateScratchpad(stepID: stepID, taskID: taskID, content: "   \n\t ")

        XCTAssertNil(persistedStep()?.scratchpad,
                     "Whitespace-only content must clear the scratchpad, not store blanks")
    }

    /// Bracketed with the SAME clock production stamps with (`MonotonicClock`), never
    /// `Date()` — the two disagree sub-second and drift under parallel test load.
    func testUpdateScratchpad_bumpsStepUpdatedAt() async throws {
        arrangeLiveStep()
        let before = MonotonicClock.shared.now()

        await service.updateScratchpad(stepID: stepID, taskID: taskID, content: "notes")

        let after = try XCTUnwrap(persistedStep()?.updatedAt)
        XCTAssertGreaterThan(after, before,
                             "The feed's change detection keys on updatedAt — a scratchpad write that doesn't bump it renders stale")
    }

    func testUpdateScratchpad_stepOnlyInAnOlderRun_writesNothing() async {
        let old = Run(id: 0, steps: [
            StepExecution(id: stepID, role: .softwareEngineer, title: "Engineer", status: .done)
        ])
        let latest = Run(id: 1, steps: [
            StepExecution(id: "other_role", role: .techLead, title: "TL", status: .running)
        ])
        arrangeLiveStep(runs: [old, latest])

        await service.updateScratchpad(stepID: stepID, taskID: taskID, content: "notes")

        XCTAssertNil(delegate.taskToMutate?.runs[0].steps[0].scratchpad,
                     "A historical run must not be rewritten by a live step's scratchpad")
        XCTAssertNil(delegate.taskToMutate?.runs[1].steps[0].scratchpad,
                     "Nor may the write land on a same-index step belonging to another role")
    }

    // MARK: recordAutoSupervisorAnswer

    /// The autonomous in-loop answer un-parks the step so the tool loop can continue.
    /// Leaving `.needsSupervisorInput` set would keep the engine reporting a wait that
    /// nobody is going to answer.
    func testRecordAutoSupervisorAnswer_unparksTheStepAndMarksTheAnswerAutomated() async {
        arrangeLiveStep(status: .needsSupervisorInput)
        _ = await service.setNeedsSupervisorInput(
            stepID: stepID, taskID: taskID, question: "May I run the build?")
        XCTAssertEqual(persistedStep()?.status, .needsSupervisorInput, "Precondition: the step is parked")

        await service.recordAutoSupervisorAnswer(
            stepID: stepID, taskID: taskID,
            question: "May I run the build?", answer: "Approved.")

        XCTAssertEqual(persistedStep()?.supervisorAnswer, "Approved.")
        XCTAssertEqual(persistedStep()?.supervisorQuestion, "May I run the build?")
        XCTAssertEqual(persistedStep()?.needsSupervisorInput, false)
        XCTAssertEqual(persistedStep()?.status, .pending,
                       "A parked step must be released to `.pending` so the engine restarts it")
        XCTAssertEqual(persistedStep()?.supervisorAnswerWasAuto, true,
                       "The feed's 'Auto-answered' badge keys on this flag — a human answer must stay distinguishable")
    }

    /// Only the parked status is rewritten. A `.running` step that gets an auto-answer
    /// mid-loop must keep running — flipping it to `.pending` would make the engine start
    /// a second execution of a live step.
    func testRecordAutoSupervisorAnswer_runningStep_keepsItsStatus() async {
        arrangeLiveStep(status: .running)

        await service.recordAutoSupervisorAnswer(
            stepID: stepID, taskID: taskID, question: "q", answer: "a")

        XCTAssertEqual(persistedStep()?.status, .running,
                       "Only `.needsSupervisorInput` is released; every other status is left alone")
    }

    func testRecordAutoSupervisorAnswer_emptyAnswer_storesNilNotAnEmptyString() async {
        arrangeLiveStep()

        await service.recordAutoSupervisorAnswer(
            stepID: stepID, taskID: taskID, question: "   ", answer: "  \n ")

        XCTAssertNil(persistedStep()?.supervisorAnswer,
                     "An empty answer must read as 'no answer', not as an empty instruction")
        XCTAssertNil(persistedStep()?.supervisorQuestion)
    }

    /// The auto path never carries attachments, so a previous ROUND's attachment paths
    /// must be dropped — otherwise the next prompt re-attaches files the Supervisor sent
    /// for a different question.
    func testRecordAutoSupervisorAnswer_dropsThePreviousRoundsAttachmentPaths() async {
        var task = NTMSTask(id: taskID, title: "T", supervisorTask: "G")
        task.runs = [Run(id: 0, steps: [
            StepExecution(
                id: stepID, role: .softwareEngineer, title: "Engineer", status: .needsSupervisorInput,
                supervisorAnswer: "old answer",
                supervisorAnswerAttachmentPaths: ["/tmp/spec.pdf"])
        ])]
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)

        await service.recordAutoSupervisorAnswer(
            stepID: stepID, taskID: taskID, question: "next question", answer: "next answer")

        XCTAssertEqual(persistedStep()?.supervisorAnswerAttachmentPaths.isEmpty, true,
                       "Stale attachments from a prior Q&A round must not ride the new answer")
    }

    // MARK: setNeedsSupervisorInput

    /// Parking for a NEW question must wipe the previous round entirely. A surviving
    /// answer is read by the re-entry seam as "already answered", and the step resumes
    /// without ever showing the human the new question.
    func testSetNeedsSupervisorInput_clearsThePreviousRoundsAnswer() async {
        var task = NTMSTask(id: taskID, title: "T", supervisorTask: "G")
        task.runs = [Run(id: 0, steps: [
            StepExecution(
                id: stepID, role: .softwareEngineer, title: "Engineer", status: .running,
                supervisorAnswer: "yes, go ahead",
                supervisorAnswerAttachmentPaths: ["/tmp/old.png"],
                supervisorAnswerWasAuto: true)
        ])]
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)

        let applied = await service.setNeedsSupervisorInput(
            stepID: stepID, taskID: taskID, question: "  Which database?  ")

        XCTAssertTrue(applied)
        XCTAssertEqual(persistedStep()?.supervisorQuestion, "Which database?",
                       "The question is trimmed before storage")
        XCTAssertNil(persistedStep()?.supervisorAnswer,
                     "A stale answer must never survive into the next question")
        XCTAssertEqual(persistedStep()?.supervisorAnswerAttachmentPaths.isEmpty, true)
        XCTAssertEqual(persistedStep()?.supervisorAnswerWasAuto, false)
        XCTAssertEqual(persistedStep()?.needsSupervisorInput, true)
        XCTAssertEqual(persistedStep()?.status, .needsSupervisorInput)
    }

    /// An empty question still parks: the escalation caps (drift / parse-failure) call
    /// this as their escape hatch, and the feed supplies its own fallback prose. What
    /// must NOT happen is the engine transitioning to "needs input" while the writer
    /// reports failure.
    func testSetNeedsSupervisorInput_whitespaceOnlyQuestion_stillParks_withNilQuestion() async {
        arrangeLiveStep()

        let applied = await service.setNeedsSupervisorInput(
            stepID: stepID, taskID: taskID, question: "   \n ")

        XCTAssertTrue(applied,
                      "The park itself succeeded — the caller must not read this as a failed escape hatch")
        XCTAssertNil(persistedStep()?.supervisorQuestion,
                     "An empty question is stored as nil so the feed uses its fallback prose")
        XCTAssertEqual(persistedStep()?.status, .needsSupervisorInput)
    }

    /// CLAUDE.md §7: `mutateTask` returning `true` only proves persistence. When the
    /// closure short-circuits (step gone), the writer must report `false` and fire NO
    /// backstop — otherwise a retry-cap escape hatch flips the engine to "needs
    /// Supervisor input" with no question on screen.
    func testSetNeedsSupervisorInput_stepMissingFromLatestRun_returnsFalseAndFiresNoBackstop() async {
        arrangeLiveStep(runs: [Run(id: 0, steps: [
            StepExecution(id: "other_role", role: .techLead, title: "TL", status: .running)
        ])])
        delegate.eventLog.removeAll()

        let applied = await service.setNeedsSupervisorInput(
            stepID: stepID, taskID: taskID, question: "orphan question")

        XCTAssertFalse(applied,
                       "A persisted-but-unapplied mutation must report failure — `mutateTask == true` is not enough")
        XCTAssertTrue(delegate.notifyQueuedMessageBackstopCalls.isEmpty,
                      "The auto-resuming backstop must not fire for a park that never landed")
        XCTAssertTrue(delegate.eventLog.contains("mutate-begin:\(taskID)"),
                      "Precondition: the mutation WAS attempted — the guard is inside the closure")
    }

    /// Ordering contract: the backstop drains queued Supervisor messages against the
    /// newly-parked step, so it must observe the persisted park — never run inside the
    /// mutation closure.
    func testSetNeedsSupervisorInput_firesBackstopAfterTheMutationPersists() async {
        arrangeLiveStep()
        delegate.eventLog.removeAll()

        _ = await service.setNeedsSupervisorInput(
            stepID: stepID, taskID: taskID, question: "Which database?")

        XCTAssertEqual(delegate.eventLog,
                       ["mutate-begin:\(taskID)", "mutate-end:\(taskID)", "backstop:\(taskID)"],
                       "The backstop must fire strictly AFTER the park persists — got \(delegate.eventLog)")
    }

    /// The park is a stop: the step's running-task handle is dropped so nothing still
    /// claims the step is executing while it waits on a human.
    func testSetNeedsSupervisorInput_dropsTheRunningTaskHandle() async {
        arrangeLiveStep()
        service._testInjectRunningTask(stepID: stepID, taskID: taskID, runningTask: Task {})
        XCTAssertTrue(service.isStepRunning(stepID: stepID, taskID: taskID), "Precondition")

        _ = await service.setNeedsSupervisorInput(
            stepID: stepID, taskID: taskID, question: "Which database?")

        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: taskID),
                       "A parked step must stop reporting as running — the graph would otherwise show it working forever")
        XCTAssertTrue(service._testHasExecutionState(stepID: stepID, taskID: taskID),
                      "The execution ENTRY must survive: the step is suspended, not torn down, and the answer path writes through the same barrier")
    }

    // MARK: generateAutoSupervisorAnswer

    /// Detached service: there is no state to reason about and no artifact reader, so the
    /// auto-answer short-circuits to a canned approval WITHOUT paying an LLM round-trip.
    /// A regression that dropped the guard would issue a real request from a service that
    /// cannot persist the result.
    func testGenerateAutoSupervisorAnswer_withNoDelegate_returnsApprovedWithoutCallingTheClient() async {
        let task = arrangeLiveStep()
        let client = DENoopLLMClient()
        service.delegate = nil

        let answer = await service.generateAutoSupervisorAnswer(
            question: "Shall I proceed?",
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: deStubConfig())

        XCTAssertEqual(answer, "Approved.",
                       "A detached service must fall back to the canned approval rather than block the run")
        XCTAssertEqual(client.callCount, 0,
                       "The short-circuit must happen before any streaming call is issued")
    }
}
