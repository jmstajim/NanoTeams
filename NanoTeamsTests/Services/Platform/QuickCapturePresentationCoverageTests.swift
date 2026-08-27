import XCTest

@testable import NanoTeams

// MARK: - Test doubles

/// `HotkeyManager` double that can REFUSE a combo, standing in for one another
/// app already owns. The existing double in `ScreenInputHotkeyTests` is
/// `private` to that file, and no test ever populated its `refusedKeyCodes`, so
/// `setup`'s "couldn't claim the shortcut" banner had never been driven.
@MainActor
private final class RefusingHotkeyManager: HotkeyManager {
    var refusedKeyCodes: Set<UInt32> = []
    private(set) var registeredKeyCodes: [UInt32] = []
    /// Retained exactly as the production singleton retains them. NEVER
    /// invoked here — the open handler calls `togglePanel()` and the clip
    /// handler kicks off a real ⌘C capture.
    private(set) var handlers: [UInt32: () -> Void] = [:]

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        guard !refusedKeyCodes.contains(keyCode) else { return false }
        registeredKeyCodes.append(keyCode)
        handlers[id] = handler
        return true
    }
}

// MARK: - Presentation policy (pure)

/// Covers `QuickCapturePresentationPolicy`, the two routing decisions split out
/// of `QuickCaptureController.togglePanel` / `.updatePanelContent`. Neither had
/// any coverage: `togglePanel` is unreferenced by the entire test target, and
/// `updatePanelContent` always early-returns in tests (`dictation` is nil —
/// `DictationService` can't safely be constructed on CI, CLAUDE.md #47), so all
/// four submit branches were dead.
@MainActor
final class QuickCapturePresentationPolicyTests: XCTestCase {

