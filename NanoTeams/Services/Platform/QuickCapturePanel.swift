import AppKit
import SwiftUI

// MARK: - Quick Capture Panel

/// A floating NSPanel that hosts the Quick Capture SwiftUI form.
/// Stays on top of all windows (including other apps), supports text input,
/// and does not activate the main application window.
class QuickCapturePanel: NSPanel, NSWindowDelegate {
    var onPanelHidden: (() -> Void)?
    /// Called when the retry loop exhausted attempts AFTER seeing a focusable
    /// field at least once — meaning AppKit refused `makeFirstResponder`
    /// repeatedly and the caret never landed. Distinguishes the silent-caret
    /// bug from the legitimate working-mode case (only a loader, no field).
    var onFocusRestorationFailed: (() -> Void)?
    /// AppKit's Escape-key route. Wired by `QuickCaptureController` to its
    /// `cancelDraft()` so staged-attachment cleanup runs BEFORE the panel
    /// closes. Hosted here (not as a SwiftUI hidden Cancel button inside
    /// `QuickCaptureFormView`) because the SwiftUI ViewBuilder background
    /// pattern made the form re-evaluate per CoreAnimation frame the inner
    /// composer NSScrollView emitted during trackpad-scroll
    /// (CLAUDE.md Swift Style #50). When `nil` (tests/previews that don't
    /// own a draft), `cancelOperation` falls back to plain `orderOut(_:)`.
    var onCancelKeyPressed: (() -> Void)?

    /// The size the user last committed to via drag-resize (captured on
    /// `windowDidEndLiveResize`) — also seeded from the autosaved frame on
    /// first show. While set, all NON-live resize attempts are blocked: the
    /// override chain (`setFrame`, `setContentSize`) returns this size
    /// instead of the requested one. This is the defense against
    /// SwiftUI-content-driven auto-grow (NSHostingView propagating
    /// intrinsicContentSize despite `sizingOptions = []`). `nil` only during
    /// the brief window between init and first show.
    private var userLockedSize: NSSize?

    /// Authoritative resize floor — NOT to be read from `super.minSize`, which
    /// AppKit zeroes out ~2.5s after panel show for this style combo
    /// (`.nonactivatingPanel + .titled + .fullSizeContentView` + hidden window
    /// buttons + NSHostingView with `sizingOptions = []`). Observed in
    /// production logs: after the reset, every clamp/resize site that reads
    /// `self.minSize` saw `(0, 0)` and let user drag down to ~27×33 px.
    /// Pinned by `QuickCapturePanelMinSizeTests`.
    static let panelMinSize = NSSize(width: 250, height: 250)

    /// In-flight focus-retry Task. Stored so a new `startFocusRetry` call
    /// can cancel its predecessor — without this, rapid `+` presses spawn
    /// overlapping retry loops that all fire `onFocusRestorationFailed` on
    /// the silent-caret failure path, stacking the error banner.
    private var focusRetryTask: Task<Void, Never>?

