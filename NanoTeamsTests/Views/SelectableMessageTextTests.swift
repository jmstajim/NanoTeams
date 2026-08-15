import XCTest
import AppKit
@testable import NanoTeams

/// Pins the load-bearing perf primitives of `SelectableMessageText`. The
/// streaming hot path depends on `applyContent` taking the **append-only**
/// branch when new content is a strict prefix-extension of the prior
/// applied content — that keeps `NSLayoutManager`'s glyph layout bounded
/// to the delta instead of re-shaping the entire string.
///
/// The fixture uses `SelfSizingTextView` (production type) so the tests
/// never silently fall through TextKit 1's escape hatches; the `apply()`
/// helper tracks `previousContent` in a `var` field, mirroring production's
/// `Coordinator`, so the prefix-extension check sees the same baseline
/// production does.
@MainActor
final class SelectableMessageTextTests: XCTestCase {

    private var textView: SelfSizingTextView!
    private var previousContent: String = ""
    private var attributes: [NSAttributedString.Key: Any]!

    override func setUp() async throws {
        try await super.setUp()
        // Static-state hygiene: the process-wide fallback width must not
        // leak between test cases (any setFrameSize ≥ 50 records it).
        SelfSizingTextView.resetFallbackWidthForTesting()
        textView = SelfSizingTextView()
        SelectableMessageText.configure(textView)
        attributes = SelectableMessageText.defaultAttributes
        textView.textStorage?.setAttributedString(NSAttributedString(string: "", attributes: attributes))
        previousContent = ""
    }

