import XCTest

@testable import NanoTeams

/// A mode coordinator whose answer the test dictates, so the rebuild decision can be
/// driven without staging an engine, a run and a parked step for every case.
@MainActor
private final class ScriptedModeCoordinator: QuickCaptureModeCoordinator {
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
private final class AcceptingStalenessHotkeyManager: HotkeyManager {
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool { true }
}

/// Wave 22 — the panel's rebuild decision compared a COARSER value than the one the panel
/// renders.
///
/// `QuickCaptureFormView` takes `mode: QuickCaptureMode` **by value**, and reads the
/// supervisor question, the role header and the working role name straight out of it
/// (`answerPayload` at `QuickCaptureFormView.swift:93` has no fallback to
/// `formState.pendingAnswer`). The rebuild decision, though, compared
/// `QuickCaptureVisualMode` — a three-case enum that collapses every `.supervisorAnswer`
/// to `.answer` and discards `.taskWorking`'s `roleName`. Two materially different
/// contents were therefore "the same mode", and the hosting view was left alone.
///
/// What made it reachable: `dismissPanel()` never nils `panel` and never resets
/// `currentVisualMode`, so on the next show both `isNewPanel` and `modeChanged` are false
/// and the SAME view graph is re-ordered in.
///
/// The harm is display-only but worse for it: `submitAnswer` routes through
/// `formState.pendingAnswer`, which IS fresh — so the user reads question A and their
/// answer is delivered to question B.
@MainActor
final class QuickCapturePanelStalenessCoverageTests: XCTestCase {

    private var sut: QuickCaptureController!
    private var store: NTMSOrchestrator!
    private var dictation: DictationService!
    private var coordinator: ScriptedModeCoordinator!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        QuickCaptureController.shared._testReset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-stale-\(UUID().uuidString)", isDirectory: true)
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
        coordinator = ScriptedModeCoordinator()
        let controller = QuickCaptureController(
            hotkeyManager: AcceptingStalenessHotkeyManager(),
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

    private func answer(_ question: String, stepID: String = "role-1", taskID: Int = 7) -> QuickCaptureMode {
        .supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: stepID,
            taskID: taskID,
            role: .softwareEngineer,
            roleDefinition: nil,
            question: question,
            messageContent: nil,
            thinking: nil,
            isChatMode: true
        ))
    }

    private var contentSets: Int { sut._testPanel?._testSetContentCount ?? -1 }

    // MARK: - Reopen

    /// The reported shape: dismiss while answering task A's question, reopen once the
    /// panel would answer a DIFFERENT question. Same visual mode, different content.
    ///
    /// RED: restore `if isNewPanel || modeChanged` in `presentPanelSync` → the count does
    /// not move and the panel keeps rendering the first question.
    func testReopenWithADifferentQuestion_rebuildsTheContent() async throws {
        let c = try await makeController()
        coordinator.next = answer("Which database?")
        c._testPresentPanelSync()
        let baseline = contentSets
        XCTAssertGreaterThan(baseline, 0, "first show must build content")

        c.dismissPanel()
        coordinator.next = answer("Force-push to main?", stepID: "role-2", taskID: 9)
        c._testPresentPanelSync()

        XCTAssertGreaterThan(contentSets, baseline,
                             "A second question is different content even though both are `.answer`. "
                                 + "Leaving the old hosting view up shows a question the user is not answering.")
    }

    /// The negative control that keeps the fix from degenerating into "rebuild always":
    /// re-opening onto genuinely identical content must still be free.
    ///
    /// RED: replace the identity comparison with an unconditional `updatePanelContent()`
    /// → the count moves and this fails.
    func testReopenWithIdenticalContent_doesNotRebuild() async throws {
        let c = try await makeController()
        coordinator.next = .overlay
        c._testPresentPanelSync()
        let baseline = contentSets

        c.dismissPanel()
        c._testPresentPanelSync()

        XCTAssertEqual(contentSets, baseline,
                       "Nothing the view renders changed — rebuilding would drop the first responder "
                           + "and reset the composer's measured height for no reason.")
    }

