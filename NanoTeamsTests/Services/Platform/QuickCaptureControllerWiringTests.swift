import XCTest
@testable import NanoTeams

/// Wiring tests for `QuickCaptureController.presentPanelSync`. The pure-helper
/// surface (`QuickCaptureMode.expectsFocusableField`, panel state, mode
/// resolution) is each pinned independently; this suite verifies the *wiring*
/// between them — that `presentPanelSync` actually passes
/// `resolvedMode.expectsFocusableField` to `panel.show(expectsFocusableField:)`.
///
/// A regression like hardcoding `panel.show(expectsFocusableField: true)`
/// would still pass every unit test of the underlying helpers but silently
/// break the silent-caret routing for loader-only working mode. These tests
/// close that gap via the `_testLastShowExpectsFocusableField` spy on
/// `QuickCapturePanel`.
@MainActor
final class QuickCaptureControllerWiringTests: XCTestCase {

    var sut: QuickCaptureController!
    /// Retained for the refocus tests only. The caret restore now lives inside
    /// `updatePanelContent`, behind the same `guard let panel, let store, let dictation`
    /// as the content build — which is the honest coupling (nothing was swapped, so
    /// nothing needs restoring), but it means a refocus assertion has to supply all three.
    var store: NTMSOrchestrator!
    var dictation: DictationService!

    /// Wires the two prerequisites `setUp` deliberately leaves nil, so
    /// `updatePanelContent` runs its body instead of skipping.
    ///
    /// Wiring them is exactly what makes the SwiftUI form get built, which is what the
    /// mirror's CI runner cannot survive — so the availability skip belongs HERE rather
    /// than in `setUp`: the four tests that never call this are unaffected and keep
    /// running everywhere. They are also the controlled half of the comparison that
    /// identified the trigger (see `PanelHostingAvailability`).
    func wireContentPrerequisites() throws {
        try PanelHostingAvailability.skipUnlessTheFormCanBeHosted()
        store = TestOrchestrator.make()
        dictation = DictationService()
        sut.store = store
        sut.dictation = dictation
    }

    override func setUp() async throws {
        try await super.setUp()
        sut = QuickCaptureController.shared
        sut._testReset()
        if sut._testIsInAnswerMode { sut._testExitAnswerMode() }
        sut.formState._testClearAnswerDrafts()
        sut.formState.supervisorTask = ""
        sut.isTaskSelected = false
        sut._testForceNewTaskMode = false
        // Each test starts with the panel hidden so presentPanelSync's
        // `guard !isPanelVisible` doesn't no-op.
        sut._testIsPanelVisible = false
    }

    override func tearDown() async throws {
        if sut._testIsInAnswerMode { sut._testExitAnswerMode() }
        sut.formState.supervisorTask = ""
        sut.isTaskSelected = false
        sut._testForceNewTaskMode = false
        sut._testIsPanelVisible = false
        sut._testPanel?._testLastShowExpectsFocusableField = nil
        sut.store = nil
        sut.dictation = nil
        store = nil
        dictation = nil
        sut = nil
        try await super.tearDown()
    }

    /// Generic invariant: whatever mode `resolveMode()` produces,
    /// `presentPanelSync` must pass that mode's `expectsFocusableField` to
    /// `panel.show(...)`. The two values MUST match — if a future refactor
    /// reads from a stale property or hardcodes a literal, this fails.
    func testPresentPanelSync_passesResolvedModeFocusableFieldToPanel() {
        sut._testPresentPanelSync()

        let resolved = sut._testResolveMode()
        let recorded = sut._testPanel?._testLastShowExpectsFocusableField
        XCTAssertNotNil(recorded, "presentPanelSync must call panel.show()")
        XCTAssertEqual(recorded, resolved.expectsFocusableField,
                       "Wiring must pass `resolvedMode.expectsFocusableField`, not a stale or hardcoded value.")
    }

    /// Explicit overlay-mode wiring: no task selected → `.overlay` →
    /// `expectsFocusableField: true`. Pins one specific mode path so a future
    /// refactor that breaks JUST overlay wiring still fails here even if the
    /// generic test happens to pass for a different default mode.
    func testPresentPanelSync_overlayMode_passesTrue() {
        sut.isTaskSelected = false
        sut._testForceNewTaskMode = true  // forces overlay regardless of active task

        sut._testPresentPanelSync()

        XCTAssertEqual(sut._testPanel?._testLastShowExpectsFocusableField, true,
                       "Overlay mode renders a focusable composer; `expectsFocusableField` must be true so a missing field surfaces as a regression.")
    }

