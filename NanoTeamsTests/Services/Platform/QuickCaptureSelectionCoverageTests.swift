import XCTest

@testable import NanoTeams

// MARK: - Doubles

/// A `HotkeyManager` double that REPLAYS what it registered.
///
/// Every existing double in the suite stores the handlers and never calls them — one of
/// them says so outright: "Retained exactly as the production singleton retains them.
/// NEVER invoked here." That was the right call while invoking the open handler meant
/// presenting an NSPanel and the clip handler meant synthesizing a real ⌘C into whatever
/// app was frontmost. With `SelectionCapturing` seamed, the clip handler is inert, so the
/// handlers can finally be fired — and until they were, nothing verified that ⌃⌥⌘0 and
/// ⌃⌥⌘K are wired to different things at all.
@MainActor
private final class ReplayingHotkeyManager: HotkeyManager {
    private(set) var handlers: [UInt32: () -> Void] = [:]
    private(set) var registeredKeyCodes: [UInt32] = []

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        registeredKeyCodes.append(keyCode)
        handlers[id] = handler
        return true
    }

    /// Fires the handler registered under `id`. Returns false if nothing was registered,
    /// so a test cannot pass by firing a handler that does not exist.
    func fire(id: UInt32) -> Bool {
        guard let handler = handlers[id] else { return false }
        handler()
        return true
    }
}

/// A `SelectionCapturing` double: records the root it was asked about, returns a scripted
/// capture.
@MainActor
private final class ScriptedSelectionCapturer: SelectionCapturing {
    var scripted = ClipboardCaptureResult(text: nil, fileURLs: [])
    private(set) var accessibilityRequests = 0
    private(set) var capturedRoots: [URL?] = []

    func requestAccessibilityIfNeeded() { accessibilityRequests += 1 }

    func captureSelection(workFolderRoot: URL?) async -> ClipboardCaptureResult {
        capturedRoots.append(workFolderRoot)
        return scripted
    }
}

// MARK: - Selection capture routing

/// Covers `QuickCaptureController+ClipboardHandling.captureClipboardContent` — every one
/// of its 11 lines was uncovered, because its two `ClipboardCaptureService` statics
/// synthesize a real ⌘C and rewrite the system pasteboard.
///
/// The routing it performs is the part that matters: a capture filed into the task-mode
/// bucket while the panel is in answer mode still renders a card, just attached to a
/// draft the user never meant. `stageCapturedContent` was already `internal` "so tests
/// can call it" — which covered the staging and left the routing that chooses the bucket
/// untested.
@MainActor
final class QuickCaptureSelectionCoverageTests: XCTestCase {

