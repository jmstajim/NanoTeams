import XCTest
@testable import NanoTeams

/// `reportingError` — how the Autovisor learns whether a `control_task` verb worked.
///
/// It used to answer by snapshotting `lastErrorMessage` across the `await`, which fails in
/// BOTH directions and reports `ok:true` for a failed operation either way:
///
///  - the error banner CONSUMES that slot (writes nil) on any render, and every wrapped op
///    suspends again after setting the error — `removeTask` runs `reconcileChatModelResidency`,
///    which hops to an actor and may make a network call — so the post-await read sees nil;
///  - a REPEATED identical error never differs from the snapshot even when nothing consumed it.
///
/// The consequence is not cosmetic: told a task was deleted when it is still on disk and
/// still in `tasks_index.json`, the manager keeps it in its "ONE TASK IN FLIGHT" slot and
/// keeps firing its recurrence. Same class as the one `retryTeamGenerationReportingResult`
/// documents; that one reads durable task state instead, which these verbs do not have.
@MainActor
final class AutovisorReportingErrorTests: NTMSOrchestratorTestBase {

    func testErrorConsumedByTheBannerMidOperation_isStillReported() async {
        let result = await sut._testReportingError("Deleted task #1.") {
            self.sut.lastErrorMessage = "Failed to delete task #1."
            // Exactly what `ErrorBannerView` does when SwiftUI renders during the
            // operation's own later suspension points.
            self.sut.lastErrorMessage = nil
        }

        XCTAssertFalse(result.ok, "a consumed banner must not read as success")
        XCTAssertEqual(result.message, "Failed to delete task #1.")
    }

    func testRepeatedIdenticalError_isStillReported() async {
        sut.lastErrorMessage = "Failed to delete task #1."

        let result = await sut._testReportingError("Deleted task #1.") {
            self.sut.lastErrorMessage = "Failed to delete task #1."
        }

        XCTAssertFalse(
            result.ok, "an error identical to a prior one is still THIS op's failure")
        XCTAssertEqual(result.message, "Failed to delete task #1.")
    }

    func testNoError_reportsSuccess() async {
        sut.lastErrorMessage = "some earlier, unrelated failure"

        let result = await sut._testReportingError("Deleted task #1.") { }

        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.message, "Deleted task #1.")
    }

    /// A stale error from BEFORE the op must not be attributed to it — the counter is what
    /// separates "an error exists" from "this op produced one".
    func testPreexistingErrorLeftUntouched_reportsSuccess() async {
        sut.lastErrorMessage = "earlier failure"
        _ = sut.lastErrorMessage  // the banner has not consumed it

        let result = await sut._testReportingError("Renamed task #1.") { }

        XCTAssertTrue(result.ok, result.message)
    }

    // MARK: - The mechanism

    func testErrorSurfaceCount_bumpsOnEveryNonNilAssignment_andNeverOnNil() {
        let start = sut.errorSurfaceCount

        sut.lastErrorMessage = "a"
        XCTAssertEqual(sut.errorSurfaceCount, start + 1)

        sut.lastErrorMessage = "a"          // repeated identical
        XCTAssertEqual(sut.errorSurfaceCount, start + 2)

        sut.lastErrorMessage = nil          // banner consumption
        XCTAssertEqual(sut.errorSurfaceCount, start + 2, "a nil write is not an error")
        XCTAssertEqual(
            sut.lastSurfacedError, "a", "the message must survive banner consumption")
    }
}