    init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 260, height: 320)) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configure()
    }

    // MARK: - Configuration

    private func configure() {
        // Floating behavior
        isFloatingPanel = true
        level = .floating
        collectionBehavior.insert(.fullScreenAuxiliary)

        // Titlebar
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true

        // Persistence
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        // Appearance
        backgroundColor = NSColor(Colors.surfacePrimary)
        isOpaque = false
        hasShadow = true
        animationBehavior = .none

        // Resize floor = `panelMinSize` (single source of truth declared
        // above). `minSize` alone doesn't always cap user drag-resize for
        // this style combo (`.nonactivatingPanel` + `.fullSizeContentView`
        // + transparent titlebar — users can still drag below the floor);
        // the real enforcement lives in `windowWillResize(_:to:)` and the
        // override chain (`setFrame`, `setContentSize`) below. We also
        // set `contentMinSize` so the content-area resize path is capped.
        // Pinned by `QuickCapturePanelMinSizeTests`.
        minSize = Self.panelMinSize
        contentMinSize = Self.panelMinSize
        delegate = self
        setFrameAutosaveName(UserDefaultsKeys.quickCapturePanelFrame)

        // Hide standard window buttons
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    // MARK: - SwiftUI Content

    /// Sets the SwiftUI content view for this panel.
    func setContent<Content: View>(_ view: Content) {
        let hosting = NSHostingView(rootView: view.ignoresSafeArea())
        // Pin the panel to the user-resized frame: don't let SwiftUI's intrinsic
        // content size drive a window resize. Without this, `onGeometryChange`
        // measurements inside the form (e.g. MessageComposer's auto-grow field)
        // feed a new preferred size up through NSHostingView, and the autosaved
        // frame ends up oscillating.
        hosting.sizingOptions = []
        contentView = hosting
    }

    // MARK: - Focus

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Resize floor enforcement
    //
    // For this particular style combo (`.nonactivatingPanel` + `.titled` +
    // `.fullSizeContentView` + transparent titlebar + hidden window buttons),
    // neither `minSize`/`contentMinSize` nor `windowWillResize` reliably caps
    // user drag. AppKit takes different routes during live resize (one of
    // `setFrame:display:`, `setFrameSize:`, `setContentSize:`), and we don't
    // know in advance which one the user's drag will hit. We override ALL of
    // them and provide a post-fact snap-back via `windowDidResize` as the
    // last resort if a future macOS release adds yet another path.

    private func decide(_ requested: NSSize) -> NSSize {
        ResizeDecision.decide(
            requested: requested,
            userLocked: userLockedSize,
            floor: Self.panelMinSize,
            isUserResize: inLiveResize
        )
    }

    @objc func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // `windowWillResize` only fires during live user drag, so request is
        // always honored (clamped to floor). Lock is captured at drag end.
        ResizeDecision.decide(
            requested: frameSize,
            userLocked: userLockedSize,
            floor: Self.panelMinSize,
            isUserResize: true
        )
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // User finished dragging — this size becomes the new lock. Any
        // subsequent NSHostingView intrinsic-size push will be ignored.
        captureUserLock(size: frame.size)
    }

    /// Stores the user's intended size as the lock, clamping to floor.
    /// AppKit can zero `super.minSize` mid-drag for our style combo, so
    /// `frame.size` at drag-end may be sub-floor — clamping here prevents
    /// the lock from pinning the panel below the floor on subsequent shows.
    /// Pinned by `QuickCapturePanelMinSizeTests`.
    private func captureUserLock(size: NSSize) {
        userLockedSize = clampSize(size)
    }

    func windowDidResize(_ notification: Notification) {
        // Two cases:
        //   1. In live drag: enforce floor (lock is irrelevant — user is
        //      actively setting a new size, captured on drag end).
        //   2. Not in live drag: any size delta is programmatic
        //      (content-driven). Restore the lock if it differs.
        if inLiveResize {
            let clamped = clampSize(frame.size)
            if clamped != frame.size {
                var newFrame = frame
                newFrame.size = clamped
                super.setFrame(newFrame, display: true)
            }
            return
        }
        if let locked = userLockedSize, frame.size != locked {
            var newFrame = frame
            newFrame.size = locked
            super.setFrame(newFrame, display: false)
        }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let decided = decide(frameRect.size)
        super.setFrame(NSRect(origin: frameRect.origin, size: decided), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        let decided = decide(frameRect.size)
        super.setFrame(NSRect(origin: frameRect.origin, size: decided), display: displayFlag, animate: animateFlag)
    }

    override func setContentSize(_ size: NSSize) {
        super.setContentSize(decide(size))
    }

    // MARK: - minSize / contentMinSize floor (defensive)
    //
    // AppKit zeroes out `super.minSize` and `super.contentMinSize` ~2.5s after
    // panel show for this style combo (observed in production logs). The
    // override getters return at least `panelMinSize` so live-resize keeps
    // honoring the floor regardless of internal resets.
    override var minSize: NSSize {
        get {
            let base = super.minSize
            return NSSize(
                width: max(base.width, Self.panelMinSize.width),
                height: max(base.height, Self.panelMinSize.height)
            )
        }
        set { super.minSize = newValue }
    }

    override var contentMinSize: NSSize {
        get {
            let base = super.contentMinSize
            return NSSize(
                width: max(base.width, Self.panelMinSize.width),
                height: max(base.height, Self.panelMinSize.height)
            )
        }
        set { super.contentMinSize = newValue }
    }

    // MARK: - Resize decision (pure)
    //
    // Drives every resize entry on the panel — `setFrame`, `setContentSize`,
    // `windowWillResize` — so SwiftUI content-intrinsic-size auto-grow does
    // NOT change the window dimensions after the user has set them via drag.
    // `NSHostingView` propagates `intrinsicContentSize` up to the host panel
    // even with `sizingOptions = []` (known macOS 13+ behavior); without an
    // explicit lock on the user's frame, every content change (mode swap,
    // long question text, attachment grid expansion) re-fits the panel.
    // Unit-tested in `QuickCapturePanelResizeDecisionTests`.
    nonisolated enum ResizeDecision {
        /// `decide` (not `resize`) because the function classifies — the caller
        /// is the one that applies the result. Symmetric with
        /// `FocusRetryDecision.step`.
        static func decide(
            requested: NSSize,
            userLocked: NSSize?,
            floor: NSSize,
            isUserResize: Bool
        ) -> NSSize {
            let clampedRequest = clamp(requested, to: floor)
            if isUserResize { return clampedRequest }
            // Re-clamp the lock too — never trust it to be ≥ floor. AppKit
            // zeros `super.minSize` for our style combo, so a lock captured
            // mid-drag during the reset window could be sub-floor; without
            // re-clamping here a stale lock would silently produce a
            // sub-floor result.
            if let locked = userLocked {
                return clamp(locked, to: floor)
            }
            return clampedRequest
        }

        private static func clamp(_ size: NSSize, to floor: NSSize) -> NSSize {
            NSSize(
                width: max(size.width, floor.width),
                height: max(size.height, floor.height)
            )
        }
    }

    private func clampSize(_ size: NSSize) -> NSSize {
        // Read from the static constant — NOT `self.minSize`. The property
        // override above already clamps reads, but using the constant directly
        // is one less indirection AND keeps clamp logic working in unit tests
        // that mutate `super.minSize` directly to simulate the reset.
        NSSize(
            width: max(size.width, Self.panelMinSize.width),
            height: max(size.height, Self.panelMinSize.height)
        )
    }

    private func clampRect(_ rect: NSRect) -> NSRect {
        NSRect(origin: rect.origin, size: clampSize(rect.size))
    }

    // MARK: - Focus Retry Loop

    /// Terminal outcome of `runFocusRetry`. The pure-decision step
    /// (`FocusRetryDecision.Step`) carries `.retry` as an INTERMEDIATE value;
    /// this loop-level type is `.success` / `.exhausted` / `.cancelled` only,
    /// since the loop runs to completion before returning.
    enum FocusRetryOutcome: Equatable {
        /// A focusable field was found and AppKit accepted `makeFirstResponder`.
        case success
        /// All attempts ran without success. `sawFieldEver == true` means a
        /// field was found at least once but AppKit refused it — caller should
        /// surface the silent-caret banner. `false` means no field ever appeared
        /// (expected for working-mode loader panels).
        case exhausted(sawFieldEver: Bool)
        /// `provideContentView` returned `nil` (panel torn down), `isCancelled`
        /// returned `true` (Task cancelled mid-sleep), or `makeFirstResponder`
        /// returned `.cancelled` (`[weak self]` caught a dead panel). Caller
        /// should exit silently — this is a benign dismissal, not an error.
        case cancelled

        /// Should this outcome surface to the user via `onFocusRestorationFailed`?
        /// `expectsFocusableField` disambiguates the `.exhausted(sawFieldEver: false)`
        /// case — for loader-only working mode it's legitimate (silent OK), for
        /// overlay/answer/chat-working it's a real form-rendering regression and
        /// must be reported.
        ///
        /// `.exhausted(sawFieldEver: true)` is always reported: a field appeared
        /// but AppKit refused it — that's the silent-caret bug we're guarding
        /// against, regardless of caller mode.
        func shouldReportFailure(expectsFocusableField: Bool) -> Bool {
            switch self {
            case .success, .cancelled:
                return false
            case .exhausted(let sawAny):
                return sawAny || expectsFocusableField
            }
        }
    }

    /// Tri-state result of asking AppKit to make a view first-responder.
    /// Distinguishes the silent-teardown case (`[weak self]` saw nil) from
    /// AppKit's refusal — both produce `focusSucceeded: false` for the
    /// classifier, but `.cancelled` additionally short-circuits the loop so
    /// a torn-down panel doesn't trip `onFocusRestorationFailed`.
    ///
    /// `Sendable` for symmetry with `FocusRetryDecision.Step` — the value
    /// flows through an async retry loop's closure, so the conformance is
    /// load-bearing under Swift 6 strict concurrency.
    enum ResponderResult: Equatable, Sendable {
        /// AppKit's `makeFirstResponder(_:)` returned `true`.
        case accepted
        /// AppKit refused — outgoing responder vetoed `resignFirstResponder`,
        /// or `acceptsFirstResponder` flipped between walk and call.
        case refused
        /// The wrapping closure observed a dead panel (`[weak self]` was nil).
        /// Loop must exit `.cancelled`; reporting `.refused` here would
        /// misclassify the teardown as a silent-caret bug.
        case cancelled
    }

    /// Drives the focus-restoration retry loop with injected side-effect
    /// dependencies so the composition is unit-testable without a real NSPanel.
    /// The pure-decision classifier lives in `FocusRetryDecision.step`; this
    /// helper sequences it with `layoutForce` (forces NSHostingView to mount its
    /// SwiftUI subtree before the responder walk), `sleep` (16ms inter-attempt
    /// gap on the production path), and `isCancelled` checks.
    @MainActor
    static func runFocusRetry(
        maxAttempts: Int,
        provideContentView: @MainActor () -> NSView?,
        layoutForce: @MainActor (NSView) -> Void,
        findField: @MainActor (NSView) -> NSView? = firstFocusableTextResponder,
        makeFirstResponder: @MainActor (NSView) -> ResponderResult,
        sleep: () async -> Void,
        isCancelled: @MainActor () -> Bool
    ) async -> FocusRetryOutcome {
        var sawFieldEver = false
        for attempt in 0..<maxAttempts {
            guard let contentView = provideContentView() else { return .cancelled }
            layoutForce(contentView)
            let firstField = findField(contentView)
            let foundField = firstField != nil
            let respondResult = firstField.map { makeFirstResponder($0) }
            if respondResult == .cancelled { return .cancelled }
            let focusSucceeded = respondResult == .accepted
            switch FocusRetryDecision.step(
                attempt: attempt,
                maxAttempts: maxAttempts,
                sawFieldEver: sawFieldEver,
                foundField: foundField,
                focusSucceeded: focusSucceeded
            ) {
            case .success:
                return .success
            case .retry:
                sawFieldEver = sawFieldEver || foundField
                await sleep()
                if isCancelled() { return .cancelled }
            case .exhausted(let sawAny):
                return .exhausted(sawFieldEver: sawAny)
            }
        }
        // `maxAttempts == 0` is a no-op contract, not a misuse — return the
        // same shape as a real exhaustion so callers route via the standard
        // `.exhausted` branch.
        return .exhausted(sawFieldEver: sawFieldEver)
    }

    // MARK: - Focus Retry Decision (pure)

    /// Pure step function used by `show(expectsFocusableField:)`'s focus retry
    /// loop. Extracted so the success-vs-refused-vs-exhausted classification
    /// is unit-testable (see `QuickCapturePanelFocusRetryDecisionTests`).
    /// `nonisolated` so tests can call it without crossing the main actor.
    nonisolated enum FocusRetryDecision {
        enum Step: Equatable, Sendable {
            case success                                  // field focused
            case retry                                    // try again next frame
            case exhausted(sawFieldEver: Bool)            // give up; carrier flag tells caller whether a field was ever seen
        }

        static func step(
            attempt: Int,
            maxAttempts: Int,
            sawFieldEver: Bool,
            foundField: Bool,
            focusSucceeded: Bool
        ) -> Step {
            if foundField, focusSucceeded { return .success }
            if attempt + 1 >= maxAttempts {
                return .exhausted(sawFieldEver: sawFieldEver || foundField)
            }
            return .retry
        }
    }

    // MARK: - Dismiss on Esc

    override func cancelOperation(_ sender: Any?) {
        // Host owns dismissal when wired — it needs to run cleanup (e.g.
        // `cancelDraft`) synchronously before the panel closes, and would
        // race a direct `orderOut(_:)` here.
        if let onCancelKeyPressed {
            onCancelKeyPressed()
        } else {
            orderOut(sender)
        }
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onPanelHidden?()
    }

    // MARK: - Show / Hide

    /// Shows the panel. Restores the autosaved frame (clamped to floor), centers
    /// on the mouse screen if no autosave is usable, then kicks off the async
    /// focus-retry loop. The `expectsFocusableField` parameter disambiguates the
    /// `.exhausted(sawFieldEver: false)` outcome — passed in (rather than read
    /// from a mutable property) so each invocation locks in the value at
    /// show-time, immune to a concurrent re-show racing the in-flight retry.
    func show(expectsFocusableField: Bool) {
        #if DEBUG
        _testLastShowExpectsFocusableField = expectsFocusableField
        #endif
        // Clear the lock before `setFrameUsingName` so autosave restore can
        // apply — otherwise the override chain would treat the restore as a
        // programmatic resize and ignore it. Lock is re-captured below from
        // the actual restored frame, so the size is preserved end-to-end.
        userLockedSize = nil
        let restored = setFrameUsingName(frameAutosaveName)
        if !restored || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            centerOnMouseScreen()
        }
        // `setFrameUsingName` restores the saved frame verbatim — it does NOT
        // clamp to the current `minSize`. Frames persisted under a prior, smaller
        // floor (or before the floor was raised at all) come back below it, and
        // once the window is below `minSize` AppKit's live-resize drag won't pull
        // it back up. Clamp here and re-save so the floor sticks across sessions.
        var clamped = frame
        if clamped.size.width < Self.panelMinSize.width { clamped.size.width = Self.panelMinSize.width }
        if clamped.size.height < Self.panelMinSize.height { clamped.size.height = Self.panelMinSize.height }
        if clamped != frame {
            setFrame(clamped, display: false)
            saveFrame(usingName: frameAutosaveName)
        }
        // Capture the restored (and floor-clamped) frame as the user's lock so
        // any subsequent SwiftUI-content-driven resize is ignored.
        captureUserLock(size: frame.size)
        makeKeyAndOrderFront(nil)

        // SwiftUI's `@FocusState`-driven `.focused($var)` does not reliably
        // activate inside an NSPanel-hosted `NSHostingView`; the AppKit
        // responder retry loop is the load-bearing path.
        // `requireVisible: false` — `makeKeyAndOrderFront` above already made
        // the panel visible synchronously.
        startFocusRetry(expectsFocusableField: expectsFocusableField, requireVisible: false)
    }

    /// Re-runs the responder retry loop against the current `contentView`
    /// when the hosting view was swapped (`setContent(_:)`) and the AppKit
    /// first responder was dropped.
    func refocusInputField() {
        #if DEBUG
        _testRefocusInvocationCount += 1
        #endif
        // Clicking the sidebar `+` makes the main NanoTeams window key, so
        // the panel is `isVisible` but not `isKeyWindow` — the caret won't
        // appear even after `makeFirstResponder` succeeds. Pull key back
        // (no app activation: `.nonactivatingPanel` style).
        makeKeyAndOrderFront(nil)
        // `requireVisible: true` defends the dismiss-race — user can Esc
        // mid-retry; without the guard the loop would exhaust against an
        // `orderOut`-ed window and trip the silent-caret banner.
        startFocusRetry(expectsFocusableField: true, requireVisible: true)
    }

    private func startFocusRetry(expectsFocusableField: Bool, requireVisible: Bool) {
        // Cancel any in-flight retry so spam-tap collapses to one outcome
        // (the loop's `isCancelled` check converts cancellation to `.cancelled`,
        // which `shouldReportFailure` suppresses).
        focusRetryTask?.cancel()
        focusRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await Self.runFocusRetry(
                maxAttempts: 15,  // ~240ms total budget (15 × 16ms)
                provideContentView: { [weak self] in
                    guard let self else { return nil }
                    // Dismiss-race guard for the refocus path: a non-visible
                    // panel means the user closed it after our caller picked
                    // up `isPanelVisible == true`. Returning nil routes the
                    // loop to `.cancelled` instead of an `.exhausted` that
                    // would falsely fire `onFocusRestorationFailed`.
                    if requireVisible, !self.isVisible { return nil }
                    return self.contentView
                },
                layoutForce: { $0.layoutSubtreeIfNeeded() },
                makeFirstResponder: { [weak self] view -> ResponderResult in
                    // Dead self → `.cancelled` routes the outcome through
                    // silent benign exit rather than the silent-caret banner.
                    guard let self else { return .cancelled }
                    return self.makeFirstResponder(view) ? .accepted : .refused
                },
                sleep: { try? await Task.sleep(for: .milliseconds(16)) },
                isCancelled: { Task.isCancelled }
            )
            if outcome.shouldReportFailure(expectsFocusableField: expectsFocusableField) {
                self.onFocusRestorationFailed?()
            }
        }
    }

    // MARK: - First Responder Discovery

    /// Depth-first search for the first NSView capable of becoming first responder
    /// AND accepting text input — i.e. an editable `NSTextView` or `NSTextField`.
    /// Skips hidden views and non-text responders (labels, decorative views).
    /// Returns the first match or nil.
    private static func firstFocusableTextResponder(in view: NSView) -> NSView? {
        if view.isHidden { return nil }
        if let text = view as? NSTextView, text.isEditable, text.acceptsFirstResponder {
            return text
        }
        if let field = view as? NSTextField, field.isEditable, field.acceptsFirstResponder {
            return field
        }
        for sub in view.subviews {
            if let match = firstFocusableTextResponder(in: sub) {
                return match
            }
        }
        return nil
    }

    #if DEBUG
    /// Records the `expectsFocusableField` value passed to the most recent
    /// `show(...)` call. Reset by writing `nil`.
    var _testLastShowExpectsFocusableField: Bool?

    private(set) var _testRefocusInvocationCount = 0

    /// Test-only access to the private walker. Pinned by `QuickCapturePanelWalkerTests`.
    static func _testFirstFocusableTextResponder(in view: NSView) -> NSView? {
        firstFocusableTextResponder(in: view)
    }
    /// Test-only access to the resize clamp helpers. Pinned by
    /// `QuickCapturePanelMinSizeTests` — the 250×250 floor MUST stay in sync
    /// with `minSize`/`contentMinSize` so that all clamp routes
    /// (`windowWillResize`, `setFrame`, `setContentSize`) honor the same value.
    func _testClampSize(_ size: NSSize) -> NSSize { clampSize(size) }
    func _testClampRect(_ rect: NSRect) -> NSRect { clampRect(rect) }
    var _testUserLockedSize: NSSize? { userLockedSize }
    func _testCaptureUserLock(size: NSSize) { captureUserLock(size: size) }
    #endif

    /// Hides the panel. Does NOT release or clear content.
    func hide() {
        // Explicit save so the user's last-resized frame is durably persisted
        // before we order-out. AppKit's automatic autosave fires on resize
        // events, but with `isReleasedWhenClosed = false` + `.nonactivatingPanel`
        // the auto-save can miss the final resize-then-immediately-hide
        // sequence; without this call, autosave intermittently lost the user's
        // newly-chosen size and the next show restored a stale frame.
        saveFrame(usingName: frameAutosaveName)
        orderOut(nil)
    }

    // MARK: - Positioning

    private func centerOnMouseScreen() {
        let mouseScreen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main

        guard let screen = mouseScreen else { return }

        let screenFrame = screen.visibleFrame
        let panelFrame = frame
        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.midY - panelFrame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    nonisolated deinit {}
}