    private func answerPayload(isChatMode: Bool = false) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: "role-1",
            taskID: 7,
            role: .softwareEngineer,
            roleDefinition: nil,
            question: "Which approach?",
            messageContent: nil,
            thinking: nil,
            isChatMode: isChatMode
        )
    }

    // MARK: toggleRoute

    /// Full 2×2 truth table. The `hasOpenWorkFolder` split is the documented
    /// warm/cold path: ⌃⌥⌘0 with a folder already open must present on the
    /// caller's turn, because the `Task` hop the cold path needs is
    /// perceptible on a keyboard shortcut.
    func testToggleRoute_truthTable() {
        typealias P = QuickCapturePresentationPolicy
        XCTAssertEqual(P.toggleRoute(isPanelVisible: true, hasOpenWorkFolder: true), .dismiss)
        XCTAssertEqual(P.toggleRoute(isPanelVisible: true, hasOpenWorkFolder: false), .dismiss)
        XCTAssertEqual(P.toggleRoute(isPanelVisible: false, hasOpenWorkFolder: true), .presentSynchronously)
        XCTAssertEqual(P.toggleRoute(isPanelVisible: false, hasOpenWorkFolder: false), .bootstrapThenPresent)
    }

    /// Visibility dominates: a visible panel is dismissed regardless of work
    /// folder state. Inverting this would make ⌃⌥⌘0 present a second time over
    /// an already-open panel instead of toggling it shut.
    func testToggleRoute_visibilityDominatesWorkFolderState() {
        for hasFolder in [true, false] {
            XCTAssertEqual(
                QuickCapturePresentationPolicy.toggleRoute(
                    isPanelVisible: true, hasOpenWorkFolder: hasFolder),
                .dismiss
            )
        }
    }

    // MARK: submitAction

    func testSubmitAction_overlay_createsATask() {
        XCTAssertEqual(QuickCapturePresentationPolicy.submitAction(for: .overlay), .createTask)
    }

    /// An answer must route to `submitAnswer` in BOTH chat and non-chat teams —
    /// the chat flag only decides what happens after the send, not where it goes.
    func testSubmitAction_supervisorAnswer_submitsAnswerRegardlessOfChatMode() {
        for chat in [true, false] {
            XCTAssertEqual(
                QuickCapturePresentationPolicy.submitAction(
                    for: .supervisorAnswer(payload: answerPayload(isChatMode: chat))),
                .submitSupervisorAnswer
            )
        }
    }

    func testSubmitAction_chatWorking_queuesAMessage() {
        XCTAssertEqual(
            QuickCapturePresentationPolicy.submitAction(
                for: .taskWorking(roleName: "Engineer", isChatMode: true)),
            .queueChatMessage
        )
    }

    /// Non-chat working renders a loader with no composer. Wiring it to
    /// `createTask` (the old `else` fallthrough shape) would have made the
    /// panel silently create a SECOND task while the first is still running.
    func testSubmitAction_nonChatWorking_isDisabled() {
        XCTAssertEqual(
            QuickCapturePresentationPolicy.submitAction(
                for: .taskWorking(roleName: "Engineer", isChatMode: false)),
            .disabled
        )
    }

    /// The role name never affects routing — only `isChatMode` does.
    func testSubmitAction_ignoresRoleName() {
        for name in ["", "Engineer", "Product Manager"] {
            XCTAssertEqual(
                QuickCapturePresentationPolicy.submitAction(
                    for: .taskWorking(roleName: name, isChatMode: true)),
                .queueChatMessage
            )
        }
    }

    /// `disabled` and `expectsFocusableField` encode the same fact — "this mode
    /// renders no composer" — from two different files. If they drift, either
    /// the focus-retry banner fires on a panel that legitimately has no field,
    /// or a live send button sits on a mode with nothing to send.
    func testSubmitDisabled_andFocusExpectation_stayInLockstep() {
        let modes: [QuickCaptureMode] = [
            .overlay,
            .supervisorAnswer(payload: answerPayload(isChatMode: true)),
            .supervisorAnswer(payload: answerPayload(isChatMode: false)),
            .taskWorking(roleName: "Engineer", isChatMode: true),
            .taskWorking(roleName: "Engineer", isChatMode: false)
        ]
        for mode in modes {
            XCTAssertTrue(
                QuickCapturePresentationPolicy.agreesWithFocusExpectation(mode),
                "submitAction and expectsFocusableField disagree for \(mode)."
            )
        }
    }
}

// MARK: - Controller callbacks & lifecycle branches

/// Covers the `QuickCaptureController` members that had no test driving them:
/// the two panel callbacks (previously anonymous closures inside
/// `createPanel`, so unreachable without constructing and SHOWING a real
/// NSPanel), `togglePanel`'s dismiss arm, the `dismissPanel` fork, and the
/// `store == nil` arm of `embedFilesInPrompt`.
@MainActor
final class QuickCaptureControllerCallbackTests: XCTestCase {

