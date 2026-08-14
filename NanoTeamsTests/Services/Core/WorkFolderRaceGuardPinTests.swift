import XCTest

@testable import NanoTeams

/// Source-level pins for three guards in `NTMSOrchestrator+WorkFolderManagement` whose window
/// cannot be opened deterministically from a test.
///
/// Each protects the same shape: a value captured before a LONG `await`, used after it, where
/// the thing it names may have moved. `switchTeam` captures a task id and a team id, then
/// suspends in `pauseRun` — which awaits a step's cancellation handler (up to
/// `LLMConstants.cancelHandlerTimeoutSeconds`), a recursive child-pause cascade and a disk
/// write — before persisting. `setUpSearchIndexCoordinatorIfEnabled` builds a coordinator bound
/// to one folder and suspends in `start()` before publishing it.
/// `setAgentInstructionInjected` draws a conclusion from a scan another refresh may have
/// superseded.
///
/// Why pinned in source rather than behaviourally: every seam that could open those windows is
/// closed. `TeamEngine` and `LLMExecutionService` are both `final`, so neither `pause()` nor
/// `cancelStepExecution` can be overridden to switch folders mid-suspension; the repository IS
/// injectable, but `mutateTask`'s disk write runs on a `Task.detached` whose ordering against
/// the caller's resumption is not defined, so a hook there proves nothing. Adding a production
/// seam for the sole benefit of these three tests would be worse than the structural pin — and
/// a behavioural test built on "the scheduler will probably interleave" is the flake this
/// project has already paid for twice (CLAUDE.md, 2026-07-18 and 2026-08-09).
///
/// So these assert the guard EXISTS and sits between the suspension and the write. That is
/// exactly the property a behavioural test cannot observe: not "does the guard work" (it is an
/// equality check — a unit test of it would be vacuous) but "was it removed".
final class WorkFolderRaceGuardPinTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Source with `//` comments stripped.
    ///
    /// Not optional hygiene: the first cut of `testInjectedPromotion_onlyConcludesFromItsOwnScan`
    /// matched raw text, and the RED run proved it — commenting the guard out with `// MUT`
    /// left the word in place and the pin passed against code with the guard disabled. Every
    /// source-scan pin in this project strips comments for exactly this reason.
    private func workFolderManagementSource() throws -> String {
        try strippedSource("NanoTeams/Services/Core/NTMSOrchestrator+WorkFolderManagement.swift")
    }

    private func schedulingSource() throws -> String {
        try strippedSource("NanoTeams/Services/Core/NTMSOrchestrator+Scheduling.swift")
    }

    private func strippedSource(_ relativePath: String) throws -> String {
        try source(relativePath)
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let idx = line.range(of: "//")?.lowerBound else { return line }
                return String(line[..<idx])
            }
            .joined(separator: "\n")
    }

    /// Body of `func <name>` up to the next top-level `    func ` / `    private func `.
    private func body(of function: String, in text: String) throws -> String {
        guard let start = text.range(of: "func \(function)") else {
            throw XCTSkip("\(function) not found — re-point this pin at its new seam")
        }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n    func ") ?? rest.range(of: "\n    private func ")
        return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
    }

    // MARK: - switchTeam

    /// RED: delete `guard workFolderURL == folderURL else { return }` from `switchTeam` → a
    /// folder switch during `pauseRun` lets `mutateTask` bind the NEW folder's URL while the
    /// task id and team id came from the old one. Task ids are per-folder sequential ints, so
    /// the collision is the norm: folder A's team id is pinned onto an unrelated task in folder
    /// B and `TeamSwitchPlanner.filteredSteps` deletes every step whose role isn't in A's
    /// roster — that task's run history, on disk.
    func testSwitchTeam_reChecksTheFolderBetweenPauseAndPersist() throws {
        let text = try body(of: "switchTeam(to teamID: NTMSID)", in: workFolderManagementSource())
        // Assembled at runtime: a literal here would let this file's own prose satisfy a
        // future scan of the test target (CLAUDE.md, 2026-08-07).
        let guardNeedle = "guard workFolderURL == " + "folderURL"
        guard let pauseIdx = text.range(of: "await pauseRun(")?.upperBound,
              let guardIdx = text.range(of: guardNeedle)?.lowerBound,
              let writeIdx = text.range(of: "await mutateTask(")?.lowerBound
        else {
            return XCTFail(
                "switchTeam must re-check the captured work folder between `pauseRun` and "
                    + "`mutateTask`; one of the three anchors is missing")
        }
        XCTAssertTrue(
            pauseIdx < guardIdx && guardIdx < writeIdx,
            "the folder re-check must sit AFTER the suspension it guards and BEFORE the write")
    }

    // MARK: - Search index coordinator

    /// RED: relax the install guard back to `if searchIndexCoordinator != nil` → a coordinator
    /// built for folder A is published after A has been closed. Nothing tears it down (the
    /// switch's own teardown already ran against a nil slot), so its FSEventStream and index
    /// writes keep running against the previous project, default storage acquires an index the
    /// method's own doc forbids, and `exploratory_search` resolves postings from one folder
    /// while executing against another.
    func testCoordinatorInstall_reChecksTheFolderAfterStart() throws {
        let text = try body(
            of: "setUpSearchIndexCoordinatorIfEnabled()", in: workFolderManagementSource())
        guard let startIdx = text.range(of: "await coordinator.start()")?.upperBound,
              let assignIdx = text.range(of: "searchIndexCoordinator = coordinator")?.lowerBound
        else { return XCTFail("the install anchors are missing") }

        let between = String(text[startIdx..<assignIdx])
        XCTAssertTrue(
            between.contains("workFolderURL == " + "url"),
            "the coordinator must not be published for a folder that is no longer open")
        XCTAssertTrue(
            between.contains("await coordinator.stop()"),
            "the coordinator we built must be torn down when we lose either race")
    }

    // MARK: - Agent-instruction promotion

    /// RED: drop `authoritative` from the condition → a scan superseded by any concurrent
    /// refresh (a second grid tick, or any `startRun` while Settings is open) is treated as
    /// evidence, and the user's just-persisted setting is rolled back with a wrong explanation
    /// about a perfectly readable file.
    func testInjectedPromotion_onlyConcludesFromItsOwnScan() throws {
        let text = try body(
            of: "setAgentInstructionInjected(relativePath:", in: workFolderManagementSource())
        let bindNeedle = "let authoritative = await " + "refreshAgentInstructions()"
        XCTAssertTrue(
            text.contains(bindNeedle),
            "the promotion must observe whether its own scan was published")
        guard let bindIdx = text.range(of: bindNeedle)?.upperBound,
              let concludeIdx = text.range(of: "injectedFiles.contains")?.lowerBound
        else { return XCTFail("the conclusion anchor is missing") }
        XCTAssertTrue(
            String(text[bindIdx..<concludeIdx]).contains("authoritative"),
            "the conclusion must be gated on the scan being this call's own")
    }

    /// Guards the three pins above against silently scanning nothing — a rename or an extraction
    /// behind a helper would make every `range(of:)` above miss and the assertions vacuous.
    ///
    /// RED: rename or extract any of the five anchors (hoist the `pauseRun`/`mutateTask` pair
    /// into a helper, or rename `searchIndexCoordinator`) → this reds while the three pins above
    /// go quietly vacuous. That is the point: the failure lands here, where the invariant is
    /// written down, instead of on three assertions that silently stopped scanning anything.
    func testThePinsAreNotVacuous() throws {
        let text = try workFolderManagementSource()
        for anchor in [
            "await pauseRun(", "await mutateTask(", "await coordinator.start()",
            "searchIndexCoordinator = coordinator", "injectedFiles.contains",
        ] {
            XCTAssertTrue(text.contains(anchor), "anchor vanished: \(anchor)")
        }
        let scheduling = try schedulingSource()
        for anchor in ["await mutateTask(", "await pauseRun("] {
            XCTAssertTrue(scheduling.contains(anchor), "scheduling anchor vanished: \(anchor)")
        }
    }

    // MARK: - Run-timeout watchdog

    /// The fourth site of the same shape, and the one the guard was never generalized to.
    /// `fireRecurrence` and `reconcileMissedRecurrences` — same file, same poll tick, same
    /// cooperative cancellation — both capture the folder at entry and re-check it after every
    /// suspension, with a comment explaining that a resumed pass resolves its captured task id
    /// against the NEW folder. `evaluateRunTimeouts` samples its ids from `taskEngineStates`
    /// once, then suspends twice per iteration, and had no re-check at all.
    ///
    /// RED: delete either `guard workFolderURL == folderURL else { return }` from
    /// `evaluateRunTimeouts` → a folder switch during `mutateTask` / `pauseRun` lets the next
    /// iteration stamp `timedOutAt` on, and pause, an unrelated same-numbered task in the new
    /// folder. Task ids are per-folder sequential ints, so the collision is the norm; the mark
    /// is persisted, renders as "(timed out)" in the run-history picker for good, and is
    /// reported to the Autovisor as `timed_out: true`.
    ///
    /// Behavioural rather than structural was considered and rejected for the reason stated at
    /// the top of this file: `mutateTask`'s write runs on a `Task.detached` whose ordering
    /// against the caller's resumption is undefined, so a repository hook proves nothing.
    func testRunTimeouts_reChecksTheFolderAcrossBothSuspensions() throws {
        let text = try body(of: "evaluateRunTimeouts(now:", in: schedulingSource())
        let guardNeedle = "guard workFolderURL == " + "folderURL"
        XCTAssertTrue(
            text.contains("let folderURL = " + "workFolderURL"),
            "the watchdog must capture the folder it sampled its task ids from")

        guard let loopIdx = text.range(of: "for taskID in activeIDs")?.upperBound,
              let mutateIdx = text.range(of: "await mutateTask(")?.lowerBound,
              let pauseIdx = text.range(of: "await pauseRun(")?.lowerBound
        else { return XCTFail("the watchdog's anchors are missing") }

        // One re-check inside the loop before the read that feeds the writes (covers the
        // PREVIOUS iteration's two suspensions), and one between the two suspensions of THIS
        // iteration.
        XCTAssertTrue(
            String(text[loopIdx..<mutateIdx]).contains(guardNeedle),
            "the loop body must re-check the folder before acting on an id sampled before it")
        XCTAssertTrue(
            String(text[mutateIdx..<pauseIdx]).contains(guardNeedle),
            "a switch during the persist must not be followed by a pause in the new folder")
    }

    /// The other half of the same function: which clock its budget is measured on.
    /// Kept here rather than with the behavioural clock tests because it is the same
    /// "a value captured on one side of a boundary is used on the other" family, and because
    /// the signature is the whole defence — `RunTimeoutClockCoverageTests` proves the
    /// behaviour, this proves nobody quietly re-defaulted it.
    ///
    /// RED: change the default back to `Date()` → both assertions here and two behavioural
    /// tests red together.
    func testRunTimeouts_defaultClockIsTheOneThatStampsTheRun() throws {
        let text = try schedulingSource()
        XCTAssertTrue(
            text.contains("func evaluateRunTimeouts(now: Date = " + "MonotonicClock.shared.now())"),
            "the budget is measured against `Run.createdAt`, a MonotonicClock stamp")
        XCTAssertTrue(
            try body(of: "fireRecurrence(taskID:", in: text).contains("recurrence.isDue(now: now)"),
            "the recurrence half still compares wall-clock `now` against a wall-clock "
                + "`nextFireAt` — this file deliberately uses two clocks")
    }
}
