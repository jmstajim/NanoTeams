import XCTest
@testable import NanoTeams

/// Pins the contract that makes a reconcile deferral provably TEMPORARY.
///
/// `NTMSRepository.pinsTeamAsBusy` decides whether a task blocks its team's
/// bundled-content update. Deferral is only ever meant to last one open — the
/// banner promises "will retry on next open" — and that promise holds only if
/// something HEALS the status that caused it. The healers are:
///
///  * `openWorkFolder`, which recovers the ACTIVE task, and
///  * `recoverStaleStatusesAcrossIndex`, which recovers every task whose
///    *derived summary* status is `.running` or `.needsSupervisorInput`.
///
/// So the invariant is a subset relation:
///
///     pinsTeamAsBusy(task) ⟹ task.derivedStatusFromActiveRun() ∈ sweepable
///
/// Break it and a deferral becomes permanent: the team's prompts, tools and
/// settings never receive another bundled update, with no error and no way for
/// the user to tell. That is exactly the bug this suite was written for — a
/// paused task derives `.paused`, which the sweep skips.
///
/// This is deliberately a PROPERTY over the whole `(roleStatus, stepStatus)`
/// grid rather than a handful of examples, because the failure mode is someone
/// later widening the predicate "just a little".
final class ReconcileDeferralEquivalenceTests: XCTestCase {

    /// Statuses `recoverStaleStatusesAcrossIndex` filters for. Kept as a literal
    /// rather than referencing the orchestrator so a change there has to be a
    /// conscious edit here too.
    private static let sweepable: Set<TaskStatus> = [.running, .needsSupervisorInput]

    private static let roleStatuses: [RoleExecutionStatus] = [
        .idle, .ready, .working, .needsAcceptance, .accepted,
        .revisionRequested, .done, .failed, .skipped
    ]

    private static let stepStatuses: [StepStatus?] = [
        nil, .pending, .running, .paused, .needsSupervisorInput, .needsApproval, .done, .failed
    ]

    private let roleID = "role_a"

    private func makeTask(
        role: RoleExecutionStatus,
        step: StepStatus?,
        taskStatus: TaskStatus,
        closedAt: Date? = nil
    ) -> NTMSTask {
        let steps = step.map {
            [StepExecution(id: roleID, role: .softwareEngineer, title: "SE", status: $0)]
        } ?? []
        return NTMSTask(
            id: 0,
            title: "t",
            supervisorTask: "t",
            status: taskStatus,
            runs: [Run(id: 0, steps: steps, roleStatuses: [roleID: role], teamID: "team")],
            closedAt: closedAt,
            preferredTeamID: "team"
        )
    }

    // MARK: - The invariant

    /// Every pair the predicate calls busy must be one status recovery will sweep.
    func testBusyImpliesSweepable_acrossTheWholeGrid() {
        var busyCount = 0
        // Both `task.status` values matter: `.paused` arms the recovery latch,
        // which `derivedStatusFromActiveRun` consults to downgrade a `.running`
        // base to `.paused`. A busy pair must survive that downgrade too.
        for taskStatus in [TaskStatus.running, .paused] {
            for role in Self.roleStatuses {
                for step in Self.stepStatuses {
                    let task = makeTask(role: role, step: step, taskStatus: taskStatus)
                    guard NTMSRepository.pinsTeamAsBusy(task) else { continue }
                    busyCount += 1
                    let derived = task.derivedStatusFromActiveRun()
                    XCTAssertTrue(
                        Self.sweepable.contains(derived),
                        "pinsTeamAsBusy(role: \(role), step: \(String(describing: step)), "
                        + "task.status: \(taskStatus)) is true but derives \(derived), which "
                        + "recoverStaleStatusesAcrossIndex does NOT sweep — this deferral "
                        + "would be PERMANENT"
                    )
                }
            }
        }
        // Anti-vacuum: a predicate that returned false everywhere would satisfy
        // the implication trivially. 2 step statuses × 2 task statuses.
        XCTAssertEqual(busyCount, 4, "expected exactly the .working × {.running, .needsSupervisorInput} pairs")
    }

    /// The complement, stated positively so the predicate can't quietly shrink
    /// to `false` and still pass the invariant above.
    func testBusySet_isExactlyWorkingBesideALiveStep() {
        for role in Self.roleStatuses {
            for step in Self.stepStatuses {
                let expected = role == .working
                    && (step == .running || step == .needsSupervisorInput)
                XCTAssertEqual(
                    NTMSRepository.pinsTeamAsBusy(
                        makeTask(role: role, step: step, taskStatus: .running)
                    ),
                    expected,
                    "role: \(role), step: \(String(describing: step))"
                )
            }
        }
    }

    // MARK: - Guards

    func testClosedTask_isNeverBusy() {
        for step in Self.stepStatuses {
            let task = makeTask(
                role: .working, step: step, taskStatus: .running,
                closedAt: MonotonicClock.shared.now()
            )
            XCTAssertFalse(
                NTMSRepository.pinsTeamAsBusy(task),
                "a closed task cannot be executing (step: \(String(describing: step)))"
            )
        }
    }