    var sut: QuickCaptureController!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        sut = QuickCaptureController.shared
        sut._testReset()
        if sut._testIsInAnswerMode { sut._testExitAnswerMode() }
        sut.formState._testClearAnswerDrafts()
        sut.formState.supervisorTask = ""
        sut.isTaskSelected = false
        sut._testForceNewTaskMode = false
        sut._testIsPanelVisible = false
    }

    override func tearDown() async throws {
        if sut._testIsInAnswerMode { sut._testExitAnswerMode() }
        sut.formState.supervisorTask = ""
        sut.isTaskSelected = false
        sut._testForceNewTaskMode = false
        sut._testIsPanelVisible = false
        sut._testReset()
        sut = nil
        try await super.tearDown()
    }

    // MARK: handlePanelHidden

    /// AppKit can order the panel out by a route the controller did not
    /// initiate (the `cancelOperation` fallback, a `close()`). If the flag
    /// stayed `true`, `presentPanelSync`'s `guard !isPanelVisible` would
    /// short-circuit forever and ⌃⌥⌘0 would stop working for the session.
    func testHandlePanelHidden_clearsVisibility() {
        sut._testIsPanelVisible = true
        sut.handlePanelHidden()
        XCTAssertFalse(sut._testIsPanelVisible)
    }

    func testHandlePanelHidden_isIdempotent() {
        sut._testIsPanelVisible = true
        sut.handlePanelHidden()
        sut.handlePanelHidden()
        XCTAssertFalse(sut._testIsPanelVisible)
    }

    // MARK: handleFocusRestorationFailure

    /// This banner is the user's ONLY signal for the silent-caret bug — the
    /// panel is on screen, looks focused, and drops every keystroke. Its
    /// wording had no coverage at all.
    func testHandleFocusRestorationFailure_surfacesAnActionableBanner() async {
        let store = TestOrchestrator.make()
        sut.store = store
        sut.handleFocusRestorationFailure()

        let message = store.lastErrorMessage
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("focus") == true,
                      "Banner must name the problem. Got: \(message ?? "nil")")
        XCTAssertTrue(message?.contains("Click into the field") == true,
                      "Banner must tell the user the recovery step. Got: \(message ?? "nil")")
    }

    /// Torn-down / not-yet-set-up controller: the callback must be inert, not a
    /// crash. `store` is `weak`, so this is reachable in production if the
    /// orchestrator is released while a retry loop is still in flight.
    func testHandleFocusRestorationFailure_withNoStore_isInert() {
        sut.store = nil
        sut.handleFocusRestorationFailure()  // must not trap
    }

    // MARK: togglePanel

    /// The dismiss arm — the only one of the three that can be driven without
    /// putting a panel on screen. `togglePanel` had zero coverage before this.
    func testTogglePanel_whenVisible_dismisses() {
        sut._testIsPanelVisible = true
        sut._testForceNewTaskMode = true
        sut.togglePanel()
        XCTAssertFalse(sut._testIsPanelVisible)
        XCTAssertFalse(sut._testForceNewTaskMode,
                       "Dismiss must release the forced new-task pin.")
    }

    /// Toggling a hidden panel must not fall through to the dismiss arm and
    /// leave the flag set — a regression there would make the shortcut a no-op
    /// on every other press.
    func testTogglePanel_whenHidden_takesAPresentRoute() {
        XCTAssertEqual(
            QuickCapturePresentationPolicy.toggleRoute(
                isPanelVisible: sut._testIsPanelVisible,
                hasOpenWorkFolder: sut.store?.workFolderURL != nil),
            .bootstrapThenPresent,
            "A hidden panel with no work folder must route to the bootstrap path, not dismiss."
        )
    }

    // MARK: dismissPanel

    /// Task-mode dismiss keeps the draft (Drafts-app behaviour) but must clear
    /// the answer session, or a stale `pendingAnswer` from a previous task
    /// would make the next open resolve into answer mode for a question that
    /// has already been answered.
    func testDismissPanel_outsideAnswerMode_clearsTheAnswerSession() {
        sut._testIsPanelVisible = true
        sut.formState.supervisorTask = "draft survives"
        sut.dismissPanel()

        XCTAssertFalse(sut._testIsPanelVisible)
        XCTAssertFalse(sut._testIsInAnswerMode)
        XCTAssertNil(sut.formState.pendingAnswer)
        XCTAssertEqual(sut.formState.supervisorTask, "draft survives",
                       "Task draft must survive a dismiss.")
    }

    /// Answer-mode dismiss takes the other fork: `exitAnswerMode` saves the
    /// per-task answer draft and restores the stashed task draft.
    func testDismissPanel_inAnswerMode_exitsAndRestoresTheTaskDraft() {
        sut.formState.supervisorTask = "task draft"
        sut._testEnterAnswerMode(.supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: "r", taskID: 3, role: .softwareEngineer, roleDefinition: nil,
            question: "q?", messageContent: nil, thinking: nil, isChatMode: false
        )))
        XCTAssertTrue(sut._testIsInAnswerMode)
        sut.formState.answerText = "half-typed answer"
        sut._testIsPanelVisible = true

        sut.dismissPanel()

        XCTAssertFalse(sut._testIsPanelVisible)
        XCTAssertFalse(sut._testIsInAnswerMode)
        XCTAssertEqual(sut.formState.supervisorTask, "task draft",
                       "Exiting answer mode must restore the stashed task draft.")
    }

    // MARK: embedFilesInPrompt

    /// The `store == nil` arm. It must be `false`, not a crash and not `true`:
    /// defaulting to `true` would make a detached controller read and inline
    /// every attachment's bytes into the prompt.
    func testEmbedFilesInPrompt_withNoStore_isFalse() {
        sut.store = nil
        XCTAssertFalse(sut.embedFilesInPrompt)
    }

    func testEmbedFilesInPrompt_mirrorsTheStoreConfiguration() async {
        let store = TestOrchestrator.make()
        sut.store = store
        let original = store.configuration.embedFilesInPrompt
        defer { store.configuration.embedFilesInPrompt = original }

        store.configuration.embedFilesInPrompt = true
        XCTAssertTrue(sut.embedFilesInPrompt)
        store.configuration.embedFilesInPrompt = false
        XCTAssertFalse(sut.embedFilesInPrompt)
    }
}