    private var capturer: ScriptedSelectionCapturer!
    private var hotkeys: ReplayingHotkeyManager!
    private var controller: QuickCaptureController!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        QuickCaptureController.shared._testReset()
        capturer = ScriptedSelectionCapturer()
        hotkeys = ReplayingHotkeyManager()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-select-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        controller = nil
        hotkeys = nil
        capturer = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        QuickCaptureController.shared._testReset()
        try await super.tearDown()
    }

    /// A store with a REAL work folder open. The hotkey tests need this: with no folder,
    /// `showPanel` first awaits `bootstrapDefaultStorageIfNeeded()`, which writes a
    /// default-storage tree under Application Support — a side effect outside the temp
    /// dir, and slow enough that the capture is not observable within a bounded wait.
    private func makeStoreWithWorkFolder() async -> NTMSOrchestrator {
        let store = TestOrchestrator.make()
        await store.openWorkFolder(tempDir)
        return store
    }

    /// Bounded wait for the clip handler's fire-and-forget `Task`. Deadline-based rather
    /// than a fixed yield count, because the handler's body contains real awaits.
    private func waitUntil(
        _ predicate: () -> Bool, timeout: TimeInterval = 3.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    private func makeController() -> QuickCaptureController {
        let made = QuickCaptureController(
            hotkeyManager: hotkeys,
            formState: QuickCaptureFormState(),
            selectionCapturer: capturer
        )
        controller = made
        return made
    }

    private func answerMode(taskID: Int = 1) -> QuickCaptureMode {
        .supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: "r", taskID: taskID, role: .softwareEngineer, roleDefinition: nil,
            question: "which?", messageContent: nil, thinking: nil, isChatMode: true))
    }

    /// RED: swap the two `stageCapturedContent` calls' `answerMode:` arguments → the clip
    /// lands in `clippedTexts` and both assertions fail.
    func testCapture_inAnswerMode_routesToTheAnswerBucket() async {
        let sut = makeController()
        capturer.scripted = ClipboardCaptureResult(text: "selected prose", fileURLs: [])

        await sut.captureClipboardContent(mode: answerMode())

        XCTAssertEqual(sut.formState.answerClippedTexts, ["selected prose"],
                       "an answer-mode capture belongs to the answer draft")
        XCTAssertTrue(sut.formState.clippedTexts.isEmpty,
                      "it must NOT also reach the task draft — the card would render "
                          + "against a draft the user never meant")
    }

    /// This slot used to hold `testCapture_answerFlagWithoutAnAnswerMode_routesToTheTaskBucket`,
    /// which drove the routing with a DISAGREEING pair — `needsAnswerMode: true` beside
    /// `.taskWorking` — and pinned the result as correct. Neither half survived scrutiny:
    /// both call sites derived the flag from the mode, so the pair could not disagree in
    /// production; and its rationale ("no answer draft to file against") was false for
    /// chat-mode `.taskWorking`, which docks the composer against exactly those buckets.
    /// The parameter is gone and the routing is now a property of the mode — see
    /// `QuickCaptureChatComposerBucketCoverageTests` for the replacement, which asserts
    /// the opposite for that mode.
    ///
    /// RED: return `false` for chat-mode `.taskWorking` in `composerBindsAnswerBuckets`
    /// → this fails, which is precisely the state the deleted test asserted was correct.
    func testCapture_chatWorkingRoutingMovedToItsOwnSuite() {
        XCTAssertTrue(
            QuickCaptureMode.taskWorking(roleName: "Engineer", isChatMode: true)
                .composerBindsAnswerBuckets,
            "the fact the deleted test denied")
    }

    /// RED: drop `selectionCapturer.requestAccessibilityIfNeeded()` → this fails. The
    /// prompt has to precede the capture: without Accessibility trust the synthesized ⌘C
    /// is dropped by the OS and the capture silently returns nothing.
    func testCapture_requestsAccessibilityBeforeCapturing() async {
        let sut = makeController()
        await sut.captureClipboardContent(mode: .overlay)
        XCTAssertEqual(capturer.accessibilityRequests, 1)
        XCTAssertEqual(capturer.capturedRoots.count, 1)
    }

    /// The work-folder root is what enables `// Source: path:line` enrichment, and it is
    /// gated on `hasRealWorkFolder` — default storage must NOT be handed over, or clips
    /// get enriched with paths under Application Support that mean nothing to the user.
    ///
    /// RED: pass `store?.workFolderURL` unconditionally → the nil assertion fails.
    func testCapture_withoutARealWorkFolder_passesNoRootForEnrichment() async {
        let sut = makeController()
        sut.store = nil  // no store at all is the strongest form of "not a real folder"

        await sut.captureClipboardContent(mode: .overlay)

        XCTAssertEqual(capturer.capturedRoots, [nil],
                       "no work folder means no source enrichment")
    }

    /// Anti-vacuity for the three tests above: an empty capture must stage nothing at
    /// all. Without this a `stageCapturedContent` that appended unconditionally would
    /// satisfy the bucket assertions by accident.
    func testCapture_emptySelection_stagesNothing() async {
        let sut = makeController()
        capturer.scripted = ClipboardCaptureResult(text: nil, fileURLs: [])

        await sut.captureClipboardContent(mode: answerMode())

        XCTAssertTrue(sut.formState.answerClippedTexts.isEmpty)
        XCTAssertTrue(sut.formState.clippedTexts.isEmpty)
        XCTAssertTrue(sut.formState.attachments.isEmpty)
    }

    // MARK: - A restore that could not be put back

    /// `captureSelection` snapshots the clipboard, posts ⌘C, and puts the snapshot back. When the
    /// put-back is REFUSED the clipboard is left empty — the user's content is gone, and the only
    /// evidence is `restoreFailed`. Discovering it at the next ⌘V is too late to re-copy.
    ///
    /// RED: drop the `captured.restoreFailed` branch in `captureClipboardContent` → silent.
    func testCapture_whenTheClipboardCouldNotBeRestored_tellsTheUser() async {
        let sut = makeController()
        let store = await makeStoreWithWorkFolder()
        sut.store = store
        capturer.scripted = ClipboardCaptureResult(
            text: "selected prose", fileURLs: [], restoreFailed: true)

        await sut.captureClipboardContent(mode: answerMode())

        XCTAssertEqual(
            sut.formState.answerClippedTexts, ["selected prose"],
            "the capture still succeeds — the loss is the user's PREVIOUS clipboard")
        let message = store.lastErrorMessage ?? ""
        XCTAssertTrue(message.contains("clipboard"), "got: \(message)")
    }

    /// The normal path must stay quiet, or the warning is noise nobody reads.
    func testCapture_whenTheClipboardWasRestored_saysNothing() async {
        let sut = makeController()
        let store = await makeStoreWithWorkFolder()
        sut.store = store
        store.lastErrorMessage = nil
        capturer.scripted = ClipboardCaptureResult(text: "prose", fileURLs: [])

        await sut.captureClipboardContent(mode: answerMode())

        XCTAssertNil(store.lastErrorMessage)
    }

    // MARK: - The hotkey handlers

    /// The two registered handlers must do DIFFERENT things — ⌃⌥⌘0 opens the overlay,
    /// ⌃⌥⌘K captures the selection first. Nothing had ever fired either, so nothing
    /// noticed if both were wired to the same closure.
    ///
    /// RED: register the clip handler's closure for the open id too → the capture-count
    /// assertion fails.
    func testHotkeys_openAndClipHandlersAreWiredToDifferentEffects() async {
        let sut = makeController()
        let store = await makeStoreWithWorkFolder()
        sut.store = store
        // Panel already visible, so the open handler takes `togglePanel`'s `.dismiss`
        // route: no NSPanel is created and no async bootstrap Task is spawned.
        sut._testIsPanelVisible = true

        XCTAssertEqual(hotkeys.registeredKeyCodes, [], "setup has not run yet")
        sut.setup(store: store, dictation: DictationService())
        XCTAssertEqual(hotkeys.registeredKeyCodes, [29, 40],
                       "'0' and 'k' — the combos the Settings sheet advertises")

        // ⌃⌥⌘0 → dismiss, no capture.
        XCTAssertTrue(hotkeys.fire(id: 1), "the open handler must be registered under id 1")
        XCTAssertFalse(sut._testIsPanelVisible, "the open handler toggles the overlay")
        XCTAssertEqual(capturer.capturedRoots.count, 0,
                       "opening the overlay must not capture the user's selection — "
                           + "⌃⌥⌘0 is the no-clip combo")
    }

    /// The clip handler dispatches into an async `Task`, so the capture is observable
    /// only after yielding. Firing it is now safe precisely because `SelectionCapturing`
    /// is injected — with the production capturer this test would send ⌘C to whatever app
    /// happened to be frontmost on the machine running it.
    ///
    /// RED: change the clip handler to `showPanel(withClip: false)` → no capture is
    /// requested and this fails.
    func testHotkeys_clipHandlerCapturesTheSelection() async {
        let sut = makeController()
        let store = await makeStoreWithWorkFolder()
        sut.store = store
        sut._testIsPanelVisible = true
        sut.setup(store: store, dictation: DictationService())
        capturer.scripted = ClipboardCaptureResult(text: "grabbed", fileURLs: [])

        XCTAssertTrue(hotkeys.fire(id: 2), "the clip handler must be registered under id 2")
        // The handler body is `Task { await showPanel(withClip: true) }`.
        let captured = await waitUntil { [capturer] in !(capturer?.capturedRoots.isEmpty ?? true) }
        XCTAssertTrue(captured, "the clip handler never reached the capturer")

        XCTAssertEqual(capturer.accessibilityRequests, 1,
                       "⌃⌥⌘K must ask for Accessibility trust and capture")
        XCTAssertEqual(sut.formState.clippedTexts, ["grabbed"])
    }

    /// `setup` is one-shot: a second call must not register a second pair of handlers.
    /// Carbon would return a distinct hot-key ref for the same combo, and the first would
    /// leak — the app would hold two claims on ⌃⌥⌘0 for the rest of the session.
    ///
    /// RED: remove the `guard !didSetupHotkeys` → four key codes are registered.
    func testSetup_isIdempotent() async {
        let sut = makeController()
        let store = TestOrchestrator.make()
        let dictation = DictationService()

        sut.setup(store: store, dictation: dictation)
        sut.setup(store: store, dictation: dictation)

        XCTAssertEqual(hotkeys.registeredKeyCodes, [29, 40],
                       "a second setup must not claim the combos again")
    }

    /// The inert defaults are the seams' whole safety argument — a test that forgets to inject
    /// must get "no selection" and "no hotkey", never a real keystroke into another app and never
    /// a process-global Carbon registration. Pins that BOTH defaults are inert and that
    /// production overrides both.
    ///
    /// `hotkeyManager` was the odd one out until 2026-08-09: it resolved OUTWARD, to
    /// `GlobalHotkeyManager.shared`, so 78 of 88 test construction sites were handed the live
    /// registrar. Nothing broke, for a reason that is luck rather than design — `register` is
    /// reachable only through `setup(store:dictation:)` and all 20 of those sites happen to inject
    /// a fake. CLAUDE.md #49 is the same shape at 93 sites, discovered only after it had been
    /// issuing real network calls and unloading a developer's hand-loaded model for months.
    ///
    /// RED: change either default back to its live implementation (`?? GlobalHotkeyManager.shared`,
    /// `?? SystemSelectionCapturer()`) → the matching `is Inert…` assertion fails. Drop either
    /// argument from `.shared` → the matching production assertion fails, which is the half that
    /// catches a silent product regression rather than a test-hygiene one.
    func testDefaultsAreInertAndProductionOverridesThem() async {
        let bare = QuickCaptureController(formState: QuickCaptureFormState())

        let result = await bare.selectionCapturer.captureSelection(workFolderRoot: nil)
        XCTAssertNil(result.text, "the default must capture nothing")
        XCTAssertTrue(result.fileURLs.isEmpty)
        XCTAssertTrue(bare.selectionCapturer is InertSelectionCapturer,
                      "a forgotten injection must not reach the real ⌘C synthesis")

        XCTAssertTrue(bare.hotkeyManager is InertHotkeyManager,
                      "a forgotten injection must not reach the process-global Carbon registrar")
        XCTAssertFalse(
            bare.hotkeyManager.register(id: 1, keyCode: 29,
                                        modifiers: 0, handler: {}),
            "the inert registrar must report the combo as unclaimed rather than pretend")

        XCTAssertTrue(QuickCaptureController.shared.selectionCapturer is SystemSelectionCapturer,
                      "production must name the live capturer explicitly, or ⌃⌥⌘K "
                          + "silently captures nothing for every user")
        XCTAssertTrue(QuickCaptureController.shared.hotkeyManager is GlobalHotkeyManager,
                      "production must name the live registrar explicitly, or ⌃⌥⌘0 and ⌃⌥⌘K "
                          + "silently never fire for every user")
    }
}