    // MARK: - In-place refresh

    /// No dismiss involved: the same task asks a second question. `taskChanged` is false
    /// and the visual mode is `.answer` both times, so the old decision saw nothing.
    ///
    /// RED: revert `refreshPanelIfVisible` to compare `QuickCaptureVisualMode` → fails.
    func testRefreshWhileVisible_sameTaskNewQuestion_rebuilds() async throws {
        let c = try await makeController()
        coordinator.next = answer("Which database?")
        c._testPresentPanelSync()
        let baseline = contentSets

        coordinator.next = answer("Drop the column?", stepID: "role-1", taskID: 7)
        c.refreshPanelIfVisible()

        XCTAssertGreaterThan(contentSets, baseline,
                             "Same task, same visual mode, different question — the panel must follow.")
    }

    /// `DefaultQuickCaptureModeCoordinator` documents a lockstep: *"Role displayed in the
    /// title MUST equal the role that `submitQueuedMessageFromForm` targets"*. The queue
    /// target is resolved live at submit time; the title was frozen at build time. On a
    /// role handoff inside a running multi-role chat team the two diverge, and the user
    /// addresses a role that is no longer listening.
    ///
    /// RED: revert the comparison to `QuickCaptureVisualMode` → the header keeps naming
    /// the outgoing role.
    func testRefreshWhileVisible_workingRoleHandoff_rebuilds() async throws {
        let c = try await makeController()
        coordinator.next = .taskWorking(roleName: "Loremaster", isChatMode: true)
        c._testPresentPanelSync()
        let baseline = contentSets

        coordinator.next = .taskWorking(roleName: "Rogue", isChatMode: true)
        c.refreshPanelIfVisible()

        XCTAssertGreaterThan(contentSets, baseline,
                             "`QuickCaptureVisualMode` collapses both to `.working` and discards the role "
                                 + "name, which is exactly the value the header renders.")
    }

    /// The other half of the ratchet: a passive refresh that resolves to the same content
    /// must not churn the hosting view. `refreshPanelIfVisible` runs on every engine-state
    /// and task-status change, so an unconditional rebuild would thrash the composer.
    ///
    /// RED: make `refreshPanelIfVisible` rebuild unconditionally → fails.
    func testRefreshWhileVisible_nothingChanged_doesNotRebuild() async throws {
        let c = try await makeController()
        coordinator.next = .taskWorking(roleName: "Loremaster", isChatMode: true)
        c._testPresentPanelSync()
        let baseline = contentSets

        c.refreshPanelIfVisible()
        c.refreshPanelIfVisible()

        XCTAssertEqual(contentSets, baseline,
                       "Two no-op refreshes must cost nothing.")
    }
}

// MARK: - The pure decision

/// `QuickCapturePresentationPolicy.renderIdentity(of:)` is the single statement of *what
/// the form view renders out of its by-value mode*. It exists so the rebuild decision and
/// the render cannot drift again — the previous decision compared a value
/// (`QuickCaptureVisualMode`) that was designed for a different question.
@MainActor
final class QuickCaptureRenderIdentityTests: XCTestCase {

    private typealias P = QuickCapturePresentationPolicy