// MARK: - Init defaults

/// Covers `QuickCaptureController.init`'s defaulting arms. No existing test
/// constructs the controller with all three seams nil, so the
/// `?? GlobalHotkeyManager.shared` / `?? DefaultQuickCaptureModeCoordinator()`
/// / `?? QuickCaptureFormState()` fallbacks were unexecuted, as was the
/// `keepOpenInChat` "absent key means true" branch.
///
/// Every test here is `async` because it constructs a `@MainActor` class in the
/// test body — a synchronous `@MainActor` test doing that aborts the worker on
/// Xcode 26.3 (CLAUDE.md §Testing Conventions).
@MainActor
final class QuickCaptureControllerInitDefaultsTests: XCTestCase {

    private var keepOpenStore: InMemoryConfigurationStorage!

    override func setUp() async throws {
        try await super.setUp()
        keepOpenStore = InMemoryConfigurationStorage()
    }

    override func tearDown() async throws {
        keepOpenStore = nil
        try await super.tearDown()
    }

    /// A fresh install has no stored preference. The default must be `true` —
    /// chat teams keeping the overlay open after a send is the whole point of
    /// the setting.
    func testInit_withNoStoredPreference_defaultsKeepOpenInChatToTrue() async {
        // The store is injected into THIS instance, not into the shared singleton: `init`
        // reads its own `storage` parameter, so seeding the singleton would leave this
        // construction reading `UserDefaults.standard` — the very shared domain D-4 is about,
        // where a sibling worker's `false` makes this assertion fail for a reason that has
        // nothing to do with the default.
        let sut = QuickCaptureController(
            formState: QuickCaptureFormState(), storage: keepOpenStore)
        XCTAssertTrue(sut.keepOpenInChat)
    }

    /// `object(forKey:) != nil` is what distinguishes "user turned it off" from
    /// "never set". A plain `bool(forKey:)` read would return `false` for both
    /// and silently flip the default.
    func testInit_withStoredFalse_honoursTheUsersChoice() async {
        keepOpenStore.set(false, forKey: UserDefaultsKeys.quickCaptureKeepOpenInChat)
        let sut = QuickCaptureController(
            formState: QuickCaptureFormState(), storage: keepOpenStore)
        XCTAssertFalse(sut.keepOpenInChat)
    }

    func testInit_withStoredTrue_readsTrue() async {
        keepOpenStore.set(true, forKey: UserDefaultsKeys.quickCaptureKeepOpenInChat)
        let sut = QuickCaptureController(
            formState: QuickCaptureFormState(), storage: keepOpenStore)
        XCTAssertTrue(sut.keepOpenInChat)
    }

