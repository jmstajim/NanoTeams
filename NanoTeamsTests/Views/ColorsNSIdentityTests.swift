import AppKit
import XCTest
@testable import NanoTeams

/// Regression pin for the AppKit NSColor accessors being MEMOIZED (`static let`),
/// not computed (`static var`). The redesign made them computed, so every access
/// returned a fresh dynamic `NSColor`; that broke `NSAttributedString` equality
/// and the NSTextView append-only / appearance-restamp short-circuits
/// (`SelectableMessageText`, `ResolvedPromptView`, `PlaceholderParser`), forcing
/// full relayouts on scroll (the CLAUDE.md #50 lag family). Identity stability
/// across accesses is the contract those paths depend on.
final class ColorsNSIdentityTests: XCTestCase {

    func testNSTextPrimary_isStableInstance() {
        XCTAssertTrue(Colors.nsTextPrimary === Colors.nsTextPrimary,
            "Colors.nsTextPrimary must be a memoized singleton — a fresh instance per access breaks NSAttributedString equality and NSTextView short-circuits (CLAUDE.md #50).")
    }

    func testNSTextSecondary_isStableInstance() {
        XCTAssertTrue(Colors.nsTextSecondary === Colors.nsTextSecondary,
            "Colors.nsTextSecondary must be a memoized singleton.")
    }

    func testNSSurfaceCard_isStableInstance() {
        XCTAssertTrue(Colors.nsSurfaceCard === Colors.nsSurfaceCard,
            "Colors.nsSurfaceCard must be a memoized singleton.")
    }

    /// Two `PlaceholderParser` builds of the same template must produce equal
    /// attributed strings (the resolved-text run uses `Colors.nsTextPrimary`).
    /// This is the end-to-end consequence the memoization restores, mirrored by
    /// `PlaceholderAttachmentEqualityTests.testReResolvedTemplate_isEqualAcrossBuilds`.
    func testResolvedTextColor_stableAcrossPlaceholderBuilds() {
        let defs: [(key: String, label: String, category: String)] = [
            (key: "roleName", label: "Role Name", category: "role")
        ]
        let a = PlaceholderParser.attributedString(
            from: "Role: {roleName}", placeholders: defs, resolvedValues: ["roleName": "Coding Agent"]
        )
        let b = PlaceholderParser.attributedString(
            from: "Role: {roleName}", placeholders: defs, resolvedValues: ["roleName": "Coding Agent"]
        )
        XCTAssertEqual(a, b)
    }
}
