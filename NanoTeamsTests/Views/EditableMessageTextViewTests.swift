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

    // MARK: - NSScrollView wiring (native cursor-following preconditions)

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
