import CoreGraphics
import XCTest

@testable import NanoTeams

/// Pause must stop the agent from touching the user's mouse and keyboard.
///
/// `activateTargetAndSettle` raises the target app and then waits 150 ms for window ordering
/// to settle. That wait was `try? await Task.sleep(...)` — and `try?` swallows the
/// `CancellationError` a cancelled sleep throws, so the sleep RETURNED IMMEDIATELY on Pause
/// and the click / keystroke went on to land on the user's machine, on the app that had just
/// been raised to the front. Nothing downstream re-checked: the tool-result loop that dispatches
/// this finalizer checks cancellation between results exactly zero times.
///
/// The same file's capture path always honoured cancellation — `catch is CancellationError`
/// on both `ScreenCaptureService.capture` and `VisionAnalysisService.analyze`. The input paths
/// couldn't, because nothing on them throws; the swallowed sleep was the only signal, and it
/// was thrown away. That asymmetry is the whole defect, and it lived in a file at 11% coverage.
///
/// These tests drive the real shared click/scroll path through `_testRunPointerAction`, which
/// injects `perform` — the production closure calls `InputControlService.click`, which posts a
/// CGEvent at the developer's actual cursor. A test exercising the real closure would move the
/// mouse and click for real, and would do so *precisely* on a RED run. The capture below carries
/// no `appName` / `bundleID` and the target is nil, so the activation branch resolves no app:
/// no window raise, no settle sleep, no OS side effect of any kind.
@MainActor
final class ComputerUseCancellationTests: XCTestCase, @unchecked Sendable {

    private var sut: LLMExecutionService!

    override func setUp() async throws {
        try await super.setUp()
        // Matches the sibling computer-use suites: no delegate is wired, so the persistence
        // side of `finalizeToolResult` is inert and only `conversationMessages` records the
        // append. Repository injection is required outright — CLAUDE.md §Strict DIP.
        sut = LLMExecutionService(repository: NTMSRepository())
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    /// A 100×100 pt region captured at 100×100 px with its origin at the global top-left, so
    /// image (10, 10) maps cleanly to a global point. `appName`/`bundleID` are deliberately nil:
    /// with a nil `target` that makes the activation spec unresolvable, which is what keeps this
    /// test from raising a window or sleeping.
    private static func makeCapture() -> CapturedScreen {
        CapturedScreen(
            pngBase64: "", pixelWidth: 100, pixelHeight: 100,
            regionWidthPt: 100, regionHeightPt: 100, originX: 0, originY: 0,
            targetKind: "display", appName: nil, bundleID: nil,
            windowTitle: nil, displayID: nil, pid: nil)
    }

    private struct PointerRun: Sendable {
        let performed: Bool
        let messageCount: Int
    }

    /// Runs the pointer path inside a task that is guaranteed to be cancelled first when
    /// `cancelled` is true — it spins on `Task.isCancelled` rather than racing a sleep, so the
    /// assertion is never about timing.
    private func runPointer(cancelled: Bool) async -> PointerRun {
        let service = sut!
        let capture = Self.makeCapture()
        let task = Task { @MainActor () -> PointerRun in
            if cancelled {
                while !Task.isCancelled { await Task.yield() }
            }
            var performed = false
            var messages: [ChatMessage] = []
            await service._testRunPointerAction(
                x: 10, y: 10, target: nil, warnOnMiss: true,
                stepID: "role-1", taskID: 1, capture: capture,
                conversationMessages: &messages,
                perform: { _ in performed = true; return "Clicked." })
            return PointerRun(performed: performed, messageCount: messages.count)
        }
        if cancelled { task.cancel() }
        return await task.value
    }

    // MARK: - The regression

    func testCancelledStep_synthesizesNoInput() async {
        let run = await runPointer(cancelled: true)

        XCTAssertFalse(run.performed,
                       "Pause cancelled the step — the click must not reach the user's machine")
    }

    /// A cancelled step is being torn down, so the finalizer must also append nothing: a tool
    /// result written here lands in a conversation nobody will ever send, and `finalizeToolResult`
    /// additionally persists a `[CALL]`/`[RESULT]` pair and rewrites the tool card. Silent return
    /// is what the capture path already does on `CancellationError`.
    func testCancelledStep_appendsNoToolResult() async {
        let run = await runPointer(cancelled: true)

        XCTAssertEqual(run.messageCount, 0,
                       "a cancelled step must not commit a tool result")
    }

    // MARK: - Anti-vacuity

    /// Without this the two tests above pass against a `_testRunPointerAction` that never runs
    /// anything at all — including one broken by a future change to the seam itself.
    func testLiveStep_stillClicksAndAppendsItsResult() async {
        let run = await runPointer(cancelled: false)

        XCTAssertTrue(run.performed, "a live step must still act")
        XCTAssertEqual(run.messageCount, 1, "and commit exactly one tool result")
    }
}
