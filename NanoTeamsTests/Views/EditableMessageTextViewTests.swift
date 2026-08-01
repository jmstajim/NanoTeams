import XCTest
import SwiftUI
import AppKit
@testable import NanoTeams

/// Pins the load-bearing behaviors of `EditableMessageTextView` — the
/// `NSViewRepresentable` that replaces SwiftUI `TextField(axis: .vertical) +
/// ScrollView + .scrollPosition` inside `MessageComposer.messageField`.
///
/// Tests exercise the production `Coordinator` and `EditableNSTextView`
/// directly rather than going through SwiftUI lifecycle. The
/// representable struct itself is a thin DTO — what matters at runtime is
/// the Coordinator's two-way sync, the subclass's responder-chain
/// bridging, and the wiring of the NSScrollView container.
@MainActor
final class EditableMessageTextViewTests: XCTestCase {

    // MARK: - Coordinator: text binding round-trip

    /// Coordinator must propagate AppKit-side edits into the SwiftUI
    /// binding. Without this, typing in the field never updates `text`
    /// and the form sees a stale value.
    func testCoordinator_textDidChange_propagatesToBinding() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textBox = MutableBoxBinding(initial: "")
        let focusBox = MutableBoxBinding(initial: false)
        coordinator.configure(
            textBinding: textBox.binding,
            isFocusedBinding: focusBox.binding,
            onReturnKey: { _, _ in false }
        )
        let textView = makeStandaloneTextView(initialText: "user typed this")
        let note = Notification(name: NSText.didChangeNotification, object: textView)

        coordinator.textDidChange(note)