    /// All-nil construction — exercises every `??` fallback in one go and
    /// proves the defaults are inert (no hotkey is claimed until `setup`).
    func testInit_withNoInjectedSeams_buildsItsOwnFormState() async {
        // The all-nil path IS this test's subject, and it only READS the store at init — no
        // property is set, so nothing reaches the shared domain. Injecting a store here would
        // test a different construction than the one this test is named for.
        // ratchet:allow-shared-defaults reads only; the all-nil fallback is the subject
        let sut = QuickCaptureController()
        XCTAssertFalse(sut._testIsPanelVisible)
        XCTAssertFalse(sut._testIsInAnswerMode)
        XCTAssertNil(sut._testPanel, "Construction must not create a panel.")
        XCTAssertTrue(sut.formState.attachments.isEmpty)
    }

    /// An injected form state must be THE one the controller uses — the queue
    /// bridge in `NanoTeamsApp.onAppear` hands `formState` to the orchestrator,
    /// so a copy here would silently orphan every queued Supervisor message.
    func testInit_usesTheInjectedFormStateIdentity() async {
        let injected = QuickCaptureFormState()
        let sut = QuickCaptureController(formState: injected)
        XCTAssertTrue(sut.formState === injected)
    }

    /// `keepOpenInChat`'s `didSet` is the only writer of the key.
    func testKeepOpenInChat_setterPersists() async {
        // ONE store shared by both controllers: "a second instance observes the persisted
        // value" is the property under test, and it needs a common store — just not the
        // process-global one.
        let store = InMemoryConfigurationStorage()
        let sut = QuickCaptureController(formState: QuickCaptureFormState(), storage: store)
        sut.keepOpenInChat = false
        XCTAssertEqual(
            store.object(forKey: UserDefaultsKeys.quickCaptureKeepOpenInChat) as? Bool,
            false
        )
        // A second controller built now must observe the persisted value.
        let reread = QuickCaptureController(formState: QuickCaptureFormState(), storage: store)
        XCTAssertFalse(reread.keepOpenInChat)
    }
}

// MARK: - setup() hotkey-refusal banner

/// `setup(store:dictation:)`'s error arm — the wiring from
/// `unclaimedHotkeyMessage` to `store.lastErrorMessage`. The pure message
/// builder is pinned by `UnclaimedHotkeyMessageTests`, and the registration
/// contract by `ScreenInputHotkeyRegistrationTests`, but nothing joined them:
/// that suite's double declares `refusedKeyCodes` and no test ever assigns it.
///
/// Failure scenario the banner exists for: Alfred / Raycast already owns
/// ⌃⌥⌘0. Carbon refuses, `register` returns `false`, and without the banner the
/// shortcut the Settings sheet advertises simply never fires — indistinguishable
/// from the feature being broken.
///
/// Uses a FRESH controller, never `.shared`: `didSetupHotkeys` is a one-shot
/// latch that `_testReset()` deliberately does not clear.
@MainActor
final class QuickCaptureSetupHotkeyFailureTests: XCTestCase {