// MARK: - Previews

// periphery:ignore - used in #Preview macros below
@MainActor
private enum QuickCapturePanelPreview {
    static func makeStore() -> NTMSOrchestrator {
        let store = NTMSOrchestrator(repository: NTMSRepository())
        store.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "Preview"),
                settings: .defaults,
                teams: Team.defaultTeams
            ),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: nil
        )
        return store
    }

    static func makeFormState(
        supervisorTask: String = "",
        attachments: [StagedAttachment] = [],
        clippedTexts: [String] = []
    ) -> QuickCaptureFormState {
        let state = QuickCaptureFormState()
        state.supervisorTask = supervisorTask
        state.attachments = attachments
        state.clippedTexts = clippedTexts
        return state
    }

    static func makeAttachment(
        fileName: String,
        stagedRelativePath: String
    ) -> StagedAttachment {
        // Preview helper — create a temp file so StagedAttachment.init succeeds.
        let url = URL(fileURLWithPath: "/tmp/\(fileName)")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        // swiftlint:disable:next force_try
        return try! StagedAttachment(url: url, stagedRelativePath: stagedRelativePath)
    }
}

#Preview("Quick Capture Panel — Empty") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState()

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(store.configuration)
    .environment(StreamingPreviewManager())
    .frame(width: 250, height: 360)
}