    private func payload(
        stepID: String = "role-1",
        taskID: Int = 7,
        question: String = "Which database?",
        messageContent: String? = nil,
        thinking: String? = nil,
        role: Role = .softwareEngineer,
        roleDefinition: TeamRoleDefinition? = nil,
        isChatMode: Bool = true
    ) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: stepID, taskID: taskID, role: role, roleDefinition: roleDefinition,
            question: question, messageContent: messageContent, thinking: thinking,
            isChatMode: isChatMode
        )
    }

    func testOverlay_isStableAcrossCalls() {
        XCTAssertEqual(P.renderIdentity(of: .overlay), P.renderIdentity(of: .overlay))
    }

    func testDistinctCategories_neverCollide() {
        let ids = Set([
            P.renderIdentity(of: .overlay),
            P.renderIdentity(of: .supervisorAnswer(payload: payload())),
            P.renderIdentity(of: .taskWorking(roleName: "Rogue", isChatMode: true)),
        ])
        XCTAssertEqual(ids.count, 3)
    }

    /// Every field the view actually renders must move the identity. Each row is one
    /// mutation of the payload; a field left out of `renderIdentity` shows up here as a
    /// collision with the baseline.
    ///
    /// RED: drop any single field from `renderIdentity`'s answer arm → that row fails.
    func testAnswerIdentity_movesWithEveryRenderedField() {
        let base = P.renderIdentity(of: .supervisorAnswer(payload: payload()))
        let variants: [(String, SupervisorAnswerPayload)] = [
            ("question", payload(question: "Drop the column?")),
            ("stepID", payload(stepID: "role-2")),
            ("taskID", payload(taskID: 8)),
            ("messageContent", payload(messageContent: "…thinking out loud")),
            ("thinking", payload(thinking: "chain of thought")),
            ("role", payload(role: .codeReviewer)),
            ("isChatMode", payload(isChatMode: false)),
        ]
        for (name, p) in variants {
            XCTAssertNotEqual(P.renderIdentity(of: .supervisorAnswer(payload: p)), base,
                              "`\(name)` is rendered by the form view, so it must move the render identity")
        }
    }

    /// The role DEFINITION supplies the avatar and the displayed role name in
    /// `SupervisorAnswerHeaderView`, so swapping it is a content change even when every
    /// scalar field is untouched.
    ///
    /// RED: drop `roleDefinition?.id` from the answer arm → fails.
    func testAnswerIdentity_movesWithTheRoleDefinition() {
        let base = P.renderIdentity(of: .supervisorAnswer(payload: payload()))
        let withDef = payload(roleDefinition: TeamRoleDefinition(
            id: "team_role_engineer", name: "Engineer", prompt: "", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies()
        ))
        XCTAssertNotEqual(P.renderIdentity(of: .supervisorAnswer(payload: withDef)), base)
    }

    /// Both `taskWorking` fields are rendered: `roleName` in the header, `isChatMode` in
    /// the choice of body (loader vs loader + queue composer).
    ///
    /// RED: collapse `taskWorking` to a constant → both assertions fail.
    func testWorkingIdentity_movesWithRoleNameAndChatMode() {
        let base = P.renderIdentity(of: .taskWorking(roleName: "Loremaster", isChatMode: true))
        XCTAssertNotEqual(P.renderIdentity(of: .taskWorking(roleName: "Rogue", isChatMode: true)), base)
        XCTAssertNotEqual(P.renderIdentity(of: .taskWorking(roleName: "Loremaster", isChatMode: false)), base)
    }

    /// Field values must not be able to smear into each other across a separator — the
    /// classic delimiter bug that makes two different contents hash the same.
    ///
    /// The fixture uses ADJACENT fields on purpose: `messageContent` and `thinking` sit
    /// next to each other, so with an empty separator both rows render the same string.
    /// A first cut split `stepID`/`question`, which are three fields apart — the values in
    /// between kept them distinct and the test passed against an empty separator, i.e. it
    /// pinned nothing.
    ///
    /// RED: join the answer arm's fields with `""` → these two collide and this fails.
    func testFieldsCannotSmearAcrossTheSeparator() {
        let a = P.renderIdentity(of: .supervisorAnswer(payload: payload(messageContent: "ab", thinking: "c")))
        let b = P.renderIdentity(of: .supervisorAnswer(payload: payload(messageContent: "a", thinking: "bc")))
        XCTAssertNotEqual(a, b)
    }
}
