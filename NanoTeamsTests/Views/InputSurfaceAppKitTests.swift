import AppKit
import SwiftUI
import XCTest
@testable import NanoTeams

/// The AppKit half of the input surface, asserted against BOTH editable representables through the
/// same parameterised body.
///
/// One corpus, two subjects, deliberately: the property that failed before 2026-08-24 was not
/// "this editor paints wrong" but "the two editors disagree" — `PromptTemplateEditor` filled the
/// card surface on the text view, `EditableMessageTextView` filled nothing at all. A per-file test
/// would have been green on both sides of that disagreement.
///
/// `@MainActor` + `async` lifecycle: a SYNC test method in a `@MainActor` class that constructs a
/// main-actor AppKit type is the `abort()` family (CLAUDE.md testing conventions), and
/// `@unchecked Sendable` is restated because it is not inherited.
@MainActor
final class InputSurfaceAppKitTests: XCTestCase, @unchecked Sendable {

    /// What every editable representable's wiring must satisfy. Named so a failure says which
    /// editor broke, not merely that "a" scroll view did.
    private func assertStamped(_ scrollView: NSScrollView,
                               editor: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return XCTFail("\(editor): documentView is not an NSTextView", file: file, line: line)
        }

        // Exactly ONE painter, and it is the scroll view — see `InputSurface.stamp` for why the
        // text view is the wrong surface (its document is shorter than the viewport when the
        // field is empty, so a textView fill paints only the top third).
        XCTAssertTrue(scrollView.drawsBackground,
                      "\(editor): the scroll view must paint the input fill", file: file, line: line)
        XCTAssertFalse(textView.drawsBackground,
                       "\(editor): the text view must not paint — the scroll view already did",
                       file: file, line: line)

        // NOT `contentView.drawsBackground == false`: measured 2026-08-24, the clip view and the
        // scroll view share one background flag, so that assertion is unsatisfiable alongside the
        // one above. What still has to hold is that the clip view cannot paint
        // `controlBackgroundColor` — which is now guaranteed by the COLOUR, not by the flag.
        XCTAssertTrue(scrollView.contentView.backgroundColor === Colors.nsSurfaceInput,
                      "\(editor): the clip view must carry the input fill, never controlBackgroundColor",
                      file: file, line: line)

        // Identity, not value: on oledDark surfacePrimary and surfaceCard are both #000000, so a
        // value assertion would pass under exactly the mutation this exists to catch.
        XCTAssertTrue(scrollView.backgroundColor === Colors.nsSurfaceInput,
                      "\(editor): the fill must be the nsSurfaceInput instance", file: file, line: line)

        XCTAssertEqual(textView.textContainerInset, InputSurface.Density.editor.nsTextInset,
                       "\(editor): inset must come from the shared Density", file: file, line: line)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, 0,
                       "\(editor): lineFragmentPadding must be 0 or the caret sits 5pt further in",
                       file: file, line: line)

        // The #50 half, restated here so it now covers BOTH editors rather than one: an AppKit
        // fill must never be rounded by a layer mask.
        XCTAssertEqual(scrollView.layer?.cornerRadius ?? 0, 0,
                       "\(editor): a rounded layer mask is an offscreen pass per frame (#50)",
                       file: file, line: line)
        XCTAssertFalse(scrollView.layer?.masksToBounds ?? false,
                       "\(editor): masksToBounds re-introduces the measured scroll hitch (#50)",
                       file: file, line: line)
    }

    func testEditableMessageTextView_isStamped() async {
        var text = "hello"
        var focused = false
        let view = EditableMessageTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 }),
            placeholder: "Message…",
            maxHeight: 180,
            minLineCount: 3,
            autofocusOnAppear: false,
            onReturnKey: { _, _ in true }
        )
        assertStamped(view.testHooks_makeNSView(coordinator: view.makeCoordinator()),
                      editor: "EditableMessageTextView")
    }

    func testPromptTemplateEditor_isStamped() async {
        var template = "Hello {roleName}."
        var pending: String? = nil
        let editor = PromptTemplateEditor(
            template: Binding(get: { template }, set: { template = $0 }),
            pendingInsertion: Binding(get: { pending }, set: { pending = $0 }),
            placeholders: [(key: "roleName", label: "Role Name", category: "role")]
        )
        assertStamped(editor.testHooks_makeNSView(coordinator: editor.makeCoordinator()),
                      editor: "PromptTemplateEditor")
    }

    /// The latch is what keeps the stamp off the streaming-rate path. Edge-triggered means: fires
    /// on a NEW value, stays silent on a repeat, and fires again when the value changes back.
    func testThemeStampLatchIsEdgeTriggered() async {
        var latch = ThemeStampLatch()
        XCTAssertTrue(latch.shouldStamp("terminal"), "first call must fire")
        XCTAssertFalse(latch.shouldStamp("terminal"), "a repeat must not fire — this is the throttle")
        XCTAssertTrue(latch.shouldStamp("oled"), "a change must fire")
        XCTAssertFalse(latch.shouldStamp("oled"))
        XCTAssertTrue(latch.shouldStamp("terminal"), "changing back is a change")
    }

    /// `.editor` and `.field` may differ in inset and nothing else — the moment they disagree on
    /// fill, border, radius or width there are two input surfaces again.
    func testDensitiesDifferOnlyInInset() async {
        XCTAssertNotEqual(InputSurface.Density.editor.nsTextInset,
                          InputSurface.Density.field.nsTextInset)
        XCTAssertEqual(InputSurface.Density.editor.nsTextInset, NSSize(width: 4, height: 4),
                       "editor inset must equal the AppKit textContainerInset so SwiftUI and NSTextView agree")
        XCTAssertNil(InputSurface.Density.editor.chromeMinHeight,
                     "a multi-line editor's height is the caller's business")
        XCTAssertEqual(InputSurface.Density.field.chromeMinHeight, 28)
    }
}