#Preview("Quick Capture Panel — Task") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState(
        supervisorTask: "Review the first-run experience, identify friction points, and propose a simpler setup path."
    )

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(store.configuration)
    .environment(StreamingPreviewManager())
    .frame(width: 250, height: 360)
}

#Preview("Quick Capture Panel — Clips") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState(
        supervisorTask: "Summarize the pasted research and extract the main risks.",
        clippedTexts: [
            "Interview notes mention a slow setup flow and unclear permissions prompts.",
            "Support tickets mention users abandoning onboarding before the first successful action."
        ]
    )

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(store.configuration)
    .environment(StreamingPreviewManager())
    .frame(width: 250, height: 360)
}

#Preview("Quick Capture Panel — Files") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState(
        attachments: [
            QuickCapturePanelPreview.makeAttachment(fileName: "LaunchPlan.md", stagedRelativePath: "drafts/launch-plan.md"),
            QuickCapturePanelPreview.makeAttachment(fileName: "Metrics.csv", stagedRelativePath: "drafts/metrics.csv")
        ]
    )

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(store.configuration)
    .environment(StreamingPreviewManager())
    .frame(width: 250, height: 360)
}

#Preview("Quick Capture Panel — Mixed") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState(
        supervisorTask: "Combine the attached documents with the clipped evidence and propose a retention experiment plan.",
        attachments: [
            QuickCapturePanelPreview.makeAttachment(fileName: "RetentionBrief.pdf", stagedRelativePath: "drafts/retention-brief.pdf")
        ],
        clippedTexts: [
            "Customer interviews highlight that teams do not understand what happens after they create the first task."
        ]
    )

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(store.configuration)
    .environment(StreamingPreviewManager())
    .frame(width: 250, height: 420)
}

