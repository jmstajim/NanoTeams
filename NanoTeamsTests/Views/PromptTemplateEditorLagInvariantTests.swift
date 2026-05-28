import XCTest
import SwiftUI
import AppKit
@testable import NanoTeams

/// Regression guard for the `PromptTemplateEditor` lag-fix. The editor is an
/// `NSViewRepresentable` over `NSScrollView + NSTextView` used in Settings →
/// Team → Prompts. A previous iteration set
/// `scrollView.wantsLayer + layer.cornerRadius + layer.masksToBounds = true`
/// to produce a visual rounded clip — that combination is exactly the failure
/// mode documented in CLAUDE.md Swift Style #50: with a scrolling sublayer,
/// CoreAnimation does an offscreen mask pass on every trackpad-scroll frame,
/// 100%-CPU-binding the main thread for seconds at a time.
///
/// The same file was also using the convenience `NSTextView()` initializer,
/// which can opt into TextKit 2 with a nil `layoutManager` — placeholder-chip
/// attachment rendering breaks silently in that mode.
///
/// These tests are structural pins, not behavioral — they assert the
/// load-bearing properties (no rounded clip, TextKit 1 stack) so a future
/// refactor that re-introduces either failure mode trips a test instead of
/// silently shipping the lag/render regression.
///
/// Tests reach `makeNSView` via the production `testHooks_makeNSView` seam —
/// mirrors `EditableMessageTextView`'s pattern. Walking an `NSHostingView`
/// subtree (the prior approach) was fragile against SwiftUI internals and
/// silently fell back to a fresh empty NSScrollView on miss, which would
/// trivially satisfy every structural assertion.
@MainActor
final class PromptTemplateEditorLagInvariantTests: XCTestCase {

    /// `wantsLayer + cornerRadius + masksToBounds` over a scrolling sublayer
    /// forces an offscreen GPU mask per CA frame (CLAUDE.md Swift Style #50).
    /// None of these may be set; the visual frame is contributed by the
    /// caller's SwiftUI `.overlay(strokeBorder)` (or omitted) instead.
    func testMakeNSView_scrollViewHasNoLayerRoundedClip() {
        let scrollView = makeEditor()

        XCTAssertEqual(
            scrollView.layer?.cornerRadius ?? 0, 0,
            "scrollView.layer.cornerRadius must be 0 — see CLAUDE.md Swift Style #50."
        )
        XCTAssertFalse(
            scrollView.layer?.masksToBounds ?? false,
            "scrollView.layer.masksToBounds must be false — see CLAUDE.md Swift Style #50."
        )
    }

    /// Both `scrollView.drawsBackground` and the inner `NSClipView`'s
    /// `drawsBackground` must be false. The clip view defaults to drawing
    /// `controlBackgroundColor`; without disabling it, the textView's own
    /// background is occluded. The outer scroll view's `drawsBackground`
    /// being false is what lets the textView's `backgroundColor` be the
    /// sole visible fill.
    func testMakeNSView_neitherScrollViewNorClipViewDrawsBackground() {
        let scrollView = makeEditor()

        XCTAssertFalse(
            scrollView.drawsBackground,
            "scrollView.drawsBackground must be false so the textView's own backgroundColor is the visible fill."
        )
        XCTAssertFalse(
            scrollView.contentView.drawsBackground,
            "scrollView.contentView (NSClipView) must NOT draw background — otherwise it paints controlBackgroundColor over the textView."
        )
    }

    /// The convenience `NSTextView()` initializer may opt into TextKit 2 with
    /// a nil `layoutManager`. The fix uses `init(frame:textContainer:)` with
    /// an explicitly-built TextKit 1 stack so `layoutManager` and
    /// `textStorage` are guaranteed non-nil and chip-attachment rendering
    /// continues to work.
    func testMakeNSView_textViewHasTextKit1Stack() {
        let scrollView = makeEditor()
        guard let textView = scrollView.documentView as? NSTextView else {
            XCTFail("documentView must be NSTextView")
            return
        }

        XCTAssertNotNil(
            textView.layoutManager,
            "NSTextView.layoutManager must be non-nil — TextKit 2 nil-layoutManager mode breaks chip rendering."
        )
        XCTAssertNotNil(
            textView.textStorage,
            "NSTextView.textStorage must be non-nil — every storage read in the file relies on this invariant."
        )
        XCTAssertNotNil(
            textView.textContainer,
            "NSTextView.textContainer must be non-nil — explicit container wires width-tracking and wrapping."
        )
        XCTAssertTrue(
            textView.textContainer?.widthTracksTextView ?? false,
            "textContainer.widthTracksTextView must be true so wrapping reflows on resize."
        )
    }

    // MARK: - Test helpers

    /// Drives `testHooks_makeNSView` against a freshly-built `Coordinator`,
    /// returning the production NSScrollView. Bypasses `NSHostingView` so the
    /// test pins the actual production wiring and never lands on a fallback
    /// empty NSScrollView when SwiftUI's hosting internals shift shape.
    private func makeEditor() -> NSScrollView {
        var template = "Hello {roleName}, your task is {taskBrief}."
        var pendingInsertion: String? = nil
        let editor = PromptTemplateEditor(
            template: Binding(get: { template }, set: { template = $0 }),
            pendingInsertion: Binding(get: { pendingInsertion }, set: { pendingInsertion = $0 }),
            placeholders: [
                (key: "roleName", label: "Role Name", category: "role"),
                (key: "taskBrief", label: "Task Brief", category: "context")
            ]
        )
        let coordinator = editor.makeCoordinator()
        return editor.testHooks_makeNSView(coordinator: coordinator)
    }
}
