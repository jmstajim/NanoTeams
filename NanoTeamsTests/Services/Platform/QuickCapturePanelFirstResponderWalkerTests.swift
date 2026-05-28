import AppKit
import XCTest

@testable import NanoTeams

/// Characterization tests for `QuickCapturePanel.firstFocusableTextResponder`.
/// The walker drives the focus-restoration loop's "is there a text input in the
/// SwiftUI tree yet?" question — if a future change ever loosens its filters
/// (e.g. starts returning labels or hidden views), the loop would happily
/// `makeFirstResponder` on a non-text-accepting view and the caret silently
/// goes missing.
@MainActor
final class QuickCapturePanelFirstResponderWalkerTests: XCTestCase {

    private func find(in view: NSView) -> NSView? {
        QuickCapturePanel._testFirstFocusableTextResponder(in: view)
    }

    // MARK: - Negative cases

    func testReturnsNil_forEmptyView() {
        XCTAssertNil(find(in: NSView()))
    }

    func testReturnsNil_forTreeWithoutTextResponders() {
        let root = NSView()
        root.addSubview(NSView())
        root.addSubview(NSImageView())
        XCTAssertNil(find(in: root))
    }

    func testSkips_nonEditableTextField() {
        // SwiftUI `Text` renders as a non-editable `NSTextField` — must NOT be
        // returned as a focus target.
        let label = NSTextField(labelWithString: "hello")
        XCTAssertFalse(label.isEditable)
        XCTAssertNil(find(in: label))
    }

    func testSkips_nonEditableTextView() {
        // Read-only `NSTextView` (e.g. selectable display surfaces) must not
        // be promoted to first responder — keystrokes would be silently dropped.
        let textView = NSTextView()
        textView.isEditable = false
        XCTAssertNil(find(in: textView))
    }

    func testSkips_hiddenSubtree_evenIfItContainsEditableField() {
        let root = NSView()
        let hidden = NSView()
        hidden.isHidden = true
        let editable = NSTextField()
        editable.isEditable = true
        hidden.addSubview(editable)
        root.addSubview(hidden)
        XCTAssertNil(find(in: root))
    }

    // MARK: - Positive cases

    func testFinds_editableTextField_atRoot() {
        let field = NSTextField()
        field.isEditable = true
        XCTAssertTrue(find(in: field) === field)
    }

    func testFinds_editableTextField_atDepth() {
        let root = NSView()
        let mid = NSView()
        let leaf = NSTextField()
        leaf.isEditable = true
        mid.addSubview(leaf)
        root.addSubview(mid)
        XCTAssertTrue(find(in: root) === leaf)
    }

    func testFinds_editableTextView_atRoot() {
        let textView = NSTextView()
        textView.isEditable = true
        XCTAssertTrue(find(in: textView) === textView)
    }

    func testReturnsFirstMatch_inDepthFirstOrder() {
        // Two editable fields side by side — DFS must return the first one
        // encountered (subview order).
        let root = NSView()
        let firstField = NSTextField()
        firstField.isEditable = true
        let secondField = NSTextField()
        secondField.isEditable = true
        root.addSubview(firstField)
        root.addSubview(secondField)
        XCTAssertTrue(find(in: root) === firstField)
    }
}
