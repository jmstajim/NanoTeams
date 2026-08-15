import XCTest

@testable import NanoTeams

@MainActor
private final class FocusStubModeCoordinator: QuickCaptureModeCoordinator {
    var next: QuickCaptureMode = .overlay
    func resolveMode(
        isTaskSelected: Bool,
        activeTask: NTMSTask?,
        engineState: TeamEngineState?,
        activeTeam: Team?,
        forceNewTaskMode: Bool
    ) -> QuickCaptureMode { next }
}

@MainActor
private final class AcceptingFocusHotkeyManager: HotkeyManager {
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool { true }
}

/// Wave 22 — who puts the caret back after the hosting view is replaced.
///
/// `QuickCapturePanel.setContent` builds a NEW `NSHostingView` and assigns it to
/// `contentView`, taking the old subtree — and the window's first responder with it — out
/// of the hierarchy. Exactly two things ever restore it: `show(expectsFocusableField:)`,
/// which runs on the present path only, and `refocusInputField()`. Of the three composers
/// the panel can render, only the task-creation one self-heals via
/// `autofocusOnAppear: true`; the answer composer and the chat-queue composer do not.
///
/// So a rebuild into answer or chat-working mode left a visible panel that accepted no
/// keystrokes — and silently, because the "could not focus the input field" banner is
/// wired to the retry loop that was never started.
///
/// The carried claim said four of the five rebuild sites were affected. Re-derivation says
/// otherwise: `presentPanelSync` is covered by the `show(...)` that follows it, and a
/// rebuild into new-task mode self-heals. What was genuinely uncovered is
/// `refreshPanelIfVisible` and the two post-submit rebuilds in `+TaskCreation`.
@MainActor
final class QuickCaptureFocusRestorationCoverageTests: XCTestCase {

    private var sut: QuickCaptureController!
    private var store: NTMSOrchestrator!
    private var dictation: DictationService!
    private var coordinator: FocusStubModeCoordinator!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        QuickCaptureController.shared._testReset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-focus-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        sut?._testIsPanelVisible = false
        sut = nil
        store = nil
        dictation = nil
        coordinator = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        QuickCaptureController.shared._testReset()
        try await super.tearDown()
    }

    /// Every test here drives a rebuild, so the availability skip lives in the shared
    /// helper rather than per test — see `PanelHostingAvailability`. It must run BEFORE
    /// the controller is wired: the abort happens while the form is built.
    private func makeController() async throws -> QuickCaptureController {
        try PanelHostingAvailability.skipUnlessTheFormCanBeHosted()
        coordinator = FocusStubModeCoordinator()
        let controller = QuickCaptureController(
            hotkeyManager: AcceptingFocusHotkeyManager(),
            modeCoordinator: coordinator,
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

    private var refocuses: Int { sut._testPanel?._testRefocusInvocationCount ?? -1 }
    private var keyPulls: Int { sut._testPanel?._testKeyPullCount ?? -1 }

    private func answer(_ question: String) -> QuickCaptureMode {
        .supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: "role-1", taskID: 7, role: .softwareEngineer, roleDefinition: nil,
            question: question, messageContent: nil, thinking: nil, isChatMode: true
        ))
    }

    // MARK: - The restore

    /// The commonest flow in the app: the panel is open watching a chat task work, the LLM
    /// asks a question, the panel flips to answer mode. Before the fix the user typed into
    /// a window with no first responder and nothing happened.
    ///
    /// RED: delete the `panel.refocusInputField(...)` call from `updatePanelContent` → the
    /// count does not move.
    func testRebuildWhileVisible_intoAnswerMode_restoresTheResponder() async throws {
        let c = try await makeController()
        coordinator.next = .taskWorking(roleName: "Coding Assistant", isChatMode: true)
        c._testPresentPanelSync()
        let baseline = refocuses

        coordinator.next = answer("Which database?")
        c.refreshPanelIfVisible()

        XCTAssertEqual(refocuses, baseline + 1,
            "A rebuild into a composer-bearing mode must put the caret back.")
    }

    /// A loader-only working mode renders no field at all. `refocusInputField` hardcodes
    /// `expectsFocusableField: true`, so running it here would exhaust the retry loop and
    /// fire the silent-caret banner for a panel that legitimately has nothing to focus —
    /// turning a fix into a new false alarm.
    ///
    /// RED: drop the `currentMode.expectsFocusableField` gate → the count moves and this
    /// fails.
    func testRebuildWhileVisible_intoLoaderOnlyWorkingMode_doesNotRefocus() async throws {
        let c = try await makeController()
        coordinator.next = .overlay
        c._testPresentPanelSync()
        let baseline = refocuses

        coordinator.next = .taskWorking(roleName: "Engineer", isChatMode: false)
        c.refreshPanelIfVisible()

        XCTAssertEqual(refocuses, baseline,
            "Non-chat working mode is the one legitimate no-field case.")
    }

    /// The present path already runs the retry loop through `show(expectsFocusableField:)`,
    /// which additionally passes the honest expectation instead of a hardcoded `true`.
    /// Refocusing from `updatePanelContent` too would start a second loop that immediately
    /// cancels the first.
    ///
    /// RED: drop the `isPanelVisible` gate → the count moves on the present path.
    func testRebuildOnThePresentPath_leavesFocusToShow() async throws {
        let c = try await makeController()
        coordinator.next = answer("Which database?")

        c._testPresentPanelSync()

        XCTAssertEqual(c._testPanel?._testRefocusInvocationCount, 0,
            "`show(expectsFocusableField:)` owns focus on the present path.")
        XCTAssertNotNil(c._testPanel?._testLastShowExpectsFocusableField,
            "…and it really did run.")
    }

    // MARK: - Key focus

    /// Restoring the caret and TAKING the keyboard are separable, and only the first is
    /// safe on a passive rebuild: `refreshPanelIfVisible` runs on engine transitions and
    /// sidebar navigation, where the main window is key on purpose.
    ///
    /// RED: make `updatePanelContent`'s call `pullKeyBack: true` → the key-pull count moves
    /// and the panel steals focus from whatever the user is typing in.
    func testPassiveRebuild_restoresTheCaretWithoutTakingKeyFocus() async throws {
        let c = try await makeController()
        coordinator.next = .taskWorking(roleName: "Coding Assistant", isChatMode: true)
        c._testPresentPanelSync()
        let baselineRefocus = refocuses
        let baselineKeyPull = keyPulls

        coordinator.next = answer("Which database?")
        c.refreshPanelIfVisible()

        XCTAssertEqual(refocuses, baselineRefocus + 1, "caret restored")
        XCTAssertEqual(keyPulls, baselineKeyPull, "…but key focus left where the user put it")
    }

    /// `showNewTask` is the opposite case and the reason the key-pull exists at all: it is
    /// reachable from the sidebar `+`, which has just made the MAIN window key, so the
    /// panel must take it back or the caret is invisible even once the responder is set.
    ///
    /// RED: change `showNewTask`'s call to `updatePanelContent()` → the key-pull count does
    /// not move.
    func testShowNewTaskWhileVisible_pullsKeyFocusBack() async throws {
        let c = try await makeController()
        coordinator.next = .overlay
        c._testPresentPanelSync()
        let baselineKeyPull = keyPulls
        let baselineRefocus = refocuses

        c.showNewTask()

        XCTAssertEqual(refocuses, baselineRefocus + 1,
            "still exactly one refocus per showNewTask — the restore moved into "
            + "updatePanelContent, it did not double up")
        XCTAssertEqual(keyPulls, baselineKeyPull + 1,
            "an explicit request for the panel takes key back")
    }
}