        XCTAssertEqual(textBox.value, "user typed this")
        XCTAssertEqual(coordinator.lastAppliedText, "user typed this",
                       "Coordinator must record what it just absorbed from AppKit so updateNSView's guard sees the matching baseline and skips the redundant write.")
    }

    /// Re-entering the binding-write path on the same content must NOT
    /// touch `textView.string`. Load-bearing guard: re-setting `.string`
    /// would reset `selectedRange` to the end of the new string, jumping
    /// the user's caret on every SwiftUI round-trip re-render.
    func testApplyText_equalContent_doesNotMutateTextView() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textView = makeStandaloneTextView(initialText: "hello")
        coordinator.absorbInitialText("hello")
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        coordinator.applyText("hello", to: textView)

        XCTAssertEqual(textView.string, "hello")
        XCTAssertEqual(textView.selectedRange().location, 2,
                       "Idempotent no-op write must preserve the caret position.")
    }

    /// External text replacement MUST take the write branch — the
    /// binding-write guard exists only for round-trip no-ops, not for
    /// genuine external resets.
    func testApplyText_differentContent_writesToTextView() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textView = makeStandaloneTextView(initialText: "old")
        coordinator.absorbInitialText("old")

        coordinator.applyText("new draft", to: textView)

        XCTAssertEqual(textView.string, "new draft")
        XCTAssertEqual(coordinator.lastAppliedText, "new draft")
    }

    // MARK: - Coordinator: return-key dispatch

    /// `handleReturnKey` is the extracted seam — `textView(_:doCommandBy:)`
    /// reads modifier flags from `NSApp.currentEvent` and forwards here.
    /// Tests target the seam directly so they don't have to mock
    /// `NSEvent`.
    func testHandleReturnKey_callbackConsumed_returnsTrue() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textBox = MutableBoxBinding(initial: "")
        let focusBox = MutableBoxBinding(initial: false)
        var capturedShift: Bool?
        var capturedCommand: Bool?
        coordinator.configure(
            textBinding: textBox.binding,
            isFocusedBinding: focusBox.binding,
            onReturnKey: { shift, cmd in
                capturedShift = shift
                capturedCommand = cmd
                return true
            }
        )

        let consumed = coordinator.handleReturnKey(hasShift: true, hasCommand: false)

        XCTAssertTrue(consumed)
        XCTAssertEqual(capturedShift, true)
        XCTAssertEqual(capturedCommand, false)
    }

    /// When the callback returns `false`, we must surface that to AppKit
    /// so `NSTextView`'s default `insertNewline:` runs and a literal `\n`
    /// is inserted at the caret. Eating the key here would silently
    /// suppress newlines.
    func testHandleReturnKey_callbackNotConsumed_returnsFalse() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textBox = MutableBoxBinding(initial: "")
        let focusBox = MutableBoxBinding(initial: false)
        coordinator.configure(
            textBinding: textBox.binding,
            isFocusedBinding: focusBox.binding,
            onReturnKey: { _, _ in false }
        )

        XCTAssertFalse(coordinator.handleReturnKey(hasShift: false, hasCommand: false))
    }

    /// Direct-construction test path: `Coordinator()` with no `configure(...)`
    /// call. Production never reaches this state (see `wire(coordinator:)`
    /// ordering), but the nil-branch is exercised through this seam.
    /// Consumes (`true`) to match `MessageKeyPolicy.ignore` — both paths read
    /// as "no-op" rather than producing a stray newline.
    func testHandleReturnKey_noCallback_consumes() async {
        let coordinator = EditableMessageTextView.Coordinator()

        XCTAssertTrue(
            coordinator.handleReturnKey(hasShift: false, hasCommand: false),
            "An un-configured Coordinator must consume Enter rather than insert a literal newline."
        )
    }

    /// Only `insertNewline:` triggers the return-key path. Other
    /// commands (`deleteBackward:`, navigation, etc.) must fall through
    /// to NSTextView's defaults — never invoke the submit callback.
    func testDoCommandBy_nonInsertNewlineSelector_doesNotInvokeCallback() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textBox = MutableBoxBinding(initial: "")
        let focusBox = MutableBoxBinding(initial: false)
        var fired = false
        coordinator.configure(
            textBinding: textBox.binding,
            isFocusedBinding: focusBox.binding,
            onReturnKey: { _, _ in fired = true; return true }
        )
        let textView = makeStandaloneTextView(initialText: "")

        let consumed = coordinator.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertFalse(consumed)
        XCTAssertFalse(fired, "Non-newline selectors must never invoke the return-key callback.")
    }

    // MARK: - Coordinator: focus binding

    /// `EditableNSTextView.becomeFirstResponder` / `resignFirstResponder`
    /// drive this method via a closure. The binding it owns gates the
    /// paste-monitor lifecycle in `MessageComposer` — getting this wrong
    /// silently breaks Cmd+V image-paste.
    func testUpdateFocusBinding_writesValue() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textBox = MutableBoxBinding(initial: "")
        let focusBox = MutableBoxBinding(initial: false)
        coordinator.configure(
            textBinding: textBox.binding,
            isFocusedBinding: focusBox.binding,
            onReturnKey: { _, _ in false }
        )

        coordinator.updateFocusBinding(true)
        XCTAssertEqual(focusBox.value, true)

        coordinator.updateFocusBinding(false)
        XCTAssertEqual(focusBox.value, false)
    }

    /// Idempotent: writing the same value must not touch the binding. A
    /// reactive observer downstream (e.g. `.onChange(of: isFocused)` that
    /// installs the paste monitor) would otherwise re-fire on every focus
    /// query AppKit does internally.
    func testUpdateFocusBinding_sameValue_doesNotWrite() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textBox = MutableBoxBinding(initial: "")
        let focusBox = MutableBoxBinding(initial: true)
        coordinator.configure(
            textBinding: textBox.binding,
            isFocusedBinding: focusBox.binding,
            onReturnKey: { _, _ in false }
        )
        focusBox.writeCount = 0

        coordinator.updateFocusBinding(true)

        XCTAssertEqual(focusBox.writeCount, 0,
                       "Idempotent setter must skip the write when the value is unchanged so observers don't re-fire.")
    }

    /// Un-configured Coordinator must not crash when a focus event
    /// arrives before the first `configure` call (early lifecycle window).
    func testUpdateFocusBinding_unconfigured_noop() async {
        let coordinator = EditableMessageTextView.Coordinator()

        coordinator.updateFocusBinding(true)
        // Reaching here without crash is the assertion.
    }

    // MARK: - EditableNSTextView: responder bridging

    /// The subclass exists primarily to bridge AppKit's responder chain
    /// to a SwiftUI binding. `focusUpdateHandler` is what
    /// `EditableMessageTextView.makeNSView` wires into the Coordinator's
    /// idempotent setter.
    func testEditableNSTextView_becomeFirstResponder_callsHandler() {
        let textView = makeStandaloneEditableNSTextView()
        let window = makeHeadlessWindow(contentView: textView)
        defer { window.orderOut(nil) }
        var captured: [Bool] = []
        textView.focusUpdateHandler = { captured.append($0) }

        let didBecome = window.makeFirstResponder(textView)

        XCTAssertTrue(didBecome)
        XCTAssertEqual(captured, [true],
                       "becomeFirstResponder override must propagate the responder gain to the handler.")
    }

    func testEditableNSTextView_resignFirstResponder_callsHandler() {
        let textView = makeStandaloneEditableNSTextView()
        let window = makeHeadlessWindow(contentView: textView)
        defer { window.orderOut(nil) }
        _ = window.makeFirstResponder(textView)
        var captured: [Bool] = []
        textView.focusUpdateHandler = { captured.append($0) }

        _ = window.makeFirstResponder(nil)

        XCTAssertEqual(captured, [false],
                       "resignFirstResponder override must propagate the responder loss to the handler.")
    }

    // MARK: - EditableNSTextView: placeholder rendering

    /// Placeholder draws only when the field is empty AND unfocused.
    /// Same convention as native `NSTextField` placeholder behavior.
    func testPlaceholder_emptyAndUnfocused_drawsPlaceholder() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = ""
        textView.placeholderText = "Type here"
        let window = makeHeadlessWindow(contentView: textView)
        defer { window.orderOut(nil) }

        textView.testHooks_drawForTesting()

        XCTAssertTrue(textView._didDrawPlaceholderForTesting)
    }

    func testPlaceholder_emptyAndFocused_stillDraws() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = ""
        textView.placeholderText = "Type here"
        let window = makeHeadlessWindow(contentView: textView)
        defer { window.orderOut(nil) }
        _ = window.makeFirstResponder(textView)

        textView.testHooks_drawForTesting()

        XCTAssertTrue(textView._didDrawPlaceholderForTesting,
                      "Placeholder stays visible while focused so it acts as a hint until the user types — matches the SwiftUI TextField behavior this NSViewRepresentable replaced.")
    }

    func testPlaceholder_nonEmpty_doesNotDraw() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = "user content"
        textView.placeholderText = "Type here"
        let window = makeHeadlessWindow(contentView: textView)
        defer { window.orderOut(nil) }

        textView.testHooks_drawForTesting()

        XCTAssertFalse(textView._didDrawPlaceholderForTesting)
    }

    func testPlaceholder_emptyPlaceholderText_doesNotDraw() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = ""
        textView.placeholderText = nil
        let window = makeHeadlessWindow(contentView: textView)
        defer { window.orderOut(nil) }

        textView.testHooks_drawForTesting()

        XCTAssertFalse(textView._didDrawPlaceholderForTesting)
    }

    // MARK: - EditableNSTextView: placeholder repaint invalidation

    /// THE regression pin for the frozen-placeholder bug.
    /// `EditableMessageTextView.updateNSView` re-assigns `placeholderText` on
    /// every SwiftUI render, and the composer's placeholder changes while the
    /// field is EMPTY (`TeamActivityComposer`'s recipient going nil → `.role(X)`)
    /// — the one state where the placeholder is the only thing on screen and
    /// nothing else dirties the view (the Coordinator's `applyText` early-returns
    /// on unchanged text). Without the property's `didSet` the OLD string stayed
    /// painted until a click or a window resize, so a live composer kept
    /// advertising "No active recipient — accept, restart a role, or request
    /// changes."
    ///
    /// Deliberately NOT hosted in a window (unlike the draw-decision tests
    /// above): `NSView.needsDisplay` is not assertable either way — it never
    /// latches on a windowless view, and a freshly hosted one already reads
    /// `true` before anything sets it — so the counter incremented inside
    /// `invalidatePlaceholderDisplay()` is the seam. Hosting here would only
    /// turn the assertion into a tautology.
    func testPlaceholder_changedWhileEmpty_invalidatesDisplay() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = ""
        textView.placeholderText = "No active recipient — accept, restart a role, or request changes."
        let baseline = textView._placeholderInvalidationCountForTesting

        textView.placeholderText = "Queue a message for Marketolog…"

        XCTAssertEqual(
            textView._placeholderInvalidationCountForTesting, baseline + 1,
            "A changed placeholder must mark the view dirty — nothing else repaints an empty field, so the previous recipient's hint would stay on screen until the user clicks in."
        )
    }

    /// The other edge of the same guard, and the reason it is an equality check
    /// rather than an unconditional `needsDisplay = true`: `updateNSView` runs on
    /// EVERY parent re-render — many per second while an LLM streams into the
    /// feed above the composer — and re-writes the same placeholder each time.
    /// Repainting this NSScrollView-backed representable per render is the
    /// per-frame cost CLAUDE.md #50 was written about.
    func testPlaceholder_reassignedIdenticalValue_doesNotInvalidate() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = ""
        textView.placeholderText = "Queue a message for Marketolog…"
        let baseline = textView._placeholderInvalidationCountForTesting

        for _ in 0..<10 {
            textView.placeholderText = "Queue a message for Marketolog…"
        }

        XCTAssertEqual(
            textView._placeholderInvalidationCountForTesting, baseline,
            "Re-assigning an identical placeholder must be a no-op — updateNSView writes it on every render, and an unconditional invalidation would repaint the representable per frame (CLAUDE.md #50)."
        )
    }

    /// Clearing direction: a placeholder that goes away while the field is empty
    /// must repaint too, or the last string stays painted over an empty field.
    /// Pins the guard against a plausible "only invalidate when the placeholder
    /// will actually be drawn" tightening — `shouldDrawPlaceholder()` reads the
    /// NEW value, so gating on it would skip exactly this case.
    func testPlaceholder_clearedWhileEmpty_invalidatesDisplay() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = ""
        textView.placeholderText = "Queue a message for Marketolog…"
        let baseline = textView._placeholderInvalidationCountForTesting

        textView.placeholderText = nil

        XCTAssertEqual(
            textView._placeholderInvalidationCountForTesting, baseline + 1,
            "Removing the placeholder must repaint — gating the invalidation on shouldDrawPlaceholder() (which reads the NEW value) would leave the old string painted over an empty field."
        )
    }

    /// Pins the render path itself, not just the property. The `didSet` can only
    /// fire if `updateNSView` keeps ASSIGNING the placeholder every render —
    /// dropping that one line silently restores the frozen-hint bug, and the
    /// three property-level tests above would all stay green.
    func testUpdateNSView_changedPlaceholder_appliesAndInvalidatesOnce() {
        let textBinding = MutableBoxBinding(initial: "")
        let focusBinding = MutableBoxBinding(initial: false)
        let makeView = { (placeholder: String) in
            EditableMessageTextView(
                text: textBinding.binding,
                isFocused: focusBinding.binding,
                placeholder: placeholder,
                maxHeight: 220,
                minLineCount: 1,
                autofocusOnAppear: false,
                onReturnKey: { _, _ in false }
            )
        }
        let coordinator = makeView("No active recipient — accept, restart a role, or request changes.")
            .makeCoordinator()
        let scrollView = makeView("No active recipient — accept, restart a role, or request changes.")
            .testHooks_makeNSView(coordinator: coordinator)
        guard let textView = scrollView.documentView as? EditableNSTextView else {
            return XCTFail("testHooks_makeNSView must install an EditableNSTextView as documentView")
        }
        // Measure deltas: `wire(...)` already applied the initial placeholder
        // (nil → string is a change), so absolutes would encode that first bump.
        let baseline = textView._placeholderInvalidationCountForTesting

        makeView("Queue a message for Marketolog…")
            .testHooks_updateNSView(scrollView, coordinator: coordinator)

        XCTAssertEqual(textView.placeholderText, "Queue a message for Marketolog…",
                       "updateNSView must re-apply the placeholder on every render — it is the only writer once the view exists.")
        XCTAssertEqual(
            textView._placeholderInvalidationCountForTesting, baseline + 1,
            "A render carrying a new placeholder must request exactly one repaint."
        )

        for _ in 0..<5 {
            makeView("Queue a message for Marketolog…")
                .testHooks_updateNSView(scrollView, coordinator: coordinator)
        }

        XCTAssertEqual(
            textView._placeholderInvalidationCountForTesting, baseline + 1,
            "Steady-state re-renders carry an unchanged placeholder and must request no further repaints."
        )
    }

    // MARK: - EditableNSTextView: placeholder invalidation corner cases

    /// Degenerate no-op: a view that never had a placeholder being re-told it has
    /// none. `nil != nil` is false, so the guard must swallow it — otherwise every
    /// render of a placeholder-less composer (`MessageComposer`'s `placeholder`
    /// defaults to `""`, and several call sites pass nothing) would repaint.
    func testPlaceholder_nilToNil_doesNotInvalidate() {
        let textView = makeStandaloneEditableNSTextView()
        let baseline = textView._placeholderInvalidationCountForTesting

        textView.placeholderText = nil

        XCTAssertEqual(textView._placeholderInvalidationCountForTesting, baseline,
                       "nil → nil is not a change and must not request a repaint.")
    }

    func testPlaceholder_identicalEmptyStrings_doNotInvalidate() {
        let textView = makeStandaloneEditableNSTextView()
        textView.placeholderText = ""
        let baseline = textView._placeholderInvalidationCountForTesting

        textView.placeholderText = ""

        XCTAssertEqual(textView._placeholderInvalidationCountForTesting, baseline,
                       "\"\" → \"\" is not a change — this is the steady state of every composer with no placeholder.")
    }

    /// Characterization, not a requirement: `nil` and `""` are both non-drawing
    /// states (`shouldDrawPlaceholder` rejects both), so this repaint is strictly
    /// wasted — but the guard is deliberately a plain value comparison rather than
    /// a "will it draw" predicate, because that predicate reads the NEW value and
    /// would break the clearing case. One wasted repaint on a transition that
    /// happens at most once per view is the accepted price of that simplicity.
    func testPlaceholder_nilToEmptyString_invalidatesEvenThoughNeitherDraws() {
        let textView = makeStandaloneEditableNSTextView()
        let baseline = textView._placeholderInvalidationCountForTesting

        textView.placeholderText = ""

        XCTAssertEqual(textView._placeholderInvalidationCountForTesting, baseline + 1)
        XCTAssertFalse(textView.shouldDrawPlaceholder(),
                       "Both nil and \"\" are non-drawing — the repaint is wasted but harmless.")
    }

    /// The invalidation is deliberately NOT gated on the field being empty. A draft
    /// in progress hides the placeholder, but the recipient can change underneath
    /// it, and the string has to be correct the moment the user clears the field —
    /// which is exactly when they are most likely to be looking for it.
    func testPlaceholder_changedWhileFieldNonEmpty_invalidatesAndIsCorrectOnceCleared() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = "half-typed draft"
        textView.placeholderText = "No active recipient — accept, restart a role, or request changes."
        let baseline = textView._placeholderInvalidationCountForTesting

        textView.placeholderText = "Queue a message for Marketolog…"

        XCTAssertEqual(textView._placeholderInvalidationCountForTesting, baseline + 1)
        textView.testHooks_drawForTesting()
        XCTAssertFalse(textView._didDrawPlaceholderForTesting,
                       "Nothing is drawn while a draft is present…")

        textView.string = ""
        textView.testHooks_drawForTesting()
        XCTAssertTrue(textView._didDrawPlaceholderForTesting)
        XCTAssertEqual(textView.placeholderText, "Queue a message for Marketolog…",
                       "…and clearing the draft must reveal the CURRENT hint, not the one from when the draft started.")
    }

    /// A role finishing and restarting walks the placeholder A → B → A. Nothing
    /// memoizes "already seen", so each leg is its own change and its own repaint.
    func testPlaceholder_alternatingValues_invalidatesEveryChange() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = ""
        let a = "Queue a message for Marketolog…"
        let b = "No active recipient — accept, restart a role, or request changes."
        textView.placeholderText = a
        let baseline = textView._placeholderInvalidationCountForTesting

        textView.placeholderText = b
        textView.placeholderText = a

        XCTAssertEqual(textView._placeholderInvalidationCountForTesting, baseline + 2,
                       "Returning to a previously-used string is still a change from what is currently painted.")
    }

    /// `shouldDrawPlaceholder` gates on `isEmpty`, not on whitespace — a
    /// whitespace-only placeholder counts as present and paints (invisibly).
    /// Characterization of the existing predicate so a future "trim it" tweak is
    /// a deliberate decision rather than a silent one.
    func testPlaceholder_whitespaceOnly_countsAsPresent() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = ""
        textView.placeholderText = "   "

        textView.testHooks_drawForTesting()

        XCTAssertTrue(textView._didDrawPlaceholderForTesting,
                      "Only `isEmpty` suppresses the placeholder; whitespace is treated as content.")
    }

    // MARK: - updateNSView corner cases (per-render path)

    /// The lock and the placeholder are independent per-render writes. Toggling
    /// only the lock must not request a placeholder repaint — otherwise every
    /// improve-prompt stream start/stop would repaint the field for nothing.
    func testUpdateNSView_onlyInputLockToggled_doesNotInvalidatePlaceholder() {
        let textBinding = MutableBoxBinding(initial: "")
        let focusBinding = MutableBoxBinding(initial: false)
        let coordinator = EditableMessageTextView.Coordinator()
        let scrollView = makeRepresentable(
            text: textBinding.binding, isFocused: focusBinding.binding,
            placeholder: "Send a message…"
        ).testHooks_makeNSView(coordinator: coordinator)
        guard let textView = scrollView.documentView as? EditableNSTextView else {
            return XCTFail("documentView must be an EditableNSTextView")
        }
        let baseline = textView._placeholderInvalidationCountForTesting

        makeRepresentable(
            text: textBinding.binding, isFocused: focusBinding.binding,
            placeholder: "Send a message…", isInputLocked: true
        ).testHooks_updateNSView(scrollView, coordinator: coordinator)

        XCTAssertTrue(textView.isInputLocked, "The lock must still land.")
        XCTAssertEqual(textView._placeholderInvalidationCountForTesting, baseline,
                       "An unchanged placeholder must not repaint just because a neighbouring property moved.")
    }

    /// Pins the ordering `applyUpdate` depends on: it reads the OLD lock state to
    /// decide whether to drop the undo stack, BEFORE assigning the new one. The
    /// improve stream writes via `.string =`, which registers no undo actions, so
    /// a Cmd+Z across an unlock would surface incoherent partial states.
    func testUpdateNSView_unlocking_clearsUndoStack() throws {
        let textBinding = MutableBoxBinding(initial: "")
        let focusBinding = MutableBoxBinding(initial: false)
        let coordinator = EditableMessageTextView.Coordinator()
        let scrollView = makeRepresentable(
            text: textBinding.binding, isFocused: focusBinding.binding,
            placeholder: "", isInputLocked: true
        ).testHooks_makeNSView(coordinator: coordinator)
        let textView = try XCTUnwrap(scrollView.documentView as? EditableNSTextView)
        let window = makeHeadlessWindow(contentView: scrollView)
        defer { window.orderOut(nil) }
        let undo = try XCTUnwrap(textView.undoManager, "NSTextView resolves its undo manager through the window.")
        undo.registerUndo(withTarget: self) { _ in }
        XCTAssertTrue(undo.canUndo, "Precondition: something is on the undo stack.")

        makeRepresentable(
            text: textBinding.binding, isFocused: focusBinding.binding,
            placeholder: "", isInputLocked: false
        ).testHooks_updateNSView(scrollView, coordinator: coordinator)

        XCTAssertFalse(undo.canUndo,
                       "Unlocking must drop the undo stack — the transition is detected by comparing the OLD lock value before it is overwritten.")
    }

    /// A single render can carry both a new draft and a new recipient. Neither
    /// write may swallow the other.
    func testUpdateNSView_textAndPlaceholderBothChanged_bothLand() {
        let textBinding = MutableBoxBinding(initial: "")
        let focusBinding = MutableBoxBinding(initial: false)
        let coordinator = EditableMessageTextView.Coordinator()
        let scrollView = makeRepresentable(
            text: textBinding.binding, isFocused: focusBinding.binding,
            placeholder: "No active recipient — accept, restart a role, or request changes."
        ).testHooks_makeNSView(coordinator: coordinator)
        guard let textView = scrollView.documentView as? EditableNSTextView else {
            return XCTFail("documentView must be an EditableNSTextView")
        }
        textBinding.binding.wrappedValue = "restored draft"

        makeRepresentable(
            text: textBinding.binding, isFocused: focusBinding.binding,
            placeholder: "Queue a message for Marketolog…"
        ).testHooks_updateNSView(scrollView, coordinator: coordinator)

        XCTAssertEqual(textView.string, "restored draft")
        XCTAssertEqual(textView.placeholderText, "Queue a message for Marketolog…")
    }

    // MARK: - NSScrollView wiring (native cursor-following preconditions)

    /// `wire(...)` applies the initial placeholder before the text view joins the
    /// hierarchy, so its `didSet` invalidation is a no-op there — the first paint
    /// after insertion covers it. Pinned so the initial value can't silently stop
    /// being applied (which would leave a blank hint until the first change).
    func testMakeNSView_appliesInitialPlaceholder() {
        let textBinding = MutableBoxBinding(initial: "")
        let focusBinding = MutableBoxBinding(initial: false)
        let view = EditableMessageTextView(
            text: textBinding.binding,
            isFocused: focusBinding.binding,
            placeholder: "Queue a message for Marketolog…",
            maxHeight: 220,
            minLineCount: 1,
            autofocusOnAppear: false,
            onReturnKey: { _, _ in false }
        )
        let scrollView = view.testHooks_makeNSView(coordinator: view.makeCoordinator())

        XCTAssertEqual((scrollView.documentView as? EditableNSTextView)?.placeholderText,
                       "Queue a message for Marketolog…")
    }

    /// Native cursor-following depends on three structural guarantees:
    /// (1) NSTextView is `isVerticallyResizable` so it can grow beyond
    /// the scroll view's clip bounds; (2) it sits as `documentView` of
    /// an NSScrollView (which is what auto-scrolls on `scrollRangeToVisible`);
    /// (3) the scroll view shows a vertical scroller. Regressions here
    /// silently break the iMessage-style behavior even when the rest of
    /// the wiring is intact.
    func testMakeNSView_scrollViewWiringSupportsCursorFollowing() {
        let textBinding = MutableBoxBinding(initial: "")
        let focusBinding = MutableBoxBinding(initial: false)
        let view = EditableMessageTextView(
            text: textBinding.binding,
            isFocused: focusBinding.binding,
            placeholder: "",
            maxHeight: 220,
            minLineCount: 1,
            autofocusOnAppear: false,
            onReturnKey: { _, _ in false }
        )
        let coordinator = view.makeCoordinator()
        let scrollView = view.testHooks_makeNSView(coordinator: coordinator)

        guard let textView = scrollView.documentView as? EditableNSTextView else {
            return XCTFail("scrollView.documentView must be EditableNSTextView — without this NSScrollView won't host the editor.")
        }
        XCTAssertTrue(textView.isVerticallyResizable,
                      "Vertically-resizable textView is what NSScrollView watches for content overflow.")
        XCTAssertTrue(scrollView.hasVerticalScroller,
                      "NSScrollView needs the vertical scroller to be enabled or scrollRangeToVisible can't reveal off-screen caret.")
        XCTAssertEqual(textView.string, "",
                       "Initial text from the binding must be applied during makeNSView.")
        XCTAssertNotNil(textView.layoutManager,
                        "TextKit 1 stack must be live — convenience NSTextView() can opt into TextKit 2 with nil layoutManager.")
    }

    /// Initial text from the binding must reach the live NSTextView.
    func testMakeNSView_initialBinding_propagatesToTextView() {
        let textBinding = MutableBoxBinding(initial: "preset")
        let focusBinding = MutableBoxBinding(initial: false)
        let view = EditableMessageTextView(
            text: textBinding.binding,
            isFocused: focusBinding.binding,
            placeholder: "",
            maxHeight: 220,
            minLineCount: 1,
            autofocusOnAppear: false,
            onReturnKey: { _, _ in false }
        )
        let coordinator = view.makeCoordinator()
        let scrollView = view.testHooks_makeNSView(coordinator: coordinator)

        XCTAssertEqual((scrollView.documentView as? EditableNSTextView)?.string, "preset")
        XCTAssertEqual(coordinator.lastAppliedText, "preset",
                       "Coordinator's baseline must match the initial text so subsequent equal-content updates take the no-op branch.")
    }

    // MARK: - sizeThatFits wiring

    /// Regression sentinel: `sizeThatFits` must route through the
    /// Coordinator-owned `MessageTextLayoutCache`. A regression to a
    /// throwaway `NSLayoutManager` inside `sizeThatFits` (the original
    /// hazard documented in `MessageTextLayoutCache`) would silently
    /// re-shape the whole string per SwiftUI proposal — caught here by
    /// asserting the cache's debug compute counter advances.
    func testSizeThatFits_routesThroughCoordinatorMeasureCache() {
        let textBinding = MutableBoxBinding(initial: "hello world hello world")
        let focusBinding = MutableBoxBinding(initial: false)
        let view = EditableMessageTextView(
            text: textBinding.binding,
            isFocused: focusBinding.binding,
            placeholder: "",
            maxHeight: 220,
            minLineCount: 1,
            autofocusOnAppear: false,
            onReturnKey: { _, _ in false }
        )
        let coordinator = view.makeCoordinator()
        let scrollView = view.testHooks_makeNSView(coordinator: coordinator)
        let initialCompute = coordinator.measureCache.computeCount
        let initialHit = coordinator.measureCache.hitCount

        _ = view.testHooks_sizeThatFits(
            ProposedViewSize(width: 200, height: nil),
            nsView: scrollView,
            coordinator: coordinator
        )

        XCTAssertGreaterThan(
            coordinator.measureCache.computeCount + coordinator.measureCache.hitCount,
            initialCompute + initialHit,
            "sizeThatFits must drive the Coordinator's measureCache — otherwise a throwaway LM regression would not be caught."
        )
    }

    /// Cache invalidation on edit: same-length substring rewrite must
    /// re-shape, not hit the cache. The cache key is `(length, width)`,
    /// so append-only callers don't need explicit invalidation but
    /// editable callers do.
    func testMeasureCache_invalidatedOnTextEdit_evenForSameLength() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textView = makeStandaloneTextView(initialText: "abcde")
        let textBox = MutableBoxBinding(initial: "abcde")
        let focusBox = MutableBoxBinding(initial: false)
        coordinator.configure(
            textBinding: textBox.binding,
            isFocusedBinding: focusBox.binding,
            onReturnKey: { _, _ in false }
        )

        // Prime the cache.
        _ = coordinator.measureCache.measure(textStorage: textView.textStorage!, width: 200)
        let primedCompute = coordinator.measureCache.computeCount

        // Same-length edit through applyText.
        coordinator.applyText("xyzwv", to: textView)
        _ = coordinator.measureCache.measure(textStorage: textView.textStorage!, width: 200)

        XCTAssertGreaterThan(
            coordinator.measureCache.computeCount, primedCompute,
            "Same-length edit must invalidate the cache so the new wrap shape gets re-shaped."
        )
    }

    /// Sibling to the `applyText` invalidation pin: the AppKit-side
    /// edit path (`textDidChange`, fired on every keystroke and IME
    /// commit) must also invalidate the cache. Without this, typing a
    /// same-length substring keeps the field at the prior wrap height.
    func testMeasureCache_invalidatedOnTextDidChange_evenForSameLength() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textView = makeStandaloneTextView(initialText: "abcde")
        let textBox = MutableBoxBinding(initial: "abcde")
        let focusBox = MutableBoxBinding(initial: false)
        coordinator.configure(
            textBinding: textBox.binding,
            isFocusedBinding: focusBox.binding,
            onReturnKey: { _, _ in false }
        )
        _ = coordinator.measureCache.measure(textStorage: textView.textStorage!, width: 200)
        let primedCompute = coordinator.measureCache.computeCount

        // Simulate an AppKit-side edit by replacing the storage contents
        // and posting the delegate notification the live NSTextView would
        // emit on the user's keystroke.
        textView.string = "xyzwv"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        _ = coordinator.measureCache.measure(textStorage: textView.textStorage!, width: 200)

        XCTAssertGreaterThan(
            coordinator.measureCache.computeCount, primedCompute,
            "textDidChange must invalidate the measure cache so a same-length edit doesn't return a stale wrap height."
        )
    }

    // MARK: - Re-binding contract

    /// SwiftUI rebuilds the representable struct on every parent re-render
    /// — the closures captured in the previous render are stale. The
    /// per-render `configure(...)` call must overwrite them so the
    /// freshest `onReturnKey` is dispatched. A regression to "set once"
    /// semantics would let an old closure submit with the wrong
    /// `canSubmit` / `isSubmitting` snapshot.
    func testCoordinator_configure_calledTwice_swapsCallback() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textBox = MutableBoxBinding(initial: "")
        let focusBox = MutableBoxBinding(initial: false)
        var firstFired = false
        var secondFired = false

        coordinator.configure(
            textBinding: textBox.binding,
            isFocusedBinding: focusBox.binding,
            onReturnKey: { _, _ in firstFired = true; return true }
        )
        coordinator.configure(
            textBinding: textBox.binding,
            isFocusedBinding: focusBox.binding,
            onReturnKey: { _, _ in secondFired = true; return true }
        )

        _ = coordinator.handleReturnKey(hasShift: false, hasCommand: false)

        XCTAssertFalse(firstFired, "Stale callback from prior configure() must not fire.")
        XCTAssertTrue(secondFired, "Latest configure() call must own the dispatch.")
    }

    // MARK: - Autofocus

    /// Self-attached lifecycle: when `autofocusOnFirstWindow` is true,
    /// the first non-nil `window` triggers a deferred `makeFirstResponder`.
    /// Pinning here so a regression to attaching focus outside the
    /// `viewDidMoveToWindow` hook (and thus racing window attachment)
    /// fails loudly.
    func testAutofocus_movingToWindow_requestsFirstResponder() {
        let textView = makeStandaloneEditableNSTextView()
        textView.autofocusOnFirstWindow = true
        let window = makeHeadlessWindow(contentView: textView)
        defer { window.orderOut(nil) }

        let expectation = XCTestExpectation(description: "first responder lands after viewDidMoveToWindow")
        DispatchQueue.main.async {
            // Spin one more runloop pass for the async dispatch inside
            // viewDidMoveToWindow to land.
            DispatchQueue.main.async {
                XCTAssertTrue(window.firstResponder === textView,
                              "Autofocus must request first-responder once attached to a window.")
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 1.0)
    }

    /// `autofocusOnFirstWindow = false` (the default for surfaces that
    /// don't want to steal focus) must NOT request first-responder.
    func testAutofocus_disabled_doesNotRequestFirstResponder() {
        let textView = makeStandaloneEditableNSTextView()
        textView.autofocusOnFirstWindow = false
        let window = makeHeadlessWindow(contentView: textView)
        defer { window.orderOut(nil) }

        let expectation = XCTestExpectation(description: "first responder unchanged after viewDidMoveToWindow")
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                XCTAssertFalse(window.firstResponder === textView,
                               "Autofocus disabled — textView must not become first responder unsolicited.")
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Input lock (improve-prompt streaming)

    /// Default is unlocked — existing composer surfaces keep full editing.
    func testInputLock_defaultsFalse() {
        let textView = makeStandaloneEditableNSTextView()
        XCTAssertFalse(textView.isInputLocked)
    }

    /// While locked, the `shouldChangeText` funnel refuses interactive edits
    /// (keyboard, paste, delete). This is what blocks the user from typing a
    /// half-improved prompt mid-stream.
    func testInputLock_locked_refusesInteractiveEdits() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = "original"
        textView.isInputLocked = true

        let allowed = textView.shouldChangeText(
            in: NSRange(location: 8, length: 0), replacementString: "!")

        XCTAssertFalse(allowed, "a locked field must reject user edits at the shouldChangeText gate")
    }

    /// Unlocked, the gate defers to NSTextView's default (permits the edit).
    func testInputLock_unlocked_permitsInteractiveEdits() {
        let textView = makeStandaloneEditableNSTextView()
        textView.string = "original"
        textView.isInputLocked = false

        let allowed = textView.shouldChangeText(
            in: NSRange(location: 8, length: 0), replacementString: "!")

        XCTAssertTrue(allowed)
    }

    /// The improve stream writes via `.string =` (through the Coordinator's
    /// `applyText`), which bypasses `shouldChangeText` — so a locked field
    /// still receives programmatic stream writes.
    func testInputLock_programmaticApplyText_landsWhileLocked() async {
        let coordinator = EditableMessageTextView.Coordinator()
        let textView = makeStandaloneEditableNSTextView()
        textView.string = "original"
        textView.isInputLocked = true
        coordinator.absorbInitialText("original")

        coordinator.applyText("streamed rewrite", to: textView)

        XCTAssertEqual(textView.string, "streamed rewrite",
                       "programmatic stream writes must land even while manual input is locked")
    }

    /// `makeNSView` threads the initial `isInputLocked` onto the text view.
    func testMakeNSView_appliesInitialInputLock() {
        let textBinding = MutableBoxBinding(initial: "x")
        let focusBinding = MutableBoxBinding(initial: false)
        let view = EditableMessageTextView(
            text: textBinding.binding,
            isFocused: focusBinding.binding,
            placeholder: "",
            maxHeight: 220,
            minLineCount: 1,
            autofocusOnAppear: false,
            onReturnKey: { _, _ in false },
            isInputLocked: true
        )
        let coordinator = view.makeCoordinator()
        let scrollView = view.testHooks_makeNSView(coordinator: coordinator)

        XCTAssertEqual((scrollView.documentView as? EditableNSTextView)?.isInputLocked, true)
    }

    // MARK: - Test fixtures

    private func makeStandaloneTextView(initialText: String) -> NSTextView {
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80), textContainer: container)
        view.string = initialText
        return view
    }

    private func makeStandaloneEditableNSTextView() -> EditableNSTextView {
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        let view = EditableNSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80), textContainer: container)
        view.isEditable = true
        return view
    }

    /// Builds the representable with the fields these tests never vary, so a
    /// corner test reads as the one thing it changes.
    private func makeRepresentable(
        text: Binding<String>,
        isFocused: Binding<Bool>,
        placeholder: String,
        isInputLocked: Bool = false
    ) -> EditableMessageTextView {
        EditableMessageTextView(
            text: text,
            isFocused: isFocused,
            placeholder: placeholder,
            maxHeight: 220,
            minLineCount: 1,
            autofocusOnAppear: false,
            onReturnKey: { _, _ in false },
            isInputLocked: isInputLocked
        )
    }

    private func makeHeadlessWindow(contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        return window
    }
}

// MARK: - Test helpers

/// Tiny binding-like wrapper that owns its storage and exposes a
/// `Binding<Value>` so tests can read what production code wrote, and
/// count writes (idempotency assertions).
@MainActor
private final class MutableBoxBinding<Value> {
    var value: Value
    var writeCount: Int = 0

    init(initial: Value) { self.value = initial }

    var binding: Binding<Value> {
        Binding(
            get: { self.value },
            set: { newValue in
                self.writeCount += 1
                self.value = newValue
            }
        )
    }
}