    func testTaskWithNoRuns_isNeverBusy() {
        let task = NTMSTask(id: 0, title: "t", supervisorTask: "t", runs: [])
        XCTAssertFalse(NTMSRepository.pinsTeamAsBusy(task))
    }

    /// Historical runs legitimately retain `.needsAcceptance` / `.revisionRequested`
    /// forever, so scanning anything but `runs.last` would manufacture permanent
    /// deferrals. Pins the "only the last run" half of the predicate.
    func testOnlyTheLastRunIsInspected() {
        let stale = Run(
            id: 0,
            steps: [StepExecution(id: roleID, role: .softwareEngineer, title: "SE", status: .running)],
            roleStatuses: [roleID: .working],
            teamID: "team"
        )
        let current = Run(
            id: 1,
            steps: [StepExecution(id: roleID, role: .softwareEngineer, title: "SE", status: .done)],
            roleStatuses: [roleID: .done],
            teamID: "team"
        )
        let task = NTMSTask(
            id: 0, title: "t", supervisorTask: "t",
            runs: [stale, current], preferredTeamID: "team"
        )
        XCTAssertFalse(
            NTMSRepository.pinsTeamAsBusy(task),
            "a superseded run must not pin the team — only runs.last can be live"
        )
    }

    // MARK: - busyRoleIDs

    /// The banner names roles, so the list must be stable across launches.
    /// `roleStatuses` is a Dictionary — Swift seeds string hashing per process,
    /// so unsorted output would reword the message on every run.
    func testBusyRoleIDs_areSorted() {
        let ids = ["zulu", "alpha", "mike"]
        let run = Run(
            id: 0,
            steps: ids.map {
                StepExecution(id: $0, role: .softwareEngineer, title: $0, status: .running)
            },
            roleStatuses: Dictionary(uniqueKeysWithValues: ids.map { ($0, .working) }),
            teamID: "team"
        )
        let task = NTMSTask(
            id: 0, title: "t", supervisorTask: "t", runs: [run], preferredTeamID: "team"
        )
        XCTAssertEqual(NTMSRepository.busyRoleIDs(task), ["alpha", "mike", "zulu"])
    }

    /// Every blocking role is reported, not just the first — the message must
    /// not imply that resolving one is enough.
    func testBusyRoleIDs_reportsEveryBlockingRole_andSkipsIdleOnes() {
        let run = Run(
            id: 0,
            steps: [
                StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .running),
                StepExecution(id: "b", role: .productManager, title: "B", status: .done),
                StepExecution(id: "c", role: .techLead, title: "C", status: .needsSupervisorInput)
            ],
            roleStatuses: ["a": .working, "b": .working, "c": .working],
            teamID: "team"
        )
        let task = NTMSTask(
            id: 0, title: "t", supervisorTask: "t", runs: [run], preferredTeamID: "team"
        )
        XCTAssertEqual(NTMSRepository.busyRoleIDs(task), ["a", "c"])
    }

    /// A step with no `roleStatuses` entry is not a busy role: the predicate is
    /// driven by the ROLE status, and `Run.initialRoleStatuses` seeds an entry
    /// for every role in the roster.
    func testStepWithoutARoleStatusEntry_isNotBusy() {
        let run = Run(
            id: 0,
            steps: [StepExecution(id: "orphan", role: .softwareEngineer,
                                  title: "O", status: .running)],
            roleStatuses: [:],
            teamID: "team"
        )
        let task = NTMSTask(
            id: 0, title: "t", supervisorTask: "t", runs: [run], preferredTeamID: "team"
        )
        XCTAssertTrue(NTMSRepository.busyRoleIDs(task).isEmpty)
    }

    /// An empty LAST run supersedes a busy earlier one — `runs.last` is the only
    /// live run, and a fresh run starts with no steps.
    func testEmptyLastRun_supersedesABusyEarlierRun() {
        let busy = Run(
            id: 0,
            steps: [StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .running)],
            roleStatuses: ["a": .working],
            teamID: "team"
        )
        let fresh = Run(id: 1, steps: [], roleStatuses: ["a": .ready], teamID: "team")
        let task = NTMSTask(
            id: 0, title: "t", supervisorTask: "t", runs: [busy, fresh], preferredTeamID: "team"
        )
        XCTAssertFalse(NTMSRepository.pinsTeamAsBusy(task))
    }

    /// Multi-role: one busy role is enough, and an idle majority must not mask it.
    func testAnyBusyRoleInTheRunPinsTheTeam() {
        let run = Run(
            id: 0,
            steps: [
                StepExecution(id: "a", role: .productManager, title: "PM", status: .done),
                StepExecution(id: "b", role: .softwareEngineer, title: "SE", status: .running)
            ],
            roleStatuses: ["a": .done, "b": .working],
            teamID: "team"
        )
        let task = NTMSTask(
            id: 0, title: "t", supervisorTask: "t", runs: [run], preferredTeamID: "team"
        )
        XCTAssertTrue(NTMSRepository.pinsTeamAsBusy(task))
    }
}