    /// Re-show preserves the new mode's value, not the previous show's.
    /// Defends against the race the property form had: if `expectsFocusableField`
    /// is ever cached at the panel level, a second show would record the old
    /// value when it should record the new one.
    func testPresentPanelSync_resetsRecordedValueOnEachShow() {
        sut._testPresentPanelSync()
        XCTAssertNotNil(sut._testPanel?._testLastShowExpectsFocusableField)

        // Simulate hide-then-show without reaching into the panel directly —
        // flip visibility back to false (test setup pattern) and re-present.
        sut._testIsPanelVisible = false
        sut._testPanel?._testLastShowExpectsFocusableField = nil

        sut._testPresentPanelSync()

        XCTAssertNotNil(sut._testPanel?._testLastShowExpectsFocusableField,
                        "Each presentPanelSync must record a fresh value — verifies show() is actually called on every show pipeline pass, not skipped after the first.")
    }

    // MARK: - showNewTask refocus wiring

    func testShowNewTask_whenAlreadyVisible_invokesRefocusInputField() async throws {
        try wireContentPrerequisites()
        sut._testPresentPanelSync()
        XCTAssertTrue(sut._testIsPanelVisible, "presentPanelSync must mark panel visible")
        let baseline = sut._testPanel?._testRefocusInvocationCount ?? -1
        XCTAssertGreaterThanOrEqual(baseline, 0, "panel must exist after presentPanelSync")

        sut.showNewTask()

        XCTAssertEqual(sut._testPanel?._testRefocusInvocationCount, baseline + 1,
                       "Visible-branch showNewTask must refocus after updatePanelContent rebuilds the NSHostingView.")
    }

    func testShowNewTask_whenHidden_doesNotInvokeRefocusInputFieldSynchronously() {
        XCTAssertFalse(sut._testIsPanelVisible)
        let baseline = sut._testPanel?._testRefocusInvocationCount ?? 0

        sut.showNewTask()

        // Hidden branch dispatches Task { await showPanel(...) }, so any
        // synchronous refocus would be in the wrong place.
        XCTAssertEqual(sut._testPanel?._testRefocusInvocationCount ?? 0, baseline,
                       "Hidden-panel path drives focus via panel.show, not refocusInputField.")
    }

    /// Spam-tap at controller wiring level: N consecutive `showNewTask()`
    /// calls must invoke `refocusInputField()` exactly N times. Defends
    /// against a future "debounce duplicate showNewTask" optimization that
    /// would silently break repeat-press caret recovery. (Panel-level
    /// coalescing of in-flight retry Tasks is intentional and orthogonal —
    /// the counter increments before Task spawn.)
    func testShowNewTask_repeatedOnVisible_invokesRefocusOncePerCall() async throws {
        try wireContentPrerequisites()
        sut._testPresentPanelSync()
        let baseline = sut._testPanel?._testRefocusInvocationCount ?? -1
        XCTAssertGreaterThanOrEqual(baseline, 0)

        sut.showNewTask()
        sut.showNewTask()
        sut.showNewTask()

        XCTAssertEqual(sut._testPanel?._testRefocusInvocationCount, baseline + 3,
                       "Each showNewTask on visible panel must refocus — spam-tap is a real scenario.")
    }

    /// Answer-mode → new-task transition: `showNewTask()` calls
    /// `formState.exitAnswerMode()` before the visible-branch refocus.
    /// If a future async refactor of `exitAnswerMode` defers the refocus,
    /// this fails — the user gets exit-from-answer but no caret in the new
    /// task field.
    func testShowNewTask_fromAnswerMode_stillRefocusesAndExitsAnswerMode() async throws {
        try wireContentPrerequisites()
        sut._testPresentPanelSync()
        sut._testEnterAnswerMode(.supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: "test-step",
            taskID: 1,
            role: .softwareEngineer,
            roleDefinition: nil,
            question: "Anything?",
            messageContent: nil,
            thinking: nil,
            isChatMode: false
        )))
        XCTAssertTrue(sut._testIsInAnswerMode)
        let baseline = sut._testPanel?._testRefocusInvocationCount ?? -1
        XCTAssertGreaterThanOrEqual(baseline, 0)

        sut.showNewTask()

        XCTAssertFalse(sut._testIsInAnswerMode, "showNewTask must exit answer mode")
        XCTAssertEqual(sut._testPanel?._testRefocusInvocationCount, baseline + 1,
                       "showNewTask must still refocus after exitAnswerMode side-effects.")
    }
}
