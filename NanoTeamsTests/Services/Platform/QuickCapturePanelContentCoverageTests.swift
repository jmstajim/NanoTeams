import XCTest

@testable import NanoTeams

/// A `HotkeyManager` double that claims everything and never replays.
@MainActor
private final class AcceptingHotkeyManager: HotkeyManager {
    private(set) var registeredKeyCodes: [UInt32] = []
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        registeredKeyCodes.append(keyCode)
        return true
    }
}

/// Covers `QuickCaptureController.updatePanelContent()` and the four submit closures it
/// installs — 46 of the controller's 79 uncovered lines.
///
/// The gap was a WIRING gap, not an OS boundary. `updatePanelContent` bails on
/// `guard let panel, let store, let dictation`, and the existing suites supply at most
/// two of the three: `QuickCaptureControllerWiringTests` presents a real panel but never
/// sets `store`, and nothing set `dictation`. The comment on that guard explains the
/// graceful skip as a concession to `SFSpeechRecognizer` being unsafe to construct on CI
/// (CLAUDE.md #47) — but `DictationService` documents itself as lazy ("no AVFoundation /
/// Speech APIs are touched in `init()`") and eleven sites in `DictationServiceTests`
/// already build one. So the third prerequisite was always available, and the whole body
/// past the guard had simply never run.
///
/// The submit closures were dead for a second, independent reason: they were built inline
/// and captured straight into the SwiftUI view, so even a test that got past the guard
/// could not invoke one. `submitAction(for:)` is now named, which is what makes the four
/// destinations assertable.
@MainActor
final class QuickCapturePanelContentCoverageTests: XCTestCase {

