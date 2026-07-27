import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for the **Accept Role / Request Changes** review
/// loop — Supervisor reviews a role's output mid-run and either accepts
/// (unblocking downstream) or requests changes (sending back for revision).
///
/// This complements `EndToEndSupervisorAcceptanceTests` (which focuses on
/// acceptance-mode settings) by exercising the Supervisor's review
/// controls directly on role/run state.
///
/// Pinned behaviors:
/// 1. `acceptRole` flips role status → `.accepted`, no step rerun.
/// 2. `acceptRole` on a task with no active run returns `false` (guard).
/// 3. `acceptRole` updates `roleStatuses[roleID]` only — other roles
///    untouched.
/// 4. Accepted role persists to disk → survives reopen.
/// 5. `requestRevision` with comment sets `revisionComment` on the step.
/// 6. Revision preserves `llmConversation`/artifacts (tested here as a
///    contract check — the detailed preservation tests live in
///    `EndToEndSupervisorAcceptanceTests`).
/// 7. Revision without comment is rejected or no-ops silently (error
///    surfaced).
@MainActor
final class EndToEndRoleAcceptanceReviewTests: NTMSOrchestratorTestBase {

    private func seedTaskWithNeedsAcceptanceStep(
        stepID: String = "pm",
        role: Role = .productManager
    ) async -> Int {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!

        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: stepID,
                role: role,
                title: "\(role)",
                status: .done,
                completedAt: MonotonicClock.shared.now()
            )
            var run = Run(id: 0, steps: [step],
                          roleStatuses: [stepID: .needsAcceptance])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        return id
    }

    /// Seeds a single-step task whose role sits at an arbitrary `roleStatus`,
    /// for exercising `acceptRole`'s status guard.
    private func seedTask(roleStatus: RoleExecutionStatus) async -> Int {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: "pm", role: .productManager, title: "PM",
                status: .done, completedAt: MonotonicClock.shared.now()
            )
            var run = Run(id: 0, steps: [step], roleStatuses: ["pm": roleStatus])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        return id
    }

    // MARK: - Scenario 1: acceptRole flips status

    func testAcceptRole_flipsStatusToAccepted() async {
        let id = await seedTaskWithNeedsAcceptanceStep()

        let ok = await sut.acceptRole(taskID: id, roleID: "pm")
        XCTAssertTrue(ok)

        let status = sut.loadedTask(id)?.runs.last?.roleStatuses["pm"]
        XCTAssertEqual(status, .accepted,
                       "Role status must flip to .accepted after Supervisor confirms")
    }

    // MARK: - Scenario 2: No active run → error

    func testAcceptRole_noActiveRun_returnsFalse() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!

        // Task has no runs — we never seeded one
        await sut.mutateTask(taskID: id) { task in task.runs = [] }

        let ok = await sut.acceptRole(taskID: id, roleID: "pm")
        XCTAssertFalse(ok, "Accepting with no active run must fail")
        XCTAssertNotNil(sut.lastErrorMessage,
                        "Error surfaced via lastErrorMessage")
    }

    // MARK: - Scenario 3: Siblings untouched

    func testAcceptRole_onlyAffectsTargetRole() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!

        await sut.mutateTask(taskID: id) { task in
            let a = StepExecution(id: "pm", role: .productManager, title: "PM",
                                   status: .done)
            let b = StepExecution(id: "tech_lead", role: .techLead, title: "TL",
                                   status: .done)
            var run = Run(id: 0, steps: [a, b], roleStatuses: [
                "pm": .needsAcceptance,
                "tech_lead": .needsAcceptance,
            ])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        _ = await sut.acceptRole(taskID: id, roleID: "pm")

        let statuses = sut.loadedTask(id)?.runs.last?.roleStatuses ?? [:]
        XCTAssertEqual(statuses["pm"], .accepted)
        XCTAssertEqual(statuses["tech_lead"], .needsAcceptance,
                       "Accepting PM must not touch Tech Lead's acceptance state")
    }

    // MARK: - Scenario 4: Acceptance persists across reopen

    func testAcceptRole_persistsAcrossReopen() async {
        let id = await seedTaskWithNeedsAcceptanceStep()
        _ = await sut.acceptRole(taskID: id, roleID: "pm")

        // Simulate restart
        sut = TestOrchestrator.make()
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: id)

        let status = sut.activeTask?.runs.last?.roleStatuses["pm"]
        XCTAssertEqual(status, .accepted,
                       "Accepted status must be persisted to task.json")
    }

    // MARK: - Scenario 5: requestRevision appends feedback + flips role status

    func testRequestRevision_appendsFeedbackMessage_andFlipsRoleStatus() async {
        let id = await seedTaskWithNeedsAcceptanceStep()

        await sut.requestRevision(taskID: id, roleID: "pm",
                                   comment: "Add more detail about scaling.")

        let run = sut.loadedTask(id)?.runs.last
        XCTAssertEqual(run?.roleStatuses["pm"], .revisionRequested,
                       "Role status must flip to .revisionRequested")

        let step = run?.steps.first { $0.id == "pm" }
        let feedbackMessage = step?.messages.last { $0.role == .supervisor }
        XCTAssertNotNil(feedbackMessage,
                        "Supervisor feedback message must be appended to step.messages")
        XCTAssertTrue(feedbackMessage?.content.contains("Add more detail about scaling.") ?? false,
                      "Feedback content must include the user's comment")
        XCTAssertTrue(feedbackMessage?.content.hasPrefix("Supervisor Feedback:") ?? false,
                      "Feedback message must be prefixed so the LLM recognizes it")
    }

    // MARK: - Scenario 6: requestRevision preserves conversation + artifacts

    /// Revision must not reset the LLM conversation or wipe artifacts —
    /// the role re-executes WITH its prior context so the LLM can apply
    /// the feedback incrementally.
    func testRequestRevision_preservesLLMConversationAndArtifacts() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!

        let preservedArtifact = Artifact(
            name: "Product Requirements",
            description: "Original requirements",
            relativePath: "artifacts/pm/product_requirements.md"
        )
        let preservedMessage = LLMMessage(role: .assistant, content: "Prior assistant turn")

        await sut.mutateTask(taskID: id) { task in
            var step = StepExecution(
                id: "pm", role: .productManager, title: "PM",
                status: .done,
                completedAt: MonotonicClock.shared.now(),
                artifacts: [preservedArtifact]
            )
            step.llmConversation = [preservedMessage]
            var run = Run(id: 0, steps: [step],
                          roleStatuses: ["pm": .needsAcceptance])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        await sut.requestRevision(taskID: id, roleID: "pm",
                                   comment: "Expand section 2.")

        let step = sut.loadedTask(id)?.runs.last?.steps.first { $0.id == "pm" }
        XCTAssertFalse(step?.artifacts.isEmpty ?? true,
                       "Artifacts must survive revision (feedback applied on top)")
        XCTAssertFalse(step?.llmConversation.isEmpty ?? true,
                       "LLM conversation must survive revision")
    }

    // MARK: - Scenario 7: Accepted task can still be corrected via revision

    /// Corner case: user accepts, then realizes they want changes. Before
    /// the engine moves to the next role, the Supervisor requests a
    /// revision on the just-accepted role.
    func testRequestRevision_onAcceptedRole_flipsBackToRevisionRequested() async {
        let id = await seedTaskWithNeedsAcceptanceStep()
        _ = await sut.acceptRole(taskID: id, roleID: "pm")
        XCTAssertEqual(sut.loadedTask(id)?.runs.last?.roleStatuses["pm"], .accepted)

        // Now the role is .accepted — requesting a revision must still flip it
        await sut.requestRevision(taskID: id, roleID: "pm",
                                   comment: "Actually I want changes")

        let run = sut.loadedTask(id)?.runs.last
        XCTAssertEqual(run?.roleStatuses["pm"], .revisionRequested,
                       "Post-acceptance revision must re-flip role status")
    }

    // MARK: - Scenario 8: Multiple sequential acceptances

    /// User accepts role A, then role B, then role C in quick succession.
    /// Each acceptance must flip its own role without interference.
    func testAcceptRole_multipleSequential_allApplied() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!

        await sut.mutateTask(taskID: id) { task in
            let steps = ["pm", "tech_lead", "software_engineer"].map { role in
                StepExecution(id: role, role: .softwareEngineer,
                              title: role, status: .done)
            }
            var run = Run(id: 0, steps: steps, roleStatuses: [
                "pm": .needsAcceptance,
                "tech_lead": .needsAcceptance,
                "software_engineer": .needsAcceptance,
            ])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        for role in ["pm", "tech_lead", "software_engineer"] {
            let ok = await sut.acceptRole(taskID: id, roleID: role)
            XCTAssertTrue(ok, "Accept \(role) must succeed")
        }

        let statuses = sut.loadedTask(id)?.runs.last?.roleStatuses ?? [:]
        XCTAssertEqual(statuses["pm"], .accepted)
        XCTAssertEqual(statuses["tech_lead"], .accepted)
        XCTAssertEqual(statuses["software_engineer"], .accepted)
    }

    // MARK: - Scenario 9: acceptRole status guard (honest rejection, no spurious transition)

    /// The Autovisor "accepts every done role" bug at its root: accepting a role that is
    /// already `.done` (no acceptance gate) must be REJECTED, not silently overwrite
    /// `.done` → `.accepted` and report success.
    func testAcceptRole_onDoneRole_rejectedAndUnchanged() async {
        let id = await seedTask(roleStatus: .done)
        let ok = await sut.acceptRole(taskID: id, roleID: "pm")
        XCTAssertFalse(ok, "accepting an already-done role must fail")
        XCTAssertEqual(sut.loadedTask(id)?.runs.last?.roleStatuses["pm"], .done,
                       "a rejected accept must NOT mutate the role status")
        XCTAssertEqual(sut.lastErrorMessage, "Role already completed")
    }

    func testAcceptRole_onAcceptedRole_rejected() async {
        let id = await seedTask(roleStatus: .accepted)
        let ok = await sut.acceptRole(taskID: id, roleID: "pm")
        XCTAssertFalse(ok)
        XCTAssertEqual(sut.loadedTask(id)?.runs.last?.roleStatuses["pm"], .accepted)
        XCTAssertEqual(sut.lastErrorMessage, "Role already accepted")
    }

    /// Future-proofing meta-guard: iterate EVERY `RoleExecutionStatus` (CaseIterable) and assert
    /// ONLY `.needsAcceptance` is acceptable. A status added later is auto-covered — the
    /// hand-enumerated tests above would otherwise silently leave a new case untested.
    func testAcceptRole_onlyNeedsAcceptanceIsAccepted_acrossAllStatuses() async {
        await sut.openWorkFolder(tempDir)
        for status in RoleExecutionStatus.allCases {
            let id = await sut.createTask(title: "T", supervisorTask: "x")!
            await sut.mutateTask(taskID: id) { task in
                let step = StepExecution(id: "pm", role: .productManager, title: "PM", status: .done)
                task.runs = [Run(id: 0, steps: [step], roleStatuses: ["pm": status])]
            }
            let ok = await sut.acceptRole(taskID: id, roleID: "pm")
            if status == .needsAcceptance {
                XCTAssertTrue(ok, "\(status) must be acceptable")
                XCTAssertEqual(sut.loadedTask(id)?.runs.last?.roleStatuses["pm"], .accepted)
            } else {
                XCTAssertFalse(ok, "\(status) must NOT be acceptable")
                XCTAssertEqual(sut.loadedTask(id)?.runs.last?.roleStatuses["pm"], status,
                               "\(status) must be left unchanged on rejection")
            }
        }
    }

    // MARK: - Scenario 10: degenerate / no-side-effect guard paths

    /// Degenerate guard: the step exists but has NO `roleStatuses` entry (e.g. before the
    /// engine seeds statuses). `acceptRole` must reject ("Role not found") and must NOT
    /// fabricate an `.accepted` entry from nothing — which the pre-fix unconditional write did.
    func testAcceptRole_roleHasNoStatusEntry_rejectedWithoutCreatingOne() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!
        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(id: "pm", role: .productManager, title: "PM", status: .done)
            task.runs = [Run(id: 0, steps: [step], roleStatuses: [:])]  // no entry for "pm"
        }
        let ok = await sut.acceptRole(taskID: id, roleID: "pm")
        XCTAssertFalse(ok)
        XCTAssertEqual(sut.lastErrorMessage, "Role not found: pm")
        XCTAssertNil(sut.loadedTask(id)?.runs.last?.roleStatuses["pm"],
                     "rejecting must NOT fabricate an .accepted entry from a missing key")
    }

    /// A rejected accept performs no write — the guard returns before `mutateTask`, so
    /// `run.updatedAt` is untouched (no spurious persistence on the reject path).
    func testAcceptRole_rejection_doesNotBumpRunUpdatedAt() async {
        let id = await seedTask(roleStatus: .done)
        let before = sut.loadedTask(id)?.runs.last?.updatedAt
        XCTAssertNotNil(before)
        _ = await sut.acceptRole(taskID: id, roleID: "pm")
        XCTAssertEqual(sut.loadedTask(id)?.runs.last?.updatedAt, before,
                       "a rejected accept must not persist any mutation")
    }

    /// Corner: `acceptRole` is scoped to the LATEST run. A role that was `.needsAcceptance` in
    /// an OLD run but `.done` in the current run is rejected (it reads `runs.last`), and neither
    /// run is mutated.
    func testAcceptRole_scopedToLatestRun_oldRunNeedsAcceptanceIgnored() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!
        await sut.mutateTask(taskID: id) { task in
            let oldStep = StepExecution(id: "pm", role: .productManager, title: "PM", status: .done)
            let newStep = StepExecution(id: "pm", role: .productManager, title: "PM", status: .done)
            task.runs = [
                Run(id: 0, steps: [oldStep], roleStatuses: ["pm": .needsAcceptance]),  // historical
                Run(id: 1, steps: [newStep], roleStatuses: ["pm": .done]),             // current
            ]
        }
        let ok = await sut.acceptRole(taskID: id, roleID: "pm")
        XCTAssertFalse(ok, "the latest run's .done status governs, not the old run's .needsAcceptance")
        XCTAssertEqual(sut.lastErrorMessage, "Role already completed")
        XCTAssertEqual(sut.loadedTask(id)?.runs.last?.roleStatuses["pm"], .done,
                       "the current run is untouched")
        XCTAssertEqual(sut.loadedTask(id)?.runs.first?.roleStatuses["pm"], .needsAcceptance,
                       "the historical run is never touched by acceptRole")
    }
}
