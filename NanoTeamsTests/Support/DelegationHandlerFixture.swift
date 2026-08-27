import XCTest

@testable import NanoTeams

extension XCTestCase {

    /// Suspends a real `delegate_to_team`-shaped handler on `childID` and waits until the
    /// awaiter can see it.
    ///
    /// Pause and resume ask `TaskCompletionAwaiter.hasWaiters` — the PROCESS-lifetime fact —
    /// not `step.activeDelegationChildID`, which outlives the process. A fixture that seeds
    /// only the durable marker therefore describes a step that is NOT mid-delegation, and the
    /// verbs are right to skip it. Suites used to seed exactly that and assert the step keeps
    /// running "so its handler keeps awaiting the child", with no handler anywhere: green
    /// against the old predicate, and a defect recorded as desired behaviour (CLAUDE.md #63).
    ///
    /// Lives here rather than in `NTMSOrchestratorTestBase` because the suites that need it
    /// are split — some subclass the base, some build their own store as a plain `XCTestCase`.
    /// One home either way (#112: `Support`, on the synced side).
    ///
    /// Returns the handler `Task` so the caller can cancel it. `completionAwaiter.cancelAll`
    /// resumes the continuation; leaving it suspended leaks into the next test.
    @MainActor
    @discardableResult
    func registerSuspendedDelegationHandler(
        on store: NTMSOrchestrator,
        childID: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Task<Void, Never> {
        let handler = Task { @MainActor in
            _ = await store.completionAwaiter.register(taskID: childID)
        }
        var attempts = 0
        while !store.completionAwaiter.hasWaiters(for: childID), attempts < 50 {
            try? await Task.sleep(for: .milliseconds(1))
            attempts += 1
        }
        XCTAssertTrue(
            store.completionAwaiter.hasWaiters(for: childID),
            "premise: a delegate_to_team handler must be suspended on child #\(childID) — "
                + "without it the step is NOT mid-delegation and the verb is right to skip it",
            file: file, line: line
        )
        return handler
    }
}
