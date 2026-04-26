import XCTest

@testable import NanoTeams

/// User-path tests for the shared work-folder-context generation state on
/// `NTMSOrchestrator`. Both the Settings card and the Sidebar work-folder card
/// drive the same `isGeneratingWorkFolderContext` flag through
/// `startGeneratingWorkFolderContext` / `cancelWorkFolderContextGeneration`,
/// so a single bad transition would desync the two surfaces.
///
/// Tests assert state transitions only — the actual LLM streaming call is
/// covered by `WorkFolderManagementServiceTests`. We cancel each in-flight task
/// synchronously after asserting the flip so no real network call resolves.
@MainActor
final class WorkFolderContextGenerationTests: NTMSOrchestratorTestBase {

    // MARK: - Start path

    /// Clicking "Generate" in either surface flips the flag synchronously so
    /// the other surface re-renders into its "Generating…" branch on the same
    /// run loop.
    func testStart_flipsFlagSynchronously() async {
        await sut.openWorkFolder(tempDir)

        XCTAssertFalse(sut.isGeneratingWorkFolderContext)

        sut.startGeneratingWorkFolderContext()

        XCTAssertTrue(sut.isGeneratingWorkFolderContext,
                      "Flag must flip before the spawned Task awaits — otherwise " +
                      "the second surface would miss the generating state during " +
                      "the network round-trip.")

        sut.cancelWorkFolderContextGeneration()
    }

    /// Re-clicking "Generate" while a generation is already in flight must be
    /// a no-op. Without the guard, the second click would replace the Task
    /// handle, leaving the original task uncancellable.
    func testStart_whileAlreadyGenerating_isNoOp() async {
        await sut.openWorkFolder(tempDir)

        sut.startGeneratingWorkFolderContext()
        XCTAssertTrue(sut.isGeneratingWorkFolderContext)

        // Second start — must not flip anything off, must not lose the original task.
        sut.startGeneratingWorkFolderContext()
        XCTAssertTrue(sut.isGeneratingWorkFolderContext,
                      "Idempotent start must keep the flag true")

        // Cancel must still abort the original task.
        sut.cancelWorkFolderContextGeneration()
        XCTAssertFalse(sut.isGeneratingWorkFolderContext)
    }

    /// Without an open work folder the action is meaningless — the LLM call
    /// has nothing to read. Both UI surfaces are hidden in that state, but the
    /// guard belongs on the orchestrator so a stray notification or hotkey
    /// can't bypass it.
    func testStart_withoutWorkFolder_isNoOp() {
        XCTAssertNil(sut.workFolderURL)

        sut.startGeneratingWorkFolderContext()

        XCTAssertFalse(sut.isGeneratingWorkFolderContext,
                       "Must not flip flag when there's no folder to generate against")
    }

    // MARK: - Cancel path

    /// Cancelling during generation: flag clears so both surfaces hide the
    /// spinner, and the user sees an info message acknowledging the stop.
    func testCancel_duringGeneration_clearsFlagAndShowsInfo() async {
        await sut.openWorkFolder(tempDir)

        sut.startGeneratingWorkFolderContext()
        XCTAssertTrue(sut.isGeneratingWorkFolderContext)

        sut.cancelWorkFolderContextGeneration()

        XCTAssertFalse(sut.isGeneratingWorkFolderContext)
        XCTAssertEqual(sut.lastInfoMessage, "Generation stopped",
                       "User-facing confirmation belongs in lastInfoMessage")
    }

    /// Cancelling when nothing is running must not surface a phantom
    /// "Generation stopped" toast — that would confuse the user when, e.g.,
    /// switching work folders triggers the cancel pathway pre-emptively.
    func testCancel_whenNotGenerating_isNoOp() async {
        await sut.openWorkFolder(tempDir)
        XCTAssertNil(sut.lastInfoMessage)

        sut.cancelWorkFolderContextGeneration()

        XCTAssertFalse(sut.isGeneratingWorkFolderContext)
        XCTAssertNil(sut.lastInfoMessage,
                     "Cancel must not set an info message when nothing was running")
    }

    /// Repeated cancels are idempotent — second cancel leaves state untouched
    /// and does not stomp the user's info-message slot with a duplicate toast.
    func testCancel_repeatedCalls_isIdempotent() async {
        await sut.openWorkFolder(tempDir)
        sut.startGeneratingWorkFolderContext()

        sut.cancelWorkFolderContextGeneration()
        XCTAssertEqual(sut.lastInfoMessage, "Generation stopped")
        sut.lastInfoMessage = nil

        sut.cancelWorkFolderContextGeneration()

        XCTAssertFalse(sut.isGeneratingWorkFolderContext)
        XCTAssertNil(sut.lastInfoMessage,
                     "Second cancel must not re-toast")
    }

    // MARK: - Cross-surface synchronization

    /// Settings starts → Sidebar can cancel and vice versa, since both surfaces
    /// route through the same orchestrator methods. This is the headline user
    /// path the feature exists for.
    func testStartFromOneSurface_canBeCancelledFromAnother() async {
        await sut.openWorkFolder(tempDir)

        // "Settings" clicks Generate.
        sut.startGeneratingWorkFolderContext()
        XCTAssertTrue(sut.isGeneratingWorkFolderContext)

        // "Sidebar" clicks the spinner to cancel.
        sut.cancelWorkFolderContextGeneration()
        XCTAssertFalse(sut.isGeneratingWorkFolderContext)
        XCTAssertEqual(sut.lastInfoMessage, "Generation stopped")
    }
}