    /// `DictationService` is held `weak` by the controller, so the test needs a
    /// strong reference for the duration. Constructing it is safe — its init is
    /// documented as lazy (no AVFoundation / Speech APIs touched).
    private var dictation: DictationService!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        dictation = DictationService()
    }

    override func tearDown() async throws {
        dictation = nil
        try await super.tearDown()
    }

    private func makeController(refusing keyCodes: Set<UInt32>) -> (QuickCaptureController, RefusingHotkeyManager) {
        let hotkeys = RefusingHotkeyManager()
        hotkeys.refusedKeyCodes = keyCodes
        let controller = QuickCaptureController(
            hotkeyManager: hotkeys,
            formState: QuickCaptureFormState()
        )
        return (controller, hotkeys)
    }

    func testSetup_bothShortcutsClaimed_surfacesNoBanner() async {
        let store = TestOrchestrator.make()
        let (controller, hotkeys) = makeController(refusing: [])
        controller.setup(store: store, dictation: dictation)

        XCTAssertNil(store.lastErrorMessage)
        XCTAssertEqual(Set(hotkeys.registeredKeyCodes), [29, 40])
    }

    /// Key code 29 is `0` — the Quick Capture combo.
    func testSetup_openShortcutRefused_bannersThatComboOnly() async {
        let store = TestOrchestrator.make()
        let (controller, hotkeys) = makeController(refusing: [29])
        controller.setup(store: store, dictation: dictation)

        let message = store.lastErrorMessage
        XCTAssertNotNil(message, "A refused registration must not be silent.")
        XCTAssertTrue(message?.contains("⌃⌥⌘0") == true, "Got: \(message ?? "nil")")
        XCTAssertFalse(message?.contains("⌃⌥⌘K") == true, "Got: \(message ?? "nil")")
        XCTAssertEqual(hotkeys.registeredKeyCodes, [40],
                       "The clip shortcut must still be claimed when only the open one is refused.")
    }

    /// Key code 40 is `k` — the Context Capture combo.
    func testSetup_clipShortcutRefused_bannersThatComboOnly() async {
        let store = TestOrchestrator.make()
        let (controller, hotkeys) = makeController(refusing: [40])
        controller.setup(store: store, dictation: dictation)

        let message = store.lastErrorMessage
        XCTAssertTrue(message?.contains("⌃⌥⌘K") == true, "Got: \(message ?? "nil")")
        XCTAssertFalse(message?.contains("⌃⌥⌘0") == true, "Got: \(message ?? "nil")")
        XCTAssertEqual(hotkeys.registeredKeyCodes, [29])
    }

    /// `lastErrorMessage` is a single coalescing slot, so two writes would show
    /// only the second. Both refusals must arrive as ONE message.
    func testSetup_bothShortcutsRefused_coalescesIntoOneBannerNamingBoth() async {
        let store = TestOrchestrator.make()
        let (controller, hotkeys) = makeController(refusing: [29, 40])
        controller.setup(store: store, dictation: dictation)

        let message = store.lastErrorMessage
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("⌃⌥⌘0") == true, "Got: \(message ?? "nil")")
        XCTAssertTrue(message?.contains("⌃⌥⌘K") == true, "Got: \(message ?? "nil")")
        XCTAssertTrue(hotkeys.registeredKeyCodes.isEmpty)
    }

    /// The latch: a second `setup` must not re-register (Carbon would claim the
    /// combo twice) — but it MUST rebind the store, because the app can open a
    /// new work folder behind the same controller.
    func testSetup_calledTwice_registersOnceButRebindsTheStore() async {
        let first = TestOrchestrator.make()
        let second = TestOrchestrator.make()
        let (controller, hotkeys) = makeController(refusing: [])

        controller.setup(store: first, dictation: dictation)
        XCTAssertEqual(hotkeys.registeredKeyCodes.count, 2)

        controller.setup(store: second, dictation: dictation)
        XCTAssertEqual(hotkeys.registeredKeyCodes.count, 2,
                       "didSetupHotkeys must gate re-registration.")
        XCTAssertTrue(controller.store === second)
    }

    /// A refusal on the FIRST setup must not re-banner on every later setup
    /// call — the latch short-circuits before the message is rebuilt.
    func testSetup_secondCallAfterARefusal_doesNotRepeatTheBanner() async {
        let first = TestOrchestrator.make()
        let second = TestOrchestrator.make()
        let (controller, _) = makeController(refusing: [29, 40])

        controller.setup(store: first, dictation: dictation)
        XCTAssertNotNil(first.lastErrorMessage)

        controller.setup(store: second, dictation: dictation)
        XCTAssertNil(second.lastErrorMessage,
                     "The one-shot latch must stop the banner from re-firing on every setup.")
    }
}