    private var sut: QuickCaptureController!
    private var store: NTMSOrchestrator!
    private var dictation: DictationService!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        QuickCaptureController.shared._testReset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-content-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        sut?._testIsPanelVisible = false
        sut = nil
        store = nil
        dictation = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        QuickCaptureController.shared._testReset()
        try await super.tearDown()
    }

    /// All three prerequisites wired, plus a real work folder so `resolveMode` has
    /// something to resolve against.
    private func makeWiredController() async -> QuickCaptureController {
        let controller = QuickCaptureController(
            hotkeyManager: AcceptingHotkeyManager(),
            formState: QuickCaptureFormState(),
            selectionCapturer: InertSelectionCapturer()
        )
        store = TestOrchestrator.make()
        await store.openWorkFolder(tempDir)
        dictation = DictationService()
        controller.store = store
        controller.dictation = dictation
        sut = controller
        return controller
    }

    // MARK: - The guard

    /// The three prerequisites are equals: a missing one skips, none crashes. This is the
    /// contract the graceful `guard let panel, let store, let dictation` establishes, and
    /// it matters because the previous shape singled `dictation` out into a
    /// `preconditionFailure` — which aborted the whole XCTest worker from a leaked
    /// fire-and-forget `showPanel` Task, reported against an unrelated test
    /// (CLAUDE.md Грабли 2026-07-07).
    ///
    /// RED: turn any one of the three into a `preconditionFailure` → the corresponding
    /// call below kills the process instead of returning.
    func testUpdatePanelContent_missingAnyPrerequisite_skipsWithoutCrashing() async {
        let controller = await makeWiredController()

        controller.dictation = nil
        controller.updatePanelContent()   // no dictation

        controller.dictation = dictation
        controller.store = nil
        controller.updatePanelContent()   // no store

        controller.store = store
        controller.updatePanelContent()   // no panel

        XCTAssertNil(controller._testPanel, "no panel was ever presented")
    }

    /// The body past the guard, exercised end to end: present a panel so all three
    /// prerequisites hold, then rebuild content.
    ///
    /// RED: make `updatePanelContent` return before `panel.setContent(...)` → the
    /// content-set assertion fails.
    func testUpdatePanelContent_withEveryPrerequisite_buildsAndSetsTheForm() async throws {
        // Skipped per test, not per class: the seven tests below wire the same
        // prerequisites but never present a panel, so `updatePanelContent` still skips for
        // them and they keep running everywhere. They are the controlled half that pinned
        // the trigger to the form build — see `PanelHostingAvailability`.
        try PanelHostingAvailability.skipUnlessTheFormCanBeHosted()
        let controller = await makeWiredController()
        controller._testIsPanelVisible = false
        controller._testPresentPanelSync()

        XCTAssertNotNil(controller._testPanel, "presentPanelSync must create the panel")
        XCTAssertTrue(controller._testPanel?._testHasContent == true,
                      "the panel must have been handed a form view — an empty panel is "
                          + "the silent form of this bug: the overlay appears blank")

        // A second rebuild must be idempotent, which is what `showNewTask` and
        // `refreshPanelIfVisible` rely on when they call it on an already-visible panel.
        controller.updatePanelContent()
        XCTAssertTrue(controller._testPanel?._testHasContent == true)
    }

    /// `pendingWorkingMode` is a one-shot: `+TaskCreation` sets it after a submit so the
    /// panel flips to the loader without waiting for the engine to report `.running`.
    /// It must CLEAR on read, or the panel is pinned to the loader and the user can never
    /// get back to a composer.
    ///
    /// RED: drop `pendingWorkingMode = false` → the flag stays set and this fails.
    func testUpdatePanelContent_pendingWorkingMode_isConsumedOnce() async throws {
        try PanelHostingAvailability.skipUnlessTheFormCanBeHosted()
        let controller = await makeWiredController()
        controller._testPresentPanelSync()

        controller.pendingWorkingMode = true
        controller.updatePanelContent()

        XCTAssertFalse(controller.pendingWorkingMode,
                       "a one-shot flag left set pins the panel to the loader forever")
    }

    // MARK: - The four submit destinations

    private func answerMode(taskID: Int = 1) -> QuickCaptureMode {
        .supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: "r", taskID: taskID, role: .softwareEngineer, roleDefinition: nil,
            question: "which?", messageContent: nil, thinking: nil, isChatMode: true))
    }

    /// Non-chat working mode renders a loader with no composer, so its action must be a
    /// no-op — and specifically must NOT fall through to `createTask`, which would create
    /// a task from an empty form every time the user pressed Return on the loader.
    ///
    /// RED: change the `.disabled` arm to the `.createTask` closure → a task is created
    /// and this fails.
    func testSubmitAction_nonChatWorking_isANoOp() async {
        let controller = await makeWiredController()
        let before = store.snapshot?.tasksIndex.tasks.count ?? 0

        controller.submitAction(for: .taskWorking(roleName: "Engineer", isChatMode: false))()
        await Task.yield()

        XCTAssertEqual(store.snapshot?.tasksIndex.tasks.count ?? 0, before,
                       "a loader-only mode must not create anything")
    }

    /// Chat-mode working queues for the running role rather than creating a task.
    ///
    /// RED: wire `.queueChatMessage` to the `createTask` closure → a task appears and the
    /// queue stays empty, failing both assertions.
    func testSubmitAction_chatWorking_queuesInsteadOfCreating() async {
        let controller = await makeWiredController()
        guard let taskID = await store.createTask(title: "t", supervisorTask: "brief") else {
            return XCTFail("could not seed a task")
        }
        await store.switchTask(to: taskID)
        controller.formState.answerText = "steer the role"
        let before = store.snapshot?.tasksIndex.tasks.count ?? 0

        controller.submitAction(for: .taskWorking(roleName: "Engineer", isChatMode: true))()

        XCTAssertEqual(store.snapshot?.tasksIndex.tasks.count ?? 0, before,
                       "queueing must not create a second task")
        XCTAssertEqual(controller.formState.queuedMessages(for: taskID).count, 1,
                       "the message must land in the queue for the active task")
    }

    /// `.overlay` is the only mode that creates. Pinned so a future mode addition that
    /// forgets its arm cannot silently inherit task creation.
    ///
    /// RED: make `submitAction(for:)`'s `.createTask` arm return `{}` → no task is
    /// created and this fails.
    func testSubmitAction_overlay_createsATask() async {
        let controller = await makeWiredController()
        controller.formState.supervisorTask = "build a calculator"
        let before = store.snapshot?.tasksIndex.tasks.count ?? 0

        controller.submitAction(for: .overlay)()
        // The body is `Task { await createTask() }`; give it a bounded window.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              (store.snapshot?.tasksIndex.tasks.count ?? 0) == before {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertGreaterThan(store.snapshot?.tasksIndex.tasks.count ?? 0, before,
                             "the overlay's send button must create the task")
    }

    /// Answer mode routes to `submitAnswer`. Without a pending question there is nothing
    /// to answer, so the observable contract is that it does NOT create a task — the
    /// failure mode if the arm were mis-wired to `.createTask`.
    ///
    /// RED: wire `.submitSupervisorAnswer` to the `createTask` closure → this fails.
    func testSubmitAction_answerMode_doesNotCreateATask() async {
        let controller = await makeWiredController()
        controller.formState.answerText = "the answer"
        let before = store.snapshot?.tasksIndex.tasks.count ?? 0

        controller.submitAction(for: answerMode())()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(store.snapshot?.tasksIndex.tasks.count ?? 0, before,
                       "answering is not creating")
    }

    /// Anti-vacuity: the four modes must not all resolve to the same closure. Two modes
    /// sharing an action is exactly the regression the tests above are written against,
    /// and a `submitAction(for:)` that ignored its argument would pass several of them.
    func testSubmitAction_everyModeResolvesThroughThePolicy() async {
        let controller = await makeWiredController()
        let modes: [QuickCaptureMode] = [
            .overlay,
            .taskWorking(roleName: "r", isChatMode: true),
            .taskWorking(roleName: "r", isChatMode: false),
            answerMode()
        ]
        let routes = modes.map { QuickCapturePresentationPolicy.submitAction(for: $0) }
        XCTAssertEqual(Set(routes).count, 4,
                       "the four modes must reach four distinct destinations: \(routes)")
        // And the controller must build a closure for each without trapping.
        for mode in modes { _ = controller.submitAction(for: mode) }
    }

    // MARK: - The queue path's missing-store arm

    /// `submitQueuedMessageFromForm` guards on `store` before anything else. Reachable in
    /// production between a work-folder close and the panel's next rebuild.
    ///
    /// RED: remove the `guard let store` → this dereferences nil and crashes.
    func testSubmitQueuedMessage_withoutAStore_returnsWithoutCrashing() async {
        let controller = await makeWiredController()
        controller.formState.answerText = "orphan message"
        controller.store = nil

        controller.submitQueuedMessageFromForm()

        XCTAssertTrue(controller.formState.taskIDsWithQueuedMessages.isEmpty,
                      "with no store there is no task to queue against")
    }
}
