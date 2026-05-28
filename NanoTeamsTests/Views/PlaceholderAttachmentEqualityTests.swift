import AppKit
import XCTest
@testable import NanoTeams

/// Pins `PlaceholderAttachment`'s value-equality on `(key, label, category)`.
/// Without value equality, the change-detection short-circuit in
/// `ResolvedPromptView.updateNSView` (which compares `NSTextStorage.isEqual`
/// to the new `NSAttributedString`) would always fail and force a full
/// `setAttributedString` on every SwiftUI re-render, resetting cursor and
/// selection state.
final class PlaceholderAttachmentEqualityTests: XCTestCase {

    func testEquality_sameTriple_isEqual() {
        let a = PlaceholderAttachment(key: "roleName", label: "Role Name", category: "role")
        let b = PlaceholderAttachment(key: "roleName", label: "Role Name", category: "role")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hash, b.hash, "Equal instances must have equal hash")
    }

    func testEquality_differentKey_notEqual() {
        let a = PlaceholderAttachment(key: "roleName", label: "Role Name", category: "role")
        let b = PlaceholderAttachment(key: "teamName", label: "Role Name", category: "role")
        XCTAssertNotEqual(a, b)
    }

    func testEquality_differentLabel_notEqual() {
        let a = PlaceholderAttachment(key: "roleName", label: "Role Name", category: "role")
        let b = PlaceholderAttachment(key: "roleName", label: "Different",  category: "role")
        XCTAssertNotEqual(a, b)
    }

    func testEquality_differentCategory_notEqual() {
        let a = PlaceholderAttachment(key: "roleName", label: "Role Name", category: "role")
        let b = PlaceholderAttachment(key: "roleName", label: "Role Name", category: "tools")
        XCTAssertNotEqual(a, b)
    }

    func testEquality_otherType_notEqual() {
        let a = PlaceholderAttachment(key: "roleName", label: "Role Name", category: "role")
        XCTAssertFalse(a.isEqual(NSObject()))
        XCTAssertFalse(a.isEqual(nil))
    }

    /// Regression guard: `NSAttributedString` equality recursively compares
    /// embedded `NSTextAttachment` instances via `isEqual`. Two attributed
    /// strings built from fresh PlaceholderAttachment instances with the
    /// same `(key, label, category)` must compare equal — that's what
    /// `ResolvedPromptView.updateNSView`'s short-circuit relies on.
    func testAttributedStringEquality_freshInstancesSameTriple_areEqual() {
        let attA = PlaceholderAttachment(key: "roleName", label: "Role Name", category: "role")
        let attB = PlaceholderAttachment(key: "roleName", label: "Role Name", category: "role")
        let a = NSAttributedString(attachment: attA)
        let b = NSAttributedString(attachment: attB)
        XCTAssertEqual(a, b, "Same-triple chips embedded in NSAttributedString must compare equal")
    }

    /// `color(for:)` must return a **singleton** NSColor per category. The
    /// previous implementation built `NSColor(name: nil) { ... }` fresh on
    /// every call, producing instances that compared unequal by identity
    /// even though they resolved to the same RGB. That broke
    /// `NSAttributedString.isEqual` for colored resolved-value runs, which
    /// in turn defeated `ResolvedPromptView.updateNSView`'s short-circuit
    /// and forced a full NSTextView relayout on every scroll-driven SwiftUI
    /// re-render — visible as scroll lag.
    func testColorForCategory_returnsSameInstancePerCategory() {
        for category in ["role", "context", "tools", "artifacts"] {
            let a = PlaceholderAttachment.color(for: category)
            let b = PlaceholderAttachment.color(for: category)
            XCTAssertTrue(a === b,
                "color(for: \(category)) must be a memoized singleton; got two distinct instances")
        }
    }

    /// `NSCache` hit-path pin: two attachments with the same `(label,
    /// category)` must share the same underlying `NSImage` instance — that's
    /// the perf contract that keeps NSTextView's attachment-rendering cost
    /// down across SwiftUI re-renders. `key` deliberately differs to lock in
    /// the cache key as `(label, category)` only (NOT `key`-sensitive).
    func testImageCache_sameLabelCategory_reusesNSImageInstance() {
        let a = PlaceholderAttachment(key: "k1", label: "Same Label", category: "role")
        let b = PlaceholderAttachment(key: "k2", label: "Same Label", category: "role")
        XCTAssertTrue(a.image === b.image,
            "Cache hit on (label, category) must reuse the NSImage instance regardless of `key`")
    }

    /// End-to-end regression: re-resolving the same template twice must
    /// produce `NSAttributedString` instances that compare equal under
    /// `isEqual` — which is what `ResolvedPromptView.updateNSView` calls to
    /// skip redundant `setAttributedString` work during SwiftUI re-renders.
    /// Covers both branches: chip-rendered slots AND colored-text resolved
    /// slots (the latter is where the dynamic-color identity bug bit).
    func testReResolvedTemplate_isEqualAcrossBuilds() {
        let definitions: [(key: String, label: String, category: String)] = [
            (key: "roleName", label: "Role Name", category: "role"),
            (key: "workFolderContext", label: "Work Folder Context", category: "context"),
        ]
        let template = "Role: {roleName}\n\nContext: {workFolderContext}"
        let resolvedValues: [String: String] = ["roleName": "Coding Agent"]
        // {workFolderContext} omitted → chip; {roleName} resolved → colored text.

        let first = PlaceholderParser.attributedString(
            from: template, placeholders: definitions, resolvedValues: resolvedValues
        )
        let second = PlaceholderParser.attributedString(
            from: template, placeholders: definitions, resolvedValues: resolvedValues
        )

        XCTAssertEqual(first, second,
            "Two builds of the same template must compare equal; otherwise ResolvedPromptView re-runs setAttributedString on every SwiftUI body invocation")
    }
}