    override func tearDown() async throws {
        SelfSizingTextView.resetFallbackWidthForTesting()
        textView = nil
        attributes = nil
        previousContent = ""
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Drive `applyContent` exactly as production does: pass our tracked
    /// `previousContent` as the baseline (mirroring `Coordinator.lastAppliedContent`),
    /// and only update the baseline on success.
    @discardableResult
    private func apply(_ content: String) -> Bool {
        let didApply = SelectableMessageText.applyContent(
            content,
            previousContent: previousContent,
            to: textView,
            attributes: attributes
        )
        if didApply { previousContent = content }
        return didApply
    }

    /// Capture the next NSTextStorage edit notification's `editedMask`
    /// and `editedRange` for one `apply` call. Returns `nil` if no edit
    /// fires (same-content no-op).
    private func captureEdit(during action: () -> Void) -> (mask: NSTextStorageEditActions, range: NSRange)? {
        guard let storage = textView.textStorage else {
            XCTFail("textStorage missing — fixture broken")
            return nil
        }
        let recorder = TextStorageEditRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { note in
            guard let s = note.object as? NSTextStorage else { return }
            recorder.captures.append((mask: s.editedMask, range: s.editedRange))
        }
        defer { NotificationCenter.default.removeObserver(token) }
        action()
        return recorder.captures.last
    }

    // MARK: - Basic content propagation

    func testApplyContent_setsContentOnEmptyView() async {
        XCTAssertTrue(apply("Hello"))
        XCTAssertEqual(textView.string, "Hello")
    }

    func testApplyContent_identicalContent_isNoop() async {
        apply("Hello")
        let storageBefore = textView.textStorage
        XCTAssertTrue(apply("Hello"), "Same content must succeed (no-op success).")
        XCTAssertEqual(textView.string, "Hello")
        XCTAssertTrue(textView.textStorage === storageBefore,
                      "Same-content update must not swap the text storage.")
    }

    // MARK: - Streaming hot path: append-only verified via edit notifications (C3)

    /// The append-only branch fires `editedCharacters` over a range whose
    /// `location` equals the prior storage length. A full replace fires
    /// over `(0, newLength)`. Pinning the range distinguishes the two
    /// paths — storage identity / monotonic length alone don't.
    func testApplyContent_prefixExtension_takesAppendBranch_notFullReplace() async {
        apply("Hello ")
        let lengthBefore = textView.textStorage?.length ?? 0
        let edit = captureEdit(during: { apply("Hello World") })
        XCTAssertNotNil(edit, "Prefix-extension must fire an edit notification.")
        XCTAssertTrue(edit!.mask.contains(.editedCharacters),
                      "Append must fire .editedCharacters.")
        XCTAssertEqual(edit!.range.location, lengthBefore,
                       "Append range must start at prior length, not 0 — full-replace would start at 0.")
        XCTAssertEqual(edit!.range.length, "World".utf16.count,
                       "Append range length must equal the suffix's UTF-16 count.")
        XCTAssertEqual(textView.string, "Hello World")
    }

    /// Multi-tick streaming: every tick takes the append branch. If any
    /// iteration fell through to full replace, its edit range would
    /// start at 0 and the test would fail.
    func testApplyContent_repeatedPrefixExtensions_eachTickTakesAppendBranch() async {
        apply("a")
        for stop in 2...50 {
            let next = String(repeating: "a", count: stop)
            let priorLength = textView.textStorage?.length ?? 0
            let edit = captureEdit(during: { apply(next) })
            guard let edit else {
                return XCTFail("Iteration \(stop): expected an edit notification.")
            }
            XCTAssertEqual(edit.range.location, priorLength,
                           "Iteration \(stop): append range must start at prior length \(priorLength), got \(edit.range.location).")
            XCTAssertEqual(edit.range.length, 1,
                           "Iteration \(stop): single-char append must fire a 1-length edit range.")
        }
        XCTAssertEqual(textView.string.count, 50)
    }

    // MARK: - Diverging path: full replace verified via edit notifications

    /// Diverging content fires an edit over `(0, newLength)` — the
    /// signature of `setAttributedString`.
    func testApplyContent_divergingContent_takesFullReplaceBranch() async {
        apply("abc")
        let edit = captureEdit(during: { apply("xyz") })
        XCTAssertNotNil(edit)
        XCTAssertEqual(edit!.range.location, 0,
                       "Diverging content must full-replace from offset 0.")
        XCTAssertEqual(edit!.range.length, "xyz".utf16.count)
        XCTAssertEqual(textView.string, "xyz")
    }

    func testApplyContent_commitTimeRewrite_replacesCleanly() async {
        apply("Hello world")
        apply("world only")
        XCTAssertEqual(textView.string, "world only")
        XCTAssertFalse(textView.string.contains("Hello"))
    }

    func testApplyContent_sharedPrefixButDiverging_doesFullReplace() async {
        apply("Hello world")
        let edit = captureEdit(during: { apply("Hello there") })
        XCTAssertNotNil(edit)
        XCTAssertEqual(edit!.range.location, 0,
                       "Shared prefix with diverging tail must full-replace, not append.")
        XCTAssertEqual(textView.string, "Hello there")
    }

    /// Empty new content after a non-empty baseline takes the diverging
    /// branch (`"".hasPrefix(nonEmpty) == false`), so storage clears.
    func testApplyContent_emptyNewContent_clearsView() async {
        apply("Hello")
        apply("")
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(textView.textStorage?.length ?? -1, 0)
    }

    // MARK: - Unicode correctness

    func testApplyContent_streamingZWJEmoji_doesNotCorruptCluster() async {
        let stages: [String] = [
            "👨",
            "👨\u{200D}",
            "👨\u{200D}👩",
            "👨\u{200D}👩\u{200D}",
            "👨\u{200D}👩\u{200D}👧"
        ]
        for stage in stages {
            apply(stage)
            XCTAssertEqual(textView.string, stage,
                           "After applying \(stage.unicodeScalars.count) scalars, view must match input verbatim.")
        }
    }

    func testApplyContent_combiningMarks_doesNotCorrupt() async {
        apply("e")
        apply("e\u{0301}")
        XCTAssertEqual(textView.string, "e\u{0301}")
    }

    // MARK: - Attribute preservation across appends

    func testApplyContent_attributesPreservedAcrossAppends() async {
        apply("Hello ")
        apply("Hello World")
        guard let storage = textView.textStorage, storage.length > 6 else {
            return XCTFail("storage too short to test boundary attributes")
        }
        let prefixAttrs = storage.attributes(at: 5, effectiveRange: nil)
        let suffixAttrs = storage.attributes(at: 6, effectiveRange: nil)
        XCTAssertEqual(prefixAttrs[.font] as? NSFont, suffixAttrs[.font] as? NSFont)
        XCTAssertEqual(prefixAttrs[.foregroundColor] as? NSColor, suffixAttrs[.foregroundColor] as? NSColor)
    }

    // MARK: - View configuration

    func testConfigure_setsReadOnlyTransparentFlags() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.drawsBackground)
        XCTAssertFalse(view.isRichText)
        XCTAssertEqual(view.textContainer?.lineFragmentPadding, 0)
        XCTAssertEqual(view.textContainerInset, .zero)
        XCTAssertFalse(view.textContainer?.widthTracksTextView ?? true,
                       "widthTracksTextView must be off — we sync from setFrameSize.")
    }

    // MARK: - SelfSizingTextView contracts

    func testSelfSizingTextView_init_hasTextKit1LayoutManager() async {
        let view = SelfSizingTextView()
        XCTAssertNotNil(view.layoutManager)
        XCTAssertNotNil(view.textContainer)
        XCTAssertNotNil(view.textStorage)
    }

    func testSelfSizingTextView_intrinsicContentSize_widthIsNoIntrinsicMetric() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        view.setFrameSize(NSSize(width: 200, height: 100))
        SelectableMessageText.applyContent(
            "Some content that takes up some lines of text and probably wraps a few times.",
            previousContent: "",
            to: view, attributes: attributes
        )
        let size = view.intrinsicContentSize
        XCTAssertEqual(size.width, NSView.noIntrinsicMetric,
                       "Width must be noIntrinsicMetric — SwiftUI's parent .frame(maxWidth: .infinity) drives width.")
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertEqual(size.height, ceil(size.height),
                       "Height must be ceil'd so SwiftUI doesn't get sub-pixel jitter.")
    }

    func testSelfSizingTextView_setFrameSize_syncsTextContainerWidth() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        view.setFrameSize(NSSize(width: 100, height: 0))
        XCTAssertEqual(view.textContainer?.size.width ?? 0, 100, accuracy: 0.6)
        view.setFrameSize(NSSize(width: 350, height: 0))
        XCTAssertEqual(view.textContainer?.size.width ?? 0, 350, accuracy: 0.6)
    }

    // MARK: - setFrameSize epsilon (S5 — pin both edges of the > 0.5pt threshold)

    func testSelfSizingTextView_setFrameSize_subPixelChange_isNoOp() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        view.setFrameSize(NSSize(width: 200.0, height: 0))
        view.resetTestCountersForTesting()

        view.setFrameSize(NSSize(width: 200.3, height: 0))
        XCTAssertEqual(view.invalidationCountForTesting, 0,
                       "Sub-pixel width change (0.3pt) must not trigger invalidate.")

        view.setFrameSize(NSSize(width: 201.5, height: 0))
        XCTAssertEqual(view.invalidationCountForTesting, 1,
                       "Width change beyond the epsilon (1.5pt) must trigger one invalidate.")
    }

    /// Strict `> 0.5` boundary: exactly 0.5pt does NOT trigger; 0.51pt does.
    /// Pinned so a regression to `>= 0.5` shifts the boundary by one float
    /// epsilon and gets caught.
    func testSelfSizingTextView_setFrameSize_exactlyEpsilon_isNoOp() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        view.setFrameSize(NSSize(width: 200.0, height: 0))
        view.resetTestCountersForTesting()

        view.setFrameSize(NSSize(width: 200.5, height: 0))
        XCTAssertEqual(view.invalidationCountForTesting, 0,
                       "Exactly 0.5pt change must NOT trigger (strict > 0.5 inequality).")

        view.setFrameSize(NSSize(width: 201.01, height: 0))
        XCTAssertEqual(view.invalidationCountForTesting, 1,
                       "0.51pt change above 200.5 must trigger.")
    }

    func testSelfSizingTextView_scrollWheel_forwardsToNextResponder() async {
        let view = SelfSizingTextView()
        let recorder = ScrollWheelRecorder()
        view.nextResponder = recorder

        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cgEvent)
        else {
            return XCTFail("Could not synthesize a scroll wheel event.")
        }
        view.scrollWheel(with: event)
        XCTAssertEqual(recorder.scrollEventCount, 1)
    }

    func testSelfSizingTextView_scrollWheel_nilNextResponder_doesNotCrash() async {
        let view = SelfSizingTextView()
        XCTAssertNil(view.nextResponder)
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                    wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cgEvent)
        else {
            return XCTFail("Could not synthesize a scroll wheel event.")
        }
        view.scrollWheel(with: event)
    }

    func testSelfSizingTextView_resetCursorRects_addsArrowCursor() async {
        let view = SelfSizingTextView()
        view.setFrameSize(NSSize(width: 200, height: 50))
        view.resetCursorRects()
        let selector = #selector(NSView.resetCursorRects)
        let method = view.method(for: selector)
        let baseMethod = NSTextView.instanceMethod(for: selector)
        XCTAssertNotEqual(method, baseMethod,
                          "SelfSizingTextView must override resetCursorRects.")
    }

    // MARK: - Coordinator round-trip

    func testCoordinator_tracksAppliedContentAcrossUpdates() async {
        let coord = SelectableMessageText.Coordinator()
        XCTAssertEqual(coord.lastAppliedContent, "")
        coord.recordApplied("Hello")
        XCTAssertEqual(coord.lastAppliedContent, "Hello")
        coord.recordApplied("Hello World")
        XCTAssertEqual(coord.lastAppliedContent, "Hello World")
    }

    func testApplyContent_drivenByCoordinator_streamsZWJCorrectly() async {
        let coord = SelectableMessageText.Coordinator()
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)

        let stages = ["👨", "👨\u{200D}", "👨\u{200D}👩", "👨\u{200D}👩\u{200D}👧"]
        for stage in stages {
            let didApply = SelectableMessageText.applyContent(
                stage,
                previousContent: coord.lastAppliedContent,
                to: view, attributes: attributes
            )
            XCTAssertTrue(didApply, "applyContent on a backed view must succeed.")
            coord.recordApplied(stage)
            XCTAssertEqual(view.string, stage,
                           "After applying \(stage), view must match input verbatim.")
        }
    }

    // MARK: - Layout reentrancy regression (I1)

    /// Frame-resize → applyContent → intrinsicContentSize → frame-resize
    /// cycle counts `ensureLayout` calls. Each cycle is bounded:
    /// applyContent triggers exactly one settle ensureLayout, and each
    /// `intrinsicContentSize` read triggers exactly one. Total per cycle
    /// must stay at the small constant we expect — anything larger means
    /// a recursive amplification path opened up between
    /// `intrinsicContentSize` ↔ `setFrameSize` ↔ `applyContent`.
    func testLayoutReentrancy_ensureLayoutCallsAreBounded() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        view.setFrameSize(NSSize(width: 300, height: 0))
        view.resetTestCountersForTesting()

        // Cycle: apply (1 ensureLayout) → read intrinsic (1) → resize (0
        // ensureLayout — only invalidate). Expected total: 2 per cycle.
        SelectableMessageText.applyContent(
            "Hello world from a long enough body to wrap once at width 300.",
            previousContent: "",
            to: view, attributes: attributes
        )
        _ = view.intrinsicContentSize
        view.setFrameSize(NSSize(width: 350, height: 0))
        let cycleOneCount = view.ensureLayoutCallCountForTesting
        XCTAssertLessThanOrEqual(cycleOneCount, 4,
            "Cycle 1: ensureLayout count = \(cycleOneCount). >4 indicates an amplification loop between intrinsicContentSize ↔ setFrameSize ↔ applyContent.")

        // Second cycle to confirm the bound holds steady (not a one-shot
        // ramp-up).
        view.resetTestCountersForTesting()
        SelectableMessageText.applyContent(
            "Hello world from a long enough body to wrap once at width 300. And a bit more.",
            previousContent: "Hello world from a long enough body to wrap once at width 300.",
            to: view, attributes: attributes
        )
        _ = view.intrinsicContentSize
        view.setFrameSize(NSSize(width: 400, height: 0))
        let cycleTwoCount = view.ensureLayoutCallCountForTesting
        XCTAssertLessThanOrEqual(cycleTwoCount, 4,
            "Cycle 2: ensureLayout count = \(cycleTwoCount). Bound must hold steady.")
    }

    // MARK: - viewDidChangeEffectiveAppearance (I6)

    /// Re-stamps foreground color across the full text storage. The
    /// override must be idempotent and must touch every glyph (defense
    /// against stale-color appearances at the append boundary).
    func testViewDidChangeEffectiveAppearance_reappliesForegroundColorAcrossStorage() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        SelectableMessageText.applyContent(
            "Hello ",
            previousContent: "",
            to: view, attributes: attributes
        )
        // Mutate one glyph's color to simulate stale-color drift, then
        // trigger the appearance-change path and confirm it's re-stamped.
        guard let storage = view.textStorage else { return XCTFail("storage missing") }
        storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       NSColor.red, "Setup precondition: glyph 0 was forced red.")

        view.viewDidChangeEffectiveAppearance()

        let restamped = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(restamped, SelectableMessageText.defaultTextColor,
                       "viewDidChangeEffectiveAppearance must re-stamp the dynamic textColor across the entire storage.")
    }

    /// Empty storage edge case — must not crash on the appearance path.
    func testViewDidChangeEffectiveAppearance_emptyStorage_isNoOp() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        XCTAssertEqual(view.textStorage?.length ?? -1, 0)
        view.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(view.textStorage?.length ?? -1, 0,
                       "Empty-storage appearance change must remain a no-op.")
    }

    // MARK: - applyContent return-value contract (C2)

    /// On a backed `SelfSizingTextView` (TextKit 1 stack guaranteed by
    /// init), every applyContent succeeds. The Bool return path's
    /// `false` branch is the textStorage-nil escape valve, only
    /// reachable on a TextKit 2 future SDK regression — pinned by
    /// implication via the assertion in production. Here we pin the
    /// happy-path contract.
    func testApplyContent_returnsTrue_onBackedTextView_appendBranch() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        XCTAssertTrue(SelectableMessageText.applyContent(
            "abc",
            previousContent: "",
            to: view, attributes: attributes
        ))
        XCTAssertTrue(SelectableMessageText.applyContent(
            "abcdef",
            previousContent: "abc",
            to: view, attributes: attributes
        ), "Append branch must return true on a backed view.")
    }

    func testApplyContent_returnsTrue_onBackedTextView_replaceBranch() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        SelectableMessageText.applyContent("abc", previousContent: "", to: view, attributes: attributes)
        XCTAssertTrue(SelectableMessageText.applyContent(
            "xyz",
            previousContent: "abc",
            to: view, attributes: attributes
        ), "Diverging-content branch must return true on a backed view.")
    }

    func testApplyContent_returnsTrue_onIdenticalContent() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        SelectableMessageText.applyContent("abc", previousContent: "", to: view, attributes: attributes)
        XCTAssertTrue(SelectableMessageText.applyContent(
            "abc",
            previousContent: "abc",
            to: view, attributes: attributes
        ), "Same-content no-op must return true (caller can safely record-applied).")
    }

    // MARK: - Fresh-realization height (blank-feed regression)
    //
    // A fresh `SelfSizingTextView`'s explicit TextKit-1 container defaults
    // to width 1e7 (`NSTextContainer()`), and `setFrameSize` is the ONLY
    // writer of the container width. When `LazyVStack` re-realizes an
    // offscreen cell, SwiftUI can read `intrinsicContentSize` BEFORE the
    // real frame lands — pre-fix that measured the text UNWRAPPED: a
    // ~1280pt paragraph reported ~16pt (80x under), realized rows collapsed
    // to slivers, and the feed rendered blank until a user scroll delivered
    // real frames. These tests pin the fallback ladder: fresh + fallback
    // available → measure at the feed's last real width; fresh + no
    // fallback → legacy unwrapped measure (graceful degradation); synced →
    // the live container always wins.

    /// Long single-paragraph prose (no newlines): unwrapped it is ONE line
    /// (~16pt); wrapped at feed width it is a genuinely tall cell (>500pt).
    /// The gap between the two is what makes every assertion unambiguous.
    private func longSingleParagraph() -> String {
        String(repeating: "wave spawner config lorem ipsum ", count: 180)
    }

    /// Seed the process-wide fallback width the way production does — a
    /// sibling cell receiving a real frame from a layout pass.
    private func seedFallbackWidth(_ width: CGFloat) {
        let throwaway = SelfSizingTextView()
        SelectableMessageText.configure(throwaway)
        throwaway.setFrameSize(NSSize(width: width, height: 0))
    }

    func testIntrinsicContentSize_freshUnsyncedView_withFallback_measuresAtLastPlausibleWidth() async {
        seedFallbackWidth(566)

        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        let coordinator = SelectableMessageText.Coordinator()
        view.fallbackMeasureCache = coordinator.measureCache
        SelectableMessageText.applyContent(
            longSingleParagraph(), previousContent: "", to: view, attributes: attributes
        )

        guard let storage = view.textStorage else { return XCTFail("storage missing") }
        let expected = coordinator.measureCache.measure(textStorage: storage, width: 566)
        XCTAssertGreaterThan(expected, 500, "Fixture must be a genuinely tall cell at feed width.")

        let size = view.intrinsicContentSize
        XCTAssertEqual(size.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(size.height, expected,
                       "A fresh cell (frame not landed, container at the 1e7 default) must measure at the feed's last real width — unwrapped it reports one line and blanks the feed.")
    }

    func testIntrinsicContentSize_subMinWidthContainer_freshView_withFallback_isNonZero() async {
        seedFallbackWidth(566)

        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        let coordinator = SelectableMessageText.Coordinator()
        view.fallbackMeasureCache = coordinator.measureCache
        SelectableMessageText.applyContent(
            longSingleParagraph(), previousContent: "", to: view, attributes: attributes
        )
        view.textContainer?.size = NSSize(width: 10, height: CGFloat.greatestFiniteMagnitude)

        guard let storage = view.textStorage else { return XCTFail("storage missing") }
        let height = view.intrinsicContentSize.height
        XCTAssertGreaterThan(height, 0,
                             "Fresh view + sub-50 container returned lastGoodIntrinsicHeight == 0 pre-fix — the literal zero-height hole.")
        XCTAssertEqual(height, coordinator.measureCache.measure(textStorage: storage, width: 566))
    }

    func testIntrinsicContentSize_freshView_noFallbackWidth_fallsBackToLegacyMeasure() async {
        // No width recorded anywhere in the process (first-ever layout).
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        let coordinator = SelectableMessageText.Coordinator()
        view.fallbackMeasureCache = coordinator.measureCache
        SelectableMessageText.applyContent(
            longSingleParagraph(), previousContent: "", to: view, attributes: attributes
        )

        let height = view.intrinsicContentSize.height
        XCTAssertGreaterThan(height, 0, "Graceful degradation: no fallback width → legacy measure, never zero.")
        XCTAssertLessThan(height, 100,
                          "Legacy measure is unwrapped (1e7-wide container) — a single paragraph is one line.")
    }

    func testIntrinsicContentSize_freshView_nilCache_legacyBehavior() async {
        seedFallbackWidth(566)

        // Cache NOT wired — production requires BOTH the width and the cache.
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        SelectableMessageText.applyContent(
            longSingleParagraph(), previousContent: "", to: view, attributes: attributes
        )

        let height = view.intrinsicContentSize.height
        XCTAssertGreaterThan(height, 0)
        XCTAssertLessThan(height, 100, "Without the measure cache the legacy unwrapped path applies.")
    }

    func testIntrinsicContentSize_emptyContent_freshView_doesNotUseFallback() async {
        seedFallbackWidth(566)

        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        let coordinator = SelectableMessageText.Coordinator()
        view.fallbackMeasureCache = coordinator.measureCache

        let height = view.intrinsicContentSize.height
        XCTAssertLessThan(height, 50, "Empty content must not produce a bogus tall height.")
        XCTAssertEqual(coordinator.measureCache.computeCount, 0,
                       "Fallback must skip empty storage — nothing to measure.")
    }

    func testIntrinsicContentSize_afterRealWidthSync_measuresLiveContainer_notFallback() async {
        seedFallbackWidth(566)

        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        let coordinator = SelectableMessageText.Coordinator()
        view.fallbackMeasureCache = coordinator.measureCache
        SelectableMessageText.applyContent(
            longSingleParagraph(), previousContent: "", to: view, attributes: attributes
        )
        guard let storage = view.textStorage else { return XCTFail("storage missing") }
        let h566 = coordinator.measureCache.measure(textStorage: storage, width: 566)

        view.setFrameSize(NSSize(width: 300, height: 0))
        let live = view.intrinsicContentSize.height
        let h300 = coordinator.measureCache.measure(textStorage: storage, width: 300)

        XCTAssertNotEqual(h300, h566,
                          "Fixture: the two widths must produce different heights for this comparison to mean anything.")
        XCTAssertEqual(live, h300, accuracy: 1.0,
                       "After a real frame lands, the live container measure wins — the fallback never overrides a synced width.")
    }

    func testSetFrameSize_plausibleWidth_recordsStaticFallbackWidth() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        // Boundary: exactly minMeasurementWidth (50) records.
        view.setFrameSize(NSSize(width: 50, height: 0))
        XCTAssertTrue(view.hasSyncedRealWidth)
        XCTAssertEqual(SelfSizingTextView.lastPlausibleMeasureWidth, 50)
    }

    func testSetFrameSize_subMinWidth_doesNotRecord() async {
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        view.setFrameSize(NSSize(width: 49.9, height: 0))
        XCTAssertFalse(view.hasSyncedRealWidth)
        XCTAssertNil(SelfSizingTextView.lastPlausibleMeasureWidth,
                     "Sub-50 frames are transient layout noise — they must not become the fallback width.")
    }

    func testIntrinsicContentSize_subMinWidthAfterSync_returnsLastGoodHeight() async {
        // No cache wired — pins the pre-existing defensive branch in isolation.
        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        SelectableMessageText.applyContent(
            longSingleParagraph(), previousContent: "", to: view, attributes: attributes
        )
        view.setFrameSize(NSSize(width: 566, height: 0))
        let synced = view.intrinsicContentSize.height
        XCTAssertGreaterThan(synced, 500)

        view.textContainer?.size = NSSize(width: 10, height: CGFloat.greatestFiniteMagnitude)
        XCTAssertEqual(view.intrinsicContentSize.height, synced,
                       "Transient sub-50 container width must return the last good height, not re-measure at ~1 glyph per line.")
    }

    func testIntrinsicContentSize_fallbackPath_doesNotRunLiveEnsureLayout() async {
        seedFallbackWidth(566)

        let view = SelfSizingTextView()
        SelectableMessageText.configure(view)
        let coordinator = SelectableMessageText.Coordinator()
        view.fallbackMeasureCache = coordinator.measureCache
        SelectableMessageText.applyContent(
            longSingleParagraph(), previousContent: "", to: view, attributes: attributes
        )
        view.resetTestCountersForTesting() // applyContent's settle-pass bumped it

        _ = view.intrinsicContentSize
        _ = view.intrinsicContentSize
        XCTAssertEqual(view.ensureLayoutCallCountForTesting, 0,
                       "Fresh-realization reads must route through the measure cache, never shape the live 1e7-wide container.")
    }

    func testFreshRealization_afterPriorCellLayout_reportsTrueHeightImmediately() async {
        let content = longSingleParagraph()

        // Cell A: laid out normally at the feed width.
        let viewA = SelfSizingTextView()
        SelectableMessageText.configure(viewA)
        SelectableMessageText.applyContent(content, previousContent: "", to: viewA, attributes: attributes)
        viewA.setFrameSize(NSSize(width: 566, height: 0))
        let settled = viewA.intrinsicContentSize.height
        XCTAssertGreaterThan(settled, 500)

        // Cell B: freshly re-realized by LazyVStack — new view, new
        // Coordinator, frame not landed. The FIRST intrinsic read must
        // already report the true height (the user-visible invariant).
        let coordinatorB = SelectableMessageText.Coordinator()
        let viewB = SelfSizingTextView()
        SelectableMessageText.configure(viewB)
        viewB.fallbackMeasureCache = coordinatorB.measureCache
        SelectableMessageText.applyContent(content, previousContent: "", to: viewB, attributes: attributes)

        XCTAssertEqual(viewB.intrinsicContentSize.height, settled, accuracy: 1.0,
                       "A re-realized cell must report its true height on the FIRST intrinsic read — this is the blank-feed regression.")
    }
}

// MARK: - Test fixtures

/// Main-thread-confined by construction: the observer is registered with
/// `queue: nil`, so NotificationCenter delivers synchronously on the posting
/// thread, and every post originates from `applyContent` on this @MainActor
/// test class. `@unchecked Sendable` records that, since `Binding`-style
/// `@Sendable` observer blocks would otherwise reject the capture.
private final class TextStorageEditRecorder: @unchecked Sendable {
    var captures: [(mask: NSTextStorageEditActions, range: NSRange)] = []
}

private final class ScrollWheelRecorder: NSResponder {
    var scrollEventCount: Int = 0
    override func scrollWheel(with event: NSEvent) {
        scrollEventCount += 1
    }
}