#Preview("Supervisor Answer") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState()

    let payload = SupervisorAnswerPayload(
        stepID: "preview",
        taskID: Int(),
        role: .softwareEngineer,
        roleDefinition: nil,
        question: "Should I use async/await or completion handlers for the network layer?",
        messageContent: "I've analyzed the existing codebase and found two possible approaches for the network layer. I need your guidance on which direction to take.",
        thinking: "The codebase currently mixes both patterns. I should ask which one to standardize on.",
        isChatMode: false
    )

    QuickCaptureFormView(
        mode: .supervisorAnswer(payload: payload),
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(store.configuration)
    .environment(StreamingPreviewManager())
    .frame(width: 250, height: 420)
}

#Preview("Supervisor Answer — Chat Mode") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState()

    let payload = SupervisorAnswerPayload(
        stepID: "preview",
        taskID: Int(),
        role: .custom(id: "assistant"),
        roleDefinition: TeamRoleDefinition(
            id: "assistant", name: "Assistant", icon: "bubble.left.and.bubble.right.fill",
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            iconBackground: RoleColorDefaults.defaultHex
        ),
        question: "What should I focus on next?",
        messageContent: "Hi! I'm ready to help. What do you need?\n\nOptions:\n1. Describe a specific task\n2. Upload files to work with\n3. Ask something about the project",
        thinking: "The user started a chat session. I should ask what they need help with.",
        isChatMode: true
    )

    QuickCaptureFormView(
        mode: .supervisorAnswer(payload: payload),
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(store.configuration)
    .environment(StreamingPreviewManager())
    .frame(width: 250, height: 540)
}
