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

    /// The chip cache's key is `(label, category)` and nothing else — two slots naming the same
    /// placeholder render identical pixels, so `key` must not split them into two cache entries.
    ///
    /// This replaces an assertion that two attachments built with the same `(label, category)`
    /// share one `NSImage` INSTANCE. That asked `NSCache` for a guarantee it does not make:
    /// eviction is legal at any moment and under a coverage-instrumented parallel run it happens,
    /// so the test failed intermittently — twice at the cost of a five-minute measurement, and
    /// never reproducibly in isolation. Instance identity is the cache's business; the key is
    /// ours, it is the part a refactor can actually break, and it cannot flake.
    ///
    /// RED: fold `key` into `imageCacheKey` → the first assertion fails. Drop `category` from it
    /// → the second does.
    func testImageCacheKey_isLabelAndCategoryOnly() {
        XCTAssertEqual(
            PlaceholderAttachment.imageCacheKey(label: "Same Label", category: "role"),
            PlaceholderAttachment.imageCacheKey(label: "Same Label", category: "role"),
            "the key must not depend on the slot's `key` — these two are the same chip")
        XCTAssertNotEqual(
            PlaceholderAttachment.imageCacheKey(label: "Same Label", category: "role"),
            PlaceholderAttachment.imageCacheKey(label: "Same Label", category: "context"),
            "category picks the chip colour, so it has to split the entry")
        XCTAssertNotEqual(
            PlaceholderAttachment.imageCacheKey(label: "A", category: "role"),
            PlaceholderAttachment.imageCacheKey(label: "B", category: "role"))
    }

    /// And the key is what `init` actually consults, so the pin above is not about a function
    /// nobody calls: an attachment's rendered size is a pure function of `(label, category)`.
    /// Size rather than instance identity — same reason as above.
    func testAttachmentsSharingLabelAndCategory_renderTheSameChip() {
        let a = PlaceholderAttachment(key: "k1", label: "Same Label", category: "role")
        let b = PlaceholderAttachment(key: "k2", label: "Same Label", category: "role")
        XCTAssertEqual(a.image?.size, b.image?.size)
        XCTAssertEqual(a.bounds, b.bounds)
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
